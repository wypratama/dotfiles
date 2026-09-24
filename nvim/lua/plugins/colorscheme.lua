return {
  {
    "rose-pine/neovim",
    name = "rose-pine",
    lazy = false,
    priority = 1000,
    opts = {
      variant = "main", -- auto, main, moon, or dawn
      dark_variant = "main",
      dim_inactive_windows = false,
      extend_background_behind_borders = false,
      enable = {
        terminal = true,
        legacy_highlights = true,
        migrations = true,
      },
      styles = {
        bold = true,
        italic = true,
        transparency = true,
      },
      groups = {
        border = 'surface'
      },
      highlight_groups = {
        -- Terminal-mode cursor (Claude, shell). smear-cursor draws the blue
        -- cursor in normal/insert mode but not in terminal mode, where the
        -- Ghostty rose-pine cursor (#555169) is nearly invisible. Match the
        -- smear color; 'guicursor' t: uses this group (config/options.lua).
        TermCursor = { fg = "#191724", bg = "#2F7EDB" },
      },
    },
  },

  {
    "LazyVim/LazyVim",
    opts = {
      colorscheme = "rose-pine",
    },
  },
}
