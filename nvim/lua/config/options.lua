-- Options are automatically loaded before lazy.nvim startup
-- Default options that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/options.lua
-- Add any additional options here

-- Per-project local config: Nvim will run a `.nvim.lua` (or `.nvimrc`/`.exrc`)
-- found in the cwd or any parent dir, after you approve it once via `:trust`.
-- Use it for one-off project needs (e.g. a different LSP, format-on-save
-- toggle) without touching this global config. See `:h 'exrc'`.
vim.o.exrc = true

-- Clipboard over SSH: LazyVim sets clipboard=unnamedplus, which routes y/p
-- through the "+" register. Inside tmux, nvim already auto-detects tmux as
-- the provider (tmux relays to the local clipboard via OSC 52, and paste
-- reads tmux's own buffer instantly - no network round trip). But a bare
-- `ssh host nvim` with no tmux and no xclip/wl-copy/etc has no provider at
-- all, because nvim only falls back to OSC 52 on its own when 'clipboard'
-- is empty - and LazyVim already set it. So fill that one gap in explicitly.
-- (Left unset when running locally/inside tmux, since OSC 52 paste blocks
-- for up to ~10s waiting on a terminal reply if the terminal never answers.)
if vim.env.SSH_TTY and vim.env.TMUX == nil then
  vim.g.clipboard = "osc52"
end
