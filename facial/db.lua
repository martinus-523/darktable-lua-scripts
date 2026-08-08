-- db.lua — stores one row per detected face
--
-- The scanner's json is flattened on the way in: every face becomes its own row,
-- so review can ask for exactly the faces it needs instead of re-parsing a blob.
--
-- The lua API has no sqlite binding, so this drives the sqlite3 command line
-- tool, The store is a database of its own -- darktable's library.db and
--  data.db are never touched -- but it lives in the same folder, which
-- darktable itself tells us via dt.configuration.config_dir

local dt = require "darktable"

local M = {}

-- --- CONFIG ----------------------------------------------------------------
-- Path to the sqlite3 command line tool. /usr/bin/sqlite3 ships with macOS and
-- most Linux distributions. Change if yours lives elsewhere.
local SQLITE_PATH = "/usr/bin/sqlite3"

M.DB_PATH = dt.configuration.config_dir .. "/facial.db"

-- --- small helpers ---------------------------------------------------------
-- Quote for the shell: wrap in single quotes and break out for each embedded one.
local function shq(s) return "'" .. tostring(s):gsub("'", [['"'"']]) .. "'" end

-- Quote for SQL: wrap in single quotes and double each embedded one.
local function sqlq(s) return "'" .. tostring(s):gsub("'", "''") .. "'" end

-- Feed sqlite3 through a file rather than argv: scanner json can be far larger
-- than a command line is allowed to be, and it may contain newlines.
-- Returns the tool's output lines, or nil plus a message.
local function run_sql(sql)
  local script = dt.configuration.tmp_dir .. "/facial_db.sql"
  local f, err = io.open(script, "w")
  if not f then return nil, "could not write " .. script .. ": " .. tostring(err) end
  f:write(sql)
  f:close()

  local pipe = io.popen(shq(SQLITE_PATH) .. " -batch " .. shq(M.DB_PATH) ..
                        " < " .. shq(script) .. " 2>&1")
  if not pipe then
    os.remove(script)
    return nil, "could not run " .. SQLITE_PATH
  end

  local lines = {}
  for line in pipe:lines() do lines[#lines + 1] = line end
  pipe:close()
  os.remove(script)

  -- sqlite3 is silent on success, so anything on a write is an error. Callers
  -- that expect output check the lines themselves.
  return lines
end

-- Created on first use, so merely requiring this module writes nothing.
local schema_ready = false

local function ensure_schema()
  if schema_ready then return true end

  -- 'level' is the mipmap level the scan ran against: the bbox is in that
  -- rendering's pixel space and means nothing without it.
  local lines, err = run_sql([[
    CREATE TABLE IF NOT EXISTS faces (
      imgid      INTEGER NOT NULL,
      face_index INTEGER NOT NULL,
      name       TEXT,
      similarity REAL,
      x1         INTEGER,
      y1         INTEGER,
      x2         INTEGER,
      y2         INTEGER,
      det_score  REAL,
      age        INTEGER,
      sex        TEXT,
      crop       TEXT,
      level      INTEGER,
      scanned_at TEXT NOT NULL,
      PRIMARY KEY (imgid, face_index)
    );
  ]])
  if not lines then return false, err end
  if #lines > 0 then return false, table.concat(lines, "\n") end

  schema_ready = true
  return true
end

-- Null when the value is missing, otherwise the literal.
local function num(v) return v and string.format("%.10g", v) or "NULL" end
local function int(v) return v and string.format("%d", math.floor(v)) or "NULL" end
local function txt(v) return v and sqlq(v) or "NULL" end

-- --- api -------------------------------------------------------------------
-- Replace the stored faces for one image. 'faces' is a list of tables shaped
-- like the scanner's json entries: index, name, similarity, bbox {x1,y1,x2,y2},
-- det_score, age, sex, crop -- every field optional except index.
-- 'level' is the mipmap level the scan ran against.
-- Returns true, or false plus a message.
function M.store_faces(imgid, faces, level)
  if type(imgid) ~= "number" then return false, "imgid must be a number" end
  if type(faces) ~= "table" then return false, "faces must be a table" end
  if level ~= nil and type(level) ~= "number" then return false, "level must be a number" end

  local ok, err = ensure_schema()
  if not ok then return false, err end

  local now = os.date("!%Y-%m-%dT%H:%M:%SZ")

  -- Rescanning an image replaces its faces outright, so a second scan that
  -- finds fewer of them cannot leave stale rows behind.
  local stmts = { "BEGIN;", string.format("DELETE FROM faces WHERE imgid = %d;", imgid) }
  for position, f in ipairs(faces) do
    local bbox = f.bbox or {}
    stmts[#stmts + 1] = string.format(
      "INSERT INTO faces (imgid, face_index, name, similarity, x1, y1, x2, y2, " ..
      "det_score, age, sex, crop, level, scanned_at) " ..
      "VALUES (%d, %d, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s);",
      imgid, f.index or (position - 1), txt(f.name), num(f.similarity),
      int(bbox.x1), int(bbox.y1), int(bbox.x2), int(bbox.y2),
      num(f.det_score), int(f.age), txt(f.sex), txt(f.crop), int(level), sqlq(now))
  end
  stmts[#stmts + 1] = "COMMIT;"

  local lines
  lines, err = run_sql(table.concat(stmts, "\n"))
  if not lines then return false, err end
  if #lines > 0 then return false, table.concat(lines, "\n") end

  return true
end

-- The stored faces for one image, in scanner order. An empty table means the
-- image was scanned and no face was found; nil plus a message means the lookup
-- itself failed.
function M.get_faces(imgid)
  if type(imgid) ~= "number" then return nil, "imgid must be a number" end

  local ok, err = ensure_schema()
  if not ok then return nil, err end

  -- Fields are joined on a tab. Not an ascii control code such as char(31),
  -- however tempting: the sqlite3 command line tool escapes those on the way
  -- out (char(31) arrives as the two characters '^_'), while a tab passes
  -- through untouched. Tabs and newlines inside the text columns are folded to
  -- spaces first, so a value can never split a row or a field.
  local safe = "replace(replace(coalesce(%s, ''), char(9), ' '), char(10), ' ')"
  local lines
  lines, err = run_sql(string.format([[
    SELECT face_index || char(9) || ]] .. safe:format("name") .. [[ || char(9)
        || coalesce(similarity, '') || char(9)
        || coalesce(x1, '') || char(9) || coalesce(y1, '') || char(9)
        || coalesce(x2, '') || char(9) || coalesce(y2, '') || char(9)
        || coalesce(det_score, '') || char(9) || coalesce(age, '') || char(9)
        || ]] .. safe:format("sex") .. [[ || char(9)
        || ]] .. safe:format("crop") .. [[ || char(9)
        || coalesce(level, '')
    FROM faces WHERE imgid = %d ORDER BY face_index;
  ]], imgid))
  if not lines then return nil, err end

  local faces = {}
  for _, line in ipairs(lines) do
    local f = {}
    for field in (line .. "\t"):gmatch("(.-)\t") do f[#f + 1] = field end
    faces[#faces + 1] = {
      index      = tonumber(f[1]),
      name       = f[2] ~= "" and f[2] or nil,
      similarity = tonumber(f[3]),
      bbox       = { x1 = tonumber(f[4]), y1 = tonumber(f[5]),
                     x2 = tonumber(f[6]), y2 = tonumber(f[7]) },
      det_score  = tonumber(f[8]),
      age        = tonumber(f[9]),
      sex        = f[10] ~= "" and f[10] or nil,
      crop       = f[11] ~= "" and f[11] or nil,
      level      = tonumber(f[12])
    }
  end

  return faces
end

return M
