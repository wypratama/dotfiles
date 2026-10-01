-- Endpoint wrappers for the opencode v2 HTTP API.
--
-- Every response is wrapped by the server as {"data": ...}, so unwrap() is
-- applied consistently and callers work with the payload directly.

local http = require("ocmini.http")
local log = require("ocmini.log")

local M = {}

---@param body table|nil
---@return table|nil
local function unwrap(body)
  if type(body) == "table" and body.data ~= nil then
    return body.data
  end
  return body
end

---@generic T
---@param res table|nil
---@param err string|nil
---@param ctx string
---@return T|nil
local function checked(res, err, ctx)
  if err then
    log.error(ctx .. ": " .. err)
    return nil
  end
  return unwrap(res)
end

-- server ---------------------------------------------------------------------

---@return table|nil info
function M.info()
  local res, err = http.get("/api/info")
  return checked(res, err, "server info")
end

-- sessions -------------------------------------------------------------------

---@param opts {limit: integer?, order: string?, search: string?}?
---@return table[]|nil sessions
function M.list_sessions(opts)
  local res, err = http.get("/api/session", opts)
  local data = checked(res, err, "list sessions")
  if type(data) == "table" and data.list then
    return data.list
  end
  return data
end

---@return table|nil session
function M.active_session()
  local res, err = http.get("/api/session/active")
  if err then
    return nil
  end
  return unwrap(res)
end

---@param opts {title: string?, agent: string?, model: table?}?
---@return table|nil session
function M.create_session(opts)
  opts = opts or {}
  local body = { location = { directory = vim.fn.getcwd() } }
  if opts.title then
    body.title = opts.title
  end
  if opts.agent then
    body.agent = opts.agent
  end
  if opts.model then
    body.model = opts.model
  end
  local res, err = http.post("/api/session", body)
  return checked(res, err, "create session")
end

---@param id string
---@return table|nil session
function M.get_session(id)
  local res, err = http.get("/api/session/" .. id)
  return checked(res, err, "get session")
end

---@param id string
function M.delete_session(id)
  local _, err = http.delete("/api/session/" .. id)
  return err == nil, err
end

-- messages -------------------------------------------------------------------

---List a session's messages, oldest first.
---
---Request ascending pages so history, timelines and whole-session diffs include
---older turns beyond the server's default newest-message page.
---@param session_id string
---@return table[]|nil messages
function M.messages(session_id, opts)
  opts = opts or {}
  local messages, seen, cursor = {}, {}, nil
  repeat
    local res, err = http.get("/api/session/" .. session_id .. "/message", {
      limit = opts.recent and 20 or 100,
      order = not cursor and (opts.recent and "desc" or "asc") or nil,
      cursor = cursor,
    })
    if err then log.error("list messages: " .. err); return nil end
    local page = res
    if type(page) == "table" and type(page.data) == "table" and page.data.cursor then page = page.data end
    local data = unwrap(page)
    if type(data) ~= "table" then return nil end
    for _, message in ipairs(data) do messages[#messages + 1] = message end
    cursor = type(page.cursor) == "table" and page.cursor.next or nil
    if cursor == vim.NIL then cursor = nil end
    if cursor and seen[cursor] then log.error("message pagination returned a repeated cursor"); return nil end
    if cursor then seen[cursor] = true end
  until not cursor or opts.recent
  if opts.recent then
    local ordered = {}
    for index = #messages, 1, -1 do ordered[#ordered + 1] = messages[index] end
    return ordered
  end
  return messages
end

---Send a prompt. `files` is a list of {uri = "file:///abs/path", name = string?}.
---@param session_id string
---@param text string
---@param opts {files: table[]?, agents: table[]?}?
---@return boolean ok, string|nil error
function M.prompt(session_id, text, opts)
  opts = opts or {}
  local body = { text = text }
  if opts.files and #opts.files > 0 then
    body.files = opts.files
  end
  if opts.agents and #opts.agents > 0 then
    body.agents = opts.agents
  end
  local res, err = http.post("/api/session/" .. session_id .. "/prompt", body)
  if err then
    return false, err
  end
  return true, nil
end

---@return table[]|nil commands
function M.commands()
  if not http.has_credentials() then
    return {}
  end
  local res, err = http.get("/api/command")
  local data = checked(res, err, "list commands")
  if type(data) == "table" and data.list then
    return data.list
  end
  return type(data) == "table" and data or nil
end

---@param session_id string
---@param command string
---@param arguments string
---@param callback fun(ok: boolean, err: string|nil)
function M.command(session_id, command, arguments, callback, opts)
  opts = opts or {}
  http.post_async("/api/session/" .. session_id .. "/command", {
    name = command,
    text = arguments,
    files = opts.files,
    agents = opts.agents,
  }, function(res, err)
    if err then
      callback(false, err)
      return
    end
    callback(true, nil)
  end)
end

---@param session_id string
---@return boolean ok, string|nil error
function M.undo(session_id)
  local messages = M.messages(session_id) or {}
  local message_id
  for i = #messages, 1, -1 do
    local info = messages[i].info or messages[i]
    if info.type == "user" or info.role == "user" then
      message_id = info.id
      break
    end
  end
  if not message_id then
    return false, "there is no user turn to undo"
  end
  local res, err = http.post("/api/session/" .. session_id .. "/revert/stage", { messageID = message_id, files = true })
  if err then
    return false, err
  end
  return true
end

---@param session_id string
---@return boolean ok, string|nil error
function M.redo(session_id)
  local _, err = http.delete("/api/session/" .. session_id .. "/revert")
  if err then
    return false, err
  end
  return true
end

---@param session_id string
---@return boolean ok, string|nil error
function M.interrupt(session_id)
  local _, err = http.post("/api/session/" .. session_id .. "/interrupt", {})
  if err then
    return false, err
  end
  return true
end

-- agents and models ----------------------------------------------------------

---Agents and models, located at `directory` (default: the cwd).
---
---The location matters: the server scopes these lists to a project, and without
---one it answers with an empty list rather than an error. The query is
---`location[directory]`, which is how the v2 API spells a structured object
---parameter over a query string (matching opencode.nvim's query_string()).
---
---There is also a warm-up quirk: the first call for a directory can come back
---empty while the server is still loading that project's agents, and a second
---call moments later returns them. So an empty result is retried once.
---@param path string
---@param ctx string
---@return table[]|nil
local function located_list(path, ctx)
  local query = "location%5Bdirectory%5D=" .. vim.uri_encode(vim.fn.getcwd())
  local latest
  for attempt = 1, 2 do
    local res, err = http.get(path .. "?" .. query)
    local data = checked(res, err, ctx)
    if type(data) == "table" and data.list then
      data = data.list
    end
    latest = data
    if type(data) == "table" and #data > 0 then
      return data
    end
    if attempt == 1 then
      vim.wait(400, function()
        return false
      end)
    end
  end
  return latest
end

---@return table[]|nil models
function M.models()
  return located_list("/api/model", "list models")
end

---@return table[]|nil agents
function M.agents()
  return located_list("/api/agent", "list agents")
end

---@param session_id string
---@param model table Model.Ref: {id = string, providerID = string, variant = string?}
---@return boolean ok, string|nil error
function M.set_model(session_id, model)
  local _, err = http.post("/api/session/" .. session_id .. "/model", { model = model })
  if err then
    return false, err
  end
  return true
end

---@param session_id string
---@param agent string
---@return boolean ok, string|nil error
function M.set_agent(session_id, agent)
  local _, err = http.post("/api/session/" .. session_id .. "/agent", { agent = agent })
  if err then
    return false, err
  end
  return true
end

-- permissions ----------------------------------------------------------------

---@param session_id string
---@return table[]|nil requests
function M.permissions(session_id)
  local res, err = http.get("/api/session/" .. session_id .. "/permission")
  if err then
    return nil
  end
  local data = unwrap(res)
  if type(data) == "table" and data.list then
    return data.list
  end
  return data
end

---@param session_id string
---@param request_id string
---@param decision "once"|"always"|"reject"
---@param message string|nil
---@return boolean ok, string|nil error
function M.reply_permission(session_id, request_id, decision, message)
  local body = { decision = decision }
  if message then
    body.message = message
  end
  local _, err = http.post("/api/session/" .. session_id .. "/permission/" .. request_id .. "/reply", body)
  if err then
    return false, err
  end
  return true
end

-- filesystem (for @-mentions) ------------------------------------------------

---@param path string
---@return string query string including the leading "?"
local function scoped(path)
  return path .. "?location%5Bdirectory%5D=" .. vim.uri_encode(vim.fn.getcwd())
end

---Find files matching `query`, most relevant first.
---
---Paths come back relative to `location.directory`, and every entry has `type`
---("file" or "directory"); filter out directories so a mention never attaches
---a folder.
---@param query string
---@param limit integer?
---@return table[]|nil results
function M.find_files(query, limit)
  local res, err = http.get(scoped("/api/fs/find") .. "&query=" .. vim.uri_encode(query) .. "&limit=" .. tostring(limit or 50))
  if err then
    return nil
  end
  local data = unwrap(res)
  if type(data) == "table" and data.list then
    data = data.list
  end
  if type(data) ~= "table" then
    return nil
  end
  local files = {}
  for _, item in ipairs(data) do
    if item.type ~= "directory" and type(item.path) == "string" then
      files[#files + 1] = item
    end
  end
  return files
end

-- OpenCode v2 management endpoints (verified against the running server schema).
function M.update_session(id, body)
  local res, err = http.request({ method = "PATCH", path = "/api/session/" .. id, body = body })
  if not err and not res then return M.get_session(id) end
  return checked(res, err, "update session")
end

function M.fork_session(id, before)
  local res, err = http.post("/api/session/" .. id .. "/fork", before and { before = before } or {})
  return checked(res, err, "fork session")
end

function M.revert_to(id, message_id)
  local _, err = http.post("/api/session/" .. id .. "/revert/stage", { messageID = message_id, files = true })
  return err == nil, err
end

function M.diff(id, query)
  local res, err = http.get("/api/session/" .. id .. "/diff", query)
  return checked(res, err, "session diff")
end

function M.forms(id)
  local res, err = http.get("/api/session/" .. id .. "/form")
  return checked(res, err, "pending questions")
end

function M.reply_form(id, form_id, answer, callback)
  http.post_async("/api/session/" .. id .. "/form/" .. form_id .. "/reply", { answer = answer }, function(_, err)
    callback(err == nil, err)
  end)
end

function M.cancel_form(id, form_id)
  local _, err = http.delete("/api/session/" .. id .. "/form/" .. form_id)
  return err == nil, err
end

function M.compact(id)
  local _, err = http.post("/api/session/" .. id .. "/compact", {})
  return err == nil, err
end

function M.mcp()
  return located_list("/api/mcp", "MCP servers")
end

function M.toggle_mcp(name, connected)
  local path = scoped("/api/experimental/mcp/" .. vim.uri_encode(name) .. (connected and "/disconnect" or "/connect"))
  local _, err = http.post(path, {})
  return err == nil, err
end

return M
