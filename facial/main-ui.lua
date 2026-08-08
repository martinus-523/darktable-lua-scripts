-- main-ui.lua — the widgets for the facial module
--
-- Everything is built inside M.ui(), because a darktable widget can only ever
-- have one parent: widgets created at file scope would be bound the first time
-- M.ui() is called and error on any later call.

local dt = require "darktable"

local M = {}

-- this method creates the buttons
local function get_buttons(scan_library, review)
    return dt.new_widget("box") {
        orientation = "horizontal",
        expand = true,
        fill = true,
        padding = 0,
        dt.new_widget("button") { label = "scan library", clicked_callback = scan_library },
        dt.new_widget("button") { label = "review", clicked_callback = review }
    }
end

-- Writes straight through to the preference, so both ways of setting the path
-- end up in the same place.
local function get_exe_chooser(functions)
    return dt.new_widget("file_chooser_button") {
        title = "select the face detection executable",
        value = functions.get_executable(),
        is_directory = false,
        changed_callback = function(w)
            functions.set_executable(w.value)
        end
    }
end

-- The lua API has no expander, so a stack whose first page is an empty box acts
-- as the collapsed state; with v_size_fixed off it takes no height there.
local function get_settings_stack(exe_chooser)
    local stack = dt.new_widget("stack") {
        v_size_fixed = false,
        dt.new_widget("box") { orientation = "vertical" },
        exe_chooser
    }
    -- set after construction: 'active' only means something once the pages exist
    stack.active = 1
    return stack
end

local function get_settings_button(settings_stack, exe_chooser, get_executable)
    -- kept here rather than read back from the stack: reading 'active' returns
    -- the visible child widget, not the index that was written to it
    local open = false
    -- declared first so the callback can refer to the button it lives on
    local settings_button
    settings_button = dt.new_widget("button") {
        label = "settings",
        tooltip = "set the face detection executable",
        clicked_callback = function()
            open = not open
            settings_stack.active = open and 2 or 1
            settings_button.label = open and "hide settings" or "settings"
            -- Pick up an edit made in darktable's preferences dialog meanwhile.
            if open then exe_chooser.value = get_executable() end
        end
    }
    return settings_button
end

-- And create the main ui for darktable
function M.ui(functions)
    local exe_chooser = get_exe_chooser(functions)
    local settings_stack = get_settings_stack(exe_chooser)

    return dt.new_widget("box") {
        orientation = "vertical",
        get_buttons(functions.scan_library, functions.review),
        get_settings_button(settings_stack, exe_chooser, functions.get_executable),
        settings_stack,
        functions.review_widget
    }
end

return M
