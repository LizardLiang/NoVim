local M = {}

local config = require('novim.config')
local state = require('novim.state')

local HEADER = ' NoVim'
local SEPARATOR = ' ' .. string.rep('─', 36)

local function is_valid_sidebar()
  return state.sidebar_win ~= nil
    and vim.api.nvim_win_is_valid(state.sidebar_win)
    and state.sidebar_buf ~= nil
    and vim.api.nvim_buf_is_valid(state.sidebar_buf)
end

local function render_toc()
  if not state.toc then return { HEADER, SEPARATOR, ' (loading...)' }, {} end

  local lines = { HEADER, SEPARATOR }
  local line_map = {}

  local function render_node(node, depth)
    local has_children = #node.children > 0
    local indent = string.rep('  ', depth)
    local icon
    if not has_children then
      icon = (state.current_url and node.url == state.current_url) and ' ► ' or '   '
    elseif node.expanded then
      icon = ' ▾ '
    else
      icon = ' ▸ '
    end
    local lnum = #lines + 1
    table.insert(lines, indent .. icon .. node.title)
    line_map[lnum] = { node = node }
    if has_children and node.expanded then
      for _, child in ipairs(node.children) do
        render_node(child, depth + 1)
      end
    end
  end

  for _, node in ipairs(state.toc) do
    render_node(node, 0)
  end

  return lines, line_map
end

local function set_buf_lines(buf, lines)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
end

function M.refresh_highlight()
  if not is_valid_sidebar() then return end
  local lines, new_map = render_toc()
  state.line_map = new_map
  set_buf_lines(state.sidebar_buf, lines)
end

local function handle_enter()
  local cursor_line = vim.api.nvim_win_get_cursor(state.sidebar_win)[1]
  local entry = state.line_map[cursor_line]
  if not entry then return end
  local node = entry.node
  if #node.children > 0 then
    node.expanded = not node.expanded
    M.refresh_highlight()
  elseif node.url then
    require('novim.reader').open(node.url)
  end
end

local function handle_toggle_cursor()
  local cursor_line = vim.api.nvim_win_get_cursor(state.sidebar_win)[1]
  local entry = state.line_map[cursor_line]
  if not entry then return end
  local node = entry.node
  if #node.children > 0 then
    node.expanded = not node.expanded
    M.refresh_highlight()
  end
end

local function setup_keymaps(buf)
  local function map(lhs, rhs)
    vim.keymap.set('n', lhs, rhs, { noremap = true, silent = true, buffer = buf })
  end

  map('<CR>', handle_enter)
  map('o', handle_toggle_cursor)
  map('<Tab>', handle_toggle_cursor)
  map('q', function() M.close() end)
  map('r', function()
    state.toc = nil
    state.toc_loading = false
    M.load_toc()
  end)
  map('u', function() M.edit_url() end)
  map('?', function()
    vim.notify(
      '[NoVim] Sidebar keys:\n'
        .. '  <Enter>  open / toggle expand\n'
        .. '  o / <Tab>  toggle expand\n'
        .. '  q  close sidebar\n'
        .. '  r  refresh chapter list\n'
        .. '  u  change source URL',
      vim.log.levels.INFO
    )
  end)
end

-- Applies a new source URL and reloads the chapter list.
local function apply_url(url)
  local settings = require('novim.settings')
  settings.set_source_url(url)
  state.toc = nil
  state.toc_loading = false
  vim.schedule(function()
    vim.notify('[NoVim] URL updated. Reloading...', vim.log.levels.INFO)
    M.load_toc()
  end)
end

-- Change the source URL. Pass a URL to set it directly (":NoVimUrl <url>"),
-- or omit it to be prompted with the current value pre-filled.
function M.edit_url(url)
  if url then
    url = url:match('^%s*(.-)%s*$')
    if url ~= '' then
      apply_url(url)
      return
    end
  end

  local settings = require('novim.settings')
  local current = settings.get_source_url() or ''
  vim.ui.input({ prompt = '[NoVim] Source URL: ', default = current }, function(input)
    if not input then return end -- cancelled
    input = input:match('^%s*(.-)%s*$')
    if input == '' then
      vim.notify('[NoVim] URL unchanged.', vim.log.levels.INFO)
      return
    end
    apply_url(input)
  end)
end

function M.load_toc()
  if state.toc_loading then return end

  local settings = require('novim.settings')
  local source_url = settings.get_source_url()

  if not source_url or source_url == '' then
    vim.ui.input({ prompt = '[NoVim] Enter the URL of the content to read: ' }, function(url)
      if not url or url:match('^%s*$') then
        vim.notify('[NoVim] No URL provided. Run :NoVim to try again.', vim.log.levels.WARN)
        return
      end
      settings.set_source_url(url)
      -- Schedule back onto main loop in case vim.ui.input callback is async
      vim.schedule(function()
        vim.notify('[NoVim] URL saved. Loading...', vim.log.levels.INFO)
        M.load_toc()
      end)
    end)
    return
  end

  state.toc_loading = true

  local fetcher = require('novim.fetcher')
  -- pcall so a fetch-path error (e.g. an adapter or header-merge bug that
  -- throws instead of returning `nil, err`) can't leave toc_loading stuck
  -- true and permanently block future r/reload attempts.
  local ok, toc, err = pcall(fetcher.fetch_toc, source_url)
  state.toc_loading = false

  if not ok then
    vim.notify('[NoVim] ' .. tostring(toc), vim.log.levels.ERROR)
    if is_valid_sidebar() then
      set_buf_lines(state.sidebar_buf, { HEADER, SEPARATOR, ' (error — press r to retry)' })
    end
    return
  end

  if err then
    vim.notify(err, vim.log.levels.ERROR)
    -- Clear loading indicator
    if is_valid_sidebar() then
      set_buf_lines(state.sidebar_buf, { HEADER, SEPARATOR, ' (error — press r to retry)' })
    end
    return
  end

  state.toc = toc
  vim.notify(string.format('[NoVim] Loaded %d chapter groups.', #toc), vim.log.levels.INFO)
  M.refresh_highlight()

  -- If the pasted source_url names a specific chapter and nothing has
  -- been saved for this novel yet, open that chapter now.
  local sites = require('novim.sites')
  local adapter = sites.resolve(source_url)
  local entry_chapter = adapter.entry_chapter(source_url)
  if entry_chapter and not state.current_url then
    local progress = require('novim.progress')
    local key = adapter.novel_key(source_url)
    if not progress.load(key) then
      require('novim.reader').open(source_url)
    end
  end
end

function M.open()
  if is_valid_sidebar() then
    vim.api.nvim_set_current_win(state.sidebar_win)
    return
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].swapfile = false
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].filetype = 'novim-sidebar'
  vim.bo[buf].modifiable = false
  setup_keymaps(buf)

  vim.cmd('topleft vertical ' .. config.options.sidebar_width .. ' new')
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)

  vim.wo[win].winfixwidth = true
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = 'no'
  vim.wo[win].wrap = false
  vim.wo[win].cursorline = true
  vim.wo[win].statusline = ' NoVim'
  vim.wo[win].fillchars = 'eob: '

  state.sidebar_win = win
  state.sidebar_buf = buf

  vim.api.nvim_create_autocmd('WinClosed', {
    pattern = tostring(win),
    once = true,
    callback = function()
      state.sidebar_win = nil
      state.sidebar_buf = nil
    end,
  })

  if state.toc then
    M.refresh_highlight()
  else
    set_buf_lines(buf, { HEADER, SEPARATOR, ' (loading...)' })
    M.load_toc()
  end
end

function M.close()
  if state.sidebar_win and vim.api.nvim_win_is_valid(state.sidebar_win) then
    vim.api.nvim_win_close(state.sidebar_win, true)
  end
  state.sidebar_win = nil
  state.sidebar_buf = nil
end

function M.toggle()
  if is_valid_sidebar() then
    M.close()
  else
    M.open()
  end
end

return M
