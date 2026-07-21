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

-- Progress file shape: { last = "<key>", novels = { ["<key>"] = { url, line, saved_at } } }
-- Older files use the single-slot shape { url, line, saved_at }; migrate
-- those in memory (rewritten to the new shape on the next save).
local function migrate(data)
  if data.novels then
    if type(data.novels) ~= 'table' then
      -- e.g. a hand-edited or corrupted file like {"novels": 5} — treat
      -- exactly like the corrupt-JSON path in read_json rather than
      -- letting `data.novels[key]` throw later in M.load/M.save.
      vim.notify('[NoVim] Progress file malformed, starting fresh.', vim.log.levels.WARN)
      return { novels = {} }
    end
    return data
  end
  if data.url then
    local sites = require('novim.sites')
    local ok, adapter = pcall(sites.resolve, data.url)
    local key = data.url
    if ok and adapter then
      local kok, k = pcall(adapter.novel_key, data.url)
      if kok and k then key = k end
    end
    return {
      last = key,
      novels = {
        [key] = { url = data.url, line = data.line, saved_at = data.saved_at },
      },
    }
  end
  return { novels = {} }
end

-- M.load(key): returns that novel's saved slot, or nil.
-- M.load(): returns the last-read novel's saved slot, or nil.
function M.load(key)
  local raw = read_json(config.options.save_path)
  if not raw then return nil end
  local data = migrate(raw)
  if key then
    return data.novels[key]
  end
  return data.last and data.novels[data.last] or nil
end

function M.save(url, line)
  local sites = require('novim.sites')
  local key = sites.resolve(url).novel_key(url)

  local raw = read_json(config.options.save_path)
  local data = raw and migrate(raw) or { novels = {} }
  data.novels = data.novels or {}

  data.novels[key] = {
    url = url,
    line = line,
    saved_at = os.date('!%Y-%m-%dT%H:%M:%SZ'),
  }
  data.last = key

  write_json(config.options.save_path, data)
end

return M
