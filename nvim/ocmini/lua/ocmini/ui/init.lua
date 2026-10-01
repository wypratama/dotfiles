-- Window lifecycle: the transcript float, the prompt float, and focus handling.

local config = require("ocmini.config")
local float_layout = require("ocmini.ui.float_layout")
local log = require("ocmini.log")
local render = require("ocmini.render")
local state = require("ocmini.state")

local api = vim.api
local panel = require("ocmini.ui.panel")

local M = {}

---@return boolean
function M.visible()
  local w = state.windows.output_win
  return w ~= nil and api.nvim_win_is_valid(w)
end

---Is the prompt window open (as opposed to a hidden session)?
---@return boolean
function M.input_visible()
  local w = state.windows.input_win
  return w ~= nil and api.nvim_win_is_valid(w)
end

---@return integer|nil
function M.focus_win()
  local w = state.windows
  for _, key in ipairs({ "input_win", "output_win" }) do
    if w[key] and api.nvim_win_is_valid(w[key]) then
      return w[key]
    end
  end
  return nil
end

---Create (or reuse) the transcript buffer.
---@return integer bufnr
local function transcript_buf()
  if render.buf and api.nvim_buf_is_valid(render.buf) then
    return render.buf
  end
  local buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_name(buf, "ocmini://transcript")
  vim.bo[buf].filetype = config.values.ui.output_filetype
  render.attach(buf)
  return buf
end

---Open the transcript (and prompt) at the configured geometry.
---@param opts {focus: "input"|"output"|"none", with_input: boolean|nil}?
function M.open(opts)
  opts = opts or {}
  local with_input = opts.with_input ~= false
  local api_geom = float_layout.compute(with_input)

  if M.visible() then
    float_layout.update(state.windows, with_input)
    M.sync_input_visibility(with_input)
    if opts.focus ~= "none" then
      local target = opts.focus == "output" and state.windows.output_win or M.focus_win()
      if target then
        pcall(api.nvim_set_current_win, target)
      end
    end
    return
  end

  local buf = transcript_buf()
  local out_win = panel.open(buf, false, api_geom.output)
  state.windows.output_win = out_win
  state.windows.position = config.values.ui.position
  render.apply_window(out_win)
  pcall(api.nvim_win_set_option, out_win, "winhighlight", config.values.ui.window_highlight)

  if with_input then
    local input = require("ocmini.input")
    state.windows.input_win = input.create(api_geom.input)
  end

  state.opened = true
  require("ocmini.status").update()
  if opts.focus ~= "none" then
    local target = opts.focus == "output" and out_win or M.focus_win()
    if target then
      pcall(api.nvim_set_current_win, target)
    end
  end
end

---Show or hide just the prompt window, keeping the transcript open.
---@param show boolean
function M.sync_input_visibility(show)
  local input = require("ocmini.input")
  if show then
    if not M.input_visible() then
      local geom = float_layout.compute(true)
      state.windows.input_win = input.create(geom.input)
      require("ocmini.status").update()
    end
  elseif M.input_visible() then
    input.close()
  end
end

---Hide the panel without tearing down the session (the session keeps streaming in
---the background, so re-showing it is instant). floatbench calls this when the
---workbench turns off.
function M.hide()
  require("ocmini.input").close()
  M.close_windows()
end

---Close the floats but leave the session and its buffers alive.
function M.close_windows()
  for _, key in ipairs({ "output_win", "input_win" }) do
    local win = state.windows[key]
    if win and api.nvim_win_is_valid(win) then
      pcall(panel.close, win)
    end
    state.windows[key] = nil
  end
end

---Full teardown: windows, event stream, and buffers.
function M.close()
  require("ocmini.events").stop()
  M.close_windows()
  require("ocmini.input").destroy()
  render.buf = nil
  state.opened = false
end

---Toggle the whole panel.
function M.toggle()
  if M.visible() then
    M.hide()
  else
    require("ocmini").open()
  end
end

---Notify about a connection problem in the transcript, if it is open.
---@param msg string
function M.report_error(msg)
  log.error(msg)
  if M.visible() then
    render.render_status("  ✖ " .. msg, "OcminiToolError")
  end
end

return M
