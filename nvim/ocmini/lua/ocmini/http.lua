-- HTTP transport for the opencode v2 API.
--
-- The server speaks plain HTTP + Basic auth on localhost, so there is no need
-- for a curl/pty abstraction here: one-shot calls go through vim.system and the
-- long-lived event stream is a single `curl -N` job we parse frame by frame.
--
-- This module deliberately does not require `server`: the server module sets the
-- credentials here once it knows them, which keeps the dependency one-way
-- (log <- http <- server) and avoids a require cycle.

local log = require("ocmini.log")

local M = {}

---@type string|nil
local base_url = nil
---@type string|nil
local password = nil
---@type string|nil
local username = "opencode"

---Point the transport at a server. Called by ocmini.server once it has both the
---URL and the password.
---@param url string e.g. "http://127.0.0.1:46001"
---@param pw string
---@param user string?
function M.set_credentials(url, pw, user)
  base_url = url
  password = pw
  username = user or "opencode"
end

function M.clear_credentials()
  base_url = nil
  password = nil
end

---@return boolean
function M.has_credentials()
  return base_url ~= nil and password ~= nil
end

function M.base_url()
  return base_url
end

---@return string[] curl arguments shared by every request.
local function auth_args()
  if not base_url or not password then
    return {}
  end
  return { "-u", string.format("%s:%s", username, password) }
end

---@param path string
---@return string
local function url_for(path)
  assert(base_url, "ocmini.http: no server credentials (call set_credentials first)")
  if path:match("^https?://") then
    return path
  end
  return base_url .. path
end

---Build a query string from a table, skipping nil values.
---@param query table<string, string|number|boolean|nil>|nil
---@return string
local function encode_query(query)
  if not query then
    return ""
  end
  local parts = {}
  for k, v in pairs(query) do
    if v ~= nil then
      parts[#parts + 1] = string.format("%s=%s", vim.uri_encode(k), vim.uri_encode(tostring(v)))
    end
  end
  if #parts == 0 then
    return ""
  end
  return "?" .. table.concat(parts, "&")
end

local function error_detail(result)
  local body = (result.stdout or ""):gsub("%s+$", "")
  if body ~= "" then
    local ok, decoded = pcall(vim.json.decode, body)
    if ok and type(decoded) == "table" then
      local message = decoded.message or type(decoded.error) == "table" and decoded.error.message
      if message then return tostring(message) end
    end
    return body:sub(1, 1500)
  end
  return (result.stderr or ""):gsub("%s+$", "")
end

---One-shot JSON request. Synchronous on purpose: every call targets a local
---server and answers in single-digit milliseconds, which is far cheaper than
---threading a coroutine through the whole plugin.
---
---@param opts {method: string?, path: string, body: table|nil, query: table|nil, timeout: integer?}
---@return table|nil decoded JSON body
---@return string|nil error
function M.request(opts)
  local method = (opts.method or "GET"):upper()
  local full_url = url_for(opts.path) .. encode_query(opts.query)
  local timeout = opts.timeout or 30000

  local cmd = { "curl", "-sS", "--fail-with-body", "--max-time", tostring(timeout / 1000) }
  vim.list_extend(cmd, auth_args())
  if opts.body ~= nil then
    vim.list_extend(cmd, { "-X", method, "-H", "Content-Type: application/json", "-d", vim.json.encode(next(opts.body) == nil and vim.empty_dict() or opts.body) })
  elseif method ~= "GET" then
    vim.list_extend(cmd, { "-X", method })
  end
  cmd[#cmd + 1] = full_url

  log.debug(string.format("request %s %s", method, full_url))

  local ok, res = pcall(function()
    return vim.system(cmd, { text = true }):wait(timeout)
  end)
  if not ok then
    return nil, tostring(res)
  end
  if res.code ~= 0 then
    local detail = error_detail(res)
    return nil, string.format("%s %s failed (%d): %s", method, opts.path, res.code, detail)
  end

  local body = (res.stdout or ""):gsub("%s+$", "")
  if body == "" then
    return nil, nil
  end
  local decoded_ok, decoded = pcall(vim.json.decode, body, { luanil = { object = true, array = true } })
  if not decoded_ok then
    return nil, string.format("%s %s: invalid JSON: %s", method, opts.path, tostring(decoded))
  end
  return decoded, nil
end

---Issue a JSON request without blocking Neovim while OpenCode executes it.
---@param opts {method: string?, path: string, body: table|nil, query: table|nil, timeout: integer?}
---@param callback fun(body: table|nil, err: string|nil)
function M.request_async(opts, callback)
  local method = (opts.method or "GET"):upper()
  local full_url = url_for(opts.path) .. encode_query(opts.query)
  local timeout = opts.timeout or 3600000
  local cmd = { "curl", "-sS", "--fail-with-body", "--max-time", tostring(timeout / 1000) }
  vim.list_extend(cmd, auth_args())
  if opts.body ~= nil then
    vim.list_extend(cmd, { "-X", method, "-H", "Content-Type: application/json", "-d", vim.json.encode(next(opts.body) == nil and vim.empty_dict() or opts.body) })
  elseif method ~= "GET" then
    vim.list_extend(cmd, { "-X", method })
  end
  cmd[#cmd + 1] = full_url

  log.debug(string.format("async request %s %s", method, full_url))
  local ok, process = pcall(vim.system, cmd, { text = true }, function(res)
    vim.schedule(function()
      if res.code ~= 0 then
        local detail = error_detail(res)
        callback(nil, string.format("%s %s failed (%d): %s", method, opts.path, res.code, detail))
        return
      end
      local body = (res.stdout or ""):gsub("%s+$", "")
      if body == "" then
        callback(nil, nil)
        return
      end
      local decoded_ok, decoded = pcall(vim.json.decode, body, { luanil = { object = true, array = true } })
      if not decoded_ok then
        callback(nil, string.format("%s %s: invalid JSON: %s", method, opts.path, tostring(decoded)))
        return
      end
      callback(decoded, nil)
    end)
  end)
  if not ok then
    callback(nil, tostring(process))
  end
end

function M.post_async(path, body, callback)
  M.request_async({ method = "POST", path = path, body = body or {} }, callback)
end

---@param path string
---@param query table|nil
---@return table|nil, string|nil
function M.get(path, query)
  return M.request({ method = "GET", path = path, query = query })
end

---@param path string
---@param body table
---@return table|nil, string|nil
function M.post(path, body)
  return M.request({ method = "POST", path = path, body = body or {} })
end

---@param path string
---@param body table
---@return table|nil, string|nil
function M.patch(path, body)
  return M.request({ method = "PATCH", path = path, body = body or {} })
end

---@param path string
---@return table|nil, string|nil
function M.delete(path)
  return M.request({ method = "DELETE", path = path })
end

---Open the server-sent event stream. `on_frame` receives the decoded payload of
---every complete SSE frame; `on_state` receives "open" | "closed" | "error".
---
---The stream is long-lived and reconnecting, so this is a job rather than a
---vim.system() call.
---
---@param path string
---@param on_frame fun(frame: {id: string|nil, event: string|nil, data: table})
---@param on_state fun(state: string, detail: string|nil)?
---@return integer job id
function M.stream(path, on_frame, on_state)
  local cmd = { "curl", "-sN", "--no-buffer", "--max-time", "86400" }
  vim.list_extend(cmd, auth_args())
  cmd[#cmd + 1] = url_for(path)

  log.debug("stream open: " .. url_for(path))

  -- Line-oriented SSE consumer. jobstart hands us lines *without* their
  -- terminators, so a buffer search for "\n\n" would never find a frame
  -- boundary; we consume blank lines as the separator instead. The final
  -- element of each on_stdout batch may be a partial line, so it is held back
  -- until the next batch completes it.
  local cur = { id = nil, event = nil, data = {} }
  local partial = ""

  local function flush_frame()
    if #cur.data == 0 and cur.event == nil then
      return
    end
    local raw = table.concat(cur.data, "\n")
    local frame = { id = cur.id, event = cur.event }
    cur = { id = nil, event = nil, data = {} }
    if raw == "" then
      return
    end
    local ok, decoded = pcall(vim.json.decode, raw, { luanil = { object = true, array = true } })
    if not (ok and type(decoded) == "table") then
      log.debug("stream: undecodable data: " .. raw:sub(1, 200))
      return
    end
    frame.data = decoded
    local handler_ok, err = pcall(on_frame, frame)
    if not handler_ok then
      log.error("stream handler error: " .. tostring(err))
      log.debug(debug.traceback("", 2))
    end
  end

  ---@param line string one complete SSE line, terminator stripped
  local function handle_line(line)
    if line == "" then
      flush_frame()
      return
    end
    if line:sub(1, 1) == ":" then
      return -- ": heartbeat" and other SSE comments
    end
    local field, value = line:match("^([%w_%-]+):[ ]?(.*)$")
    if field == "data" then
      cur.data[#cur.data + 1] = value
    elseif field == "event" then
      cur.event = value
    elseif field == "id" then
      cur.id = value
    end
  end

  local job = vim.fn.jobstart(cmd, {
    stdout_buffered = false,
    stderr_buffered = false,
    on_stdout = function(_, data)
      if not data then
        return
      end
      local last = #data
      for i = 1, last do
        local line = data[i]
        if i == last then
          partial = partial .. line
        else
          handle_line(partial .. line)
          partial = ""
        end
      end
    end,
    on_stderr = function(_, data)
      if data then
        for _, chunk in ipairs(data) do
          if chunk ~= "" then
            log.debug("stream stderr: " .. chunk)
          end
        end
      end
    end,
    on_exit = function(_, code)
      if on_state then
        if code == 0 then
          on_state("closed", nil)
        else
          on_state("error", string.format("event stream exited with code %d", code))
        end
      end
    end,
  })

  if on_state then
    local started = job > 0
    vim.schedule(function()
      if started then
        on_state("open", nil)
      else
        on_state("error", "failed to spawn curl")
      end
    end)
  end

  return job
end

return M
