-- scan_library.lua — deciding which images still need a face scan

local dt = require "darktable"

local M = {}

-- Attached to an image once it has been through a scan.
M.SCANNED_TAG = "darktable.faceid.scanned"

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

-- The preference keys live in facial.lua, so the accessor is handed in rather
-- than reached for from here.
function M.scan_library(get_executable)
  if get_executable() == "" then
    dt.print("facial: set the face detection executable first.")
    return
  end
  local unscanned = M.get_unscanned_images()

  if #unscanned == 0 then
    dt.print("facial: every image has already been scanned.")
    return
  end
  dt.print(string.format("facial: %d image(s) without the '%s' tag.", #unscanned, M.SCANNED_TAG))

  -- TODO: implement the actual scan
end

return M
