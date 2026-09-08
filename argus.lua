-- argus.lua — zero-shot image tagging with SigLIP
--
-- Runs tagger.py (via uv) on the selected images and attaches the resulting
-- labels as hierarchical tags under Argus| (e.g. Argus|Animals|Dog,
-- Argus|Location|Indoor|Kitchen, Argus|Light|Sunset — see data/vocabulary.tsv).
-- Everything runs locally; see readme.md for the one-time uv setup.

local this_module = ...
local folder = this_module and this_module:match("^(.*[/\\])") or ""

local dt = require "darktable"
-- CHANGED: dt.control.execute() cannot handle a command with more than one
-- quoted item on Windows; dtutils.system.windows_command() runs it via a
-- batch file instead. Ships with darktable, no extra install needed.
local dsys = require "lib/dtutils.system"
local json = require(folder .. "lib/json")

-- `folder` is the module prefix for require(); to invoke tagger.py we need
-- this file's directory as an absolute filesystem path instead (the module
-- name is relative to darktable's lua/ directory).
local source = debug.getinfo(1, "S").source:gsub("^@", "")
local script_dir = source:match("^(.*[/\\])") or ""
if script_dir:sub(1, 1) ~= "/" and not script_dir:match("^%a:[/\\]") then
  script_dir = dt.configuration.config_dir .. "/lua/" .. script_dir
end

local MODULE = "argus"
local DEFAULT_PREFIX = "Argus"

-- the tagger emits full hierarchy paths ("Objects|Vehicles|Car"); we only
-- root them under the configurable prefix (default Argus|) so machine tags
-- stay recognizable

-- --- preferences ------------------------------------------------------------

dt.preferences.register(
  MODULE, "prefix", "string",
  "argus: tag prefix",
  "Root under which all tags are attached, without the trailing | "
  .. "(empty = " .. DEFAULT_PREFIX .. "). Also used to detect already "
  .. "tagged images, so tags made with an older prefix are not recognized",
  DEFAULT_PREFIX
)

dt.preferences.register(
  MODULE, "capitalize_prefix", "bool",
  "argus: capitalize tag prefix",
  "Force the first letter of the tag prefix to a capital "
  .. "(unchecked forces it to lowercase)",
  true
)

dt.preferences.register(
  MODULE, "threshold", "float",
  "argus: score threshold",
  "Minimum score (0-1) for a label to become a tag; SigLIP scores generic "
  .. "labels low, correct ones usually land between 0.001 and 0.3",
  0.001, 0.0, 1.0, 0.001
)

dt.preferences.register(
  MODULE, "topk_scene", "integer",
  "argus: max scene tags",
  "At most this many Places365 scene tags per image",
  3, 0, 20
)

dt.preferences.register(
  MODULE, "topk_object", "integer",
  "argus: max object tags",
  "At most this many OpenImages object tags per image",
  8, 0, 50
)

dt.preferences.register(
  MODULE, "topk_extra", "integer",
  "argus: max extra tags",
  "At most this many tags from the user-editable extra list per image",
  3, 0, 20
)

dt.preferences.register(
  MODULE, "skip_tagged", "bool",
  "argus: skip already tagged images",
  "Leave out images that already carry any tag under the configured prefix",
  true
)

-- --- helpers ----------------------------------------------------------------

local function quote(arg)
  return '"' .. tostring(arg):gsub('"', '\\"') .. '"'
end

-- number-to-string that ignores the locale (a Dutch locale would otherwise
-- render 0.15 as "0,15" and break the tagger's argument parsing) and trims
-- float32 noise like 0.0010000000474975 from preference values
local function fmt_num(x)
  return (string.format("%.6g", x):gsub(",", "."))
end

-- CHANGED: compare paths regardless of slash direction. Lua builds
-- "C:\Photos/IMG.CR3"; Python may hand back either form, and a mismatch
-- means zero tags attached with no error message.
local function norm(p) return (p:gsub("\\", "/")) end

-- darktable launched from the GUI often has a minimal PATH, so look for uv
-- in the usual install locations before falling back to the bare name.
-- CHANGED: added a Windows branch. HOME is unset on Windows (it is
-- USERPROFILE) and none of the POSIX paths exist, so this always fell
-- through to a bare "uv" that only worked if darktable inherited a PATH
-- containing it.
local function find_uv()
  if dt.configuration.running_os == "windows" then
    local up = os.getenv("USERPROFILE") or ""
    local la = os.getenv("LOCALAPPDATA") or ""
    local candidates = {
      up .. "\\.local\\bin\\uv.exe",
      la .. "\\Microsoft\\WinGet\\Links\\uv.exe",
      la .. "\\Programs\\uv\\uv.exe",
    }
    for _, path in ipairs(candidates) do
      local f = io.open(path, "r")
      if f then f:close() return path end
    end
    return "uv.exe"
  end

  local home = os.getenv("HOME") or ""
  local candidates = {
    home .. "/.local/bin/uv",
    "/opt/homebrew/bin/uv",
    "/usr/local/bin/uv",
    "/usr/bin/uv",
  }
  for _, path in ipairs(candidates) do
    local f = io.open(path, "r")
    if f then f:close() return path end
  end
  return "uv"
end

local function tagger_path()
  return script_dir .. "tagger.py"
end

-- the configured tag root including the trailing "|", e.g. "Argus|"
local function tag_prefix()
  local p = dt.preferences.read(MODULE, "prefix", "string") or ""
  p = p:gsub("%s+$", ""):gsub("|+$", "")
  if p == "" then p = DEFAULT_PREFIX end
  local first = p:sub(1, 1)
  if dt.preferences.read(MODULE, "capitalize_prefix", "bool") then
    first = first:upper()
  else
    first = first:lower()
  end
  return first .. p:sub(2) .. "|"
end

local function has_argus_tag(image, prefix)
  for _, tag in ipairs(dt.tags.get_tags(image)) do
    if tag.name:sub(1, #prefix) == prefix then return true end
  end
  return false
end

local function read_file(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local content = f:read("*a")
  f:close()
  return content
end

-- --- main action ------------------------------------------------------------

local function tag_images(images)
  if #images == 0 then
    dt.print("argus: no images selected")
    return
  end

  -- keep only images the run should touch, remembering each by its full path
  local by_path = {}
  local prefix = tag_prefix()
  local skip_tagged = dt.preferences.read(MODULE, "skip_tagged", "bool")
  local paths = {}
  for _, image in ipairs(images) do
    if not (skip_tagged and has_argus_tag(image, prefix)) then
      -- CHANGED: normalise the key
      local path = norm(image.path .. "/" .. image.filename)
      paths[#paths + 1] = path
      by_path[path] = image
    end
  end
  if #paths == 0 then
    dt.print("argus: all selected images already have " .. prefix .. " tags")
    return
  end

  local tmp = dt.configuration.tmp_dir
  local paths_file = tmp .. "/argus-paths.txt"
  local json_file = tmp .. "/argus-tags.json"
  local log_file = tmp .. "/argus.log"
  local progress_file = tmp .. "/argus-progress.txt"

  local f = io.open(paths_file, "w")
  if not f then
    dt.print("argus: cannot write " .. paths_file)
    return
  end
  f:write(table.concat(paths, "\n"), "\n")
  f:close()
  os.remove(json_file)
  os.remove(progress_file)

  local command = table.concat({
    quote(find_uv()), "run", quote(tagger_path()),
    "--in", quote(paths_file),
    "--out", quote(json_file),
    "--threshold", fmt_num(dt.preferences.read(MODULE, "threshold", "float")),
    "--topk-scene", fmt_num(dt.preferences.read(MODULE, "topk_scene", "integer")),
    "--topk-object", fmt_num(dt.preferences.read(MODULE, "topk_object", "integer")),
    "--topk-extra", fmt_num(dt.preferences.read(MODULE, "topk_extra", "integer")),
    "--progress", quote(progress_file),
  }, " ") .. " 2> " .. quote(log_file)

  -- CHANGED: force UTF-8 for all of Python's default file encodings.
  -- Without it, reading vocabulary.tsv or any data file containing
  -- non-ASCII characters raises UnicodeDecodeError under the cp1252
  -- Windows default. Works because windows_command runs the whole string
  -- through a batch file.
  if dt.configuration.running_os == "windows" then
    command = 'set "PYTHONUTF8=1" & ' .. command
  end

  dt.print(string.format("argus: tagging %d image(s)…", #paths))
  dt.print_log("argus: " .. command)

  -- dt.control.execute yields this coroutine while the tagger runs, so a
  -- dispatched sibling can poll the progress file the tagger overwrites
  -- after every batch and move a progress bar (bottom left). The bar sits
  -- at 0% while the model loads, which dominates the very first run.
  local job = dt.gui.create_job(
    string.format("argus: tagging %d image(s)", #paths), true)
  local finished = false
  dt.control.dispatch(function()
    while not finished do
      dt.control.sleep(500)
      if finished then break end
      local done, total = (read_file(progress_file) or ""):match("^(%d+)%s+(%d+)")
      if total and tonumber(total) > 0 then
        job.percent = tonumber(done) / tonumber(total)
      end
    end
  end)

  -- CHANGED: route through windows_command on Windows. This is the fix for
  -- "The filename, directory name, or volume label syntax is incorrect."
  local rc
  if dt.configuration.running_os == "windows" then
    rc = dsys.windows_command(command)
  else
    rc = dt.control.execute(command)
  end
  finished = true
  job.valid = false

  if rc ~= 0 then
    dt.print("argus: tagger failed (exit " .. rc .. "), see " .. log_file)
    return
  end

  local content = read_file(json_file)
  if not content then
    dt.print("argus: tagger produced no output, see " .. log_file)
    return
  end
  local ok, results = pcall(json.decode, content)
  if not ok or type(results) ~= "table" then
    dt.print("argus: cannot parse tagger output: " .. tostring(results))
    return
  end

  local tagged, attached = 0, 0
  for path, groups in pairs(results) do
    -- CHANGED: normalise the lookup too
    local image = by_path[norm(path)]
    if image then
      local any = false
      for _, group_entries in pairs(groups) do
        for _, entry in ipairs(group_entries) do
          local tag = dt.tags.create(prefix .. entry[1])
          dt.tags.attach(tag, image)
          attached = attached + 1
          any = true
        end
      end
      if any then tagged = tagged + 1 end
    end
  end

  dt.print(string.format(
    "argus: attached %d tag(s) to %d of %d image(s)",
    attached, tagged, #paths))
end

-- --- registration -----------------------------------------------------------

-- CHANGED: darktable 5.6 sets the global darktable_gui_safe when it is safe
-- to install a lib; registering earlier silently drops the button because
-- of a startup race that reports lighttable before it is initialized.
local registered = false

local function register_ui()
  if registered then return end
  registered = true
  dt.gui.libs.image.register_action(
    MODULE, "argus: auto tag",
    function(_, images) tag_images(images) end,
    "tag the selected images with Places365 scenes and OpenImages objects"
  )
end

if darktable_gui_safe then
  register_ui()
else
  dt.register_event(MODULE .. "_gui", "view-changed",
    function(_, old, new)
      if new.id == "lighttable" and darktable_gui_safe then
        register_ui()
        dt.destroy_event(MODULE .. "_gui", "view-changed")
      end
    end)
end

dt.register_event(
  MODULE, "shortcut",
  function() tag_images(dt.gui.action_images) end,
  "argus: auto tag selected images"
)

dt.print_log("argus.lua loaded.")

-- CHANGED: script_manager expects a table with destroy/restart so the
-- script can be started and stopped from the scripts module.
local script_data = {}
script_data.metadata = {
  name = "argus",
  purpose = "zero-shot image tagging with SigLIP",
  author = "",
  help = "",
}
script_data.destroy = function()
  dt.gui.libs.image.destroy_action(MODULE)
  dt.destroy_event(MODULE, "shortcut")
end
script_data.destroy_method = nil
script_data.restart = nil
script_data.show = nil

return script_data
