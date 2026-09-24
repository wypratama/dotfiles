-- Diffview panel config: the normal left split, or (while the floating
-- workbench is ON) a float in its Explorer slot, see
-- experiments/floatbench_diff.lua. Diffview accepts a function here.
local function panel_win_config(default)
  return function()
    if package.loaded["experiments.floatbench"] then
      return require("experiments.floatbench_diff").panel_config(default)
    end
    return default
  end
end

-- <leader>gd toggles: close the Diffview in this tab, jump to an open one
-- from another tab, or open a new one.
local function toggle_diffview()
  local lib = require("diffview.lib")
  if lib.get_current_view() then
    vim.cmd("DiffviewClose")
  elseif lib.views[1] and vim.api.nvim_tabpage_is_valid(lib.views[1].tabpage) then
    vim.api.nvim_set_current_tabpage(lib.views[1].tabpage)
  else
    vim.cmd("DiffviewOpen")
  end
end

return {
  {
    "sindrets/diffview.nvim",
    event = "VeryLazy",
    cmd = { "DiffviewOpen", "DiffviewClose", "DiffviewFileHistory" },
    keys = {
      -- <leader>gD is left to LazyVim (Snacks "Git Diff (origin)")
      { "<leader>gd", toggle_diffview, desc = "Git diff (Diffview) toggle" },
      { "<leader>gh", "<CMD>DiffviewFileHistory %<CR>", desc = "Git file history" },
      { "<leader>gH", "<CMD>DiffviewFileHistory<CR>", desc = "Git history (all)" },
    },
    opts = {
      enhanced_diff_hl = true,
      use_icons = true,
      file_panel = {
        listing_style = "list", -- flat list of changed files, like VSCode's Source Control view
        -- match Snacks explorer sidebar width so switching feels seamless
        win_config = panel_win_config({ position = "left", width = 40 }),
      },
      file_history_panel = {
        win_config = panel_win_config({ position = "bottom", height = 16 }),
      },
      view = {
        default = { layout = "diff2_horizontal", winbar_info = true },
        merge_tool = { layout = "diff3_mixed", winbar_info = true },
        file_history = { layout = "diff2_horizontal", winbar_info = true },
      },
    },
  },
}
