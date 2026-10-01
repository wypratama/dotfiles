-- A bordered background with a narrower text window gives real, symmetric
-- padding. Neovim's sign/formatting options do not reserve a right text gutter.
local api = vim.api
local M = {}
local panels = {}

local function content_config(geom)
  local border = geom.border or "rounded"
  local top, left = 1, 1
  if border == "none" or border == "" then
    top, left = 0, 0
  elseif type(border) == "table" then
    top = border[2] and border[2] ~= "" and 1 or 0
    left = border[8] and border[8] ~= "" and 1 or 0
  end
  return {
    relative = geom.relative or "editor",
    row = geom.row + top,
    col = geom.col + left + 1,
    width = math.max(geom.width - 2, 1),
    height = geom.height,
    border = "none",
    style = "minimal",
    focusable = geom.focusable ~= false,
    zindex = (geom.zindex or 40) + 1,
  }
end

local function frame_options(win)
  local wo = vim.wo[win]
  wo.number = false
  wo.relativenumber = false
  wo.signcolumn = "no"
  wo.foldcolumn = "0"
  wo.statuscolumn = ""
  wo.winbar = ""
  wo.cursorline = false
  wo.colorcolumn = ""
  wo.winhighlight = require("ocmini.config").values.ui.window_highlight .. ",EndOfBuffer:Normal"
end

function M.open(buf, enter, geom)
  local background = api.nvim_create_buf(false, true)
  vim.bo[background].bufhidden = "wipe"
  local frame_geom = vim.tbl_extend("force", geom, { focusable = false, style = "minimal" })
  local frame = api.nvim_open_win(background, false, frame_geom)
  frame_options(frame)
  local win = api.nvim_open_win(buf, enter, content_config(geom))
  panels[win] = { frame = frame, geom = vim.deepcopy(geom) }
  api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(win),
    once = true,
    callback = function()
      panels[win] = nil
      if api.nvim_win_is_valid(frame) then
        api.nvim_win_close(frame, true)
      end
    end,
  })
  return win
end

function M.update(win, geom)
  local panel = panels[win]
  if not panel then
    return api.nvim_win_set_config(win, geom)
  end
  panel.geom = vim.deepcopy(geom)
  api.nvim_win_set_config(panel.frame, vim.tbl_extend("force", geom, { focusable = false }))
  frame_options(panel.frame)
  api.nvim_win_set_config(win, content_config(geom))
end

function M.set_title(win, title)
  local panel = panels[win]
  local frame = panel and panel.frame or win
  api.nvim_win_set_config(frame, { title = title, title_pos = "left" })
end

function M.set_footer(win, text)
  local panel = panels[win]
  if not panel then return end
  local width = panel.geom.width
  while vim.fn.strdisplaywidth(text) > width and #text > 0 do text = vim.fn.strcharpart(text, 0, vim.fn.strchars(text)-1) end
  api.nvim_win_set_config(panel.frame, { footer = text, footer_pos = "left" })
end

function M.close(win)
  local panel = panels[win]
  panels[win] = nil
  if api.nvim_win_is_valid(win) then
    api.nvim_win_close(win, true)
  end
  if panel and api.nvim_win_is_valid(panel.frame) then
    api.nvim_win_close(panel.frame, true)
  end
end

return M
