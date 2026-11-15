# Apps and widgets in panes

A Rex pane can show something other than its terminal: a `.rui` widget, a web page, a native app written for it, or
any app's window ([embed.md](embed.md)). It moves with the pane (splits, resizes, floating, dragging), shows in Rex's
tab previews, and when it quits (cmd+q with the pane focused, or the pane closed) the pane is a terminal again.

```sh
rexui pane calendar        # the shown distro's panes/calendar.rui (or any path to a .rui file)
rexui pane github.com      # a web page (any URL, a host, localhost:3000; `rexui pane web` for a start page)
rexui-hello                # a native app built on the pane SDK, run in the pane
rexui embed Blender        # any app's window (embed.md)
```

`rexui pane`, `rexui embed` and `rexui launch` show it in the pane they're typed in, or where their first options say:
`--split right|left|above|below` (a new pane beside the focused one), `--tab` (a new tab), `--block <id>` (over that
pane's terminal, in the background). From a file, `rex.openPane(widget, {...})` does the same ([globals.md](globals.md#rex)).
Moving the pointer onto such a pane gives it the keyboard, as a click would.

## Widgets: a .rui file in a pane

A widget is drawn by rexui like a dock, inside the pane. Its top element is a `Dock` (only its padding, colour and
alignment matter there), it reloads when saved, and its Processes find the distro's backends as its docks' do. A
distro's widgets are its `panes/*.rui` files (never loaded as docks; `rexui check` checks them with the docks).

| | |
|-|-|
| `pane.id` | its pane's block id (as in `panes.list`) |
| `pane.args` | what `rexui pane` was given after the file: `rexui pane board ~/notes` gives `["~/notes"]` |

```qml
// panes/board.rui
Dock {
    padding: 20; spacing: 10; color: theme.background
    property string folder: pane.args[0] || "~/notes"
    property var here: ({ entries: [] })
    Component.onCompleted: files.list(folder).then((r) => here = r)
    Text { text: folder; font.size: 18; font.bold: true }
    List { grow: 1; model: here.entries; delegate: Text { text: modelData.name } }
}
```

## Web pages in panes

`rexui pane <url>` shows the page in the distro's `panes/web.rui` if it has one, else rexui's own (back, forward,
reload and an address bar that also searches), with the address as `pane.args[0]`. Its WebViews are a dock's: logins
shared, cmd+l, cmd+r, cmd+[ / cmd+], zoom; a link that opens a new window opens in the pane. Each pane keeps its own page
and history across relaunches of Rex UI, until the pane's `rexui pane` ends.

## Native apps: the pane SDK

[apps/sdk/RexPane.swift](../../apps/sdk/RexPane.swift) is compiled into the app. The app draws into a window kept off
screen; rexui shows that window's layers in the pane and hands the app the pane's size, focus, appearance, the mouse
over it, and the keys while the pane has Rex's focus. Rex keeps its cmd shortcuts (except cut, copy, paste, select all,
undo, redo, and cmd+q, which quits the app as its own Quit would) and every key its keymap binds, but the chords in
`$REXUI_PANE_KEYS` (comma separated: whoever starts the app sets it). Outside Rex (no `$REX_BLOCK`) the app opens as an
ordinary window, for working on it.

```swift
import SwiftUI

struct Notes: View {
    @EnvironmentObject var pane: RexPaneState
    @State var text = ""
    var body: some View {
        TextEditor(text: $text)
            .padding()
            .opacity(pane.focused ? 1 : 0.85)
    }
}

RexPane.run(name: "notes") { Notes() }
```

| | |
|-|-|
| `RexPane.run(name:content:) -> Never` | runs a SwiftUI app in its pane (or a window outside Rex) |
| `RexPane.run(name:view:) -> Never` | the same for an AppKit view |
| `RexPaneState` | an environment object of the root view: `focused` (the pane has Rex's keyboard focus), `visible` (on screen: another tab hides it), `embedded` (in a pane, not a window) |
| `PaneLink` | the link itself, for an app that manages its own window: `PaneLink(name:window:focus:scale:)`, `stop()`, `markDrawn()`, `PaneLink.block` (the pane), `PaneLink.sizeChanged`, `PaneLink.screenChanged`, `PaneLink.quit` (cmd+q's action instead of terminating) |

A distro's apps are `panes/<name>/`, a Bazel package each beside its widgets, built with its backends by `rexui build`:

```starlark
# panes/notes/BUILD.bazel
load("@rules_swift//swift:swift_binary.bzl", "swift_binary")

swift_binary(name = "mine-notes", srcs = ["main.swift", "@rexui//apps/sdk:RexPane.swift"])
```

### The protocol

The SDK speaks it for you; an app in another language can speak it itself. JSON lines over
`~/Library/Application Support/rexui/panes.sock` (the app's pane is `$REX_BLOCK`, its session `$REX_SESSION`):

| App to rexui | |
|--------------|-|
| `{"hello": 1, "block", "session", "pid", "name", "context", "keys", "opaque", "fullscreen"}` | once connected: `context` is its window's Core Animation context id; `keys` the chords it takes from Rex; `opaque`: no clear parts; `fullscreen`: over the whole window once shown |
| `{"context": n}` | the window's context changed |
| `{"drawn": true}` | the window has drawn something (`pane.appDrawn`) |
| `{"cursor": name}` | the cursor it asked for (`arrow`, `iBeam`, `pointingHand`, `crosshair`, `resizeLeftRight`, `resizeUpDown`, `none`, ...) |
| `{"popups": [{"context", "frame": [x, y, w, h]}]}` | its other windows (menus, dialogs) to show over it, back to front |
| `{"layout": [x, top, w, h]}` | where its content is in its window, and the window's size |
| `{"fullscreen": bool}` | over the whole of Rex's window, or back into the pane |

| rexui to app | |
|--------------|-|
| `{"size": [w, h], "scale": s}` | the pane's size (pt) and backing scale |
| `{"focus": bool}`, `{"visible": bool}` | the pane has Rex's keyboard focus; it's on screen |
| `{"screen": [x, y, w, h]}` | where the pane is on screen |
| `{"appearance": "dark" \| "light"}` | Rex's appearance |
| `{"event": base64, "x", "y"}` | a CGEvent (`CGEventCreateData`) at x, y in the pane (pt from its top left), to replay in the window |
| `{"move": [dx, dy]}` | while rexui holds the cursor for the app: the mouse's own movement |
| `{"drop": [path], "x", "y"}` | files dragged from rexui let go over the pane |
| `{"quit": true}` | cmd+q in the pane: quit as the app's own Quit would |

An app that links [apps/sdk/rexpane_lane.c](../../apps/sdk/rexpane_lane.c) takes its input through a binary lane in
shared memory instead of `"event"` lines ([rexpane_lane.h](../../apps/sdk/rexpane_lane.h)).

## The launcher's list: launcher.json

A distro's `launcher.json` lists what its launcher (and `rexui launch <name>`) can open in a pane: apps, programs and
widgets.

```json
{
  "apps": [
    { "name": "Blender", "path": "/Applications/Blender.app", "keys": ["ctrl+s"] },
    { "name": "Doom", "subtitle": "Freedoom", "symbol": "flame.fill", "relative": true,
      "command": ["dsda-doom", "-iwad", "~/Games/freedoom2.wad"] }
  ],
  "widgets": [{ "path": "~/notes/board.rui", "name": "Board", "subtitle": "Notes", "symbol": "square.grid.2x2" }],
  "keys": ["ctrl+z", "ctrl+shift+z", "ctrl+r"]
}
```

An entry has a `path` (an .app) or a `command` (a program on `$PATH` and its arguments), and optionally `subtitle`,
`icon` (a PNG) or `symbol` (an SF Symbol), and `relative` ([embed.md](embed.md)). `keys`: chords an app in a pane gets
instead of Rex (the top-level ones for every app, an entry's for that one), given to it as `$REXUI_PANE_KEYS`. The
distro's `panes/*.rui` files are listed as widgets by their Dock's `title` and `icon`; `"widgets"` adds files from
anywhere.

From init.lua (`require("rexui")`), a new pane on the right unless told otherwise:

```lua
local rexui = require("rexui")
rexui.embed("Blender")                                  -- rexui embed --split right Blender
rexui.pane("calendar", { split = "below" })
rexui.launch("Doom", { tab = true })
for _, it in ipairs(rexui.launchable()) do rex.log(it.kind .. " " .. it.name) end
```
