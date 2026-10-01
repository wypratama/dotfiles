-- Float geometry for the transcript and prompt windows.
--
-- Semantics (deliberately self-consistent, and what experiments/floatbench_opencode.lua
-- feeds us after repointing config.ui.float at the workbench's right-hand box):
--
--   width, height : OUTER size of the whole stack, borders included
--   row, col      : OUTER top-left, 0-indexed, relative to "editor"
--   gap           : blank rows between two independent, fully bordered windows.
--
-- A value of 1 or less is read as a fraction of the screen, anything larger as an
-- absolute cell count. That keeps defaults expressible as ratios while letting the
-- workbench hand us exact cell geometry.

local config = require("ocmini.config")

local M = {}

---@param value number
---@param total integer Screen dimension the ratio applies to.
---@param allow_zero boolean? Keep zero as the first screen row/column.
---@return integer
function M.resolve(value, total, allow_zero)
  value = tonumber(value) or 0
  if allow_zero and value == 0 then
    return 0
  end
  if value <= 1 then
    return math.max(math.floor(total * value), 1)
  end
  return math.max(math.floor(value), 1)
end

---How many border rows/cols a border style actually draws.
---@param border integer|string|table
---@param index integer 1-based position in an 8-element border array
---@return integer
local function drawn(border, index)
  if type(border) == "table" then
    return (border[index] ~= "" and border[index] ~= nil) and 1 or 0
  end
  return 1
end

---@param border integer|string|table
---@return integer horizontal edges (left + right)
local function h_edges(border)
  return drawn(border, 2) + drawn(border, 4)
end

---@param border integer|string|table
---@return integer vertical edges (top + bottom)
local function v_edges(border)
  return drawn(border, 1) + drawn(border, 6)
end

---Compute nvim_open_win configs for the stack.
---@param show_input boolean|nil Include the prompt window?
---@return {output: table, input: table|nil}
function M.compute(show_input)
  local f = config.values.ui.float
  local cols, lines = vim.o.columns, vim.o.lines

  local outer_w = M.resolve(f.width, cols)
  local outer_h = M.resolve(f.height, lines)
  local row = M.resolve(f.row, lines, true)
  local col = M.resolve(f.col, cols, true)
  local gap = math.max(math.floor(tonumber(f.gap) or 0), 0)
  local border = f.border or "rounded"
  local zindex = f.zindex or 40

  local he, ve = h_edges(border), v_edges(border)
  local content_w = math.max(outer_w - he, 4)

  local output = {
    relative = "editor",
    row = row,
    col = col,
    width = content_w,
    height = math.max(outer_h - ve, 2),
    border = border,
    focusable = true,
    zindex = zindex,
  }

  if not show_input then
    return { output = output, input = nil }
  end

  -- Reserve a compact, usable editor at the bottom. The previous 50/50 split made
  -- the prompt consume half the assistant panel while only showing one text row.
  -- Keep the transcript and composer as separate rectangles with a clear gap.
  local input_outer_h = math.max(math.floor(tonumber(config.values.input.height) or 9), ve + 2)
  input_outer_h = math.min(input_outer_h, math.max(outer_h - ve - 2, ve + 2))
  local out_outer_h = math.max(outer_h - input_outer_h - gap, ve + 2)
  local in_top = row + out_outer_h + gap
  local in_outer_h = input_outer_h

  return {
    output = {
      relative = "editor",
      row = row,
      col = col,
      width = content_w,
      height = math.max(out_outer_h - ve, 2),
      border = border,
      focusable = true,
      zindex = zindex,
    },
    input = {
      relative = "editor",
      row = in_top,
      col = col,
      width = content_w,
      height = math.max(in_outer_h - ve, 1),
      border = border,
      title = " Enter send · Shift-Enter newline ",
      title_pos = "left",
      focusable = true,
      zindex = zindex,
    },
  }
end

---Reposition already-open windows. experiments/floatbench_opencode.lua calls this
---after rewriting config.ui.float, so it must work on existing window ids and
---tolerate either window being absent.
---@param windows OcminiWindows
---@param show_input boolean|nil
function M.update(windows, show_input)
  if not windows then
    return
  end
  local api = vim.api
  local geom = M.compute(show_input)

  if windows.output_win and api.nvim_win_is_valid(windows.output_win) then
    pcall(require("ocmini.ui.panel").update, windows.output_win, geom.output)
    require("ocmini.render").apply_window(windows.output_win)
  end
  if windows.input_win and api.nvim_win_is_valid(windows.input_win) then
    if geom.input then
      pcall(require("ocmini.ui.panel").update, windows.input_win, geom.input)
      require("ocmini.input").apply_window(windows.input_win)
    else
      pcall(require("ocmini.ui.panel").close, windows.input_win)
      windows.input_win = nil
    end
  end
  require("ocmini.status").update()
end

return M
