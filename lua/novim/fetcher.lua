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

-- Percent-encode bytes outside the URL-safe unreserved set
-- ([A-Za-z0-9-_.~]) so CJK and reserved characters survive being placed
-- into a query string or POST form field.
function M.url_encode(s)
  return (s:gsub('[^%w%-_.~]', function(c)
    return string.format('%%%02X', c:byte())
  end))
end

-- Encode a flat table of form fields into an "a=1&b=2" application/
-- x-www-form-urlencoded body, both keys and values percent-encoded.
local function encode_form(form)
  local parts = {}
  for k, v in pairs(form or {}) do
    table.insert(parts, M.url_encode(tostring(k)) .. '=' .. M.url_encode(tostring(v)))
  end
  return table.concat(parts, '&')
end

-- POST `form` (a flat key/value table) to `url`. Mirrors http_get's
-- structure exactly: plenary path first, system-curl argv fallback
-- second, same merged_headers() call so default UA/Accept-Language and
-- host-scoped http_headers apply identically to POST as to GET.
function M.http_post(url, form, extra_headers)
  local headers = merged_headers(url, extra_headers)
  local body = encode_form(form)

  local ok, curl = pcall(require, 'plenary.curl')
  if ok then
    local res = curl.post(url, {
      body = body,
      timeout = 10000,
      follow = true,
      raw = { '-L' },
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

  -- Fallback: system curl. Build the argument list (rather than a
  -- formatted shell string) so headers/quoting survive on Windows, where
  -- vim.fn.system(table) execs without a shell.
  local args = { 'curl', '-sL', '--max-time', '10' }
  for name, value in pairs(headers) do
    table.insert(args, '-H')
    table.insert(args, name .. ': ' .. value)
  end
  table.insert(args, '--data')
  table.insert(args, body)
  table.insert(args, url)

  local resp_body = vim.fn.system(args)
  if vim.v.shell_error ~= 0 then
    return nil, '[NoVim] Failed to fetch page. Check connection.'
  end
  return resp_body, nil
end

-- Async GET. `callback(body, err)` is always invoked via vim.schedule, so
-- callers never have to worry about running off the main loop regardless
-- of which backend serviced the request.
--
-- plenary path: curl.get's own callback already fires off libuv's loop
-- (not necessarily the main loop), so it is wrapped in vim.schedule too.
-- Fallback path: vim.system when available (nvim >= 0.10); otherwise
-- vim.fn.jobstart, since the README claims nvim >= 0.8 and vim.system
-- alone is not available there.
function M.http_get_async(url, extra_headers, callback)
  local headers = merged_headers(url, extra_headers)

  local ok, curl = pcall(require, 'plenary.curl')
  if ok then
    curl.get(url, {
      timeout = 10000,
      follow = true,
      raw = { '-L' },
      headers = headers,
      callback = function(res)
        vim.schedule(function()
          if res and res.status == 200 then
            callback(res.body, nil)
            return
          end
          local status = res and tostring(res.status) or '0'
          if res and res.status == 404 then
            callback(nil, '[NoVim] Page not found (404): ' .. url)
            return
          end
          callback(nil, '[NoVim] Failed to fetch page. Check connection. (status: ' .. status .. ')')
        end)
      end,
      on_error = function(err)
        vim.schedule(function()
          callback(nil, '[NoVim] Failed to fetch page. ' .. tostring(err and err.message or 'Check connection.'))
        end)
      end,
    })
    return
  end

  -- Fallback: system curl, argv-table form (never a shell string).
  local args = { 'curl', '-sL', '--max-time', '10' }
  for name, value in pairs(headers) do
    table.insert(args, '-H')
    table.insert(args, name .. ': ' .. value)
  end
  table.insert(args, url)

  if vim.system then
    vim.system(args, { text = true }, function(res)
      vim.schedule(function()
        if res.code ~= 0 then
          callback(nil, '[NoVim] Failed to fetch page. Check connection.')
          return
        end
        callback(res.stdout, nil)
      end)
    end)
    return
  end

  -- nvim < 0.10: no vim.system. jobstart with buffered stdout.
  local out = {}
  vim.fn.jobstart(args, {
    stdout_buffered = true,
    on_stdout = function(_, data)
      if data then
        for _, line in ipairs(data) do
          table.insert(out, line)
        end
      end
    end,
    on_exit = function(_, code)
      vim.schedule(function()
        if code ~= 0 then
          callback(nil, '[NoVim] Failed to fetch page. Check connection.')
          return
        end
        callback(table.concat(out, '\n'), nil)
      end)
    end,
  })
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

-- Build a Lua-pattern fragment matching `tag` case-insensitively, e.g.
-- "div" -> "[Dd][Ii][Vv]". `tag` must be plain ASCII letters (no pattern
-- magic characters) — true for every tag name find_tag_close is called
-- with (div, article, ...).
local function case_insensitive_tag_pattern(tag)
  local out = {}
  for i = 1, #tag do
    local c = tag:sub(i, i)
    table.insert(out, '[' .. c:upper() .. c:lower() .. ']')
  end
  return table.concat(out)
end

-- Depth-aware walk that finds the byte offset of the '<' that begins the
-- closing </tag> matching the tag whose opening tag ends at `start_pos`
-- (i.e. `start_pos` is the byte right after that opening tag's '>').
-- Nested <tag>...</tag> pairs are tracked so a tag nested inside the one
-- we're bounding doesn't terminate the scan early. Returns nil if no
-- matching close is found (malformed/truncated HTML) — callers should
-- fall back to a secondary terminator in that case rather than treating
-- the rest of the document as in-scope.
--
-- Generalised from a div-only helper that used to live in
-- sites/czbooks.lua, so article-scoped adapters (e.g. ixdzs) can reuse it
-- without duplicating the depth-tracking logic.
function M.find_tag_close(html, tag, start_pos)
  local tag_pat = case_insensitive_tag_pattern(tag)
  local depth = 1
  local pos = start_pos
  local len = #html
  while pos <= len do
    local open_s, open_e = html:find('<%s*' .. tag_pat .. '[%s>]', pos)
    local close_s, close_e = html:find('<%s*/%s*' .. tag_pat .. '%s*>', pos)
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

  local html, err = adapter.fetch_toc_html(index_url)
  if not html then return nil, err end

  return adapter.parse_toc(html, index_url)
end

return M
