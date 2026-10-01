local M = {}
function M.path(name)
  local root = require('ocmini.config').values.data_dir or (vim.fn.stdpath('state')..'/ocmini')
  return root .. '/' .. name..'.json'
end
function M.read(name, fallback)
  local file = io.open(M.path(name), 'r')
  if not file then return vim.deepcopy(fallback or {}) end
  local text = file:read('*a'); file:close()
  local ok, value = pcall(vim.json.decode, text)
  return ok and type(value) == 'table' and value or vim.deepcopy(fallback or {})
end
function M.write(name, value)
  local path = M.path(name)
  local ok, err = pcall(function()
    vim.fn.mkdir(vim.fn.fnamemodify(path, ':h'), 'p', 448)
    local temporary = path..'.'..vim.fn.getpid()..'.tmp'
    local file = assert(io.open(temporary, 'w'))
    file:write(vim.json.encode(value)); file:close()
    vim.fn.setfperm(temporary, 'rw-------')
    assert(os.rename(temporary, path))
  end)
  if not ok then require('ocmini.log').warn('Could not save '..name..': '..tostring(err)) end
  return ok
end
return M
