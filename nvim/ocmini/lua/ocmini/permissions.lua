-- Permission prompts.
--
-- `permission.asked` arrives as a live event. Rather than blocking in a modal, we
-- append a highlighted block to the end of the transcript and put y/n/a keymaps on
-- the transcript window, so the question is answered in the same place the work is
-- happening and the transcript stays readable.

local api = require("ocmini.api")
local log = require("ocmini.log")
local render = require("ocmini.render")
local state = require("ocmini.state")

local nvim_api = vim.api

local M = {}

---One-line description of what is being asked for.
---
---A real request carries no `message`: it has `action` ("external_directory")
---and `resources` (a list of glob patterns such as { "/etc/*" }). Anything
---unrecognised falls back to vim.inspect so nothing is silently dropped.
---@param req table Permission.Request
---@return string
local function describe(req)
  local parts = {}
  for _, res in ipairs(req.resources or {}) do
    if type(res) == "string" then
      parts[#parts + 1] = res
    end
  end
  if #parts == 0 then
    return type(req.message) == "string" and req.message or vim.inspect(req.resources or req, { newline = " ", indent = "" })
  end
  return table.concat(parts, ", ")
end

---Answer the open request.
---@param decision "once"|"always"|"reject"
function M.reply(decision)
  local req = state.pending_permission
  if not req then
    return
  end
  local ok, err = api.reply_permission(req.sessionID, req.id, decision, nil)
  if ok then
    state.pending_permission = nil
    local label = decision == "once" and "allowed once" or decision == "always" and "always allowed" or "rejected"
    render.render_status("  ⚠ permission " .. label, decision == "reject" and "OcminiMeta" or "OcminiToolDone")
  else
    log.error("permission reply failed: " .. tostring(err))
    render.render_status("  ✖ permission reply failed: " .. tostring(err), "OcminiToolError")
    return
  end
  M.clear_keymaps()
end

function M.clear_keymaps()
  local win = state.windows.output_win
  if not win or not nvim_api.nvim_win_is_valid(win) then
    return
  end
  for _, lhs in ipairs({ "y", "n", "a" }) do
    pcall(vim.keymap.del, "n", lhs, { buffer = nvim_api.nvim_win_get_buf(win) })
  end
end

---Render the prompt and arm the answer keys.
---@param req table Permission.Request
function M.show(req)
  -- A second request while one is open means the first was never answered; drop it
  -- rather than stacking two conflicting prompts.
  if state.pending_permission then
    log.debug("replacing unanswered permission request")
  end
  state.pending_permission = req

  local width = 60
  local win = state.windows.output_win
  if win and nvim_api.nvim_win_is_valid(win) then
    width = math.max(nvim_api.nvim_win_get_width(win) - 4, 30)
  end

  local body = render.wrap(describe(req), math.max(width - 4, 24))
  local lines = { "  ⚠ permission: " .. tostring(req.action or "request") }
  for _, l in ipairs(body) do
    lines[#lines + 1] = "    " .. l
  end
  vim.list_extend(lines, {
    "    [y] once   [a] always   [n] reject",
    "",
  })
  render.render_block(lines, {
    [0] = "OcminiPermission",
    [1] = "OcminiMeta",
    [2] = "OcminiPermissionKey",
  })

  if win and nvim_api.nvim_win_is_valid(win) then
    local buf = nvim_api.nvim_win_get_buf(win)
    vim.keymap.set("n", "y", function()
      M.reply("once")
    end, { buffer = buf, desc = "ocmini: allow once", nowait = true })
    vim.keymap.set("n", "a", function()
      M.reply("always")
    end, { buffer = buf, desc = "ocmini: always allow", nowait = true })
    vim.keymap.set("n", "n", function()
      M.reply("reject")
    end, { buffer = buf, desc = "ocmini: reject", nowait = true })

    -- The turn is blocked until this is answered, and the answer keys are here,
    -- so take focus. Without this the panel just stalls whenever the user
    -- happens to be typing in the prompt, with no visible way forward.
    if nvim_api.nvim_get_current_win() ~= win then
      pcall(nvim_api.nvim_set_current_win, win)
    end
    pcall(nvim_api.nvim_win_call, win, function()
      vim.cmd("normal! G")
    end)
  end
end

return M
