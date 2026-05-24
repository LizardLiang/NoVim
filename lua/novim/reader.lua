local M = {}

local config = require('novim.config')
local state = require('novim.state')
local progress = require('novim.progress')

local function url_to_bufname(url)
  local ch, sec = url:match('chapter(%d+)/(%d+)%.html$')
  if ch and sec then
    return 'novim://chapter' .. ch .. '/' .. sec
  end
  local path = url:match('/ch/(.-)%.html$') or url:match('/ch/(.+)$') or 'unknown'
  return 'novim://' .. path
end

local function find_main_win()
  local sidebar_win = state.sidebar_win
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if win ~= sidebar_win and vim.api.nvim_win_is_valid(win) then
      return win
    end
  end
  return nil
end

local function setup_reader_keymaps(buf)
  local opts = { noremap = true, silent = true, buffer = buf }
  local km = config.options.keymaps

  vim.keymap.set('n', km.next_chapter, function()
    if state.next_url then
      M.open(state.next_url)
    else
      vim.notify('[NoVim] No next chapter.', vim.log.levels.INFO)
    end
  end, opts)

  vim.keymap.set('n', km.prev_chapter, function()
    if state.prev_url then
      M.open(state.prev_url)
    else
      vim.notify('[NoVim] No previous chapter.', vim.log.levels.INFO)
    end
  end, opts)
end

local function setup_autosave(buf)
  vim.api.nvim_create_autocmd({ 'BufLeave' }, {
    buffer = buf,
    callback = function()
      if state.current_url then
        local line = vim.api.nvim_win_get_cursor(0)[1]
        progress.save(state.current_url, line)
      end
    end,
  })
end

function M.open(url)
  local fetcher = require('novim.fetcher')
  vim.notify('[NoVim] Loading...', vim.log.levels.INFO)

  local lines, prev_url, next_url, err = fetcher.fetch_chapter(url)
  if err then
    vim.notify(err, vim.log.levels.ERROR)
    return
  end

  state.current_url = url
  state.prev_url = prev_url
  state.next_url = next_url

  local bufname = url_to_bufname(url)
  local buf = vim.fn.bufnr(bufname, false)

  if buf == -1 then
    buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(buf, bufname)
    vim.bo[buf].filetype = 'novim'
    vim.bo[buf].buftype = 'nofile'
    vim.bo[buf].swapfile = false
    vim.bo[buf].bufhidden = 'hide'
    setup_reader_keymaps(buf)
    setup_autosave(buf)
  end

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].readonly = true

  state.reader_buf = buf

  local win = find_main_win()
  if win then
    vim.api.nvim_win_set_buf(win, buf)
    vim.api.nvim_set_current_win(win)
  else
    vim.cmd('vsplit')
    win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)
  end

  if config.options.word_wrap then
    vim.wo[win].wrap = true
    vim.wo[win].linebreak = true
    vim.wo[win].breakindent = true
  end
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false

  local sidebar = require('novim.sidebar')
  sidebar.refresh_highlight()

  vim.notify('[NoVim] Loaded: ' .. bufname, vim.log.levels.INFO)
end

return M
