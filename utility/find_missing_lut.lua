-- find_missing_lut.lua — find images whose lut3d module references a LUT file that is missing
--
-- The darktable lua API does not expose module history parameters, so the lut3d
-- filepath cannot be read through it. This script therefore inspects the SQLite
-- library database directly (read-only, on a private copy) and decodes the
-- lut3d "op_params" blob, whose first field is the 512-byte, null-terminated
-- LUT filepath (relative to the "plugins/darkroom/lut3d/def_path" root folder).
--
-- It then resolves every referenced LUT, checks whether the file exists, and can
-- select and/or tag the images that point at a missing LUT.

local dt = require "darktable"

-- --- CONFIG ----------------------------------------------------------------
-- Path to the sqlite3 command line tool. /usr/bin/sqlite3 ships with macOS and
-- most Linux distributions. Change if yours lives elsewhere.
local SQLITE_PATH = "/usr/bin/sqlite3"

-- Tag attached to affected images when "Tag found images" is enabled.
local MISSING_TAG = "missing-lut"

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

-- Decode a hex string (the leading bytes of op_params) into the
-- null-terminated filepath stored at the start of the lut3d params struct.
local function hex_to_filepath(hex)
  local chars = {}
  for i = 1, #hex - 1, 2 do
    local byte = tonumber(hex:sub(i, i + 1), 16)
    if not byte or byte == 0 then break end
    chars[#chars + 1] = string.char(byte)
  end
  return table.concat(chars)
end

-- Read the lut3d root folder ("def_path") from darktablerc.
local function read_lut_root(config_dir)
  local f = io.open(config_dir .. "/darktablerc", "r")
  if not f then return "" end
  local root = ""
  for line in f:lines() do
    local v = line:match("^plugins/darkroom/lut3d/def_path=(.*)$")
    if v then root = v break end
  end
  f:close()
  return root
end

-- Resolve a stored (relative) LUT path against the root folder, the same way
-- darktable does with g_build_filename().
local function resolve(root, filepath)
  filepath = filepath:gsub("\\", "/")
  if root == "" then return filepath end
  root = root:gsub("\\", "/"):gsub("/+$", "")
  return (root .. "/" .. filepath):gsub("//+", "/")
end

-- --- main ------------------------------------------------------------------
local function find_missing()
  status.label = "Scanning database..."
  report.label = ""

  local config_dir = dt.configuration.config_dir
  local db          = config_dir .. "/library.db"
  local lut_root    = read_lut_root(config_dir)

  -- Work on a private copy so darktable's live database is never touched and we
  -- can't hit lock contention. Copy the WAL/SHM sidecars too, if present, so the
  -- snapshot is consistent.
  local tmpdb = dt.configuration.tmp_dir .. "/dtlut_scan.db"
  os.remove(tmpdb) ; os.remove(tmpdb .. "-wal") ; os.remove(tmpdb .. "-shm")
  os.execute("cp " .. q(db) .. " " .. q(tmpdb) .. " 2>/dev/null")
  os.execute("cp " .. q(db .. "-wal") .. " " .. q(tmpdb .. "-wal") .. " 2>/dev/null")
  os.execute("cp " .. q(db .. "-shm") .. " " .. q(tmpdb .. "-shm") .. " 2>/dev/null")

  if not file_exists(tmpdb) then
    status.label = "Error: could not read library.db"
    return
  end

  -- For every image, take the latest active lut3d step per module instance
  -- (multi_priority) and keep it only if that step is enabled. This reflects the
  -- module's current on/off state rather than superseded history entries.
  local sql = [[
    SELECT h.imgid, hex(substr(h.op_params, 1, 512))
    FROM history h
    JOIN images i ON i.id = h.imgid
    JOIN (
      SELECT hh.imgid AS imgid, hh.multi_priority AS mp, MAX(hh.num) AS maxnum
      FROM history hh
      JOIN images ii ON ii.id = hh.imgid
      WHERE hh.operation = 'lut3d' AND hh.num < ii.history_end
      GROUP BY hh.imgid, hh.multi_priority
    ) last ON last.imgid = h.imgid AND last.mp = h.multi_priority AND last.maxnum = h.num
    WHERE h.operation = 'lut3d' AND h.enabled = 1;
  ]]

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
    local id, hex = line:match("^(%d+)|(.*)$")
    if id then
      total_refs = total_refs + 1
      local filepath = hex_to_filepath(hex)
      if filepath ~= "" then
        local full = resolve(lut_root, filepath)
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
  lines[#lines + 1] = "LUT root: " .. (lut_root ~= "" and lut_root or "(not set)")
  lines[#lines + 1] = string.format("Active lut3d references: %d", total_refs)
  lines[#lines + 1] = string.format("Missing LUT files: %d  (affecting %d image(s))", #missing_order, #found)
  for _, f in ipairs(missing_order) do
    lines[#lines + 1] = string.format("  - %s  [x%d]", f, missing_count[f])
  end
  local text = table.concat(lines, "\n")
  report.label = text
  dt.print_log("[find_missing_lut]\n" .. text)

  status.label = string.format("Done. %d image(s) reference a missing LUT.", #found)
  dt.print(status.label)
end

-- Remove the 'missing-lut' tag from all images (and delete the tag itself), so a
-- re-scan starts from a clean slate.
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
  label = "Find images with missing LUT",
  tooltip = "Scan the library for images whose 3D LUT (lut3d) file is missing",
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
  "find_missing_lut", "missing LUT finder", true, false,
  { [dt.gui.views.lighttable] = { "DT_UI_CONTAINER_PANEL_RIGHT_CENTER", 100 } },
  ui, nil, nil
)

dt.print_log("find_missing_lut.lua loaded.")
