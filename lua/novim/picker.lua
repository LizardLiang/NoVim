-- Search result picker: Telescope when installed, vim.ui.select
-- otherwise. Neither is a hard dependency of NoVim.
--
-- Telescope streams: the picker opens immediately and its finder is
-- rebuilt as each source responds (search.run's on_source callback).
-- vim.ui.select cannot be refreshed once open, so the fallback buffers
-- everything and opens once every source has settled (search.run's
-- on_done callback). This asymmetry is intentional (tactical plan D3).
local M = {}

local function format_item(result)
  local parts = { '[' .. (result.source or '?') .. '] ' .. (result.title or '?') }
  if result.author and result.author ~= '' then
    table.insert(parts, '— ' .. result.author)
  end
  if result.status and result.status ~= '' then
    table.insert(parts, '(' .. result.status .. ')')
  end
  return table.concat(parts, ' ')
end

-- Shared by both picker paths.
local function on_select(result)
  require('novim.sidebar').open_search_result(result)
end

local function build_preview_lines(r)
  local lines = {
    'Title:  ' .. (r.title or ''),
    'Author: ' .. (r.author or ''),
    'Status: ' .. (r.status or ''),
  }
  if r.latest_chapter and r.latest_chapter ~= '' then
    table.insert(lines, 'Latest: ' .. r.latest_chapter)
  end
  table.insert(lines, 'URL:    ' .. (r.url or ''))
  return lines
end

-- Returns true if a Telescope picker was actually opened, false if
-- Telescope (or one of its submodules) isn't available, so the caller
-- can fall back to vim.ui.select.
local function run_with_telescope(query)
  local ok_pickers, pickers = pcall(require, 'telescope.pickers')
  local ok_finders, finders = pcall(require, 'telescope.finders')
  local ok_conf, telescope_config = pcall(require, 'telescope.config')
  local ok_actions, actions = pcall(require, 'telescope.actions')
  local ok_state, action_state = pcall(require, 'telescope.actions.state')
  local ok_prev, previewers = pcall(require, 'telescope.previewers')
  if not (ok_pickers and ok_finders and ok_conf and ok_actions and ok_state and ok_prev) then
    return false
  end

  local all_results = {}

  local function make_finder()
    return finders.new_table({
      results = all_results,
      entry_maker = function(result)
        return {
          value = result,
          display = format_item(result),
          ordinal = (result.title or '') .. ' ' .. (result.author or ''),
        }
      end,
    })
  end

  local previewer = previewers.new_buffer_previewer({
    title = 'NoVim Result',
    define_preview = function(self, entry)
      vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, build_preview_lines(entry.value))
    end,
  })

  local picker = pickers.new({}, {
    prompt_title = 'NoVim Search: ' .. query,
    finder = make_finder(),
    sorter = telescope_config.values.generic_sorter({}),
    previewer = previewer,
    attach_mappings = function(prompt_bufnr)
      actions.select_default:replace(function()
        local entry = action_state.get_selected_entry()
        actions.close(prompt_bufnr)
        if entry then on_select(entry.value) end
      end)
      return true
    end,
  })

  picker:find()

  local function still_open()
    return picker.prompt_bufnr ~= nil and vim.api.nvim_buf_is_valid(picker.prompt_bufnr)
  end

  local search = require('novim.search')
  search.run(query,
    function(_source, results, _err)
      for _, r in ipairs(results or {}) do
        table.insert(all_results, r)
      end
      if still_open() then
        picker:refresh(make_finder(), { reset_prompt = false })
      end
    end,
    function(all)
      if #all == 0 then
        if still_open() then
          actions.close(picker.prompt_bufnr)
        end
        vim.notify('[NoVim] No results found for "' .. query .. '".', vim.log.levels.INFO)
      end
    end
  )

  return true
end

local function run_with_ui_select(query)
  local search = require('novim.search')
  search.run(query, function() end, function(all_results)
    if #all_results == 0 then
      vim.notify('[NoVim] No results found for "' .. query .. '".', vim.log.levels.INFO)
      return
    end
    vim.ui.select(all_results, {
      prompt = 'NoVim Search: ' .. query,
      format_item = format_item,
    }, function(choice)
      if choice then on_select(choice) end
    end)
  end)
end

-- Entry point: search every searchable source for `query` and present the
-- combined results. No-op on an empty/whitespace-only query.
function M.search(query)
  if not query or query:match('^%s*$') then return end

  local has_telescope = pcall(require, 'telescope')
  if has_telescope and run_with_telescope(query) then return end

  run_with_ui_select(query)
end

-- Prompts for a query via vim.ui.input, then searches. Shared by
-- :NoVimSearch (invoked with no inline query) and the sidebar's `s` key,
-- so "query omitted -> prompt" behaves identically from either entry
-- point.
function M.prompt_and_search()
  vim.ui.input({ prompt = '[NoVim] Search: ' }, function(input)
    if not input then return end -- cancelled
    input = input:match('^%s*(.-)%s*$')
    if input == '' then return end -- cancelled/empty
    M.search(input)
  end)
end

return M
