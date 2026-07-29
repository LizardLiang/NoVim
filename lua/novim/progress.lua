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

-- `title` is optional (third param). When omitted, whatever title was
-- already stored for this novel is carried over rather than being wiped --
-- callers that don't know the title yet (e.g. init.lua's VimLeavePre exit
-- save, or a plain autosave before fetch_novel_title has resolved) must
-- not clobber a title a previous save already captured. This is reading
-- this SAME key's own already-persisted value, not the global-state
-- coupling the parent branch's autosave bug was about -- see reader.lua's
-- setup_autosave, which binds `title` per buffer exactly like `url`.
function M.save(url, line, title)
  local sites = require('novim.sites')
  local key = sites.resolve(url).novel_key(url)

  local raw = read_json(config.options.save_path)
  local data = raw and migrate(raw) or { novels = {} }
  data.novels = data.novels or {}

  local existing = data.novels[key]
  data.novels[key] = {
    url = url,
    line = line,
    title = title or (existing and existing.title) or nil,
    saved_at = os.date('!%Y-%m-%dT%H:%M:%SZ'),
  }
  data.last = key

  write_json(config.options.save_path, data)
end

-- Deletes a novel's saved progress entirely. Clears `last` too when it
-- pointed at the removed key, so the next resume prompt (init.toggle)
-- doesn't offer a novel that no longer exists. No-op if the key isn't
-- present (nothing to remove, nothing to throw about).
function M.remove(key)
  local raw = read_json(config.options.save_path)
  if not raw then return end
  local data = migrate(raw)
  if not data.novels or not data.novels[key] then return end

  data.novels[key] = nil
  if data.last == key then
    data.last = nil
  end

  write_json(config.options.save_path, data)
end

-- Sets a marker on a stored entry recording that a title fetch was
-- attempted (and failed, or the adapter has no title source) -- without
-- touching url/line -- so lua/novim/library.lua's backfill sweep doesn't
-- refire a request for a permanently unreachable/untitleable entry on
-- every library open. No-op if the key isn't present.
function M.mark_title_attempted(key)
  local raw = read_json(config.options.save_path)
  if not raw then return end
  local data = migrate(raw)
  local entry = data.novels and data.novels[key]
  if not entry then return end

  entry.title_attempted = true
  write_json(config.options.save_path, data)
end

-- Every stored novel as a flat list (each entry carries its own `key`),
-- ordered most-recently-read first (by `saved_at`, ISO-8601 UTC so plain
-- string comparison sorts correctly). Entries with an equal or missing
-- saved_at (pre-existing/legacy entries) fall back to a key comparison so
-- ordering is deterministic rather than depending on pairs() iteration
-- order. Pure aside from the read, so it's directly unit-testable.
function M.list()
  local raw = read_json(config.options.save_path)
  if not raw then return {} end
  local data = migrate(raw)

  local list = {}
  for key, entry in pairs(data.novels or {}) do
    table.insert(list, {
      key = key,
      url = entry.url,
      line = entry.line,
      title = entry.title,
      title_attempted = entry.title_attempted,
      saved_at = entry.saved_at,
    })
  end

  table.sort(list, function(a, b)
    local a_saved, b_saved = a.saved_at or '', b.saved_at or ''
    if a_saved ~= b_saved then return a_saved > b_saved end
    return a.key < b.key
  end)

  return list
end

return M
