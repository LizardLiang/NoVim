local M = {}

local function http_get(url)
  local ok, curl = pcall(require, 'plenary.curl')
  if ok then
    local res = curl.get(url, { timeout = 10000 })
    if res and res.status == 200 then
      return res.body, nil
    end
    local status = res and tostring(res.status) or '0'
    if res and res.status == 404 then
      return nil, '[NoVim] Page not found (404): ' .. url
    end
    return nil, '[NoVim] Failed to fetch page. Check connection. (status: ' .. status .. ')'
  end

  -- Fallback: system curl
  local cmd = string.format('curl -sL --max-time 10 "%s"', url)
  local body = vim.fn.system(cmd)
  if vim.v.shell_error ~= 0 then
    return nil, '[NoVim] Failed to fetch page. Check connection.'
  end
  return body, nil
end

local function strip_html(s)
  s = s:gsub('<[Ss][Cc][Rr][Ii][Pp][Tt][^>]*>.-</%s*[Ss][Cc][Rr][Ii][Pp][Tt]%s*>', '')
  s = s:gsub('<[Ss][Tt][Yy][Ll][Ee][^>]*>.-</%s*[Ss][Tt][Yy][Ll][Ee]%s*>', '')
  s = s:gsub('<[Bb][Rr][^>]*/?>', '\n')
  s = s:gsub('</?[Pp][^>]*>', '\n')
  s = s:gsub('</?[Hh]%d[^>]*>', '\n')
  s = s:gsub('</?[Dd][Ii][Vv][^>]*>', '\n')
  s = s:gsub('</?[Ll][Ii][^>]*>', '\n')
  s = s:gsub('</?[Tt][Rr][^>]*>', '\n')
  s = s:gsub('<[^>]+>', '')
  s = s:gsub('&amp;', '&')
  s = s:gsub('&lt;', '<')
  s = s:gsub('&gt;', '>')
  s = s:gsub('&quot;', '"')
  s = s:gsub('&#39;', "'")
  s = s:gsub('&nbsp;', ' ')
  s = s:gsub('&#(%d+);', function(n)
    local code = tonumber(n)
    if code and code < 128 then return string.char(code) end
    return ''
  end)
  s = s:gsub('\r\n', '\n'):gsub('\r', '\n')
  s = s:gsub('\n[ \t]*\n[ \t]*\n+', '\n\n')
  local lines = {}
  for line in (s .. '\n'):gmatch('([^\n]*)\n') do
    table.insert(lines, line:match('^%s*(.-)%s*$'))
  end
  while lines[1] == '' do table.remove(lines, 1) end
  while lines[#lines] == '' do table.remove(lines) end
  return table.concat(lines, '\n')
end

local function extract_between(html, start_id, end_id)
  local s = html:find('id="' .. start_id .. '"', 1, true)
         or html:find("id='" .. start_id .. "'", 1, true)
  if not s then return nil end
  local tag_close = html:find('>', s, true)
  if not tag_close then return nil end
  local content = html:sub(tag_close + 1)
  if end_id then
    local e = content:find('id="' .. end_id .. '"', 1, true)
           or content:find("id='" .. end_id .. "'", 1, true)
    if e then content = content:sub(1, e - 1) end
  end
  return content
end

-- Extract scheme + host from a URL (e.g. "https://example.com")
local function parse_host(url)
  return url:match('^(https?://[^/]+)') or ''
end

-- Extract the base path shared by chapter URLs
-- e.g. https://example.com/book/ch/chapter060/43.html → /book/ch/
local function parse_base_path(url)
  local path = url:match('^https?://[^/]+(/.*)')  or '/'
  -- Walk up to the parent of any chapter\d+ segment
  local base = path:match('^(.*/)chapter%d+/')
  return base or path:match('^(.*/)') or '/'
end

-- Make a relative href absolute using the source URL's host
local function make_absolute(href, host)
  if href:match('^https?://') then return href end
  if href:sub(1, 1) == '/' then return host .. href end
  return href
end

function M.fetch_chapter(url)
  local html, err = http_get(url)
  if not html then return nil, nil, nil, err end

  local content_html = extract_between(html, 'content_wrapper', 'toc')
  if not content_html then
    return nil, nil, nil, '[NoVim] Could not find content on page.'
  end

  local text = strip_html(content_html)
  -- Remove inline "edit this page" links (site-specific artifact)
  text = text:gsub('\n?编辑本文\n?', '\n')
  text = text:match('^%s*(.-)%s*$') or ''

  local lines = {}
  for line in (text .. '\n'):gmatch('([^\n]*)\n') do
    table.insert(lines, line)
  end

  -- Extract prev/next chapter links from article nav
  local host = parse_host(url)
  local base_path = parse_base_path(url)
  local prev_url, next_url
  local art_html = extract_between(html, 'article', '/body')
  if art_html then
    local count = 0
    for href in art_html:gmatch('href="([^"]-chapter%d+/%d+%.html)"') do
      href = make_absolute(href, host)
      count = count + 1
      if count == 1 then prev_url = href
      elseif count == 2 then next_url = href; break
      end
    end
  end

  return lines, prev_url, next_url, nil
end

function M.fetch_toc(source_url)
  local html, err = http_get(source_url)
  if not html then return nil, err end

  local sidebar_html = extract_between(html, 'sidebar', 'article')
  if not sidebar_html then
    return nil, '[NoVim] Could not find chapter list on provided page.'
  end

  local host = parse_host(source_url)
  local base_path = parse_base_path(source_url)
  local groups = {}
  local group_map = {}

  for href, title in sidebar_html:gmatch('href="(/[^"]+)"[^>]*>([^<\n]+)') do
    -- Only process hrefs under the same base path
    if href:sub(1, #base_path) ~= base_path then
      -- skip links outside the reading section
    else
      local full_url = host .. href
      title = title:match('^%s*(.-)%s*$')
      if title ~= '' then
        if href:match('/chapter%d+/index%.html$') then
          local ch_id = href:match('chapter(%d+)')
          local g = { title = title, url = full_url, children = {}, expanded = false }
          table.insert(groups, g)
          group_map[ch_id] = #groups
        elseif href:match('/chapter%d+/%d+%.html$') then
          local ch_id = href:match('chapter(%d+)')
          local gi = ch_id and group_map[ch_id]
          if gi then
            table.insert(groups[gi].children, { title = title, url = full_url })
          end
        elseif href:match('/index%.html$') or href:match('/character%.html$') then
          table.insert(groups, {
            title = title,
            url = full_url,
            children = {},
            expanded = false,
            is_leaf = true,
          })
        end
      end
    end
  end

  return groups, nil
end

return M
