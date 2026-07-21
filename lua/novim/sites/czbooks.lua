-- Site adapter for czbooks.net.
--
-- Verified live-site facts (2026-07-20, see tactical plan):
--   * TOC page: <ul class = "nav chapter-list" id = "chapter-list"> holding
--     flat <li><a href="//czbooks.net/n/<novelId>/<chapterId>">title</a></li>
--     rows interleaved with <li class = "volume">label</li> separators.
--   * Chapter page: title in <div class = "name">, body in
--     <div class = "content"> terminated by <div class = "notice">.
--   * Nav (<a class = "prev-chapter"> / <a class = "next-chapter">) sits
--     outside div.content, so no leakage risk. Chapter 1 has no prev-chapter.
--   * Attributes are written with spaces around "=" (class = "content"),
--     so every match below is tolerant of that spacing.
--   * All internal hrefs are protocol-relative (//czbooks.net/...).
local M = {}

local fetcher = require('novim.fetcher')

-- Parses `/n/<novelId>(/<chapterId>)?` out of a czbooks URL. Returns
-- novel_id, chapter_id — chapter_id is nil when the URL names only the
-- novel index. Both nil when the URL doesn't match the czbooks shape.
-- Centralised so normalise_url/entry_chapter/novel_key/bufname don't each
-- re-match the same pattern independently.
local function parse_ids(url)
  local novel_id, chapter_id = url:match('/n/([^/?#]+)/([^/?#]+)')
  if novel_id then return novel_id, chapter_id end
  novel_id = url:match('/n/([^/?#]+)')
  return novel_id, nil
end

function M.match(url)
  return fetcher.bare_host(url) == 'czbooks.net'
end

-- Accepts either an index URL (/n/<novelId>) or a chapter URL
-- (/n/<novelId>/<chapterId>) and returns the index URL. Never appends
-- /index.html — czbooks has no such convention.
function M.normalise_url(url)
  local novel_id = parse_ids(url)
  if not novel_id then return url end
  return 'https://czbooks.net/n/' .. novel_id
end

-- Returns the chapter id if `url` names a specific chapter, else nil.
function M.entry_chapter(url)
  local _, chapter_id = parse_ids(url)
  return chapter_id
end

function M.novel_key(url)
  local novel_id = parse_ids(url)
  return 'czbooks.net/' .. (novel_id or url)
end

function M.parse_toc(html, url)
  local list_start = html:find('id%s*=%s*["\']chapter%-list["\']')
  if not list_start then
    return nil, '[NoVim] Could not find chapter list on this page. Try a direct chapter URL.'
  end
  local tag_close = html:find('>', list_start, true)
  if not tag_close then
    return nil, '[NoVim] Could not find chapter list on this page. Try a direct chapter URL.'
  end

  local rest = html:sub(tag_close + 1)
  local list_end = rest:find('</%s*[Uu][Ll]%s*>')
  local list_html = list_end and rest:sub(1, list_end - 1) or rest

  local host = fetcher.parse_host(url)
  local groups = {}
  local current = nil

  local function new_group(title)
    current = { title = title, url = nil, children = {}, expanded = false }
    table.insert(groups, current)
  end

  for tag, inner in list_html:gmatch('<[Ll][Ii]([^>]-)>(.-)</[Ll][Ii]>') do
    if tag:match('class%s*=%s*["\']volume["\']') then
      local label = inner:match('^%s*(.-)%s*$')
      new_group(label ~= '' and label or '章節')
    else
      local href = inner:match('href%s*=%s*["\']([^"\']+)["\']')
      local title = inner:match('<[Aa][^>]*>([^<]*)</[Aa]>')
      if title then title = title:match('^%s*(.-)%s*$') end

      if href and href ~= '' and title and title ~= '' then
        if not current then
          new_group('章節')
        end
        table.insert(current.children, {
          title = title,
          url = fetcher.make_absolute(href, host),
          children = {},
          is_leaf = true,
          expanded = false,
        })
      end
    end
  end

  for _, group in ipairs(groups) do
    group.is_leaf = false
  end

  if #groups == 0 then
    return nil, '[NoVim] No chapters found. Check the URL points to a supported page.'
  end

  return groups, nil
end

-- Find the byte offset of the nearest '<' at or before `upto` — used to
-- back up from an attribute match to the start of its owning tag.
local function nearest_tag_start(html, upto)
  for i = upto, 1, -1 do
    if html:sub(i, i) == '<' then return i end
  end
  return nil
end

-- Depth-aware walk that finds the byte offset of the '<' that begins the
-- closing </div> matching the div whose opening tag ends at `start_pos`
-- (i.e. `start_pos` is the byte right after that opening tag's '>').
-- Nested <div>...</div> pairs are tracked so a div nested inside the one
-- we're bounding doesn't terminate the scan early. Returns nil if no
-- matching close is found (malformed/truncated HTML) — callers should
-- fall back to a secondary terminator in that case rather than treating
-- the rest of the document as in-scope.
local function find_div_close(html, start_pos)
  local depth = 1
  local pos = start_pos
  local len = #html
  while pos <= len do
    local open_s, open_e = html:find('<%s*[Dd][Ii][Vv][%s>]', pos)
    local close_s, close_e = html:find('<%s*/%s*[Dd][Ii][Vv]%s*>', pos)
    if not close_s then
      return nil
    end
    if open_s and open_s < close_s then
      depth = depth + 1
      pos = open_e + 1
    else
      depth = depth - 1
      if depth == 0 then
        return close_s
      end
      pos = close_e + 1
    end
  end
  return nil
end

-- Byte range (start, end-exclusive-ish sub bounds) of the container the
-- chapter's title/content live in. Anchoring the class="name" /
-- class="content" probes inside this range — rather than searching from
-- byte 1 of the whole document — prevents a decoy element sharing the
-- same class earlier in the page (nav, ads, related-novel widgets) from
-- silently winning a first-match-wins scan. `id="wrapper"` is the
-- outermost element present around both on real czbooks chapter pages
-- (see tests/fixtures/czbooks_chapter1.html, captured from the live
-- site). Falls back to the whole document when absent so an unexpected
-- markup change degrades to prior (unscoped) behaviour instead of
-- breaking outright.
local function chapter_container(html)
  local id_pos = html:find('id%s*=%s*["\']wrapper["\']')
  if not id_pos then return html end
  local tag_close = html:find('>', id_pos, true)
  if not tag_close then return html end
  local close_pos = find_div_close(html, tag_close + 1)
  local content_end = close_pos and (close_pos - 1) or #html
  return html:sub(tag_close + 1, content_end)
end

function M.parse_chapter(html, url)
  local scope = chapter_container(html)

  local title
  local title_attr = scope:find('class%s*=%s*["\']name["\']')
  if title_attr then
    local tclose = scope:find('>', title_attr, true)
    if tclose then
      local after = scope:sub(tclose + 1)
      local lt = after:find('<')
      if lt then
        title = after:sub(1, lt - 1):match('^%s*(.-)%s*$')
      end
    end
  end

  local content_attr = scope:find('class%s*=%s*["\']content["\']')
  if not content_attr then
    return nil, nil, nil, nil, '[NoVim] Could not find content on page.'
  end
  local content_tag_close = scope:find('>', content_attr, true)
  if not content_tag_close then
    return nil, nil, nil, nil, '[NoVim] Could not find content on page.'
  end

  -- Bound the content div to its own matching close tag (depth-aware, so
  -- it survives nested divs such as div.notice living inside it) rather
  -- than reading unboundedly to the end of the document/scope.
  local content_close = find_div_close(scope, content_tag_close + 1)
  local content_html
  if content_close then
    content_html = scope:sub(content_tag_close + 1, content_close - 1)
  else
    -- Malformed/unclosed div.content: fall back to a secondary
    -- terminator (chapter-nav sits immediately after content on real
    -- pages) instead of reading to the end of the document.
    local rest = scope:sub(content_tag_close + 1)
    local nav_pos = rest:find('class%s*=%s*["\']chapter%-nav["\']')
    content_html = nav_pos and rest:sub(1, nav_pos - 1) or rest
  end

  -- div.notice is nested inside div.content on real pages; trim it off
  -- when present. Its absence is not an error — some chapters render
  -- without it — the bound above already keeps content_html scoped to
  -- content's own closing tag in that case.
  local notice_attr = content_html:find('class%s*=%s*["\']notice["\']')
  if notice_attr then
    local notice_tag_start = nearest_tag_start(content_html, notice_attr)
    content_html = notice_tag_start and content_html:sub(1, notice_tag_start - 1)
      or content_html:sub(1, notice_attr - 1)
  end

  local lines = fetcher.strip_html_lines(content_html)

  local host = fetcher.parse_host(url)

  local prev_href = html:match('<[Aa][^>]*class%s*=%s*["\']prev%-chapter["\'][^>]*href%s*=%s*["\']([^"\']+)["\']')
                  or html:match('<[Aa][^>]*href%s*=%s*["\']([^"\']+)["\'][^>]*class%s*=%s*["\']prev%-chapter["\']')
  local next_href = html:match('<[Aa][^>]*class%s*=%s*["\']next%-chapter["\'][^>]*href%s*=%s*["\']([^"\']+)["\']')
                  or html:match('<[Aa][^>]*href%s*=%s*["\']([^"\']+)["\'][^>]*class%s*=%s*["\']next%-chapter["\']')

  local prev_url = prev_href and fetcher.make_absolute(prev_href, host) or nil
  local next_url = next_href and fetcher.make_absolute(next_href, host) or nil

  return lines, prev_url, next_url, title, nil
end

function M.bufname(url)
  local novel_id, chapter_id = parse_ids(url)
  if novel_id and chapter_id then
    return 'novim://' .. novel_id .. '/' .. chapter_id
  end
  return 'novim://' .. (novel_id or 'unknown')
end

function M.statusline(_url, title)
  return title or ''
end

-- Human-readable label for the resume prompt (init.toggle). A separate
-- contract method rather than callers stripping the novim:// prefix off
-- bufname() themselves.
function M.label(url)
  return (M.bufname(url):gsub('^novim://', ''))
end

return M
