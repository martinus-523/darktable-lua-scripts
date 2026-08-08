-- mipmap.lua — the highest resolution rendering of an image that darktable has
-- already written to its thumbnail cache
--
-- Reading these costs a jpeg decode instead of a raw decode plus a full develop,
-- and they are already the developed image: crop, rotation and all other module
-- settings are baked in. Nothing here touches the original file.
--
-- Layout, from src/common/mipmap_cache.c:
--
--   <cache dir>/mipmaps-<sha1 of the library's real path>.d/<level>/<imgid>.jpg
--
-- The sha1 keeps separate libraries from colliding in one cache folder, so it
-- has to be computed rather than guessed at by globbing.

local dt = require "darktable"

local M = {}

-- darktable knows levels 0..10, biggest last. Levels below 10 are written when
-- 'cache_disk_backend' is on, level 10 only when 'cache_disk_backend_full' is.
M.MAX_LEVEL = 10

-- --- small helpers ---------------------------------------------------------
local function shq(s) return "'" .. tostring(s):gsub("'", [['"'"']]) .. "'" end

local function run(cmd)
  local pipe = io.popen(cmd .. " 2>/dev/null")
  if not pipe then return nil end
  local out = pipe:read("*a") or ""
  pipe:close()
  return out
end

local function file_exists(path)
  local f = io.open(path, "r")
  if f then f:close() return true end
  return false
end

-- --- locating the cache folder ---------------------------------------------
-- Which library darktable has open: darktablerc's 'database' setting, taken
-- relative to the config dir unless it is already absolute.
local function library_path()
  local config = dt.configuration.config_dir
  local db = "library.db"

  local f = io.open(config .. "/darktablerc", "r")
  if f then
    for line in f:lines() do
      local v = line:match("^database=(.*)$")
      if v and v ~= "" then db = v break end
    end
    f:close()
  end

  if db == ":memory:" then return nil end          -- no disk cache at all
  if db:sub(1, 1) ~= "/" then db = config .. "/" .. db end
  return db
end

-- darktable hashes the path after resolving symlinks, so resolve them here too.
local function real_path(path)
  local dir  = path:match("^(.*)/[^/]*$") or "."
  local base = path:match("([^/]+)$")
  local out  = run("cd " .. shq(dir) .. " && pwd -P")
  local real = out and out:match("^%s*(.-)%s*$")
  if real and real ~= "" then return real .. "/" .. base end
  return path
end

local function sha1(text)
  -- whichever of these the system has; the redirect in run() silences the
  -- 'command not found' from the ones it doesn't
  local out = run("printf %s " .. shq(text) ..
                  " | { shasum -a 1 || sha1sum || openssl dgst -sha1 ; }")
  return out and out:match(("%x"):rep(40))
end

local resolved_dir, resolved = nil, false

-- The cache folder for the open library, or nil when it cannot be worked out.
function M.cache_dir()
  if resolved then return resolved_dir end
  resolved = true

  local lib = library_path()
  if not lib then return nil end

  local hash = sha1(real_path(lib))
  if not hash then return nil end

  local dir = dt.configuration.cache_dir .. "/mipmaps-" .. hash .. ".d"
  if not file_exists(dir) then return nil end

  resolved_dir = dir
  return resolved_dir
end

-- --- api -------------------------------------------------------------------
-- The largest cached rendering of an image: its path plus the level it came
-- from, or nil when darktable has not written one yet.
function M.get_cached_image(img)
  local dir = M.cache_dir()
  if not dir then return nil end

  for level = M.MAX_LEVEL, 0, -1 do
    local path = string.format("%s/%d/%d.jpg", dir, level, img.id)
    if file_exists(path) then return path, level end
  end

  return nil
end

return M
