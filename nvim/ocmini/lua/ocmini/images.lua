local M = {}
local function notify(message,level) vim.notify(message,level or vim.log.levels.INFO,{title='OpenCode image'}) end
function M.attach(path)
  path=vim.fn.fnamemodify(vim.fn.expand(path),':p')
  if vim.fn.filereadable(path)~=1 or not path:lower():match('%.png$') and not path:lower():match('%.jpe?g$') and not path:lower():match('%.webp$') and not path:lower():match('%.gif$') then
    notify('Choose a readable PNG, JPEG, WebP or GIF image',vim.log.levels.ERROR);return false
  end
  local input=require('ocmini.input')
  input.pending_files[#input.pending_files+1]={uri=vim.uri_from_fname(path),name=vim.fn.fnamemodify(path,':t')}
  notify('Attached '..vim.fn.fnamemodify(path,':t'))
  return true
end
function M.paste()
  local command
  if vim.fn.executable('wl-paste')==1 then command={'wl-paste','--no-newline','--type','image/png'}
  elseif vim.fn.executable('xclip')==1 then command={'xclip','-selection','clipboard','-t','image/png','-o'}
  else notify('Install wl-clipboard or xclip, or use /image /path/to/image.png',vim.log.levels.WARN);return end
  vim.system(command,{},function(result)
    vim.schedule(function()
      if result.code~=0 or not result.stdout or result.stdout:sub(1,8)~='\137PNG\r\n\26\n' then notify('Clipboard does not contain a PNG image',vim.log.levels.WARN);return end
      local directory=vim.fn.stdpath('cache')..'/ocmini-images'
      vim.fn.mkdir(directory,'p',448)
      local path=directory..'/'..tostring(vim.uv.hrtime())..'.png'
      local file=io.open(path,'wb')
      if not file then notify('Could not save clipboard image',vim.log.levels.ERROR);return end
      file:write(result.stdout);file:close();vim.fn.setfperm(path,'rw-------')
      M.attach(path)
    end)
  end)
end
return M
