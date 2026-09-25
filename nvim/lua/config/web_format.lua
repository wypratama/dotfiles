-- Project config files that decide how JS/TS/Vue files are formatted on
-- save (plugins/typescript.lua) and whether eslint_d is warmed up early
-- (plugin/eslint_d_warm.lua).
local M = {}

M.prettier_configs = {
  ".prettierrc",
  ".prettierrc.json",
  ".prettierrc.js",
  ".prettierrc.cjs",
  ".prettierrc.mjs",
  ".prettierrc.yaml",
  ".prettierrc.yml",
  ".prettierrc.toml",
  "prettier.config.js",
  "prettier.config.cjs",
  "prettier.config.mjs",
}

M.eslint_configs = {
  ".eslintrc",
  ".eslintrc.js",
  ".eslintrc.cjs",
  ".eslintrc.json",
  ".eslintrc.yaml",
  ".eslintrc.yml",
  "eslint.config.js",
  "eslint.config.cjs",
  "eslint.config.mjs",
}

M.filetypes = { "javascript", "javascriptreact", "typescript", "typescriptreact", "vue" }

return M
