-- VM-local neovim config for reviewing nixpkgs.
-- Intentionally standalone: no plugin manager, no lazy-lock.json, nothing
-- shared with the Mac's dotfiles (the host home is mounted read-only anyway).
-- Everything here uses neovim 0.12's built-in LSP client.

vim.g.mapleader = " "

vim.opt.number = true
vim.opt.relativenumber = true
vim.opt.expandtab = true
vim.opt.shiftwidth = 2
vim.opt.tabstop = 2
vim.opt.signcolumn = "yes"
vim.opt.termguicolors = true
vim.opt.undofile = true
vim.opt.ignorecase = true
vim.opt.smartcase = true
vim.opt.scrolloff = 5
vim.opt.clipboard = "unnamedplus"

vim.diagnostic.config({
  virtual_text = true,
  severity_sort = true,
  float = { border = "rounded" },
})

-- nixd. `nixpkgs.expr` uses a plain path import rather than builtins.getFlake:
-- getFlake on the 3.5 GB working checkout would copy the whole tree into the
-- store on every evaluation.
vim.lsp.config("nixd", {
  cmd = { "nixd" },
  filetypes = { "nix" },
  root_markers = { "flake.nix", ".git" },
  settings = {
    nixd = {
      nixpkgs = { expr = "import " .. vim.env.HOME .. "/nixpkgs { }" },
      formatting = { command = { "nixfmt" } },
      options = {
        nixos = {
          expr = "(builtins.getFlake \"" .. vim.env.HOME .. "/nixos-config\").nixosConfigurations.nixos.options",
        },
      },
    },
  },
})
vim.lsp.enable("nixd")

vim.api.nvim_create_autocmd("LspAttach", {
  callback = function(args)
    local opts = { buffer = args.buf, silent = true }
    vim.keymap.set("n", "gd", vim.lsp.buf.definition, opts)
    vim.keymap.set("n", "gr", vim.lsp.buf.references, opts)
    vim.keymap.set("n", "K", vim.lsp.buf.hover, opts)
    vim.keymap.set("n", "<leader>rn", vim.lsp.buf.rename, opts)
    vim.keymap.set("n", "<leader>ca", vim.lsp.buf.code_action, opts)
    vim.keymap.set("n", "<leader>f", function() vim.lsp.buf.format({ async = true }) end, opts)
  end,
})

vim.keymap.set("n", "<leader>e", vim.diagnostic.open_float, { silent = true })
vim.keymap.set("n", "[d", function() vim.diagnostic.jump({ count = -1 }) end, { silent = true })
vim.keymap.set("n", "]d", function() vim.diagnostic.jump({ count = 1 }) end, { silent = true })

-- Lint the whole file with statix/deadnix, straight into the quickfix list.
vim.api.nvim_create_user_command("NixLint", function()
  local file = vim.fn.expand("%:p")
  vim.cmd("cexpr system('statix check " .. file .. " 2>&1; deadnix " .. file .. " 2>&1')")
  vim.cmd("copen")
end, {})

vim.api.nvim_create_autocmd("BufWritePre", {
  pattern = "*.nix",
  callback = function() vim.lsp.buf.format({ timeout_ms = 3000 }) end,
})
