-- Novel library window: a dedicated buffer/window listing every novel
-- NoVim has saved reading progress for, ordered most-recently-read first,
-- so a previously read novel can be resumed without recalling or
-- re-searching for its URL.
--
-- A dedicated window rather than a vim.ui.select/Telescope picker
-- (tactical plan D5): vim.ui.select cannot bind a delete key, and the
-- target machine has no Telescope installed, so a picker-based library
-- would ship removal as unreachable on the user's only real path.
-- picker.lua / search.lua are deliberately not reused here.
local M = {}

local state = require('novim.state')

local HEADER = ' NoVim Library'
local SEPARATOR = ' ' .. string.rep('─', 36)

local function is_valid_library()
  return state.library_win ~= nil
    and vim.api.nvim_win_is_valid(state.library_win)
    and state.library_buf ~= nil
    and vim.api.nvim_buf_is_valid(state.library_buf)
end

-- Searchable adapters (ixdzs, czbooks) declare source_name for the search
-- picker; legacy doesn't (searchable == false, no site of its own to
-- search). Falling back to the bare host keeps every entry -- including
-- legacy ones -- distinguishable by source (spec: "source is
-- identifiable"), without requiring source_name on every adapter.
local function source_label(entry)
  local sites = require('novim.sites')
  local ok, adapter = pcall(sites.resolve, entry.url or '')
  if ok and adapter and adapter.source_name then
    return adapter.source_name
  end
  return require('novim.fetcher').bare_host(entry.url or '')
end

-- Pure so it's unit-testable without a live window/buffer, same pattern as
-- sidebar.collect_leaf_sequence. `entries` is progress.list()'s shape.
function M.render_lines(entries)
  local lines = { HEADER, SEPARATOR }
  local line_map = {}

  if #entries == 0 then
    table.insert(lines, ' (no saved novels)')
    return lines, line_map
  end

  for _, entry in ipairs(entries) do
    local label = entry.title or entry.key
    local pos = entry.line and (' — line ' .. tostring(entry.line)) or ''
    local lnum = #lines + 1
    table.insert(lines, string.format(' %s  [%s]%s', label, source_label(entry), pos))
    line_map[lnum] = entry
  end

  return lines, line_map
end

local function set_buf_lines(buf, lines)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
end

function M.render()
  if not is_valid_library() then return end
  local progress = require('novim.progress')
  local lines, line_map = M.render_lines(progress.list())
  state.library_line_map = line_map
  set_buf_lines(state.library_buf, lines)
end

-- Fires fetch_novel_title concurrently for every entry that has neither a
-- title nor a prior failed attempt, re-rendering as each one settles.
--
-- Mirrors search.lua's settle-counter discipline: fetch_novel_title's
-- contract guarantees its callback fires exactly once, success or failure
-- (fetcher.http_get_async's own timeout included), so every branch below
-- reaches either progress.save or progress.mark_title_attempted -- no
-- branch is left dangling. The pcall around the call itself is a further
-- backstop for an adapter that throws before ever reaching its callback;
-- without it that single entry would just never re-render, which is
-- harmless here (unlike search.lua's on_done, nothing downstream is
-- waiting on every entry settling) but would otherwise permanently retry
-- every open since title_attempted would never get set.
local function backfill_titles()
  local progress = require('novim.progress')
  local sites = require('novim.sites')

  local targets = {}
  for _, entry in ipairs(progress.list()) do
    if not entry.title and not entry.title_attempted then
      table.insert(targets, entry)
    end
  end
  if #targets == 0 then return end

  for _, entry in ipairs(targets) do
    local ok, adapter = pcall(sites.resolve, entry.url or '')
    if not ok or not adapter then
      progress.mark_title_attempted(entry.key)
      M.render()
    else
      local index_url = adapter.normalise_url(entry.url)
      local call_ok = pcall(adapter.fetch_novel_title, index_url, function(title)
        if title then
          progress.save(entry.url, entry.line, title)
        else
          progress.mark_title_attempted(entry.key)
        end
        M.render()
      end)
      if not call_ok then
        progress.mark_title_attempted(entry.key)
        M.render()
      end
    end
  end
end

local function handle_enter()
  local cursor_line = vim.api.nvim_win_get_cursor(state.library_win)[1]
  local entry = state.library_line_map[cursor_line]
  if not entry then return end
  M.close()
  require('novim.sidebar').open_search_result({
    title = entry.title or entry.key,
    url = entry.url,
    source = source_label(entry),
  })
end

local function handle_remove()
  local cursor_line = vim.api.nvim_win_get_cursor(state.library_win)[1]
  local entry = state.library_line_map[cursor_line]
  if not entry then return end

  local label = entry.title or entry.key
  vim.ui.input({
    prompt = string.format('[NoVim] Remove "%s"? Saved position cannot be recovered. [y/N] ', label),
  }, function(input)
    if not input then return end -- cancelled
    input = input:match('^%s*(.-)%s*$'):lower()
    if input ~= 'y' and input ~= 'yes' then return end
    require('novim.progress').remove(entry.key)
    M.render()
  end)
end

local function setup_keymaps(buf)
  local function map(lhs, rhs)
    vim.keymap.set('n', lhs, rhs, { noremap = true, silent = true, buffer = buf })
  end

  map('<CR>', handle_enter)
  map('d', handle_remove)
  map('q', function() M.close() end)
  map('r', function()
    M.render()
    backfill_titles()
  end)
  map('?', function()
    vim.notify(
      '[NoVim] Library keys:\n'
        .. '  <Enter>  open novel\n'
        .. '  d  remove novel (confirm)\n'
        .. '  q  close library\n'
        .. '  r  refresh',
      vim.log.levels.INFO
    )
  end)
end

function M.open()
  local progress = require('novim.progress')
  if #progress.list() == 0 then
    vim.notify('[NoVim] No saved novels.', vim.log.levels.INFO)
    return
  end

  if is_valid_library() then
    vim.api.nvim_set_current_win(state.library_win)
    M.render()
    backfill_titles()
    return
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].swapfile = false
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].filetype = 'novim-library'
  vim.bo[buf].modifiable = false
  setup_keymaps(buf)

  local config = require('novim.config')
  vim.cmd('topleft vertical ' .. config.options.sidebar_width .. ' new')
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)

  vim.wo[win].winfixwidth = true
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = 'no'
  vim.wo[win].wrap = false
  vim.wo[win].cursorline = true
  vim.wo[win].statusline = ' NoVim Library'
  vim.wo[win].fillchars = 'eob: '

  state.library_win = win
  state.library_buf = buf

  vim.api.nvim_create_autocmd('WinClosed', {
    pattern = tostring(win),
    once = true,
    callback = function()
      state.library_win = nil
      state.library_buf = nil
    end,
  })

  M.render()
  backfill_titles()
end

function M.close()
  if state.library_win and vim.api.nvim_win_is_valid(state.library_win) then
    vim.api.nvim_win_close(state.library_win, true)
  end
  state.library_win = nil
  state.library_buf = nil
end

return M
