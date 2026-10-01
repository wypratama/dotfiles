-- Tiny logging shim. Everything user-visible goes through vim.notify so it obeys
-- the user's notification setup; set OC MINI_DEBUG=1 for a verbose file log.

local M = {}

local levels = vim.log.levels

---@type table<string, integer>
local level_names = {
  trace = levels.TRACE,
  debug = levels.DEBUG,
  info = levels.INFO,
  warn = levels.WARN,
  error = levels.ERROR,
}

local function debug_enabled()
  return vim.env.OCMINI_DEBUG == "1" or vim.env.OCMINI_DEBUG == "true"
end

---@param msg string
---@param level integer
function M.log(msg, level)
  local name = debug_enabled() and "OCmini" or nil
  vim.schedule(function()
    vim.notify(tostring(msg), level, { title = name })
  end)
end

function M.info(msg)
  M.log(msg, levels.INFO)
end

function M.warn(msg)
  M.log(msg, levels.WARN)
end

function M.error(msg)
  M.log(msg, levels.ERROR)
end

---Write to the debug log only (no notification). No-op unless OC MINI_DEBUG=1.
---@param msg string
function M.debug(msg)
  if not debug_enabled() then
    return
  end
  local path = vim.fn.stdpath("state") .. "/ocmini.log"
  local line = string.format("[%s] %s\n", os.date("%H:%M:%S"), msg)
  local fd = io.open(path, "a")
  if fd then
    fd:write(line)
    fd:close()
  end
end

M.levels = level_names

return M
