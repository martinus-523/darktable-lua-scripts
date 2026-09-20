--[[
  gpx_import.lua - geotag imported images from GPX tracks in the same folder

  On every import darktable fires "post-import-image" for each image. This
  script looks for *.gpx files in the image's folder and, for images that
  have no GPS position yet, asks exiftool to interpolate latitude, longitude
  and altitude from those tracks at the image's capture time. The result is
  stored in darktable (library + XMP sidecar); the image file itself is not
  modified.

  The timezone of the capture time is taken from the image's EXIF
  OffsetTimeOriginal (or OffsetTime) field. When the camera did not write
  one, the preference below is used.

  Preferences (lua options tab):
    timezone offset  - offset of the camera clock, e.g. "+02:00", used only
                       for images without an EXIF offset. Empty means the
                       local timezone of this machine (exiftool default).
    exiftool path    - location of the exiftool binary.
]]

local dt = require "darktable"

local MODULE = "gpx_import"
local TMP    = "/tmp/gpx_import"
local CACHE_TTL = 30   -- seconds before a folder is rescanned for gpx files

dt.preferences.register(MODULE, "tz_offset", "string",
  "gpx import: camera timezone offset",
  "offset of the camera clock from UTC, e.g. +02:00 or Z, used only for images whose EXIF has no OffsetTimeOriginal. Leave empty to use the local timezone of this computer",
  "")
dt.preferences.register(MODULE, "exiftool", "string",
  "gpx import: path to exiftool",
  "full path of the exiftool binary",
  "/opt/homebrew/bin/exiftool")

local function q(s) return "'" .. s:gsub("'", "'\\''") .. "'" end

local function run(cmd)
  local p = io.popen("( " .. cmd .. " ) 2>/dev/null")
  if not p then return {} end
  local lines = {}
  for l in p:lines() do lines[#lines + 1] = l end
  p:close()
  return lines
end

-- folder -> { time = os.time(), files = {...}, done = n, skipped = n }
local cache = {}

local function gpx_files(folder)
  local c = cache[folder]
  if c and os.time() - c.time < CACHE_TTL then return c end
  c = { time = os.time(), done = 0, skipped = 0 }
  c.files = run("find " .. q(folder) .. " -maxdepth 1 -type f -iname '*.gpx'")
  cache[folder] = c
  return c
end

local function valid_tz(tz)
  tz = (tz or ""):gsub("%s", "")
  if tz:upper() == "Z" then return "Z" end
  if tz:match("^[+-]%d%d:%d%d$") then return tz end
  return nil
end

-- timezone suffix for the capture time: EXIF offset of the file, else the
-- preference, else "" (exiftool then uses the local timezone)
local function tz_suffix(exiftool, file)
  local out = run(q(exiftool) .. " -s3 -f -OffsetTimeOriginal -OffsetTime " .. q(file))
  local tz = valid_tz(out[1]) or valid_tz(out[2])
  if tz then return tz, "exif" end
  local pref = dt.preferences.read(MODULE, "tz_offset", "string") or ""
  tz = valid_tz(pref)
  if tz then return tz, "preference" end
  if pref:gsub("%s", "") ~= "" then
    dt.print_log(MODULE .. ": ignoring invalid timezone offset '" .. pref .. "'")
  end
  return "", "local"
end

local function lookup(exiftool, gpx, geotime, id)
  os.execute("mkdir -p " .. q(TMP))
  local xmp = TMP .. "/" .. id .. ".xmp"
  os.remove(xmp)
  local cmd = q(exiftool) .. " -q -q"
  for _, g in ipairs(gpx) do cmd = cmd .. " -geotag " .. q(g) end
  cmd = cmd .. " -geotime=" .. q(geotime) .. " -o " .. q(xmp)
      .. " && " .. q(exiftool) .. " -n -s3 -GPSLatitude -GPSLongitude -GPSAltitude -GPSAltitudeRef " .. q(xmp)
  local out = run(cmd)
  os.remove(xmp)
  local lat, lon = tonumber(out[1]), tonumber(out[2])
  if not lat or not lon then return nil end
  local ele = tonumber(out[3])
  if ele and tonumber(out[4]) == 1 then ele = -ele end
  return lat, lon, ele
end

dt.register_event(MODULE, "post-import-image",
  function(event, image)
    if image.latitude and image.longitude then return end
    local folder = image.path
    local c = gpx_files(folder)
    if #c.files == 0 then
      dt.print_log(MODULE .. ": no gpx files in " .. folder)
      return
    end
    if c.done + c.skipped == 0 then
      dt.print(string.format("gpx import: %d gpx file(s) found in %s", #c.files, folder:match("[^/]+$") or folder))
    end

    local taken = (image.exif_datetime_taken or ""):match("^(%d%d%d%d:%d%d:%d%d %d%d:%d%d:%d%d)")
    if not taken then
      dt.print_log(MODULE .. ": no capture time for " .. image.filename)
      return
    end

    local exiftool = dt.preferences.read(MODULE, "exiftool", "string")
    local f = io.open(exiftool, "r")
    if not f then
      dt.print("gpx import: exiftool not found at " .. exiftool)
      return
    end
    f:close()
    local tz, tz_source = tz_suffix(exiftool, folder .. "/" .. image.filename)
    local lat, lon, ele = lookup(exiftool, c.files, taken .. tz, image.id)
    if not lat then
      c.skipped = c.skipped + 1
      dt.print_log(MODULE .. ": no track position for " .. image.filename .. " at " .. taken .. tz .. " (timezone from " .. tz_source .. ")")
      dt.print(string.format("gpx import: %d geotagged, %d outside track (%s)",
        c.done, c.skipped, folder:match("[^/]+$") or folder))
      return
    end

    image.latitude  = lat
    image.longitude = lon
    if ele then image.elevation = ele end
    c.done = c.done + 1
    dt.print_log(string.format("%s: %s -> %.6f, %.6f", MODULE, image.filename, lat, lon))
    dt.print(string.format("gpx import: %d geotagged, %d outside track (%s)",
      c.done, c.skipped, folder:match("[^/]+$") or folder))
  end)
