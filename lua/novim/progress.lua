local M = {}

local config = require('novim.config')

local function read_json(path)
  local f = io.open(path, 'r')
  if not f then return nil end
  local content = f:read('*a')
  f:close()
  if not content or content == '' then return nil end
  local ok, data = pcall(vim.json.decode, content)
  if not ok or type(data) ~= 'table' then
    vim.notify('[NoVim] Progress file malformed, starting fresh.', vim.log.levels.WARN)
    return nil
  end
  return data
end

local function write_json(path, data)
  local ok, encoded = pcall(vim.json.encode, data)
  if not ok then return end
  local f = io.open(path, 'w')
  if not f then
    vim.notify('[NoVim] Could not write progress file: ' .. path, vim.log.levels.WARN)
    return
  end
  f:write(encoded)
  f:close()
end

function M.load()
  return read_json(config.options.save_path)
end

function M.save(url, line)
  local data = {
    url = url,
    line = line,
    saved_at = os.date('!%Y-%m-%dT%H:%M:%SZ'),
  }
  write_json(config.options.save_path, data)
end

return M
