-- facial.lua — lighttable module with a "scan library" and a "review" action
-- import all required modules
local this_module = ...
local folder = this_module and this_module:match("^(.*[/\\])") or ""

local dt = require "darktable"
local main = require(folder .. "main-ui")
local scanner = require(folder .. "scan_library")

-- --- CONFIG ----------------------------------------------------------------
local MODULE   = "facial"          -- preference namespace / lib name
local PREF_EXE = "executable_path" -- preference holding the tool's location

-- --- preference -------------------------------------------------------------
dt.preferences.register(
  MODULE, PREF_EXE, "file",
  "facial: face detection executable",
  "Path to the external program that performs the face detection",
  ""
)

local function get_executable()
  return dt.preferences.read(MODULE, PREF_EXE, "file") or ""
end

local function set_executable(path)
  dt.preferences.write(MODULE, PREF_EXE, "file", path or "")
end

-- --- actions ---------------------------------------------------------------


local function review()
  -- TODO: implement
  dt.print("facial: review not implemented yet.")
end

-- --- UI assembly & registration --------------------------------------------

local functions = {
  -- wrapped so the button's own widget argument is dropped and the executable
  -- accessor is passed through instead
  scan_library = function() scanner.scan_library(get_executable) end,
  review = review,
  get_executable = get_executable,
  set_executable = set_executable
}

dt.register_lib(
  MODULE, "facial", true, false,
  { [dt.gui.views.lighttable] = { "DT_UI_CONTAINER_PANEL_RIGHT_CENTER", 100 } },
  main.ui(functions), nil, nil
)

dt.print_log("facial.lua loaded.")