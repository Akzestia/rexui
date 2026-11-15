-- Copyright (c) 2026-present アクゼスティア
-- SPDX-License-Identifier: MIT
local M = {}

local editor = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h:h")
local checkout = vim.fn.fnamemodify(editor, ":h:h")

M.defaults = {
	cmd = { checkout .. "/build/rui-ls" },
	grammar_path = editor .. "/tree-sitter-rui",
	indent = true,
}

function M.setup(opts)
	opts = vim.tbl_extend("force", M.defaults, vim.g.rui or {}, opts or {})
	M.opts = opts

	vim.filetype.add({ extension = { rui = "rui" } })
	require("rui.tree-sitter").setup(opts)
	require("rui.ls").setup(opts)

	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_loaded(buf) and vim.api.nvim_buf_get_name(buf):match("%.rui$") and vim.bo[buf].filetype ~= "rui" then
			vim.bo[buf].filetype = "rui"
		end
	end
end

return M
