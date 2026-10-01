local M = { trigger = nil }
function M.complete(findstart, base)
  if findstart == 1 then
    local before = vim.api.nvim_get_current_line():sub(1,vim.fn.col('.')-1)
    local start, trigger = before:match('()([@/])[%w_%.%/%-]*$')
    if not start then return -3 end
    M.trigger = trigger
    return start
  end
  local items = {}
  local function add(word, menu, path)
    if word:lower():find(base:lower(),1,true) then items[#items+1]={word=word,menu=menu,dup=0,user_data=path and vim.json.encode({path=path}) or ''} end
  end
  if M.trigger == '/' then
    for _,command in ipairs(require('ocmini.actions').commands()) do add(command.name,command.description) end
    for _,command in ipairs(require('ocmini.api').commands() or {}) do add(command.name or command.id,command.description or 'Command') end
  elseif M.trigger == '@' then
    for _,file in ipairs(require('ocmini.api').find_files(base,50) or {}) do
      if file.type~='directory' then add(file.path,'File',file.path) end
    end
    for _,agent in ipairs(require('ocmini.api').agents() or {}) do
      if not agent.hidden then add(agent.name or agent.id,'Agent') end
    end
  end
  return items
end
return M
