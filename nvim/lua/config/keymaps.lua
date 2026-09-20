-- Keymaps are automatically loaded on the VeryLazy event
-- Default keymaps that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/keymaps.lua
-- Add any additional keymaps here

local function lazyvim_is_main_window()
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

Snacks.keymap.set({ "n", "t" }, "<leader>t", function()
  -- Reuse the existing terminal instead of keying the lookup off
  -- LazyVim.root(): the old code called Snacks.terminal.get(nil, { cwd =
  -- LazyVim.root(), ... }) on every press, but the terminal id includes cwd,
  -- and root() depends on the current buffer (from a terminal buffer it
  -- resolves differently). So pressing <leader>t from inside the terminal,
  -- or from a file with a different root, computed a different id and opened
  -- a brand-new terminal instead of focusing the one you had.
  local terminal
  for _, t in ipairs(Snacks.terminal.list()) do
    if t:buf_valid() then
      terminal = t
      break
    end
  end
  if not terminal then
    local anchor = lazyvim_is_main_window() or vim.api.nvim_get_current_win()
    terminal = Snacks.terminal.get(nil, {
      cwd = LazyVim.root(),
      -- Explicit so it's auditable: defaults to vim.o.shell (/bin/zsh on
      -- macOS). If you still see bash, the old bash-backed buffer is being
      -- reused -- wipe it once (see note below) and confirm with
      -- `:echo &shell` and `echo $0` inside the new terminal.
      shell = vim.env.SHELL or vim.o.shell,
      create = true,
      win = { relative = "win", win = anchor, height = 0.3, wo = { winbar = "" } },
    })
  end
  if terminal then
    -- Toggle: pressing <leader>t while inside the terminal hides it.
    if vim.api.nvim_get_current_buf() == terminal.buf then
      terminal:hide()
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
