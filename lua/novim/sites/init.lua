-- Adapter registry: resolves a URL to the site adapter that knows how to
-- parse it. Each adapter implements:
--   match(url)                -> boolean
--   normalise_url(url)        -> index URL to fetch the TOC from
--   novel_key(url)            -> stable per-novel key for progress storage
--   entry_chapter(url)        -> chapter id if `url` names a chapter, else nil
--   parse_toc(html, url)      -> nodes, err
--   parse_chapter(html, url)  -> lines, prev_url, next_url, title, err
--   bufname(url)              -> buffer name string
--   statusline(url, title)    -> statusline label string
--   label(url)                -> human-readable resume-prompt label string
--
-- All methods above are required — callers invoke them unconditionally,
-- with no `adapter.method and adapter.method(...)` optional-guard pattern.
--
-- New adapters must be listed before `legacy`, which matches every URL and
-- therefore must stay last.
local M = {}

M.adapters = {
  require('novim.sites.czbooks'),
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

return M
