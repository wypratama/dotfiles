-- Keymaps are automatically loaded on the VeryLazy event
-- Default keymaps that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/keymaps.lua
-- Add any additional keymaps here

-- tab to switch between buffers
vim.api.nvim_set_keymap("n", "<TAB>", ":bnext<CR>", { noremap = true, silent = true })
vim.api.nvim_set_keymap("n", "<S-TAB>", ":bprevious<CR>", { noremap = true, silent = true })

-- leader xx to close current buffer
vim.api.nvim_set_keymap("n", "<leader>xx", ":bd<CR>", { noremap = true, silent = true, desc = "Close current buffer" })
-- leader xa to close all buffers
vim.api.nvim_set_keymap(
  "n",
  "<leader>xa",
  ":bufdo bd<CR>",
  { noremap = true, silent = true, desc = "Close all buffers" }
)
-- leader xc to close all buffers except current one
vim.api.nvim_set_keymap(
  "n",
  "<leader>xc",
  ':bufdo if bufnr("") != bufnr("%") | bd | endif<CR>',
  { noremap = true, silent = true, desc = "Close all buffers except current one" }
)
-- leader xs to close all saved buffers
vim.api.nvim_set_keymap(
  "n",
  "<leader>xs",
  ':bufdo if &buftype !=# "help" && &buftype !=# "terminal" && bufname("") !~# "^term://.*" | if getbufvar(bufnr(""), "&modified") == 0 | bd | endif | endif<CR>',
  { noremap = true, silent = true, desc = "Close all saved buffers" }
)

-- leader e to focus on neotree by calling :Neotree focus
vim.api.nvim_set_keymap(
  "n",
  "<leader>e",
  ":Neotree focus<CR>",
  { noremap = true, silent = true, desc = "Focus on Neotree" }
)

-- leader h call require("edgy").goto_main()
vim.api.nvim_set_keymap(
  "n",
  "<leader>h",
  ':lua require("edgy").goto_main()<CR>',
  { noremap = true, silent = true, desc = "Go to main file" }
)

-- Fungsi untuk memeriksa apakah terminal terbuka
function Toggle_or_focus_terminal()
  local term_buf = nil
  -- Periksa semua buffer terbuka
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    -- Cari buffer terminal
    if vim.bo[buf].buftype == "terminal" then
      term_buf = buf
      break
    end
  end

  if term_buf then
    -- Jika terminal ditemukan, fokus ke jendela terminal
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_buf(win) == term_buf then
        vim.api.nvim_set_current_win(win)
        return
      end
    end
    -- Jika terminal ada tapi belum terbuka di jendela, buka di jendela baru
    vim.cmd("sb " .. term_buf)
  else
    -- Jika tidak ada terminal, buka terminal baru
    LazyVim.terminal(nil, { cwd = LazyVim.root() })
  end
end

vim.api.nvim_set_keymap(
  "n",
  "<leader>t",
  ":lua Toggle_or_focus_terminal()<CR>",
  { noremap = true, silent = true, desc = "Open or Focus Terminal (Root Dir)" }
)
