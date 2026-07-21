-- Guard against double-loading
if vim.g.novim_loaded then return end
vim.g.novim_loaded = true

-- Verify plenary or curl are available
local has_plenary = pcall(require, 'plenary.curl')
if not has_plenary then
  if vim.fn.executable('curl') == 0 then
    vim.notify(
      '[NoVim] plenary.nvim required. Add it to dependencies:\n'
        .. '  { "nvim-lua/plenary.nvim" }',
      vim.log.levels.ERROR
    )
  end
end

-- Auto-setup with defaults (user can override by calling setup() in their config)
require('novim').setup({})

-- Register :NoVim command
vim.api.nvim_create_user_command('NoVim', function()
  require('novim').toggle()
end, { desc = 'Toggle NoVim reader sidebar' })

-- Register :NoVimUrl command — edit saved source URL from anywhere.
-- Takes an optional URL; without one, prompts with the current value.
vim.api.nvim_create_user_command('NoVimUrl', function(opts)
  require('novim.sidebar').edit_url(opts.args ~= '' and opts.args or nil)
end, { nargs = '?', desc = 'Edit NoVim source URL' })
