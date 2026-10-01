local M = {}
local api = require('ocmini.api')
local state = require('ocmini.state')
local function notify(message,level) vim.notify(message,level or vim.log.levels.INFO,{title='OpenCode diff'}) end
local function root()
  return state.session and state.session.location and state.session.location.directory or vim.fn.getcwd()
end
local function query(all)
  if not all then return {} end
  local users={}
  for _,message in ipairs(api.messages(state.session_id) or {}) do if message.type=='user' then users[#users+1]=message.id end end
  return #users>0 and {from=users[1],to=users[#users]} or {}
end
local function path_for(directory,file)
  local path=vim.fn.simplify(file:sub(1,1)=='/' and file or directory..'/'..file)
  directory=vim.fn.fnamemodify(directory,':p'):gsub('/$','')
  if path:sub(1,#directory+1)~=directory..'/' then return nil,'File lies outside this session workspace: '..file end
  local current=path
  while current~=directory and #current>#directory do
    local stat=vim.uv.fs_lstat(current)
    if stat and stat.type=='link' then return nil,'Cannot revert through a symbolic link: '..file end
    current=vim.fn.fnamemodify(current,':h')
  end
  return path
end
local function read(path)
  local file=io.open(path,'rb')
  if not file then return {exists=false} end
  local data=file:read('*a');file:close()
  return {exists=true,data=data,permissions=vim.fn.getfperm(path)}
end
local function digest(value)
  return value.exists and vim.fn.sha256(value.data) or 'absent'
end
local function modified(path)
  for _,buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_name(buf)==path and vim.bo[buf].modified then return true end
  end
  return false
end
-- Check first: git apply rejects changed or unsafe paths without altering files.
function M.apply(files,directory,session_id)
  session_id = session_id or state.session_id
  if state.session_id == session_id and state.streaming then return false,'Interrupt the current turn before reverting files' end
  local backup={sessionID=session_id,title=state.title,time=os.time(),directory=directory,files={}}
  local patches={}
  for _,file in ipairs(files) do
    local path,err=path_for(directory,file.file)
    if not path then return false,err end
    if modified(path) then return false,'Save or discard your buffer edits before reverting '..path end
    local before=read(path)
    backup.files[#backup.files+1]={path=path,before=before}
    patches[#patches+1]=file.patch
  end
  local patch=table.concat(patches,'\n')
  if patch=='' then return false,'No changes to revert' end
  local check=vim.system({'git','apply','--reverse','--check','--whitespace=nowarn'}, {cwd=directory,stdin=patch,text=true}):wait(5000)
  if check.code~=0 then return false,check.stderr~='' and check.stderr or 'Patch no longer applies cleanly' end
  -- Persist the original content before the first write.
  local store=require('ocmini.storage')
  local snapshots=store.read('snapshots')
  local id=tostring(vim.uv.hrtime()); backup.id=id
  snapshots[id]=backup
  if not store.write('snapshots',snapshots) then return false,'Could not save a restore point; no files changed' end
  local result=vim.system({'git','apply','--reverse','--whitespace=nowarn'}, {cwd=directory,stdin=patch,text=true}):wait(5000)
  if result.code~=0 then return false,result.stderr end
  for _,file in ipairs(backup.files) do file.after=digest(read(file.path)) end
  store.write('snapshots',snapshots)
  vim.cmd('checktime')
  return true
end
local function confirm(files,directory,session_id)
  session_id = session_id or state.session_id
  vim.ui.select({'Cancel','Revert changes'},{prompt='Revert changes in '..#files..' file(s)? A restore point will be saved.'},function(choice)
    if choice~='Revert changes' then return end
    local ok,err=M.apply(files,directory,session_id)
    notify(ok and 'Files reverted. /snapshots can restore them.' or tostring(err),ok and vim.log.levels.INFO or vim.log.levels.ERROR)
  end)
end
function M.revert(all)
  local files=api.diff(state.session_id,query(all))
  if not files or #files==0 then notify('No file changes in this range');return end
  confirm(files,root())
end
function M.open(all)
  local session_id=state.session_id
  local files=api.diff(state.session_id,query(all))
  if not files or #files==0 then notify('No file changes in this range');return end
  local directory=root()
  local lines,positions={},{}
  for index,file in ipairs(files) do
    positions[index]=#lines+1
    lines[#lines+1]=string.format('File: %s (+%d -%d)',file.file,file.additions or 0,file.deletions or 0)
    vim.list_extend(lines,vim.split(file.patch or '', '\n',{plain=true}))
    lines[#lines+1]=''
  end
  vim.cmd('tabnew')
  local buf=vim.api.nvim_get_current_buf()
  vim.bo[buf].buftype='nofile';vim.bo[buf].bufhidden='wipe';vim.bo[buf].swapfile=false
  vim.bo[buf].filetype='diff'
  vim.api.nvim_buf_set_name(buf,'ocmini://diff/'..tostring(vim.uv.hrtime()))
  vim.api.nvim_buf_set_lines(buf,0,-1,false,lines)
  vim.bo[buf].modifiable=false
  local function current()
    local row=vim.api.nvim_win_get_cursor(0)[1];local index=1
    for i,position in ipairs(positions) do if row>=position then index=i end end
    return index
  end
  local function map(key,callback,desc) vim.keymap.set('n',key,callback,{buffer=buf,desc=desc}) end
  map('q',function()vim.cmd('tabclose')end,'Close OpenCode diff')
  map(']f',function()vim.api.nvim_win_set_cursor(0,{positions[math.min(current()+1,#files)],0})end,'Next changed file')
  map('[f',function()vim.api.nvim_win_set_cursor(0,{positions[math.max(current()-1,1)],0})end,'Previous changed file')
  map('gr',function()confirm({files[current()]},directory,session_id)end,'Revert this file')
  map('gR',function()confirm(files,directory,session_id)end,'Revert all reviewed files')
  map('gf',function()
    local path,err=path_for(directory,files[current()].file)
    if path then vim.cmd('tabedit '..vim.fn.fnameescape(path)) else notify(err,vim.log.levels.ERROR) end
  end,'Open this file')
  notify(']f/[f: files; gr: revert file; gR: revert all; gf: open file; q: close')
end
function M.restore_snapshot(snapshot)
  for _,file in ipairs(snapshot.files) do
    if modified(file.path) then return false,'Unsaved buffer changes: '..file.path end
    if not file.after or digest(read(file.path))~=file.after then return false,'File changed since the revert: '..file.path end
    local _,err=path_for(snapshot.directory,file.path)
    if err then return false,err end
  end
  for _,file in ipairs(snapshot.files) do
    if file.before.exists then
      vim.fn.mkdir(vim.fn.fnamemodify(file.path,':h'),'p')
      local handle=io.open(file.path,'wb')
      if not handle then return false,'Cannot restore '..file.path end
      handle:write(file.before.data);handle:close()
      vim.fn.setfperm(file.path,file.before.permissions)
    elseif vim.fn.filereadable(file.path)==1 then
      local ok,err=os.remove(file.path)
      if not ok then return false,err end
    end
  end
  local store=require('ocmini.storage');local snapshots=store.read('snapshots');snapshots[snapshot.id]=nil;store.write('snapshots',snapshots)
  vim.cmd('checktime')
  return true
end
function M.restore()
  local items={}
  for _,snapshot in pairs(require('ocmini.storage').read('snapshots')) do
    if snapshot.sessionID==state.session_id then items[#items+1]=snapshot end
  end
  table.sort(items,function(a,b)return a.time>b.time end)
  if #items==0 then notify('No local restore points for this session');return end
  vim.ui.select(items,{prompt='Restore point',format_item=function(item)return os.date('%Y-%m-%d %H:%M:%S',item.time)..' — '..#item.files..' file(s)' end},function(item)
    if not item then return end
    vim.ui.select({'Cancel','Restore files'},{prompt='Restore the files saved before this revert?'},function(choice)
      if choice=='Restore files' then local ok,err=M.restore_snapshot(item);notify(ok and 'Files restored' or tostring(err),ok and vim.log.levels.INFO or vim.log.levels.ERROR) end
    end)
  end)
end
return M
