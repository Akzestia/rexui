# Lua 5.4.7

lua.org's source (lua-5.4.7.tar.gz, SHA-256 9fbf5e28ef86c69858f6d3d34eccc32e911c1a28b4120ff3e84aaa70cfbf1e30), `src/`
without `lua.c` and `luac.c`, unchanged. MIT licensed: the notice is at the end of `lua.h`. rexui reads a distro's
`rui-config.lua` with it (src/base/config.mm), in a state of its own with only the base, string, table, math and utf8 libraries.
