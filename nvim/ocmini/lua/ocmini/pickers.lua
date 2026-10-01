-- Pickers for switching model, agent, and session.
--
-- All three use Snacks' picker, which LazyVim already configures, so they inherit
-- the user's layout and keymaps instead of shipping another picker.

local api = require("ocmini.api")
local log = require("ocmini.log")
local state = require("ocmini.state")

local M = {}

---@param items table[]
---@param opts table
local function pick(items, opts)
  if #items == 0 then
    log.warn(opts.empty_message or "nothing to pick from")
    return
  end
  local ok, snacks = pcall(require, "snacks")
  if not ok then
    log.error("snacks.nvim is required for ocmini pickers")
    return
  end
  -- Snacks' signature is pick(source, opts): the first argument is a *source
  -- name*, not a list. Called as pick(items, opts) it takes the items table as
  -- the source name and then concatenates it into a history path, which throws.
  -- The single-table form is the documented overload.
  opts.items = items
  snacks.picker.pick(opts)
end

---Switch the session's model.
function M.model()
  local models = api.models()
  if not models then
    return
  end
  local items = {}
  local favorites = require("ocmini.storage").read("favorites")
  for _, info in ipairs(models) do
    if info.enabled ~= false then
      items[#items + 1] = {
        text = string.format("%s/%s", info.providerID or "?", info.name or info.modelID or info.id),
        desc = (favorites[info.providerID .. "/" .. info.id] and "★ " or "") .. (info.family or ""),
        favorite = favorites[info.providerID .. "/" .. info.id] or false,
        id = info.id,
        providerID = info.providerID,
      }
    end
  end
  table.sort(items, function(a, b)
    if a.favorite ~= b.favorite then return a.favorite end
    return a.text < b.text
  end)
  pick(items, {
    source = "ocmini_model",
    title = "opencode model",
    format = function(item)
      local session = state.session
      local current = session and session.model and session.model.id
      return {
        { (item.id == current and "● " or "  ") .. item.text, item.id == current and "OcminiToolDone" or "Normal" },
        { item.desc ~= "" and ("  " .. item.desc) or "", "Comment" },
      }
    end,
    confirm = function(picker, item)
      picker:close()
      if not state.session_id then
        return
      end
      local ref = { id = item.id, providerID = item.providerID }
      local ok, err = api.set_model(state.session_id, ref)
      if ok then
        if state.session then
          state.session.model = ref
        end
        require("ocmini.render").render_status("  model: " .. item.text, "OcminiMeta")
        require("ocmini.status").update()
      else
        log.error("could not switch model: " .. tostring(err))
      end
    end,
  })
end

---Switch the session's agent.
function M.agent()
  local agents = api.agents()
  if not agents then
    return
  end
  local items = {}
  for _, info in ipairs(agents) do
    if not info.hidden then
      items[#items + 1] = {
        text = info.name or info.id,
        desc = info.description or info.mode or "",
        id = info.id,
      }
    end
  end
  pick(items, {
    source = "ocmini_agent",
    title = "opencode agent",
    format = function(item)
      local current = state.session and state.session.agent
      return {
        { (item.id == current and "● " or "  ") .. item.text, item.id == current and "OcminiToolDone" or "Normal" },
        { item.desc ~= "" and ("  " .. item.desc) or "", "Comment" },
      }
    end,
    confirm = function(picker, item)
      picker:close()
      if not state.session_id then
        return
      end
      local ok, err = api.set_agent(state.session_id, item.id)
      if ok then
        if state.session then
          state.session.agent = item.id
        end
        require("ocmini.render").render_status("  agent: " .. item.text, "OcminiMeta")
        require("ocmini.status").update()
      else
        log.error("could not switch agent: " .. tostring(err))
      end
    end,
  })
end

---Switch to another session.
function M.session()
  local sessions = api.list_sessions({ limit = 50, order = "desc" })
  if not sessions then
    return
  end
  local items = {}
  for _, info in ipairs(sessions) do
    items[#items + 1] = {
      text = info.title or info.id,
      desc = info.id,
      id = info.id,
      time = info.time and info.time.updated or 0,
    }
  end
  table.sort(items, function(a, b)
    return (a.time or 0) > (b.time or 0)
  end)
  pick(items, {
    source = "ocmini_session",
    title = "opencode sessions",
    format = function(item)
      local current = state.session_id
      return {
        { (item.id == current and "● " or "  ") .. item.text, item.id == current and "OcminiToolDone" or "Normal" },
        { "  " .. item.desc, "Comment" },
      }
    end,
    confirm = function(picker, item)
      picker:close()
      require("ocmini.events").switch_session(item.id)
    end,
  })
end

---Choose a slash command from OpenCode plus the actions provided by its TUI.
---@param origin {buf: integer, row: integer, col: integer}
function M.command(origin)
  local commands = api.commands() or {}
  local items, seen = {}, {}
  local function add(name, desc, builtin)
    if type(name) == "string" and name ~= "" and not seen[name] then
      seen[name] = true
      items[#items + 1] = {
        text = "/" .. name,
        name = name,
        desc = type(desc) == "string" and desc or "",
        builtin = builtin or false,
      }
    end
  end

  for _, command in ipairs(require("ocmini.actions").commands()) do
    add(command.name, command.description, true)
  end
  for _, command in ipairs(commands) do
    add(command.name or command.id, command.description or command.agent)
  end

  pick(items, {
    source = "ocmini_command",
    title = "OpenCode commands",
    layout = { preset = "select" },
    format = function(item)
      return {
        { item.text, "Function" },
        { item.desc ~= "" and ("  " .. item.desc) or "", "Comment" },
      }
    end,
    confirm = function(picker, item)
      picker:close()
      if item.builtin then
        require("ocmini.input").run_builtin(origin.buf, origin.row, origin.col, item.name)
      else
        require("ocmini.input").insert_command(origin.buf, origin.row, origin.col, item.name)
      end
    end,
  })
end

return M
