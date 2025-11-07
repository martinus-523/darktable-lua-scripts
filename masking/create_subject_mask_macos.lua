-- create_subject_mask.lua — macOS version

local dt = require "darktable"
local df = require "lib/dtutils.file"

-- --- CONFIG (set your absolute paths) --------------------------------------
local REMBG_PATH  = "/opt/homebrew/bin/backgroundremover"
local GMIC_PATH = "/opt/homebrew/bin/gmic"
local DCRAW_PATH = "/opt/homebrew/bin/dcraw_emu"
local RASTER_MASK_OUTPUT_FOLDER = "~/Documents/DarkTable/Raster Masks"

-- backgroundremover is based on python and has issues running without the proper paths
local ENV = "PATH=/opt/homebrew/bin:$PATH DYLD_LIBRARY_PATH=/opt/homebrew/lib "

-- --- UI --------------------------------------------------------------------
local keep_png = dt.new_widget("check_button") { label = " Keep intermediate PNG", value = false }
local status    = dt.new_widget("label") { label = "" }
local model     = "u2net_human_seg"

-- --- small helpers ---------------------------------------------------------
local function join(a,b) return (a:sub(-1) == "/" and a..b) or (a.."/"..b) end
local function base(name) return name:match("^(.*)%.") or name end
local function q(s) return "'" .. tostring(s):gsub("'", [['"'"']]) .. "'" end

local function ok(cmd)
  local r, how, code = os.execute(cmd)
  if type(r) == "number" then return r == 0 end
  if r == true then return (how == nil or how == "exit") and (code == nil or code == 0) end
  return false
end

local function exec(cmd, succes, error)
  dt.print_log(cmd)
  if not ok(cmd) then
      dt.print_log(error)
      return 13
  end
  dt.print_log(succes)
  return 7
end

-- --- simple availability checks -------------------------------------------
local function have_rembg()  return ok(ENV .. REMBG_PATH  .. " -h >/dev/null 2>&1") end
local function have_gmic() return ok(GMIC_PATH .. " -version >/dev/null 2>&1") end
local function have_dcraw() return ok(DCRAW_PATH .. " -v >/dev/null 2>&1") end

-- --- main processing methods -----------------------------------------------

local function extract_jpeg(img, in_path, tmp_jpeg)

  -- to prevent issues with dcraw overview a file in the library copy the file to a tmp location
  local ext = img.filename:match("%.[^%.]+$") or ""
  local tmp_raw = os.tmpname() .. ext
  local tmp_tiff = tmp_raw .. ".tiff"
  df.file_copy(in_path, tmp_raw)

  -- unfortunately, image magick give tons of issues. so dcraw must be used. however dcraw generates tiffs 
  -- while the background remover needs a jpeg file. so also ffmpeg is needed to make convert the tiff file to jpg
  local raw_to_tiff = DCRAW_PATH .. " -w -T " .. tmp_raw
  local tiff = exec(raw_to_tiff , "converting raw file to tiff: " .. img.filename, "conversion to jpg failed: " .. img.filename)

  -- the raw file is not needed anymore 
  os.remove(tmp_raw)

  -- if the tiff conversion failed, return 
  if tiff == 13 then return 13 end

  local tiff_to_jpg = GMIC_PATH .. " " .. tmp_tiff .. " -o " .. tmp_jpeg .. ",quality=95"
  local result exec(tiff_to_jpg , "converting raw file to tiff: " .. img.filename, "conversion to jpg failed: " .. img.filename)
  
  -- also the tiff is not longer needed  
  os.remove(tmp_tiff)

  return result
end

-- this method will take the tmp_jpeg removes the background and writes it to the tmp_png file
local function remove_background(img, tmp_jpeg, tmp_png, method)
  -- currently only backgroundremover on mac is supported
  dt.print_log("removing background using model " .. model .. " : " .. img.filename)
  local rmb_cmd = ENV .. q(REMBG_PATH) .. " -i " .. q(tmp_jpeg) .. " -o " .. q(tmp_png) .. " -m " .. model .. " -a -ae 1"

  -- execute and return the result
  return exec(rmb_cmd, "Intermediate PNG created: " .. tmp_png, "removing background failed: " .. img.filename)
end

local function create_mask(img, tmp_png, mask_dest)

  -- the image with the remove background it self is not mask, use gmic to create a mask
  dt.print_log("creating raster mask: " .. img.filename)
  
  local tmp_mask = os.tmpname() .. ".pfm"
  local gmic_cmd = GMIC_PATH .. " " .. tmp_png .. " -to_gray -negate -threshold 99% -negate -erode_circ 1 -blur 0.5 -o pfm:" .. tmp_mask
  
  -- execute and return the result
  local result = exec(gmic_cmd, "PFM mask created: " .. mask_dest, "creating mask failed: " .. img.filename)
  if result == 13 then return 13 end

  df.file_copy(tmp_mask, mask_dest)
  os.remove(tmp_mask)

  return result
end

-- update the status information
local function update_status(ok_count, fail_count)
  local summary = string.format("Running. %d succeeded, %d failed.", ok_count, fail_count)
  status.label = summary
  dt.print(summary)
end

-- --- main action -----------------------------------------------------------
local function create_subject_mask()
  local images = dt.gui.selection()

  -- Check if the requirements are met: there should have been images select and all the cli tools should be available
  if #images == 0 then dt.print("Select one or more images."); status.label = "No selection."; return end
  if not have_gmic() then local m="gmic not found: "..GMIC_PATH; dt.print(m); status.label=m; return end
  if not have_rembg() then local m="backgrond remover not found: " .. REMBG_PATH; dt.print(m); status.label=m; return end
  
  local ok_count, fail_count = 0, 0
  local count = 0

  -- Inform that the process is started
  status.label = "Process started.."

  for _, img in ipairs(images) do
    local in_path  = join(img.path, img.filename)
    local stem     = base(img.filename)
    local tmp_png  = os.tmpname() .. "_remove_background.png"
    local intermediate_png  = join(img.path, stem .. "_bg_removed.png")
    local out_pfm  = join(RASTER_MASK_OUTPUT_FOLDER, stem .. "_" .. model .. ".pfm")
    local tmp_jpeg = os.tmpname() .. ".jpg"

    -- 1) Create a jpeg version from the raw image. This is required since the background remove can't deal with raw images
    local dt_jpeg = extract_jpeg(img, in_path, tmp_jpeg)
    if dt_jpeg == 13 then
      fail_count = fail_count + 1
      update_status(ok_count, fail_count)
      goto continue
    end

    -- 2) Use some ai tools to remove the background..
    local rem_bg = remove_background(img, tmp_jpeg, tmp_png, "bg_rem_mac")
    if rem_bg == 13 then
      fail_count = fail_count + 1
      update_status(ok_count, fail_count)
      goto continue
    end

    -- 3) check if the user want to keep the png
    if keep_png then
      df.file_copy(tmp_png, intermediate_png)
    end

    -- 3) use image gmic to create a pfm file out of the png with the removed background
    local pfm = create_mask(img, tmp_png, out_pfm)
    if pfm == 13 then
      fail_count = fail_count + 1
      update_status(ok_count, fail_count)
      goto continue
    end

 
    ok_count = ok_count + 1
    update_status(ok_count, fail_count)
    ::continue::
  end

  local summary = string.format("Done. %d succeeded, %d failed.", ok_count, fail_count)
  status.label = summary
  dt.print(summary)
end

------------------------------------------------------------------------------
-- Main UI components, buttons, model dropdown etc.
------------------------------------------------------------------------------

-- a button to start the proces
local button = dt.new_widget("button"){
  label = "Create subject mask",
  tooltip = "Use a external AI tool to generate subject mask",
  clicked_callback = create_subject_mask
}

-- dropdown with all the models for segmentation that are available
local dropdown = dt.new_widget("combobox"){
  label  = "Model",  
  tooltip = "Choose a model",
  value = 1,
  tooltip = "Choose an item",
  changed_callback = function(self)
    model = self.value
    dt.print_log("model selected: " .. self.value)
  end,
  "u2net_human_seg", "u2net", "u2netp"
}

-- box that contains all the ui elements
local ui = dt.new_widget("box"){
  orientation = "vertical",
  dropdown,
  keep_png,
  button,
  dt.new_widget("separator"){},
  status
}

------------------------------------------------------------------------------
-- Registration of the masking 
------------------------------------------------------------------------------

dt.register_lib(
  "masking", "masking", true, false,
  { [dt.gui.views.darkroom] = {"DT_UI_CONTAINER_PANEL_RIGHT_CENTER", 100} },
  ui, nil, nil
)

dt.print_log("create_subject_mask.lua loaded.")