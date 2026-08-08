-- facial.lua — lighttable module with a "scan library" and a "review" action
--
-- The path to the external executable is stored as a darktable preference
-- (settings > lua options > facial), so it survives restarts.

local dt = require "darktable"

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

-- --- actions ---------------------------------------------------------------
local function scan_library()
  if get_executable() == "" then
    dt.print("facial: set the face detection executable in settings > lua options.")
    return
  end
  -- TODO: implement
  dt.print("facial: scan library not implemented yet.")
end

local function review()
  -- TODO: implement
  dt.print("facial: review not implemented yet.")
end

-- --- UI assembly & registration --------------------------------------------
local scan_button = dt.new_widget("button") {
  label = "scan library",
  clicked_callback = scan_library
}

local review_button = dt.new_widget("button") {
  label = "review",
  clicked_callback = review
}

-- A horizontal box gives each child an equal share of the width (expand + fill),
-- and 'padding' is the space GTK puts on both sides of every child -- so the two
-- buttons each take 50% and sit 2 * padding apart.
local ui = dt.new_widget("box") {
  orientation = "horizontal",
  expand = true,
  fill = true,
  padding = 2,
  scan_button,
  review_button
}

dt.register_lib(
  MODULE, "facial", true, false,
  { [dt.gui.views.lighttable] = { "DT_UI_CONTAINER_PANEL_RIGHT_CENTER", 100 } },
  ui, nil, nil
)

dt.print_log("facial.lua loaded.")
