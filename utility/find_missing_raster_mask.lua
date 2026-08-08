-- find_missing_raster_mask.lua — find images whose rasterfile module references an external raster mask file that is missing
--
-- The darktable lua API does not expose module history parameters, so the
-- rasterfile (external raster mask) filepath cannot be read through it. This
-- script therefore inspects the SQLite library database directly (read-only, on
-- a private copy) and decodes the rasterfile "op_params" blob.
--
-- The rasterfile op_params (4100 bytes) stores two null-terminated fields:
--   offset    4 : char folder[2048]   (the directory)
--   offset 2052 : char filename[2048] (the mask file name, e.g. *.pfm)
-- The full mask path is folder .. "/" .. filename.
--
-- It then checks whether every referenced mask file exists, and can select
-- and/or tag the images that point at a missing external raster mask.

local dt = require "darktable"

-- --- CONFIG ----------------------------------------------------------------
-- Path to the sqlite3 command line tool. /usr/bin/sqlite3 ships with macOS and
-- most Linux distributions. Change if yours lives elsewhere.
local SQLITE_PATH = "/usr/bin/sqlite3"

-- Tag attached to affected images when "Tag found images" is enabled.
local MISSING_TAG = "missing-raster-mask"

-- Byte offsets (1-based, for SQLite substr) and field size of the folder and
-- filename strings inside the rasterfile op_params blob.
local FIELD_SIZE     = 2048
local FOLDER_POS     = 5      -- byte offset 4 -> substr position 5
local FILENAME_POS   = 2053   -- byte offset 2052 -> substr position 2053

-- --- UI --------------------------------------------------------------------
local opt_select = dt.new_widget("check_button") { label = " Select found images", value = true }
local opt_tag    = dt.new_widget("check_button") { label = " Tag found images ('" .. MISSING_TAG .. "')", value = false }
local status     = dt.new_widget("label") { label = "Ready." }
local report     = dt.new_widget("label") { label = "" }

-- --- small helpers ---------------------------------------------------------
local function q(s) return "'" .. tostring(s):gsub("'", [['"'"']]) .. "'" end

local function file_exists(path)
  local f = io.open(path, "r")
  if f then f:close() return true end
  return false
end

-- Decode a hex string (a null-terminated char[] field of op_params) into its
-- string value, stopping at the first null byte. This also discards any stale
-- bytes left behind when a shorter value was written over a longer one.
local function hex_to_string(hex)
  local chars = {}
  for i = 1, #hex - 1, 2 do
    local byte = tonumber(hex:sub(i, i + 1), 16)
    if not byte or byte == 0 then break end
    chars[#chars + 1] = string.char(byte)
  end
  return table.concat(chars)
end

-- Join the stored folder and filename the same way darktable does with
-- g_build_filename().
local function join(folder, filename)
  folder   = folder:gsub("\\", "/")
  filename = filename:gsub("\\", "/")
  if folder == ""   then return filename end
  if filename == "" then return folder end
  return (folder:gsub("/+$", "") .. "/" .. filename):gsub("//+", "/")
end

-- --- main ------------------------------------------------------------------
local function find_missing()
  status.label = "Scanning database..."
  report.label = ""

  local config_dir = dt.configuration.config_dir
  local db          = config_dir .. "/library.db"

  -- Work on a private copy so darktable's live database is never touched and we
  -- can't hit lock contention. Copy the WAL/SHM sidecars too, if present, so the
  -- snapshot is consistent.
  local tmpdb = dt.configuration.tmp_dir .. "/dtrastermask_scan.db"
  os.remove(tmpdb) ; os.remove(tmpdb .. "-wal") ; os.remove(tmpdb .. "-shm")
  os.execute("cp " .. q(db) .. " " .. q(tmpdb) .. " 2>/dev/null")
  os.execute("cp " .. q(db .. "-wal") .. " " .. q(tmpdb .. "-wal") .. " 2>/dev/null")
  os.execute("cp " .. q(db .. "-shm") .. " " .. q(tmpdb .. "-shm") .. " 2>/dev/null")

  if not file_exists(tmpdb) then
    status.label = "Error: could not read library.db"
    return
  end

  -- For every image, take the latest active rasterfile step per module instance
  -- (multi_priority) and keep it only if that step is enabled. This reflects the
  -- module's current on/off state rather than superseded history entries.
  local sql = string.format([[
    SELECT h.imgid,
           hex(substr(h.op_params, %d, %d)),
           hex(substr(h.op_params, %d, %d))
    FROM history h
    JOIN images i ON i.id = h.imgid
    JOIN (
      SELECT hh.imgid AS imgid, hh.multi_priority AS mp, MAX(hh.num) AS maxnum
      FROM history hh
      JOIN images ii ON ii.id = hh.imgid
      WHERE hh.operation = 'rasterfile' AND hh.num < ii.history_end
      GROUP BY hh.imgid, hh.multi_priority
    ) last ON last.imgid = h.imgid AND last.mp = h.multi_priority AND last.maxnum = h.num
    WHERE h.operation = 'rasterfile' AND h.enabled = 1;
  ]], FOLDER_POS, FIELD_SIZE, FILENAME_POS, FIELD_SIZE)

  local pipe = io.popen(SQLITE_PATH .. " -batch -separator '|' " .. q(tmpdb) .. " " .. q(sql) .. " 2>/dev/null")
  local rows = {}
  if pipe then
    for line in pipe:lines() do rows[#rows + 1] = line end
    pipe:close()
  end
  os.remove(tmpdb) ; os.remove(tmpdb .. "-wal") ; os.remove(tmpdb .. "-shm")

  -- Group the references by resolved path and note which images are affected.
  local exist_cache = {}
  local function is_missing(path)
    if exist_cache[path] == nil then exist_cache[path] = not file_exists(path) end
    return exist_cache[path]
  end

  local missing_count = {}   -- resolved path -> number of references
  local missing_order = {}   -- keeps report ordering stable
  local missing_imgids = {}  -- imgid -> true
  local total_refs = 0

  for _, line in ipairs(rows) do
    local id, folder_hex, filename_hex = line:match("^(%d+)|([^|]*)|(.*)$")
    if id then
      total_refs = total_refs + 1
      local folder   = hex_to_string(folder_hex)
      local filename = hex_to_string(filename_hex)
      if filename ~= "" then
        local full = join(folder, filename)
        if is_missing(full) then
          if not missing_count[full] then
            missing_count[full] = 0
            missing_order[#missing_order + 1] = full
          end
          missing_count[full] = missing_count[full] + 1
          missing_imgids[tonumber(id)] = true
        end
      end
    end
  end

  -- Map the affected image ids to lua image objects.
  local found = {}
  if next(missing_imgids) then
    for i = 1, #dt.database do
      local img = dt.database[i]
      if missing_imgids[img.id] then found[#found + 1] = img end
    end
  end

  -- Act on the results.
  if opt_select.value and #found > 0 then
    dt.gui.selection(found)
  end
  if opt_tag.value and #found > 0 then
    local tag = dt.tags.create(MISSING_TAG)
    for _, img in ipairs(found) do dt.tags.attach(tag, img) end
  end

  -- Build a report (also written to the log for easy copy/paste).
  local lines = {}
  lines[#lines + 1] = string.format("Active rasterfile references: %d", total_refs)
  lines[#lines + 1] = string.format("Missing raster mask files: %d  (affecting %d image(s))", #missing_order, #found)
  for _, f in ipairs(missing_order) do
    lines[#lines + 1] = string.format("  - %s  [x%d]", f, missing_count[f])
  end
  local text = table.concat(lines, "\n")
  report.label = text
  dt.print_log("[find_missing_raster_mask]\n" .. text)

  status.label = string.format("Done. %d image(s) reference a missing raster mask.", #found)
  dt.print(status.label)
end

-- Remove the 'missing-raster-mask' tag from all images (and delete the tag
-- itself), so a re-scan starts from a clean slate.
local function clear_tag()
  local target
  for _, t in ipairs(dt.tags) do
    if t.name == MISSING_TAG then target = t break end
  end
  if not target then
    status.label = string.format("No '%s' tag found.", MISSING_TAG)
    return
  end
  local n = #target
  dt.tags.delete(target)
  status.label = string.format("Cleared '%s' tag from %d image(s).", MISSING_TAG, n)
  dt.print(status.label)
end

-- --- UI assembly & registration --------------------------------------------
local button = dt.new_widget("button") {
  label = "Find images with missing raster mask",
  tooltip = "Scan the library for images whose external raster mask (rasterfile) file is missing",
  clicked_callback = find_missing
}

local clear_button = dt.new_widget("button") {
  label = "Clear '" .. MISSING_TAG .. "' tag",
  tooltip = "Detach the '" .. MISSING_TAG .. "' tag from all images (deletes the tag)",
  clicked_callback = clear_tag
}

local ui = dt.new_widget("box") {
  orientation = "vertical",
  opt_select,
  opt_tag,
  button,
  clear_button,
  dt.new_widget("separator") {},
  status,
  report
}

dt.register_lib(
  "find_missing_raster_mask", "missing raster mask finder", true, false,
  { [dt.gui.views.lighttable] = { "DT_UI_CONTAINER_PANEL_RIGHT_CENTER", 100 } },
  ui, nil, nil
)

dt.print_log("find_missing_raster_mask.lua loaded.")
