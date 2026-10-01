-- Structured questions and MCP forms use the v2 form protocol.
local api = require('ocmini.api')
local state = require('ocmini.state')
local M = { pending = {}, active = nil, generation = 0 }

local function notice(message, level)
  vim.notify(message, level or vim.log.levels.INFO, { title = 'OpenCode question' })
end

function M.visible(field, answers)
  for _, condition in ipairs(field.when or {}) do
    local value = answers[condition.key]
    if value == nil then return false end
    local equal = type(value) == 'table' and vim.tbl_contains(value, condition.value) or value == condition.value
    if condition.op == 'eq' and not equal or condition.op == 'neq' and equal then return false end
  end
  return true
end

function M.validate(field, value)
  if value == nil then return not field.required, 'An answer is required' end
  if field.type == 'number' or field.type == 'integer' then
    if type(value) ~= 'number' or value ~= value then return false, 'Enter a number' end
    if field.type == 'integer' and value % 1 ~= 0 then return false, 'Enter a whole number' end
    if field.minimum and value < field.minimum or field.maximum and value > field.maximum then return false, 'Number is outside the allowed range' end
  elseif field.type == 'multiselect' then
    if #value < (field.minItems or (field.required and 1 or 0)) or field.maxItems and #value > field.maxItems then
      return false, 'Choose the required number of options'
    end
  elseif field.type == 'string' then
    local length = vim.fn.strchars(value)
    if field.required and value == '' or field.minLength and length < field.minLength or field.maxLength and length > field.maxLength then
      return false, 'Answer length is outside the allowed range'
    end
  end
  return true
end

function M.show(form)
  if not form or not form.id or form.sessionID ~= state.session_id then return end
  M.pending[form.id] = form
  if M.active then return end
  M.active = form.id
  local generation = M.generation
  local answers = vim.empty_dict()
  local function current()
    return generation == M.generation and M.active == form.id and M.pending[form.id] ~= nil and state.session_id == form.sessionID
  end
  local function pause()
    M.active = nil
    notice('Question kept pending. Use /questions to answer it.')
  end
  local next_field
  next_field = function(index)
    if not current() then return end
    local field = form.fields[index]
    if not field then
      api.reply_form(form.sessionID, form.id, answers, function(ok, err)
        if generation ~= M.generation then return end
        M.active = nil
        if ok then
          M.pending[form.id] = nil
          notice('Answer sent')
          local _, pending = next(M.pending)
          if pending then M.show(pending) end
        else notice('Could not send answer: '..tostring(err), vim.log.levels.ERROR) end
      end)
      return
    end
    if not M.visible(field, answers) then next_field(index + 1); return end
    if field.hidden then
      if field.default ~= nil then answers[field.key] = field.default end
      next_field(index + 1); return
    end
    local prompt = (field.title or field.key)..(field.description and (' — '..field.description) or '')
    local function accept(value)
      if not current() then return end
      local ok, err = M.validate(field, value)
      if not ok then notice(err, vim.log.levels.WARN); next_field(index); return end
      if value ~= nil then answers[field.key] = value end
      next_field(index + 1)
    end
    if field.type == 'external' then
      vim.ui.select({'Open link', 'Keep pending'}, {prompt = prompt}, function(choice)
        if not current() then return end
        if choice == 'Open link' then vim.ui.open(field.url) end
        pause()
      end)
    elseif field.type == 'boolean' then
      vim.ui.select({'Yes', 'No'}, {prompt = prompt}, function(choice)
        if not current() then return end
        if not choice then pause() else accept(choice == 'Yes') end
      end)
    elseif field.type == 'multiselect' then
      local selected = vim.deepcopy(field.default or {})
      local choose
      choose = function()
        local items = { { done = true, label = 'Done ('..#selected..' selected)' } }
        for _, option in ipairs(field.options or {}) do
          items[#items+1] = { value = option.value, label = (vim.tbl_contains(selected, option.value) and '[x] ' or '[ ] ')..option.label }
        end
        if field.custom then items[#items+1] = { custom = true, label = 'Other…' } end
        vim.ui.select(items, {prompt = prompt, format_item = function(item) return item.label end}, function(item)
          if not current() then return end
          if not item then pause(); return end
          if item.done then accept(selected); return end
          if item.custom then
            vim.ui.input({prompt = 'Other answer: '}, function(value)
              if not current() then return end
              if value and value ~= '' and not vim.tbl_contains(selected, value) then selected[#selected+1] = value end
              choose()
            end)
          else
            local found = false
            for i, value in ipairs(selected) do if value == item.value then table.remove(selected, i); found = true; break end end
            if not found then selected[#selected+1] = item.value end
            choose()
          end
        end)
      end
      choose()
    elseif field.options and #field.options > 0 then
      local items = vim.deepcopy(field.options)
      if field.custom then items[#items+1] = {custom = true, label = 'Other…'} end
      if not field.required then items[#items+1] = {skip = true, label = 'Skip'} end
      vim.ui.select(items, {prompt = prompt, format_item = function(item) return item.label..(item.description and (' — '..item.description) or '') end}, function(item)
        if not current() then return end
        if not item then pause(); return end
        if item.custom then
          vim.ui.input({prompt = prompt..': '}, function(value) if not current() then return end; if value == nil then pause() else accept(value) end end)
        else accept(item.skip and nil or item.value) end
      end)
    else
      vim.ui.input({prompt = prompt..': ', default = field.default ~= nil and tostring(field.default) or nil}, function(value)
        if not current() then return end
        if value == nil then pause(); return end
        if field.type == 'number' or field.type == 'integer' then
          value = tonumber(value)
          if value == nil then notice('Enter a number',vim.log.levels.WARN); next_field(index); return end
        end
        accept(value)
      end)
    end
  end
  next_field(1)
end

function M.refresh()
  if not state.session_id then return end
  for _, form in ipairs(api.forms(state.session_id) or {}) do M.pending[form.id] = form end
end

function M.pick()
  M.refresh()
  local items = vim.tbl_values(M.pending)
  if #items == 0 then notice('No pending questions'); return end
  vim.ui.select(items, {prompt = 'Pending questions', format_item = function(form) return form.title end}, function(form)
    if not form then return end
    vim.ui.select({'Answer', 'Reject request'}, {prompt = form.title}, function(choice)
      if choice == 'Answer' then M.show(form)
      elseif choice == 'Reject request' then
        local ok, err = api.cancel_form(form.sessionID, form.id)
        if ok then M.pending[form.id] = nil else notice(tostring(err), vim.log.levels.ERROR) end
      end
    end)
  end)
end

function M.settled(id)
  M.pending[id] = nil
  if M.active == id then M.active = nil end
end

function M.reset()
  M.generation = M.generation + 1
  M.active = nil
  M.pending = {}
end
return M
