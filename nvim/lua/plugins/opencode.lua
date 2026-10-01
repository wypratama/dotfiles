-- ocmini: a minimal Neovim front end for the opencode CLI.
--
-- It lives in this repo (nvim/ocmini) and is registered with lazy.nvim as a local
-- `dir` plugin, so there is nothing to clone, no lock entry and no install step.
-- It talks to a private `opencode serve` over loopback HTTP, so it works with
-- whatever opencode CLI you have installed rather than being pinned to a branch
-- that has to match.
--
-- While the floating workbench is ON it takes the right-hand assistant slot
-- (experiments/floatbench.lua): whichever assistant was opened last shows there.
--
-- Commands: :Opencode [open|hide|close|input|output|new|sessions|model|agent|mention|interrupt|status]
return {
  {
    dir = vim.fn.stdpath("config") .. "/ocmini",
    name = "ocmini",
    lazy = true,
    cmd = { "Opencode" },
    keys = {
      {
        "<leader>og",
        function()
          require("ocmini").toggle()
        end,
        mode = { "n", "v" },
        desc = "Toggle opencode panel",
      },
      {
        "<leader>oi",
        function()
          require("ocmini").input()
        end,
        mode = { "n", "v" },
        desc = "Opencode prompt input",
      },
      {
        "<leader>oo",
        function()
          require("ocmini").output()
        end,
        mode = { "n", "v" },
        desc = "Opencode transcript output",
      },
      {
        "<leader>oy",
        function()
          require("ocmini.context").select()
          require("ocmini").input()
        end,
        mode = "x",
        desc = "Attach selection to OpenCode",
      },
      {
        "<leader>o/",
        function()
          if vim.fn.mode():match("[vV]") or vim.fn.mode() == "\22" then require("ocmini.context").select() end
          require("ocmini").input()
          vim.schedule(function() require("ocmini.actions").run("quick") end)
        end,
        mode = { "n", "x" },
        desc = "OpenCode quick chat",
      },
    },
    -- snacks.nvim backs the model/agent/session pickers; render-markdown renders
    -- the transcript buffer (see the filetype spec below).
    dependencies = {
      "MeanderingProgrammer/render-markdown.nvim",
      "folke/snacks.nvim",
    },
    opts = {},
    config = function(_, opts)
      require("ocmini").setup(opts)
    end,
  },

  -- Render the transcript buffer as markdown.
  {
    "MeanderingProgrammer/render-markdown.nvim",
    ft = { "opencode_output" },
    opts = function(_, opts)
      opts.file_types = opts.file_types or { "markdown", "norg", "rmd", "org", "codecompanion" }
      table.insert(opts.file_types, "opencode_output")
      -- opencode's own output is not markdown-concealed; limit that to its buffer
      -- so editing real markdown files is unchanged.
      opts.overrides = opts.overrides or {}
      opts.overrides.filetype = opts.overrides.filetype or {}
      opts.overrides.filetype.opencode_output = { anti_conceal = { enabled = false } }
    end,
  },
}
