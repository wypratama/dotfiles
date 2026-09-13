return {
  {
    "catgoose/nvim-colorizer.lua",
    event = "BufReadPre",
    opts = {
      options = {
        parsers = {
          css = true,
          tailwind = {
            enable = true,
            -- Read colors from the real, resolved theme (custom/semantic
            -- tokens like `primary-100`, non-standard steps like `neutral-40`
            -- included) via the tailwindcss LSP. Requires the on_attach
            -- capability patch in plugins/tailwind.lua to actually fire.
            lsp = { enable = true, disable_document_color = true },
            -- Feed LSP-resolved colors back into the static name-matcher, so
            -- tokens the LSP has seen once (in a `class="..."` attribute
            -- somewhere) also get the *correct* color when they show up again
            -- as plain text the LSP can't reach on its own, e.g. inside a
            -- bare object literal like `{ root: 'bg-primary-100' }`.
            update_names = true,
          },
        },
        display = {
          mode = "virtualtext",
          virtualtext = {
            char = "●",
            position = "before",
            hl_mode = "foreground",
          },
        },
      },
    },
    config = function(_, opts)
      require("colorizer").setup(opts)

      -- Custom/semantic Tailwind tokens that never appear in a `class="..."`
      -- attribute anywhere (e.g. only used inside a bare object literal like
      -- `{ root: 'bg-primary-100' }`) are invisible to the tailwindcss LSP no
      -- matter what, so they can't be picked up via `update_names` either.
      -- Read each project's own `@theme` CSS block directly instead, and feed
      -- the real custom colors into the static/context-free name matcher, so
      -- they're colored correctly anywhere they show up as plain text.
      local theme = require("config.tailwind_theme")
      vim.api.nvim_create_autocmd({ "BufReadPost", "BufNewFile" }, {
        group = vim.api.nvim_create_augroup("tailwind_theme_colors", { clear = true }),
        callback = function(args)
          theme.refresh_for_buffer(args.buf, opts)
        end,
      })

      vim.api.nvim_create_user_command("TailwindThemeReload", function()
        theme.reload()
        theme.refresh_for_buffer(vim.api.nvim_get_current_buf(), opts)
      end, { desc = "Re-parse the current project's Tailwind @theme colors" })

      vim.api.nvim_create_user_command("TailwindThemeStatus", function()
        local lines = theme.status(vim.api.nvim_get_current_buf())
        vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO, { title = "Tailwind theme" })
      end, { desc = "Show what the Tailwind @theme parser found for the current project" })
    end,
  },
}
