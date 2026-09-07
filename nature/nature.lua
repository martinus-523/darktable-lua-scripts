-- nature.lua — review companion for artemis
--
-- Adds a "nature" panel to the lighttable that shows the Artemis| tags of
-- the selected image and lets you accept or reject the identification:
-- accept copies each Artemis| tag as a Nature| tag (the Artemis| ones stay,
-- marking the image as reviewed), reject detaches the Artemis| tags. Both
-- buttons are disabled when there is nothing to review — no Artemis| tags,
-- or Nature| tags already present.

local dt = require "darktable"

local MODULE = "nature"
local NATURE_PREFIX = "Nature|"

-- artemis's root is configurable; read the same preference so nature follows
-- it, with the same fallback as artemis.lua
local function artemis_prefix()
  local p = dt.preferences.read("artemis", "prefix", "string") or ""
  p = p:gsub("%s+$", ""):gsub("|+$", "")
  if p == "" then p = "Artemis" end
  return p .. "|"
end

local function starts_with(name, prefix)
  return name:sub(1, #prefix) == prefix
end

-- the image's Artemis| tags, and whether any Nature| tag is present
local function review_state(image)
  local prefix = artemis_prefix()
  local artemis_tags, has_nature = {}, false
  for _, tag in ipairs(dt.tags.get_tags(image)) do
    if starts_with(tag.name, prefix) then
      artemis_tags[#artemis_tags + 1] = tag
    elseif starts_with(tag.name, NATURE_PREFIX) then
      has_nature = true
    end
  end
  return artemis_tags, has_nature
end

-- --- widgets ------------------------------------------------------------

local status_label = dt.new_widget("label") {
  label = "",
  halign = "start",
  ellipsize = "end",
}

local tags_view = dt.new_widget("text_view") {
  text = "",
  editable = false,
}

local accept_button, reject_button -- forward, callbacks need update_panel

-- the image's Artemis| tags if it is up for review (has them, and no
-- Nature| tags yet), nil otherwise
local function reviewable(image)
  local artemis_tags, has_nature = review_state(image)
  if #artemis_tags == 0 or has_nature then return nil end
  return artemis_tags
end

-- the single selected image, or nil
local function selected_image()
  local selection = dt.gui.selection()
  if #selection == 1 then return selection[1] end
  return nil
end

local function update_panel()
  local selection = dt.gui.selection()

  if #selection == 0 then
    status_label.label = "select an image"
    tags_view.text = ""
    accept_button.sensitive = false
    reject_button.sensitive = false
    return
  end

  -- several images: batch accept only; each image is reviewed against its
  -- own tags, so there is nothing meaningful to show in the tag view
  if #selection > 1 then
    local pending = 0
    for _, image in ipairs(selection) do
      if reviewable(image) then pending = pending + 1 end
    end
    status_label.label = string.format(
      "%d images selected, %d to review", #selection, pending)
    tags_view.text = ""
    accept_button.sensitive = pending > 0
    reject_button.sensitive = false
    return
  end

  local image = selection[1]
  local artemis_tags, has_nature = review_state(image)
  local prefix = artemis_prefix()

  -- show each identification with the root stripped, one per line
  local lines = {}
  for _, tag in ipairs(artemis_tags) do
    lines[#lines + 1] = tag.name:sub(#prefix + 1):gsub("|", " › ")
  end
  tags_view.text = table.concat(lines, "\n")

  if #artemis_tags == 0 then
    status_label.label = "no " .. prefix .. " tags on this image"
    accept_button.sensitive = false
    reject_button.sensitive = false
  elseif has_nature then
    status_label.label = "already reviewed (" .. NATURE_PREFIX .. " tags present)"
    accept_button.sensitive = false
    reject_button.sensitive = false
  else
    status_label.label = string.format("%d identification(s) found", #artemis_tags)
    accept_button.sensitive = true
    reject_button.sensitive = true
  end
end

-- accept works on the whole selection; every image only receives copies of
-- its own Artemis| tags, and already reviewed / untagged images are skipped
local function accept()
  local prefix = artemis_prefix()
  local accepted_images, accepted_tags = 0, 0
  for _, image in ipairs(dt.gui.selection()) do
    local artemis_tags = reviewable(image)
    if artemis_tags then
      for _, tag in ipairs(artemis_tags) do
        local nature_tag = dt.tags.create(NATURE_PREFIX .. tag.name:sub(#prefix + 1))
        dt.tags.attach(nature_tag, image)
      end
      accepted_images = accepted_images + 1
      accepted_tags = accepted_tags + #artemis_tags
    end
  end
  dt.print(string.format("nature: accepted %d tag(s) on %d image(s)",
                         accepted_tags, accepted_images))
  update_panel()
end

local function reject()
  local image = selected_image()
  if not image then return end
  local artemis_tags = reviewable(image)
  if not artemis_tags then update_panel() return end

  for _, tag in ipairs(artemis_tags) do
    dt.tags.detach(tag, image)
  end
  dt.print(string.format("nature: rejected %d tag(s)", #artemis_tags))
  update_panel()
end

accept_button = dt.new_widget("button") {
  label = "accept",
  tooltip = "copy the " .. artemis_prefix() .. " tags as " .. NATURE_PREFIX .. " tags",
  sensitive = false,
  clicked_callback = accept,
}

reject_button = dt.new_widget("button") {
  label = "reject",
  tooltip = "remove the " .. artemis_prefix() .. " tags from this image",
  sensitive = false,
  clicked_callback = reject,
}

local main_widget = dt.new_widget("box") {
  orientation = "vertical",
  status_label,
  tags_view,
  dt.new_widget("box") {
    orientation = "horizontal",
    accept_button,
    reject_button,
  },
}

-- --- registration -------------------------------------------------------

dt.register_lib(
  MODULE, "nature", true, false,
  { [dt.gui.views.lighttable] = { "DT_UI_CONTAINER_PANEL_RIGHT_CENTER", 20 } },
  main_widget
)

dt.register_event(MODULE, "selection-changed", update_panel)

pcall(update_panel) -- selection may not be queryable while still loading

dt.print_log("nature.lua loaded.")
