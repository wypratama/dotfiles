-- Empty-editor welcome for the floating workbench (experiments/floatbench.lua):
-- when the workbench opens with no file, the editor float shows the dashboard
-- art (config/art.lua) centered, instead of an empty [No Name] buffer.
--
-- It is a read-only, unlisted scratch buffer, so it has no tab and opening a
-- file (explorer, picker, :e) simply replaces it. While it is shown, the
-- editor window's gutter (numbers, signs, statuscolumn) is hidden; the
-- window's own options come back when another buffer takes its place.

local M = {}

local api = vim.api
local ns = api.nvim_create_namespace("floatbench_welcome")
local BLANK = vim.fn.nr2char(0x2800) -- braille "no dots", the art's padding

local HINTS = "<C-h> explorer    <leader>ff find file    <leader>t terminal    <C-l> claude"

-- Window options hidden while the welcome is shown (restored afterwards).
local GUTTER = {
  number = false,
  relativenumber = false,
  signcolumn = "no",
  foldcolumn = "0",
  statuscolumn = "",
  cursorline = false,
  list = false,
}

local S = { buf = nil, win = nil, saved = nil }

---Art with its blank padding columns cropped, so it fits narrow panels.
---@return string[] lines, integer width
local function cropped_art()
  local rows, first, last = {}, math.huge, 0
  for _, line in ipairs(require("config.art").sleekraken) do
    local chars = vim.fn.split(line, "\\zs")
    rows[#rows + 1] = chars
    for i, c in ipairs(chars) do
      if c ~= BLANK then
        first, last = math.min(first, i), math.max(last, i)
      end
    end
  end
  local out = {}
  for _, chars in ipairs(rows) do
    out[#out + 1] = table.concat(vim.list_slice(chars, first, last))
  end
  return out, math.max(last - first + 1, 0)
end

---Is `buf` an untouched empty [No Name] buffer (nothing worth keeping)?
function M.is_empty(buf)
  return api.nvim_buf_is_valid(buf)
    and vim.bo[buf].buftype == ""
    and api.nvim_buf_get_name(buf) == ""
    and not vim.bo[buf].modified
    and api.nvim_buf_line_count(buf) == 1
    and api.nvim_buf_get_lines(buf, 0, 1, false)[1] == ""
end

local function set_highlights()
  local ok, p = pcall(require, "rose-pine.palette")
  p = ok and type(p) == "table" and p or { iris = "#c4a7e7", muted = "#6e6a86" }
  api.nvim_set_hl(0, "FloatbenchWelcomeArt", { fg = p.iris })
  api.nvim_set_hl(0, "FloatbenchWelcomeHint", { fg = p.muted })
end

local function restore_gutter()
  local win, saved = S.win, S.saved
  S.saved = nil
  if not (saved and win and api.nvim_win_is_valid(win)) then
    return
  end
  if api.nvim_win_get_buf(win) == S.buf then
    return -- still showing the welcome
  end
  for name, value in pairs(saved) do
    pcall(api.nvim_set_option_value, name, value, { win = win, scope = "local" })
  end
end

local function hide_gutter(win)
  if S.saved and S.win == win then
    return
  end
  S.win, S.saved = win, {}
  for name, value in pairs(GUTTER) do
    local opt = { win = win, scope = "local" }
    S.saved[name] = api.nvim_get_option_value(name, opt)
    api.nvim_set_option_value(name, value, opt)
  end
end

---The (reused) welcome buffer.
function M.buf()
  if S.buf and api.nvim_buf_is_valid(S.buf) then
    return S.buf
  end
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].filetype = "floatbench_welcome"
  vim.bo[buf].modifiable = false
  S.buf = buf
  api.nvim_create_autocmd("BufWinLeave", {
    buffer = buf,
    callback = function()
      vim.schedule(restore_gutter)
    end,
    desc = "Floatbench welcome: restore the editor gutter",
  })
  return buf
end

---(Re)draw the welcome centered in `win` if it shows the welcome buffer.
function M.render(win)
  if not (win and api.nvim_win_is_valid(win) and S.buf and api.nvim_win_get_buf(win) == S.buf) then
    return
  end
  set_highlights()
  hide_gutter(win)

  local art, art_w = cropped_art()
  local width = api.nvim_win_get_width(win)
  local height = api.nvim_win_get_height(win) - (vim.wo[win].winbar ~= "" and 1 or 0)
  local hint = vim.fn.strdisplaywidth(HINTS) <= width and HINTS or ""
  local block_h = #art + (hint ~= "" and 2 or 0)

  local lines = {}
  for _ = 1, math.max(math.floor((height - block_h) / 2), 0) do
    lines[#lines + 1] = ""
  end
  local art_row = #lines
  local pad = string.rep(" ", math.max(math.floor((width - art_w) / 2), 0))
  for _, l in ipairs(art) do
    lines[#lines + 1] = pad .. l
  end
  local hint_row
  if hint ~= "" then
    lines[#lines + 1] = ""
    hint_row = #lines
    lines[#lines + 1] = string.rep(" ", math.max(math.floor((width - vim.fn.strdisplaywidth(hint)) / 2), 0)) .. hint
  end

  vim.bo[S.buf].modifiable = true
  api.nvim_buf_set_lines(S.buf, 0, -1, false, lines)
  vim.bo[S.buf].modifiable = false
  vim.bo[S.buf].modified = false

  api.nvim_buf_clear_namespace(S.buf, ns, 0, -1)
  for i = 0, #art - 1 do
    api.nvim_buf_set_extmark(S.buf, ns, art_row + i, 0, { line_hl_group = "FloatbenchWelcomeArt" })
  end
  if hint_row then
    api.nvim_buf_set_extmark(S.buf, ns, hint_row, 0, { line_hl_group = "FloatbenchWelcomeHint" })
  end
  pcall(api.nvim_win_set_cursor, win, { 1, 0 })
end

return M
