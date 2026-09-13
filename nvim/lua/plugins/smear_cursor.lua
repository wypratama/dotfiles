return {
  {
    "sphamba/smear-cursor.nvim",
    event = "VeryLazy",
    opts = {
      -- VSCode cursor bar color; tmux/terminals sometimes override cursor
      -- color, so set it explicitly to match the multicursor bar #2F7EDB.
      cursor_color = "#2F7EDB",
      smear_between_buffers = true,
      smear_between_neighbor_lines = true,
      scroll_buffer_space = true,
      legacy_computing_symbols_support = false,
      smear_insert_mode = true,
    },
  },
}