-- Floating workbench experiment (phase 2 prototype, NOT a plugin).
--
-- Supersedes the phase-1 winbar experiment (normal-window decoration, which
-- can only ever draw a top edge). Here the workbench is four independent
-- floating windows whose geometry is managed as one three-column layout:
--
--   ╭─ Explorer ─╮ ╭─ Editor ──────────────╮ ╭─ Claude ───╮
--   │            │ │                       │ │            │
--   │            │ ╰───────────────────────╯ │            │
--   │            │ ╭─ Terminal ────────────╮ │            │
--   │            │ │                       │ │            │
--   ╰────────────╯ ╰───────────────────────╯ ╰────────────╯
--
-- Explorer and Claude are full-height side panels; only the center column is
-- split (editor over terminal).
--
-- Architecture notes:
-- - One layout calculation (M.layout). VimResized/OptionSet re-run it.
-- - Editor float hosts the user's REAL buffer (same bufnr, so LSP/Treesitter/
--   completion/keymaps are untouched). It is marked `w:snacks_main`, which
--   Snacks' main-window finder always accepts, so stock explorer/picker
--   "open" lands in it without any custom confirm action.
-- - Explorer is a real Snacks explorer picker whose layout is a single float
--   root box sized from our geometry (having its own root box makes Snacks
--   skip the "sidebar" preset, so it never becomes a split).
-- - Terminal / Claude reuse the existing mechanisms (Snacks.terminal and
--   claudecode.nvim) to own the job; we only "adopt" their buffer into our
--   own float. Buffer-local terminal keymaps and claudecode's IDE connection
--   survive because the buffer is the same.
-- - A backdrop float (blank cells, Normal bg) hides the untouched base splits,
--   so disabling restores stock LazyVim exactly.
-- - Panels use zindex=40 so LSP/completion floats (>=50) render above them.
-- - wincmd h/j/k/l cannot reach floats, so M.nav() moves over the fixed grid.
--
-- Usage: :FloatbenchToggle (<leader>uW), :FloatbenchStatus,
--        :FloatbenchFocus {explorer,editor,terminal,claude}, :FloatbenchCycle

local M = {}

M.enabled = false

local AUG = "FloatbenchExperiment"

M.config = {
  left_frac = 0.18, -- explorer width fraction
  right_frac = 0.22, -- claude width fraction
  editor_frac = 0.75, -- editor share of center height (terminal gets the rest)
  gap = 0, -- cells between the three columns (0 = borders sit flush)
  vgap = 0, -- cells between editor and terminal (ignored when join_center)
  -- Editor + terminal share one divider line (├─ Terminal ─┤) instead of two
  -- stacked borders: a 0-cell vertical gap still reads ~2x wider than the
  -- column gaps, because cells are about twice as tall as they are wide.
  join_center = true,
  margin = 0, -- cells around the workbench
  z_backdrop = 5,
  z_panel = 40,
}

local S = {
  wins = {}, -- name -> winid {backdrop, editor, terminal, claude}
  bufs = {}, -- name -> bufnr (backdrop, claude_note)
  explorer = nil, -- Snacks picker object
  relayout_timer = nil,
  saved_keys = {}, -- "mode|lhs" -> maparg() dict (or false) shadowed while ON
  hidden = {}, -- name -> true for hidden side panels (terminal, claude)
}

local ORDER = { "explorer", "editor", "terminal", "claude" }

-- nvim border order: topleft, top, topright, right, botright, bottom, botleft,
-- left. "" drops that edge.
local BORDER_OPEN_BOTTOM = { "╭", "─", "╮", "│", "", "", "", "│" }
local BORDER_DIVIDER_TOP = { "├", "─", "┤", "│", "╯", "─", "╰", "│" }

local pin_explorer_z -- defined with the explorer helpers below

-- Fixed grid neighbours for M.nav().
local NAV = {
  editor = { h = "explorer", l = "claude", j = "terminal" },
  terminal = { h = "explorer", l = "claude", k = "editor" },
  explorer = { l = "editor" },
  claude = { h = "editor" },
}

---Usable screen area minus tabline/statusline/cmdline.
---@return integer cols, integer rows, integer top
local function screen_area()
  local cols, lines = vim.o.columns, vim.o.lines
  local top = (vim.o.showtabline == 2 or (vim.o.showtabline == 1 and #vim.api.nvim_list_tabpages() > 1)) and 1 or 0
  local bottom = ((vim.o.laststatus == 3 or vim.o.laststatus == 2) and 1 or 0) + vim.o.cmdheight
  return cols, lines - top - bottom, top
end

---Single layout calculation. Returns outer boxes {row, col, w, h} incl border.
function M.layout()
  local cfg = M.config
  local cols, rows, top = screen_area()
  local m, g = cfg.margin, cfg.gap
  local vg = cfg.join_center and 0 or cfg.vgap

  local hide_t, hide_c, hide_e = S.hidden.terminal, S.hidden.claude, S.hidden.explorer
  local join = cfg.join_center and not hide_t

  -- Hidden panels hand their space to the editor.
  local left_w = hide_e and 0 or math.max(math.floor(cols * cfg.left_frac), 20)
  local right_w = hide_c and 0 or math.max(math.floor(cols * cfg.right_frac), 24)
  local lg, rg = hide_e and 0 or g, hide_c and 0 or g
  local center_w = cols - left_w - right_w - 2 * m - lg - rg
  local full_h = rows - 2 * m
  local editor_h = hide_t and full_h or math.floor((full_h - vg) * cfg.editor_frac)
  local term_h = full_h - editor_h - vg

  local ex_col, ce_col, cl_col = m, m + left_w + lg, m + left_w + lg + center_w + rg
  return {
    cols = cols,
    rows = rows,
    top = top,
    explorer = { row = top + m, col = ex_col, w = left_w, h = full_h },
    editor = {
      row = top + m,
      col = ce_col,
      w = center_w,
      h = editor_h,
      border = join and BORDER_OPEN_BOTTOM or nil,
    },
    terminal = {
      row = top + m + editor_h + vg,
      col = ce_col,
      w = center_w,
      h = term_h,
      border = join and BORDER_DIVIDER_TOP or nil,
    },
    claude = { row = top + m, col = cl_col, w = right_w, h = full_h },
  }
end

---@param box table outer box
---@param title string
---@return table nvim_open_win config (content dims)
local function win_args(box, title)
  local border = box.border or "rounded"
  -- Outer box rows minus the border rows actually drawn (top/bottom edges).
  local edges = type(border) == "table" and ((border[2] ~= "" and 1 or 0) + (border[6] ~= "" and 1 or 0)) or 2
  return {
    relative = "editor",
    row = box.row,
    col = box.col,
    width = math.max(box.w - 2, 4),
    height = math.max(box.h - edges, 2),
    border = border,
    title = " " .. title .. " ",
    title_pos = "left",
    focusable = true,
    zindex = M.config.z_panel,
  }
end

---@param name string
---@return boolean
local function win_valid(name)
  return S.wins[name] ~= nil and vim.api.nvim_win_is_valid(S.wins[name])
end

---@return boolean
local function explorer_valid()
  return S.explorer ~= nil and not S.explorer.closed and S.explorer.layout ~= nil and S.explorer.layout:valid()
end

---@param buf integer
---@return string
local TITLES = { editor = "Editor", terminal = "Terminal", claude = "Claude" }

---@param name string
---@return string
local function title_for(name)
  return TITLES[name] or name
end

-- ── Editor tabs ──────────────────────────────────────────────────────────
-- VS Code-style tab row inside the editor float, drawn in its winbar. Order
-- is bufnr order, i.e. the same order <Tab>/<S-Tab> (:bnext/:bprev) walk.
-- The global bufferline is hidden while the workbench is ON (see open()).

local TABS_WINBAR = "%!v:lua.require'experiments.floatbench'.tabline()"

---Window-local only (like :setlocal): `vim.wo[win].winbar = ...` would also
---set the global default and leak the tab row into normal splits.
---@param win integer
local function set_tabs_winbar(win)
  local opt = { win = win, scope = "local" }
  if vim.api.nvim_get_option_value("winbar", opt) ~= TABS_WINBAR then
    vim.api.nvim_set_option_value("winbar", TABS_WINBAR, opt)
  end
end

---Drop the tab row from every window that picked it up (via buffer-saved
---window options) once the workbench is OFF.
local function clear_tabs_winbar()
  if vim.go.winbar == TABS_WINBAR then
    vim.go.winbar = ""
  end
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    local opt = { win = w, scope = "local" }
    if vim.api.nvim_get_option_value("winbar", opt) == TABS_WINBAR then
      vim.api.nvim_set_option_value("winbar", "", opt)
    end
  end
end

---@return integer[] listed buffers in :bnext order
local function tab_bufs()
  return vim.tbl_map(function(info)
    return info.bufnr
  end, vim.fn.getbufinfo({ buflisted = 1 }))
end

---Icon highlight on the active tab's background, created on demand.
---@param hl string
---@return string
local function active_icon_hl(hl)
  local name = "FloatbenchTabIcon_" .. hl
  if vim.fn.hlexists(name) == 0 then
    local fg = vim.api.nvim_get_hl(0, { name = hl, link = false }).fg
    local bg = vim.api.nvim_get_hl(0, { name = "FloatbenchTabActive", link = false }).bg
    vim.api.nvim_set_hl(0, name, { fg = fg, bg = bg })
  end
  return name
end

---@param buf integer
---@param tails table<string, integer> tail -> count, for disambiguation
---@return string label, string icon, string icon_hl
local function tab_label(buf, tails)
  local path = vim.api.nvim_buf_get_name(buf)
  local tail = vim.fn.fnamemodify(path, ":t")
  local label = tail ~= "" and tail or "[No Name]"
  if tail ~= "" and (tails[tail] or 0) > 1 then
    label = vim.fn.fnamemodify(path, ":h:t") .. "/" .. tail
  end
  local icon, icon_hl = "", "FloatbenchTab"
  local ok, MiniIcons = pcall(require, "mini.icons")
  if ok and tail ~= "" then
    local i, h = MiniIcons.get("file", tail)
    icon, icon_hl = i .. " ", h
  end
  return label, icon, icon_hl
end

---winbar expression for the editor float.
---@return string
function M.tabline()
  local win = vim.g.statusline_winid
  if not win or not vim.api.nvim_win_is_valid(win) then
    return ""
  end
  local cur = vim.api.nvim_win_get_buf(win)
  local bufs = tab_bufs()
  local tails = {}
  for _, b in ipairs(bufs) do
    local t = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(b), ":t")
    tails[t] = (tails[t] or 0) + 1
  end

  local tabs, active = {}, nil
  for _, b in ipairs(bufs) do
    local label, icon, icon_hl = tab_label(b, tails)
    local is_cur = b == cur
    local hl = is_cur and "%#FloatbenchTabActive#" or "%#FloatbenchTab#"
    local ihl = is_cur and active_icon_hl(icon_hl) or icon_hl
    local mark = vim.bo[b].modified and "%#FloatbenchTabModified" .. (is_cur and "Active" or "") .. "#●"
      or (
        (is_cur and "%#FloatbenchTabCloseActive#" or "%#FloatbenchTabClose#")
        .. "%"
        .. b
        .. "@v:lua.FloatbenchTabClose@×%X"
      )
    local text = ("%" .. b .. "@v:lua.FloatbenchTabClick@")
      .. hl
      .. "  "
      .. "%#"
      .. ihl
      .. "#"
      .. icon
      .. hl
      .. label:gsub("%%", "%%%%")
      .. " %X"
      .. mark
      .. hl
      .. " "
    tabs[#tabs + 1] = { text = text, width = vim.fn.strdisplaywidth("  " .. icon .. label .. " ● ") }
    if is_cur then
      active = #tabs
    end
  end

  -- No listed buffers (e.g. the editor shows an unlisted scratch/help buffer
  -- after the last file was closed): just an empty tab row.
  if #tabs == 0 then
    return "%#FloatbenchTabFill#"
  end

  -- Too many tabs: keep a window of tabs around the active one.
  local avail = vim.api.nvim_win_get_width(win)
  local first, last = active or 1, active or 1
  local used = tabs[first] and tabs[first].width or 0
  while true do
    local grew = false
    if last < #tabs and used + tabs[last + 1].width <= avail then
      last, used, grew = last + 1, used + tabs[last + 1].width, true
    end
    if first > 1 and used + tabs[first - 1].width <= avail then
      first, used, grew = first - 1, used + tabs[first - 1].width, true
    end
    if not grew then
      break
    end
  end
  local out = {}
  for i = first, last do
    out[#out + 1] = tabs[i].text
  end
  return table.concat(out) .. "%#FloatbenchTabFill#"
end

---Tab click: left = show buffer in the editor, middle = close it.
_G.FloatbenchTabClick = function(buf, _, button)
  if button == "m" then
    return _G.FloatbenchTabClose(buf)
  end
  if win_valid("editor") and vim.api.nvim_buf_is_valid(buf) then
    vim.api.nvim_set_current_win(S.wins.editor)
    vim.api.nvim_win_set_buf(S.wins.editor, buf)
  end
end

_G.FloatbenchTabClose = function(buf)
  if vim.api.nvim_buf_is_valid(buf) then
    Snacks.bufdelete({ buf = buf })
  end
end

---Hide the global bufferline while ON (the tabs live in the editor now) and
---stop it from re-showing itself; restore_bufferline() undoes both.
local function hide_bufferline()
  local ok, cfg = pcall(require, "bufferline.config")
  S.saved_tabline = {
    showtabline = vim.o.showtabline,
    auto = ok and cfg.options and cfg.options.auto_toggle_bufferline,
  }
  if ok and cfg.options then
    cfg.options.auto_toggle_bufferline = false
  end
  vim.o.showtabline = 0
end

local function restore_bufferline()
  local saved = S.saved_tabline
  if not saved then
    return
  end
  S.saved_tabline = nil
  local ok, cfg = pcall(require, "bufferline.config")
  if ok and cfg.options and saved.auto ~= nil then
    cfg.options.auto_toggle_bufferline = saved.auto
  end
  -- With auto-toggle back on, bufferline decides again on its next redraw.
  vim.o.showtabline = saved.showtabline
end

-- ── Styling ──────────────────────────────────────────────────────────────

local function set_highlights()
  local ok, p = pcall(require, "rose-pine.palette")
  if not ok or type(p) ~= "table" then
    p = { highlight_med = "#403d52", muted = "#6e6a86", subtle = "#908caa", text = "#e0def4" }
  end
  -- Panel bg follows Normal: transparent under rose-pine transparency=true,
  -- opaque base otherwise. Blank backdrop cells hide the splits either way.
  vim.api.nvim_set_hl(0, "FloatbenchPanel", { link = "Normal" })
  vim.api.nvim_set_hl(0, "FloatbenchBackdrop", { link = "Normal" })
  vim.api.nvim_set_hl(0, "FloatbenchBorder", { fg = p.highlight_med })
  vim.api.nvim_set_hl(0, "FloatbenchTitle", { fg = p.subtle })
  vim.api.nvim_set_hl(0, "FloatbenchBorderActive", { fg = p.muted })
  vim.api.nvim_set_hl(0, "FloatbenchTitleActive", { fg = p.text, bold = true })
  -- Editor tabs: flat, muted inactive tabs; the active one gets a surface bg.
  local tab_bg = p.surface or "#1f1d2e"
  vim.api.nvim_set_hl(0, "FloatbenchTabFill", { link = "FloatbenchPanel" })
  vim.api.nvim_set_hl(0, "FloatbenchTab", { fg = p.muted })
  vim.api.nvim_set_hl(0, "FloatbenchTabActive", { fg = p.text, bg = tab_bg, bold = true })
  vim.api.nvim_set_hl(0, "FloatbenchTabClose", { fg = p.highlight_med })
  vim.api.nvim_set_hl(0, "FloatbenchTabCloseActive", { fg = p.subtle, bg = tab_bg })
  vim.api.nvim_set_hl(0, "FloatbenchTabModified", { fg = p.gold or "#f6c177" })
  vim.api.nvim_set_hl(0, "FloatbenchTabModifiedActive", { fg = p.gold or "#f6c177", bg = tab_bg })
  -- Icon groups are derived from the active bg; rebuild them lazily.
  for _, name in ipairs(vim.fn.getcompletion("FloatbenchTabIcon_", "highlight")) do
    vim.api.nvim_set_hl(0, name, {})
  end
end

---@param active boolean
---@return string winhighlight value for a panel float
local function panel_whl(active)
  local sfx = active and "Active" or ""
  return table.concat({
    "Normal:FloatbenchPanel",
    "NormalNC:FloatbenchPanel",
    "NormalFloat:FloatbenchPanel",
    "FloatBorder:FloatbenchBorder" .. sfx,
    "FloatTitle:FloatbenchTitle" .. sfx,
    "WinBar:FloatbenchTabFill",
    "WinBarNC:FloatbenchTabFill",
  }, ",")
end

---Border/title-only mapping for the Snacks box window (its content windows
---keep Snacks' own highlights).
---@param active boolean
local function explorer_whl(active)
  local sfx = active and "Active" or ""
  return "Normal:FloatbenchPanel,NormalFloat:FloatbenchPanel,FloatBorder:FloatbenchBorder"
    .. sfx
    .. ",FloatTitle:FloatbenchTitle"
    .. sfx
end

---@param win integer
---@param value string
local function set_whl(win, value)
  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_set_option_value("winhighlight", value, { win = win, scope = "local" })
  end
end

---Which panel does a window belong to?
---@param win integer
---@return string?
local function panel_of(win)
  for name, w in pairs(S.wins) do
    if w == win and name ~= "backdrop" then
      return name
    end
  end
  if explorer_valid() then
    for _, sw in pairs(S.explorer.layout.wins) do
      if sw.win == win then
        return "explorer"
      end
    end
  end
end

local function refresh_active()
  if not M.enabled then
    return
  end
  local active = panel_of(vim.api.nvim_get_current_win())
  for _, name in ipairs({ "editor", "terminal", "claude" }) do
    if win_valid(name) then
      set_whl(S.wins[name], panel_whl(active == name))
    end
  end
  if explorer_valid() then
    local root = S.explorer.layout.root
    local whl = explorer_whl(active == "explorer")
    root.opts.wo.winhighlight = whl -- survive Snacks layout updates
    set_whl(root.win, whl)
    -- The search box border uses the same subtle panel border color.
    local input = S.explorer.input and S.explorer.input.win
    if input and input:win_valid() then
      local merged = Snacks.util.winhl(vim.wo[input.win].winhighlight, { FloatBorder = "FloatbenchBorder" })
      local parts = {}
      for k, v in pairs(merged) do
        parts[#parts + 1] = k .. ":" .. v
      end
      input.opts.wo.winhighlight = table.concat(parts, ",")
      set_whl(input.win, input.opts.wo.winhighlight)
    end
  end
end

-- ── Panels ───────────────────────────────────────────────────────────────

---Show `buf` in our float for `name`: any other window showing it (e.g. the
---plugin's own split) is closed first; the buffer and its job survive
---because terminal buffers are bufhidden=hide.
---@param name string
---@param buf integer
local function adopt(name, buf)
  local cfg = win_args(M.layout()[name], title_for(name))
  if win_valid(name) then
    if vim.api.nvim_win_get_buf(S.wins[name]) ~= buf then
      vim.api.nvim_win_set_buf(S.wins[name], buf)
    end
    vim.api.nvim_win_set_config(S.wins[name], cfg)
    return
  end
  for _, w in ipairs(vim.fn.win_findbuf(buf)) do
    if #vim.api.nvim_tabpage_list_wins(0) > 1 then
      pcall(vim.api.nvim_win_close, w, false)
    end
  end
  S.wins[name] = vim.api.nvim_open_win(buf, false, cfg)
  set_whl(S.wins[name], panel_whl(false))
end

---@param buf integer
---@return boolean
local function is_claude_buf(buf)
  local t = vim.b[buf].snacks_terminal
  return type(t) == "table" and vim.inspect(t.cmd or ""):lower():find("claude", 1, true) ~= nil
end

---@return integer? bufnr of the reusable shell terminal (never the Claude one)
local function shell_terminal_buf()
  local Snacks = require("snacks")
  for _, t in ipairs(Snacks.terminal.list()) do
    if t:buf_valid() and not is_claude_buf(t.buf) then
      return t.buf
    end
  end
  -- None yet: create through the same path as <leader>t, directly at the
  -- terminal box so there is no visible flash before we adopt it.
  local box = M.layout().terminal
  local t = Snacks.terminal.get(nil, {
    cwd = LazyVim.root(),
    shell = vim.env.SHELL or vim.o.shell,
    create = true,
    start_insert = false,
    win = {
      position = "float",
      row = box.row,
      col = box.col,
      width = box.w - 2,
      height = box.h - 2,
      border = "rounded",
      zindex = M.config.z_panel,
      enter = false,
      wo = { winbar = "" },
    },
  })
  if not (t and t:buf_valid()) then
    return nil
  end
  -- It was created as a float only to avoid a flash before we adopt it; give
  -- it the stock <leader>t split settings back, so after the workbench is OFF
  -- <leader>t shows it as the normal bottom split, not a stray float.
  local o = t.opts
  o.position, o.relative, o.height, o.width = "bottom", "win", 0.3, 0.4
  o.win, o.row, o.col, o.border, o.zindex, o.enter = nil, nil, nil, nil, nil, nil
  return t.buf
end

---@return integer? bufnr of the claudecode.nvim terminal
local function claude_buf()
  local ok, term = pcall(require, "claudecode.terminal")
  if not ok then
    return nil
  end
  local buf = term.get_active_terminal_bufnr()
  if buf and vim.api.nvim_buf_is_valid(buf) then
    return buf
  end
  -- Start Claude through claudecode (keeps the IDE/MCP connection), placed
  -- at the claude box so it does not flash as a split first.
  local box = M.layout().claude
  pcall(term.open, {
    snacks_win_opts = {
      position = "float",
      row = box.row,
      col = box.col,
      width = box.w - 2,
      height = box.h - 2,
      border = "rounded",
      zindex = M.config.z_panel,
    },
  })
  buf = term.get_active_terminal_bufnr()
  return buf and vim.api.nvim_buf_is_valid(buf) and buf or nil
end

---@return integer note buffer shown when Claude is unavailable
local function claude_note_buf()
  local buf = S.bufs.claude_note
  if buf == nil or not vim.api.nvim_buf_is_valid(buf) then
    buf = vim.api.nvim_create_buf(false, true)
    S.bufs.claude_note = buf
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "",
      "  claudecode.nvim / `claude` CLI unavailable.",
      "  Fix it, then :FloatbenchToggle twice.",
    })
  end
  return buf
end

local function explorer_layout()
  local box = M.layout().explorer
  return {
    backdrop = false, -- we own the backdrop
    layout = {
      row = box.row,
      col = box.col,
      width = math.max(box.w - 2, 10),
      height = math.max(box.h - 2, 5),
      zindex = M.config.z_panel,
      border = "rounded",
      title = " Explorer ",
      title_pos = "left",
      box = "vertical",
      -- Search input in its own rounded box, like the stock sidebar layout.
      { win = "input", height = 1, border = "rounded" },
      { win = "list", border = "none" },
    },
  }
end

---Snacks.layout lifts itself above any float that is up when it is built
---(e.g. noice's z=60 LSP progress), which would put the explorer over hover/
---completion popups. The picker rebuilds its layout on resize, so this runs
---after every open and relayout to pin it back to the panel layer.
pin_explorer_z = function()
  local layout = explorer_valid() and S.explorer.layout or nil
  if not layout or layout.opts.layout.zindex == M.config.z_panel then
    return
  end
  layout.opts.layout.zindex = M.config.z_panel
  for _, bw in pairs(layout.box_wins) do
    bw.opts.zindex = M.config.z_panel
    if bw:win_valid() then
      vim.api.nvim_win_set_config(bw.win, { zindex = M.config.z_panel })
    end
  end
  layout:update()
end

---Open the explorer as a Snacks picker float sized from our geometry.
local function show_explorer()
  local Snacks = require("snacks")
  S.explorer = Snacks.explorer({
    cwd = LazyVim.root(),
    preview = false,
    prompt = " / ", -- search-box prompt with a left pad (stock is a ">" chevron)
    focus = false, -- keep focus in the editor on open
    layout = explorer_layout(),
    -- <Esc> (or q) closes the Snacks explorer: treat it as a hidden panel so
    -- the editor takes the column; <leader>e / <C-h> bring it back.
    on_close = function(picker)
      if M.enabled and S.explorer == picker then
        S.explorer = nil
        S.hidden.explorer = true
        vim.schedule(M.relayout)
      end
    end,
    on_show = function(picker)
      S.explorer = S.explorer or picker
      if S.focus_explorer_on_show then
        S.focus_explorer_on_show = nil
        picker:focus("list")
      end
      pin_explorer_z()
      refresh_active()
    end,
  })
end

---Close every stock (non-workbench) explorer, e.g. the sidebar split.
local function close_stock_explorers()
  for _, p in ipairs(require("snacks").picker.get({ source = "explorer" })) do
    if p ~= S.explorer then
      pcall(function()
        p:close()
      end)
    end
  end
end

-- ── Focus ────────────────────────────────────────────────────────────────

---@param name string explorer|editor|terminal|claude
function M.focus(name)
  if not M.enabled then
    vim.notify("Floatbench is off", vim.log.levels.WARN)
    return
  end
  if name == "explorer" then
    if not explorer_valid() then
      if S.hidden.explorer then
        S.hidden.explorer = nil
        M.relayout() -- shrink the editor back first
      end
      if win_valid("editor") then
        vim.api.nvim_set_current_win(S.wins.editor)
      end
      S.focus_explorer_on_show = true -- a fresh picker shows asynchronously
      show_explorer()
      return
    end
    pcall(function()
      S.explorer:focus("list")
    end)
    return
  end
  if S.hidden[name] then
    M.show(name)
  end
  if win_valid(name) then
    vim.api.nvim_set_current_win(S.wins[name])
  else
    vim.notify("Floatbench: no " .. name .. " panel", vim.log.levels.WARN)
  end
end

-- ── Hide / show side panels ──────────────────────────────────────────────
-- Terminal and Claude can be hidden: the float closes, the editor grows into
-- the space, and the buffer (and its job) keeps running for the next show.

local HIDEABLE = { terminal = true, claude = true }

---@param name string terminal|claude
function M.hide(name)
  if not M.enabled or not HIDEABLE[name] or not win_valid(name) then
    return
  end
  local win = S.wins[name]
  S.wins[name] = nil -- before closing, so WinClosed doesn't treat it as :q
  S.hidden[name] = true
  if vim.api.nvim_get_current_win() == win and win_valid("editor") then
    vim.api.nvim_set_current_win(S.wins.editor)
  end
  pcall(vim.api.nvim_win_close, win, false)
  M.relayout()
  refresh_active()
end

---@param name string terminal|claude
function M.show(name)
  if not M.enabled or not HIDEABLE[name] or win_valid(name) then
    return
  end
  S.hidden[name] = nil
  M.relayout() -- shrink the editor first so the panel has room
  local buf = name == "terminal" and shell_terminal_buf() or claude_buf() or claude_note_buf()
  if buf then
    adopt(name, buf)
  end
  refresh_active()
end

---<leader>t / <leader>ac: show+focus when hidden, hide when already in it,
---otherwise focus it.
---@param name string terminal|claude
function M.toggle_panel(name)
  if S.hidden[name] or not win_valid(name) then
    M.focus(name)
  elseif vim.api.nvim_get_current_win() == S.wins[name] then
    M.hide(name)
  else
    M.focus(name)
  end
end

---Hide whichever panel shows `buf` (used by the terminal <C-/> key).
---@param buf integer
---@return boolean handled
function M.hide_buf(buf)
  for name in pairs(HIDEABLE) do
    if win_valid(name) and vim.api.nvim_win_get_buf(S.wins[name]) == buf then
      M.hide(name)
      return true
    end
  end
  return false
end

---Move focus to the grid neighbour in direction h/j/k/l.
---@param dir string
---Panel reachable from the current one in direction h/j/k/l, if any.
---@param dir string
---@return string?
function M.nav_target(dir)
  local cur = panel_of(vim.api.nvim_get_current_win()) or "editor"
  local target = (NAV[cur] or {})[dir]
  return target and not S.hidden[target] and target or nil
end

function M.nav(dir)
  local target = M.nav_target(dir)
  if target then
    M.focus(target)
  end
end

function M.cycle()
  local cur = panel_of(vim.api.nvim_get_current_win())
  local idx = 0
  for i, name in ipairs(ORDER) do
    if name == cur then
      idx = i
    end
  end
  M.focus(ORDER[idx % #ORDER + 1])
end

---Editor window, if the workbench is on (used by config/keymaps.lua).
---@return integer?
function M.editor_win()
  return M.enabled and win_valid("editor") and S.wins.editor or nil
end

---Shadow a global mapping while the workbench is ON; restored by close().
local function shadow(mode, lhs, rhs, desc)
  local key = mode .. "|" .. lhs
  if S.saved_keys[key] == nil then
    local saved = vim.fn.maparg(lhs, mode, false, true)
    S.saved_keys[key] = next(saved) ~= nil and saved or false
  end
  vim.keymap.set(mode, lhs, rhs, { desc = "Floatbench: " .. desc, silent = true })
end

local function shadow_keys()
  for dir, desc in pairs({ h = "left", j = "down", k = "up", l = "right" }) do
    shadow("n", "<C-" .. dir .. ">", function()
      M.nav(dir)
    end, "panel " .. desc)
  end
  for _, lhs in ipairs({ "<leader>e", "<leader>E" }) do
    shadow("n", lhs, function()
      M.focus("explorer")
    end, "focus explorer")
  end
  shadow("n", "<leader>ac", function()
    M.toggle_panel("claude")
  end, "toggle claude")
  shadow("n", "<leader>af", function()
    M.focus("claude")
  end, "focus claude")
end

local function restore_keys()
  for key, saved in pairs(S.saved_keys) do
    local mode, lhs = key:match("^(.-)|(.*)$")
    pcall(vim.keymap.del, mode, lhs)
    if saved then
      pcall(vim.fn.mapset, mode, false, saved)
    end
  end
  S.saved_keys = {}
end

-- ── Lifecycle ────────────────────────────────────────────────────────────

---Largest normal split holding a file buffer: its buffer seeds the editor.
---@return integer win
local function base_main_win()
  local best, area = vim.api.nvim_get_current_win(), -1
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local b = vim.api.nvim_win_get_buf(w)
    if vim.api.nvim_win_get_config(w).relative == "" and not vim.w[w].snacks_layout and vim.bo[b].buftype == "" then
      local a = vim.api.nvim_win_get_width(w) * vim.api.nvim_win_get_height(w)
      if a > area then
        best, area = w, a
      end
    end
  end
  return best
end

function M.open()
  if M.enabled then
    M.relayout()
    return
  end
  local geo = M.layout()
  if geo.editor.w < 30 or geo.editor.h < 8 then
    vim.notify("Floatbench: screen too small", vim.log.levels.WARN)
    return
  end
  M.enabled = true
  set_highlights()
  hide_bufferline()
  geo = M.layout() -- the tabline row is free now

  local base = base_main_win()
  S.base_win = base
  close_stock_explorers()

  -- Backdrop covers exactly the content area (tabline/statusline stay).
  local back = S.bufs.backdrop
  if back == nil or not vim.api.nvim_buf_is_valid(back) then
    back = vim.api.nvim_create_buf(false, true)
    S.bufs.backdrop = back
  end
  S.wins.backdrop = vim.api.nvim_open_win(back, false, {
    relative = "editor",
    row = geo.top,
    col = 0,
    width = geo.cols,
    height = geo.rows,
    style = "minimal",
    focusable = false,
    zindex = M.config.z_backdrop,
  })
  set_whl(S.wins.backdrop, "Normal:FloatbenchBackdrop,NormalFloat:FloatbenchBackdrop")

  -- Editor hosts the REAL buffer. Enter it while opening so the float
  -- inherits the base window's options (number, signcolumn, ...).
  vim.api.nvim_set_current_win(base)
  S.wins.editor = vim.api.nvim_open_win(vim.api.nvim_win_get_buf(base), true, win_args(geo.editor, "Editor"))
  vim.w[S.wins.editor].snacks_main = true
  set_tabs_winbar(S.wins.editor)
  vim.api.nvim_win_set_config(S.wins.editor, win_args(geo.editor, title_for("editor")))
  set_whl(S.wins.editor, panel_whl(true))

  -- Explorer before the other panels: Snacks stacks new layouts above any
  -- existing float (Snacks.win.zindex), so opening it now keeps it at z=40.
  show_explorer()

  local tbuf = shell_terminal_buf()
  if tbuf then
    adopt("terminal", tbuf)
  end
  adopt("claude", claude_buf() or claude_note_buf())

  vim.api.nvim_set_current_win(S.wins.editor)
  vim.cmd.stopinsert()
  shadow_keys()

  local group = vim.api.nvim_create_augroup(AUG, { clear = true })
  vim.api.nvim_create_autocmd("VimResized", {
    group = group,
    callback = function()
      if S.relayout_timer then
        vim.fn.timer_stop(S.relayout_timer)
      end
      S.relayout_timer = vim.fn.timer_start(50, function()
        S.relayout_timer = nil
        vim.schedule(M.relayout)
      end)
    end,
    desc = "Floatbench: relayout after resize",
  })
  vim.api.nvim_create_autocmd("OptionSet", {
    group = group,
    pattern = { "showtabline", "laststatus", "cmdheight" },
    callback = function()
      vim.schedule(M.relayout)
    end,
    desc = "Floatbench: relayout when reserved rows change",
  })
  vim.api.nvim_create_autocmd("BufWinEnter", {
    group = group,
    callback = function()
      -- winbar is window-local but a buffer can bring its own saved value
      -- for this window; keep the tab row on the editor regardless.
      if win_valid("editor") then
        set_tabs_winbar(S.wins.editor)
      end
    end,
    desc = "Floatbench: keep editor tab row",
  })
  vim.api.nvim_create_autocmd("WinEnter", {
    group = group,
    callback = function()
      vim.schedule(refresh_active)
    end,
    desc = "Floatbench: highlight focused panel",
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    callback = function(ev)
      -- Terminal/Claude closed from the outside (:q, job exit) just become
      -- hidden panels; closing the editor tears the whole workbench down.
      local closed = tonumber(ev.match)
      for _, name in ipairs({ "terminal", "claude" }) do
        if S.wins[name] == closed then
          S.wins[name] = nil
          S.hidden[name] = true
          vim.schedule(M.relayout)
          return
        end
      end
      for _, name in ipairs({ "editor" }) do
        if S.wins[name] == closed then
          S.wins[name] = nil
          vim.schedule(function()
            if M.enabled then
              M.close()
              vim.notify("Floatbench: " .. name .. " panel closed, workbench off", vim.log.levels.INFO)
            end
          end)
          return
        end
      end
    end,
    desc = "Floatbench: hide closed side panels, teardown if editor closes",
  })
end

---Recompute geometry and move/resize every panel in place.
function M.relayout()
  if not M.enabled then
    return
  end
  local geo = M.layout()
  if win_valid("backdrop") then
    vim.api.nvim_win_set_config(S.wins.backdrop, {
      relative = "editor",
      row = geo.top,
      col = 0,
      width = geo.cols,
      height = geo.rows,
    })
  end
  for _, name in ipairs({ "editor", "terminal", "claude" }) do
    if win_valid(name) then
      vim.api.nvim_win_set_config(S.wins[name], win_args(geo[name], title_for(name)))
    end
  end
  -- Snacks layouts deep-copy opts.layout on every update, so mutating the
  -- root box and calling update() resizes the explorer without reopening.
  if explorer_valid() then
    local root = S.explorer.layout.opts.layout
    local fresh = explorer_layout().layout
    root.row, root.col, root.width, root.height = fresh.row, fresh.col, fresh.width, fresh.height
    S.explorer.layout:update()
    pin_explorer_z()
  end
end

function M.close()
  if not M.enabled then
    return
  end
  M.enabled = false
  pcall(vim.api.nvim_del_augroup_by_name, AUG)
  if S.relayout_timer then
    pcall(vim.fn.timer_stop, S.relayout_timer)
    S.relayout_timer = nil
  end
  -- Continue where you were: the base split takes the editor's buffer.
  local ebuf = win_valid("editor") and vim.api.nvim_win_get_buf(S.wins.editor) or nil
  if S.explorer then
    pcall(function()
      S.explorer:close()
    end)
    S.explorer = nil
  end
  for _, name in ipairs({ "editor", "terminal", "claude", "backdrop" }) do
    if win_valid(name) then
      pcall(vim.api.nvim_win_close, S.wins[name], true)
    end
    S.wins[name] = nil
  end
  restore_keys()
  restore_bufferline()
  S.hidden = {} -- next open shows every panel again
  local base = S.base_win
  if base and vim.api.nvim_win_is_valid(base) then
    if ebuf and vim.api.nvim_buf_is_valid(ebuf) and vim.bo[ebuf].buftype == "" then
      pcall(vim.api.nvim_win_set_buf, base, ebuf)
    end
    pcall(vim.api.nvim_set_current_win, base)
  end
  clear_tabs_winbar()
  -- Terminal/Claude buffers persist (jobs keep running) for instant reopen.
end

function M.toggle()
  if M.enabled then
    M.close()
    vim.notify("Floatbench: OFF", vim.log.levels.INFO)
  else
    M.open()
    if M.enabled then
      vim.notify("Floatbench: ON", vim.log.levels.INFO)
    end
  end
end

function M.status()
  local lines = { "floatbench " .. (M.enabled and "ON" or "OFF") }
  local geo = M.layout()
  table.insert(lines, string.format("screen %dx%d (top=%d)", geo.cols, geo.rows, geo.top))
  local function describe(name, win)
    local conf = vim.api.nvim_win_get_config(win)
    local title = conf.title
    if type(title) == "table" then
      title = table.concat(vim.tbl_map(function(c)
        return c[1]
      end, title))
    end
    return string.format(
      "%-9s win=%-5d rel=%s border=%s title=%q %dx%d @%s,%s z=%s",
      name,
      win,
      conf.relative,
      type(conf.border) == "table" and (conf.border[1] or "?") or tostring(conf.border),
      tostring(title or ""),
      conf.width,
      conf.height,
      tostring(conf.row),
      tostring(conf.col),
      tostring(conf.zindex)
    )
  end
  for _, name in ipairs({ "backdrop", "editor", "terminal", "claude" }) do
    if win_valid(name) then
      table.insert(lines, describe(name, S.wins[name]))
    else
      table.insert(lines, name .. ": --")
    end
  end
  if explorer_valid() then
    table.insert(lines, describe("explorer", S.explorer.layout.root.win))
  else
    table.insert(lines, "explorer: --")
  end
  vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO, { title = "Floatbench" })
  return lines
end

return M
