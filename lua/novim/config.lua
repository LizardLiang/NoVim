local M = {}

M.defaults = {
  sidebar_width = 40,
  save_path = nil,
  source_url = nil,  -- set by user or prompted on first run; persisted to disk
  keymaps = {
    next_chapter = ']c',
    prev_chapter = '[c',
    toggle_sidebar = '<leader>nv',
  },
  word_wrap = true,
}

M.options = vim.deepcopy(M.defaults)

function M.setup(opts)
  M.options = vim.tbl_deep_extend('force', M.defaults, opts or {})
  if not M.options.save_path then
    M.options.save_path = vim.fn.stdpath('data') .. '/novim_progress.json'
  end
end

return M
