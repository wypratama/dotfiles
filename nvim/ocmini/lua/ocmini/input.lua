-- The prompt window: a small scratch buffer under the transcript.
--
-- Enter submits, Shift-Enter inserts a newline, Ctrl-C interrupts a running turn, and
-- a leading `/` opens the command picker. `@word` tokens resolve to attachments.

local api = require("ocmini.api")
local config = require("ocmini.config")
local log = require("ocmini.log")
local state = require("ocmini.state")

local nvim_api = vim.api

local M = {}

---@type integer|nil
M.buf = nil

---Attached files chosen for the next submit, populated by the mention picker.
---@type table[]
M.pending_files = {}

---@return string
local function buffer_text()
  if not M.buf or not nvim_api.nvim_buf_is_valid(M.buf) then
    return ""
  end
  return table.concat(nvim_api.nvim_buf_get_lines(M.buf, 0, -1, false), "\n"):gsub("%s+$", "")
end

local function clear_buffer()
  if M.buf and nvim_api.nvim_buf_is_valid(M.buf) then
    nvim_api.nvim_buf_set_lines(M.buf, 0, -1, false, { "" })
  end
end

local function merge_files(...)
  local files, seen = {}, {}
  for _, group in ipairs({ ... }) do
    for _, file in ipairs(group or {}) do
      local key = file.uri or file.name or vim.inspect(file)
      if not seen[key] then seen[key] = true; files[#files + 1] = file end
    end
  end
  return files
end

---Resolve file and agent mentions. Explicit picker attachments preserve paths
---with spaces; hand-typed tokens are resolved against the project directory.
local function resolve_mentions(text)
  local files, agents, available, seen = {}, {}, {}, {}
  if not config.values.input.mentions then return files, agents end
  if text:find("@", 1, true) then
    for _, agent in ipairs(api.agents() or {}) do available[agent.name or agent.id] = true end
  end
  for token in text:gmatch("@([%w%._%-%/]+)") do
    if not seen[token] then
      seen[token] = true
      if available[token] then
        agents[#agents + 1] = { name = token }
      else
        local hit = (api.find_files(token, 1) or {})[1]
        if hit and type(hit.path) == "string" and hit.path ~= "" then
          local abs = vim.fn.fnamemodify(hit.path, ":p"):gsub("/$", "")
          files[#files + 1] = { uri = vim.uri_from_fname(abs), name = vim.fn.fnamemodify(abs, ":t") }
        end
      end
    end
  end
  return files, agents
end

---Send the current buffer contents as a prompt.
function M.submit()
  local text = buffer_text()
  if text == "" then
    return
  end
  if not state.session_id then
    log.error("no opencode session; nothing to send to")
    return
  end

  local explicit = M.pending_files
  local render = require("ocmini.render")

  local command, arguments = text:match("^%s*/([%w_%-%.]+)%s*(.-)%s*$")
  if command and require("ocmini.actions").is_builtin(command) then
    clear_buffer()
    M.execute_builtin(command, arguments)
    return
  end
  local guard = config.values.prompt_guard
  if guard then
    local ok, allowed = pcall(guard)
    if not ok or not allowed then log.warn("Prompt blocked by prompt_guard"); return end
  end
  local submitted_session, submitted_cwd = state.session_id, vim.fn.getcwd()
  if command then
    render.render_local_user(text, explicit)
    clear_buffer()
    M.pending_files = {}
    api.command(submitted_session, command, arguments, function(ok, err)
      if ok then require("ocmini.history").add(text, submitted_cwd) end
      if state.session_id ~= submitted_session then
        if not ok then
          log.error("Slash command in session " .. submitted_session .. " failed: " .. tostring(err))
          local drafts = require("ocmini.tabs").drafts
          drafts[submitted_session] = drafts[submitted_session] or { text = "", files = {} }
          if drafts[submitted_session].text == "" then drafts[submitted_session] = { text = text, files = explicit } end
        end
        return
      end
      if not ok then
        log.error("slash command failed: " .. tostring(err))
        render.render_status("  ✖ " .. tostring(err), "OcminiToolError")
        if M.buf and nvim_api.nvim_buf_is_valid(M.buf) and buffer_text() == "" then
          nvim_api.nvim_buf_set_lines(M.buf, 0, -1, false, vim.split(text, "\n", { plain = true }))
        end
        M.pending_files = merge_files(explicit, M.pending_files)
      end
    end, { files = explicit })
    return
  end

  local mentioned_files, agents = resolve_mentions(text)
  local files = merge_files(explicit, mentioned_files)
  local prompt_text, prompt_files = require("ocmini.context").prepare(text, files)
  local ok, err = api.prompt(state.session_id, prompt_text, { files = prompt_files, agents = agents })
  if not ok then
    log.error("prompt failed: " .. tostring(err))
    render.render_status("  ✖ " .. tostring(err), "OcminiToolError")
    return
  end

  require("ocmini.history").add(text)
  M.pending_files = {}
  clear_buffer()
  render.render_local_user(text, files)
  log.debug("prompt sent (" .. #text .. " chars, " .. #files .. " files, " .. #explicit .. " explicit)")
end

---Interrupt the running turn.
---
---No status is rendered here: the server answers with session.execution.interrupted,
---which render.on_event turns into the "■ interrupted" line. Rendering locally as
---well would print it twice, and it would also print when nothing was running.
function M.interrupt()
  if not state.session_id or not state.streaming then
    return
  end
  local ok, err = api.interrupt(state.session_id)
  if not ok then
    log.error("interrupt failed: " .. tostring(err))
  end
end

---Set up buffer-local keymaps and options for a new prompt buffer.
---@param buf integer
local function configure(buf)
  local bo = vim.bo[buf]
  bo.buflisted = false
  bo.swapfile = false
  bo.filetype = config.values.ui.input_filetype
  bo.buftype = "nofile"
  bo.bufhidden = "hide"
  bo.wrapmargin = 0
  bo.textwidth = 0

  local keys = config.values.keys
  local map = function(mode, lhs, rhs, desc)
    vim.keymap.set(mode, lhs, rhs, { buffer = buf, desc = desc, nowait = true })
  end

  local submit = function()
    M.submit()
  end

  -- Match OpenCode's TUI: Enter submits, modified Enter inserts a newline.
  map("i", keys.submit, submit, "ocmini: send prompt")
  map("i", "<C-s>", submit, "ocmini: send prompt")
  map("n", "<CR>", submit, "ocmini: send prompt")

  map("i", "<S-CR>", "<CR>", "ocmini: newline")
  map("i", "<C-CR>", "<CR>", "ocmini: newline")
  map("i", "<M-CR>", "<CR>", "ocmini: newline")
  vim.keymap.set("i", "/", function()
    local win = state.windows.input_win
    local cursor = win and nvim_api.nvim_win_get_cursor(win) or { 1, 0 }
    local row, col = cursor[1] - 1, cursor[2]
    local before = nvim_api.nvim_buf_get_lines(buf, 0, -1, false)
    local is_fresh_prompt = table.concat(before, ""):gsub("%s", "") == "" and col == 0
    nvim_api.nvim_buf_set_text(buf, row, col, row, col, { "/" })
    if win and nvim_api.nvim_win_is_valid(win) then
      pcall(nvim_api.nvim_win_set_cursor, win, { row + 1, col + 1 })
    end
    if is_fresh_prompt then
      vim.schedule(function()
        M.pick_command(buf, row, col)
      end)
    end
  end, { buffer = buf, nowait = true, desc = "ocmini: slash commands" })
  map("i", keys.interrupt, function()
    M.interrupt()
  end, "ocmini: interrupt")
  map("n", keys.interrupt, function()
    M.interrupt()
  end, "ocmini: interrupt")
  map("i", "<C-w>", "<C-u>", "ocmini: clear prompt")
  for _, mode in ipairs({"i", "n"}) do
    map(mode, "<C-p>", function()
      if mode == "i" and vim.fn.pumvisible() == 1 then
        nvim_api.nvim_feedkeys(nvim_api.nvim_replace_termcodes("<C-p>", true, false, true), "n", false)
      else require("ocmini.history").move(-1) end
    end, "ocmini: previous prompt")
    map(mode, "<C-n>", function()
      if mode == "i" and vim.fn.pumvisible() == 1 then
        nvim_api.nvim_feedkeys(nvim_api.nvim_replace_termcodes("<C-n>", true, false, true), "n", false)
      else require("ocmini.history").move(1) end
    end, "ocmini: next prompt")
    map(mode, "<M-v>", function() require("ocmini.images").paste() end, "ocmini: paste image")
  end
  _G.OcminiComplete = function(findstart, base) return require("ocmini.completion").complete(findstart, base) end
  bo.omnifunc = "v:lua.OcminiComplete"
  nvim_api.nvim_create_autocmd("CompleteDone", {
    buffer = buf,
    callback = function()
      local item = vim.v.completed_item
      if not item or not item.user_data or item.user_data == "" then return end
      local ok, data = pcall(vim.json.decode, item.user_data)
      if ok and data.path then
        M.pending_files = merge_files(M.pending_files, {{uri = vim.uri_from_fname(vim.fn.fnamemodify(data.path, ":p")), name = vim.fn.fnamemodify(data.path, ":t")}})
      end
    end,
  })
  map("i", "@", "@<C-x><C-o>", "ocmini: complete file or agent")
  map("i", "#", function() require("ocmini.context").pick() end, "ocmini: manage context")


end

---Replace the leading slash with a selected command, retaining the prompt focus.
function M.insert_command(buf, row, col, command)
  if not nvim_api.nvim_buf_is_valid(buf) then
    return
  end
  local line = nvim_api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
  if line:sub(col + 1, col + 1) == "/" then
    nvim_api.nvim_buf_set_text(buf, row, col, row, col + 1, { "/" .. command .. " " })
    local win = state.windows.input_win
    if win and nvim_api.nvim_win_is_valid(win) then
      pcall(nvim_api.nvim_win_set_cursor, win, { row + 1, col + #command + 2 })
    end
  end
  M.focus()
end

function M.execute_builtin(command, arguments)
  require("ocmini.actions").run(command, arguments or "")
end

function M.set_text(text)
  if not M.buf or not nvim_api.nvim_buf_is_valid(M.buf) then return end
  nvim_api.nvim_buf_set_lines(M.buf, 0, -1, false, vim.split(text, "\n", {plain = true}))
  local win = state.windows.input_win
  if win and nvim_api.nvim_win_is_valid(win) then
    local row = nvim_api.nvim_buf_line_count(M.buf)
    local line = nvim_api.nvim_buf_get_lines(M.buf,row-1,row,false)[1] or ""
    nvim_api.nvim_win_set_cursor(win,{row,#line})
  end
end

function M.run_builtin(buf, row, col, command)
  if nvim_api.nvim_buf_is_valid(buf) then
    local line = nvim_api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
    if line:sub(col + 1, col + 1) == "/" then
      nvim_api.nvim_buf_set_text(buf, row, col, row, col + 1, { "" })
    end
  end
  M.execute_builtin(command)
end

function M.pick_command(buf, row, col)
  require("ocmini.pickers").command({ buf = buf, row = row, col = col })
end

---Window-local display setup for the prompt float.
---@param win integer
function M.apply_window(win)
  if not win or not nvim_api.nvim_win_is_valid(win) then
    return
  end
  local wo = vim.wo[win]
  wo.wrap = true
  wo.linebreak = true
  wo.breakindent = false
  wo.showbreak = "NONE"
  wo.scrolloff = 0
  wo.sidescrolloff = 0
  wo.spell = false
  wo.number = false
  wo.relativenumber = false
  wo.signcolumn = "no"
  wo.statuscolumn = ""
  wo.colorcolumn = ""
  wo.foldcolumn = "0"
  wo.winbar = ""
  pcall(vim.api.nvim_win_set_option, win, "winhighlight", config.values.ui.window_highlight)
end

---Create the prompt window for the given geometry.
---@param geom table nvim_open_win config
---@return integer winid
function M.create(geom)
  if M.buf and nvim_api.nvim_buf_is_valid(M.buf) and state.windows.input_win
    and nvim_api.nvim_win_is_valid(state.windows.input_win)
  then
    require("ocmini.ui.panel").update(state.windows.input_win, geom)
    return state.windows.input_win
  end

  if not M.buf or not nvim_api.nvim_buf_is_valid(M.buf) then
    M.buf = nvim_api.nvim_create_buf(false, true)
    nvim_api.nvim_buf_set_name(M.buf, "ocmini://prompt")
    configure(M.buf)
  end

  local win = require("ocmini.ui.panel").open(M.buf, true, geom)
  state.windows.input_win = win
  M.apply_window(win)
  return win
end

function M.close()
  local windows = {}
  local win = state.windows.input_win
  if win then
    windows[win] = true
  end
  if M.buf and nvim_api.nvim_buf_is_valid(M.buf) then
    for _, attached in ipairs(nvim_api.nvim_list_wins()) do
      if nvim_api.nvim_win_get_buf(attached) == M.buf then
        windows[attached] = true
      end
    end
  end
  for attached in pairs(windows) do
    if nvim_api.nvim_win_is_valid(attached) then
      pcall(require("ocmini.ui.panel").close, attached)
    end
  end
  state.windows.input_win = nil
end

function M.destroy()
  M.close()
  if M.buf and nvim_api.nvim_buf_is_valid(M.buf) then
    pcall(nvim_api.nvim_buf_delete, M.buf, { force = true })
  end
  M.buf = nil
  M.pending_files = {}
end

---Focus the prompt window if it is open.
function M.focus()
  local win = state.windows.input_win
  if win and nvim_api.nvim_win_is_valid(win) then
    pcall(nvim_api.nvim_set_current_win, win)
    vim.cmd("startinsert")
  end
end

---Open a file picker for @-mentions and attach the selection to the next prompt.
function M.pick_mention()
  local results = api.find_files("", 200)
  if not results or #results == 0 then
    log.warn("no files found for mention")
    return
  end
  local items = {}
  for _, entry in ipairs(results) do
    if entry.type ~= "directory" and type(entry.path) == "string" and entry.path ~= "" then
      items[#items + 1] = { text = entry.path, path = entry.path }
    end
  end
  if #items == 0 then
    return
  end

  local snacks = require("snacks")
  -- Single-table form: Snacks' pick(source, opts) would read `items` as the
  -- source name. See ocmini.pickers.pick().
  snacks.picker.pick({
    source = "ocmini_mention",
    title = "Mention a file",
    items = items,
    cwd = true,
    format = function(item)
      return { { item.text, "Normal" } }
    end,
    confirm = function(picker, item)
      picker:close()
      local rel = vim.fn.fnamemodify(item.path, ":.")
      local win = state.windows.input_win
      if M.buf and nvim_api.nvim_buf_is_valid(M.buf) and win and nvim_api.nvim_win_is_valid(win) then
        M.pending_files[#M.pending_files + 1] = {
          uri = "file://" .. vim.fn.fnamemodify(item.path, ":p"):gsub("/$", ""),
          name = vim.fn.fnamemodify(item.path, ":t"),
        }
        -- Insert the mention at the cursor so the model sees the reference too.
        local ok, cur = pcall(nvim_api.nvim_win_get_cursor, win)
        local row = (ok and cur[1] or 1) - 1
        local col = ok and cur[2] or 0
        local line = nvim_api.nvim_buf_get_lines(M.buf, row, row + 1, false)[1] or ""
        local before, after = line:sub(1, col), line:sub(col + 1)
        nvim_api.nvim_buf_set_lines(M.buf, row, row + 1, false, { before .. "@" .. rel .. " " .. after })
        pcall(nvim_api.nvim_win_set_cursor, win, { row + 1, #before + #rel + 2 })
      end
    end,
  })
end

return M
