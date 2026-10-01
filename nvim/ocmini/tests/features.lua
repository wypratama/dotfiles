local script=debug.getinfo(1,'S').source:sub(2)
vim.opt.rtp:append(vim.fn.fnamemodify(script,':p:h:h'))
vim.o.swapfile=false
local a=vim.api
local failures={}
local function test(name,run)
 local ok,err=pcall(run)
 if ok then print('PASS '..name) else failures[#failures+1]=name..': '..tostring(err);print('FAIL '..failures[#failures]) end
end
local directory=vim.fn.tempname();vim.fn.mkdir(directory,'p')
local config=require('ocmini.config');config.setup({data_dir=directory..'/state',context={enabled=true}})
local state=require('ocmini.state');state.session_id='ses_test';state.session={id='ses_test',location={directory=directory}}
local api=require('ocmini.api')
test('history persists and restores an unsent draft',function()
 local input=require('ocmini.input');input.create({relative='editor',row=1,col=1,width=45,height=5,border='rounded'})
 local history=require('ocmini.history');history.add('first\nline');history.add('second');input.set_text('unsent draft')
 history.move(-1);assert(a.nvim_buf_get_lines(input.buf,0,-1,false)[1]=='second')
 history.move(-1);assert(#a.nvim_buf_get_lines(input.buf,0,-1,false)==2)
 history.move(1);history.move(1);assert(a.nvim_buf_get_lines(input.buf,0,-1,false)[1]=='unsent draft')
 input.close()
end)
test('questions submit typed, boolean, multiselect and conditional answers',function()
 local questions=require('ocmini.questions');questions.reset()
 local select_original,input_original=vim.ui.select,vim.ui.input
 local choices={2,2,2,3,1};local index=0;local inputs={'Custom answer','Details'};local input_index=0;local submitted
 vim.ui.select=function(items,_,callback) index=index+1;callback(items[choices[index]]) end
 vim.ui.input=function(_,callback) input_index=input_index+1;callback(inputs[input_index]) end
 local original=api.reply_form
 api.reply_form=function(id,form,answers,callback)assert(id=='ses_test');submitted=answers;callback(true)end
 questions.show({id='frm_test',sessionID='ses_test',title='Test',fields={
  {key='kind',type='string',required=true,custom=true,options={{value='preset',label='Preset'}}},
  {key='confirm',type='boolean'},
  {key='tags',type='multiselect',required=true,minItems=2,options={{value='a',label='A'},{value='b',label='B'}}},
  {key='details',type='string',when={{key='confirm',op='eq',value=false}}},
  {key='hidden_by_condition',type='string',required=true,when={{key='confirm',op='eq',value=true}}},
 }})
 vim.ui.select,vim.ui.input=select_original,input_original;api.reply_form=original
 assert(submitted.kind=='Custom answer');assert(submitted.confirm==false);assert(#submitted.tags==2)
 assert(submitted.details=='Details');assert(submitted.hidden_by_condition==nil);assert(questions.active==nil)
end)
test('cancelled question remains answerable and stale callbacks are ignored',function()
 local questions=require('ocmini.questions');questions.reset()
 local original=vim.ui.input;local callback
 vim.ui.input=function(_,cb)callback=cb end
 questions.show({id='frm_cancel',sessionID='ses_test',title='Test',fields={{key='text',type='string'}}})
 callback(nil);assert(questions.pending.frm_cancel and not questions.active)
 questions.show(questions.pending.frm_cancel);questions.reset();callback('stale');assert(not questions.active)
 vim.ui.input=original
end)
test('context captures unsaved editor contents, selection and diagnostics',function()
 local buf=a.nvim_create_buf(true,false);a.nvim_set_current_buf(buf);a.nvim_buf_set_name(buf,directory..'/example.lua')
 a.nvim_buf_set_lines(buf,0,-1,false,{'first','second','third'});vim.bo[buf].modified=true
 local context=require('ocmini.context');context.capture(buf);assert(context.select(2,2))
 local namespace=a.nvim_create_namespace('ocmini_test_diagnostic');vim.diagnostic.set(namespace,buf,{{lnum=1,col=0,message='test warning',severity=vim.diagnostic.severity.WARN}})
 local text,files=context.prepare('Fix this',{})
 assert(text:find('Unsaved buffer contents',1,true));assert(text:find('test warning',1,true));assert(text:find('second',1,true))
 assert(#files==0);vim.bo[buf].modified=false
end)
test('v2 command, undo and redo use the installed API shapes',function()
 local http=require('ocmini.http');local original_post,original_async,original_delete=http.post,http.post_async,http.delete
 local original_messages=api.messages;local calls={}
 http.post=function(path,body)calls[#calls+1]={path=path,body=body};return{}end
 http.post_async=function(path,body,cb)calls[#calls+1]={path=path,body=body};cb({})end
 http.delete=function(path)calls[#calls+1]={path=path};return{}end
 api.messages=function()return{{id='msg_user',type='user'},{id='msg_assistant',type='assistant'}}end
 api.command('ses_test','test','arg',function(ok)assert(ok)end)
 assert(calls[1].body.name=='test' and calls[1].body.text=='arg' and not calls[1].body.command)
 assert(api.undo('ses_test'));assert(calls[2].path:match('/revert/stage$'));assert(calls[2].body.messageID=='msg_user')
 assert(api.redo('ses_test'));assert(calls[3].path:match('/revert$'))
 http.post,http.post_async,http.delete=original_post,original_async,original_delete;api.messages=original_messages
end)
test('diff revert saves a restore point and refuses later edits',function()
 local repo=directory..'/repo';vim.fn.mkdir(repo,'p')
 assert(vim.system({'git','init',repo}):wait().code==0)
 local path=repo..'/file.txt';vim.fn.writefile({'before'},path)
 assert(vim.system({'git','add','file.txt'},{cwd=repo}):wait().code==0)
 vim.fn.writefile({'after'},path)
 local patch=vim.system({'git','diff','--no-ext-diff','--no-color'},{cwd=repo,text=true}):wait().stdout
 local diff=require('ocmini.diff');local ok,err=diff.apply({{file='file.txt',patch=patch}},repo);assert(ok,err)
 assert(vim.fn.readfile(path)[1]=='before')
 local snapshot=next(require('ocmini.storage').read('snapshots'));snapshot=require('ocmini.storage').read('snapshots')[snapshot]
 vim.fn.writefile({'later edit'},path);assert(not diff.restore_snapshot(snapshot));assert(vim.fn.readfile(path)[1]=='later edit')
 vim.fn.writefile({'before'},path);local restored,error=diff.restore_snapshot(snapshot);assert(restored,error)
 assert(vim.fn.readfile(path)[1]=='after')
 local success=diff.apply({{file='../outside.txt',patch=patch}},repo);assert(not success)
end)
test('message pagination preserves chronological order beyond one page',function()
 local http=require('ocmini.http');local original=http.get;local calls=0
 http.get=function(_,query)
  calls=calls+1
  if calls==1 then assert(query.order=='asc');return {data={{id='old',type='user'}},cursor={next='next-page'}} end
  assert(query.cursor=='next-page' and query.order==nil);return {data={{id='new',type='user'}},cursor={}}
 end
 local messages=api.messages('ses_test');http.get=original
 assert(#messages==2 and messages[1].id=='old' and messages[2].id=='new')
end)
test('empty request payloads serialize as JSON objects',function()
 local http=require('ocmini.http');local original=vim.system;local payload
 http.set_credentials('http://localhost:1','test')
 vim.system=function(command)
  for index,argument in ipairs(command)do if argument=='-d' then payload=command[index+1] end end
  return {wait=function()return{code=0,stdout='',stderr=''}end}
 end
 local _,err=http.post('/test',{});vim.system=original;http.clear_credentials()
 assert(not err);assert(payload=='{}')
end)
test('feature modules and all commands load without cyclic dependencies',function()
 for _,name in ipairs({'actions','completion','tabs','status','images','questions','diff'})do assert(require('ocmini.'..name))end
 local actions=require('ocmini.actions');assert(#actions.commands()>25);assert(actions.is_builtin('questions'));assert(actions.is_builtin('diff'))
end)
if #failures>0 then print(table.concat(failures,'\n'));vim.cmd('cquit 1')
else print('All feature checks passed');vim.cmd('qa!') end
