-- Copyright (c) 2026-present アクゼスティア
-- SPDX-License-Identifier: MIT
local M = {}

local function capabilities()
	local ok, blink = pcall(require, "blink.cmp")
	if ok then
		return blink.get_lsp_capabilities()
	end
	return vim.lsp.protocol.make_client_capabilities()
end

function M.setup(opts)
	if not opts.cmd then
		return
	end
	if vim.fn.executable(opts.cmd[1]) == 0 then
		vim.notify("rui: " .. opts.cmd[1] .. " not found, so no rui-ls", vim.log.levels.WARN)
		return
	end
	local config = {
		cmd = opts.cmd,
		filetypes = { "rui" },
		root_markers = { ".git" },
		capabilities = capabilities(),
	}

	if vim.lsp.config and vim.lsp.enable then
		vim.lsp.config("rui_ls", config)
		vim.lsp.enable("rui_ls")
		return
	end

	local ok, lspconfig = pcall(require, "lspconfig")
	if not ok then
		vim.notify("rui: Neovim < 0.11 needs nvim-lspconfig", vim.log.levels.WARN)
		return
	end
	local configs = require("lspconfig.configs")
	local util = require("lspconfig.util")
	configs.rui_ls = {
		default_config = {
			cmd = config.cmd,
			filetypes = config.filetypes,
			root_dir = function(fname)
				return util.root_pattern(unpack(config.root_markers))(fname) or vim.fs.dirname(fname)
			end,
			capabilities = config.capabilities,
		},
	}
	lspconfig.rui_ls.setup({})
end

return M
