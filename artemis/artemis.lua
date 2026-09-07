-- artemis.lua — animal & bird species identification with BioCLIP 2.5
--
-- Runs tagger.py (via uv) on the selected images and attaches the predicted
-- taxonomy as hierarchical tags under Artemis| — by default one scientific
-- and one English tag per identification, e.g.
-- Artemis|Scientific|Aves|Passeriformes|Paridae|Parus major and
-- Artemis|English|Birds|Perching Birds|Tits and Chickadees|Great Tit. The tagger
-- only descends the taxonomy as far as it is confident, so an unclear photo
-- may end at order or family level. Everything runs locally; see readme.md
-- for the one-time uv setup (the first run downloads ~7 GB of model data).

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

local MODULE = "artemis"
local DEFAULT_PREFIX = "Artemis"

-- --- preferences ------------------------------------------------------------

dt.preferences.register(
  MODULE, "prefix", "string",
  "artemis: tag prefix",
  "Root under which all tags are attached, without the trailing | "
  .. "(empty = " .. DEFAULT_PREFIX .. "). Also used to detect already "
  .. "tagged images, so tags made with an older prefix are not recognized",
  DEFAULT_PREFIX
)

dt.preferences.register(
  MODULE, "scope", "enum",
  "artemis: taxa scope",
  "Which part of the Tree of Life may become tags: all animals, only birds, "
  .. "or every kingdom (also plants, fungi, …)",
  "animals", "animals", "birds", "all"
)

dt.preferences.register(
  MODULE, "tag_style", "enum",
  "artemis: tag style",
  "'separate' attaches two tags per identification: a scientific tree "
  .. "(Scientific|Aves|…|Parus major) and an English tree "
  .. "(English|Birds|…|Great Tit); 'scientific' or 'english' attach only "
  .. "one of them; 'combined' is a scientific tree ending in "
  .. "'Parus major (Great Tit)' without such a branch. English names "
  .. "fall back to the scientific ones where none are known",
  "separate", "separate", "scientific", "english", "combined"
)

dt.preferences.register(
  MODULE, "threshold", "float",
  "artemis: confidence threshold",
  "Minimum probability (0-1) for a taxonomic rank to be tagged; the tagger "
  .. "descends class, order, family, genus, species and stops at the "
  .. "deepest rank still above this value. Below it at class level already, "
  .. "the image gets no tag (probably no animal in it)",
  0.3, 0.0, 1.0, 0.05
)

dt.preferences.register(
  MODULE, "topk", "integer",
  "artemis: max species tags",
  "At most this many species tags per image, for photos with several "
  .. "confidently identified species in frame",
  1, 1, 10
)

dt.preferences.register(
  MODULE, "skip_tagged", "bool",
  "artemis: skip already tagged images",
  "Leave out images that already carry any tag under the configured prefix",
  true
)

-- --- helpers ----------------------------------------------------------------

local function quote(arg)
  return '"' .. tostring(arg):gsub('"', '\\"') .. '"'
end

-- number-to-string that ignores the locale (a Dutch locale would otherwise
-- render 0.3 as "0,3" and break the tagger's argument parsing) and trims
-- float32 noise from preference values
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

-- the configured tag root including the trailing "|", e.g. "Artemis|"
local function tag_prefix()
  local p = dt.preferences.read(MODULE, "prefix", "string") or ""
  p = p:gsub("%s+$", ""):gsub("|+$", "")
  if p == "" then p = DEFAULT_PREFIX end
  return p .. "|"
end

local function has_artemis_tag(image, prefix)
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
    dt.print("artemis: no images selected")
    return
  end

  -- keep only images the run should touch, remembering each by its full path
  local by_path = {}
  local prefix = tag_prefix()
  local skip_tagged = dt.preferences.read(MODULE, "skip_tagged", "bool")
  local paths = {}
  for _, image in ipairs(images) do
    if not (skip_tagged and has_artemis_tag(image, prefix)) then
      local path = image.path .. "/" .. image.filename
      paths[#paths + 1] = path
      by_path[path] = image
    end
  end
  if #paths == 0 then
    dt.print("artemis: all selected images already have " .. prefix .. " tags")
    return
  end

  local tmp = dt.configuration.tmp_dir
  local paths_file = tmp .. "/artemis-paths.txt"
  local json_file = tmp .. "/artemis-tags.json"
  local log_file = tmp .. "/artemis.log"
  local progress_file = tmp .. "/artemis-progress.txt"

  local f = io.open(paths_file, "w")
  if not f then
    dt.print("artemis: cannot write " .. paths_file)
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
    "--topk", fmt_num(dt.preferences.read(MODULE, "topk", "integer")),
    "--scope", dt.preferences.read(MODULE, "scope", "enum"),
    "--tag-style", dt.preferences.read(MODULE, "tag_style", "enum"),
    "--progress", quote(progress_file),
  }, " ") .. " 2> " .. quote(log_file)

  dt.print(string.format("artemis: identifying species in %d image(s)…",
                         #paths))
  dt.print_log("artemis: " .. command)

  -- dt.control.execute yields this coroutine while the tagger runs, so a
  -- dispatched sibling can poll the progress file the tagger overwrites
  -- after every batch and move a progress bar (bottom left). The bar sits
  -- at 0% while the model loads, which dominates the very first run.
  local job = dt.gui.create_job(
    string.format("artemis: identifying species in %d image(s)", #paths), true)
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

  local rc = dt.control.execute(command)
  finished = true
  job.valid = false

  if rc ~= 0 then
    dt.print("artemis: tagger failed (exit " .. rc .. "), see " .. log_file)
    return
  end

  local content = read_file(json_file)
  if not content then
    dt.print("artemis: tagger produced no output, see " .. log_file)
    return
  end
  local ok, results = pcall(json.decode, content)
  if not ok or type(results) ~= "table" then
    dt.print("artemis: cannot parse tagger output: " .. tostring(results))
    return
  end

  local tagged, attached = 0, 0
  for path, entries in pairs(results) do
    local image = by_path[path]
    if image then
      local any = false
      for _, entry in ipairs(entries) do
        local tag = dt.tags.create(prefix .. entry[1])
        dt.tags.attach(tag, image)
        attached = attached + 1
        any = true
      end
      if any then tagged = tagged + 1 end
    end
  end

  dt.print(string.format(
    "artemis: attached %d tag(s) to %d of %d image(s)",
    attached, tagged, #paths))
end

-- --- registration -----------------------------------------------------------

dt.gui.libs.image.register_action(
  MODULE, "artemis: identify species",
  function(_, images) tag_images(images) end,
  "identify animal and bird species with BioCLIP and tag their taxonomy"
)

dt.register_event(
  MODULE, "shortcut",
  function() tag_images(dt.gui.action_images) end,
  "artemis: identify species in selected images"
)

dt.print_log("artemis.lua loaded.")
