# Any app in a pane: `rexui embed`

`rexui embed <app>` shows another app's main window inside the pane it's typed in, at the pane's size. The app runs in
its own process as usual; rexui keeps its window off screen and shows its layers in the pane, and hands it the pane's
size, focus, mouse and keys, as for an app built on the pane SDK ([panes.md](panes.md)). Quit it (cmd+q with the pane
focused) or close the pane, and the pane is a terminal again.

```sh
rexui embed "osu!"                                   # an app by its name, or a path to its .app
rexui embed --split right Blender                    # in a new pane beside the focused one
rexui embed --relative dsda-doom -iwad freedoom2.wad # a game that turns with the mouse
rexui embed --crossover Steam notepad.exe            # a Windows program in a CrossOver bottle
rexui embed --library                                # the injected library's path
```

## How it works

The first run clones the app into `~/Library/Application Support/rexui/embed` (an APFS clone: instant, taking no
space; made again when the app changes) and signs the clone ad hoc, without its updater, so it can load rexui's
`librexui-embed.dylib`. The app itself is never touched. The clone's window is kept off screen, out of the Dock, the
app switcher and window managers' tiling, and the app believes itself active while its pane has the focus.

System apps can't be embedded (they can't be re-signed). A program that isn't an app (a path, or a name on `$PATH`)
runs as it is, without a copy, unless it's signed with the hardened runtime. A re-signed app loses what's tied to its
signature (iCloud, keychain groups), and an app's own online checks may see the clone as modified.

## Options

| Option | |
|--------|-|
| `--relative` | for games that turn with the mouse: the app's relative mouse mode and grab are its own, rexui locks the real cursor while the pointer is in the focused pane, and the app reads the mouse's movement |
| `--crossover <bottle> <program> [args]` | a Windows program of a CrossOver bottle: a `.lnk`, an `.exe` path (Unix or `C:\...`) or a name the bottle has (`notepad.exe`); one of CrossOver's launchers by its name starts what it starts (`rexui embed Steam`) |
| `--split right\|left\|above\|below`, `--tab`, `--block <id>` | where it shows: a new pane beside the focused one, a new tab, or over that pane's terminal in the background |
| `--library` | prints the path of `librexui-embed.dylib` |
| `{pane_w}`, `{pane_h}` in the arguments | the pane's size in pixels: `-screen-width {pane_w} -screen-height {pane_h}` |

| Environment | |
|-------------|-|
| `$REXUI_PANE_KEYS` | chords the app gets instead of Rex's keymap (comma separated: `ctrl+s,ctrl+z`) |
| `$REXUI_EMBED_EXE` | with `--crossover`: which programs' windows may be the pane's (comma separated: `Game.exe`) |
| `$REXUI_EMBED_TARGET` | a file (`{"block", "session"}`) naming the pane, read as the window is taken: for a program started by another (a game Steam launches) |
| `$REXUI_CROSSOVER` | another CrossOver app to run bottles through (copied the same way) |

## Games

The pane is the game's display: it sizes itself to the pane and follows its resizes. Without `--relative` the system
cursor is the only truth: a game's relative mode and mouse grab are refused, its mouse position is the pointer's place
in the pane, and the cursor is hidden over the pane while the game hides its own. With `--relative` (or a Windows game
that locks the cursor), the cursor is captured in the pane: the real cursor held still while it's in the focused pane,
and the game gets the mouse's own movement (rui-config.lua's `pane_raw_mouse`). **cmd+esc** lets the cursor go; a press
in the pane captures it again. `pane_fullscreen_key` (cmd+shift+f by default) puts the game over the whole window, and
the same key (or Rex's zoom key) brings it back into its pane.

## Windows programs (CrossOver)

`--crossover` runs a program through a clone of CrossOver (made as an app's is), every executable re-signed ad hoc and
without the launchers' own loader, so each program's windows are its own process's. The pane shows the first big
window any of the bottle's programs shows (Steam's updater, then its main window: one closing hands the pane to the
next). The window is kept where the pane is on screen, transparent and click-through, so its menus, dialogs and
tooltips open over the pane. A game Steam starts is Steam's child: start Steam from the pane with the game and name
the game's program:

```sh
REXUI_EMBED_EXE=Game.exe rexui embed --crossover Steam 'C:\Program Files (x86)\Steam\steam.exe' -applaunch <appid>
```

## From a file or init.lua

`rex.openPane` opens a widget; an app is opened through a backend that starts `rexui embed` with the pane's
`$REX_BLOCK` (the main distro's launcher does this, from `launcher.json`: [panes.md](panes.md#the-launchers-list-launcherjson)).
In init.lua:

```lua
local rexui = require("rexui")
rexui.embed("Blender")
rexui.embed("dsda-doom", { relative = true, args = { "-iwad", "freedoom2.wad" }, tab = true })
```
