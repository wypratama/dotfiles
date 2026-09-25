-- Start eslint_d as soon as a JS/TS/Vue file of an eslint project opens.
-- Its first run loads the project's eslint config (~2s cold, more for heavy
-- configs like @antfu/eslint-config), which can blow LazyVim's 3s
-- format-on-save timeout and silently skip formatting. conform.nvim only
-- loads on the first save, so this lives in plugin/ (sourced at startup,
-- before the first file is read).
local warmed = {} -- project root -> true

vim.api.nvim_create_autocmd("FileType", {
  group = vim.api.nvim_create_augroup("eslint_d_warm", { clear = true }),
  pattern = require("config.web_format").filetypes,
  callback = function(ev)
    local file = vim.api.nvim_buf_get_name(ev.buf)
    if file == "" then
      return
    end
    -- mason's bin may not be on PATH yet for the very first buffer
    local exe = vim.fn.exepath("eslint_d")
    if exe == "" then
      local mason_bin = vim.fn.stdpath("data") .. "/mason/bin/eslint_d"
      exe = vim.fn.executable(mason_bin) == 1 and mason_bin or ""
    end
    if exe == "" then
      return
    end
    local cfg = vim.fs.find(require("config.web_format").eslint_configs, { path = file, upward = true })[1]
    local root = cfg and vim.fs.dirname(cfg)
    if root and not warmed[root] then
      warmed[root] = true
      -- A throwaway lint of this file (output discarded, nothing written):
      -- `eslint_d start` alone only spawns the daemon; the slow part is
      -- loading the project's config/plugins on the first real lint.
      local text = table.concat(vim.api.nvim_buf_get_lines(ev.buf, 0, -1, false), "\n")
      vim.system({ exe, "--fix-to-stdout", "--stdin", "--stdin-filename", file }, { cwd = root, stdin = text })
    end
  end,
  desc = "Start eslint_d early so the first format-on-save doesn't time out",
})
