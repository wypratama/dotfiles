local M = { items = {}, drafts = {} }
local state = require('ocmini.state')
function M.leave()
  local input = require('ocmini.input')
  if state.session_id and input.buf and vim.api.nvim_buf_is_valid(input.buf) then
    M.drafts[state.session_id] = {text=table.concat(vim.api.nvim_buf_get_lines(input.buf,0,-1,false),'\n'),files=vim.deepcopy(input.pending_files)}
  end
end
function M.enter(session)
  if not session then return end
  local found = false
  for _,item in ipairs(M.items) do if item.id==session.id then item.title=session.title; found=true end end
  if not found then M.items[#M.items+1]={id=session.id,title=session.title} end
  local input = require('ocmini.input')
  local draft = M.drafts[session.id] or {text='',files={}}
  input.set_text(draft.text)
  input.pending_files=vim.deepcopy(draft.files)
  require('ocmini.history').index=nil
  require('ocmini.status').context_size=nil
  require('ocmini.status').update()
end
function M.remove(id)
  M.drafts[id]=nil
  for index,item in ipairs(M.items) do if item.id==id then table.remove(M.items,index);break end end
end
function M.pick()
  vim.ui.select(M.items,{prompt='Open sessions',format_item=function(item)
    return (item.id==state.session_id and '● ' or '  ')..(item.title or item.id)
  end},function(item) if item then require('ocmini.events').switch_session(item.id) end end)
end
function M.cycle(direction)
  if #M.items<2 then return end
  for index,item in ipairs(M.items) do
    if item.id==state.session_id then
      require('ocmini.events').switch_session(M.items[(index-1+direction)%#M.items+1].id)
      return
    end
  end
end
return M
