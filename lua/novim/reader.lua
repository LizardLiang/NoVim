local M = {}

local config = require('novim.config')
local state = require('novim.state')
local progress = require('novim.progress')

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

-- Decide the line to save when `target_buf` is left, given the set of
-- currently open windows (as {win, buf} pairs so this stays a pure
-- function callers can unit-test without a live Neovim UI). Returns the
-- cursor line from whichever window actually displays `target_buf`, or
-- nil if no window does (the buffer was left via a swap onto a window
-- that no longer shows it -- skip the save rather than saving a cursor
-- position that belongs to some other buffer/window).
function M.resolve_autosave_line(target_buf, win_buf_pairs, cursor_fn)
  for _, pair in ipairs(win_buf_pairs) do
    if pair.buf == target_buf then
      return cursor_fn(pair.win)
    end
  end
  return nil
end

-- `url` is bound at buffer-creation time (once, since setup_autosave is
-- only called for newly created buffers -- see M.open) rather than read
-- from state.current_url inside the callback. state.current_url is
-- reassigned to the NEW chapter's url before BufLeave fires on the OLD
-- buffer, so reading it here would save the old buffer's cursor line
-- under the new novel's key. Binding at closure-creation time keeps each
-- buffer saving under its own, stable url.
--
-- `title` (the novel's title, not the chapter's -- see state.chapter_title
-- for that) is bound the exact same way, for the exact same reason: it's
-- whatever was already known for this novel at the moment THIS buffer was
-- created, not re-read from anywhere mutable when BufLeave eventually
-- fires. May be nil if the title hasn't been captured yet (fetch is async,
-- see sidebar.load_toc) -- progress.save treats an omitted/nil title as
-- "leave whatever's already stored alone", so this never wipes a title a
-- later save captures.
local function setup_autosave(buf, url, title)
  vim.api.nvim_create_autocmd({ 'BufLeave' }, {
    buffer = buf,
    callback = function()
      local win_buf_pairs = {}
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        table.insert(win_buf_pairs, { win = win, buf = vim.api.nvim_win_get_buf(win) })
      end
      local line = M.resolve_autosave_line(buf, win_buf_pairs, function(win)
        return vim.api.nvim_win_get_cursor(win)[1]
      end)
      if line then
        progress.save(url, line, title)
      end
    end,
  })
end

function M.open(url)
  local fetcher = require('novim.fetcher')
  local sites = require('novim.sites')
  vim.notify('[NoVim] Loading...', vim.log.levels.INFO)

  local lines, prev_url, next_url, title, err = fetcher.fetch_chapter(url)
  if err then
    vim.notify(err, vim.log.levels.ERROR)
    return
  end

  state.current_url = url
  state.chapter_title = title
  state.prev_url = prev_url
  state.next_url = next_url

  local bufname = sites.resolve(url).bufname(url)
  local buf = vim.fn.bufnr(bufname, false)

  if buf == -1 then
    buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(buf, bufname)
    vim.bo[buf].filetype = 'novim'
    vim.bo[buf].buftype = 'nofile'
    vim.bo[buf].swapfile = false
    vim.bo[buf].bufhidden = 'hide'
    setup_reader_keymaps(buf)

    local novel_key = sites.resolve(url).novel_key(url)
    local saved = progress.load(novel_key)
    setup_autosave(buf, url, saved and saved.title or nil)
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
