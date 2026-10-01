-- ocmini in the floating workbench's assistant slot (experiment; used by
-- experiments/floatbench.lua while the workbench is ON).
--
-- ocmini has a native float layout: ui.position = "float" with
-- ui.float = { width, height, row, col, border, gap, zindex }. While the
-- workbench is ON its config is pointed at the right-hand slot's box, so opening
-- the panel (<leader>og, :Opencode, ...) lands straight in the slot: transcript on
-- top, prompt below, each with its own rounded border and a one-row gap.
-- Turning the workbench OFF restores ocmini's own position/float config.
--
-- Note the geometry: ocmini treats width/height as the OUTER size of the whole
-- stack (it adds the borders itself), so the slot box is passed through as-is.

local M = {}

local api = vim.api
local saved = nil -- ocmini's own ui config, restored by restore()

---@return table|nil
local function oc_config()
  local ok, cfg = pcall(require, "ocmini.config")
  return ok and cfg.values and cfg.values.ui or nil
end

---@return table|nil
local function oc_windows()
  local ok, st = pcall(require, "ocmini.state")
  return ok and st.windows or nil
end

---Visible ocmini windows: the transcript and the prompt.
---@return integer[]
function M.windows()
  local w, out = oc_windows(), {}
  if w then
    for _, key in ipairs({ "output_win", "input_win" }) do
      if w[key] and api.nvim_win_is_valid(w[key]) then
        out[#out + 1] = w[key]
      end
    end
  end
  return out
end

---Is ocmini's transcript window open (in this tab)?
function M.visible()
  local w = oc_windows()
  return w ~= nil and w.output_win ~= nil and api.nvim_win_is_valid(w.output_win)
end

---Window to focus when the slot is entered: the prompt if open, else transcript.
function M.focus_win()
  local w = oc_windows()
  for _, key in ipairs({ "input_win", "output_win" }) do
    if w and w[key] and api.nvim_win_is_valid(w[key]) then
      return w[key]
    end
  end
end

---Does `buf` belong to ocmini (prompt or transcript)?
function M.is_oc_buf(buf)
  local ft = vim.bo[buf].filetype
  return ft == "opencode" or ft == "opencode_output"
end

-- ocmini resolves values in (0, 1] as ratios of the screen, so an absolute
-- row/col of exactly 1 would mean "100%"; nudge it past 1 (floored back to 1).
local function abs(v)
  return v == 1 and 1.0001 or v
end

---Point ocmini's float layout at `box` (the slot's outer box) and move
---already-open ocmini windows there.
function M.apply(box)
  local cfg = oc_config()
  if not cfg then
    return
  end
  if not saved then
    saved = {
      position = cfg.position,
      float = vim.deepcopy(cfg.float),
      window_highlight = cfg.window_highlight,
    }
  end
  cfg.position = "float"
  cfg.float = vim.tbl_extend("force", cfg.float or {}, {
    -- transcript and prompt have independent borders with no overlap, so their
    -- bottom and top edges form the visible double divider.
    width = abs(box.w),
    height = abs(box.h),
    row = abs(box.row),
    col = abs(box.col),
    border = "rounded",
    gap = 0,
    zindex = 40,
  })
  cfg.window_highlight = "Normal:FloatbenchPanel,FloatBorder:FloatbenchBorder,FloatTitle:FloatbenchTitle,SignColumn:FloatbenchPanel"

  local w = oc_windows()
  if w then
    w.position = "float" -- a hidden session reopens with its last position
    if M.visible() then
      local show_input = w.input_win ~= nil and api.nvim_win_is_valid(w.input_win)
      pcall(require("ocmini.ui.float_layout").update, w, show_input)
      -- Windows already open were built with ocmini's own winhighlight, so the
      -- workbench's panel groups have to be pushed onto them here.
      for _, key in ipairs({ "output_win", "input_win" }) do
        if w[key] and api.nvim_win_is_valid(w[key]) then
          pcall(api.nvim_win_set_option, w[key], "winhighlight", cfg.window_highlight)
        end
      end
      pcall(require("ocmini.status").update)
    end
  end
end

---Hide ocmini's windows (session keeps running).
function M.hide()
  if M.visible() then
    pcall(function()
      require("ocmini.ui").hide()
    end)
  end
end

---Workbench OFF: hide the slot floats and give ocmini its own config back.
function M.restore()
  M.hide()
  local cfg = oc_config()
  if cfg and saved then
    cfg.position = saved.position
    cfg.float = saved.float
    cfg.window_highlight = saved.window_highlight
    local w = oc_windows()
    if w then
      w.position = saved.position
    end
  end
  saved = nil
end

return M
