local function c(code)
  return vim.fn.nr2char(code)
end

return {
  {
    "nvim-mini/mini.icons",
    opts = {
      default = {
        -- VSCode codicon fallbacks: used only for file types mini.icons has no
        -- logo for. Everything else uses mini.icons' built-in logo set
        -- (rust, go, python, vue, react, svelte, astro, docker, ... ).
        directory = { glyph = c(0xea83) }, -- cod-folder
        file = { glyph = c(0xea7b) }, -- cod-file
        filetype = { glyph = c(0xea7b) },
        extension = { glyph = c(0xea7b) },
      },
      -- Exact filenames (mini.icons matches 'file' entries by basename only).
      -- These resolve to their real logos instead of generic icons.
      --stylua: ignore
      file = {
        -- vitest (dev-vitest)
        ["vitest.config.ts"] = { glyph = c(0xe8d9), hl = "MiniIconsYellow" },
        ["vitest.config.mts"] = { glyph = c(0xe8d9), hl = "MiniIconsYellow" },
        ["vitest.config.js"] = { glyph = c(0xe8d9), hl = "MiniIconsYellow" },
        ["vitest.config.mjs"] = { glyph = c(0xe8d9), hl = "MiniIconsYellow" },
        ["vitest.workspace.ts"] = { glyph = c(0xe8d9), hl = "MiniIconsYellow" },
        ["vitest.workspace.mts"] = { glyph = c(0xe8d9), hl = "MiniIconsYellow" },
        -- vite (dev-vite)
        ["vite.config.ts"] = { glyph = c(0xe8d6), hl = "MiniIconsPurple" },
        ["vite.config.mts"] = { glyph = c(0xe8d6), hl = "MiniIconsPurple" },
        ["vite.config.js"] = { glyph = c(0xe8d6), hl = "MiniIconsPurple" },
        ["vite.config.mjs"] = { glyph = c(0xe8d6), hl = "MiniIconsPurple" },
        -- jest (dev-jest)
        ["jest.config.js"] = { glyph = c(0xe807), hl = "MiniIconsYellow" },
        ["jest.config.mjs"] = { glyph = c(0xe807), hl = "MiniIconsYellow" },
        ["jest.config.cjs"] = { glyph = c(0xe807), hl = "MiniIconsYellow" },
        ["jest.config.ts"] = { glyph = c(0xe807), hl = "MiniIconsYellow" },
      },
    },
  },
}