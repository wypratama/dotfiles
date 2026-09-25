-- Snacks dashboard header: the "sleek kraken" art instead of LazyVim's logo.
-- Only the header changes; LazyVim's buttons/startup section are kept.
-- The art lives in config/art.lua (also used by the floatbench welcome).

return {
  {
    "folke/snacks.nvim",
    opts = {
      dashboard = {
        preset = {
          header = table.concat(require("config.art").sleekraken, "\n"),
        },
      },
    },
  },
}
