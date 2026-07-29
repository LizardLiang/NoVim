-- Cross-source novel search orchestration.
--
-- Fans a single query out to every `sites.searchable()` adapter
-- concurrently (fetcher.http_get_async), tags each adapter's results with
-- its source, and streams them back to the caller via callbacks so a
-- Telescope-style picker can refresh incrementally while a vim.ui.select
-- fallback waits for everything to settle.
--
-- Scoped to search only -- TOC/chapter fetching stay on the pre-existing
-- synchronous path (fetcher.http_get / fetcher.fetch_toc / fetcher.fetch_chapter),
-- untouched by this module.
local M = {}

-- M.run(query, on_source, on_done)
--   on_source(source_name, results, err) -- called once per adapter as it
--     settles (success, parse error, or request error/timeout). `results`
--     is a (possibly empty) list on success, nil on error.
--   on_done(all_results) -- called exactly once, after every source has
--     settled, with the full accumulated list across all sources. A
--     source that errors or times out still counts as "settled" so
--     on_done is guaranteed to fire even when every source fails --
--     otherwise a vim.ui.select fallback waiting on it would hang forever.
function M.run(query, on_source, on_done)
  local sites = require('novim.sites')
  local fetcher = require('novim.fetcher')
  local adapters = sites.searchable()

  local all_results = {}
  local pending = #adapters

  local function settle()
    pending = pending - 1
    if pending <= 0 then
      on_done(all_results)
    end
  end

  if pending == 0 then
    vim.schedule(function() on_done(all_results) end)
    return
  end

  for _, adapter in ipairs(adapters) do
    local url = adapter.search_request(query)
    fetcher.http_get_async(url, nil, function(body, err)
      if err then
        vim.notify(
          string.format('[NoVim] Search failed for %s: %s', adapter.source_name, tostring(err)),
          vim.log.levels.WARN
        )
        on_source(adapter.source_name, nil, err)
        settle()
        return
      end

      local ok, results, parse_err = pcall(adapter.parse_search, body, url)
      if not ok then
        vim.notify(
          string.format('[NoVim] Search failed for %s: %s', adapter.source_name, tostring(results)),
          vim.log.levels.WARN
        )
        on_source(adapter.source_name, nil, results)
        settle()
        return
      end
      if parse_err then
        vim.notify(
          string.format('[NoVim] Search failed for %s: %s', adapter.source_name, tostring(parse_err)),
          vim.log.levels.WARN
        )
        on_source(adapter.source_name, nil, parse_err)
        settle()
        return
      end

      for _, result in ipairs(results or {}) do
        result.source = result.source or adapter.source_name
        table.insert(all_results, result)
      end
      on_source(adapter.source_name, results, nil)
      settle()
    end)
  end
end

return M
