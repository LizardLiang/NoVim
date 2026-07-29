-- Offline regression tests for NoVim's site adapters.
-- Run with: nvim --headless -l tests/run.lua
-- Exits 0 when every assertion passes, 1 otherwise. No network access.

local script_dir = debug.getinfo(1, 'S').source:match('^@(.*[/\\])') or './'
local root = script_dir .. '../'
package.path = root .. 'lua/?.lua;' .. root .. 'lua/?/init.lua;' .. package.path

local failures = 0
local checks = 0

local function read_fixture(name)
  local path = script_dir .. 'fixtures/' .. name
  local f = assert(io.open(path, 'r'), 'missing fixture: ' .. path)
  local content = f:read('*a')
  f:close()
  return content
end

local function fail(msg)
  failures = failures + 1
  print('FAIL: ' .. msg)
end

local function truthy(val, msg)
  checks = checks + 1
  if not val then fail(msg) end
end

local function eq(actual, expected, msg)
  checks = checks + 1
  if actual ~= expected then
    fail(string.format('%s (expected %s, got %s)', msg, tostring(expected), tostring(actual)))
  end
end

local function is_nil(val, msg)
  checks = checks + 1
  if val ~= nil then
    fail(string.format('%s (expected nil, got %s)', msg, tostring(val)))
  end
end

local function not_contains(haystack, needle, msg)
  checks = checks + 1
  if haystack:find(needle, 1, true) then
    fail(msg .. ' (found "' .. needle .. '")')
  end
end

----------------------------------------------------------------------
-- czbooks adapter
----------------------------------------------------------------------
local czbooks = require('novim.sites.czbooks')

do
  truthy(czbooks.match('https://czbooks.net/n/ui5on5'), 'czbooks adapter matches czbooks.net host')
  truthy(not czbooks.match('https://example.com/book/ch/'), 'czbooks adapter does not match other hosts')

  eq(czbooks.normalise_url('https://czbooks.net/n/ui5on5/ui85on'), 'https://czbooks.net/n/ui5on5',
    'czbooks normalise_url derives index URL from a chapter URL')
  eq(czbooks.normalise_url('https://czbooks.net/n/ui5on5'), 'https://czbooks.net/n/ui5on5',
    'czbooks normalise_url is a no-op on an index URL')

  eq(czbooks.entry_chapter('https://czbooks.net/n/ui5on5/ui85on'), 'ui85on',
    'czbooks entry_chapter reads the chapter id from a chapter URL')
  is_nil(czbooks.entry_chapter('https://czbooks.net/n/ui5on5'), 'czbooks entry_chapter is nil for an index URL')
end

do
  local toc_html = read_fixture('czbooks_toc.html')
  local nodes, err = czbooks.parse_toc(toc_html, 'https://czbooks.net/n/ui5on5')
  truthy(nodes and not err, 'czbooks TOC parses without error')
  if nodes then
    eq(#nodes, 2, 'czbooks TOC produces 2 top-level volume groups')
    eq(nodes[1].title, 'Volume One', 'czbooks TOC first group is Volume One')
    eq(nodes[2].title, 'Volume Two', 'czbooks TOC second group is Volume Two')
    eq(#nodes[1].children, 10, 'czbooks TOC Volume One has 10 chapters')
    eq(#nodes[2].children, 10, 'czbooks TOC Volume Two has 10 chapters')
    truthy(nodes[1].is_leaf == false, 'czbooks TOC group node is not a leaf')
    truthy(nodes[1].children[1].is_leaf == true, 'czbooks TOC chapter node is a leaf')

    local first_leaf = nodes[1].children[1]
    local last_leaf = nodes[2].children[#nodes[2].children]
    truthy(first_leaf.url and first_leaf.url:match('^https://'), 'czbooks TOC first leaf URL is absolute https')
    eq(first_leaf.url, 'https://czbooks.net/n/ui5on5/ch0001', 'czbooks TOC first leaf URL resolved from protocol-relative href')
    truthy(last_leaf.url and last_leaf.url:match('^https://'), 'czbooks TOC last leaf URL is absolute https')
    eq(last_leaf.url, 'https://czbooks.net/n/ui5on5/ch0020', 'czbooks TOC last leaf URL resolved from protocol-relative href')
  end
end

do
  local ch1_html = read_fixture('czbooks_chapter1.html')
  local lines, prev_url, next_url, title, err = czbooks.parse_chapter(ch1_html, 'https://czbooks.net/n/ui5on5/ch0001')
  truthy(lines and not err, 'czbooks chapter1 parses without error')
  if lines then
    local body = table.concat(lines, '\n')
    truthy(lines[1] and lines[1]:match('^PLACEHOLDER_PARA_ONE'), 'czbooks chapter1 body starts at first content line')
    truthy(lines[#lines] and lines[#lines]:match('PLACEHOLDER_PARA_THREE'), 'czbooks chapter1 body ends at last content line')
    not_contains(body, 'NOTICE_MARKER_TEXT', 'czbooks chapter1 body excludes div.notice text')
    not_contains(body, 'NAV_MARKER_TEXT', 'czbooks chapter1 body excludes chapter-nav text')
    not_contains(body, 'ADS_MARKER_TEXT', 'czbooks chapter1 body excludes ads text')
  end
  eq(title, 'Placeholder Chapter Title 1', 'czbooks chapter1 title read from div.name')
  is_nil(prev_url, 'czbooks chapter1 has no previous chapter')
  truthy(next_url ~= nil, 'czbooks chapter1 has a next chapter')
  eq(next_url, 'https://czbooks.net/n/ui5on5/ch0002', 'czbooks chapter1 next URL resolved from protocol-relative href')
end

do
  local key = czbooks.novel_key('https://czbooks.net/n/ui5on5/ui85on')
  eq(key, 'czbooks.net/ui5on5', 'czbooks novel_key is host + novel id')
  eq(czbooks.bufname('https://czbooks.net/n/ui5on5/ui85on'), 'novim://ui5on5/ui85on', 'czbooks bufname is novim://<novelId>/<chapterId>')
  eq(czbooks.statusline('https://czbooks.net/n/ui5on5/ui85on', 'A Title'), 'A Title', 'czbooks statusline returns the adapter-supplied title')
  eq(czbooks.label('https://czbooks.net/n/ui5on5/ui85on'), 'ui5on5/ui85on', 'czbooks label strips the novim:// prefix off bufname')
end

-- Regression for Hermes finding 1: when div.notice is absent, the parser
-- must not fall through to reading the rest of the document (ads, nav,
-- everything past div.content) as chapter body.
do
  local html = read_fixture('czbooks_chapter_no_notice.html')
  local lines, prev_url, next_url, title, err =
    czbooks.parse_chapter(html, 'https://czbooks.net/n/ui5on5/ch0001')
  truthy(lines and not err, 'czbooks chapter (no notice) parses without error')
  if lines then
    local body = table.concat(lines, '\n')
    truthy(lines[1] and lines[1]:match('^PLACEHOLDER_PARA_ONE'),
      'czbooks chapter (no notice) body starts at first content line')
    truthy(lines[#lines] and lines[#lines]:match('PLACEHOLDER_PARA_THREE'),
      'czbooks chapter (no notice) body ends at last content line, not the rest of the document')
    not_contains(body, 'ADS_MARKER_TEXT', 'czbooks chapter (no notice) body excludes ads that follow div.content')
    not_contains(body, 'NAV_MARKER_TEXT', 'czbooks chapter (no notice) body excludes chapter-nav that follows div.content')
  end
  eq(title, 'Placeholder Chapter Title No Notice', 'czbooks chapter (no notice) title still read from div.name')
  truthy(next_url ~= nil, 'czbooks chapter (no notice) still finds next chapter link outside div.content')
end

-- Regression for Hermes finding 2: a decoy element sharing class="name" /
-- class="content" earlier in the document (e.g. a related-novels widget)
-- must not win the first-match-wins scan over the real title/content
-- inside the chapter's own container.
do
  local html = read_fixture('czbooks_chapter_decoy.html')
  local lines, prev_url, next_url, title, err =
    czbooks.parse_chapter(html, 'https://czbooks.net/n/ui5on5/ch0001')
  truthy(lines and not err, 'czbooks chapter (decoy) parses without error')
  eq(title, 'Placeholder Chapter Title Decoy Test', 'czbooks chapter (decoy) title ignores the earlier decoy div.name')
  if lines then
    local body = table.concat(lines, '\n')
    truthy(lines[1] and lines[1]:match('^PLACEHOLDER_PARA_ONE'), 'czbooks chapter (decoy) body starts at the real content')
    not_contains(body, 'DECOY_NAME_SHOULD_BE_IGNORED', 'czbooks chapter (decoy) body excludes the decoy name div text')
    not_contains(body, 'DECOY_CONTENT_SHOULD_BE_IGNORED', 'czbooks chapter (decoy) body excludes the decoy content div text')
    not_contains(body, 'NOTICE_MARKER_TEXT', 'czbooks chapter (decoy) body excludes div.notice text')
  end
end

----------------------------------------------------------------------
-- legacy adapter (regression — must match the pre-refactor parser
-- exactly; expected values captured by running the unmodified
-- fetcher.lua against these same fixtures before the sites/ move)
----------------------------------------------------------------------
local legacy = require('novim.sites.legacy')

do
  truthy(legacy.match('https://anything.example/whatever'), 'legacy adapter matches any host (fallback)')
  is_nil(legacy.entry_chapter('https://example.com/book/ch/chapter002/1.html'), 'legacy entry_chapter is always nil')
end

do
  local toc_html = read_fixture('legacy_toc.html')
  local nodes, err = legacy.parse_toc(toc_html, 'https://example.com/book/ch/index.html')
  truthy(nodes and not err, 'legacy TOC parses without error')
  if nodes then
    eq(#nodes, 2, 'legacy TOC has 2 top-level nodes')

    local ch1 = nodes[1]
    eq(ch1.title, 'Chapter 1', 'legacy TOC node 1 title (span.label)')
    eq(ch1.url, 'https://example.com/book/ch/chapter001/1.html', 'legacy TOC node 1 URL')
    eq(ch1.is_leaf, true, 'legacy TOC node 1 is a leaf')

    local vol1 = nodes[2]
    eq(vol1.title, 'Volume One', 'legacy TOC node 2 title (span.label, href="#")')
    is_nil(vol1.url, 'legacy TOC node 2 URL is nil (href="#")')
    eq(vol1.is_leaf, false, 'legacy TOC node 2 is not a leaf')
    eq(#vol1.children, 2, 'legacy TOC Volume One has 2 direct children')

    local ch2 = vol1.children[1]
    eq(ch2.title, 'Chapter 2', 'legacy TOC nested node title (span.label)')
    eq(ch2.url, 'https://example.com/book/ch/chapter002/1.html', 'legacy TOC nested node URL')
    eq(ch2.is_leaf, true, 'legacy TOC nested leaf node')

    local ch3 = vol1.children[2]
    eq(ch3.title, 'Chapter 3 Fallback Title', 'legacy TOC node title falls back to anchor text')
    eq(ch3.is_leaf, false, 'legacy TOC 3rd-level parent is not a leaf')
    eq(#ch3.children, 1, 'legacy TOC 3rd-level parent has 1 child')

    local ch4 = ch3.children[1]
    eq(ch4.title, 'Chapter 4 Deep', 'legacy TOC 4th-level (3+ deep) node title')
    eq(ch4.url, 'https://example.com/book/ch/chapter004/1.html', 'legacy TOC 4th-level node URL')
    eq(ch4.is_leaf, true, 'legacy TOC 4th-level node is a leaf')
  end
end

do
  local chapter_html = read_fixture('legacy_chapter.html')
  local lines, prev_url, next_url, title, err = legacy.parse_chapter(chapter_html, 'https://example.com/book/ch/chapter002/1.html')
  truthy(lines and not err, 'legacy chapter parses without error')
  is_nil(title, 'legacy parse_chapter returns no title (URL-derived statusline instead)')
  if lines then
    -- Captured from the unmodified pre-refactor fetcher.lua against this fixture.
    local expected = {
      'PLACEHOLDER_PARA_ONE some short filler text.',
      '',
      '',
      'PLACEHOLDER_PARA_TWO another short filler line.',
    }
    eq(#lines, #expected, 'legacy chapter line count matches pre-refactor capture')
    for i = 1, math.max(#lines, #expected) do
      eq(lines[i], expected[i], 'legacy chapter line ' .. i .. ' matches pre-refactor capture')
    end
  end
  eq(prev_url, 'https://example.com/book/ch/chapter001/1.html', 'legacy chapter prev_url matches pre-refactor capture')
  eq(next_url, 'https://example.com/book/ch/chapter003/1.html', 'legacy chapter next_url matches pre-refactor capture')
end

do
  eq(legacy.bufname('https://example.com/book/ch/chapter060/43.html'), 'novim://chapter060/43',
    'legacy bufname matches pre-refactor url_to_bufname')
  eq(legacy.statusline('https://example.com/book/ch/chapter060/43.html', nil), 'Ch.060 / 43',
    'legacy statusline matches pre-refactor init.statusline')
  eq(legacy.statusline('https://example.com/other/page.html', nil), '',
    'legacy statusline is empty for non-chapter URLs')
end

-- New coverage (finding 11): label(url) is now a required contract method,
-- not init.lua reaching into bufname()'s novim:// prefix convention itself.
do
  eq(legacy.label('https://example.com/book/ch/chapter060/43.html'), 'chapter060/43',
    'legacy label strips the novim:// prefix off bufname')
end

----------------------------------------------------------------------
-- adapter registry
----------------------------------------------------------------------
local sites = require('novim.sites')

do
  local adapter = sites.resolve('https://czbooks.net/n/ui5on5/ui85on')
  truthy(adapter == czbooks, 'sites.resolve returns the czbooks adapter for a czbooks URL')

  local fallback = sites.resolve('https://example.com/book/ch/index.html')
  truthy(fallback == legacy, 'sites.resolve falls back to the legacy adapter for unclaimed hosts')
end

----------------------------------------------------------------------
-- progress.lua (finding 3): a non-table `data.novels` (e.g. a corrupted
-- or hand-edited file like {"novels": 5}) must degrade exactly like the
-- existing corrupt-JSON path, not throw out through M.load/M.save.
----------------------------------------------------------------------
local progress = require('novim.progress')
local config = require('novim.config')

local function write_file(path, content)
  local f = assert(io.open(path, 'w'))
  f:write(content)
  f:close()
end

local function with_progress_file(content, fn)
  local path = vim.fn.tempname() .. '_novim_progress_test.json'
  write_file(path, content)
  local prev = config.options.save_path
  config.options.save_path = path
  local ok, err = pcall(fn)
  config.options.save_path = prev
  os.remove(path)
  if not ok then error(err, 0) end
end

do
  with_progress_file('{"novels": 5}', function()
    local ok, result = pcall(progress.load)
    truthy(ok, 'progress.load does not throw when novels is a number')
    is_nil(result, 'progress.load returns nil when novels is a number (treated as malformed)')
  end)
end

do
  with_progress_file('{"novels": "not a table"}', function()
    local ok, result = pcall(progress.load, 'czbooks.net/ui5on5')
    truthy(ok, 'progress.load(key) does not throw when novels is a string')
    is_nil(result, 'progress.load(key) returns nil when novels is a string (treated as malformed)')
  end)
end

do
  with_progress_file('{"novels": true}', function()
    local ok = pcall(progress.save, 'https://czbooks.net/n/ui5on5/ch0001', 5)
    truthy(ok, 'progress.save does not throw when the existing file has novels = true')
    local saved = progress.load('czbooks.net/ui5on5')
    truthy(saved ~= nil, 'progress.save recovers into a fresh novels table after a malformed one')
    if saved then
      eq(saved.line, 5, 'progress.save recovered entry has the saved line')
    end
  end)
end

----------------------------------------------------------------------
-- fetcher.lua header merge (findings 5, 6, 7)
----------------------------------------------------------------------
local fetcher = require('novim.fetcher')

local function with_http_headers(value, fn)
  local prev = config.options.http_headers
  config.options.http_headers = value
  local ok, err = pcall(fn)
  config.options.http_headers = prev
  if not ok then error(err, 0) end
end

do
  with_http_headers({ ['user-agent'] = 'CustomUA/1.0' }, function()
    local headers = fetcher.resolve_headers('https://czbooks.net/n/ui5on5')
    local ua_keys = 0
    for name in pairs(headers) do
      if name:lower() == 'user-agent' then ua_keys = ua_keys + 1 end
    end
    eq(ua_keys, 1, 'case-insensitive header override leaves exactly one user-agent header, not two conflicting ones')
    eq(headers['user-agent'], 'CustomUA/1.0', 'case-insensitive override keeps the user-supplied casing and value')
  end)
end

do
  with_http_headers({ ['User-Agent'] = 12345 }, function()
    local ok, headers = pcall(fetcher.resolve_headers, 'https://czbooks.net/n/ui5on5')
    truthy(ok, 'resolve_headers does not throw for a numeric header value')
    eq(headers['User-Agent'], 12345, 'numeric header values are accepted')
  end)
end

do
  with_http_headers({ ['X-Bad'] = { 'not', 'a', 'string' } }, function()
    local ok, headers = pcall(fetcher.resolve_headers, 'https://czbooks.net/n/ui5on5')
    truthy(ok, 'resolve_headers does not throw for a non-string/number header value')
    if ok then
      is_nil(headers['X-Bad'], 'non-string/number header values are dropped rather than crashing the curl arg build')
    end
  end)
end

do
  with_http_headers({ ['czbooks.net'] = { ['X-Only-For-Czbooks'] = 'yes' } }, function()
    local czbooks_headers = fetcher.resolve_headers('https://czbooks.net/n/ui5on5')
    eq(czbooks_headers['X-Only-For-Czbooks'], 'yes', 'host-keyed http_headers apply to the matching host')

    local other_headers = fetcher.resolve_headers('https://example.com/book/ch/index.html')
    is_nil(other_headers['X-Only-For-Czbooks'], 'host-keyed http_headers do not leak to a different host')
  end)
end

----------------------------------------------------------------------
-- config.lua NOVIM_DATA_DIR: env-relocatable data dir (progress + settings)
----------------------------------------------------------------------
local settings = require('novim.settings')

local function with_env_data_dir(value, fn)
  local prev = vim.env.NOVIM_DATA_DIR
  vim.env.NOVIM_DATA_DIR = value
  local ok, err = pcall(fn)
  vim.env.NOVIM_DATA_DIR = prev
  config.setup({}) -- restore options resolved without the test env var
  if not ok then error(err, 0) end
end

do
  local dir = vim.fn.tempname() .. '_novim_data_dir'
  with_env_data_dir(dir, function()
    config.setup({})
    eq(config.options.save_path, dir .. '/novim_progress.json',
      'NOVIM_DATA_DIR relocates the progress file into the env directory')
    eq(config.options.data_dir, dir, 'NOVIM_DATA_DIR is exposed as options.data_dir')
    truthy(vim.fn.isdirectory(dir) == 1, 'NOVIM_DATA_DIR directory is created when missing')

    settings.set_source_url('https://czbooks.net/n/ui5on5')
    local f = io.open(dir .. '/novim_settings.json', 'r')
    truthy(f ~= nil, 'settings file is written inside NOVIM_DATA_DIR')
    if f then f:close() end
    eq(settings.get_source_url(), 'https://czbooks.net/n/ui5on5',
      'source_url round-trips through the relocated settings file')
    config.options.source_url = nil
  end)
  vim.fn.delete(dir, 'rf')
end

do
  local dir = vim.fn.tempname() .. '_novim_data_dir_prec'
  with_env_data_dir(dir, function()
    config.setup({ save_path = '/explicit/opt/path.json' })
    eq(config.options.save_path, dir .. '/novim_progress.json',
      'NOVIM_DATA_DIR wins over an explicit setup({save_path}) opt')
  end)
  vim.fn.delete(dir, 'rf')
end

do
  with_env_data_dir(nil, function()
    config.setup({})
    eq(config.options.save_path, vim.fn.stdpath('data') .. '/novim_progress.json',
      'without NOVIM_DATA_DIR the default stdpath progress location is unchanged')
    config.setup({ save_path = '/explicit/opt/path.json' })
    eq(config.options.save_path, '/explicit/opt/path.json',
      'without NOVIM_DATA_DIR an explicit setup({save_path}) still wins')
  end)
end

do
  -- A file occupying the target path makes the dir uncreatable.
  local blocker = vim.fn.tempname() .. '_novim_blocker'
  write_file(blocker, 'x')
  with_env_data_dir(blocker, function()
    local ok = pcall(config.setup, {})
    truthy(ok, 'setup does not throw when NOVIM_DATA_DIR is uncreatable')
    eq(config.options.save_path, vim.fn.stdpath('data') .. '/novim_progress.json',
      'uncreatable NOVIM_DATA_DIR falls back to the default progress location')
  end)
  os.remove(blocker)
end

----------------------------------------------------------------------
-- ixdzs adapter
----------------------------------------------------------------------
local ixdzs = require('novim.sites.ixdzs')

do
  truthy(ixdzs.match('https://ixdzs.tw/read/552802/p1.html'), 'ixdzs adapter matches ixdzs.tw host')
  truthy(ixdzs.match('https://ixdzs.com/read/552802/p1.html'), 'ixdzs adapter matches an ixdzs.com mirror host')
  truthy(not ixdzs.match('https://czbooks.net/n/ui5on5'), 'ixdzs adapter does not match a different host')

  eq(ixdzs.normalise_url('https://ixdzs.tw/read/552802/p1.html'), 'https://ixdzs.tw/read/552802/',
    'ixdzs normalise_url derives the index URL from a chapter URL')
  eq(ixdzs.normalise_url('https://ixdzs.tw/read/552802/'), 'https://ixdzs.tw/read/552802/',
    'ixdzs normalise_url is a no-op on an index URL')
  eq(ixdzs.normalise_url('https://ixdzs.com/read/552802/p1.html'), 'https://ixdzs.com/read/552802/',
    'ixdzs normalise_url preserves a mirror host rather than hardcoding ixdzs.tw')

  eq(ixdzs.entry_chapter('https://ixdzs.tw/read/552802/p1.html'), 'p1',
    'ixdzs entry_chapter reads the chapter id from a chapter URL')
  is_nil(ixdzs.entry_chapter('https://ixdzs.tw/read/552802/'), 'ixdzs entry_chapter is nil for an index URL')

  eq(ixdzs.novel_key('https://ixdzs.tw/read/552802/p1.html'), ixdzs.novel_key('https://ixdzs.com/read/552802/p9.html'),
    'ixdzs novel_key is mirror-independent (same key across ixdzs.tw and ixdzs.com)')
  eq(ixdzs.novel_key('https://ixdzs.tw/read/552802/p1.html'), 'ixdzs/552802',
    'ixdzs novel_key is keyed on book id alone')

  eq(ixdzs.bufname('https://ixdzs.tw/read/552802/p1.html'), 'novim://552802/p1',
    'ixdzs bufname is novim://<bid>/<chapterId>')
  eq(ixdzs.bufname('https://ixdzs.tw/read/552802/'), 'novim://552802',
    'ixdzs bufname on an index URL has no chapter segment')
  eq(ixdzs.label('https://ixdzs.tw/read/552802/p1.html'), '552802/p1',
    'ixdzs label strips the novim:// prefix off bufname')
end

do
  local toc_html = read_fixture('ixdzs_toc_fragment.html')
  local nodes, err = ixdzs.parse_toc(toc_html, 'https://ixdzs.tw/read/552802/')
  truthy(nodes and not err, 'ixdzs TOC parses without error')
  if nodes then
    eq(#nodes, 5, 'ixdzs TOC produces a flat list of 5 leaf nodes, no synthetic grouping')
    eq(nodes[1].title, 'Placeholder Chapter 1', 'ixdzs TOC first node title, document order')
    eq(nodes[5].title, 'Placeholder Chapter 5', 'ixdzs TOC last node title, document order')
    truthy(nodes[1].is_leaf == true, 'ixdzs TOC node is a leaf')
    eq(#nodes[1].children, 0, 'ixdzs TOC leaf node has no children')
    eq(nodes[3].url, 'https://ixdzs.tw/read/552802/p3.html', 'ixdzs TOC relative href resolved absolute against the source host')
  end

  local empty_nodes, empty_err = ixdzs.parse_toc('', 'https://ixdzs.tw/read/552802/')
  is_nil(empty_nodes, 'ixdzs TOC on an empty fragment returns nil nodes')
  truthy(empty_err ~= nil, 'ixdzs TOC on an empty fragment returns an error')
end

do
  local html = read_fixture('ixdzs_chapter_p1.html')
  local lines, prev_url, next_url, title, err = ixdzs.parse_chapter(html, 'https://ixdzs.tw/read/552802/p1.html')
  truthy(lines and not err, 'ixdzs chapter p1 parses without error')
  eq(title, 'Placeholder Chapter Title 1', 'ixdzs chapter p1 title read from h1.page-d-name')
  if lines then
    local body = table.concat(lines, '\n')
    truthy(lines[1] and lines[1]:match('^PLACEHOLDER_PARA_ONE'), 'ixdzs chapter p1 body starts at first content line')
    truthy(lines[#lines] and lines[#lines]:match('PLACEHOLDER_PARA_THREE'), 'ixdzs chapter p1 body ends at last content line')
    not_contains(body, 'BG_SSP_MARKER_TEXT', 'ixdzs chapter p1 body excludes the bg-ssp ad block')
    not_contains(body, 'ABG_MARKER_TEXT', 'ixdzs chapter p1 body excludes the trailing p.abg ad')
    not_contains(body, 'var x = 1', 'ixdzs chapter p1 body excludes inline script content')
    is_nil(lines[1]:match('^Placeholder Chapter Title 1$'), 'ixdzs chapter p1 duplicated h3 heading is not the first body line')
  end
  is_nil(prev_url, 'ixdzs chapter p1 has no previous chapter (chapter-pre points at the index page trap)')
  eq(next_url, 'https://ixdzs.tw/read/552802/p2.html', 'ixdzs chapter p1 next URL resolved absolute')
end

do
  local html = read_fixture('ixdzs_chapter_mid.html')
  local lines, prev_url, next_url, title, err = ixdzs.parse_chapter(html, 'https://ixdzs.tw/read/552802/p3.html')
  truthy(lines and not err, 'ixdzs chapter mid parses without error')
  eq(title, 'Placeholder Chapter Title Mid', 'ixdzs chapter mid title read from h1.page-d-name')
  eq(prev_url, 'https://ixdzs.tw/read/552802/p2.html', 'ixdzs chapter mid previous URL resolved absolute')
  eq(next_url, 'https://ixdzs.tw/read/552802/p4.html', 'ixdzs chapter mid next URL resolved absolute')
end

do
  local html = read_fixture('ixdzs_search.html')
  local results, err = ixdzs.parse_search(html, 'https://ixdzs.tw/bsearch?q=x')
  truthy(results and not err, 'ixdzs search parses without error')
  if results then
    eq(#results, 2, 'ixdzs search returns 2 results')
    eq(results[1].title, 'Placeholder Novel One Full Title', 'ixdzs search first result title (from a[title], not truncated link text)')
    eq(results[1].url, 'https://ixdzs.tw/read/552802/', 'ixdzs search first result URL resolved absolute from data-url')
    eq(results[1].author, 'Placeholder Author One', 'ixdzs search first result author')
    eq(results[1].status, 'Ongoing', 'ixdzs search first result status')
    eq(results[2].title, 'Placeholder Novel Two Full Title', 'ixdzs search second result title')
  end
end

----------------------------------------------------------------------
-- czbooks search
----------------------------------------------------------------------
do
  local html = read_fixture('czbooks_search.html')
  local results, err = czbooks.parse_search(html, 'https://czbooks.net/s/x')
  truthy(results and not err, 'czbooks search parses without error')
  if results then
    eq(#results, 2, 'czbooks search returns 2 results')
    eq(results[1].title, 'Placeholder Novel Alpha', 'czbooks search first result title')
    eq(results[1].url, 'https://czbooks.net/n/aaa111', 'czbooks search first result URL resolved from a protocol-relative href')
    eq(results[1].author, 'Placeholder Author Alpha', 'czbooks search first result author')
    eq(results[1].status, 'Ongoing', 'czbooks search first result status')
    eq(results[2].title, 'Placeholder Novel Beta', 'czbooks search second result title')
  end
end

----------------------------------------------------------------------
-- sites.searchable()
----------------------------------------------------------------------
do
  local searchable = sites.searchable()
  local names = {}
  for _, adapter in ipairs(searchable) do names[adapter.source_name] = true end
  truthy(names['czbooks'], 'sites.searchable() includes czbooks')
  truthy(names['ixdzs'], 'sites.searchable() includes ixdzs')

  local has_legacy = false
  for _, adapter in ipairs(searchable) do
    if adapter == legacy then has_legacy = true end
  end
  truthy(not has_legacy, 'sites.searchable() excludes the legacy fallback adapter')

  local ixdzs_resolved = sites.resolve('https://ixdzs.tw/read/552802/p1.html')
  truthy(ixdzs_resolved == ixdzs, 'sites.resolve returns the ixdzs adapter for an ixdzs URL, ahead of legacy')
end

----------------------------------------------------------------------
-- fetcher.url_encode
----------------------------------------------------------------------
do
  eq(fetcher.url_encode('abc123-_.~'), 'abc123-_.~', 'url_encode leaves unreserved characters unchanged')
  eq(fetcher.url_encode('a b'), 'a%20b', 'url_encode percent-encodes a reserved character (space)')
  eq(fetcher.url_encode('部'), '%E9%83%A8', 'url_encode percent-encodes a CJK character by UTF-8 byte')
end

----------------------------------------------------------------------
-- sidebar.collect_leaf_sequence (jump-to-chapter numbering, as a pure
-- function over a synthetic tree -- no live sidebar window needed)
----------------------------------------------------------------------
local sidebar = require('novim.sidebar')

do
  local flat_tree = {
    { title = 'Ch1', url = 'u1', children = {}, is_leaf = true, expanded = false },
    { title = 'Ch2', url = 'u2', children = {}, is_leaf = true, expanded = false },
    { title = 'Ch3', url = 'u3', children = {}, is_leaf = true, expanded = false },
  }
  local leaves = sidebar.collect_leaf_sequence(flat_tree)
  eq(#leaves, 3, 'collect_leaf_sequence over a flat tree returns every leaf')
  eq(leaves[1].node.title, 'Ch1', 'collect_leaf_sequence preserves document order (1st)')
  eq(leaves[3].node.title, 'Ch3', 'collect_leaf_sequence preserves document order (3rd)')
  eq(#leaves[1].ancestors, 0, 'collect_leaf_sequence: a top-level leaf has no ancestors')
end

do
  local group = {
    title = 'Volume One', url = nil, expanded = false, is_leaf = false,
    children = {
      { title = 'Ch1', url = 'u1', children = {}, is_leaf = true, expanded = false },
      { title = 'Ch2', url = 'u2', children = {}, is_leaf = true, expanded = false },
    },
  }
  local tree = {
    { title = 'Ch0', url = 'u0', children = {}, is_leaf = true, expanded = false },
    group,
  }
  local leaves = sidebar.collect_leaf_sequence(tree)
  eq(#leaves, 3, 'collect_leaf_sequence walks into a collapsed group (leaves found regardless of expanded state)')
  eq(leaves[2].node.title, 'Ch1', 'collect_leaf_sequence: 2nd leaf is the collapsed group\'s first child')
  eq(#leaves[2].ancestors, 1, 'collect_leaf_sequence: leaf inside a group has that group as its ancestor')
  truthy(leaves[2].ancestors[1] == group, 'collect_leaf_sequence: ancestor reference is the actual group node')
  eq(leaves[3].node.title, 'Ch2', 'collect_leaf_sequence: 3rd leaf is the collapsed group\'s second child')
end

----------------------------------------------------------------------
-- reader.resolve_autosave_line (regression: autosave writing progress
-- under the wrong novel when switching chapters via cross-source search)
--
-- Two bugs, fixed together:
-- 1. setup_autosave used to read state.current_url inside the BufLeave
--    callback, but M.open reassigns state.current_url to the NEW
--    chapter's url before the OLD buffer's BufLeave fires -- so the old
--    buffer's cursor line got saved under the new novel's key. Fixed by
--    binding url at buffer-creation time (tested at the reader.lua call
--    site, not exercisable as a pure function here).
-- 2. setup_autosave used to read the cursor from window 0 (the CURRENT
--    window), not necessarily the window displaying the buffer being
--    left (e.g. focus was on the sidebar window). resolve_autosave_line
--    extracts that decision into a pure function: given the buffer being
--    left and the live {win, buf} pairs, find the window that actually
--    shows it, or return nil (skip save) if none does.
----------------------------------------------------------------------
local reader = require('novim.reader')

do
  local line = reader.resolve_autosave_line(42, {
    { win = 1000, buf = 99 },
    { win = 1001, buf = 42 },
  }, function(win)
    if win == 1001 then return 7 end
    error('cursor_fn called for the wrong window: ' .. win)
  end)
  eq(line, 7, 'resolve_autosave_line reads the cursor from the window that actually shows the target buffer')
end

do
  local line = reader.resolve_autosave_line(42, {
    { win = 1000, buf = 99 },
  }, function(win)
    error('cursor_fn should not be called when no window shows the target buffer')
  end)
  is_nil(line, 'resolve_autosave_line returns nil (skip save) when no window displays the target buffer, e.g. focus is on the sidebar')
end

do
  -- The window showing the target buffer is not the first or current
  -- window -- must not just grab win_buf_pairs[1] or "the current window".
  local line = reader.resolve_autosave_line(5, {
    { win = 10, buf = 1 },
    { win = 20, buf = 2 },
    { win = 30, buf = 5 },
  }, function(win) return win end)
  eq(line, 30, 'resolve_autosave_line finds the target buffer\'s window regardless of its position in the window list')
end

-- The three tests above cover resolve_autosave_line's DECISION logic in
-- isolation, but the fix rests on an assumption about Neovim itself that
-- pure functions can't exercise: that when BufLeave fires during
-- nvim_win_set_buf, the affected window still reports the OLD buffer at
-- the moment the callback runs. If that ordering were ever reversed,
-- resolve_autosave_line would find no window showing the left buffer and
-- return nil -- setup_autosave would silently SKIP the save entirely,
-- trading corruption for silent total loss of autosave. This block pins
-- that guarantee against a real buffer/window/autocmd (unlike the rest of
-- this suite, which only exercises pure parsing), so a future Neovim or
-- refactor can't quietly re-break it.
do
  local orig_win = vim.api.nvim_get_current_win()
  local orig_buf = vim.api.nvim_win_get_buf(orig_win)

  local buf_a = vim.api.nvim_create_buf(true, false)
  local buf_b = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(buf_a, 0, -1, false, { 'a1', 'a2', 'a3', 'a4', 'a5' })
  vim.api.nvim_buf_set_lines(buf_b, 0, -1, false, { 'b1', 'b2' })

  local win = orig_win
  vim.api.nvim_win_set_buf(win, buf_a)
  vim.api.nvim_win_set_cursor(win, { 4, 0 })

  local fired, saved_line
  local autocmd_id = vim.api.nvim_create_autocmd('BufLeave', {
    buffer = buf_a,
    callback = function()
      fired = true
      local win_buf_pairs = {}
      for _, w in ipairs(vim.api.nvim_list_wins()) do
        table.insert(win_buf_pairs, { win = w, buf = vim.api.nvim_win_get_buf(w) })
      end
      saved_line = reader.resolve_autosave_line(buf_a, win_buf_pairs, function(w)
        return vim.api.nvim_win_get_cursor(w)[1]
      end)
    end,
  })

  local other_win
  local ok, err = pcall(function()
    -- CASE 1: same window swaps A -> B (the chapter/novel switch path).
    fired, saved_line = false, nil
    vim.api.nvim_win_set_buf(win, buf_b)
    truthy(fired, 'BufLeave fires when nvim_win_set_buf swaps the window off buf_a')
    eq(saved_line, 4,
      'BufLeave-ordering assumption broke: the window must still report the OLD buffer when BufLeave '
        .. 'fires so resolve_autosave_line can find it and read its own cursor line (4). A failure here '
        .. 'means Neovim changed the ordering and autosave is now silently skipping saves (returns nil), '
        .. 'not just saving the wrong line -- this is not a cosmetic off-by-one, it is silent data loss')

    -- CASE 2: buf_a stays visible in `win`, but focus moves to a different
    -- window (the sidebar-focus case the fix exists for).
    vim.api.nvim_win_set_buf(win, buf_a)
    vim.api.nvim_win_set_cursor(win, { 2, 0 })
    vim.cmd('vsplit')
    other_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(other_win, buf_b)
    vim.api.nvim_set_current_win(other_win)

    fired, saved_line = false, nil
    vim.api.nvim_win_set_buf(win, buf_b)
    truthy(fired, 'BufLeave fires when the focused-elsewhere window is swapped off buf_a')
    eq(saved_line, 2,
      'resolve_autosave_line reads buf_a\'s own window cursor (2), not the focused-but-unrelated '
        .. 'window\'s cursor (1), when focus is on a different window than the one showing the buffer being left')
  end)

  -- Cleanup runs unconditionally: a leaked split window, scratch buffer,
  -- or live BufLeave autocmd here would corrupt the config.setup /
  -- NOVIM_DATA_DIR tests that run after this block.
  vim.api.nvim_del_autocmd(autocmd_id)
  if other_win and vim.api.nvim_win_is_valid(other_win) then
    vim.api.nvim_win_close(other_win, true)
  end
  if vim.api.nvim_win_is_valid(orig_win) then
    vim.api.nvim_set_current_win(orig_win)
    vim.api.nvim_win_set_buf(orig_win, orig_buf)
  end
  if vim.api.nvim_buf_is_valid(buf_a) then
    vim.api.nvim_buf_delete(buf_a, { force = true })
  end
  if vim.api.nvim_buf_is_valid(buf_b) then
    vim.api.nvim_buf_delete(buf_b, { force = true })
  end

  if not ok then error(err, 0) end
end

----------------------------------------------------------------------
print(string.format('\n%d checks, %d failures', checks, failures))
if failures > 0 then
  os.exit(1)
end
os.exit(0)
