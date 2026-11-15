# Other people's work in rexui

rexui's license (`LICENSE`, the rexui License) covers rexui's own work. The parts below are other people's. Each stays
under its own license, and nothing in rexui's license changes that.

rexui's own files say their license in their first lines (`SPDX-License-Identifier`): the rexui License for most of
them, and MIT or GPL-3.0-only where they're marked so, with the texts in `LICENSES/`. Marked MIT: the distros but main,
the backends' contract and SDKs (`backends/README.md`, `backends/include/`, `backends/sdk/`), `apps/sdk/`,
tree-sitter-rui, nvim-rui and the template `rexui new` starts from. Marked GPL-3.0-only: the `main` distro, for the
Caelestia shell's work in it (below). Each distro has its license in its own folder.

## In this repository

| Path | What | Whose | License | Notice |
|---|---|---|---|---|
| `third_party/lua/` | Lua 5.4.7, unchanged | Lua.org, PUC-Rio | MIT | the end of `third_party/lua/lua.h` |
| `tools/editor/tree-sitter-rui/src/scanner.c` | tree-sitter-javascript's scanner, changed for `.rui` | Max Brunsfeld | MIT | `tools/editor/tree-sitter-rui/LICENSE` |
| `tools/editor/tree-sitter-rui/src/tree_sitter/` | tree-sitter's headers | Max Brunsfeld | MIT | the same |
| `tools/editor/tree-sitter-rui/src/parser.c`, `grammar.json`, `node-types.json` | generated from `grammar.js`, which extends tree-sitter-javascript's grammar | Max Brunsfeld and rexui | MIT | the same |
| `tools/editor/tree-sitter-rui/queries/highlights.scm` | nvim-treesitter's `ecma` and `javascript` highlight queries (commit a2f6944), changed, with rexui's rules for `.rui` added | the nvim-treesitter contributors | Apache-2.0 | the file's first line; the license text in `tools/editor/tree-sitter-rui/LICENSE` |
| `distros/main/backends/visualiser/main.swift` (`monstercat()`), `distros/main/ui/Palette.rui` (the schemes) | translated from the Caelestia shell (`caelestia-dots/shell`) and its CLI's schemes (`caelestia-dots/cli`; those come in turn from Catppuccin, Dracula, Gruvbox, Nord and others) | the Caelestia authors | GPL-3.0 | `distros/main/LICENSE` |
| `distros/main/backends/visualiser/main.swift` (class `Cava`) | a Swift port of cava's `cavacore.c` | Karl Stavestrand | MIT | below |
| `src/ui/elements/shader_prelude.h` (`rx_hash`, `rx_hash2`) | "Hash without Sine" | David Hoskins | MIT | below |
| `distros/main/ui/icons/deno.png` | Deno's logo, shown by the Deno dock | Deno Land Inc. | Deno's brand guidelines (deno.com/brand); a trademark, not licensed by rexui | |
| `distros/endfield/fonts/LICENSES/` | the licenses of the fonts `distros/endfield/fonts/fetch.sh` downloads | their authors | as each says | |

## Downloaded when you install

`just install` and the distros' fetch scripts download these from their own sources. They aren't part of rexui, and
you get each under its own license:

- Google Sans Flex, Rubik, Saira, Space Grotesk, Iosevka: SIL Open Font License 1.1
- HarmonyOS Sans: HarmonyOS Sans Fonts License Agreement
- Material Symbols: Apache License 2.0
- EasyList and EasyPrivacy: GPL-3.0 or CC BY-SA 3.0
- Peter Lowe's ad and tracking server list: its own terms (pgl.yoyo.org)
- uBlock Origin Lite: GPL-3.0
- The ARKNIGHTS ENDFIELD wordmark and emblem, only if you run `distros/endfield/assets/marks.sh`: downloaded from the
  game's official site (endfield.gryphline.com) and saved as it draws them; Hypergryph's and Gryphline's, and rexui
  gives you no rights in them
- Bongo Cat (the GIF in the main distro's player): StrayRogue's drawing, downloaded from the Caelestia shell's
  repository; it has no published license, and rexui gives you no rights in it
- The build's dependencies, fetched by Bazel, Cargo and npm (rules_cc, rules_swift, rules_rust, apple_support,
  rules_shell, nlohmann_json, googletest, the moq crates, tokio, serde_json, anyhow, url, tree-sitter-javascript,
  tree-sitter-cli): each under its own license

## Names

Rex and Superlogical are Superlogical's. Arknights: Endfield is Hypergryph's and Gryphline's; the `endfield` distro
follows its design language and contains none of the game's art, fonts or text. Claude is Anthropic's. Deno is Deno
Land Inc.'s. rexui isn't made, endorsed or supported by any of them.

## Notices

### cava

Copyright (c) 2015 Karl Stavestrand <karl@stavestrand.no>

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

### Hash without Sine

Copyright (c)2014 David Hoskins.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
