-- artemis.lua — animal & bird species identification with BioCLIP 2.5
--
-- Identifies the species in the selected images with the artemis-bioclip
-- model (built by tools/build_model.py, installed through darktable's AI
-- preferences) and attaches the predicted taxonomy as hierarchical tags
-- under Artemis| — by default one scientific and one English tag per
-- identification, e.g. Artemis|Scientific|Aves|Passeriformes|Paridae|Parus
-- major and Artemis|English|Birds|Perching Birds|Tits and Chickadees|Great
-- Tit. The walk only descends the taxonomy as far as it is confident, so an
-- unclear photo may end at order or family level. Images already accepted in
-- the nature review panel (any tag under nature's prefix, Nature| by
-- default) are never scanned. Inference runs inside darktable through the
-- darktable.ai Lua API (darktable >= 5.6) — no Python, no external
-- processes.

local dt = require "darktable"

-- data/taxa.bin and data/rank-names.tsv live next to this file; the module
-- name is relative to darktable's lua/ directory, so turn it into an
-- absolute filesystem path
local source = debug.getinfo(1, "S").source:gsub("^@", "")
local script_dir = source:match("^(.*[/\\])") or ""
if script_dir:sub(1, 1) ~= "/" and not script_dir:match("^%a:[/\\]") then
  script_dir = dt.configuration.config_dir .. "/lua/" .. script_dir
end

local MODULE = "artemis"
local DEFAULT_PREFIX = "Artemis"
local MODEL_ID = "artemis-bioclip"

-- tower.onnx takes a fixed 224x224 crop; the build tool asserts the model's
-- preprocess matches (CLIP: shortest side to 224, then center crop)
local CROP = 224

-- fixed-width record size of data/taxa.bin (kept in sync with
-- tools/build_model.py); one record per TreeOfLife row, sorted by lineage
local RECORD_SIZE = 256

-- taxonomy indices kingdom..species = 0..6; the walk covers class..species
local WALK_RANKS = { 2, 3, 4, 5, 6 }

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
  "Minimum probability (0-1) for a taxonomic rank to be tagged; the walk "
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

-- --- tag helpers ------------------------------------------------------------

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

-- images with tags under nature's root have been accepted in the nature
-- review panel and are never scanned again; nature's prefix is configurable,
-- so read the same preference with the same fallback as nature.lua
local function nature_prefix()
  local p = dt.preferences.read("nature", "prefix", "string") or ""
  p = p:gsub("%s+$", ""):gsub("|+$", "")
  if p == "" then p = "Nature" end
  return p
end

-- true when the image carries the nature root tag itself or anything under it
local function has_nature_tag(image)
  local root = nature_prefix()
  local prefix = root .. "|"
  for _, tag in ipairs(dt.tags.get_tags(image)) do
    if tag.name == root or tag.name:sub(1, #prefix) == prefix then
      return true
    end
  end
  return false
end

-- --- taxonomy data ----------------------------------------------------------

-- data/rank-names.tsv -> { "<rank>|<scientific>" = English }, for the
-- english and separate tag styles; a missing file just means the English
-- tag tree keeps the scientific rank names
local function load_rank_names()
  local names = {}
  local rank_idx = { kingdom = 0, class = 2, order = 3, family = 4 }
  local f = io.open(script_dir .. "data/rank-names.tsv", "r")
  if not f then
    dt.print_log("artemis: no rank-names.tsv; English tags keep "
                 .. "scientific ranks")
    return names
  end
  for line in f:lines() do
    local trimmed = line:gsub("\r$", ""):match("^%s*(.-)%s*$")
    if trimmed ~= "" and trimmed:sub(1, 1) ~= "#" then
      local sci, rank, eng = trimmed:match("^(.-)\t(.-)\t(.*)$")
      sci = sci and sci:match("^%s*(.-)%s*$")
      eng = eng and eng:match("^%s*(.-)%s*$")
      rank = rank and rank_idx[rank:match("^%s*(.-)%s*$")]
      if sci and sci ~= "" and rank and eng and eng ~= "" then
        names[rank .. "|" .. sci] = eng
      end
    end
  end
  f:close()
  return names
end

-- open data/taxa.bin and return a row -> record lookup (cached per run).
-- each record is the 8 pipe-separated fields kingdom..species, common name
local function open_taxa()
  local path = script_dir .. "data/taxa.bin"
  local f = io.open(path, "rb")
  if not f then
    return nil, "cannot read " .. path .. " — run tools/build_model.py"
  end
  local cache = {}
  local function record(row)
    local rec = cache[row]
    if rec then return rec end
    f:seek("set", row * RECORD_SIZE)
    local raw = f:read(RECORD_SIZE)
    if not raw then error("taxa.bin row " .. row .. " out of range — "
                          .. "rebuild model and taxa.bin together") end
    rec = {}
    for field in (raw:match("^[^\0]*") .. "|"):gmatch("(.-)|") do
      rec[#rec + 1] = field
    end
    for i = #rec + 1, 8 do rec[i] = "" end
    cache[row] = rec
    return rec
  end
  return record, nil, f
end

-- --- tag construction (ports tagger.py's lineage/make_tags) -------------------

-- hierarchical tag for a lineage down to WALK_RANKS[depth+1]; the species
-- component is replaced by `leaf`, all other ranks go through `translate`.
-- kingdom is prepended for non-animals so plants and fungi stay
-- recognizable; empty ranks are skipped, and so is the genus level when
-- the species leaf follows it anyway
local function lineage(rec, depth, leaf, translate)
  local parts = {}
  local species_depth = #WALK_RANKS - 1
  if rec[1] ~= "Animalia" then
    local p = translate(0, rec[1])
    if p and p ~= "" then parts[#parts + 1] = p end
  end
  for d = 0, depth do
    local rank = WALK_RANKS[d + 1]
    if not (rank == 5 and depth == species_depth) then
      local part
      if rank == 6 then part = leaf
      else part = translate(rank, rec[rank + 1]) end
      if part and part ~= "" then parts[#parts + 1] = part end
    end
  end
  return table.concat(parts, "|")
end

-- the tag path(s) for one identification, following the configured style:
-- 'separate' (default) emits a scientific and an English tree tag,
-- 'scientific' / 'english' just one of them, 'combined' a scientific tree
-- whose species leaf carries the common name in parentheses
local function make_tags(rec, depth, style, rank_names)
  local species = depth == #WALK_RANKS - 1
  local binomial = (rec[6] .. " " .. rec[7]):match("^%s*(.-)%s*$")
  local common = rec[8]:match("^%s*(.-)%s*$")
  if common ~= "" then
    common = common:sub(1, 1):upper() .. common:sub(2)
  end

  local ident = function(_, name) return name end
  local trans = function(rank, name)
    return rank_names[rank .. "|" .. name] or name
  end

  local paths = {}
  if style == "separate" or style == "scientific" then
    paths[#paths + 1] = "Scientific|"
      .. lineage(rec, depth, species and binomial or nil, ident)
  end
  if style == "combined" then
    local leaf
    if species then
      leaf = common ~= "" and (binomial .. " (" .. common .. ")") or binomial
    end
    paths[#paths + 1] = lineage(rec, depth, leaf, ident)
  end
  if style == "separate" or style == "english" then
    local leaf
    if species then leaf = common ~= "" and common or binomial end
    paths[#paths + 1] = "English|" .. lineage(rec, depth, leaf, trans)
  end
  return paths
end

-- --- hierarchy walk ----------------------------------------------------------

local function in_scope(rec, scope)
  if scope == "birds" then return rec[3] == "Aves" end
  if scope == "animals" then return rec[1] == "Animalia" end
  return true
end

-- Walk class -> species over the scorer's per-rank top-64 group sums and
-- return the tag paths. At each rank the candidates are sorted by
-- probability mass, so the first one that is in scope and nested inside the
-- previous rank's winner is the argmax; the walk stops when it falls below
-- the threshold, and the deepest passing rank becomes the tag. Species-level
-- hits add runner-up species that also clear the threshold (feeder shots
-- with several birds), up to the topk preference.
local function identify(out, record, opts)
  local best
  for d = 0, #WALK_RANKS - 1 do
    local sums = out[3 * d + 1]
    local starts = out[3 * d + 2]
    local ends = out[3 * d + 3]
    local pick
    for i = 0, sums:shape()[2] - 1 do
      local a = math.floor(starts:get({0, i}) + 0.5)
      local b = math.floor(ends:get({0, i}) + 0.5)
      if (not best or (a >= best.start_row and b <= best.end_row))
          and in_scope(record(a), opts.scope) then
        pick = { depth = d, sum = sums:get({0, i}),
                 start_row = a, end_row = b }
        break
      end
    end
    if not pick or pick.sum < opts.threshold then break end
    best = pick
  end
  if not best then return {} end

  local paths = make_tags(record(best.start_row), best.depth,
                          opts.tag_style, opts.rank_names)
  if best.depth == #WALK_RANKS - 1 then
    local sums = out[13]
    local starts = out[14]
    local found = 1
    for i = 0, sums:shape()[2] - 1 do
      if found >= opts.topk then break end
      local s = sums:get({0, i})
      if s < opts.threshold then break end
      local a = math.floor(starts:get({0, i}) + 0.5)
      if a ~= best.start_row and in_scope(record(a), opts.scope) then
        local extra = make_tags(record(a), best.depth,
                                opts.tag_style, opts.rank_names)
        for _, p in ipairs(extra) do paths[#paths + 1] = p end
        found = found + 1
      end
    end
  end
  return paths
end

-- --- main action ------------------------------------------------------------

-- Identify one image: load a CLIP center crop through the develop pipeline,
-- run the two models, walk the taxonomy. Returns the tag paths.
local function identify_one(tower, scorer, image, record, opts)
  -- aspect-preserving load with the SHORT side at 224 (max 0 = that axis
  -- unconstrained), then a center crop — exactly CLIP's preprocessing,
  -- with darktable's high-quality resampler doing the downscale
  local w, h = image.final_width, image.final_height
  if not w or w == 0 then w, h = image.width, image.height end
  local input
  if w >= h then
    input = dt.ai.load_image(image, 0, CROP)
  else
    input = dt.ai.load_image(image, CROP, 0)
  end
  -- the pipeline output is scene-linear; BioCLIP saw gamma-encoded images
  input:linear_to_srgb()

  local ih, iw = input:shape()[3], input:shape()[4]
  if ih < CROP or iw < CROP then
    error(string.format("image too small after export (%dx%d)", iw, ih))
  end
  local crop = input:crop(
    math.floor((ih - CROP) / 2), math.floor((iw - CROP) / 2), CROP, CROP)

  local emb = tower:run(crop)
  local out = { scorer:run(emb) }
  return identify(out, record, opts)
end

local function tag_images(images)
  if #images == 0 then
    dt.print("artemis: no images selected")
    return
  end
  if not dt.ai then
    dt.print("artemis: this darktable has no AI support (needs darktable ≥ 5.6)")
    return
  end

  -- keep only images the run should touch
  local prefix = tag_prefix()
  local skip_tagged = dt.preferences.read(MODULE, "skip_tagged", "bool")
  local work = {}
  for _, image in ipairs(images) do
    if not has_nature_tag(image)
        and not (skip_tagged and has_artemis_tag(image, prefix)) then
      work[#work + 1] = image
    end
  end
  if #work == 0 then
    dt.print("artemis: all selected images are already tagged or accepted")
    return
  end

  local record, err, taxa_file = open_taxa()
  if not record then
    dt.print("artemis: " .. err)
    return
  end

  local ok_t, tower = pcall(dt.ai.load_model, MODEL_ID, nil, "tower.onnx")
  local ok_s, scorer
  if ok_t and tower then
    ok_s, scorer = pcall(dt.ai.load_model, MODEL_ID, nil, "scorer.onnx")
  end
  if not (ok_t and tower and ok_s and scorer) then
    dt.print("artemis: cannot load model '" .. MODEL_ID .. "' — build it "
             .. "with tools/build_model.py and install the .dtmodel in "
             .. "preferences → AI (see readme)")
    dt.print_log("artemis: load_model: "
                 .. tostring(ok_t and (ok_s and scorer or scorer) or tower))
    if ok_t and tower then tower:close() end
    taxa_file:close()
    return
  end

  local opts = {
    threshold = dt.preferences.read(MODULE, "threshold", "float"),
    topk = dt.preferences.read(MODULE, "topk", "integer"),
    scope = dt.preferences.read(MODULE, "scope", "enum"),
    tag_style = dt.preferences.read(MODULE, "tag_style", "enum"),
    rank_names = load_rank_names(),
  }

  dt.print(string.format("artemis: identifying species in %d image(s)…",
                         #work))
  local job = dt.gui.create_job(
    string.format("artemis: identifying species in %d image(s)", #work),
    true, function(j) j.valid = false end)

  local tagged, attached, failed = 0, 0, 0
  for i, image in ipairs(work) do
    if not job.valid then break end
    local ran, result = pcall(identify_one, tower, scorer, image,
                              record, opts)
    if ran then
      for _, path in ipairs(result) do
        dt.tags.attach(dt.tags.create(prefix .. path), image)
        attached = attached + 1
      end
      if #result > 0 then tagged = tagged + 1 end
    else
      failed = failed + 1
      dt.print_log(string.format("artemis: %s failed: %s",
                                 image.filename, tostring(result)))
    end
    if job.valid then job.percent = i / #work end
  end

  tower:close()
  scorer:close()
  taxa_file:close()
  job.valid = false

  local msg = string.format(
    "artemis: attached %d tag(s) to %d of %d image(s)",
    attached, tagged, #work)
  if failed > 0 then
    msg = msg .. string.format(", %d failed (see log)", failed)
  end
  dt.print(msg)
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
