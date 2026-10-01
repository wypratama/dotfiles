local M = { index = nil, draft = nil }
local function entries()
  return require('ocmini.storage').read('history')[vim.fn.getcwd()] or {}
end
function M.add(text, directory)
  if text == '' then return end
  local store = require('ocmini.storage')
  local history = store.read('history')
  local cwd = directory or vim.fn.getcwd()
  history[cwd] = history[cwd] or {}
  local items = history[cwd]
  if items[#items] ~= text then items[#items+1] = text end
  while #items > 200 do table.remove(items,1) end
  store.write('history',history)
  M.index, M.draft = nil, nil
end
local function text()
  local buf = require('ocmini.input').buf
  return buf and table.concat(vim.api.nvim_buf_get_lines(buf,0,-1,false),'\n') or ''
end
local function replace(value)
  require('ocmini.input').set_text(value)
end
function M.move(direction)
  local items = entries()
  if #items == 0 then return end
  if not M.index then M.draft = text(); M.index = #items+1 end
  M.index = math.max(1,math.min(#items+1,M.index+direction))
  replace(M.index == #items+1 and M.draft or items[M.index])
end
function M.pick()
  local items = entries()
  local ordered = {}
  for i = #items,1,-1 do ordered[#ordered+1] = items[i] end
  vim.ui.select(ordered,{prompt='Prompt history',format_item=function(item) return item:gsub('\n',' ↵ '):sub(1,180) end},function(item)
    if item then replace(item); require('ocmini.input').focus() end
  end)
end
return M
