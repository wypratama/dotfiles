local function c(code)
  return vim.fn.nr2char(code)
end

return {
  {
    "folke/snacks.nvim",
    keys = {
      {
        "<leader>e",
        function()
          local explorer = Snacks.picker.get({ source = "explorer" })[1]
          if explorer then
            explorer:focus()
          else
            Snacks.explorer({ cwd = LazyVim.root() })
          end
        end,
        desc = "Explorer Snacks (root dir)",
      },
      {
        "<leader>E",
        function()
          local explorer = Snacks.picker.get({ source = "explorer" })[1]
          if explorer then
            explorer:focus()
          else
            Snacks.explorer()
          end
        end,
        desc = "Explorer Snacks (cwd)",
      },
    },
    -- Folder icons (open/closed) for the Snacks picker / explorer
    --stylua: ignore
    opts = {
      picker = {
        icons = {
          files = {
            dir = c(0xea83) .. " ",      -- cod-folder
            dir_open = c(0xeaf7) .. " ", -- cod-folder_opened
            file = c(0xea7b) .. " ",     -- cod-file
          },
        },
      },
    },
  },
}
