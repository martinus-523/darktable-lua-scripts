local dt = require "darktable"

local EXIFTOOL = "/opt/homebrew/bin/exiftool"   -- /usr/local/bin on Intel
local DNGC = "/Applications/Adobe DNG Converter.app/Contents/MacOS/Adobe DNG Converter"
local TMP  = "/tmp/dngc"

local function q(s) return "'" .. s:gsub("'", "'\\''") .. "'" end

local function is_apple(path)
  local p = io.popen(EXIFTOOL .. " -s3 -Make " .. q(path))
  local make = p:read("*l") or ""
  p:close()
  return make:match("Apple") ~= nil
end

dt.register_event("iphone_dng_inplace", "pre-import",
  function(event, images)
    os.execute("mkdir -p " .. q(TMP))
    for _, path in ipairs(images) do
      if path:lower():match("%.dng$") and is_apple(path) then
        local name = path:match("[^/]+$")
        local tmp  = TMP .. "/" .. name
        local rc = dt.control.execute(
          q(DNGC) .. " -c -p1 -d " .. q(TMP) .. " -o " .. q(name) .. " " .. q(path))
        local f = io.open(tmp, "rb")
        if rc == 0 and f then
          f:close()
          os.execute("mv -f " .. q(tmp) .. " " .. q(path))
        else
          dt.print("DNG conversion failed: " .. name)
        end
      end
    end
  end)