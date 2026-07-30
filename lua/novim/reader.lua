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

-- Selects which reader buffers to wipe after a chapter swap. Pure over a
-- description of the open buffers (mirroring M.resolve_autosave_line's
-- testability convention above) so it can be unit-tested without a live
-- reader window. Each entry: { buf, is_reader, has_window }. A buffer is
-- selected only when it is a reader buffer, is not shown in any window, and
-- is not the buffer just swapped onto -- see dispose_stale_buffers below for
-- how this turns into real nvim_buf_delete calls.
function M.buffers_to_dispose(current_buf, buf_infos)
  local stale = {}
  for _, info in ipairs(buf_infos) do
    if info.is_reader and not info.has_window and info.buf ~= current_buf then
      table.insert(stale, info.buf)
    end
  end
  return stale
end

-- Live wrapper around M.buffers_to_dispose: builds buf_infos from the real
-- editor state and wipes whatever it selects. Reader buffers are identified
-- by filetype == 'novim' (set by M.open itself below), not by bufname,
-- since the novim:// prefix is adapter-owned. Uses nvim_buf_delete (bwipeout
-- semantics) rather than a plain delete because bwipeout also frees the
-- buffer NAME -- a non-wiping delete would leave the name claimed, so the
-- bufnr-by-name lookup in M.open would later find the husk and reuse it
-- without ever re-running setup_reader_keymaps/setup_autosave, silently
-- breaking ]c/[c and progress saving on that chapter.
local function dispose_stale_buffers(current_buf)
  local windowed = {}
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    windowed[vim.api.nvim_win_get_buf(win)] = true
  end

  local buf_infos = {}
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(b) then
      table.insert(buf_infos, {
        buf = b,
        is_reader = vim.bo[b].filetype == 'novim',
        has_window = windowed[b] == true,
      })
    end
  end

  -- Each delete is pcall-wrapped per buffer, rather than wrapping the whole
  -- loop, so one bad buffer (an E937-style error, or a third-party autocmd
  -- reacting badly to BufDelete) can't stop the rest of the sweep. This
  -- runs after the new chapter's content is already swapped into the
  -- window and visible (see the comment above the call site in M.open), so
  -- a throwing delete must never propagate out of here -- doing so would
  -- skip the word-wrap options, sidebar.refresh_highlight(), and the
  -- "Loaded" notify that still need to run: cleanup must never take down a
  -- read that has already succeeded.
  for _, buf in ipairs(M.buffers_to_dispose(current_buf, buf_infos)) do
    local ok, err = pcall(vim.api.nvim_buf_delete, buf, { force = true })
    if not ok then
      vim.notify('[NoVim] Failed to clean up a stale reader buffer: ' .. tostring(err), vim.log.levels.WARN)
    end
  end
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

  -- Runs after the swap above (so BufLeave already fired the outgoing
  -- buffer's autosave) and after the fetch-error early return near the top
  -- of this function (so a failed fetch wipes nothing). See
  -- dispose_stale_buffers for what qualifies as stale.
  dispose_stale_buffers(buf)

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
