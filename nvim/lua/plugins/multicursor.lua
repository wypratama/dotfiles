return {
  {
    "jake-stewart/multicursor.nvim",
    branch = "1.0",
    event = "VeryLazy",
    config = function()
      local mc = require("multicursor-nvim")
      mc.setup()

      local set = vim.keymap.set

      -- VSCode Ctrl+D equivalent (kept off <C-d>, which scrolls half a page)
      set({ "n", "x" }, "<M-d>", function()
        mc.matchAddCursor(1)
      end, { desc = "Multicursor: add selection to next match" })

      -- VSCode: Ctrl+Alt+Right/Left -> move last selection to next/prev match
      set({ "n", "x" }, "<C-Alt-Right>", function()
        mc.matchSkipCursor(1)
      end, { desc = "Multicursor: skip to next match" })
      set({ "n", "x" }, "<C-Alt-Left>", function()
        mc.matchSkipCursor(-1)
      end, { desc = "Multicursor: skip to prev match" })

      -- VSCode: Ctrl+Alt+Up/Down -> add cursor above/below
      set({ "n", "x" }, "<C-Alt-Up>", function()
        mc.lineAddCursor(-1)
      end, { desc = "Multicursor: add cursor above" })
      set({ "n", "x" }, "<C-Alt-Down>", function()
        mc.lineAddCursor(1)
      end, { desc = "Multicursor: add cursor below" })

      -- VSCode: Ctrl+Shift+L / Option+Shift+L -> select all occurrences
      set({ "n", "x" }, "<C-S-l>", function()
        mc.matchAllAddCursors()
      end, { desc = "Multicursor: select all occurrences" })
      set({ "n", "x" }, "<M-S-l>", function()
        mc.matchAllAddCursors()
      end, { desc = "Multicursor: select all occurrences" })

      -- VSCode: Ctrl+Click (term) / Alt+Click (mouse) -> insert cursor
      set("n", "<C-LeftMouse>", mc.handleMouse)
      set("n", "<C-LeftDrag>", mc.handleMouseDrag)
      set("n", "<C-LeftRelease>", mc.handleMouseRelease)
      set("n", "<A-LeftMouse>", mc.handleMouse)

      -- Cursor cycling / disable
      set({ "n", "x" }, "<C-q>", mc.toggleCursor, { desc = "Multicursor: toggle cursors" })

      -- Mappings that only apply while multiple cursors are active
      mc.addKeymapLayer(function(layerSet)
        -- VSCode: Esc clears all selections (or re-enables when disabled)
        layerSet("n", "<esc>", function()
          if not mc.cursorsEnabled() then
            mc.enableCursors()
          else
            mc.clearCursors()
          end
        end)

        layerSet({ "n", "x" }, "<left>", mc.prevCursor)
        layerSet({ "n", "x" }, "<right>", mc.nextCursor)
      end)

      -- VSCode-style cursor bar
      vim.api.nvim_set_hl(0, "MultiCursorCursor", { fg = "#0F1117", bg = "#2F7EDB" })
      vim.api.nvim_set_hl(0, "MultiCursorVisual", { link = "Visual" })
      vim.api.nvim_set_hl(0, "MultiCursorSign", { link = "SignColumn" })
      vim.api.nvim_set_hl(0, "MultiCursorMatchPreview", { link = "Search" })
    end,
  },
}