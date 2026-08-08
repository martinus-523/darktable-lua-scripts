-- review.lua — walk the faces found by a scan and let a person name them
--
-- Works face by face through the images of the collection currently shown in
-- lighttable. For each face it renders the cached rendering the scan ran
-- against with a box drawn around that face, since the lua API has no way to
-- draw over a widget: the only way to show a picture is button.image, which
-- loads a file from disk at its natural size.

local this_module = ...
local folder = this_module and this_module:match("^(.*[/\\])") or ""

local dt = require "darktable"
local db = require(folder .. "db")
local mipmap = require(folder .. "mipmap")
local scanner = require(folder .. "scan_library")

local M = {}

-- --- CONFIG ----------------------------------------------------------------
-- ImageMagick, used to draw the box and shrink the result to panel size.
local MAGICK_PATH = "/opt/homebrew/bin/magick"

-- Width the preview is scaled to, in pixels. A side panel is around this wide.
local PREVIEW_WIDTH = 360

-- Attached to an image the user stepped over, and to one they never want to see.
M.SKIPPED_TAG = "darktable|faceid|skipped"
M.IGNORE_TAG  = "darktable|faceid|ignore"

M.PEOPLE_PREFIX = scanner.PEOPLE_PREFIX

-- --- small helpers ---------------------------------------------------------
local function shq(s) return "'" .. tostring(s):gsub("'", [['"'"']]) .. "'" end

local function run(cmd)
  local pipe = io.popen(cmd .. " 2>&1")
  if not pipe then return nil, "could not run: " .. cmd end
  local out = pipe:read("*a") or ""
  local ok = pipe:close()
  if not ok then return nil, out ~= "" and out or "command failed" end
  return out
end

local function tag_names(img)
  local names = {}
  for _, t in ipairs(dt.tags.get_tags(img)) do names[#names + 1] = t.name end
  return names
end

local function has(names, wanted)
  for _, name in ipairs(names) do
    if name == wanted then return true end
  end
  return false
end

-- --- preview ---------------------------------------------------------------
-- Draw a box around one face and scale the whole thing down to panel width.
-- The box is drawn after the resize, in output coordinates, so the line keeps
-- the same thickness whatever mipmap level the scan happened to use.
local function render_preview(source, bbox)
  local size, err = run(shq(MAGICK_PATH) .. " identify -format %w " .. shq(source))
  local width = tonumber(size and size:match("%d+"))
  if not width then
    return nil, "could not read " .. source .. ": " .. tostring(err)
  end

  local scale = PREVIEW_WIDTH / width
  local target = dt.configuration.tmp_dir .. "/facial_review.jpg"
  os.remove(target)

  local box = string.format("rectangle %d,%d %d,%d",
                            math.floor((bbox.x1 or 0) * scale), math.floor((bbox.y1 or 0) * scale),
                            math.floor((bbox.x2 or 0) * scale), math.floor((bbox.y2 or 0) * scale))

  local out
  out, err = run(string.format(
    "%s %s -resize %dx -stroke red -strokewidth 2 -fill none -draw %s %s",
    shq(MAGICK_PATH), shq(source), PREVIEW_WIDTH, shq(box), shq(target)))
  if not out then return nil, err end

  return target
end

-- --- state -----------------------------------------------------------------
local state = {
  images = {},   -- images still to review
  i = 0,         -- position in that list
  img = nil,     -- image being reviewed
  faces = {},    -- its faces, from the database
  f = 0,         -- position in that list
  named = false, -- whether any face on this image was named
  tags = nil     -- the tags this module attaches, created once
}

local ui = {}    -- the widgets, filled in by M.build

local function ensure_tags()
  if state.tags then return state.tags end
  state.tags = {
    review     = dt.tags.create(scanner.REVIEW_TAG),
    identified = dt.tags.create(scanner.IDENTIFIED_TAG),
    skipped    = dt.tags.create(M.SKIPPED_TAG),
    ignore     = dt.tags.create(M.IGNORE_TAG)
  }
  return state.tags
end

-- Everything in the collection on screen that is waiting for review, minus
-- anything the user has told us to leave alone.
local function collect()
  local out = {}
  for i = 1, #dt.collection do
    local img = dt.collection[i]
    local names = tag_names(img)
    if has(names, scanner.REVIEW_TAG) and not has(names, M.IGNORE_TAG) then
      out[#out + 1] = img
    end
  end
  return out
end

local function finish(message)
  state.images, state.i, state.img, state.faces, state.f = {}, 0, nil, {}, 0
  ui.status.label = message
  ui.suggestion.label = ""
  ui.preview.label = ""
  ui.name.text = ""
  dt.print(message)
end

local show_face   -- forward declaration, the steps call each other
local next_image

-- Move to the next face of the current image, or on to the next image.
local function next_face()
  state.f = state.f + 1
  if state.f > #state.faces then
    -- Done with this image: it no longer needs review.
    local tags = ensure_tags()
    dt.tags.detach(tags.review, state.img)
    if state.named then dt.tags.attach(tags.identified, state.img) end
    return next_image()
  end
  show_face()
end

next_image = function()
  state.i = state.i + 1
  if state.i > #state.images then
    return finish("facial: review finished.")
  end

  state.img = state.images[state.i]
  state.named = false

  local faces, err = db.get_faces(state.img.id)
  if not faces then
    dt.print_log("[facial] could not read faces for image " .. state.img.id .. ": " .. tostring(err))
    faces = {}
  end
  state.faces = faces
  state.f = 0

  next_face()
end

show_face = function()
  local face = state.faces[state.f]

  ui.status.label = string.format("image %d of %d -- face %d of %d",
                                  state.i, #state.images, state.f, #state.faces)

  if face.name then
    ui.suggestion.label = string.format("suggestion: %s (%d%%)",
                                        face.name, math.floor((face.similarity or 0) * 100 + 0.5))
    ui.name.text = face.name
  else
    ui.suggestion.label = "suggestion: unknown"
    ui.name.text = ""
  end

  -- Show the same rendering the scan ran against, so the stored box lines up.
  local source = mipmap.get_cached_image(state.img)
  if not source then
    ui.preview.label = "no cached rendering"
    return
  end

  local preview, err = render_preview(source, face.bbox or {})
  if preview then
    ui.preview.label = ""
    ui.preview.image = preview
  else
    ui.preview.label = "preview failed"
    dt.print_log("[facial] " .. tostring(err))
  end
end

-- --- actions ---------------------------------------------------------------
-- Name this face: tag the image with the person and teach faceid the face.
local function accept(get_executable)
  local face = state.faces[state.f]
  if not face then return end

  local name = (ui.name.text or ""):match("^%s*(.-)%s*$")
  if name == "" then
    dt.print("facial: type a name first.")
    return
  end

  local exe = get_executable()
  local source = mipmap.get_cached_image(state.img)

  if exe ~= "" and source then
    -- face_index is faceid's own ordering, so this names exactly the face on
    -- screen even when the photo holds several.
    local _, err = run(string.format("%s enroll %s %s --face-index %d",
                                     shq(exe), shq(source), shq(name), face.index or (state.f - 1)))
    if err then
      dt.print("facial: enroll failed, see the log.")
      dt.print_log("[facial] enroll failed for image " .. state.img.id .. ": " .. err)
      return
    end
  end

  dt.tags.attach(dt.tags.create(M.PEOPLE_PREFIX .. name), state.img)
  state.named = true
  next_face()
end

-- Step over this image; it keeps its review tag so it comes back another time.
local function skip()
  if not state.img then return end
  dt.tags.attach(ensure_tags().skipped, state.img)
  next_image()
end

-- Never ask about this image again.
local function ignore()
  if not state.img then return end
  local tags = ensure_tags()
  dt.tags.attach(tags.ignore, state.img)
  dt.tags.detach(tags.review, state.img)
  next_image()
end

-- --- api -------------------------------------------------------------------
function M.start(get_executable)
  if get_executable() == "" then
    dt.print("facial: set the face detection executable first.")
    return
  end

  state.images = collect()
  state.i = 0
  if #state.images == 0 then
    return finish("facial: nothing in this collection needs review.")
  end

  dt.print(string.format("facial: %d image(s) to review.", #state.images))
  next_image()
end

-- The review widgets. Built here rather than in main-ui because every step
-- needs to write to them.
function M.build(functions)
  ui.preview = dt.new_widget("button") {
    label = "",
    tooltip = "the scanned rendering, with a box around the face being named",
    clicked_callback = function() end
  }
  ui.status     = dt.new_widget("label") { label = "" }
  ui.suggestion = dt.new_widget("label") { label = "" }
  ui.name       = dt.new_widget("entry") { text = "", placeholder = "name" }

  local accept_button = dt.new_widget("button") {
    label = "accept",
    tooltip = "tag the image with this name and enroll the face",
    clicked_callback = function() accept(functions.get_executable) end
  }
  local skip_button = dt.new_widget("button") {
    label = "skip",
    tooltip = "leave this image for later",
    clicked_callback = skip
  }
  local ignore_button = dt.new_widget("button") {
    label = "ignore",
    tooltip = "never ask about this image again",
    clicked_callback = ignore
  }

  return dt.new_widget("box") {
    orientation = "vertical",
    ui.preview,
    ui.status,
    ui.suggestion,
    ui.name,
    dt.new_widget("box") {
      orientation = "horizontal", expand = true, fill = true, padding = 0,
      accept_button, skip_button, ignore_button
    }
  }
end

return M
