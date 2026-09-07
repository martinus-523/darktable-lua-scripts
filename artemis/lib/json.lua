-- json.lua — minimal JSON decoder for autotag2
--
-- Decodes the tagger's output (objects, arrays, strings, numbers, booleans,
-- null). null becomes nil. No encoder: the Lua side never writes JSON.

local M = {}

local function decode_error(str, pos, msg)
  error(string.format("json: %s at position %d", msg, pos), 0)
end

local escapes = {
  ['"'] = '"', ["\\"] = "\\", ["/"] = "/",
  b = "\b", f = "\f", n = "\n", r = "\r", t = "\t",
}

local decode_value  -- forward declaration

local function skip_whitespace(str, pos)
  local _, last = str:find("^[ \t\r\n]*", pos)
  return last + 1
end

local function decode_string(str, pos)
  local out = {}
  local i = pos + 1  -- past the opening quote
  while true do
    local c = str:sub(i, i)
    if c == "" then
      decode_error(str, i, "unterminated string")
    elseif c == '"' then
      return table.concat(out), i + 1
    elseif c == "\\" then
      local esc = str:sub(i + 1, i + 1)
      if esc == "u" then
        local hex = str:sub(i + 2, i + 5)
        local code = tonumber(hex, 16)
        if not code then decode_error(str, i, "bad unicode escape") end
        -- encode the code point as UTF-8 (surrogate pairs not needed for tags)
        if code < 0x80 then
          out[#out + 1] = string.char(code)
        elseif code < 0x800 then
          out[#out + 1] = string.char(0xC0 + math.floor(code / 0x40),
                                      0x80 + code % 0x40)
        else
          out[#out + 1] = string.char(0xE0 + math.floor(code / 0x1000),
                                      0x80 + math.floor(code / 0x40) % 0x40,
                                      0x80 + code % 0x40)
        end
        i = i + 6
      else
        local ch = escapes[esc]
        if not ch then decode_error(str, i, "bad escape") end
        out[#out + 1] = ch
        i = i + 2
      end
    else
      out[#out + 1] = c
      i = i + 1
    end
  end
end

local function decode_number(str, pos)
  local num_str = str:match("^-?%d+%.?%d*[eE]?[+-]?%d*", pos)
  local num = tonumber(num_str)
  if not num then decode_error(str, pos, "bad number") end
  return num, pos + #num_str
end

local function decode_array(str, pos)
  local arr = {}
  pos = skip_whitespace(str, pos + 1)
  if str:sub(pos, pos) == "]" then return arr, pos + 1 end
  while true do
    local value
    value, pos = decode_value(str, pos)
    arr[#arr + 1] = value
    pos = skip_whitespace(str, pos)
    local c = str:sub(pos, pos)
    if c == "]" then return arr, pos + 1 end
    if c ~= "," then decode_error(str, pos, "expected ',' or ']'") end
    pos = skip_whitespace(str, pos + 1)
  end
end

local function decode_object(str, pos)
  local obj = {}
  pos = skip_whitespace(str, pos + 1)
  if str:sub(pos, pos) == "}" then return obj, pos + 1 end
  while true do
    if str:sub(pos, pos) ~= '"' then
      decode_error(str, pos, "expected string key")
    end
    local key, value
    key, pos = decode_string(str, pos)
    pos = skip_whitespace(str, pos)
    if str:sub(pos, pos) ~= ":" then decode_error(str, pos, "expected ':'") end
    pos = skip_whitespace(str, pos + 1)
    value, pos = decode_value(str, pos)
    obj[key] = value
    pos = skip_whitespace(str, pos)
    local c = str:sub(pos, pos)
    if c == "}" then return obj, pos + 1 end
    if c ~= "," then decode_error(str, pos, "expected ',' or '}'") end
    pos = skip_whitespace(str, pos + 1)
  end
end

decode_value = function(str, pos)
  local c = str:sub(pos, pos)
  if c == '"' then return decode_string(str, pos) end
  if c == "{" then return decode_object(str, pos) end
  if c == "[" then return decode_array(str, pos) end
  if c == "t" and str:sub(pos, pos + 3) == "true" then return true, pos + 4 end
  if c == "f" and str:sub(pos, pos + 4) == "false" then return false, pos + 5 end
  if c == "n" and str:sub(pos, pos + 3) == "null" then return nil, pos + 4 end
  if c == "-" or c:match("%d") then return decode_number(str, pos) end
  decode_error(str, pos, "unexpected character '" .. c .. "'")
end

--- Decode a JSON string. Raises on malformed input; wrap in pcall.
function M.decode(str)
  local value, pos = decode_value(str, skip_whitespace(str, 1))
  pos = skip_whitespace(str, pos)
  if pos <= #str then decode_error(str, pos, "trailing garbage") end
  return value
end

return M
