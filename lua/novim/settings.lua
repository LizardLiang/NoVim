local M = {}

local config = require('novim.config')

local function path()
  local dir = config.options.data_dir or vim.fn.stdpath('data')
  return dir .. '/novim_settings.json'
end

local function load_raw()
  local f = io.open(path(), 'r')
  if not f then return {} end
  local content = f:read('*a')
  f:close()
  if not content or content == '' then return {} end
  local ok, data = pcall(vim.json.decode, content)
  if not ok or type(data) ~= 'table' then return {} end
  return data
end

local function save_raw(data)
  local ok, encoded = pcall(vim.json.encode, data)
  if not ok then return end
  local f = io.open(path(), 'w')
  if not f then
    vim.notify('[NoVim] Could not write settings: ' .. path(), vim.log.levels.WARN)
    return
  end
  f:write(encoded)
  f:close()
end

-- Returns the source URL from runtime config or saved file, nil if unset
function M.get_source_url()
  if config.options.source_url and config.options.source_url ~= '' then
    return config.options.source_url
  end
  return load_raw().source_url
end

-- Persists source URL to disk and updates runtime config
function M.set_source_url(url)
  local data = load_raw()
  data.source_url = url
  save_raw(data)
  config.options.source_url = url
end

return M
