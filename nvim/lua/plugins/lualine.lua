-- Powerline-style statusline matching the starship prompt: each block has
-- its own background (mode color -> highlight_high -> highlight_med ->
-- overlay -> transparent) and every  is drawn in the previous block's color
-- over the next block's background. Only colors/separators change; LazyVim's
-- components and their order are kept.
local SOLID_R, SOLID_L = vim.fn.nr2char(0xe0b0), vim.fn.nr2char(0xe0b2)

return {
  {
    "nvim-lualine/lualine.nvim",
    opts = function(_, opts)
      local p = require("rose-pine.palette")
      local transparent = require("rose-pine.config").options.styles.transparency
      local fill = transparent and "NONE" or p.surface

      local theme = {}
      for mode, color in pairs({ normal = p.rose, insert = p.foam, visual = p.iris, replace = p.pine, command = p.love }) do
        theme[mode] = {
          a = { bg = color, fg = p.base, gui = "bold" },
          b = { bg = p.highlight_high, fg = color },
          c = { bg = fill, fg = p.text },
          -- right side mirrors the left: transparent -> overlay (x) ->
          -- highlight_high (y, from b) -> mode color (z, from a)
          x = { bg = p.overlay, fg = p.text },
        }
      end
      -- lualine has a separate "terminal" mode (Claude, shell); without it the
      -- x block falls back to the transparent c colors in terminals.
      theme.terminal = theme.normal
      theme.inactive = {
        a = { bg = fill, fg = p.muted },
        b = { bg = fill, fg = p.muted },
        c = { bg = fill, fg = p.muted },
        x = { bg = fill, fg = p.muted },
      }
      opts.options.theme = theme
      opts.options.section_separators = { left = SOLID_R, right = SOLID_L }

      -- lualine_c: root dir on highlight_med, then diagnostics/filetype/path on
      -- overlay. A table `separator` makes lualine draw a colored transition
      -- to the next component instead of a thin, text-colored chevron.
      local c = opts.sections.lualine_c
      local path_i
      for i, comp in ipairs(c) do
        if comp[1] == "filetype" then
          path_i = i + 1
        end
      end
      for i, comp in ipairs(c) do
        if i == 1 then -- LazyVim.lualine.root_dir()
          comp.color = { fg = p.foam, bg = p.highlight_med }
          comp.separator = { right = SOLID_R }
        elseif path_i and i <= path_i then -- diagnostics, filetype, pretty_path
          comp.color = vim.tbl_extend("force", type(comp.color) == "table" and comp.color or {}, { bg = p.overlay })
          comp.separator = i == path_i and { right = SOLID_R } or ""
        end
      end

      -- lualine_x (noice, lazy updates, diff, ...) is one overlay block now.
      -- Its components are conditional and lualine draws no separator at the
      -- middle split, so each one opens with a colored  instead of the thin
      -- text-colored chevron; between two x components that arrow is overlay
      -- on overlay and just reads as a space.
      for _, comp in ipairs(opts.sections.lualine_x) do
        if type(comp) == "table" then
          comp.separator = { left = SOLID_L }
        end
      end
    end,
  },
}
