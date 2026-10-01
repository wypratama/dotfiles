-- ocmini: a small Neovim client for the opencode CLI.
--
-- It talks to `opencode serve` over plain HTTP on loopback, subscribes to the
-- server-sent event stream, and renders the conversation into a pair of floats
-- (transcript + prompt) that can also be slotted into the right-hand column of
-- experiments/floatbench.lua.
--
-- Public surface used by experiments/floatbench_opencode.lua:
--   ocmini.open / toggle / close / hide
--   ocmini.state.windows
--   ocmini.ui.float_layout.update
--   ocmini.config.values.ui.{position, float, window_highlight}

local config = require("ocmini.config")
local log = require("ocmini.log")

local M = {}

---@type table<string, vim.api.keyset.highlight>
local highlights = {
  OcminiUserHeader = { link = "DiagnosticOk", default = true },
  OcminiMeta = { link = "Comment", default = true },
  OcminiToolRunning = { link = "DiagnosticInfo", default = true },
  OcminiToolDone = { link = "DiagnosticOk", default = true },
  OcminiToolError = { link = "DiagnosticError", default = true },
  OcminiPermission = { link = "DiagnosticWarn", default = true },
  OcminiPermissionKey = { link = "DiagnosticWarn", default = true },
}

local function apply_highlights()
  for group, spec in pairs(highlights) do
    vim.api.nvim_set_hl(0, group, spec)
  end
end

---@param opts table? User options from setup().
---
---Safe to call more than once: a later call re-applies the options. (Earlier
---this returned early on a second call, which silently dropped user opts —
---lazy.nvim's spec `config` runs setup() when the plugin is first required, so
---any setup() in the user's own config came second and was ignored.)
function M.setup(opts)
  config.setup(opts)
  apply_highlights()
  require("ocmini.context").setup()

  -- Do not leave a private `opencode serve` behind. Re-created with
  -- clear = true, so calling setup() twice does not stack autocommands.
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = vim.api.nvim_create_augroup("ocmini", { clear = true }),
    desc = "Shut down the private opencode server",
    callback = function()
      pcall(function()
        require("ocmini.ui").close()
      end)
      if config.values.server.kill_on_exit then
        pcall(function()
          require("ocmini.server").stop()
        end)
      end
    end,
  })
end

---Open the panel, connecting if necessary.
---@param opts {focus: "input"|"output"|"none", with_input: boolean|nil}?
function M.open(opts)
  M.setup()
  opts = opts or {}
  local ui = require("ocmini.ui")
  ui.open(opts)

  -- Connect off the critical path so the floats paint immediately.
  vim.schedule(function()
    local events = require("ocmini.events")
    local state = require("ocmini.state")
    local render = require("ocmini.render")

    if state.session_id and state.stream_job then
      render.scroll_to_end()
      if opts.focus ~= "output" then
        require("ocmini.input").focus()
      end
      return
    end

    render.render_status("  … connecting to opencode", "OcminiMeta")
    local ok, err = events.ensure()
    if not ok then
      ui.report_error(err or "could not connect to opencode")
      return
    end
    render.scroll_to_end()
    if opts.focus ~= "output" then
      require("ocmini.input").focus()
    end
  end)
end

---Toggle the panel.
function M.toggle()
  local ui = require("ocmini.ui")
  if ui.visible() then
    M.hide()
  else
    M.open()
  end
end

---Hide the floats but keep the session streaming.
function M.hide()
  require("ocmini.ui").hide()
end

---Tear everything down.
function M.close()
  require("ocmini.ui").close()
end

---Focus the prompt window, opening the panel if needed.
function M.input()
  local ui = require("ocmini.ui")
  if not ui.visible() then
    M.open({ focus = "input" })
    return
  end
  ui.sync_input_visibility(true)
  require("ocmini.input").focus()
end

---Focus the transcript window, opening the panel if needed.
function M.output()
  local ui = require("ocmini.ui")
  if not ui.visible() then
    M.open({ focus = "output" })
    return
  end
  ui.sync_input_visibility(false)
  local win = require("ocmini.state").windows.output_win
  if win then
    pcall(vim.api.nvim_set_current_win, win)
  end
end

---@return string
function M.status()
  local state = require("ocmini.state")
  if not state.session_id then
    return "no session"
  end
  local bits = { state.session_id }
  if state.title and state.title ~= "" then
    bits[#bits + 1] = state.title
  end
  if state.streaming then
    bits[#bits + 1] = "streaming"
  end
  if state.pending_permission then
    bits[#bits + 1] = "permission pending"
  end
  return table.concat(bits, " · ")
end

M.log = log

return M
