-- Transcript rendering: turns messages and live events into buffer lines.
--
-- Block model
-- -----------
-- The transcript is a flat scratch buffer built from *keyed blocks*. Each block
-- remembers where it starts and how tall it currently is, and re-rendering a block
-- replaces only its own region (inserting or deleting lines as it grows or
-- shrinks) while shifting the recorded positions of every block below it.
--
-- That is what makes interleaved turns work: a tool call stays exactly where it
-- appeared even though reasoning and prose keep streaming in beneath it. An
-- earlier "rewrite from here to the end of the buffer" approach silently ate
-- whatever had been appended after the block being updated.
--
-- Highlights travel with the lines, and rows are only resolved to absolute buffer
-- indices once the block's start line is known — marking lines before they are
-- written would land on the wrong text.
--
-- Live event payload contract (opencode v2, verified against a running server):
--   * text / reasoning  keyed by d.assistantMessageID + d.ordinal
--                       started carries no text, delta appends, ended replaces
--   * tools            keyed by d.id; the *name* only arrives on
--                       session.tool.input.started, not on session.tool.called
--                       progress carries metadata, success/failed carry content
--
-- Live events key their parts like this:
--   * text / reasoning -> "<kind>:<assistantMessageID>:<ordinal>"
--   * tools            -> "tool:<callID>"

local config = require("ocmini.config")
local state = require("ocmini.state")

local api = vim.api
local ns = api.nvim_create_namespace("ocmini")

local M = {}

---@type integer|nil
M.buf = nil

---Whether the "no messages yet" placeholder is currently the only content. The
---first real block after an empty history replaces it.
---@type boolean
local placeholder = false

-- buffer / window setup -------------------------------------------------------

---Buffer-local display setup. Window-local options are applied separately by
---apply_window() because there is no window to set them on yet.
---@param buf integer
function M.attach(buf)
  M.buf = buf
  local bo = vim.bo[buf]
  bo.buflisted = false
  bo.swapfile = false
  local function map(key, callback, desc)
    vim.keymap.set("n", key, callback, { buffer = buf, desc = desc })
  end
  map("i", function() require("ocmini.input").focus() end, "OpenCode: compose")
  map("<CR>", function()
    vim.ui.select({"Tool output", "Reasoning"}, { prompt = "Expand/collapse" }, function(choice)
      if choice then require("ocmini.actions").run(choice == "Tool output" and "tools" or "reasoning") end
    end)
  end, "OpenCode: expand output")
  map("]t", function() require("ocmini.tabs").cycle(1) end, "OpenCode: next session")
  map("[t", function() require("ocmini.tabs").cycle(-1) end, "OpenCode: previous session")
  local function message(direction)
    local win = require("ocmini.state").windows.output_win
    if not win then return end
    local cursor = api.nvim_win_get_cursor(win)[1]
    local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
    local row = cursor + direction
    while row >= 1 and row <= #lines do
      if lines[row]:match("^▌ you") then api.nvim_win_set_cursor(win, { row, 0 }); return end
      row = row + direction
    end
  end
  map("]]", function() message(1) end, "OpenCode: next message")
  map("[[", function() message(-1) end, "OpenCode: previous message")
  map("gf", function()
    local name = vim.fn.expand("<cfile>")
    local file, row = name:match("^(.-):(%d+)$")
    file = file or name
    if vim.fn.filereadable(file) == 1 then
      vim.cmd("tabedit " .. vim.fn.fnameescape(file))
      if row then pcall(api.nvim_win_set_cursor, 0, { tonumber(row), 0 }) end
    end
  end, "OpenCode: open file")
end

---Window-local display setup for the transcript float.
---@param win integer
function M.apply_window(win)
  if not (win and api.nvim_win_is_valid(win)) then
    return
  end
  local wo = vim.wo[win]
  wo.wrap = true
  wo.linebreak = true
  wo.breakindent = false
  wo.showbreak = "NONE"
  wo.scrolloff = 0
  wo.sidescrolloff = 0
  wo.cursorline = false
  wo.spell = false
  wo.conceallevel = 0 -- opencode's own output is not markdown-concealed
  wo.foldenable = false
  wo.foldlevel = 0
  wo.number = false
  wo.relativenumber = false
  wo.signcolumn = "no"
  wo.statuscolumn = ""
  wo.colorcolumn = ""
  wo.foldcolumn = "0"
  wo.winbar = ""
end

---@return integer|nil
local function buf()
  if M.buf and api.nvim_buf_is_valid(M.buf) then
    return M.buf
  end
  return nil
end

-- block primitives -----------------------------------------------------------

---@class OcminiBlock
---@field lines string[]
---@field hl table<integer, string> Relative row index -> highlight group.

---@param start integer
---@param lines string[]
---@param hl table<integer, string>|nil
local function apply_hl(start, lines, hl)
  local b = buf()
  if not b then
    return
  end
  api.nvim_buf_clear_namespace(b, ns, start, start + #lines)
  for row, group in pairs(hl or {}) do
    local line = lines[row + 1]
    if line and #line > 0 then
      pcall(api.nvim_buf_set_extmark, b, ns, start + row, 0, { end_col = #line, hl_group = group })
    end
  end
end

---Replace the region of `count` lines starting at `start`, inserting or deleting
---lines as needed. Returns the region's new height.
---@param start integer
---@param count integer
---@param block OcminiBlock
---@return integer new_count
local function set_region(start, count, block)
  local b = buf()
  if not b then
    return count
  end
  local stop = math.min(start + count, api.nvim_buf_line_count(b))
  pcall(api.nvim_buf_set_lines, b, start, stop, false, block.lines)
  apply_hl(start, block.lines, block.hl)
  return #block.lines
end

---After resizing the block at `start`, move every recorded block below it by the
---same number of lines.
---@param start integer
---@param delta integer
local function shift_after(start, delta)
  if delta == 0 then
    return
  end
  for _, part in pairs(state.parts) do
    if part.start and part.start > start then
      part.start = part.start + delta
    end
  end
end

---Replace the whole buffer. Used for a fresh history render, where nothing above
---the region matters.
---@param block OcminiBlock
local function write_all(block)
  local b = buf()
  if not b then
    return
  end
  pcall(api.nvim_buf_set_lines, b, 0, -1, false, block.lines)
  apply_hl(0, block.lines, block.hl)
end

---Append a block at the end of the buffer.
---@param block OcminiBlock
---@return integer|nil start, integer count
local function append(block)
  local b = buf()
  if not b then
    return nil, 0
  end
  if placeholder and #block.lines > 0 then
    placeholder = false
    write_all(block)
    return 0, #block.lines
  end
  local start = api.nvim_buf_line_count(b)
  pcall(api.nvim_buf_set_lines, b, start, start, false, block.lines)
  apply_hl(start, block.lines, block.hl)
  return start, #block.lines
end

---Render or re-render a keyed block: insert it the first time it is seen, then
---resize it in place.
---@param key string
---@param block OcminiBlock
---@return table|nil the tracked part
local function paint(key, block)
  local part = state.parts[key]
  if part and part.start then
    local old = part.count or 0
    local new_count = set_region(part.start, old, block)
    shift_after(part.start, new_count - old)
    part.count = new_count
  else
    local start, count = append(block)
    part = { start = start, count = count }
    state.parts[key] = part
  end
  M.scroll_to_end()
  return part
end

-- text helpers ---------------------------------------------------------------

---@param lines string[]
---@param hl table<integer, string>
---@param row integer Relative index.
---@param group string
local function mark(lines, hl, row, group)
  hl[row] = group
end

---Width to wrap streamed prose at.
---@return integer
local function wrap_width()
  local win = state.windows.output_win
  if win and api.nvim_win_is_valid(win) then
    return math.max(api.nvim_win_get_width(win), 1)
  end
  return math.max(math.floor(vim.o.columns * 0.6), 20)
end

---Greedy word wrap that preserves blank lines and existing newlines.
---@param text string
---@param width integer
---@return string[]
local function wrap(text, width)
  local out = {}
  for _, paragraph in ipairs(vim.split(text or "", "\n", { plain = true })) do
    if paragraph == "" then
      out[#out + 1] = ""
    else
      local line = ""
      for word in paragraph:gmatch("%S+") do
        if line == "" then
          line = word
        elseif #line + 1 + #word <= width then
          line = line .. " " .. word
        else
          out[#out + 1] = line
          line = word
        end
      end
      if line ~= "" then
        out[#out + 1] = line
      end
    end
  end
  if #out == 0 then
    out[1] = ""
  end
  return out
end

---First line of `text` that has something on it. Reasoning parts start with a
---blank line, so taking line 1 verbatim would render an empty summary.
---@param text string
---@return string
local function first_meaningful_line(text)
  for _, line in ipairs(vim.split(text or "", "\n", { plain = true })) do
    local trimmed = line:gsub("^%s+", ""):gsub("%s+$", "")
    if trimmed ~= "" then
      return trimmed
    end
  end
  return ""
end

M.wrap = wrap

-- tool blocks ----------------------------------------------------------------

---@class OcminiToolView
---@field name string
---@field status "running"|"completed"|"error"
---@field detail string|nil
---@field error string|nil
---@field preview string[]|nil

---Build the lines for a tool call.
---@param view OcminiToolView
---@param width integer
---@return OcminiBlock
local function tool_block(view, width)
  local lines, hl = {}, {}
  local glyph, group = "⏺", "OcminiToolRunning"
  if view.status == "completed" then
    glyph, group = "✔", "OcminiToolDone"
  elseif view.status == "error" then
    glyph, group = "✖", "OcminiToolError"
  end

  local head = string.format("  %s %s", glyph, view.name or "tool")
  if view.detail and view.detail ~= "" then
    head = head .. "  " .. view.detail
  end
  lines[1] = head
  mark(lines, hl, 0, group)

  if view.error and view.error ~= "" then
    for _, l in ipairs(wrap(view.error, math.max(width - 4, 20))) do
      lines[#lines + 1] = "    " .. l
      mark(lines, hl, #lines - 1, "OcminiToolError")
    end
  end

  for _, l in ipairs(view.preview or {}) do
    lines[#lines + 1] = "    " .. l
    mark(lines, hl, #lines - 1, "OcminiMeta")
  end

  lines[#lines + 1] = ""
  return { lines = lines, hl = hl }
end

---Render a tool call, keeping the name/details/status we have learned so far.
---@param call_id any
---@param update table Fields to merge into the tracked view.
local function paint_tool(call_id, update)
  local key = "tool:" .. tostring(call_id)
  local part = state.parts[key] or {}
  for k, v in pairs(update) do
    if v ~= nil then
      part[k] = v
    end
  end
  part.status = part.status or "running"
  part.name = part.name or "tool"
  local block = tool_block(part, wrap_width())
  local tracked = paint(key, block)
  if tracked then
    for k, v in pairs(part) do
      if k ~= "start" and k ~= "count" then
        tracked[k] = v
      end
    end
  end
end

---@param call_id any
---@return table|nil
local function tool_part(call_id)
  return state.parts["tool:" .. tostring(call_id)]
end

---One-line description of a tool call's input.
---@param input any
---@return string
local function tool_detail(input)
  if type(input) ~= "table" then
    return ""
  end
  for _, key in ipairs({ "filePath", "path", "url" }) do
    if type(input[key]) == "string" and input[key] ~= "" then
      return vim.fn.fnamemodify(input[key], ":t")
    end
  end
  for _, key in ipairs({ "command", "pattern", "query" }) do
    if type(input[key]) == "string" and input[key] ~= "" then
      local one_line = input[key]:gsub("\n", " "):gsub("%s+", " ")
      if #one_line > 60 then
        one_line = one_line:sub(1, 57) .. "..."
      end
      return one_line
    end
  end
  return ""
end

---Flatten a tool's `content` array into preview lines.
---@param content any
---@param limit integer
---@param width integer
---@return string[]
local function tool_preview(content, limit, width)
  if type(content) ~= "table" then
    return {}
  end
  local text = {}
  for _, piece in ipairs(content) do
    if type(piece) == "table" and type(piece.text) == "string" then
      text[#text + 1] = piece.text
    end
  end
  if #text == 0 then
    return {}
  end
  local joined = table.concat(text, "\n")
  local lines = wrap(joined, math.max(width - 4, 20))
  while #lines > 0 and lines[#lines] == "" do
    table.remove(lines)
  end
  if limit > 0 and #lines > limit then
    local trimmed = {}
    for i = 1, limit do
      trimmed[i] = lines[i]
    end
    trimmed[#trimmed + 1] = string.format("    … %d more lines", #lines - limit)
    return trimmed
  end
  return lines
end

-- history --------------------------------------------------------------------

---@param message table
---@param width integer
---@return OcminiBlock
local function message_block(message, width)
  local lines, hl = {}, {}
  local kind = message.type

  if kind == "user" then
    lines[#lines + 1] = "▌ you"
    mark(lines, hl, #lines - 1, "OcminiUserHeader")
    for _, l in ipairs(wrap(message.text or "", width)) do
      lines[#lines + 1] = l
    end
    if type(message.files) == "table" and #message.files > 0 then
      local names = {}
      for _, f in ipairs(message.files) do
        names[#names + 1] = f.name or f.uri
      end
      lines[#lines + 1] = "  " .. table.concat(names, " ")
      mark(lines, hl, #lines - 1, "OcminiMeta")
    end
    lines[#lines + 1] = ""
    return { lines = lines, hl = hl }
  end

  if kind ~= "assistant" then
    return { lines = lines, hl = hl }
  end

  for _, part in ipairs(message.content or {}) do
    if part.type == "text" then
      for _, l in ipairs(wrap(part.text or "", width)) do
        lines[#lines + 1] = l
      end
      lines[#lines + 1] = ""
    elseif part.type == "reasoning" then
      local text = part.text or ""
      if config.values.render.collapse_reasoning then
        lines[#lines + 1] = "▚ " .. first_meaningful_line(text)
        mark(lines, hl, #lines - 1, "OcminiMeta")
        lines[#lines + 1] = ""
      else
        for _, l in ipairs(wrap(text, width)) do
          lines[#lines + 1] = "▚ " .. l
          mark(lines, hl, #lines - 1, "OcminiMeta")
        end
        lines[#lines + 1] = ""
      end
    elseif part.type == "tool" then
      local status = type(part.state) == "table" and part.state.status or "running"
      local view = {
        name = part.name or "tool",
        status = status,
        detail = config.values.render.collapse_tools and nil or tool_detail(part.state and part.state.input),
        error = status == "error"
          and type(part.state) == "table"
          and type(part.state.error) == "table"
          and part.state.error.message
          or nil,
        preview = config.values.render.collapse_tools
            and {}
          or tool_preview(part.state and part.state.content, config.values.render.tool_preview_lines, width),
      }
      local block = tool_block(view, width)
      local base = #lines
      vim.list_extend(lines, block.lines)
      for row, group in pairs(block.hl) do
        mark(lines, hl, base + row, group)
      end
    end
  end
  return { lines = lines, hl = hl }
end

---Replace the whole transcript with `messages` (oldest first).
---@param messages table[]
function M.render_history(messages)
  if not buf() then
    return
  end
  state.parts = {}
  local width = wrap_width()
  local lines, hl = {}, {}
  for _, message in ipairs(messages or {}) do
    local block = message_block(message, width)
    local base = #lines
    vim.list_extend(lines, block.lines)
    for row, group in pairs(block.hl) do
      mark(lines, hl, base + row, group)
    end
  end
  if #lines == 0 then
    lines = { "No messages yet — type below and press " .. config.values.keys.submit .. " to send." }
    placeholder = true
  else
    placeholder = false
  end
  write_all({ lines = lines, hl = hl })
  M.scroll_to_end()
end

---Echo a prompt the user just submitted.
---@param text string
---@param files table[]|nil
function M.render_local_user(text, files)
  local width = wrap_width()
  local lines, hl = { "▌ you" }, {}
  mark(lines, hl, 0, "OcminiUserHeader")
  for _, l in ipairs(wrap(text, width)) do
    lines[#lines + 1] = l
  end
  if files and #files > 0 then
    local names = {}
    for _, f in ipairs(files) do
      names[#names + 1] = f.name or f.uri
    end
    lines[#lines + 1] = "  " .. table.concat(names, " ")
  end
  lines[#lines + 1] = ""
  append({ lines = lines, hl = hl })
  M.scroll_to_end()
end

---@param text string
---@param group string
function M.render_status(text, group)
  append({ lines = { text, "" }, hl = { [0] = group } })
  M.scroll_to_end()
end

---Append an arbitrary block, with optional per-row highlights.
---@param lines string[]
---@param hl table<integer, string>|nil Relative row index -> highlight group.
function M.render_block(lines, hl)
  append({ lines = lines, hl = hl or {} })
  M.scroll_to_end()
end

function M.scroll_to_end()
  local b = buf()
  local win = state.windows.output_win
  if not b or not win or not api.nvim_win_is_valid(win) then
    return
  end
  pcall(api.nvim_win_set_cursor, win, { api.nvim_buf_line_count(b), 0 })
end

-- live events ----------------------------------------------------------------

---@param message_id any
---@param kind string
---@param ordinal any
---@return string
local function part_key(message_id, kind, ordinal)
  return string.format("%s:%s:%s", kind, tostring(message_id), tostring(ordinal))
end

---@param text string
---@param kind string
---@param width integer
---@return OcminiBlock
local function prose_block(text, kind, width)
  if kind == "reasoning" then
    if config.values.render.collapse_reasoning then
      local first = first_meaningful_line(text)
      return { lines = { first ~= "" and ("▚ " .. first) or "▚" }, hl = { [0] = "OcminiMeta" } }
    end
    -- Reasoning parts arrive with a leading newline; drop leading blank lines so
    -- the block does not start with an empty line.
    local body = vim.split(text or "", "\n", { plain = true })
    local first_content = 1
    while first_content <= #body and body[first_content]:gsub("%s", "") == "" do
      first_content = first_content + 1
    end
    local lines, hl = {}, {}
    for i = first_content, #body do
      local l = body[i]
      lines[#lines + 1] = l:gsub("%s", "") == "" and "" or ("▚ " .. l)
      mark(lines, hl, #lines - 1, "OcminiMeta")
    end
    if #lines == 0 then
      lines[1] = "▚"
      mark(lines, hl, 0, "OcminiMeta")
    end
    return { lines = lines, hl = hl }
  end
  return { lines = wrap(text, width), hl = {} }
end

---@param key string
---@param text string
---@param kind string
local function paint_part(key, text, kind)
  local part = paint(key, prose_block(text, kind, wrap_width()))
  if part then
    part.text = text
    part.kind = kind
  end
end

---The assistant message id a part belongs to.
---@param d table
---@return any
local function message_of(d)
  return d.assistantMessageID or d.messageID or d.messageId or d.message_id
end

---@param ev table Decoded SSE frame: {id, type, data = payload, created}
function M.on_event(ev)
  local etype = ev.type
  local d = ev.data or {}
  local kind = etype:find("reasoning", 1, true) and "reasoning" or "text"
  local key = part_key(message_of(d), kind, d.ordinal)
  local width = wrap_width()

  if etype == "session.text.started" or etype == "session.reasoning.started" then
    paint_part(key, d.text or "", kind)
  elseif etype == "session.text.delta" or etype == "session.reasoning.delta" then
    local part = state.parts[key] or {}
    paint_part(key, (part.text or "") .. (d.delta or ""), kind)
  elseif etype == "session.text.ended" or etype == "session.reasoning.ended" then
    paint_part(key, d.text or "", kind)
  elseif etype == "session.tool.input.started" then
    -- The tool's name only ever arrives here, so this is where a tool line first
    -- appears; tool.called follows with its input.
    paint_tool(d.id, { name = d.name })
  elseif etype == "session.tool.input.ended" then
    local part = tool_part(d.id) or {}
    paint_tool(d.id, { name = d.name or part.name })
  elseif etype == "session.tool.called" then
    paint_tool(d.id, { detail = tool_detail(d.input) })
  elseif etype == "session.tool.progress" then
    paint_tool(d.id, { status = "running" })
  elseif etype == "session.tool.success" then
    paint_tool(d.id, {
      status = "completed",
      preview = config.values.render.collapse_tools
          and {}
        or tool_preview(d.content, config.values.render.tool_preview_lines, width),
    })
  elseif etype == "session.tool.failed" then
    paint_tool(d.id, {
      status = "error",
      error = type(d.error) == "table" and d.error.message or "tool failed",
    })
  elseif etype == "session.execution.started" then
    M.render_status("  … working", "OcminiMeta")
  elseif etype == "session.execution.succeeded" then
    M.render_status("  ✓ done", "OcminiToolDone")
  elseif etype == "session.execution.interrupted" then
    M.render_status("  ■ interrupted", "OcminiMeta")
  elseif etype == "session.execution.failed" then
    local msg = "failed"
    if type(d.error) == "table" and type(d.error.message) == "string" then
      msg = d.error.message
    end
    M.render_status("  ✖ " .. msg, "OcminiToolError")
  end
end

function M.reset()
  state.parts = {}
end

return M
