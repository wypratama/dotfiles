-- Floating workbench experiment: command shims only. The module loads lazily
-- so startup is unaffected; the experiment stays OFF until toggled.
vim.api.nvim_create_user_command("FloatbenchToggle", function()
  require("experiments.floatbench").toggle()
end, { desc = "Toggle floating workbench experiment" })

vim.api.nvim_create_user_command("FloatbenchStatus", function()
  require("experiments.floatbench").status()
end, { desc = "Show floating workbench panel geometry" })

vim.api.nvim_create_user_command("FloatbenchFocus", function(opts)
  require("experiments.floatbench").focus(opts.args)
end, {
  nargs = 1,
  complete = function()
    return { "explorer", "editor", "terminal", "claude" }
  end,
  desc = "Focus a floating workbench panel",
})

vim.api.nvim_create_user_command("FloatbenchCycle", function()
  require("experiments.floatbench").cycle()
end, { desc = "Cycle focus through floating workbench panels" })

vim.keymap.set("n", "<leader>uW", function()
  require("experiments.floatbench").toggle()
end, { desc = "Toggle Floating Workbench" })
