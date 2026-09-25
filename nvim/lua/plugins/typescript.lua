-- TypeScript / JavaScript / Nuxt support
-- @usage https://www.lazyvim.org/extras/lang/typescript
return {
  -- Prettier formatting for web frontends
  -- @usage https://www.lazyvim.org/extras/formatting/prettier

  -- Formatting that adapts to what the project actually uses:
  --   * prettier config present            -> prettier formats
  --   * eslint config present              -> eslint_d formats
  --   * both present                       -> both run (eslint --fix first, then prettier)
  --   * neither present                    -> the language server formats (vtsls/vue_ls)
  -- (config file names: config/web_format.lua; eslint_d is started early by
  -- plugin/eslint_d_warm.lua so the first save doesn't time out)
  -- This prevents prettier overriding eslint-only projects and vice-versa.
  -- When a project config exists the LSP never formats: mixing it with
  -- eslint/prettier made saves flip between two styles. A missing tool gives
  -- a one-time warning instead of a silent LSP reformat.
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

      local warned = {} -- tool -> true, warn once per session
      local function warn_missing(bufnr, tools)
        for _, name in ipairs(tools) do
          local info = require("conform").get_formatter_info(name, bufnr)
          if not info.available and not warned[name] and (info.available_msg or ""):match("not found") then
            warned[name] = true
            vim.notify(
              ("This project is configured for %s, but it isn't installed (:MasonInstall %s).\nNot formatting with the language server instead, so styles don't fight."):format(
                name,
                name
              ),
              vim.log.levels.WARN,
              { title = "Format on save" }
            )
          end
        end
      end

      -- Decided per file: the project's tools, or the LSP when it has none.
      local function project_formatters(bufnr)
        local ctx = { filename = vim.api.nvim_buf_get_name(bufnr) }
        local eslint, prettier = has_eslint(ctx), has_prettier(ctx)
        if not eslint and not prettier then
          return { lsp_format = "fallback" } -- no project config: vtsls / vue_ls
        end
        -- eslint_d first (fixes lint/format issues), prettier last (final format)
        local list = { lsp_format = "never" }
        if eslint then
          table.insert(list, "eslint_d")
        end
        if prettier then
          table.insert(list, "prettier")
        end
        warn_missing(bufnr, list)
        return list
      end

      for _, ft in ipairs(web.filetypes) do
        opts.formatters_by_ft[ft] = project_formatters
      end
    end,
  },
}
