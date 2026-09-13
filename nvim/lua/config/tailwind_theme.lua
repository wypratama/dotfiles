-- Reads each project's own Tailwind v4 `@theme` CSS block and feeds the
-- resolved custom/semantic color tokens (e.g. `primary-100`, a non-standard
-- `neutral-40` step) into nvim-colorizer.lua's context-free name matcher.
--
-- Why this exists: the tailwindcss LSP can only see tokens inside a
-- `class="..."` attribute or a registered `classFunctions` call, so a bare
-- object literal like `{ root: 'bg-primary-100' }` is invisible to it no
-- matter what. This reads the actual CSS theme directly instead, so those
-- tokens get the *correct* color anywhere they appear as plain text, with no
-- changes needed in the project itself.
local M = {}

-- root -> { css_path, mtime, names } | false (checked, nothing found)
local cache = {}
-- Merged across every project visited this session (colorizer's custom name
-- table is global, not per-buffer, so this is too -- see setup()).
M.custom_names = {}

---@param value string
---@return string|nil hex without '#', or nil if unparseable
local function value_to_hex(value)
  value = vim.trim(value)

  local h6 = value:match("^#(%x%x%x%x%x%x)$")
  if h6 then
    return h6:lower()
  end
  local r3, g3, b3 = value:match("^#(%x)(%x)(%x)$")
  if r3 then
    return (r3:rep(2) .. g3:rep(2) .. b3:rep(2)):lower()
  end

  local ok, color = pcall(require, "colorizer.color")
  if not ok then
    return nil
  end

  local function fmt(r, g, b)
    if not r then
      return nil
    end
    return string.format("%02x%02x%02x", math.floor(r + 0.5), math.floor(g + 0.5), math.floor(b + 0.5))
  end

  local function nums(args)
    local out = {}
    for n in args:gmatch("[%d%.]+%%?") do
      table.insert(out, n)
    end
    return out
  end

  local oklch_args = value:match("^oklch%((.-)%)$")
  if oklch_args then
    local n = nums(oklch_args)
    if #n >= 3 then
      local l = tonumber((n[1]:gsub("%%", "")))
      if n[1]:match("%%$") then
        l = l / 100
      end
      local c = tonumber((n[2]:gsub("%%", "")))
      local h = tonumber((n[3]:gsub("%%", "")))
      if l and c and h then
        return fmt(color.oklch_to_rgb(l, c, h))
      end
    end
    return nil
  end

  local rgb_args = value:match("^rgba?%((.-)%)$")
  if rgb_args then
    local n = nums(rgb_args)
    if #n >= 3 then
      local function chan(s)
        if s:match("%%$") then
          return tonumber((s:gsub("%%", ""))) / 100 * 255
        end
        return tonumber(s)
      end
      return fmt(chan(n[1]), chan(n[2]), chan(n[3]))
    end
    return nil
  end

  local hsl_args = value:match("^hsla?%((.-)%)$")
  if hsl_args then
    local n = nums(hsl_args)
    if #n >= 3 then
      local h = tonumber((n[1]:gsub("%%", ""))) / 360
      local s = tonumber((n[2]:gsub("%%", ""))) / 100
      local l = tonumber((n[3]:gsub("%%", ""))) / 100
      return fmt(color.hsl_to_rgb(h, s, l))
    end
    return nil
  end

  return nil
end

--- Extract `--color-<name>: <value>;` declarations from `@theme { ... }` blocks.
--- Handles an optional modifier keyword (`@theme static { ... }`, `@theme
--- inline { ... }`) and chases `var(--x)` references -- including ones
--- pointing outside the @theme block entirely (e.g. `@theme inline` is
--- commonly used to alias a variable set in a plain `:root { ... }`).
---@param content string
---@param names table<string, string> accumulator, name -> "#hex"
local function extract_theme_colors(content, names)
  content = content:gsub("/%*.-%*/", "") -- strip CSS comments

  -- Every custom property anywhere in the file, as a resolution source for
  -- `var(...)` references that point outside the @theme block itself.
  -- Last declaration in document order wins, which is good enough for a
  -- best-effort static read (no attempt at real CSS cascade/scoping).
  local all_vars = {}
  for name, value in content:gmatch("%-%-([%w_-]+)%s*:%s*([^;]+);") do
    all_vars[name] = vim.trim(value)
  end

  local function resolve(value)
    local hops = 0
    while hops < 5 do
      local ref = value:match("^var%(%s*%-%-([%w_-]+)%s*[,)]")
      if not ref or not all_vars[ref] then
        break
      end
      value = all_vars[ref]
      hops = hops + 1
    end
    return value
  end

  local search_from = 1
  while true do
    -- `[^{]-` lazily skips any modifier keyword (static/inline/...) before {
    local s, e = content:find("@theme[^{]-{", search_from)
    if not s then
      break
    end
    -- Find the matching closing brace (theme blocks are flat, but be safe).
    local depth, i, close = 1, e + 1, nil
    while i <= #content do
      local c = content:sub(i, i)
      if c == "{" then
        depth = depth + 1
      elseif c == "}" then
        depth = depth - 1
        if depth == 0 then
          close = i
          break
        end
      end
      i = i + 1
    end
    close = close or #content
    local block = content:sub(e + 1, close - 1)

    for name, value in block:gmatch("%-%-color%-([%w_-]+)%s*:%s*([^;]+);") do
      local hex = value_to_hex(resolve(vim.trim(value)))
      if hex then
        names[name] = "#" .. hex
      end
    end
    search_from = close + 1
  end
end

local SKIP_DIRS = {
  node_modules = true,
  [".git"] = true,
  dist = true,
  build = true,
  [".next"] = true,
  [".nuxt"] = true,
  [".output"] = true,
  [".turbo"] = true,
}

--- Find a project's Tailwind v4 CSS entry point (a `.css` file that imports
--- "tailwindcss"), preferring ripgrep when available.
---@param root string
---@return string|nil
local function find_css_entry(root)
  if vim.fn.executable("rg") == 1 then
    local out = vim.fn.systemlist({
      "rg",
      "--files-with-matches",
      "--type",
      "css",
      "--glob",
      "!node_modules",
      "-e",
      [=[@import\s+["']tailwindcss]=],
      root,
    })
    if vim.v.shell_error == 0 and out[1] and out[1] ~= "" then
      return out[1]
    end
    return nil
  end

  local found
  local function walk(dir, depth)
    if found or depth > 6 then
      return
    end
    local ok, entries = pcall(vim.fn.readdir, dir)
    if not ok then
      return
    end
    for _, name in ipairs(entries) do
      if found then
        return
      end
      if not SKIP_DIRS[name] then
        local path = dir .. "/" .. name
        local stat = vim.uv.fs_stat(path)
        if stat then
          if stat.type == "directory" then
            walk(path, depth + 1)
          elseif name:match("%.css$") then
            local f = io.open(path, "r")
            if f then
              local content = f:read("*a")
              f:close()
              if content:match([=[@import%s+["']tailwindcss]=]) then
                found = path
              end
            end
          end
        end
      end
    end
  end
  walk(root, 0)
  return found
end

--- Read a CSS file and any local (relative) `@import`s it makes, one level
--- deep, so a theme split into a separate file still gets picked up.
---@param path string
---@return string
local function read_with_local_imports(path)
  local f = io.open(path, "r")
  if not f then
    return ""
  end
  local content = f:read("*a")
  f:close()

  local dir = vim.fs.dirname(path)
  local combined = { content }
  for rel in content:gmatch([=[@import%s+["'](%.[^"']+)["']]=]) do
    local imp_path = vim.fs.normalize(dir .. "/" .. rel)
    if vim.fn.filereadable(imp_path) == 0 and not imp_path:match("%.css$") then
      imp_path = imp_path .. ".css"
    end
    local imp_f = io.open(imp_path, "r")
    if imp_f then
      table.insert(combined, imp_f:read("*a"))
      imp_f:close()
    end
  end
  return table.concat(combined, "\n")
end

--- Discover and parse the theme for `root`, using the cache if still fresh.
---@param root string
---@return table<string, string>|nil names -> "#hex", or nil if none found
function M.get_theme_names(root)
  local cached = cache[root]
  if cached == false then
    return nil
  end
  if cached then
    local stat = vim.uv.fs_stat(cached.css_path)
    if stat and stat.mtime.sec == cached.mtime then
      return cached.names
    end
  end

  local css_path = find_css_entry(root)
  if not css_path then
    cache[root] = false
    return nil
  end

  local names = {}
  extract_theme_colors(read_with_local_imports(css_path), names)

  local stat = vim.uv.fs_stat(css_path)
  cache[root] = { css_path = css_path, mtime = stat and stat.mtime.sec, names = names }
  return names
end

--- Ensure the current buffer's project theme has been merged into
--- `M.custom_names`, reconfiguring colorizer if anything new was learned.
---@param base_opts table the static colorizer opts (without names.custom)
function M.refresh_for_buffer(bufnr, base_opts)
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" then
    return
  end
  local root = vim.fs.root(name, { ".git" }) or vim.fs.dirname(name)
  if not root then
    return
  end

  local theme_names = M.get_theme_names(root)
  if not theme_names or not next(theme_names) then
    return
  end

  local changed = false
  for k, v in pairs(theme_names) do
    if M.custom_names[k] ~= v then
      M.custom_names[k] = v
      changed = true
    end
  end

  if changed then
    -- `parsers.names.custom` only does plain whole-word matching, so
    -- `border-primary-100` wouldn't match a custom name registered as just
    -- "primary-100" (no prefix awareness). The built-in Tailwind matcher
    -- instead cross-products a fixed prefix list ("bg", "text", "border", ...)
    -- against a flat name->hex table, and registers each full combination
    -- ("bg-primary-100", "text-primary-100", ...) as its own trie entry. Add
    -- our discovered tokens into that same table so they get the same
    -- prefix-aware matching as Tailwind's bundled defaults, for free.
    local data = require("colorizer.data.tailwind_colors")
    for k, v in pairs(M.custom_names) do
      data.colors[k] = v:gsub("^#", "")
    end

    require("colorizer").setup(base_opts)
    pcall(function()
      require("colorizer").attach_to_buffer(bufnr)
    end)
  end
end

--- Force-reparse every cached project's theme (e.g. after editing @theme).
function M.reload()
  cache = {}
end

--- Diagnostic report for the given buffer's project: where it looked, what
--- (if anything) it found, and how many custom tokens got parsed.
---@param bufnr integer
---@return string[] lines
function M.status(bufnr)
  local lines = {}
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" then
    return { "Current buffer has no file name." }
  end
  local root = vim.fs.root(name, { ".git" }) or vim.fs.dirname(name)
  table.insert(lines, "project root: " .. tostring(root))

  local cached = cache[root]
  if cached == false then
    table.insert(lines, "css entry point: none found (searched for a .css file with @import \"tailwindcss\")")
    return lines
  elseif cached then
    table.insert(lines, "css entry point: " .. cached.css_path)
    local n = 0
    local preview = {}
    for k, v in pairs(cached.names) do
      n = n + 1
      if #preview < 15 then
        table.insert(preview, k .. " -> " .. v)
      end
    end
    table.insert(lines, "custom tokens parsed: " .. n)
    for _, p in ipairs(preview) do
      table.insert(lines, "  " .. p)
    end
    if n > #preview then
      table.insert(lines, "  ... and " .. (n - #preview) .. " more")
    end
  else
    table.insert(lines, "not checked yet for this root (open/re-open a buffer in this project, or run :TailwindThemeReload)")
  end
  return lines
end

return M
