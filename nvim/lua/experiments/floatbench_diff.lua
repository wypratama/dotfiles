-- Floatbench adapter for diffview.nvim (experiment, only active while the
-- floating workbench in experiments/floatbench.lua is ON).
--
-- Diffview opens its own tabpage built from normal splits. This re-homes that
-- tab into the workbench slots:
--
--   ╭ Changes ─╮╭ Original ───╮╭ Modified ───╮╭ Claude ─╮
--   │ files    ││  diff a     ││  diff b     ││         │
--   │          │╰─────────────╯╰─────────────╯│         │
--   │          │╭ Terminal / Result (merge) ─╮│         │
--   ╰──────────╯╰────────────────────────────╯╰─────────╯
--
-- - File panel -> Explorer slot: Diffview supports a float panel natively, so
--   its win_config producer (plugins/diffview.lua) asks panel_config().
-- - Diff windows -> Editor slot, side by side. They are Diffview's own window
--   ids converted in place with nvim_win_set_config, so Diffview keeps
--   working; re-applied whenever it (re)builds its layout.
-- - Merge conflicts (3/4-way layouts): the Result window goes to the Terminal
--   slot. Otherwise the running shell and Claude are shown in their slots
--   (the same buffers as the workbench tab).
-- - A tab needs one normal split, so a hidden anchor split sits under a
--   backdrop; Diffview also splits off it when it rebuilds its layout.
--
-- Diffview sets its own 'winhighlight' (diff colors) on the diff windows, so
-- border/title groups are merged into it instead of replacing it.

local M = {}

local api = vim.api
local AUG = "FloatbenchDiff"

---@type table<integer, {anchor?: integer, backdrop?: integer, terminal?: integer, claude?: integer, panels: integer[]}>
local T = {} -- tabpage -> adapter state
local timer, applying = nil, false

local function fb()
  local m = package.loaded["experiments.floatbench"]
  return m and m.enabled and m or nil
end

local function valid(win)
  return win ~= nil and api.nvim_win_is_valid(win)
end

local function current_view()
  local ok, lib = pcall(require, "diffview.lib")
  return ok and lib.get_current_view() or nil
end

---Is the current tab a Diffview tab styled by this adapter?
function M.owns_tab()
  return fb() ~= nil and T[api.nvim_get_current_tabpage()] ~= nil
end

---Geometry for the Diffview tab: every slot shown except Claude/Terminal
---when the workbench has them hidden (a merge result forces the Terminal).
local function geometry(conflict)
  local f = fb()
  return f.layout({ explorer = true, terminal = conflict })
end

---win_config producer for Diffview's file panel (see plugins/diffview.lua).
---@param default table split config used when the workbench is off
function M.panel_config(default)
  local f = fb()
  if not f then
    return default
  end
  local box = geometry(false).explorer
  return {
    type = "float",
    relative = "editor",
    row = box.row,
    col = box.col,
    width = math.max(box.w - 2, 10),
    height = math.max(box.h - 2, 5),
    border = "rounded",
    zindex = f.config.z_panel,
  }
end

---Merge `extra` ("Group:Target,...") into a window's own winhighlight.
local function merge_whl(win, extra)
  local opt = { win = win, scope = "local" }
  local map = {}
  for _, value in ipairs({ api.nvim_get_option_value("winhighlight", opt), extra }) do
    for part in value:gmatch("[^,]+") do
      local k, v = part:match("^%s*(.-):(.-)%s*$")
      if k then
        map[k] = v
      end
    end
  end
  local out = {}
  for k, v in pairs(map) do
    out[#out + 1] = k .. ":" .. v
  end
  table.sort(out)
  api.nvim_set_option_value("winhighlight", table.concat(out, ","), opt)
end

---Rounded box (the diff tab doesn't use the shared editor/terminal divider).
local function rounded(box)
  return { row = box.row, col = box.col, w = box.w, h = box.h }
end

---Put `win` (split or float) at `box` with a titled rounded border.
local function place(st, win, box, title)
  local f = fb()
  api.nvim_win_set_config(win, f.ui.win_args(rounded(box), title))
  merge_whl(win, f.ui.panel_whl(api.nvim_get_current_win() == win))
  st.panels[#st.panels + 1] = win
end

---Float showing `buf` for this tab (e.g. the running shell / Claude).
local function show_buf(st, key, buf, box, title)
  if not buf then
    if valid(st[key]) then
      pcall(api.nvim_win_close, st[key], true)
    end
    st[key] = nil
    return
  end
  local f = fb()
  local cfg = f.ui.win_args(rounded(box), title)
  if valid(st[key]) then
    if api.nvim_win_get_buf(st[key]) ~= buf then
      api.nvim_win_set_buf(st[key], buf)
    end
    api.nvim_win_set_config(st[key], cfg)
  else
    cfg.noautocmd = true
    st[key] = api.nvim_open_win(buf, false, cfg)
  end
  merge_whl(st[key], f.ui.panel_whl(api.nvim_get_current_win() == st[key]))
  st.panels[#st.panels + 1] = st[key]
end

local function ensure_anchor_and_backdrop(tab, st, geo)
  if not (valid(st.anchor) and api.nvim_win_get_tabpage(st.anchor) == tab) then
    local split
    for _, w in ipairs(api.nvim_tabpage_list_wins(tab)) do
      if api.nvim_win_get_config(w).relative == "" then
        split = w
        break
      end
    end
    if split then
      local buf = api.nvim_create_buf(false, true)
      vim.bo[buf].bufhidden = "wipe"
      st.anchor = api.nvim_open_win(buf, false, { split = "below", win = split, noautocmd = true })
    end
  end
  local cfg = {
    relative = "editor",
    row = geo.top,
    col = 0,
    width = geo.cols,
    height = geo.rows,
    style = "minimal",
    focusable = false,
    zindex = fb().config.z_backdrop,
  }
  if valid(st.backdrop) and api.nvim_win_get_tabpage(st.backdrop) == tab then
    cfg.style = nil
    api.nvim_win_set_config(st.backdrop, cfg)
  else
    local buf = api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = "wipe"
    cfg.noautocmd = true
    st.backdrop = api.nvim_open_win(buf, false, cfg)
    api.nvim_set_option_value(
      "winhighlight",
      "Normal:FloatbenchBackdrop,NormalFloat:FloatbenchBackdrop",
      { win = st.backdrop, scope = "local" }
    )
  end
end

---Titles by Diffview layout role (diff2: a/b; merge: a ours, b result,
---c theirs, d base).
local function title_for(layout, win, conflict)
  if conflict then
    return ({ a = "Ours", b = "Result", c = "Theirs", d = "Base" })[(layout.a == win and "a") or (layout.b == win and "b") or (layout.c == win and "c") or "d"]
  end
  return layout.a == win and "Original" or "Modified"
end

---Re-home the current Diffview tab into the workbench slots.
function M.apply()
  local f = fb()
  local view = f and current_view()
  if not view or applying then
    return
  end
  local layout = view.cur_layout
  if not layout or not layout:is_valid() then
    return
  end
  applying = true
  local ok, err = pcall(function()
    local tab = view.tabpage
    local st = T[tab] or { panels = {} }
    T[tab] = st
    st.panels = {}

    local conflict = #layout.windows >= 3 and layout.b ~= nil
    local geo = geometry(conflict)
    ensure_anchor_and_backdrop(tab, st, geo)

    -- file panel -> Explorer slot
    local panel = view.panel
    if panel and panel:is_open() and valid(panel.winid) then
      local is_history = view.class and view.class.__name == "FileHistoryView"
      place(st, panel.winid, geo.explorer, is_history and "History" or "Changes")
    end

    -- diff windows -> Editor slot, side by side (keep Diffview's left->right
    -- order); the merge result -> Terminal slot
    local editors = {}
    for _, w in ipairs(layout.windows) do
      if w:is_valid() and not (conflict and w == layout.b) then
        editors[#editors + 1] = w
      end
    end
    table.sort(editors, function(x, y)
      return api.nvim_win_get_position(x.id)[2] < api.nvim_win_get_position(y.id)[2]
    end)
    local box = geo.editor
    local col, width = box.col, math.floor(box.w / math.max(#editors, 1))
    for i, w in ipairs(editors) do
      local w_i = i == #editors and (box.col + box.w - col) or width
      place(st, w.id, { row = box.row, col = col, w = w_i, h = box.h }, title_for(layout, w, conflict))
      col = col + w_i
    end

    if conflict then
      show_buf(st, "terminal", nil)
      place(st, layout.b.id, geo.terminal, "Result")
    else
      show_buf(st, "terminal", f.ui.panel_buf("terminal"), geo.terminal, "Terminal")
    end
    show_buf(st, "claude", f.ui.panel_buf("claude"), geo.claude, "Claude")

    -- Rebuilding a layout (e.g. a merge conflict) can leave focus on the
    -- hidden anchor split; move it to what Diffview would focus.
    local cur = api.nvim_get_current_win()
    if api.nvim_win_get_tabpage(cur) == tab and not vim.tbl_contains(st.panels, cur) then
      local main = layout:get_main_win()
      local target = (panel and panel:is_open() and panel.winid) or (main and main.id)
      if valid(target) then
        api.nvim_set_current_win(target)
      end
    end
  end)
  applying = false
  if not ok then
    vim.notify("Floatbench diff: " .. tostring(err), vim.log.levels.WARN)
  end
end

---Debounced apply: Diffview fires several events while (re)building.
local function schedule_apply()
  if timer then
    timer:stop()
  else
    timer = (vim.uv or vim.loop).new_timer()
  end
  timer:start(30, 0, vim.schedule_wrap(M.apply))
end

---Move focus to the nearest panel in direction h/j/k/l (by screen position).
---@return integer? winid
function M.nav_target(dir)
  local st = T[api.nvim_get_current_tabpage()]
  if not st then
    return nil
  end
  local function box(win)
    local c = api.nvim_win_get_config(win)
    if c.relative == "" then
      return nil
    end
    return { r = c.row, c = c.col, h = c.height + 2, w = c.width + 2 }
  end
  local cur = box(api.nvim_get_current_win())
  if not cur then
    return nil
  end
  local best, best_d
  for _, win in ipairs(st.panels) do
    local o = valid(win) and win ~= api.nvim_get_current_win() and box(win)
    if o then
      local rows = o.r < cur.r + cur.h and cur.r < o.r + o.h
      local cols = o.c < cur.c + cur.w and cur.c < o.c + o.w
      local d = (dir == "h" and rows and cur.c - (o.c + o.w))
        or (dir == "l" and rows and o.c - (cur.c + cur.w))
        or (dir == "k" and cols and cur.r - (o.r + o.h))
        or (dir == "j" and cols and o.r - (cur.r + cur.h))
      if d and d >= -1 and (not best_d or d < best_d) then
        best, best_d = win, d
      end
    end
  end
  return best
end

local function refresh_active()
  local st = T[api.nvim_get_current_tabpage()]
  local f = fb()
  if not (st and f) then
    return
  end
  local cur = api.nvim_get_current_win()
  for _, win in ipairs(st.panels) do
    if valid(win) then
      merge_whl(win, f.ui.panel_whl(win == cur))
    end
  end
end

function M.start()
  local group = api.nvim_create_augroup(AUG, { clear = true })
  api.nvim_create_autocmd("User", {
    group = group,
    pattern = { "DiffviewViewPostLayout", "DiffviewViewEnter", "DiffviewDiffBufWinEnter" },
    callback = schedule_apply,
    desc = "Floatbench: style Diffview tab",
  })
  api.nvim_create_autocmd({ "WinNew", "VimResized" }, {
    group = group,
    callback = function()
      if current_view() then
        schedule_apply()
      end
    end,
    desc = "Floatbench: re-home Diffview windows after (re)layout",
  })
  api.nvim_create_autocmd("WinEnter", {
    group = group,
    callback = function()
      vim.schedule(refresh_active)
    end,
    desc = "Floatbench: highlight focused Diffview panel",
  })
  api.nvim_create_autocmd("User", {
    group = group,
    pattern = "DiffviewViewClosed",
    callback = function()
      vim.schedule(function()
        for tab in pairs(T) do
          if not api.nvim_tabpage_is_valid(tab) then
            T[tab] = nil
          end
        end
      end)
    end,
  })
  -- A Diffview tab that is already open gets styled right away.
  schedule_apply()
end

---Workbench OFF: close styled Diffview tabs (their windows are floats now)
---and forget the state.
function M.stop()
  pcall(api.nvim_del_augroup_by_name, AUG)
  local ok, lib = pcall(require, "diffview.lib")
  if ok then
    for _, view in ipairs(vim.list_slice(lib.views)) do
      if T[view.tabpage] then
        pcall(function()
          view:close()
          lib.dispose_view(view)
        end)
      end
    end
  end
  T = {}
end

return M
