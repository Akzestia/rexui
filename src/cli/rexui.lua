-- Copyright (c) 2026-present アクゼスティア
-- SPDX-License-Identifier: LicenseRef-rexui-1.0
local M = {}

M.command = os.getenv("HOME") .. "/.local/bin/rexui"

local function run(...)
    local r = rex.exec{ M.command, ... }
    if not r.ok then rex.log("rexui " .. table.concat({ ... }, " ") .. ": " .. (r.stderr or "")) end
    return r.ok, r.stdout
end

function M.load(name) return run("load", name) end
function M.try(path) return run("try", path) end
function M.stop() return run("try", "stop") end
local function where(opts)
    opts = opts or {}
    local w = {}
    if opts.block then w[#w + 1] = "--block"; w[#w + 1] = opts.block end
    if opts.tab then w[#w + 1] = "--tab"
    elseif opts.split or not opts.block then w[#w + 1] = "--split"; w[#w + 1] = opts.split or "right" end
    return w
end
local function shown_in(cmd, what, opts, own)
    local a = where(opts)
    for _, o in ipairs(own or {}) do a[#a + 1] = o end
    a[#a + 1] = what
    for _, x in ipairs((opts or {}).args or {}) do a[#a + 1] = x end
    return run(cmd, table.unpack(a))
end

function M.embed(what, opts)
    local own = {}
    if opts and opts.relative then own[#own + 1] = "--relative" end
    if opts and opts.crossover then own[#own + 1] = "--crossover" end
    return shown_in("embed", what, opts, own)
end
function M.pane(what, opts) return shown_in("pane", what, opts) end
function M.launch(name, opts) return shown_in("launch", name, opts) end
function M.launchable()
    local ok, out = run("launch")
    local list = {}
    if ok then
        for kind, name in out:gmatch("(%S+)%s+([^\n]-)%s*\n") do list[#list + 1] = { kind = kind, name = name } end
    end
    return list
end

function M.current()
    local ok, out = run("current")
    return ok and out:gsub("%s+$", "") or nil
end

return M
