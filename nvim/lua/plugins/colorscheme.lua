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
      highlight_groups = {},
    },
  },

  {
    "LazyVim/LazyVim",
    opts = {
      colorscheme = "rose-pine",
    },
  },
}
