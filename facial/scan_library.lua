-- scan_library.lua — deciding which images still need a face scan, and running it
--
-- Shells out to the faceid tool, so the quoting here is POSIX; macOS and linux
-- only, like the rest of this repo.

local this_module = ...
local folder = this_module and this_module:match("^(.*[/\\])") or ""

local dt = require "darktable"
local db = require(folder .. "db")
local mipmap = require(folder .. "mipmap")

local M = {}

-- Attached to an image once it has been through a scan.
M.SCANNED_TAG = "darktable|faceid|scanned"

-- Attached once a face on the image has been enrolled under a known name.
M.IDENTIFIED_TAG = "darktable|faceid|identified"

-- Attached when the image still needs a human to say who is on it.
M.REVIEW_TAG = "darktable|faceid|review"

-- darktable's hierarchical separator is '|', so a person is tagged People|Alice.
M.PEOPLE_PREFIX = "People|"

-- Every image in the library that does not carry the scanned tag.
function M.get_unscanned_images()
    local scanned = {}                         -- imgid -> true

    local tag = dt.tags.find(M.SCANNED_TAG)
    if tag then
        -- #tag is the number of tagged images and tag[i] the i-th one. Walking
        -- the tag is far cheaper than asking every image in the library for its
        -- full tag list, which is a query per image either way.
        for i = 1, #tag do
            local img = tag[i]
            if img then scanned[img.id] = true end
        end
    end

    local unscanned = {}
    for i = 1, #dt.database do
        local img = dt.database[i]
        if not scanned[img.id] then
            unscanned[#unscanned + 1] = img
        end
    end

    return unscanned
end

-- --- running the scanner ----------------------------------------------------
local function shq(s) return "'" .. tostring(s):gsub("'", [['"'"']]) .. "'" end

local function image_path(img) return img.path .. "/" .. img.filename end

-- Run a command and return its stdout, or nil plus whatever it put on stderr.
-- stderr is kept out of stdout so it can never end up inside the json.
local function run(cmd)
  local errfile = dt.configuration.tmp_dir .. "/facial_stderr.txt"

  local pipe = io.popen(cmd .. " 2>" .. shq(errfile))
  if not pipe then
    return nil, "could not run: " .. cmd
  end
  local out = pipe:read("*a") or ""
  local ok, _, code = pipe:close()

  local stderr = ""
  local f = io.open(errfile, "r")
  if f then stderr = f:read("*a") or "" ; f:close() end
  os.remove(errfile)

  if not ok then
    if stderr == "" then stderr = "exited with status " .. tostring(code) end
    return nil, stderr
  end
  return out
end

local function tag_names(img)
  local names = {}
  for _, t in ipairs(dt.tags.get_tags(img)) do names[#names + 1] = t.name end
  return names
end

-- The people already named on an image, from its People|... tags. A deeper
-- hierarchy such as People|Family|Alice names the person in its last segment.
local function people_on(names)
  local people = {}
  for _, name in ipairs(names) do
    if name:sub(1, #M.PEOPLE_PREFIX) == M.PEOPLE_PREFIX then
      local person = name:match("([^|]+)$")
      if person and person ~= "" then people[#people + 1] = person end
    end
  end
  return people
end

local function has(names, wanted)
  for _, name in ipairs(names) do
    if name == wanted then return true end
  end
  return false
end

-- Flatten faceid's json into one table per face. The producer is known and its
-- face objects are flat, so matching them out beats dragging in a json library:
-- "faces" is the only array of objects, and %b{} walks them one at a time.
-- A json null simply fails to match, which leaves the field nil.
local function parse_faces(json)
  local faces = {}

  local array = json:match('"faces"%s*:%s*(%b[])')
  if not array then return faces end

  for obj in array:gmatch("%b{}") do
    local face = {
      index      = tonumber(obj:match('"index"%s*:%s*(%-?%d+)')),
      name       = obj:match('"name"%s*:%s*"(.-)"'),
      similarity = tonumber(obj:match('"similarity"%s*:%s*([%-%+%d%.eE]+)')),
      det_score  = tonumber(obj:match('"det_score"%s*:%s*([%-%+%d%.eE]+)')),
      age        = tonumber(obj:match('"age"%s*:%s*(%-?%d+)')),
      sex        = obj:match('"sex"%s*:%s*"(.-)"'),
      crop       = obj:match('"crop"%s*:%s*"(.-)"')
    }

    local bbox = obj:match('"bbox"%s*:%s*%[(.-)%]')
    if bbox then
      local n = {}
      for v in bbox:gmatch("%-?%d+") do n[#n + 1] = tonumber(v) end
      face.bbox = { x1 = n[1], y1 = n[2], x2 = n[3], y2 = n[4] }
    end

    faces[#faces + 1] = face
  end

  return faces
end

-- One image: identify, store, tag, and enroll a face whose name we already know.
local function scan_image(exe, img, tags, stats)
  local original = image_path(img)          -- only ever used in messages
  local names = tag_names(img)

  -- Everything is read from darktable's cached rendering, never from the file
  -- on disk. An image without one is left alone rather than falling back to the
  -- original, so it is picked up again once darktable has drawn its thumbnail.
  local path, level = mipmap.get_cached_image(img)
  if not path then
    dt.print_log("[facial] no cached rendering yet for " .. original .. ", skipped")
    stats.uncached = stats.uncached + 1
    return
  end

  local json, err = run(shq(exe) .. " identify " .. shq(path))
  if not json or not json:match("^%s*{") then
    dt.print_log(string.format("[facial] identify failed for %s (cache level %d): %s",
                               original, level, err or json or "no output"))
    stats.failed = stats.failed + 1
    return
  end

  local faces = parse_faces(json)

  local stored, store_err = db.store_faces(img.id, faces, level)
  if not stored then
    dt.print_log(string.format("[facial] could not store %s: %s", original, tostring(store_err)))
    stats.failed = stats.failed + 1
    return
  end

  dt.tags.attach(tags.scanned, img)
  stats.scanned = stats.scanned + 1

  -- Enroll only when there is no doubt about which face belongs to the name:
  -- one person tagged, one face detected. faceid itself refuses to guess on a
  -- group photo, and a wrong enrollment quietly poisons every later match.
  local people = people_on(names)
  local identified = has(names, M.IDENTIFIED_TAG)

  if #people == 1 and #faces == 1 then
    local _, enroll_err = run(shq(exe) .. " enroll " .. shq(path) .. " " .. shq(people[1]))
    if enroll_err then
      dt.print_log(string.format("[facial] enroll failed for %s as '%s': %s",
                                 original, people[1], enroll_err))
    else
      dt.tags.attach(tags.identified, img)
      identified = true
      stats.enrolled = stats.enrolled + 1
    end
  elseif #people > 0 then
    dt.print_log(string.format("[facial] %s: %d person tag(s) and %d face(s), too ambiguous to enroll",
                               original, #people, #faces))
  end

  if not identified then
    dt.tags.attach(tags.review, img)
    stats.review = stats.review + 1
  end
end

-- The preference keys live in facial.lua, so the accessor is handed in rather
-- than reached for from here.
function M.scan_library(get_executable)
  local exe = get_executable()
  if exe == "" then
    dt.print("facial: set the face detection executable first.")
    return
  end
  local unscanned = M.get_unscanned_images()

  if #unscanned == 0 then
    dt.print("facial: every image has already been scanned.")
    return
  end
  dt.print(string.format("facial: %d image(s) without the '%s' tag.", #unscanned, M.SCANNED_TAG))

  local tags = {
    scanned    = dt.tags.create(M.SCANNED_TAG),
    identified = dt.tags.create(M.IDENTIFIED_TAG),
    review     = dt.tags.create(M.REVIEW_TAG)
  }

  -- The third argument is what makes the job cancellable; the callback fires on
  -- darktable's side, so it only sets a flag the loop checks.
  local cancelled = false
  local job = dt.gui.create_job("facial: scanning library", true,
                                function() cancelled = true end)

  local stats = { scanned = 0, enrolled = 0, review = 0, failed = 0, uncached = 0 }

  for i, img in ipairs(unscanned) do
    if cancelled then break end
    scan_image(exe, img, tags, stats)
    if job.valid then job.percent = i / #unscanned end
  end

  if job.valid then job.valid = false end

  local summary = string.format(
    "facial: scanned %d of %d image(s) -- %d enrolled, %d to review, %d failed, %d not cached yet%s",
    stats.scanned, #unscanned, stats.enrolled, stats.review, stats.failed, stats.uncached,
    cancelled and " (cancelled)" or "")
  dt.print(summary)
  dt.print_log("[facial] " .. summary)
end

return M
