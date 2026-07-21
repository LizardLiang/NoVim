-- Shared HTTP + HTML plumbing used by site adapters (lua/novim/sites/*).
-- Site-specific parsing lives in the adapters; this module only fetches
-- pages and exposes helpers the adapters need.
local M = {}

local config = require('novim.config')

local DEFAULT_HEADERS = {
  ['User-Agent'] = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    .. '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36',
  ['Accept-Language'] = 'zh-TW,zh;q=0.9,en;q=0.8',
}

-- Extract the bare hostname from a URL (e.g. "example.com"), no scheme.
-- Centralised here so adapters don't each re-implement it (was previously
-- duplicated in sites/czbooks.lua and sites/legacy.lua).
function M.bare_host(url)
  return url:match('^https?://([^/]+)') or url
end

-- Merge any number of header tables by case-insensitive name, later
-- tables taking priority. The winning entry's own key casing is kept on
-- the wire, so `['user-agent'] = ...` fully replaces
-- DEFAULT_HEADERS['User-Agent'] instead of riding alongside it as a
-- second, conflicting header. Values that aren't string/number are
-- dropped with a warning rather than left to crash the curl-fallback
-- path's string concatenation later.
local function merge_headers_ci(...)
  local merged = {} -- lower(name) -> { name = original-case name, value = value }
  for _, tbl in ipairs({ ... }) do
    for name, value in pairs(tbl or {}) do
      if type(value) == 'string' or type(value) == 'number' then
        merged[name:lower()] = { name = name, value = value }
      else
        vim.notify(
          string.format('[NoVim] Ignoring http_headers[%s]: value must be a string or number.', tostring(name)),
          vim.log.levels.WARN
        )
      end
    end
  end
  local result = {}
  for _, entry in pairs(merged) do
    result[entry.name] = entry.value
  end
  return result
end

-- config.options.http_headers may be either:
--   * a flat header table applied to every request (legacy/default form), or
--   * a host-keyed table `{ ['some.host'] = { headers... } }` that scopes
--     headers to just that host, so a Cookie/Authorization header aimed at
--     one site doesn't ride along to every other host (or redirect target
--     on the *initial* request's host is looked up; curl/plenary still
--     forward manually-supplied headers across redirects to a different
--     host, which host-scoping here cannot prevent).
-- Detected by shape: if every value is itself a table, treat it as
-- host-keyed; an empty table is treated as flat (nothing to scope).
local function is_host_keyed(headers)
  if not headers or next(headers) == nil then return false end
  for _, value in pairs(headers) do
    if type(value) ~= 'table' then return false end
  end
  return true
end

local function headers_for_host(url)
  local configured = config.options.http_headers or {}
  if not is_host_keyed(configured) then
    return configured
  end
  local bare = M.bare_host(url)
  return configured[bare] or {}
end

-- Merge default headers, the (possibly host-scoped) user
-- config.options.http_headers, and any per-call extra headers (highest
-- priority last).
local function merged_headers(url, extra_headers)
  return merge_headers_ci(DEFAULT_HEADERS, headers_for_host(url), extra_headers or {})
end

-- Exposed for tests (and debugging): the exact header table `http_get`
-- would send for `url` given the current config.options.http_headers,
-- without performing a request.
M.resolve_headers = merged_headers

function M.http_get(url, extra_headers)
  local headers = merged_headers(url, extra_headers)

  local ok, curl = pcall(require, 'plenary.curl')
  if ok then
    local res = curl.get(url, {
      timeout = 10000,
      follow = true,        -- follow redirects (e.g. /ch → /ch/index.html)
      raw = { '-L' },       -- belt-and-suspenders for older plenary versions
      headers = headers,
    })
    if res and res.status == 200 then
      return res.body, nil
    end
    local status = res and tostring(res.status) or '0'
    if res and res.status == 404 then
      return nil, '[NoVim] Page not found (404): ' .. url
    end
    return nil, '[NoVim] Failed to fetch page. Check connection. (status: ' .. status .. ')'
  end

  -- Fallback: system curl. Build the argument list (rather than
  -- string-formatting one shell command) so headers/quoting survive on
  -- Windows, where vim.fn.system(table) execs without a shell.
  local args = { 'curl', '-sL', '--max-time', '10' }
  for name, value in pairs(headers) do
    table.insert(args, '-H')
    table.insert(args, name .. ': ' .. value)
  end
  table.insert(args, url)

  local body = vim.fn.system(args)
  if vim.v.shell_error ~= 0 then
    return nil, '[NoVim] Failed to fetch page. Check connection.'
  end
  return body, nil
end

-- Split `text` on '\n' into a lines table. Shared so adapters that need to
-- post-process stripped text (e.g. legacy's edit-link removal) before
-- re-splitting don't each hand-roll the same gmatch loop.
function M.lines_from(text)
  local lines = {}
  for line in (text .. '\n'):gmatch('([^\n]*)\n') do
    table.insert(lines, line)
  end
  return lines
end

-- Strip tags/entities from `s` and return the result as a lines table
-- directly, skipping the join-then-resplit both site adapters used to do
-- on strip_html's string return value.
function M.strip_html_lines(s)
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
  -- Remove incomplete tags at end of string (extract_between can cut mid-tag)
  s = s:gsub('<[%a][^>]*$', '')
  s = s:gsub('\r\n', '\n'):gsub('\r', '\n')
  s = s:gsub('(\n[ \t]*)+\n', '\n\n')
  local lines = M.lines_from(s)
  for i, line in ipairs(lines) do
    lines[i] = line:match('^%s*(.-)%s*$')
  end
  while lines[1] == '' do table.remove(lines, 1) end
  while lines[#lines] == '' do table.remove(lines) end
  return lines
end

function M.strip_html(s)
  return table.concat(M.strip_html_lines(s), '\n')
end

function M.extract_between(html, start_id, end_id)
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
function M.parse_host(url)
  return url:match('^(https?://[^/]+)') or ''
end

-- Make a relative or protocol-relative href absolute using the source
-- URL's scheme + host (e.g. "https://example.com").
function M.make_absolute(href, host)
  if href:match('^https?://') then return href end
  if href:match('^//') then
    local scheme = host:match('^(https?):') or 'https'
    return scheme .. ':' .. href
  end
  if href:sub(1, 1) == '/' then return host .. href end
  return href
end

-- Resolve the URL to a site adapter, fetch its chapter page and delegate
-- parsing to the adapter.
function M.fetch_chapter(url)
  local sites = require('novim.sites')
  local adapter = sites.resolve(url)

  local html, err = M.http_get(url)
  if not html then return nil, nil, nil, nil, err end

  return adapter.parse_chapter(html, url)
end

-- Resolve the URL to a site adapter, fetch its TOC/index page and delegate
-- parsing to the adapter.
function M.fetch_toc(source_url)
  local sites = require('novim.sites')
  local adapter = sites.resolve(source_url)
  local index_url = adapter.normalise_url(source_url)

  local html, err = M.http_get(index_url)
  if not html then return nil, err end

  return adapter.parse_toc(html, index_url)
end

return M
