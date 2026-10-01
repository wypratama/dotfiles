local api = require('ocmini.api')
local state = require('ocmini.state')
local M = {}
local actions = {}
local function notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO, {title = 'OpenCode'})
end
local function register(name, description, run) actions[name] = {name=name,description=description,run=run} end
local function refresh(ok, err)
  if ok then
    require('ocmini.events').refresh()
    require('ocmini.status').refresh()
    vim.cmd('checktime')
  else notify(tostring(err or 'Operation failed'),vim.log.levels.ERROR) end
end
local function idle()
  if state.streaming then notify('Wait for the current turn to finish or interrupt it first',vim.log.levels.WARN); return false end
  return true
end
local function fork(before)
  local session = api.fork_session(state.session_id,before)
  if session then require('ocmini.events').switch_session(session.id) end
end
register('new','Start a new session',function() local ok,err=require('ocmini.events').new_session(); if not ok then notify(err,vim.log.levels.ERROR) end end)
register('sessions','Switch session',function() require('ocmini.pickers').session() end)
register('models','Choose model',function() require('ocmini.pickers').model() end)
register('agents','Choose agent',function() require('ocmini.pickers').agent() end)
register('editor','Focus the prompt composer',function() require('ocmini.input').focus() end)
register('undo','Undo the latest user turn and its file changes',function() if idle() then refresh(api.undo(state.session_id)) end end)
register('redo','Restore the last reverted turn',function() if idle() then refresh(api.redo(state.session_id)) end end)
register('questions','Answer or reject pending questions',function() require('ocmini.questions').pick() end)
register('context','Toggle editor context sources',function() require('ocmini.context').pick() end)
register('selection','Attach the last visual selection',function() if not require('ocmini.context').select() then notify('Select text in an editor buffer first') end end)
register('history','Search previous prompts',function() require('ocmini.history').pick() end)
register('diff','Review file changes from the latest turn',function() require('ocmini.diff').open(false) end)
register('diffall','Review file changes across the session',function() require('ocmini.diff').open(true) end)
register('snapshots','Restore a saved local revert point',function() require('ocmini.diff').restore() end)
register('revert','Revert files changed by the latest turn',function() if idle() then require('ocmini.diff').revert(false) end end)
register('revertall','Revert files changed across the session',function() if idle() then require('ocmini.diff').revert(true) end end)
register('rename','Rename the current session',function(text)
  local session_id = state.session_id
  local function rename(value)
    if value and value ~= '' then
      local session=api.update_session(session_id,{title=value})
      if session and state.session_id == session_id then state.session=session; state.title=session.title; require('ocmini.status').update() end
    end
  end
  if text ~= '' then rename(text) else vim.ui.input({prompt='Session name: ',default=state.title},rename) end
end)
register('delete','Delete the current session and its children',function()
  if not idle() then return end
  local id=state.session_id
  vim.ui.select({'Keep session','Delete session and children'},{prompt='Delete '..(state.title or id)..'?'},function(choice)
    if choice ~= 'Delete session and children' then return end
    local ok,err=api.delete_session(id)
    if not ok then notify(tostring(err),vim.log.levels.ERROR); return end
    require('ocmini.tabs').remove(id)
    if state.session_id == id then require('ocmini.events').new_session() end
  end)
end)
register('fork','Fork the conversation into a new session',function() fork() end)
register('timeline','Navigate, undo or fork at a user message',function()
  local session_id = state.session_id
  local items={}
  for _,message in ipairs(api.messages(state.session_id) or {}) do
    if message.type=='user' or message.role=='user' then items[#items+1]=message end
  end
  vim.ui.select(items,{prompt='Conversation timeline',format_item=function(item) return (item.text or item.id):gsub('\n',' '):sub(1,120) end},function(item)
    if not item then return end
    vim.ui.select({'Jump to message','Fork before this message','Undo to this message'},{prompt='Message action'},function(choice)
      if state.session_id ~= session_id then notify('Session changed; reopen the timeline'); return end
      if choice=='Fork before this message' then fork(item.id)
      elseif choice=='Undo to this message' and idle() then refresh(api.revert_to(state.session_id,item.id))
      elseif choice=='Jump to message' then
        local win=state.windows.output_win
        if not win or not vim.api.nvim_win_is_valid(win) then return end
        local needle=(item.text or ''):match('[^\n]+')
        if not needle then return end
        for row,line in ipairs(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win),0,-1,false)) do
          if line:find(needle:sub(1,30),1,true) then vim.api.nvim_set_current_win(win); vim.api.nvim_win_set_cursor(win,{row,0}); break end
        end
      end
    end)
  end)
end)
register('tabs','Switch between opened sessions',function() require('ocmini.tabs').pick() end)
register('parent','Switch to the parent conversation',function()
  local session=state.session or {}
  local id=session.parentID or session.fork and session.fork.sessionID
  if id then require('ocmini.events').switch_session(id) else notify('This session has no parent') end
end)
register('children','Choose a child conversation',function()
  local items={}
  for _,session in ipairs(api.list_sessions({parentID=state.session_id,limit=100}) or {}) do items[#items+1]=session end
  vim.ui.select(items,{prompt='Child sessions',format_item=function(item) return item.title or item.id end},function(item)
    if item then require('ocmini.events').switch_session(item.id) end
  end)
end)
register('variant','Choose the current model variant',function()
  local session_id = state.session_id
  local ref=state.session and state.session.model
  if not ref then notify('Choose a model first'); return end
  local items={{id=false,name='Default'}}
  for _,model in ipairs(api.models() or {}) do
    if model.id==ref.id and model.providerID==ref.providerID then
      for _,variant in ipairs(model.variants or {}) do items[#items+1]=variant end
    end
  end
  vim.ui.select(items,{prompt='Model variant',format_item=function(item) return item.name or item.id end},function(item)
    if not item then return end
    local model=vim.deepcopy(ref); model.variant=item.id or nil
    local ok,err=api.set_model(session_id,model)
    if not ok then notify(tostring(err),vim.log.levels.ERROR)
    elseif state.session_id == session_id then state.session.model=model; require('ocmini.status').update() end
  end)
end)
register('favorites','Toggle a favorite model',function()
  local store=require('ocmini.storage'); local favorites=store.read('favorites')
  vim.ui.select(api.models() or {},{prompt='Model favorites',format_item=function(model)
    local key=model.providerID..'/'..model.id
    return (favorites[key] and '★ ' or '  ')..model.providerID..'/'..model.name
  end},function(model)
    if model then local key=model.providerID..'/'..model.id; favorites[key]=not favorites[key]; store.write('favorites',favorites) end
  end)
end)
register('mcp','View and toggle MCP server connections',function()
  local items={}
  for key,server in pairs(api.mcp() or {}) do
    if type(server)=='table' then items[#items+1]={name=server.name or key, status=type(server.status)=='table' and server.status.status or server.status or server.state} end
  end
  vim.ui.select(items,{prompt='MCP servers',format_item=function(item) return tostring(item.name)..' — '..tostring(item.status) end},function(item)
    if item then local ok,err=api.toggle_mcp(item.name,item.status=='connected'); notify(ok and 'MCP connection updated' or tostring(err),ok and vim.log.levels.INFO or vim.log.levels.ERROR) end
  end)
end)
register('compact','Compact the conversation context',function() local ok,err=api.compact(state.session_id); notify(ok and 'Compaction queued' or tostring(err)) end)
register('image','Attach an image path, or paste from clipboard',function(path)
  if path=='' then require('ocmini.images').paste() else require('ocmini.images').attach(path) end
end)
register('tools','Toggle expanded tool output',function()
  if not idle() then return end
  local options=require('ocmini.config').values.render; options.collapse_tools=not options.collapse_tools
  if not options.collapse_tools then options.tool_preview_lines=0 end
  require('ocmini.events').refresh()
end)
register('reasoning','Toggle expanded reasoning',function()
  if not idle() then return end
  local options=require('ocmini.config').values.render; options.collapse_reasoning=not options.collapse_reasoning
  require('ocmini.events').refresh()
end)
register('quick','Ask about the current buffer or selection',function(text)
  local function send(prompt)
    if prompt and prompt~='' then require('ocmini.input').set_text(prompt); require('ocmini.input').submit() end
  end
  if text~='' then send(text) else vim.ui.input({prompt='Ask OpenCode: '},send) end
end)
register('export','Export the conversation to Markdown',function(path)
  local function export(filename)
    if not filename or filename=='' then return end
    filename=vim.fn.expand(filename)
    local function write()
      local lines={'# '..(state.title or 'OpenCode'),''}
      for _,message in ipairs(api.messages(state.session_id) or {}) do
        if message.type=='user' then vim.list_extend(lines,{'## You','',message.text or '',''})
        elseif message.type=='assistant' then
          lines[#lines+1]='## OpenCode'; lines[#lines+1]=''
          for _,part in ipairs(message.content or {}) do if part.type=='text' then vim.list_extend(lines,{part.text or '',''}) end end
        end
      end
      local ok=vim.fn.writefile(vim.split(table.concat(lines,'\n'),'\n',{plain=true}),filename)==0
      notify(ok and ('Exported to '..filename) or 'Export failed')
    end
    if vim.fn.filereadable(filename)==1 then
      vim.ui.select({'Cancel','Overwrite'},{prompt='File exists: '..filename},function(choice) if choice=='Overwrite' then write() end end)
    else write() end
  end
  if path~='' then export(path) else vim.ui.input({prompt='Export path: ',default=vim.fn.getcwd()..'/opencode-session.md'},export) end
end)
register('status','Show model, agent, cost and token usage',function() require('ocmini.status').refresh(); notify(require('ocmini.status').text()) end)
register('help','Show available actions and composer shortcuts',function()
  local lines={'Enter sends; Shift-Enter adds a newline.','Ctrl-P / Ctrl-N: prompt history; Alt-V: paste image.','@ + Ctrl-X Ctrl-O: file/agent completion; # manages context.',''}
  for _,action in ipairs(M.commands()) do lines[#lines+1]='/'..action.name..' — '..action.description end
  notify(table.concat(lines,'\n'))
end)
function M.commands()
  local items=vim.tbl_values(actions)
  table.sort(items,function(a,b)return a.name<b.name end)
  return items
end
function M.is_builtin(name) return actions[name]~=nil end
function M.run(name,arguments)
  local action=actions[name]
  if not action then notify('Unknown action: '..name); return end
  action.run(arguments or '')
end
return M
