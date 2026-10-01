local M = { editor = nil, selection = nil }
local a = vim.api
local function editor_buffer(buf)
  return a.nvim_buf_is_valid(buf) and vim.bo[buf].buftype == '' and a.nvim_buf_get_name(buf) ~= ''
end
function M.capture(buf)
  buf = buf or a.nvim_get_current_buf()
  if editor_buffer(buf) then M.editor = buf end
end
function M.setup()
  M.capture()
  a.nvim_create_autocmd('BufEnter', {
    group = a.nvim_create_augroup('ocmini_context', {clear = true}),
    callback = function(event) M.capture(event.buf) end,
  })
end
function M.select(first, last)
  local buf = a.nvim_get_current_buf()
  if not editor_buffer(buf) then return false end
  M.capture(buf)
  local mode = vim.fn.mode()
  local selected
  if not first then
    local from, to
    if mode == 'v' or mode == 'V' or mode == '\22' then
      from, to = vim.fn.getpos('v'), vim.fn.getpos('.')
    else from, to = vim.fn.getpos("'<"), vim.fn.getpos("'>"); mode = vim.fn.visualmode() end
    if from[2] > to[2] or from[2] == to[2] and from[3] > to[3] then from,to=to,from end
    first,last=from[2],to[2]
    if first < 1 then return false end
    if mode == 'v' then
      local endline=a.nvim_buf_get_lines(buf,last-1,last,false)[1] or ''
      local ending=math.min(to[3]-1+#vim.fn.strcharpart(endline:sub(to[3]),0,1),#endline)
      selected=a.nvim_buf_get_text(buf,first-1,math.min(from[3]-1,#(a.nvim_buf_get_lines(buf,first-1,first,false)[1] or '')),last-1,ending,{})
    elseif mode == '\22' then
      selected={}
      local left,right=math.min(from[3],to[3]),math.max(from[3],to[3])
      for _,line in ipairs(a.nvim_buf_get_lines(buf,first-1,last,false)) do selected[#selected+1]=line:sub(left,right) end
    end
  end
  first, last = math.min(first, last), math.max(first, last)
  if first < 1 then return false end
  M.selection = {file = a.nvim_buf_get_name(buf), first = first, last = last,
    text = table.concat(selected or a.nvim_buf_get_lines(buf,first-1,last,false),'\n')}
  return true
end
function M.prepare(text, files)
  local opts = require('ocmini.config').values.context
  local attachments = vim.deepcopy(files or {})
  if not opts.enabled then return text, attachments end
  local sections = {}
  local buf = M.editor
  if buf and editor_buffer(buf) then
    local name = a.nvim_buf_get_name(buf)
    if opts.current_file then
      if vim.fn.filereadable(name) == 1 then
        local uri = vim.uri_from_fname(name)
        local found = false
        for _, file in ipairs(attachments) do if file.uri == uri then found = true end end
        if not found then attachments[#attachments+1] = {uri = uri, name = vim.fn.fnamemodify(name, ':t')} end
      end
      sections[#sections+1] = 'Current file: '..name
      if vim.bo[buf].modified or vim.fn.filereadable(name) == 0 then
        sections[#sections+1] = 'Unsaved buffer contents (first '..opts.max_lines..' lines):\n'..table.concat(a.nvim_buf_get_lines(buf,0,opts.max_lines,false),'\n')
      end
    end
    if opts.diagnostics then
      local diagnostics = {}
      for _, d in ipairs(vim.diagnostic.get(buf)) do
        if d.severity <= vim.diagnostic.severity.WARN then
          diagnostics[#diagnostics+1] = string.format('%s:%d:%d: %s',name,d.lnum+1,d.col+1,d.message)
          if #diagnostics >= 20 then break end
        end
      end
      if #diagnostics > 0 then sections[#sections+1] = 'Diagnostics:\n'..table.concat(diagnostics,'\n') end
    end
  end
  if opts.selection and M.selection then
    local selection = M.selection
    sections[#sections+1] = string.format('Selection %s:%d-%d:\n%s',selection.file,selection.first,selection.last,selection.text)
  end
  if opts.git_diff then
    local result = vim.system({'git','diff','--no-ext-diff','--no-color'}, {cwd=vim.fn.getcwd(),text=true}):wait(3000)
    if result.code == 0 and result.stdout ~= '' then sections[#sections+1] = 'Working tree diff:\n'..result.stdout:sub(1,30000) end
  end
  if #sections > 0 then text = text..'\n\n<editor_context>\n'..table.concat(sections,'\n\n')..'\n</editor_context>' end
  return text, attachments
end
function M.pick()
  local opts = require('ocmini.config').values.context
  local keys = {'enabled','current_file','selection','diagnostics','git_diff','clear_selection'}
  vim.ui.select(keys,{prompt='Editor context',format_item=function(key)
    if key == 'clear_selection' then return 'Clear staged selection' end
    return (opts[key] and '[x] ' or '[ ] ')..key
  end},function(key)
    if not key then return end
    if key == 'clear_selection' then M.selection = nil else opts[key] = not opts[key] end
  end)
end
return M
