-- TypeScript / JavaScript / Nuxt support
-- @usage https://www.lazyvim.org/extras/lang/typescript
return {
  -- Prettier formatting for web frontends
  -- @usage https://www.lazyvim.org/extras/formatting/prettier

  -- Formatting that adapts to what the project actually uses:
  --   * prettier config present            -> prettier formats
  --   * eslint config present              -> eslint_d formats
  --   * both present                       -> both run (eslint --fix first, then prettier)
  --   * neither present                    -> no formatter on save
  -- (config file names: config/web_format.lua; eslint_d is started early by
  -- plugin/eslint_d_warm.lua so the first save doesn't time out)
  -- This prevents prettier overriding eslint-only projects and vice-versa.
  -- LSP formatting (vue_ls/vtsls) is never used for these filetypes: with
  -- LazyVim's default lsp_format = "fallback", a missing eslint_d (or a
  -- project with no config) silently reformatted files in the LSP's own style.
  {
    "mason-org/mason.nvim",
    opts = { ensure_installed = { "eslint_d" } },
  },
  {
    "stevearc/conform.nvim",
    optional = true,
    opts = function(_, opts)
      local web = require("config.web_format")
      local prettier_configs, eslint_configs = web.prettier_configs, web.eslint_configs

      local function has_config(ctx, names, pkg_key)
        local found = vim.fs.find(names, { path = ctx.filename, upward = true })
        if #found > 0 then
          return true
        end
        local pkg = vim.fs.find({ "package.json" }, { path = ctx.filename, upward = true })[1]
        if pkg then
          local ok, data = pcall(vim.fn.json_decode, vim.fn.readfile(pkg))
          return ok and type(data) == "table" and data[pkg_key] ~= nil
        end
        return false
      end

      local has_prettier = LazyVim.memoize(function(ctx)
        return has_config(ctx, prettier_configs, "prettier")
      end)

      local has_eslint = LazyVim.memoize(function(ctx)
        return has_config(ctx, eslint_configs, "eslintConfig")
      end)

      opts.formatters = opts.formatters or {}

      -- Only run prettier when a prettier config exists in the project
      opts.formatters.prettier = vim.tbl_deep_extend("force", opts.formatters.prettier or {}, {
        condition = function(_, ctx)
          return has_prettier(ctx)
        end,
      })

      -- Only run eslint_d when an eslint config exists in the project
      opts.formatters.eslint_d = vim.tbl_deep_extend("force", opts.formatters.eslint_d or {}, {
        condition = function(_, ctx)
          return has_eslint(ctx)
        end,
      })

      opts.formatters_by_ft = opts.formatters_by_ft or {}

      local fts = {
        "javascript",
        "javascriptreact",
        "typescript",
        "typescriptreact",
        "vue",
      }

      for _, ft in ipairs(fts) do
        opts.formatters_by_ft[ft] = opts.formatters_by_ft[ft] or {}
        local list = opts.formatters_by_ft[ft]
        -- eslint_d first (fixes lint/format issues), prettier last (final format)
        if not vim.tbl_contains(list, "eslint_d") then
          table.insert(list, 1, "eslint_d")
        end
        if not vim.tbl_contains(list, "prettier") then
          table.insert(list, "prettier")
        end
        list.lsp_format = "never"
      end
    end,
  },
}
