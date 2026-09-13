return {
  {
    "sindrets/diffview.nvim",
    event = "VeryLazy",
    cmd = { "DiffviewOpen", "DiffviewClose", "DiffviewFileHistory" },
    keys = {
      { "<leader>gd", "<CMD>DiffviewOpen<CR>", desc = "Git diff (Diffview)" },
      { "<leader>gD", "<CMD>DiffviewClose<CR>", desc = "Git diff close" },
      { "<leader>gh", "<CMD>DiffviewFileHistory %<CR>", desc = "Git file history" },
      { "<leader>gH", "<CMD>DiffviewFileHistory<CR>", desc = "Git history (all)" },
    },
    opts = {
      enhanced_diff_hl = true,
      use_icons = true,
      file_panel = {
        listing_style = "list", -- flat list of changed files, like VSCode's Source Control view
        win_config = { width = 40 }, -- match Snacks explorer sidebar width so switching feels seamless
      },
      view = {
        default = { layout = "diff2_horizontal", winbar_info = true },
        merge_tool = { layout = "diff3_mixed", winbar_info = true },
        file_history = { layout = "diff2_horizontal", winbar_info = true },
      },
    },
  },
}