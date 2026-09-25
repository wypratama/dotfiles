-- opencode.nvim in the floating workbench's Claude slot (experiment; used by
-- experiments/floatbench.lua while the workbench is ON).
--
-- opencode.nvim (v2) has a native float layout: ui.position = "float" with
-- ui.float = { width, height, row, col, border, gap, zindex }. While the
-- workbench is ON its config is pointed at the Claude slot's box, so opening
-- opencode (<leader>og, :Opencode, ...) lands straight in the slot: output on
-- top, input below (their borders share one divider line via gap = 1).
-- Turning the workbench OFF restores opencode's own position/float config.

local M = {}

local api = vim.api
local saved = nil -- opencode's own ui config, restored by restore()

local function oc_config()
  local ok, cfg = pcall(require, "opencode.config")
  return ok and cfg.ui and cfg or nil
end

local function oc_windows()
  local ok, st = pcall(require, "opencode.state")
  return ok and st.windows or nil
end

---Visible opencode windows (output, input and its footer/tab strip floats).
---@return integer[]
function M.windows()
  local w, out = oc_windows(), {}
  if w then
    for _, key in ipairs({ "output_win", "input_win", "footer_win", "tab_strip_win" }) do
      if w[key] and api.nvim_win_is_valid(w[key]) then
        out[#out + 1] = w[key]
      end
    end
  end
  return out
end

---Is opencode's output window open (in this tab)?
function M.visible()
  local w = oc_windows()
  return w ~= nil and w.output_win ~= nil and api.nvim_win_is_valid(w.output_win)
end

---Window to focus when the slot is entered: the prompt if open, else output.
function M.focus_win()
  local w = oc_windows()
  for _, key in ipairs({ "input_win", "output_win" }) do
    if w and w[key] and api.nvim_win_is_valid(w[key]) then
      return w[key]
    end
  end
end

---Does `buf` belong to opencode (prompt or conversation)?
function M.is_oc_buf(buf)
  local ft = vim.bo[buf].filetype
  return ft == "opencode" or ft == "opencode_output"
end

-- opencode resolves values in (0, 1] as ratios of the screen, so an absolute
-- row/col of exactly 1 would mean "100%"; nudge it past 1 (floored back to 1).
local function abs(v)
  return v == 1 and 1.0001 or v
end

---Point opencode's float layout at `box` (the Claude slot's outer box) and
---move already-open opencode windows there.
function M.apply(box)
  local cfg = oc_config()
  if not cfg then
    return
  end
  if not saved then
    saved = {
      position = cfg.ui.position,
      float = vim.deepcopy(cfg.ui.float),
      window_highlight = cfg.ui.window_highlight,
    }
  end
  cfg.ui.position = "float"
  cfg.ui.float = vim.tbl_extend("force", cfg.ui.float or {}, {
    -- stacked output + input fill the box; gap = 1 overlaps the input's top
    -- border with the output's bottom one (a shared divider)
    width = abs(box.w - 2),
    height = abs(box.h - 2),
    row = abs(box.row),
    col = abs(box.col),
    border = "rounded",
    gap = 1,
    zindex = 40,
  })
  cfg.ui.window_highlight = "Normal:FloatbenchPanel,FloatBorder:FloatbenchBorder,FloatTitle:FloatbenchTitle"

  local w = oc_windows()
  if w then
    w.position = "float" -- a hidden session reopens with its last position
    if M.visible() then
      local show_input = w.input_win ~= nil and api.nvim_win_is_valid(w.input_win)
      pcall(require("opencode.ui.float_layout").update, w, show_input)
      pcall(api.nvim_win_set_config, w.output_win, { title = " opencode ", title_pos = "left" })
    end
  end
end

---Hide opencode's windows (session keeps running).
function M.hide()
  if M.visible() then
    pcall(function()
      require("opencode.api").hide()
    end)
  end
end

---Workbench OFF: hide the slot floats and give opencode its own config back.
function M.restore()
  M.hide()
  local cfg = oc_config()
  if cfg and saved then
    cfg.ui.position = saved.position
    cfg.ui.float = saved.float
    cfg.ui.window_highlight = saved.window_highlight
    local w = oc_windows()
    if w then
      w.position = saved.position
    end
  end
  saved = nil
end

return M
