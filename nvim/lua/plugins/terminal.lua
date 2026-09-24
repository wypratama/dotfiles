local function term_nav(dir)
  ---@param self snacks.terminal
  return function(self)
    -- Floating workbench: panels are floats, so wincmd can't reach them.
    -- With no panel in that direction, pass the key through to the program
    -- (Claude's <C-j> newline, the shell's <C-l> clear, ...).
    local fb = package.loaded["experiments.floatbench"]
    if fb and fb.enabled then
      if not fb.nav_target(dir) then
        return "<c-" .. dir .. ">"
      end
      vim.schedule(function()
        fb.nav(dir)
      end)
      return ""
    end
    return self:is_floating() and "<c-" .. dir .. ">" or vim.schedule(function()
      vim.cmd.wincmd(dir)
    end)
  end
end

-- Hide the terminal window. In the floating workbench the visible panel is a
-- float owned by experiments/floatbench.lua (Snacks' own window is already
-- hidden), so hand the hide to the workbench instead.
local function term_hide(self)
  local fb = package.loaded["experiments.floatbench"]
  if fb and fb.enabled and fb.hide_buf(self.buf) then
    return
  end
  self:hide()
end

return {
  {
    "folke/snacks.nvim",
    opts = {
      terminal = {
        win = {
          keys = {
            term_normal = {
              "<esc>",
              function(self)
                self.esc_timer = self.esc_timer or (vim.uv or vim.loop).new_timer()
                if self.esc_timer:is_active() then
                  self.esc_timer:stop()
                  vim.cmd("stopinsert")
                else
                  self.esc_timer:start(300, 0, function() end)
                  return "<esc>"
                end
              end,
              mode = "t",
              expr = true,
              desc = "Double Escape to Normal Mode",
            },
            nav_h = { "<C-h>", term_nav("h"), desc = "Go to Left Window", expr = true, mode = "t" },
            nav_j = { "<C-j>", term_nav("j"), desc = "Go to Lower Window", expr = true, mode = "t" },
            nav_k = { "<C-k>", term_nav("k"), desc = "Go to Upper Window", expr = true, mode = "t" },
            nav_l = { "<C-l>", term_nav("l"), desc = "Go to Right Window", expr = true, mode = "t" },
            hide_slash = { "<C-/>", term_hide, desc = "Hide Terminal", mode = { "t", "n" } },
            hide_underscore = { "<c-_>", term_hide, desc = "which_key_ignore", mode = { "t", "n" } },
          },
        },
      },
    },
  },
}

