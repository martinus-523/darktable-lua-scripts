-- argus.lua — zero-shot image tagging with SigLIP
--
-- Runs tagger.py (via uv) on the selected images and attaches the resulting
-- labels as hierarchical tags under Argus| (e.g. Argus|Animals|Dog,
-- Argus|Location|Indoor|Kitchen, Argus|Light|Sunset — see data/vocabulary.tsv).
-- Everything runs locally; see readme.md for the one-time uv setup.

local this_module = ...
local folder = this_module and this_module:match("^(.*[/\\])") or ""

local dt = require "darktable"
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

-- darktable launched from the GUI often has a minimal PATH, so look for uv
-- in the usual install locations before falling back to the bare name.
local function find_uv()
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
      local path = image.path .. "/" .. image.filename
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

  local f = io.open(paths_file, "w")
  if not f then
    dt.print("argus: cannot write " .. paths_file)
    return
  end
  f:write(table.concat(paths, "\n"), "\n")
  f:close()
  os.remove(json_file)

  local command = table.concat({
    quote(find_uv()), "run", quote(tagger_path()),
    "--in", quote(paths_file),
    "--out", quote(json_file),
    "--threshold", fmt_num(dt.preferences.read(MODULE, "threshold", "float")),
    "--topk-scene", fmt_num(dt.preferences.read(MODULE, "topk_scene", "integer")),
    "--topk-object", fmt_num(dt.preferences.read(MODULE, "topk_object", "integer")),
    "--topk-extra", fmt_num(dt.preferences.read(MODULE, "topk_extra", "integer")),
  }, " ") .. " 2> " .. quote(log_file)

  dt.print(string.format("argus: tagging %d image(s)…", #paths))
  dt.print_log("argus: " .. command)

  local rc = dt.control.execute(command)
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
    local image = by_path[path]
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

dt.gui.libs.image.register_action(
  MODULE, "argus: auto tag",
  function(_, images) tag_images(images) end,
  "tag the selected images with Places365 scenes and OpenImages objects"
)

dt.register_event(
  MODULE, "shortcut",
  function() tag_images(dt.gui.action_images) end,
  "argus: auto tag selected images"
)

dt.print_log("argus.lua loaded.")
