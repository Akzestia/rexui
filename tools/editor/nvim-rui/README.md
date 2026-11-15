# nvim-rui

Neovim support for rexui's `.rui` files (README: Docks): the `rui` filetype, tree-sitter highlighting,
folding and indenting (`tools/editor/tree-sitter-rui`: QML-style elements on tree-sitter-javascript, so
bindings and handlers are highlighted as the JavaScript they are), and `rui-ls`
(`tools/editor/rui-ls`), the language server:

- diagnostics: what the dock would refuse at load, with the engine's own message (a syntax error,
  an unknown element, property or signal, an id used twice, an id inside a delegate, JavaScript that
  doesn't compile), and what loads but can't work (`onFooChanged` of no property, `clock.stat` of a
  Process, a property set twice);
- hints: what a file costs that it needn't (`rexui check --perf`'s static rules: a clock's Timer off the
  wall clock, a List of hundreds not virtualized, a Shader running with nothing to stop it, a big Drawer made at load);
- completion: an element's properties, handlers and the elements at a member, ids, the element's
  and the Dock's names, `modelData`/`index` in a delegate, the signal's arguments in a handler, and
  after a dot an id's members, `font.`'s, `theme.`/`rex.`/`i18n.`/`conf.`'s;
- hover (an element's or a property's default and README's words), go to definition (ids, your own
  properties and functions), references, highlights and rename of ids, document symbols.
- formatting (whole file or a range; with conform's `lsp_format = "fallback"`, on save): indentation
  only, with trailing spaces and `key:value` -> `key: value`. Members one level in from their element's
  line, closing brackets at their opener's; every other line (JavaScript, a value going on to the next
  line) moves with the line it hangs from, so alignment stays. No line is joined or split, multi-line
  template strings and `/* */` comments stay as they are, and a file that doesn't parse is left alone.
  It follows the editor's `shiftwidth`/`expandtab`.

The server is C++ on rexui's engine (`tools/editor/rui-ls`, built into `build/rui-ls` by `just b`): the
engine's parser and checks, the schema's elements (`src/schema/elements.rxs`) and the engine's globals.
It reads `README.md` from this checkout for hover text, again whenever it changes; a new element or
property in the schema needs `just b` and a restart of the server.

## Install

lazy.nvim, with nothing to configure (the plugin finds the grammar and the server beside it):

```lua
{
	dir = "~/rexui/tools/editor/nvim-rui",
	name = "nvim-rui",
	lazy = false,
	dependencies = { "nvim-treesitter/nvim-treesitter" },
}
```

then `:TSInstall rui` once (it builds `tree-sitter-rui`'s checked-in `src/parser.c`; again after a
grammar change: `:TSUpdate rui`). Without nvim-treesitter, `:RuiInstallParser` builds it with `cc`
into `stdpath("data")/site/parser/`.

Options (`require("rui").setup({...})` from `config`, or `vim.g.rui = {...}` from `init`; the last
`setup` wins):

| Option | Default | |
|--------|---------|-|
| `cmd` | `{ "<checkout>/build/rui-ls" }` | the server (C++, built by `just b`); `false`: none |
| `grammar_path` | `<checkout>/tools/editor/tree-sitter-rui` | for `:TSInstall rui` |
| `indent` | `true` | nvim-treesitter's `indentexpr` in `.rui` buffers |

`queries/rui` is a link to `tools/editor/tree-sitter-rui/queries`. Their JavaScript part is
nvim-treesitter's `ecma` and `javascript` highlights (copied, not inherited, so an nvim-treesitter
update can't break them against this grammar's pinned tree-sitter-javascript).

`just editor::check` regenerates the parser, runs its corpus, parses every example, checks the
queries and runs rui-ls's tests (`just editor::ls`: every example without a diagnostic, each request over
stdio).
