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

-- Recursively collects every leaf node in tree order, independent of
-- expand/collapse state, together with the chain of ancestor group nodes
-- above it. Used by jump_to_chapter so a target inside a currently
-- collapsed group can still be located (and that group then expanded)
-- rather than only being able to jump to what's presently visible.
local function collect_leaves(nodes, ancestors, out)
  for _, node in ipairs(nodes) do
    if #node.children > 0 then
      local child_ancestors = {}
      for _, a in ipairs(ancestors) do table.insert(child_ancestors, a) end
      table.insert(child_ancestors, node)
      collect_leaves(node.children, child_ancestors, out)
    else
      table.insert(out, { node = node, ancestors = ancestors })
    end
  end
end

-- Exposed for tests: the pure tree-walk behind jump_to_chapter's chapter
-- numbering, without needing a live sidebar window/buffer. Returns the
-- same `leaves` shape as render_toc's third return.
function M.collect_leaf_sequence(nodes)
  local leaves = {}
  collect_leaves(nodes, {}, leaves)
  return leaves
end

-- Third return: the full-tree leaf sequence (see collect_leaves above),
-- used by jump_to_chapter to resolve a chapter number to a node.
local function render_toc()
  if not state.toc then return { HEADER, SEPARATOR, ' (loading...)' }, {}, {} end

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

  local leaves = {}
  collect_leaves(state.toc, {}, leaves)

  return lines, line_map, leaves
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

local function find_line_for_node(target_node)
  for lnum, entry in pairs(state.line_map) do
    if entry.node == target_node then return lnum end
  end
  return nil
end

-- Prompts for a chapter number and moves the cursor to it, expanding any
-- collapsed ancestor group along the way. Long flat chapter lists (e.g.
-- ixdzs, hundreds/thousands of entries with no synthetic volume
-- chunking) are otherwise only navigable by scrolling.
function M.jump_to_chapter()
  if not is_valid_sidebar() then return end
  if not state.toc then
    vim.notify('[NoVim] No chapter list loaded yet.', vim.log.levels.WARN)
    return
  end

  local _, _, leaves = render_toc()
  local count = #leaves
  if count == 0 then
    vim.notify('[NoVim] No chapters to jump to.', vim.log.levels.WARN)
    return
  end

  vim.ui.input({ prompt = string.format('[NoVim] Jump to chapter (1-%d): ', count) }, function(input)
    if not input then return end -- cancelled
    input = input:match('^%s*(.-)%s*$')
    if input == '' then return end -- cancelled/empty

    local n = tonumber(input)
    if not n or n ~= math.floor(n) or n < 1 or n > count then
      vim.notify(string.format('[NoVim] Enter a chapter number between 1 and %d.', count), vim.log.levels.WARN)
      return
    end

    local target = leaves[n]
    local needs_refresh = false
    for _, ancestor in ipairs(target.ancestors) do
      if not ancestor.expanded then
        ancestor.expanded = true
        needs_refresh = true
      end
    end
    if needs_refresh then
      M.refresh_highlight()
    end

    if not is_valid_sidebar() then return end
    local lnum = find_line_for_node(target.node)
    if not lnum then return end
    vim.api.nvim_win_set_cursor(state.sidebar_win, { lnum, 0 })
    vim.api.nvim_win_call(state.sidebar_win, function() vim.cmd('normal! zz') end)
  end)
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
  map('s', function() require('novim.picker').prompt_and_search() end)
  map('c', function() M.jump_to_chapter() end)
  map('l', function() require('novim.library').open() end)
  map('?', function()
    vim.notify(
      '[NoVim] Sidebar keys:\n'
        .. '  <Enter>  open / toggle expand\n'
        .. '  o / <Tab>  toggle expand\n'
        .. '  q  close sidebar\n'
        .. '  r  refresh chapter list\n'
        .. '  u  change source URL\n'
        .. '  s  search across sources\n'
        .. '  c  jump to chapter number\n'
        .. '  l  open novel library',
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

  local sites = require('novim.sites')
  local adapter = sites.resolve(source_url)
  local progress = require('novim.progress')
  local key = adapter.novel_key(source_url)

  -- If the pasted source_url names a specific chapter and nothing has
  -- been saved for this novel yet, open that chapter now.
  local entry_chapter = adapter.entry_chapter(source_url)
  if entry_chapter and not state.current_url then
    if not progress.load(key) then
      require('novim.reader').open(source_url)
    end
  end

  -- Capture the novel's title once, not on every TOC load (tactical plan
  -- Phase 3): only when a saved record for this novel already exists and
  -- doesn't have one yet. Async and best-effort -- fetch_novel_title runs
  -- over fetcher.http_get_async, so this never blocks or delays the
  -- chapter list that already rendered above, and on failure it's silent
  -- beyond the (rare) fetch_novel_title error -- the library just falls
  -- back to displaying the storage key. A novel with no saved record at
  -- all yet (never read) has nowhere to persist a title to and is caught
  -- by the library's own backfill sweep once it has been read.
  local saved = progress.load(key)
  if saved and not saved.title then
    local index_url = adapter.normalise_url(source_url)
    adapter.fetch_novel_title(index_url, function(title)
      if not title then return end
      local current = progress.load(key)
      if current then
        progress.save(current.url, current.line, title)
      end
    end)
  end
end

-- Makes a chosen search result the active novel: sets it as source_url,
-- opens the sidebar if closed, loads its chapter list, and resumes any
-- saved reading position for it (or stops at the TOC when there's none).
-- The previously active novel's own saved position is untouched -- it's
-- keyed independently under its own novel_key.
function M.open_search_result(result)
  local settings = require('novim.settings')
  settings.set_source_url(result.url)
  state.toc = nil
  state.toc_loading = false

  if is_valid_sidebar() then
    vim.api.nvim_set_current_win(state.sidebar_win)
    M.load_toc()
  else
    M.open() -- creates the sidebar and calls load_toc() itself
  end

  local sites = require('novim.sites')
  local progress = require('novim.progress')
  local key = sites.resolve(result.url).novel_key(result.url)
  local saved = progress.load(key)
  if saved then
    require('novim.reader').open(saved.url)
    -- Reuse the vim.schedule + clamp cursor-restore pattern from
    -- init.toggle: the reader window/buffer may not be fully settled
    -- until the next main-loop tick.
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
