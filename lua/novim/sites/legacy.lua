-- Fallback adapter carrying the site rules NoVim originally hardcoded.
-- This is a MOVE from the old fetcher.lua / reader.lua / init.lua, not a
-- rewrite — every parsing regex and quirk (including the unbounded
-- extract_between(html, 'article', '/body') scan below, which never
-- actually finds an end marker) is preserved exactly so behaviour for
-- existing users is unchanged.
local M = {}

local fetcher = require('novim.fetcher')

-- Fallback adapter: claims every URL no other adapter claimed.
function M.match(_)
  return true
end

-- Normalise a user-supplied URL so it reliably resolves to an HTML page.
-- Strips trailing slash and appends /index.html when no file extension present.
function M.normalise_url(url)
  url = url:match('^%s*(.-)%s*$') -- trim whitespace
  url = url:gsub('/$', '')        -- remove trailing slash
  if not url:match('%.[a-zA-Z]+$') then
    url = url .. '/index.html'
  end
  return url
end

-- Extract the base path shared by chapter URLs
-- e.g. https://example.com/book/ch/chapter060/43.html → /book/ch/
local function parse_base_path(url)
  local path = url:match('^https?://[^/]+(/.*)')  or '/'
  -- Walk up to the parent of any chapter\d+ segment
  local base = path:match('^(.*/)chapter%d+/')
  return base or path:match('^(.*/)') or '/'
end

function M.novel_key(url)
  return fetcher.bare_host(url) .. parse_base_path(url)
end

-- No site of its own to search -- excluded from the search flow via this
-- explicit flag, not by probing for search-only methods it doesn't have.
M.searchable = false

-- Same plain-GET-of-the-index-page fetch every legacy site always used.
M.fetch_toc_html = fetcher.http_get

-- Legacy chapter URLs are never treated as an "entry chapter" to
-- auto-open — that behaviour is new, czbooks-only functionality.
function M.entry_chapter(_)
  return nil
end

function M.parse_toc(html, source_url)
  local sidebar_html = fetcher.extract_between(html, 'sidebar', 'article')
  if not sidebar_html then
    return nil, '[NoVim] Could not find chapter list on this page. Try a direct chapter URL.'
  end

  local host = fetcher.parse_host(source_url)

  -- Parse sidebar HTML into a tree by tracking <ul>/<ul> nesting depth.
  -- Each <ul> pushes the last-created node as the new parent; </ul> pops.
  local root = { children = {} }
  local stack = { root }   -- stack[#stack].children is the current insertion list
  local last_node = nil    -- most recently created node; becomes parent on next <ul>

  local pos = 1
  local slen = #sidebar_html

  while pos <= slen do
    local ts = sidebar_html:find('<', pos, true)
    if not ts then break end
    local te = sidebar_html:find('>', ts, true)
    if not te then break end

    local tag = sidebar_html:sub(ts, te)

    if tag:match('^<[Uu][Ll][%s>]') then
      if last_node then
        table.insert(stack, last_node)
        last_node = nil
      end
      pos = te + 1

    elseif tag:match('^</[Uu][Ll]') then
      if #stack > 1 then table.remove(stack) end
      last_node = nil
      pos = te + 1

    elseif tag:match('^<[Aa][%s]') then
      local href = tag:match('href="([^"]+)"') or tag:match("href='([^']+)'")
      local after_open = sidebar_html:sub(te + 1)
      local close_start, close_end = after_open:find('</[Aa]%s*>')
      local inner = close_start and after_open:sub(1, close_start - 1) or ''

      local title = inner:match('<span[^>]*class="label"[^>]*>([^<]+)<')
                 or inner:match('^%s*([^<\n]+)')
      if title then title = title:match('^%s*(.-)%s*$') end

      if title and title ~= '' then
        local url = href
        if url then
          url = url:match('^%s*(.-)%s*$')
          if url == '#' or url == '' then url = nil end
          if url and url:sub(1, 1) == '/' then url = host .. url end
          if url and not url:match('^https?://') then url = nil end
        end

        local node = { title = title, url = url, children = {}, expanded = false }
        table.insert(stack[#stack].children, node)
        last_node = node
      end

      pos = close_end and (te + close_end + 1) or (te + 1)

    else
      pos = te + 1
    end
  end

  -- Derive is_leaf: true when a node has no children
  local function mark_leaves(nodes)
    for _, node in ipairs(nodes) do
      node.is_leaf = (#node.children == 0)
      mark_leaves(node.children)
    end
  end
  mark_leaves(root.children)

  if #root.children == 0 then
    return nil, '[NoVim] No chapters found. Check the URL points to a supported page.'
  end

  return root.children, nil
end

function M.parse_chapter(html, url)
  local content_html = fetcher.extract_between(html, 'content_wrapper', 'toc')
  if not content_html then
    return nil, nil, nil, nil, '[NoVim] Could not find content on page.'
  end

  -- Remove chapter navigation anchor links (prev/next buttons) before stripping
  content_html = content_html:gsub('<a[^>]*href="[^"]-chapter%d+/%d+%.html"[^>]*>[^<]*</a>', '')

  local text = fetcher.strip_html(content_html)
  -- Remove inline "edit this page" links (site-specific artifact)
  text = text:gsub('\n?编辑本文\n?', '\n')
  text = text:match('^%s*(.-)%s*$') or ''

  local lines = fetcher.lines_from(text)

  -- Extract prev/next chapter links from article nav
  local host = fetcher.parse_host(url)
  local base_path = parse_base_path(url) -- unused, kept to preserve original behaviour exactly
  local prev_url, next_url
  local art_html = fetcher.extract_between(html, 'article', '/body')
  if art_html then
    local count = 0
    for href in art_html:gmatch('href="([^"]-chapter%d+/%d+%.html)"') do
      href = fetcher.make_absolute(href, host)
      count = count + 1
      if count == 1 then prev_url = href
      elseif count == 2 then next_url = href; break
      end
    end
  end

  return lines, prev_url, next_url, nil, nil
end

-- e.g. https://example.com/book/ch/chapter060/43.html → novim://chapter060/43
function M.bufname(url)
  local ch, sec = url:match('chapter(%d+)/(%d+)%.html$')
  if ch and sec then
    return 'novim://chapter' .. ch .. '/' .. sec
  end
  local path = url:match('/ch/(.-)%.html$') or url:match('/ch/(.+)$') or 'unknown'
  return 'novim://' .. path
end

function M.statusline(url, _title)
  local ch, sec = url:match('chapter(%d+)/(%d+)%.html$')
  if ch and sec then
    return string.format('Ch.%s / %s', ch, sec)
  end
  return ''
end

-- Human-readable label for the resume prompt (init.toggle). Matches what
-- init.toggle used to derive itself by stripping bufname()'s novim://
-- prefix — now an explicit adapter contract method instead.
function M.label(url)
  return (M.bufname(url):gsub('^novim://', ''))
end

return M
