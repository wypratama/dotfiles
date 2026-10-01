-- Server lifecycle: a private `opencode serve` per Neovim instance, or reuse of
-- one already running for this directory.
--
-- The whole connection story is deliberately small. opencode's own server is
-- plain HTTP + Basic auth, so instead of opencode.nvim's port-mapping and
-- credential-resolution machinery we just:
--   1. keep one random password in a 0600 state file,
--   2. bind an ephemeral port,
--   3. spawn `opencode serve --port N` with that password in the environment,
--   4. poll GET /api/info until it answers with a 2.x version.
--
-- A second Neovim instance on the same directory reuses the running server
-- instead of spawning another one.

local config = require("ocmini.config")
local http = require("ocmini.http")
local log = require("ocmini.log")

local uv = vim.uv or vim.loop

local M = {}

---@class OcminiServer
---@field url string|nil
---@field port integer|nil
---@field pid integer|nil
---@field spawned_by_us boolean

---@type OcminiServer
local state = { url = nil, port = nil, pid = nil, spawned_by_us = false }

---@type integer|nil job id of the spawn we own
local spawn_job = nil

local function mapping_path()
  return vim.fn.stdpath("data") .. "/ocmini_servers.json"
end

---@return table<string, {pid: integer, port: integer}>
local function read_mappings()
  local fd = io.open(mapping_path(), "r")
  if not fd then
    return {}
  end
  local content = fd:read("*all")
  fd:close()
  local ok, data = pcall(vim.json.decode, content or "")
  return ok and type(data) == "table" and data or {}
end

---@param data table<string, {pid: integer, port: integer}>
local function write_mappings(data)
  local ok = pcall(function()
    local fd = assert(io.open(mapping_path(), "w"))
    fd:write(vim.json.encode(data))
    fd:close()
  end)
  if not ok then
    log.debug("could not write server mappings")
  end
end

---@param pid integer
---@return boolean
local function process_alive(pid)
  if not pid or pid <= 0 then
    return false
  end
  return uv.kill(pid, 0) == 0
end

---Random hex string, preferring the kernel CSPRNG.
---@param nbytes integer
---@return string 2*nbytes hex characters
function M.random_hex(nbytes)
  local fd = io.open("/dev/urandom", "rb")
  local bytes = fd and fd:read(nbytes) or nil
  if fd then
    fd:close()
  end
  if not bytes or #bytes < nbytes then
    -- Fall back to hashing a changing clock. This only ever guards a loopback
    -- Basic-auth password, never a real secret.
    bytes = vim.fn.sha256(table.concat({ uv.hrtime(), os.time(), uv.os_getpid(), tostring(math.random()) }, ":"))
  end
  return (bytes:gsub(".", function(c)
    return string.format("%02x", c:byte())
  end))
end

---Read the shared password, generating and persisting one on first use.
---@return string|nil password, string|nil error
function M.ensure_password()
  local path = config.values.password_file

  local fd = io.open(path, "r")
  if fd then
    local pw = (fd:read("*l") or ""):gsub("%s+$", "")
    fd:close()
    if pw ~= "" then
      return pw
    end
  end

  local pw = M.random_hex(24)

  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local ok = pcall(function()
    local out = assert(io.open(path, "w"))
    out:write(pw .. "\n")
    out:close()
    vim.uv.fs_chmod(path, tonumber("600", 8))
  end)
  if not ok then
    return nil, "could not write password file: " .. path
  end
  log.debug("generated a new server password at " .. path)
  return pw
end

---Ask the OS for a free loopback port.
---@return integer
local function free_port()
  local tcp = uv.new_tcp()
  assert(tcp:bind("127.0.0.1", 0))
  local ok, addr = pcall(uv.tcp_getsockname, tcp)
  local port = ok and addr and addr.port or 0
  tcp:close()
  assert(port > 0, "could not determine a free port")
  return port
end

---Poll /api/info until the server reports a 2.x version.
---@param password string
---@param timeout_ms integer
---@return boolean ok, string|nil version, string|nil error
function M.wait_until_healthy(password, timeout_ms)
  http.set_credentials(state.url, password)
  local deadline = uv.now() + timeout_ms
  local last_err = nil
  while uv.now() < deadline do
    local body, err = http.request({ method = "GET", path = "/api/info", timeout = 2000 })
    if body and type(body.version) == "string" then
      if body.version:match("^2%.") then
        return true, body.version
      end
      return false, nil, string.format("server is v%s but this client speaks v2", body.version)
    end
    last_err = err
    vim.wait(120, function()
      return false
    end, 10)
  end
  return false, nil, last_err or "server did not become healthy in time"
end

---Try to attach to a server this directory already has.
---@return boolean
function M.attach_existing()
  if not config.values.server.reuse then
    return false
  end
  local entry = read_mappings()[vim.fn.getcwd()]
  if not entry or not process_alive(entry.pid) then
    return false
  end
  local pw = M.ensure_password()
  if not pw then
    return false
  end
  state.url = string.format("http://127.0.0.1:%d", entry.port)
  state.port = entry.port
  state.pid = entry.pid
  state.spawned_by_us = false
  local ok = M.wait_until_healthy(pw, 3000)
  if not ok then
    state.url, state.port, state.pid = nil, nil, nil
    return false
  end
  log.debug(string.format("attached to existing server pid=%d port=%d", entry.pid, entry.port))
  return true
end

---Spawn a private server and wait for it.
---@return boolean ok, string|nil error
function M.spawn()
  local pw, err = M.ensure_password()
  if not pw then
    return false, err
  end

  local port = free_port()
  state.url = string.format("http://127.0.0.1:%d", port)
  state.port = port
  state.spawned_by_us = true

  local bin = config.values.bin
  if not bin:match("[/\\]") then
    local exe = vim.fn.exepath(bin)
    if exe ~= "" then
      bin = exe
    end
  end

  log.debug(string.format("spawning %s serve --port %d", bin, port))
  -- detach = true so the server outlives this Neovim. That is what makes
  -- attach_existing() reachable at all: a non-detached child is killed with its
  -- parent, so the next instance would only ever find a dead pid. Reaping it is
  -- our job instead, which stop() does by OS pid (see below).
  spawn_job = vim.fn.jobstart({ bin, "serve", "--port", tostring(port) }, {
    detach = true,
    env = vim.tbl_extend("force", vim.uv.os_environ(), {
      OPENCODE_SERVER_PASSWORD = pw,
      OPENCODE_PASSWORD = pw,
    }),
    stdout_buffered = false,
    stderr_buffered = false,
    on_stderr = function(_, data)
      if data then
        for _, chunk in ipairs(data) do
          if chunk ~= "" then
            log.debug("server stderr: " .. chunk)
          end
        end
      end
    end,
    on_exit = function(_, code)
      if code ~= 0 then
        log.debug(string.format("server exited with code %d", code))
      end
    end,
  })

  if spawn_job <= 0 then
    spawn_job = nil
    state.url, state.port = nil, nil
    return false, "could not spawn " .. bin
  end

  local ok, _, health_err = M.wait_until_healthy(pw, config.values.startup_timeout)
  if not ok then
    M.stop()
    return false, health_err
  end

  -- jobstart returns a *job id*, not an OS pid. The pid is what a second Neovim
  -- has to probe to decide whether it can reuse this server, so record that.
  local pid = vim.fn.jobpid(spawn_job)
  state.pid = pid > 0 and pid or nil
  local mappings = read_mappings()
  mappings[vim.fn.getcwd()] = { pid = state.pid or 0, port = port }
  write_mappings(mappings)
  return true
end

---Make sure a usable server exists and the transport points at it.
---@return boolean ok, string|nil error
function M.ensure()
  local external = config.values.server
  if external.url then
    state.url = external.url:match("^https?://") and external.url or ("http://" .. external.url)
    state.spawned_by_us = false
    http.set_credentials(state.url, external.password or vim.env.OPENCODE_SERVER_PASSWORD or "", external.username or vim.env.OPENCODE_SERVER_USERNAME or "opencode")
    local info, err = http.get("/api/info")
    return info ~= nil, err
  end
  if state.url and state.pid and process_alive(state.pid) then
    local pw = M.ensure_password()
    if pw then
      http.set_credentials(state.url, pw)
      return true
    end
  end
  if M.attach_existing() then
    return true
  end
  return M.spawn()
end

function M.url()
  return state.url
end

function M.port()
  return state.port
end

function M.is_running()
  return state.url ~= nil
end

---Stop the server we own and clear state.
---
---The child is detached, so jobstop() is not enough: signal the OS pid. A
---server we merely attached to is left running for whoever owns it.
function M.stop()
  if state.spawned_by_us and state.pid and process_alive(state.pid) then
    pcall(uv.kill, state.pid, "sigterm")
  end
  if spawn_job and spawn_job > 0 then
    pcall(vim.fn.jobstop, spawn_job)
  end
  spawn_job = nil

  if state.spawned_by_us then
    local mappings = read_mappings()
    local entry = mappings[vim.fn.getcwd()]
    if entry and entry.port == state.port then
      mappings[vim.fn.getcwd()] = nil
      write_mappings(mappings)
    end
  end
  state.url, state.port, state.pid, state.spawned_by_us = nil, nil, nil, false
  http.clear_credentials()
end

return M
