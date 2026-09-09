-- argus.lua — zero-shot image tagging with SigLIP via darktable.ai
--
-- Scores the selected images against the labels in data/vocabulary.tsv with
-- the argus-siglip model (built by tools/build_model.py, installed through
-- darktable's AI preferences) and attaches the matches as hierarchical tags
-- under Argus| (e.g. Argus|Animals|Dog, Argus|Location|Indoor|Kitchen).
-- Inference runs inside darktable through the darktable.ai Lua API
-- (darktable >= 5.6) — no Python, no external processes.

local dt = require "darktable"

-- vocabulary.tsv lives next to this file; the module name is relative to
-- darktable's lua/ directory, so turn it into an absolute filesystem path
local source = debug.getinfo(1, "S").source:gsub("^@", "")
local script_dir = source:match("^(.*[/\\])") or ""
if script_dir:sub(1, 1) ~= "/" and not script_dir:match("^%a:[/\\]") then
  script_dir = dt.configuration.config_dir .. "/lua/" .. script_dir
end

local MODULE = "argus"
local DEFAULT_PREFIX = "Argus"
local MODEL_ID = "argus-siglip"

-- the model squash-resizes its input to 224x224 internally, but its bicubic
-- resize is NOT antialiased (the ONNX exporter can't emit that op). Loading
-- at a 224px bounding box makes darktable's high-quality export resampler do
-- the antialiased downscale; the in-graph resize then only ever upscales the
-- short axis, where antialiasing doesn't matter
local LOAD_MAX = 224

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
  "At most this many tags from the extra list per image",
  3, 0, 20
)

dt.preferences.register(
  MODULE, "skip_tagged", "bool",
  "argus: skip already tagged images",
  "Leave out images that already carry any tag under the configured prefix",
  true
)

-- --- helpers ----------------------------------------------------------------

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

-- Read vocabulary.tsv in file order: index i here is score index i-1 in
-- the model output, because build_model.py bakes the labels in the same
-- order with the same skip rules (comments, blanks, rows without label
-- or group). Returns a list of { group = ..., path = ... }.
local FALLBACK_BRANCH = { scene = "Location", object = "Objects" }

local function load_vocabulary()
  local path = script_dir .. "data/vocabulary.tsv"
  local f = io.open(path, "r")
  if not f then return nil, "cannot read " .. path end
  local labels = {}
  for line in f:lines() do
    local trimmed = line:gsub("\r$", ""):match("^%s*(.-)%s*$")
    if trimmed ~= "" and trimmed:sub(1, 1) ~= "#" then
      local cols = {}
      for col in (trimmed .. "\t"):gmatch("(.-)\t") do
        cols[#cols + 1] = col:match("^%s*(.-)%s*$")
      end
      local label, group, tagpath = cols[1], cols[2], cols[3]
      if label and label ~= "" and group and group ~= "" then
        if not tagpath or tagpath == "" then
          local branch = FALLBACK_BRANCH[group]
            or (group:sub(1, 1):upper() .. group:sub(2):lower())
          tagpath = branch .. "|" .. label
        end
        labels[#labels + 1] = { group = group, path = tagpath }
      end
    end
  end
  f:close()
  return labels
end

-- Run one image through the model and attach its tags.
-- Returns the number of tags attached.
local function tag_one(ctx, image, labels, prefix, threshold, topk)
  -- darktable delivers the develop-pipeline output as scene-linear RGB;
  -- SigLIP was trained on gamma-encoded images
  local input = dt.ai.load_image(image, LOAD_MAX, LOAD_MAX)
  input:linear_to_srgb()

  local scores = ctx:run(input)
  local n = scores:shape()[2]
  if n ~= #labels then
    error(string.format(
      "model scores %d labels but vocabulary.tsv has %d — rebuild the "
      .. "model with tools/build_model.py", n, #labels))
  end

  -- bucket the scores that clear the threshold by vocabulary group
  local per_group = {}
  for i = 1, n do
    local s = scores:get({0, i - 1})
    if s >= threshold then
      local group = labels[i].group
      per_group[group] = per_group[group] or {}
      local bucket = per_group[group]
      bucket[#bucket + 1] = { score = s, path = labels[i].path }
    end
  end

  local attached = 0
  for group, entries in pairs(per_group) do
    table.sort(entries, function(a, b) return a.score > b.score end)
    local cap = topk[group] or topk.extra
    for k = 1, math.min(cap, #entries) do
      dt.tags.attach(dt.tags.create(prefix .. entries[k].path), image)
      attached = attached + 1
    end
  end
  return attached
end

-- --- main action ------------------------------------------------------------

local function tag_images(images)
  if #images == 0 then
    dt.print("argus: no images selected")
    return
  end
  if not dt.ai then
    dt.print("argus: this darktable has no AI support (needs darktable ≥ 5.6)")
    return
  end

  local labels, err = load_vocabulary()
  if not labels then
    dt.print("argus: " .. err)
    return
  end

  -- keep only images the run should touch
  local prefix = tag_prefix()
  local skip_tagged = dt.preferences.read(MODULE, "skip_tagged", "bool")
  local work = {}
  for _, image in ipairs(images) do
    if not (skip_tagged and has_argus_tag(image, prefix)) then
      work[#work + 1] = image
    end
  end
  if #work == 0 then
    dt.print("argus: all selected images already have " .. prefix .. " tags")
    return
  end

  local ok, ctx = pcall(dt.ai.load_model, MODEL_ID)
  if not ok or not ctx then
    dt.print("argus: cannot load model '" .. MODEL_ID .. "' — build it "
             .. "with tools/build_model.py and install the .dtmodel in "
             .. "preferences → AI (see readme)")
    dt.print_log("argus: load_model: " .. tostring(ctx))
    return
  end

  local threshold = dt.preferences.read(MODULE, "threshold", "float")
  local topk = {
    scene = dt.preferences.read(MODULE, "topk_scene", "integer"),
    object = dt.preferences.read(MODULE, "topk_object", "integer"),
    -- any group beyond scene/object gets the extra cap
    extra = dt.preferences.read(MODULE, "topk_extra", "integer"),
  }

  dt.print(string.format("argus: tagging %d image(s)…", #work))
  local job = dt.gui.create_job(
    string.format("argus: tagging %d image(s)", #work), true,
    function(j) j.valid = false end)

  local tagged, attached, failed = 0, 0, 0
  for i, image in ipairs(work) do
    if not job.valid then break end
    local ran, result = pcall(tag_one, ctx, image, labels, prefix,
                              threshold, topk)
    if ran then
      attached = attached + result
      if result > 0 then tagged = tagged + 1 end
    else
      failed = failed + 1
      dt.print_log(string.format("argus: %s failed: %s",
                                 image.filename, tostring(result)))
    end
    if job.valid then job.percent = i / #work end
  end

  ctx:close()
  job.valid = false

  local msg = string.format(
    "argus: attached %d tag(s) to %d of %d image(s)",
    attached, tagged, #work)
  if failed > 0 then
    msg = msg .. string.format(", %d failed (see log)", failed)
  end
  dt.print(msg)
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
