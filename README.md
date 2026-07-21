# NoVim

Read web novels inside Neovim.

- NeoTree-style sidebar with collapsible chapter list
- Fetches and displays content in a read-only buffer
- Remembers your exact reading position (chapter + line) per novel, across sessions
- Prev/next chapter navigation with `]c` / `[c`

## Supported sites

- [czbooks.net](https://czbooks.net)
- Any other site whose pages follow the generic `#sidebar` / `#content_wrapper` /
  `#article` layout NoVim originally targeted (handled by the fallback adapter)

`source_url` accepts either a novel's index page or a direct chapter URL — if
you paste a chapter URL and haven't read that novel before, NoVim opens that
chapter as soon as the sidebar loads.

## Requirements

- Neovim ≥ 0.8
- [plenary.nvim](https://github.com/nvim-lua/plenary.nvim) **or** `curl` in your PATH

## Installation

### lazy.nvim

```lua
{
  'LizardLiang/NoVim',
  dependencies = { 'nvim-lua/plenary.nvim' },
  config = function()
    require('novim').setup({
      -- all options are optional
      sidebar_width = 40,
      word_wrap = true,
      keymaps = {
        next_chapter   = ']c',
        prev_chapter   = '[c',
        toggle_sidebar = '<leader>nv',
      },
      -- Override or add outbound HTTP request headers. NoVim already
      -- sends a browser User-Agent and Accept-Language by default (some
      -- sites, e.g. czbooks.net, reject requests without one); use this
      -- only if a site needs something different. Header names are
      -- matched case-insensitively against the defaults, so
      -- ['user-agent'] below replaces the built-in User-Agent rather
      -- than being sent alongside it.
      http_headers = {
        -- ['User-Agent'] = 'Mozilla/5.0 ...',
      },
      -- Alternatively, scope headers to a single host so they aren't
      -- sent on every outbound request — useful for a Cookie or
      -- Authorization header that should only ever go to one site.
      -- Detected automatically: if every value in http_headers is itself
      -- a table, it's treated as host-keyed instead of flat.
      --   http_headers = {
      --     ['czbooks.net'] = { ['Cookie'] = 'session=...' },
      --   },
      -- Caveat: this scopes headers to the host of the request NoVim
      -- initiates. If that request redirects to a different host, curl
      -- (and plenary, which shells out to curl) does not strip
      -- manually-supplied headers across the redirect — host-scoping
      -- here cannot prevent that. Avoid putting secrets in http_headers
      -- for sites that redirect to third-party hosts.
    })
  end,
}
```

## Usage

| Command / Key | Action |
|---------------|--------|
| `:NoVim` | Toggle chapter sidebar |
| `<leader>nv` | Toggle chapter sidebar (keymap) |
| `<Enter>` in sidebar | Open chapter / expand group |
| `o` or `<Tab>` in sidebar | Expand / collapse chapter group |
| `q` in sidebar | Close sidebar |
| `r` in sidebar | Refresh chapter list |
| `?` in sidebar | Show sidebar key help |
| `]c` in reader | Next chapter |
| `[c` in reader | Previous chapter |

## Status line integration

```lua
-- lualine example
require('lualine').setup({
  sections = {
    lualine_c = {
      function() return require('novim').statusline() end,
    },
  },
})
```

Returns `Ch.060 / 43` when reading a chapter, empty string otherwise.

## Reading position

Position is saved per novel automatically to
`{stdpath('data')}/novim_progress.json` whenever you leave the reader buffer
or exit Neovim. On next `:NoVim`, you will be prompted to resume the
most recently read novel at its saved chapter and line number.

## Windows note

On Windows, plenary.nvim uses system `curl.exe`. Ensure `curl` is available
in your PATH (ships with Windows 10 1803+).
