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

  for gi, group in ipairs(state.toc) do
    local icon
    if group.is_leaf then
      icon = '   '
    elseif group.expanded then
      icon = ' ▾ '
    else
      icon = ' ▸ '
    end

    local gl = #lines + 1
    table.insert(lines, icon .. group.title)
    line_map[gl] = { type = group.is_leaf and 'leaf' or 'group', group_idx = gi }

    if group.expanded and not group.is_leaf then
      for ii, item in ipairs(group.children) do
        local marker = '   '
        if state.current_url and item.url == state.current_url then
          marker = ' ► '
        end
        local il = #lines + 1
        table.insert(lines, '    ' .. marker .. item.title)
        line_map[il] = { type = 'subitem', group_idx = gi, item_idx = ii }
      end
    end
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
  local item = state.line_map[cursor_line]
  if not item then return end

  if item.type == 'group' then
    state.toc[item.group_idx].expanded = not state.toc[item.group_idx].expanded
    M.refresh_highlight()
  elseif item.type == 'leaf' then
    local url = state.toc[item.group_idx].url
    require('novim.reader').open(url)
  elseif item.type == 'subitem' then
    local url = state.toc[item.group_idx].children[item.item_idx].url
    require('novim.reader').open(url)
  end
end

local function handle_toggle(group_idx)
  if not state.toc or not state.toc[group_idx] then return end
  state.toc[group_idx].expanded = not state.toc[group_idx].expanded
  M.refresh_highlight()
end

local function setup_keymaps(buf)
  local function map(lhs, rhs)
    vim.keymap.set('n', lhs, rhs, { noremap = true, silent = true, buffer = buf })
  end

  map('<CR>', handle_enter)
  map('o', function()
    local cursor_line = vim.api.nvim_win_get_cursor(state.sidebar_win)[1]
    local item = state.line_map[cursor_line]
    if item and item.type == 'group' then handle_toggle(item.group_idx) end
  end)
  map('<Tab>', function()
    local cursor_line = vim.api.nvim_win_get_cursor(state.sidebar_win)[1]
    local item = state.line_map[cursor_line]
    if item and item.type == 'group' then handle_toggle(item.group_idx) end
  end)
  map('q', function() M.close() end)
  map('r', function()
    state.toc = nil
    state.toc_loading = false
    M.load_toc()
  end)
  map('?', function()
    vim.notify(
      '[NoVim] Sidebar keys:\n'
        .. '  <Enter>  open / toggle expand\n'
        .. '  o / <Tab>  toggle expand\n'
        .. '  q  close sidebar\n'
        .. '  r  refresh chapter list',
      vim.log.levels.INFO
    )
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
  local toc, err = fetcher.fetch_toc(source_url)
  state.toc_loading = false

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
