-- Configuration for ocmini, a minimal Neovim client for the opencode CLI.
--
-- NOTE: `config.ui` is mutated at runtime by experiments/floatbench_opencode.lua,
-- which repoints `ui.position`/`ui.float` at the workbench's right-hand slot and
-- restores the saved values when the workbench goes off. Keep those three keys
-- (position, float, window_highlight) and the "value <= 1 means a screen ratio,
-- anything larger means absolute cells" convention in float_layout.

local M = {}

---@class OcminiUi
---@field position "float"|"split" Layout of the output/input windows.
---@field float OcminiFloat Geometry of the float (see OcminiFloat).
---@field window_highlight string `Normal:<group>,FloatBorder:<group>,FloatTitle:<group>`.

---@class OcminiFloat
---@field width number Width: <=1 is a fraction of the screen, >1 is cells.
---@field height number Height: <=1 is a fraction of the screen, >1 is cells.
---@field row number Top row: <=1 is a fraction of the screen, >1 is cells.
---@field col number Left column: <=1 is a fraction of the screen, >1 is cells.
---@field border integer|string Border style, or a highlight group to dim borders.
---@field gap integer Blank rows between the output and input windows.
---@field zinteger Window z-index (kept below the floatbench workbench's own floats).

M.defaults = {
  -- The opencode binary. Resolved with `exepath` when not an absolute path.
  bin = "opencode",
  data_dir = nil, -- Optional directory for history, favorites, and restore points.
  prompt_guard = nil,
  hooks = {},

  -- Seconds to wait for the server to become healthy after spawning it.
  startup_timeout = 20000,

  -- Where the generated server password is cached (must stay mode 0600).
  password_file = nil, -- defaults to stdpath("state")/ocmini_password

  server = {
    url = nil, -- Existing v2 server URL; never killed by this plugin.
    username = nil,
    password = nil,
    -- Reuse a server already listening for this Neovim instance (see server.lua's
    -- port mapping file) instead of spawning a private one.
    reuse = true,
    -- Kill the private server when this Neovim exits.
    kill_on_exit = true,
  },

  session = {
    -- Resume the most recent session for this directory on first open.
    resume = true,
    -- Where to persist the session id so a restart can pick it back up.
    -- A JSON object keyed by directory, since a session belongs to the project
    -- it was created in. Defaults to stdpath("state")/ocmini_session
    state_file = nil,
  },

  ui = {
    position = "float",
    float = {
      width = 0.34,
      height = 0.7,
      row = 0.15,
      col = 0.63,
      border = "rounded",
      gap = 1,
      zindex = 40,
    },
    -- Panel backgrounds and borders; horizontal padding is reserved by ui.panel.
    window_highlight = "SignColumn:Normal",
    -- Filetype of the transcript buffer. experiments/../plugins/opencode.lua
    -- registers render-markdown.nvim for exactly these two filetypes.
    output_filetype = "opencode_output",
    input_filetype = "opencode",
  },

  context = { enabled = true, current_file = true, selection = true, diagnostics = true, git_diff = false, max_lines = 300 },

  input = {
    -- Outer rows for the prompt window, including its top/bottom border.
    -- The remaining space in the assistant panel is reserved for the transcript.
    height = 9,
    -- `@word` opens the file picker when submitted.
    mentions = true,
  },

  render = {
    -- Collapse assistant reasoning to a single dim line until toggled.
    collapse_reasoning = true,
    -- Show one line per tool call instead of its (often huge) input/output.
    collapse_tools = true,
    -- Truncate a single tool's rendered output to this many lines.
    tool_preview_lines = 6,
  },

  keys = {
    submit = "<CR>",
    interrupt = "<C-c>",
    toggle_reasoning = "<CR>",
    mention = "@",
  },
}

---Runtime configuration: defaults deep-merged with the user's `opts`.
---@type table
M.values = vim.deepcopy(M.defaults)

---@param opts table? User options from setup().
---
---Options are merged into the current values, not into a fresh copy of the
---defaults, so calling setup() more than once accumulates rather than resets.
---That ordering matters: a plugin spec that calls setup() when lazy.nvim loads
---the plugin would otherwise wipe out options a user had already passed.
function M.setup(opts)
  M.values = vim.tbl_deep_extend("force", M.values, opts or {})
  -- Resolve the lazily-defaulted paths once, so every other module can just read
  -- config.values.<x> without repeating the stdpath dance.
  M.values.password_file = M.values.password_file
    or (vim.fn.stdpath("state") .. "/ocmini_password")
  M.values.session.state_file = M.values.session.state_file
    or (vim.fn.stdpath("state") .. "/ocmini_session")
  return M.values
end

return M
