-- db.lua — stores the scanner's json output per image
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

  local lines, err = run_sql([[
    CREATE TABLE IF NOT EXISTS scans (
      imgid      INTEGER PRIMARY KEY,
      json       TEXT NOT NULL,
      scanned_at TEXT NOT NULL
    );
  ]])
  if not lines then return false, err end
  if #lines > 0 then return false, table.concat(lines, "\n") end

  schema_ready = true
  return true
end

-- --- api -------------------------------------------------------------------
-- Store (or replace) the scanner's json for one image.
-- Returns true, or false plus a message.
function M.store(imgid, json)
  if type(imgid) ~= "number" then return false, "imgid must be a number" end
  if type(json) ~= "string" then return false, "json must be a string" end

  local ok, err = ensure_schema()
  if not ok then return false, err end

  local lines
  lines, err = run_sql(string.format(
    "INSERT OR REPLACE INTO scans (imgid, json, scanned_at) VALUES (%d, %s, %s);",
    imgid, sqlq(json), sqlq(os.date("!%Y-%m-%dT%H:%M:%SZ"))))
  if not lines then return false, err end
  if #lines > 0 then return false, table.concat(lines, "\n") end

  return true
end

-- The stored json for one image, or nil when it has not been scanned.
-- Returns nil plus a message when the lookup itself failed.
function M.get(imgid)
  if type(imgid) ~= "number" then return nil, "imgid must be a number" end

  local ok, err = ensure_schema()
  if not ok then return nil, err end

  local lines
  lines, err = run_sql(string.format("SELECT json FROM scans WHERE imgid = %d;", imgid))
  if not lines then return nil, err end
  if #lines == 0 then return nil end

  -- One column of one row, so everything printed is the value; json holding
  -- newlines comes back as several lines and is rejoined here.
  return table.concat(lines, "\n")
end

return M
