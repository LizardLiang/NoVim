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
  local settings = require('novim.settings')
  local sites = require('novim.sites')

  -- Resolve the saved position for the novel the configured source_url
  -- actually points at, not just whatever was last read anywhere. Without
  -- this, switching source_url to a different novel (via :NoVimUrl) and
  -- restarting could offer to resume the OLD novel's position while the
  -- sidebar/TOC that opens afterward loads the NEW novel — two different
  -- novels shown at once. Only fall back to "last read anywhere" when no
  -- source_url is configured at all.
  local source_url = settings.get_source_url()
  local saved
  if source_url and source_url ~= '' then
    local key = sites.resolve(source_url).novel_key(source_url)
    saved = progress.load(key)
  else
    saved = progress.load()
  end

  if saved and not state.current_url then
    local label = sites.resolve(saved.url).label(saved.url)
    local prompt = string.format('[NoVim] Resume at %s (line %d)? [y/n] ', label, saved.line or 1)
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
  local sites = require('novim.sites')
  local adapter = sites.resolve(state.current_url)
  return adapter.statusline(state.current_url, state.chapter_title) or ''
end

return M
