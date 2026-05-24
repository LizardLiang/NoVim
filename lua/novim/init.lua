local M = {}

local config = require('novim.config')
local state = require('novim.state')

function M.setup(opts)
  config.setup(opts)

  if config.options.keymaps.toggle_sidebar then
    vim.keymap.set('n', config.options.keymaps.toggle_sidebar, function()
      require('novim.sidebar').toggle()
    end, { noremap = true, silent = true, desc = 'Toggle NoVim reader sidebar' })
  end

  vim.api.nvim_create_autocmd('VimLeavePre', {
    group = vim.api.nvim_create_augroup('novim_exit', { clear = true }),
    callback = function()
      if state.current_url then
        local buf = state.reader_buf
        if buf and vim.api.nvim_buf_is_valid(buf) then
          for _, win in ipairs(vim.api.nvim_list_wins()) do
            if vim.api.nvim_win_get_buf(win) == buf then
              local line = vim.api.nvim_win_get_cursor(win)[1]
              require('novim.progress').save(state.current_url, line)
              break
            end
          end
        end
      end
    end,
  })
end

function M.toggle()
  local sidebar = require('novim.sidebar')
  local progress = require('novim.progress')

  local saved = progress.load()
  if saved and not state.current_url then
    local title = saved.url:match('chapter(%d+/%d+)%.html$') or saved.url
    local prompt = string.format('[NoVim] Resume at chapter %s (line %d)? [y/n] ', title, saved.line or 1)
    local choice = vim.fn.input(prompt)
    if choice:lower() == 'y' then
      sidebar.open()
      require('novim.reader').open(saved.url)
      vim.schedule(function()
        local buf = state.reader_buf
        if buf and vim.api.nvim_buf_is_valid(buf) then
          for _, win in ipairs(vim.api.nvim_list_wins()) do
            if vim.api.nvim_win_get_buf(win) == buf then
              local line = math.min(saved.line or 1, vim.api.nvim_buf_line_count(buf))
              vim.api.nvim_win_set_cursor(win, { line, 0 })
              break
            end
          end
        end
      end)
      return
    end
  end

  sidebar.toggle()
end

function M.statusline()
  if not state.current_url then return '' end
  local ch, sec = state.current_url:match('chapter(%d+)/(%d+)%.html$')
  if ch and sec then
    return string.format('Ch.%s / %s', ch, sec)
  end
  return ''
end

return M
