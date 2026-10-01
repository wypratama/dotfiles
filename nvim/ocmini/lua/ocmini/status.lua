local M = { context_size = nil }
local state = require('ocmini.state')
function M.text()
  local session=state.session or {}
  local model=session.model or {}
  local tokens=session.tokens or {}
  local context=M.context_size or 0
  return string.format('%s | %s%s | context %s | output %s | $%.4f',session.agent or 'default',model.id or 'default',model.variant and ('/'..model.variant) or '',context,tokens.output or 0,session.cost or 0)
end
function M.update()
  local win=state.windows.output_win
  if not win or not vim.api.nvim_win_is_valid(win) then return end
  local panel=require('ocmini.ui.panel')
  local tabs=require('ocmini.tabs')
  local labels={' opencode '}
  if #tabs.items>1 then
    for index,item in ipairs(tabs.items) do
      labels[#labels+1]=(item.id==state.session_id and '[' or ' ')..index..(item.id==state.session_id and ']' or ' ')
    end
  end
  local session=state.session or {}
  local model=session.model or {}
  labels[#labels+1]=model.id or 'default'
  panel.set_title(win,table.concat(labels,' '))
  local count=M.context_size or 0
  local short=count>=1000 and string.format('%.1fk',count/1000) or tostring(count)
  panel.set_footer(win,string.format(' %s · ctx≈%s · $%.3f ',session.agent or 'default',short,session.cost or 0))
  local input_win=state.windows.input_win
  if input_win and vim.api.nvim_win_is_valid(input_win) then
    local label=model.id or 'default model'
    if model.variant then label=label..' · '..model.variant end
    panel.set_footer(input_win,' '..label..' ')
  end
end
function M.refresh()
  if state.session_id then
    local session=require('ocmini.api').get_session(state.session_id)
    if session then state.session=session;state.title=session.title end
    M.context_size=nil
    local messages=require('ocmini.api').messages(state.session_id,{recent=true}) or {}
    for index=#messages,1,-1 do
      local message=messages[index]
      if message.type=='assistant' and message.tokens then
        local tokens=message.tokens
        M.context_size=(tokens.input or 0)+(tokens.output or 0)+(tokens.cache and tokens.cache.read or 0)+(tokens.cache and tokens.cache.write or 0)
        break
      end
    end
  end
  M.update()
end
return M
