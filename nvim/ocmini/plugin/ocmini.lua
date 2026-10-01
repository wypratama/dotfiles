-- Commands for ocmini. Loaded on demand by lazy.nvim via `cmd = "Opencode"`, so
-- nothing here runs until the panel is actually used.

if vim.g.loaded_ocmini then
  return
end
vim.g.loaded_ocmini = true

---@param sub string|nil
local function run(sub, arguments)
  local ocmini = require("ocmini")
  ocmini.setup()

  if sub == nil or sub == "" or sub == "toggle" then
    ocmini.toggle()
  elseif sub == "open" then
    ocmini.open()
  elseif sub == "hide" then
    ocmini.hide()
  elseif sub == "close" then
    ocmini.close()
  elseif sub == "input" then
    ocmini.input()
  elseif sub == "output" then
    ocmini.output()
  elseif sub == "new" then
    ocmini.open({ with_input = false })
    vim.schedule(function()
      local ok, err = require("ocmini.events").new_session()
      if not ok then
        require("ocmini.ui").report_error(err or "could not start a new session")
      end
    end)
  elseif sub == "sessions" then
    ocmini.open()
    vim.schedule(function()
      require("ocmini.pickers").session()
    end)
  elseif sub == "model" then
    ocmini.open()
    vim.schedule(function()
      require("ocmini.pickers").model()
    end)
  elseif sub == "agent" then
    ocmini.open()
    vim.schedule(function()
      require("ocmini.pickers").agent()
    end)
  elseif sub == "mention" then
    ocmini.input()
    vim.schedule(function()
      require("ocmini.input").pick_mention()
    end)
  elseif sub == "interrupt" then
    require("ocmini.input").interrupt()
  elseif sub == "status" then
    require("ocmini.actions").run("status")
  elseif require("ocmini.actions").is_builtin(sub) then
    ocmini.open()
    vim.schedule(function() require("ocmini.actions").run(sub, arguments or "") end)
  else
    vim.notify(
      "ocmini: unknown subcommand '" .. sub .. "'\n"
        .. "open | hide | close | input | output | new | sessions | model | agent | mention | interrupt | status",
      vim.log.levels.WARN,
      { title = "ocmini" }
    )
  end
end

vim.api.nvim_create_user_command("Opencode", function(args)
  if args.range > 0 then require("ocmini.context").select(args.line1, args.line2) end
  run(args.fargs[1], table.concat(args.fargs, " ", 2))
end, {
  nargs = "*",
  range = true,
  complete = function()
    local commands = {
      "open",
      "hide",
      "close",
      "input",
      "output",
      "new",
      "sessions",
      "model",
      "agent",
      "mention",
      "interrupt",
      "status",
    }
    for _, action in ipairs(require("ocmini.actions").commands()) do commands[#commands + 1] = action.name end
    return commands
  end,
  desc = "ocmini: opencode panel",
})
