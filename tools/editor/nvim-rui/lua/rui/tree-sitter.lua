-- Copyright (c) 2026-present アクゼスティア
-- SPDX-License-Identifier: MIT
local M = {}

local function register_parser(opts)
	local ok, parsers = pcall(require, "nvim-treesitter.parsers")
	if not ok or not opts.grammar_path then
		return
	end
	if type(parsers.get_parser_configs) == "function" then
		parsers.get_parser_configs().rui = {
			install_info = { url = opts.grammar_path, files = { "src/parser.c", "src/scanner.c" } },
			filetype = "rui",
		}
	else
		parsers.rui = { install_info = { path = opts.grammar_path } }
	end
end

local function parser_path()
	return vim.fn.stdpath("data") .. "/site/parser/rui.so"
end

local function install_parser(opts, why, done)
	local out = parser_path()
	vim.fn.mkdir(vim.fs.dirname(out), "p")
	local src = opts.grammar_path .. "/src"
	vim.notify("rui: building " .. out .. (why or ""))
	vim.system(
		{ "cc", "-O2", "-shared", "-fPIC", "-I", src, src .. "/parser.c", src .. "/scanner.c", "-o", out .. ".new" },
		{ text = true },
		vim.schedule_wrap(function(r)
			if r.code ~= 0 or not os.rename(out .. ".new", out) then
				vim.notify("rui: cc failed: " .. (r.stderr or ""), vim.log.levels.ERROR)
				return
			end
			if done then
				done()
			else
				vim.notify("rui: parser built; restart nvim for it (a loaded parser stays loaded)")
			end
		end)
	)
end

local checked = false
local function stale(opts)
	if checked or not opts.grammar_path then
		return false
	end
	checked = true
	local so = vim.uv.fs_stat(parser_path())
	local c = vim.uv.fs_stat(opts.grammar_path .. "/src/parser.c")
	return so ~= nil and c ~= nil and c.mtime.sec > so.mtime.sec
end

local warned = false
local building = false

local function start(buf, opts)
	if building then
		return
	end
	if stale(opts) then
		building = true
		install_parser(opts, " (the grammar is newer)", function()
			building = false
			for _, b in ipairs(vim.api.nvim_list_bufs()) do
				if vim.api.nvim_buf_is_loaded(b) and vim.bo[b].filetype == "rui" then
					start(b, opts)
				end
			end
		end)
		return
	end
	if not pcall(vim.treesitter.language.add, "rui") then
		if not warned then
			warned = true
			vim.notify("rui: tree-sitter parser not installed: :TSInstall rui (or :RuiInstallParser)", vim.log.levels.WARN)
		end
		return
	end
	pcall(vim.treesitter.start, buf, "rui")
end

function M.setup(opts)
	local group = vim.api.nvim_create_augroup("rui_treesitter", { clear = true })
	vim.api.nvim_create_autocmd("User", {
		group = group,
		pattern = "TSUpdate",
		callback = function()
			register_parser(opts)
		end,
	})
	register_parser(opts)
	vim.api.nvim_create_user_command("RuiInstallParser", function()
		install_parser(opts)
	end, { desc = "Build the .rui tree-sitter parser with cc" })
	vim.api.nvim_create_autocmd("FileType", {
		group = group,
		pattern = "rui",
		callback = function(ev)
			vim.bo[ev.buf].commentstring = "// %s"
			start(ev.buf, opts)
			if opts.indent then
				local ok, nts = pcall(require, "nvim-treesitter")
				if ok and type(nts.indentexpr) == "function" then
					vim.bo[ev.buf].indentexpr = "v:lua.require'nvim-treesitter'.indentexpr()"
				end
			end
		end,
	})
end

return M
