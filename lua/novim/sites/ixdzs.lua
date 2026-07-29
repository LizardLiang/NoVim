-- Site adapter for ixdzs.tw (and mirrors sharing the `ixdzs.` host prefix,
-- e.g. ixdzs.com).
--
-- Verified live-site facts (2026-07-29, see tactical plan):
--   * Chapter page /read/<bid>/p<N>.html: title in h1.page-d-name, body in
--     article.page-content > <section> of <p> elements.
--   * Noise inside the article: a leading <h3> duplicating the title;
--     div[id^="bg-ssp"] + inline <script>; a trailing p.abg ad after
--     </section>.
--   * Nav: a.chapter-pre / a.chapter-next. On chapter 1, a.chapter-pre
--     points at the novel INDEX (/read/<bid>/), not a chapter — that must
--     be treated as absent, not as a previous chapter.
--   * The index page (/read/<bid>/) only renders a short recent-chapters
--     preview; the full TOC is JS-filled and must be fetched separately
--     via POST /novel/html/ with form field bid=<bid> (no special headers
--     required beyond the usual defaults).
--   * The chapter-list response is a bare <li> fragment: no <ul> wrapper,
--     no volume separators.
--   * Search: GET /bsearch?q=<percent-encoded> -> ul.u-list of
--     li.burl[data-url="/read/<bid>/"], title h3.bname > a[title], author
--     span.bauthor > a, status span.lz.
local M = {}

local fetcher = require('novim.fetcher')

-- Parses `bid, chapter_id` out of an ixdzs URL. chapter_id (e.g. "p1") is
-- nil when the URL names only the novel index. Both nil when the URL
-- doesn't match the ixdzs /read/ shape. Centralised so
-- normalise_url/entry_chapter/novel_key/bufname/fetch_toc_html don't each
-- re-match the same pattern independently.
local function parse_ids(url)
  local bid, chapter_id = url:match('/read/(%d+)/(p%d+)%.html')
  if bid then return bid, chapter_id end
  bid = url:match('/read/(%d+)')
  return bid, nil
end

function M.match(url)
  return fetcher.bare_host(url):match('^ixdzs%.') ~= nil
end

-- Accepts either an index URL (/read/<bid>/) or a chapter URL
-- (/read/<bid>/p<N>.html) and returns the index URL, preserving the host
-- of the supplied URL so mirrors are never rewritten to a hardcoded host.
function M.normalise_url(url)
  local bid = parse_ids(url)
  if not bid then return url end
  return fetcher.parse_host(url) .. '/read/' .. bid .. '/'
end

-- Returns the chapter id (e.g. "p1") if `url` names a specific chapter,
-- else nil.
function M.entry_chapter(url)
  local _, chapter_id = parse_ids(url)
  return chapter_id
end

-- Keyed on book id alone (not host), so a novel opened from one ixdzs
-- mirror resumes at the position saved from another.
function M.novel_key(url)
  local bid = parse_ids(url)
  return 'ixdzs/' .. (bid or url)
end

-- The index page itself only renders the most recent handful of chapters
-- (JS-filled beyond that); the full chapter list lives behind a POST.
function M.fetch_toc_html(index_url)
  local bid = parse_ids(index_url)
  if not bid then
    return nil, '[NoVim] Could not determine book id from URL.'
  end
  return fetcher.http_post(fetcher.parse_host(index_url) .. '/novel/html/', { bid = bid })
end

-- Chapter-list response is a bare sequence of
-- <li><a href="/read/<bid>/p<N>.html">title</a></li> rows, no <ul>
-- wrapper and no volume separators -- a single flat list of leaf nodes.
function M.parse_toc(html, url)
  local host = fetcher.parse_host(url)
  local nodes = {}

  for inner in html:gmatch('<[Ll][Ii][^>]*>(.-)</[Ll][Ii]>') do
    local href = inner:match('href%s*=%s*["\']([^"\']+)["\']')
    local title = inner:match('<[Aa][^>]*>([^<]*)</[Aa]>')
    if title then title = title:match('^%s*(.-)%s*$') end

    if href and href ~= '' and title and title ~= '' then
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

-- Find the byte offset of the nearest '<' at or before `upto` -- used to
-- back up from an attribute match to the start of its owning tag.
local function nearest_tag_start(html, upto)
  for i = upto, 1, -1 do
    if html:sub(i, i) == '<' then return i end
  end
  return nil
end

-- The chapter title (h1.page-d-name) sits OUTSIDE article.page-content,
-- so it's searched across the whole document rather than the scoped
-- article content below.
local function extract_title(html)
  local class_pos = html:find('class%s*=%s*["\']page%-d%-name["\']')
  if not class_pos then return nil end
  local tag_start = nearest_tag_start(html, class_pos)
  if not tag_start then return nil end
  local tag_close = html:find('>', tag_start, true)
  if not tag_close then return nil end
  local after = html:sub(tag_close + 1)
  local lt = after:find('<')
  if not lt then return nil end
  return after:sub(1, lt - 1):match('^%s*(.-)%s*$')
end

-- Bound the chapter body to article.page-content's own matching closing
-- tag (depth-aware via the shared fetcher.find_tag_close, generalised
-- from czbooks' div-only helper). Falls back to the whole document when
-- the article can't be found, same degradation pattern czbooks uses for
-- its own chapter container.
local function article_container(html)
  local class_pos = html:find('class%s*=%s*["\']page%-content["\']')
  if not class_pos then return html end
  local tag_start = nearest_tag_start(html, class_pos)
  if not tag_start then return html end
  local tag_close = html:find('>', tag_start, true)
  if not tag_close then return html end
  local close_pos = fetcher.find_tag_close(html, 'article', tag_close + 1)
  if close_pos then
    return html:sub(tag_close + 1, close_pos - 1)
  end
  return html:sub(tag_close + 1)
end

-- Every well-formed <script>...</script> block. (strip_html_lines would
-- also catch this, but the required strip order puts it first.)
local function strip_scripts(html)
  return (html:gsub('<[Ss][Cc][Rr][Ii][Pp][Tt][^>]*>.-</%s*[Ss][Cc][Rr][Ii][Pp][Tt]%s*>', ''))
end

-- Remove every element (any tag name) whose opening tag matches
-- `attr_pattern`, scanning depth-aware via find_tag_close so a matched
-- element that itself nests other tags of the same name (e.g. a
-- div[id^="bg-ssp"] containing another div) is removed as a whole unit.
local function strip_elements(html, attr_pattern)
  local out = {}
  local pos = 1
  while true do
    local tag_start, tag_close
    local search_pos = pos
    while true do
      local s = html:find('<%a', search_pos)
      if not s then break end
      local e = html:find('>', s, true)
      if not e then break end
      if html:sub(s, e):match(attr_pattern) then
        tag_start, tag_close = s, e
        break
      end
      search_pos = e + 1
    end

    if not tag_start then
      table.insert(out, html:sub(pos))
      break
    end

    table.insert(out, html:sub(pos, tag_start - 1))
    local tag_name = html:sub(tag_start + 1, tag_close - 1):match('^(%a+)')
    local close_pos = tag_name and fetcher.find_tag_close(html, tag_name, tag_close + 1)
    if close_pos then
      local close_end = html:find('>', close_pos, true)
      pos = close_end and (close_end + 1) or (tag_close + 1)
    else
      pos = tag_close + 1
    end
  end
  return table.concat(out)
end

-- The article opens with an <h3> duplicating h1.page-d-name's text on
-- some pages; strip it when its text matches the already-extracted title
-- and it is (ignoring leading whitespace) the first element in scope.
local function strip_leading_duplicate_heading(content_html, title)
  if not title or title == '' then return content_html end
  local s, e = content_html:find('<[Hh]3[^>]*>')
  if not s then return content_html end
  if content_html:sub(1, s - 1):match('^%s*$') == nil then return content_html end

  local close_s, close_e = content_html:find('</[Hh]3%s*>', e + 1)
  if not close_s then return content_html end

  local inner_text = content_html:sub(e + 1, close_s - 1):gsub('<[^>]+>', ''):match('^%s*(.-)%s*$')
  if inner_text == title then
    return content_html:sub(1, s - 1) .. content_html:sub(close_e + 1)
  end
  return content_html
end

-- Returns true when `class_value` (the full attribute value, e.g.
-- "chapter-paging chapter-next") carries `token` as one of its
-- whitespace-separated class tokens -- not merely as a substring, so a
-- near-miss like "chapter-next-foo" or "xchapter-next" never matches
-- "chapter-next". Plain string equality per token, not a Lua pattern, so
-- callers pass the literal class name.
local function has_class_token(class_value, token)
  for cls in class_value:gmatch('%S+') do
    if cls == token then return true end
  end
  return false
end

-- Finds the href of the first <a> tag in `html` whose class attribute
-- carries `class_name` as one token among a possibly multi-valued class
-- list -- the real site emits class="chapter-paging chapter-next", not
-- the single-token class="chapter-next" the old exact-match version
-- assumed. Tolerant of either attribute order (class before href, or
-- href before class) and of `class%s*=%s*` spacing/quote-style
-- variation, same as the rest of this file.
local function extract_nav_href(html, class_name)
  local pos = 1
  while true do
    local tag_start = html:find('<[Aa]', pos)
    if not tag_start then return nil end
    local tag_end = html:find('>', tag_start, true)
    if not tag_end then return nil end
    local tag = html:sub(tag_start, tag_end)

    local class_value = tag:match('class%s*=%s*["\']([^"\']*)["\']')
    if class_value and has_class_token(class_value, class_name) then
      local href = tag:match('href%s*=%s*["\']([^"\']+)["\']')
      if href then return href end
    end

    pos = tag_end + 1
  end
end

-- Exposed (like sidebar.collect_leaf_sequence / reader.resolve_autosave_line)
-- so tests can pin exact-match vs guard-rejection behaviour separately:
-- the chapter-1 trap link IS found by this function (it's a real href),
-- and is only turned into nil by parse_chapter's own p<N>.html guard.
M.extract_nav_href = extract_nav_href

function M.parse_chapter(html, url)
  local title = extract_title(html)

  local content_html = article_container(html)
  content_html = strip_scripts(content_html)
  content_html = strip_elements(content_html, 'id%s*=%s*["\']bg%-ssp')
  content_html = strip_elements(content_html, 'class%s*=%s*["\']abg["\']')
  content_html = strip_leading_duplicate_heading(content_html, title)

  local lines = fetcher.strip_html_lines(content_html)

  local host = fetcher.parse_host(url)
  local prev_href = extract_nav_href(html, 'chapter-pre')
  local next_href = extract_nav_href(html, 'chapter-next')

  -- Chapter 1's a.chapter-pre points at the novel index (/read/<bid>/),
  -- not a chapter -- treat anything lacking a p<N>.html segment as absent
  -- rather than a real previous/next chapter link.
  local prev_url = (prev_href and prev_href:match('p%d+%.html')) and fetcher.make_absolute(prev_href, host) or nil
  local next_url = (next_href and next_href:match('p%d+%.html')) and fetcher.make_absolute(next_href, host) or nil

  return lines, prev_url, next_url, title, nil
end

-- The novel title lives on the index page itself (matches og:title there —
-- verified live 2026-07-29, tests/fixtures/ixdzs_novel_index.html is a cut
-- of the real capture), NOT on the chapter-list response, which is a bare
-- <li> fragment with no heading at all. `index_url` is already the
-- normalise_url() result (host preserved, so mirrors work same as
-- everywhere else in this file) -- just GET it directly.
function M.fetch_novel_title(index_url, callback)
  fetcher.http_get_async(index_url, nil, function(html, err)
    if err or not html then
      callback(nil, err)
      return
    end
    local title = html:match('<[Hh]1[^>]*>(.-)</[Hh]1>')
    if title then title = title:match('^%s*(.-)%s*$') end
    if not title or title == '' then
      callback(nil, '[NoVim] Could not find novel title on page.')
      return
    end
    callback(title, nil)
  end)
end

function M.bufname(url)
  local bid, chapter_id = parse_ids(url)
  if bid and chapter_id then
    return 'novim://' .. bid .. '/' .. chapter_id
  end
  return 'novim://' .. (bid or 'unknown')
end

function M.statusline(_url, title)
  return title or ''
end

-- Human-readable label for the resume prompt (init.toggle).
function M.label(url)
  return (M.bufname(url):gsub('^novim://', ''))
end

----------------------------------------------------------------------
-- Search (searchable = true)
----------------------------------------------------------------------

M.searchable = true
M.source_name = 'ixdzs'

function M.search_request(query)
  return 'https://ixdzs.tw/bsearch?q=' .. fetcher.url_encode(query)
end

-- ul.u-list of li.burl[data-url="/read/<bid>/"], title h3.bname > a[title],
-- author span.bauthor > a, status span.lz, word count span.size (e.g.
-- "303.33萬字" -- ixdzs-only; czbooks has no equivalent field).
function M.parse_search(html, url)
  local host = fetcher.parse_host(url)
  local results = {}

  for attrs, inner in html:gmatch('<[Ll][Ii]([^>]-)>(.-)</[Ll][Ii]>') do
    if attrs:match('class%s*=%s*["\']burl["\']') then
      local data_url = attrs:match('data%-url%s*=%s*["\']([^"\']+)["\']')
      local title = inner:match('[Hh]3[^>]*class%s*=%s*["\']bname["\'].-<[Aa][^>]*title%s*=%s*["\']([^"\']*)["\']')
      local author = inner:match('[Ss]pan[^>]*class%s*=%s*["\']bauthor["\'][^>]*>.-<[Aa][^>]*>([^<]*)</[Aa]>')
      local status = inner:match('[Ss]pan[^>]*class%s*=%s*["\']lz["\'][^>]*>([^<]*)</[Ss]pan>')
      local size = inner:match('[Ss]pan[^>]*class%s*=%s*["\']size["\'][^>]*>([^<]*)</[Ss]pan>')

      if title then title = title:match('^%s*(.-)%s*$') end
      if author then author = author:match('^%s*(.-)%s*$') end
      if status then status = status:match('^%s*(.-)%s*$') end
      if size then size = size:match('^%s*(.-)%s*$') end

      if data_url and title and title ~= '' then
        table.insert(results, {
          source = M.source_name,
          title = title,
          url = fetcher.make_absolute(data_url, host),
          author = author,
          status = status,
          size = size,
        })
      end
    end
  end

  return results, nil
end

return M
