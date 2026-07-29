-- Adapter registry: resolves a URL to the site adapter that knows how to
-- parse it. Each adapter implements:
--   match(url)                    -> boolean
--   normalise_url(url)            -> index URL to fetch the TOC from
--   novel_key(url)                -> stable per-novel key for progress storage
--   entry_chapter(url)            -> chapter id if `url` names a chapter, else nil
--   fetch_toc_html(index_url)     -> html, err — how the TOC page is retrieved.
--                                     Most adapters just GET index_url; an
--                                     adapter whose full chapter list isn't
--                                     reachable by plain GET (e.g. ixdzs,
--                                     which needs a POST) owns that here
--                                     instead of leaking site knowledge into
--                                     fetcher.lua.
--   parse_toc(html, url)          -> nodes, err
--   parse_chapter(html, url)      -> lines, prev_url, next_url, title, err
--   bufname(url)                  -> buffer name string
--   statusline(url, title)        -> statusline label string
--   label(url)                    -> human-readable resume-prompt label string
--   searchable                    -> boolean; declares search capability
--
-- All methods above (including fetch_toc_html) are required on every
-- adapter — callers invoke them unconditionally, with no
-- `adapter.method and adapter.method(...)` optional-guard pattern.
--
-- When `searchable == true`, the adapter additionally implements:
--   source_name              -> human-readable string used to label/group results
--   search_request(query)    -> url to GET for that query
--   parse_search(html, url)  -> results, err
-- These are gated purely by the explicit `searchable` flag, never by
-- probing for the methods' presence — a non-searchable adapter (e.g.
-- legacy) need not define them at all.
--
-- New adapters must be listed before `legacy`, which matches every URL and
-- therefore must stay last.
local M = {}

M.adapters = {
  require('novim.sites.czbooks'),
  require('novim.sites.ixdzs'),
  require('novim.sites.legacy'),
}

function M.resolve(url)
  for _, adapter in ipairs(M.adapters) do
    if adapter.match(url) then
      return adapter
    end
  end
  -- Defensive fallback; legacy.match always returns true so this is
  -- unreachable in practice as long as legacy stays registered.
  return require('novim.sites.legacy')
end

-- Ordered subset of M.adapters whose `searchable` flag is true.
function M.searchable()
  local result = {}
  for _, adapter in ipairs(M.adapters) do
    if adapter.searchable then
      table.insert(result, adapter)
    end
  end
  return result
end

return M
