-- Event stream and session lifecycle.
--
-- One long-lived SSE subscription feeds the transcript. Events are filtered to the
-- current session (the server is shared per directory, so other sessions' traffic
-- arrives on the same stream) and dispatched to the renderer, the permission
-- prompt, and the streaming flag.

local api = require("ocmini.api")
local config = require("ocmini.config")
local http = require("ocmini.http")
local log = require("ocmini.log")
local permissions = require("ocmini.permissions")
local render = require("ocmini.render")
local server = require("ocmini.server")
local state = require("ocmini.state")

local M = {}

---Sessions are per-directory, so the remembered id is stored per-directory too
---(one JSON object keyed by directory). A single flat file would resume a
---session belonging to some other project.
---@return table<string, string>
local function read_saved_sessions()
  local fd = io.open(config.values.session.state_file, "r")
  if not fd then
    return {}
  end
  local content = fd:read("*all")
  fd:close()
  local ok, data = pcall(vim.json.decode, content or "")
  return ok and type(data) == "table" and data or {}
end

---@return string|nil
local function read_saved_session()
  local id = read_saved_sessions()[vim.fn.getcwd()]
  return type(id) == "string" and id ~= "" and id or nil
end

---@param id string|nil
local function save_session(id)
  local path = config.values.session.state_file
  local all = read_saved_sessions()
  if id then
    all[vim.fn.getcwd()] = id
  else
    all[vim.fn.getcwd()] = nil
  end
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local fd = io.open(path, "w")
  if fd then
    fd:write(vim.json.encode(all))
    fd:close()
  end
end

---Handle one decoded SSE frame.
---@param frame table {id, event, data}
local function hook(name, ...)
  local callback = config.values.hooks[name]
  if callback then local ok, err = pcall(callback, ...); if not ok then log.warn("Hook " .. name .. ": " .. tostring(err)) end end
end

local function dispatch(frame)
  local ev = frame.data
  if type(ev) ~= "table" or type(ev.type) ~= "string" then
    return
  end

  if ev.type == "server.connected" then
    log.debug("event stream connected")
    return
  end

  local payload = ev.data or {}
  vim.api.nvim_exec_autocmds("User", { pattern = "OcminiEvent", modeline = false, data = ev })

  -- Ignore traffic from other sessions in this directory.
  local sid = payload.sessionID or payload.form and payload.form.sessionID
  if sid and state.session_id and sid ~= state.session_id then
    if ev.type == "form.created" or ev.type == "permission.asked" then
      vim.notify("Another OpenCode session needs an answer: " .. sid, vim.log.levels.INFO, { title = "OpenCode" })
    end
    return
  end

  if ev.type == "form.created" then
    require("ocmini.questions").show(payload.form)
    return
  elseif ev.type == "form.replied" or ev.type == "form.cancelled" then
    require("ocmini.questions").settled(payload.id)
    return
  end

  if ev.type == "permission.asked" then
    hook("on_permission_requested", payload)
    permissions.show(payload)
    return
  end
  if ev.type == "permission.replied" then
    if state.pending_permission and payload.requestID == state.pending_permission.id then
      state.pending_permission = nil
      permissions.clear_keymaps()
    end
    return
  end

  if ev.type == "session.execution.started" then
    state.streaming = true
  elseif ev.type == "session.execution.succeeded"
    or ev.type == "session.execution.failed"
    or ev.type == "session.execution.interrupted"
  then
    state.streaming = false
    vim.schedule(function()
      require("ocmini.status").refresh()
      vim.cmd("checktime")
      hook("on_done_thinking", state.session)
    end)
  elseif ev.type == "session.renamed" then
    state.title = payload.title or state.title
    if state.session then state.session.title = state.title end
    require("ocmini.status").update()
  end

  render.on_event({ type = ev.type, data = payload, created = ev.created, id = ev.id })
end

---Open the event stream (idempotent).
function M.start()
  if state.stream_job and state.stream_job > 0 then
    return true
  end
  if not http.has_credentials() then
    return false
  end
  local job
  job = http.stream("/api/event", dispatch, function(stream_state, detail)
    if state.stream_job ~= job then return end
    if stream_state == "error" then
      state.stream_job = nil
      log.debug("event stream: " .. tostring(detail))
    elseif stream_state == "closed" then
      state.stream_job = nil
    end
  end)
  state.stream_job = job
  local active = api.active_session()
  if type(active) == "table" then state.streaming = active[state.session_id] ~= nil end
  require("ocmini.tabs").enter(state.session)
  hook("on_session_loaded", state.session)
  local current_id = state.session_id
  vim.schedule(function()
    if state.session_id ~= current_id then return end
    require("ocmini.questions").refresh()
    local _, form = next(require("ocmini.questions").pending)
    if form then require("ocmini.questions").show(form) end
  end)
  return state.stream_job > 0
end

function M.stop()
  require("ocmini.questions").reset()
  permissions.clear_keymaps()
  state.pending_permission = nil
  if state.stream_job and state.stream_job > 0 then
    pcall(vim.fn.jobstop, state.stream_job)
  end
  state.stream_job = nil
end

---Load a session's history into the transcript.
---@param id string
local function load_history(id)
  local messages = api.messages(id)
  if messages then
    render.render_history(messages)
  else
    render.render_history({})
  end
end

---Reload the current transcript after a command changes session history.
function M.refresh()
  if not state.session_id then
    return
  end
  render.reset()
  load_history(state.session_id)
end

---Resume the session recorded in the state file, if it still exists.
---@return boolean
local function try_resume()
  if not config.values.session.resume then
    return false
  end
  local id = read_saved_session()
  if not id then
    return false
  end
  local session = api.get_session(id)
  if not session then
    log.debug("saved session " .. id .. " is gone; starting a new one")
    save_session(nil)
    return false
  end
  -- A session is bound to the directory it was created in, so resuming one from
  -- a different project would hand the agent a different working tree than the
  -- files the user sees. Treat that as "no saved session".
  local dir = type(session.location) == "table" and session.location.directory or nil
  if dir and vim.fn.fnamemodify(dir, ":p") ~= vim.fn.fnamemodify(vim.fn.getcwd(), ":p") then
    log.debug("saved session " .. id .. " belongs to " .. dir .. "; starting a new one")
    return false
  end
  state.session = session
  state.session_id = session.id
  state.title = session.title
  load_history(session.id)
  log.debug("resumed session " .. session.id)
  return true
end

---Make sure a server, a session, and an event stream all exist.
---@return boolean ok, string|nil error
function M.ensure()
  if state.session_id and state.stream_job then
    return true
  end

  local ok, err = server.ensure()
  if not ok then
    return false, err
  end

  if not try_resume() then
    local session = api.create_session({ title = "neovim" })
    if not session then
      return false, "could not create an opencode session"
    end
    state.session = session
    state.session_id = session.id
    state.title = session.title
    save_session(session.id)
    render.render_history({})
  end

  return M.start()
end

---Switch to a brand new session.
---@return boolean ok, string|nil error
function M.new_session()
  local session = api.create_session({ title = "neovim" })
  if not session then return false, "could not create an opencode session" end
  require("ocmini.tabs").leave()
  M.stop()
  render.reset()
  state.reset_session()
  state.session = session
  state.session_id = session.id
  state.title = session.title
  save_session(session.id)
  render.render_history({})
  return M.start()
end

---Switch to an existing session by id.
---@param id string
---@return boolean ok, string|nil error
function M.switch_session(id)
  local session = api.get_session(id)
  if not session then
    return false, "no such session: " .. tostring(id)
  end
  require("ocmini.tabs").leave()
  M.stop()
  render.reset()
  state.reset_session()
  state.session = session
  state.session_id = session.id
  state.title = session.title
  save_session(session.id)
  load_history(session.id)
  return M.start()
end

return M
