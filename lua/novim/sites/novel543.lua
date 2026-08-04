-- Site adapter for novel543.com, plus the redirect-shim hosts that reuse its
-- URL shape.
--
-- Verified live-site facts (2026-08-04, see tactical plan):
--   * URL grammar: index /<novelId>/, full TOC /<novelId>/dir, chapter
--     /<novelId>/<seq>_<chapter>.html with later pages
--     /<novelId>/<seq>_<chapter>_<page>.html. <novelId> is digits and <seq>
--     is a per-novel constant.
--   * look.thisiscm.com and look.twword.com serve only a JS redirect stub
--     with no readable content, but reuse the identical path -- so swapping
--     the host reaches the real page. They are claimed here so a pasted shim
--     URL still works.
--   * Index page: novel title in <h1 class="title">. It renders only a short
--     recent-chapters preview; the full list is on /dir, whose own
--     <h1 class="title is-2"> carries a chapter-list suffix and therefore
--     must NOT be used as the novel title.
--   * TOC: flat <li><a rel="nofollow" href="/<novelId>/<seq>_<n>.html">title
--     </a></li> rows, no volume separators, served in ascending order. The
--     page's own navigation also uses <li><a>, so rows are filtered by href
--     shape rather than taken wholesale.
--   * Chapter page: div#chapterWarp > div.chapter-content holds a bare <h1>
--     (the title, with a trailing " (1/2)" page counter) and div.content
--     (the body <p> elements). Noise inside the body: div.gadBlock,
--     div.adBlock, <script>, <ins>.
--   * Navigation is JavaScript, not anchors: li.prevBtn / li.nextBtn carry no
--     href at all. The real links are declared as `var prevUrl = '...'` and
--     `var nextUrl = '...'`. On chapter 1 page 1, prevUrl points at the
--     page's own URL -- that is the "no previous chapter" sentinel, not a
--     link. nextUrl walks the chapter's own pages and then rolls into the
--     next chapter; prevUrl always lands on a chapter's first page.
--   * Search (/search/<keyword>, per min/main.20.js) answers 403 behind a
--     Cloudflare interactive challenge even with browser headers, so this
--     adapter is not searchable. The read paths above are not challenged.
local M = {}

local fetcher = require('novim.fetcher')

local CANONICAL_HOST = 'https://www.novel543.com'

-- Hosts that serve only a JS redirect stub while reusing novel543's exact
-- path shape.
local SHIM_HOSTS = { 'thisiscm.com', 'twword.com' }

-- Upper bound on parse_chapter's page walk, so a chapter whose page chain
-- never leaves itself can't loop forever.
local MAX_CHAPTER_PAGES = 20

-- Parses novel_id, seq, chapter, page out of a novel543 URL. seq/chapter are
-- nil when the URL names only the novel index; page is nil on a chapter's
-- first page. All nil when the URL doesn't match the novel543 shape.
-- Centralised so match/canonical_url/normalise_url/entry_chapter/novel_key/
-- bufname don't each re-match the same pattern independently.
local function parse_ids(url)
  local path = url:match('^https?://[^/]+(/.*)') or url
  local novel_id, seq, chapter, page = path:match('^/(%d+)/(%d+)_(%d+)_(%d+)%.html')
  if novel_id then return novel_id, seq, chapter, page end
  novel_id, seq, chapter = path:match('^/(%d+)/(%d+)_(%d+)%.html')
  if novel_id then return novel_id, seq, chapter, nil end
  novel_id = path:match('^/(%d+)')
  return novel_id, nil, nil, nil
end

-- True when `bare` is `domain` itself or any subdomain of it -- a plain
-- suffix test would also accept "notnovel543.com".
local function host_matches(bare, domain)
  return bare == domain or bare:sub(-(#domain + 1)) == '.' .. domain
end

function M.match(url)
  local bare = fetcher.bare_host(url)
  if host_matches(bare, 'novel543.com') then return true end
  for _, shim in ipairs(SHIM_HOSTS) do
    if host_matches(bare, shim) then return true end
  end
  return false
end

-- Rewrites to the canonical host (the shim hosts serve no readable content)
-- and folds a later-page chapter URL back to the chapter's first page, so a
-- stitched chapter is always entered at its top and saved progress stays
-- chapter-aligned rather than pointing mid-chapter.
function M.canonical_url(url)
  local novel_id, seq, chapter = parse_ids(url)
  if not novel_id then return url end
  if seq and chapter then
    return string.format('%s/%s/%s_%s.html', CANONICAL_HOST, novel_id, seq, chapter)
  end
  return CANONICAL_HOST .. '/' .. novel_id .. '/'
end

-- Accepts either an index URL (/<novelId>/) or a chapter URL and returns the
-- index URL on the canonical host. Never returns the /dir page: sidebar's
-- title backfill feeds this result to fetch_novel_title, and /dir's heading
-- carries a chapter-list suffix.
function M.normalise_url(url)
  local novel_id = parse_ids(url)
  if not novel_id then return url end
  return CANONICAL_HOST .. '/' .. novel_id .. '/'
end

-- Returns the chapter id (e.g. "8096_1") if `url` names a chapter, else nil.
function M.entry_chapter(url)
  local _, seq, chapter = parse_ids(url)
  if seq and chapter then return seq .. '_' .. chapter end
  return nil
end

-- Keyed on novel id alone (not host), so a novel opened from a shim host
-- resumes at the position saved from the canonical host.
function M.novel_key(url)
  local novel_id = parse_ids(url)
  return 'novel543/' .. (novel_id or url)
end

-- The index page renders only a short recent-chapters preview; the complete
-- chapter list lives on the sibling /dir page.
function M.fetch_toc_html(index_url)
  local base = index_url:gsub('/$', '')
  return fetcher.http_get(base .. '/dir')
end

-- The dir page carries TWO chapter lists: a short descending "latest
-- chapters" preview, and below it the complete ascending list, whose <ul>
-- is the one marked with an `all` class token. Scope to the latter -- a
-- document-wide <li> scan picks up the preview's rows as extra chapters
-- (a live capture yielded 1151 rows for 1139 real chapters, the first 12 of
-- them descending from the end of the book). Falls back to the whole
-- document when no such list is present, the same degradation pattern the
-- chapter parsers use.
local function chapter_list_scope(html)
  local pos = 1
  while true do
    local tag_start = html:find('<%s*[Uu][Ll]', pos)
    if not tag_start then return html end
    local tag_close = html:find('>', tag_start, true)
    if not tag_close then return html end

    local class_value = html:sub(tag_start, tag_close):match('class%s*=%s*["\']([^"\']*)["\']')
    for cls in (class_value or ''):gmatch('%S+') do
      if cls == 'all' then
        local close_pos = fetcher.find_tag_close(html, 'ul', tag_close + 1)
        return close_pos and html:sub(tag_close + 1, close_pos - 1)
           or html:sub(tag_close + 1)
      end
    end

    pos = tag_close + 1
  end
end

function M.parse_toc(html, url)
  local host = fetcher.parse_host(url)
  local nodes = {}

  for inner in chapter_list_scope(html):gmatch('<[Ll][Ii][^>]*>(.-)</[Ll][Ii]>') do
    local href = inner:match('href%s*=%s*["\']([^"\']+)["\']')
    local title = inner:match('<[Aa][^>]*>([^<]*)</[Aa]>')
    if title then title = title:match('^%s*(.-)%s*$') end

    -- Chapter rows only: the page's own navigation is <li><a> as well.
    if href and href:match('^/%d+/%d+_%d+%.html$') and title and title ~= '' then
      table.insert(nodes, {
        title = title,
        url = fetcher.make_absolute(href, host),
        children = {},
        is_leaf = true,
        expanded = false,
      })
    end
  end

  if #nodes == 0 then
    return nil, '[NoVim] No chapters found. Check the URL points to a supported page.'
  end

  return nodes, nil
end

-- Bound `html` to the chapter body: div.content nested inside
-- div.chapter-content. Both bounds are depth-aware via fetcher.find_tag_close
-- so nested divs don't terminate the scan early. Falls back to the wider
-- scope when a container can't be found, the same degradation pattern the
-- czbooks and ixdzs adapters use.
local function content_container(html)
  local scope = html
  local outer = html:find('class%s*=%s*["\']chapter%-content')
  if outer then
    local tag_start = fetcher.nearest_tag_start(html, outer)
    local tag_close = tag_start and html:find('>', tag_start, true)
    if tag_close then
      local close_pos = fetcher.find_tag_close(html, 'div', tag_close + 1)
      scope = close_pos and html:sub(tag_close + 1, close_pos - 1)
           or html:sub(tag_close + 1)
    end
  end

  -- Anchored right after the quote so class="chapter-content" can't match.
  local inner = scope:find('class%s*=%s*["\']content')
  if not inner then return scope end
  local tag_start = fetcher.nearest_tag_start(scope, inner)
  if not tag_start then return scope end
  local tag_close = scope:find('>', tag_start, true)
  if not tag_close then return scope end
  local close_pos = fetcher.find_tag_close(scope, 'div', tag_close + 1)
  if close_pos then
    return scope:sub(tag_close + 1, close_pos - 1)
  end
  return scope:sub(tag_close + 1)
end

-- The chapter heading is a bare <h1> inside div.chapter-content. The search
-- is scoped to that container because the index and dir pages use
-- <h1 class="title"> for entirely different text.
local function extract_title(html)
  local scope = html
  local anchor = html:find('class%s*=%s*["\']chapter%-content')
  if anchor then scope = html:sub(anchor) end
  local raw = scope:match('<[Hh]1[^>]*>(.-)</[Hh]1>')
  if not raw then return nil end
  local text = raw:gsub('<[^>]+>', ''):match('^%s*(.-)%s*$')
  if text == '' then return nil end
  return text
end

-- Drops a trailing " (1/2)" page counter: once the pages are stitched the
-- reader shows the whole chapter, so the counter would misreport it.
local function strip_page_counter(title)
  if not title then return nil end
  return (title:gsub('%s*%(%d+/%d+%)%s*$', ''))
end

-- One page's body as text lines: scoped to the content container, with ads,
-- scripts and the page's own heading removed.
local function page_lines(html)
  local content = content_container(html)
  content = content:gsub('<[Hh]1[^>]*>.-</[Hh]1>', '')
  content = fetcher.strip_scripts(content)
  content = fetcher.strip_elements(content, 'class%s*=%s*["\']gadBlock')
  content = fetcher.strip_elements(content, 'class%s*=%s*["\']adBlock')
  content = content:gsub('<[Ii][Nn][Ss][^>]*>.-</%s*[Ii][Nn][Ss]%s*>', '')
  content = content:gsub('<[Ii][Nn][Ss][^>]*/?>', '')
  return fetcher.strip_html_lines(content)
end

-- Reads a `var <name> = '...'` navigation link out of the page's inline
-- script -- li.prevBtn / li.nextBtn carry no href to read instead.
local function script_url(html, name)
  return html:match('var%s+' .. name .. '%s*=%s*[\'"]([^\'"]+)[\'"]')
end

-- Path portion of an href, so same-chapter tests work whether the site emits
-- a relative or an absolute link.
local function href_path(href)
  return href:match('^https?://[^/]+(/.*)') or href
end

function M.parse_chapter(html, url)
  local title = strip_page_counter(extract_title(html))
  local host = fetcher.parse_host(url)
  local novel_id, seq, chapter = parse_ids(url)

  local lines = page_lines(html)
  local prev_href = script_url(html, 'prevUrl')
  local next_href = script_url(html, 'nextUrl')

  -- Walk the rest of the chapter. nextUrl stays inside the chapter
  -- (/<id>/<seq>_<chapter>_<page>.html) until the final page, where it points
  -- at the following chapter instead -- that shape change is what ends the
  -- loop.
  local same_chapter
  if novel_id and seq and chapter then
    same_chapter = string.format('^/%s/%s_%s_%%d+%%.html$', novel_id, seq, chapter)
  end

  local pages = 1
  local truncated
  while same_chapter and next_href and href_path(next_href):match(same_chapter) do
    if pages >= MAX_CHAPTER_PAGES then
      truncated = string.format('[NoVim] Chapter truncated after %d pages.', MAX_CHAPTER_PAGES)
      break
    end
    local page_html, err = fetcher.http_get(fetcher.make_absolute(next_href, host))
    if not page_html then
      truncated = err or '[NoVim] Could not fetch the rest of this chapter.'
      break
    end
    for _, line in ipairs(page_lines(page_html)) do
      table.insert(lines, line)
    end
    next_href = script_url(page_html, 'nextUrl')
    pages = pages + 1
  end

  -- A page that couldn't be fetched truncates the chapter but never discards
  -- what was already read -- the notice says so in-buffer.
  if truncated then
    table.insert(lines, '')
    table.insert(lines, truncated)
  end

  local prev_url = prev_href and fetcher.make_absolute(prev_href, host) or nil
  local next_url = next_href and fetcher.make_absolute(next_href, host) or nil
  -- On the first chapter prevUrl points at the chapter's own URL; treat that
  -- sentinel as absent rather than as a link back to itself.
  if prev_url == url then prev_url = nil end
  if next_url == url then next_url = nil end

  return lines, prev_url, next_url, title, nil
end

-- The novel title lives on the index page as <h1 class="title">. `index_url`
-- is already normalise_url's result, so it is the index and not /dir --
-- whose heading carries a chapter-list suffix.
function M.fetch_novel_title(index_url, callback)
  fetcher.http_get_async(index_url, nil, function(html, err)
    if err or not html then
      callback(nil, err)
      return
    end
    local raw = html:match('<[Hh]1[^>]*class%s*=%s*["\']title["\'][^>]*>(.-)</[Hh]1>')
    local title = raw and raw:gsub('<[^>]+>', ''):match('^%s*(.-)%s*$')
    if not title or title == '' then
      callback(nil, '[NoVim] Could not find novel title on page.')
      return
    end
    callback(title, nil)
  end)
end

function M.bufname(url)
  local novel_id, seq, chapter = parse_ids(url)
  if novel_id and seq and chapter then
    return 'novim://' .. novel_id .. '/' .. seq .. '_' .. chapter
  end
  return 'novim://' .. (novel_id or 'unknown')
end

function M.statusline(_url, title)
  return title or ''
end

-- Human-readable label for the resume prompt (init.toggle).
function M.label(url)
  return (M.bufname(url):gsub('^novim://', ''))
end

-- Not searchable: /search/<keyword> is served behind a Cloudflare interactive
-- challenge (403 "Just a moment...") that the plugin's HTTP client cannot
-- satisfy. Declared explicitly so the search flow skips this adapter by flag
-- rather than by probing for search methods.
M.searchable = false

return M
