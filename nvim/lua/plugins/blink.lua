return {
  {
    "saghen/blink.cmp",
    opts = {
      keymap = {
        preset = "enter",
        ["<C-space>"] = { "show", "show_documentation", "hide_documentation" },
        ["<Tab>"] = { "accept", "fallback" },
        ["<S-Tab>"] = { "select_prev", "fallback" },
      },
    },
  },
}

