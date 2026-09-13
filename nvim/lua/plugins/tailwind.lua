-- Extra Tailwind CSS LSP configuration
return {
  {
    "neovim/nvim-lspconfig",
    opts = function(_, opts)
      opts.servers = opts.servers or {}
      opts.servers.tailwindcss = opts.servers.tailwindcss or {}

      -- Work around a tailwindcss-language-server quirk: it registers
      -- textDocument/documentColor support dynamically (via
      -- client/registerCapability) instead of declaring it in its initial
      -- capabilities. nvim-colorizer.lua's tailwind-LSP integration checks the
      -- static `server_capabilities.colorProvider` field directly, which never
      -- gets set for this server, so it silently never requests colors. Patch
      -- the static field on attach so colorizer's check passes. This has to
      -- live in the server's own `on_attach` (not a global LspAttach autocmd
      -- in autocmds.lua) because autocmds.lua only loads on VeryLazy, which
      -- can fire *after* this client has already attached (e.g. when opening
      -- Nvim directly on a file) -- missing that one attach leaves the shared
      -- client capabilities table permanently unpatched for the session.
      local on_attach = opts.servers.tailwindcss.on_attach
      opts.servers.tailwindcss.on_attach = function(client, bufnr)
        if not client.server_capabilities.colorProvider then
          client.server_capabilities.colorProvider = true
        end
        if on_attach then
          on_attach(client, bufnr)
        end
      end
    end,
  },
}
