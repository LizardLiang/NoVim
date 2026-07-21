local M = {}

M.defaults = {
  sidebar_width = 40,
  save_path = nil,
  source_url = nil,  -- set by user or prompted on first run; persisted to disk
  http_headers = {}, -- override/add outbound request headers (see fetcher.lua defaults)
  keymaps = {
    next_chapter = ']c',
    prev_chapter = '[c',
    toggle_sidebar = '<leader>nv',
  },
  word_wrap = true,
}

M.options = vim.deepcopy(M.defaults)

-- $NOVIM_DATA_DIR relocates all persisted state (progress + settings) to a
-- user-chosen directory, e.g. a OneDrive folder to sync across devices. It
-- is per-device intent, so it wins over a save_path passed to setup().
local function env_data_dir()
  local dir = vim.env.NOVIM_DATA_DIR
  if not dir or dir == '' then return nil end
  dir = vim.fn.expand(dir):gsub('[/\\]+$', '')
  local ok = pcall(vim.fn.mkdir, dir, 'p')
  if not ok or vim.fn.isdirectory(dir) == 0 then
    vim.notify('[NoVim] NOVIM_DATA_DIR not usable, falling back to default: ' .. dir, vim.log.levels.WARN)
    return nil
  end
  return dir
end

function M.setup(opts)
  M.options = vim.tbl_deep_extend('force', M.defaults, opts or {})
  local env_dir = env_data_dir()
  if env_dir then
    M.options.data_dir = env_dir
    M.options.save_path = env_dir .. '/novim_progress.json'
  else
    M.options.data_dir = vim.fn.stdpath('data')
    if not M.options.save_path then
      M.options.save_path = M.options.data_dir .. '/novim_progress.json'
    end
  end
end

return M
