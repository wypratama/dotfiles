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
  local terminal = Snacks.terminal.get(nil, {
    cwd = LazyVim.root(),
    create = true,
    win = { relative = "win", height = 0.3, wo = { winbar = "" } },
  })
  if terminal then
    local main = lazyvim_is_main_window()
    if main and vim.api.nvim_win_is_valid(main) and terminal.opts.win ~= main then
      terminal:close({ buf = false })
      terminal.opts.win = main
    end
    terminal:show():focus()
  end
end, { desc = "Terminal (Root Dir)" })
