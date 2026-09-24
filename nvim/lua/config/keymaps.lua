-- Keymaps are automatically loaded on the VeryLazy event
-- Default keymaps that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/keymaps.lua
-- Add any additional keymaps here

-- The floating workbench experiment (experiments/floatbench.lua), when ON,
-- owns the main editor window; package.loaded keeps this free when unused.
local function floatbench()
  local fb = package.loaded["experiments.floatbench"]
  return fb and fb.enabled and fb or nil
end

local function lazyvim_is_main_window()
  local fb = floatbench()
  if fb and fb.editor_win() then
    return fb.editor_win()
  end
  local wins = vim.api.nvim_tabpage_list_wins(0)
  local candidates = {}
  for _, w in ipairs(wins) do
    local conf = vim.api.nvim_win_get_config(w)
    local buf = vim.api.nvim_win_get_buf(w)
    if conf.relative == "" and not vim.w[w].snacks_layout and vim.bo[buf].buftype == "" then
      table.insert(candidates, w)
    end
  end
  table.sort(candidates, function(a, b)
    local area_a = vim.api.nvim_win_get_width(a) * vim.api.nvim_win_get_height(a)
    local area_b = vim.api.nvim_win_get_width(b) * vim.api.nvim_win_get_height(b)
    return area_a > area_b
  end)
  return candidates[1]
end

vim.keymap.set("n", "<leader>h", function()
  local current = vim.api.nvim_get_current_win()
  local target = lazyvim_is_main_window()
  if not target then
    vim.cmd("wincmd t")
    return
  end
  if target ~= current then
    vim.api.nvim_set_current_win(target)
  end
end, { desc = "Focus Main Window" })

local function main_window_buffers(cmd)
  return function()
    if vim.api.nvim_get_current_win() == lazyvim_is_main_window() then
      vim.cmd(cmd)
    end
  end
end

vim.keymap.set("n", "<Tab>", main_window_buffers("bnext"), { desc = "Next Buffer" })
vim.keymap.set("n", "<S-Tab>", main_window_buffers("bprevious"), { desc = "Previous Buffer" })

-- <leader>t never closes the terminal: it opens + focuses one when none
-- exists, otherwise shows it (if hidden) and focuses it. Hide it temporarily
-- with <C-/> from inside; the process (e.g. a dev server) keeps running.
-- Normal mode only: a terminal-mode <leader> (Space) mapping hijacks every
-- "space + t" typed into ANY terminal (e.g. "this" in the Claude prompt).
Snacks.keymap.set("n", "<leader>t", function()
  local fb = floatbench()
  if fb then
    fb.focus("terminal")
    return
  end
  -- Reuse the existing terminal instead of keying the lookup off
  -- LazyVim.root(): the old code called Snacks.terminal.get(nil, { cwd =
  -- LazyVim.root(), ... }) on every press, but the terminal id includes cwd,
  -- and root() depends on the current buffer (from a terminal buffer it
  -- resolves differently). So pressing <leader>t from inside the terminal,
  -- or from a file with a different root, computed a different id and opened
  -- a brand-new terminal instead of focusing the one you had.
  local terminal
  for _, t in ipairs(Snacks.terminal.list()) do
    -- list() also contains claudecode's Claude terminal; never grab that one.
    local info = vim.b[t.buf].snacks_terminal
    local is_claude = type(info) == "table" and vim.inspect(info.cmd or ""):lower():find("claude", 1, true)
    if t:buf_valid() and not is_claude then
      terminal = t
      break
    end
  end
  if not terminal then
    local anchor = lazyvim_is_main_window() or vim.api.nvim_get_current_win()
    local created
    terminal, created = Snacks.terminal.get(nil, {
      cwd = LazyVim.root(),
      -- Explicit so it's auditable: defaults to vim.o.shell (/bin/zsh on
      -- macOS). If you still see bash, the old bash-backed buffer is being
      -- reused -- wipe it once (see note below) and confirm with
      -- `:echo &shell` and `echo $0` inside the new terminal.
      shell = vim.env.SHELL or vim.o.shell,
      create = true,
      win = { relative = "win", win = anchor, height = 0.3, wo = { winbar = "" } },
    })
    -- get() already opened and focused the new terminal.
    if created then
      return
    end
  end
  if terminal then
    -- Already visible: just focus it (never close/reopen, keeps its place).
    if terminal:win_valid() then
      terminal:focus()
      return
    end
    local main = lazyvim_is_main_window()
    if main and vim.api.nvim_win_is_valid(main) and terminal.opts.win ~= main then
      terminal:close({ buf = false })
      terminal.opts.win = main
    end
    terminal:show():focus()
  end
end, { desc = "Terminal (Root Dir)" })
