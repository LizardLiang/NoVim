# NoVim

Read web novels inside Neovim.

- NeoTree-style sidebar with collapsible chapter list
- Fetches and displays content in a read-only buffer
- Remembers your exact reading position (chapter + line) per novel, across sessions
- Prev/next chapter navigation with `]c` / `[c`
- Search every supported source at once with `:NoVimSearch`
- A novel library (`:NoVimLibrary`) to switch between every previously read
  novel, most-recently-read first

## Supported sites

- [czbooks.net](https://czbooks.net)
- [ixdzs.tw](https://ixdzs.tw) (and mirrors, e.g. ixdzs.com) — long flat
  chapter lists (no synthetic volume grouping); use the sidebar's `c` key
  to jump straight to a chapter number instead of scrolling
- Any other site whose pages follow the generic `#sidebar` / `#content_wrapper` /
  `#article` layout NoVim originally targeted (handled by the fallback adapter)

`source_url` accepts either a novel's index page or a direct chapter URL — if
you paste a chapter URL and haven't read that novel before, NoVim opens that
chapter as soon as the sidebar loads.

## Searching

`:NoVimSearch <query>` searches every searchable source at once and shows
the combined, source-labelled results in a picker — requests fan out
concurrently, so the editor stays responsive while they're in flight.
Omit the query (`:NoVimSearch` alone, or the sidebar's `s` key) to be
prompted for one instead. Choosing a result makes that novel the active
source, loads its chapter list, and resumes your saved position if you've
read it before — the novel you switched away from keeps its own saved
position.

Uses [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim)
when installed, for a streaming, filterable picker; falls back to
`vim.ui.select` (or whatever plugin, e.g. `dressing.nvim`, replaces it)
when Telescope isn't present — neither is a required dependency.

## Novel library

`:NoVimLibrary` (or the sidebar's `l` key) opens a dedicated window listing
every novel you have saved reading progress for, most-recently-read first,
each showing its title (fetched automatically from the site when the
chapter list loads) and saved position — or its storage key when a title
isn't available yet or the site has none (the fallback adapter never has
one). This is a dedicated window rather than a picker: `vim.ui.select`
can't bind a removal key, so on a setup with no Telescope installed a
picker-based library would make removal unreachable.

| Key | Action |
|-----|--------|
| `<Enter>` | Open the novel under the cursor — makes it the active source, loads its chapter list, and resumes its saved position |
| `d` | Remove the novel under the cursor (confirms first — this deletes its saved position and cannot be undone) |
| `q` | Close the library |
| `r` | Refresh |

The first time the library is opened, any pre-existing entries saved
before this feature (or that failed to get a title before) have their
titles backfilled in the background — the library stays usable immediately
with keys shown as a placeholder, filling in as each title arrives.

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
| `:NoVimSearch [query]` | Search all sources (prompts if `query` omitted) |
| `:NoVimLibrary` | Open the novel library |
| `<leader>nv` | Toggle chapter sidebar (keymap) |
| `<Enter>` in sidebar | Open chapter / expand group |
| `o` or `<Tab>` in sidebar | Expand / collapse chapter group |
| `q` in sidebar | Close sidebar |
| `r` in sidebar | Refresh chapter list |
| `u` in sidebar | Change source URL |
| `s` in sidebar | Search across sources |
| `c` in sidebar | Jump to chapter number |
| `l` in sidebar | Open novel library |
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

### Syncing across devices

Set the `NOVIM_DATA_DIR` environment variable to relocate all persisted
state — reading progress (`novim_progress.json`) and settings
(`novim_settings.json`, the saved source URL) — into a directory of your
choice, e.g. a OneDrive folder so progress follows you across machines:

```powershell
# Windows (persistent, takes effect in new sessions)
setx NOVIM_DATA_DIR "$env:OneDrive\novim"
```

```sh
# Linux / macOS (add to your shell profile)
export NOVIM_DATA_DIR="$HOME/OneDrive/novim"
```

Precedence: `NOVIM_DATA_DIR` > `setup({ save_path = ... })` > the
`stdpath('data')` default. The directory is created if missing; if it can't
be created, NoVim warns and falls back to the default location. `~` is
expanded.

To carry over existing local state, copy the two JSON files from
`stdpath('data')` (`:echo stdpath('data')`) into the new directory once.

Caveat: sync is whole-file last-write-wins. Reading on two devices at the
same time can lose the older device's latest position for a novel; each
novel has its own slot, so other novels are unaffected.

## Windows note

On Windows, plenary.nvim uses system `curl.exe`. Ensure `curl` is available
in your PATH (ships with Windows 10 1803+).
