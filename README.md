# NoVim

Read web novels inside Neovim.

- NeoTree-style sidebar with collapsible chapter list
- Fetches and displays content in a read-only buffer
- Remembers your exact reading position (chapter + line) across sessions
- Prev/next chapter navigation with `]c` / `[c`

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

Position is saved automatically to `{stdpath('data')}/novim_progress.json`
whenever you leave the reader buffer or exit Neovim. On next `:NoVim`, you
will be prompted to resume at your saved chapter and line number.

## Windows note

On Windows, plenary.nvim uses system `curl.exe`. Ensure `curl` is available
in your PATH (ships with Windows 10 1803+).
