return {
  {
    "zeybek/camouflage.nvim",
    event = { "BufReadPre", "BufNewFile" },
    opts = {},
    keys = {
      -- NOTE: <leader>ct also maps to diffview's "choose theirs" in merge views,
      -- but that mapping is only active inside Diffview's merge-tool buffers.
      { "<leader>ct", "<cmd>CamouflageToggle<cr>", desc = "Toggle Camouflage" },
      { "<leader>cr", "<cmd>CamouflageReveal<cr>", desc = "Reveal Line" },
      { "<leader>cy", "<cmd>CamouflageYank<cr>", desc = "Yank Value" },
      { "<leader>cf", "<cmd>CamouflageFollowCursor<cr>", desc = "Follow Cursor" },
    },
  },
}
