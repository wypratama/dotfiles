-- opencode.nvim: native Neovim UI for the opencode CLI (output + input
-- windows). While the floating workbench is ON it takes the Claude slot
-- (experiments/floatbench.lua): whichever assistant was opened last shows
-- there. Default keys: <leader>og toggle, <leader>oi input, <leader>oo output.
-- opencode.nvim keeps OpenCode v2 support on its "v2" branch; pick the
-- branch from the installed CLI's major version (per device, since this
-- config is shared). `opencode --version` (~40ms) only runs when the binary
-- changed: the answer is cached keyed on its path/size/mtime. No CLI ->
-- default branch.
local function opencode_branch()
  local exe = vim.fn.exepath("opencode")
  if exe == "" then
    return nil
  end
  local stat = (vim.uv or vim.loop).fs_stat(exe)
  local key = exe .. ":" .. (stat and (stat.size .. ":" .. stat.mtime.sec) or "?")
  local cache = vim.fn.stdpath("cache") .. "/opencode-cli-version"

  local ok, lines = pcall(vim.fn.readfile, cache)
  local version = ok and lines[1] == key and lines[2] or nil
  if not version then
    local res = vim.system({ exe, "--version" }, { text = true }):wait(3000)
    version = res.code == 0 and (res.stdout or ""):match("(%d+%.%d+%.?%d*)") or nil
    if version then
      pcall(vim.fn.writefile, { key, version }, cache)
    end
  end

  local major = tonumber(version and version:match("^(%d+)"))
  return major and major >= 2 and "v2" or nil
end

return {
  {
    "sudo-tee/opencode.nvim",
    branch = opencode_branch(),
    cmd = { "Opencode" },
    keys = {
      { "<leader>o", "", desc = "+opencode", mode = { "n", "v" } },
    },
    event = "VeryLazy",
    dependencies = {
      "MeanderingProgrammer/render-markdown.nvim",
      "saghen/blink.cmp",
      "folke/snacks.nvim",
    },
    opts = {},
    config = function(_, opts)
      require("opencode").setup(opts)
    end,
  },

  -- Render opencode's output buffer as markdown too (the existing
  -- plugins/render-markdown.lua config is kept; this only adds the filetype).
  {
    "MeanderingProgrammer/render-markdown.nvim",
    ft = { "opencode_output" },
    opts = function(_, opts)
      opts.file_types = opts.file_types or { "markdown", "norg", "rmd", "org", "codecompanion" }
      table.insert(opts.file_types, "opencode_output")
      -- opencode.nvim recommends no anti-conceal for its output; limit that
      -- to its buffers so editing markdown files is unchanged.
      opts.overrides = opts.overrides or {}
      opts.overrides.filetype = opts.overrides.filetype or {}
      opts.overrides.filetype.opencode_output = { anti_conceal = { enabled = false } }
    end,
  },
}
