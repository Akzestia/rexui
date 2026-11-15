# Globals

What every `.rui` file can read and call besides its own elements. They're live: a binding that reads one follows it.
Most cost nothing until a binding reads them (a frame counter runs only while something shows it). Calls whose answer
takes time return a promise (`.then(...)`).

| Global | |
|--------|-|
| [`rex`](#rex) | Rex's tabs, sessions, actions, keys, themes; panes opened, preferences written |
| [`theme`](#theme), [`conf`](#conf), [`i18n`](#i18n) | colours, rui-config.lua's options, the language |
| [`panes`](#panes), [`pane`](#pane), [`context`](#context), [`keys`](#keys) | Rex's panes, a pane being styled, the pointer's link, the keys |
| [`shared`](#shared) | values every file sees |
| [`notices`](#notices), [`activity`](#activity), [`windows`](#windows) | Rex's notifications, its panes' program activity, its other windows |
| [`files`](#files), [`clipboard`](#clipboard), [`power`](#power) | a file manager's needs, the clipboard, battery and heat |
| [`diagnostics`](#diagnostics), [`loading`](#loading), [`debug`](#debug), `console` | Rex's server and GPU, the loading screen, the dev tools |

## rex

**Tabs and sessions.** `rex.tab` (the active tab, from 1), `rex.tabs` (how many), `rex.titles` (their titles);
`rex.session` (the session's label), `rex.sessionId`, `rex.sessions` (`[{id, label}]`, every session on the server).

| | |
|-|-|
| `rex.run(action, args)` | runs one of Rex's actions as its palette does: `rex.run("pane.split.right")`, `rex.run("client.tab.goto", { index: 2 })`, `rex.run("session.select", { session_id: id })` (`rex actions` in a terminal lists them). A Drawer whose `command` takes the action opens instead |
| `rex.closeTab(index)`, `rex.closeSession(id)` | closes a tab (from 1) or a session |
| `rex.back()` | the tab shown before, in any session |
| `rex.present(name)` | opens one of Rex's own pickers or pages: `commandPalette`, `sessionPicker`, `themePicker`, `activity`, `shortcuts`, `sessions`, `goToDirectory`, `movePaneToTab`, `switchHost`, `removeHost`, `restartServer`, `renameTab`, `renameSession`, `addHost`, `find`, `tearOff`, `themeChange`, `themeImport`, `editShortcuts`; false when there's none now |
| `rex.find(text)`, `rex.findState()` | Rex's find bar on the focused terminal with `text` in it; the bar now (`{text, count, selected, failure}`, or `null`) |
| `rex.openPane(widget, {args, cwd, direction, side, floating, focus, in})` | a new pane beside the focused one (or floating) showing a widget (the distro's `panes/<widget>.rui`, a `.rui` path, or a web address); `in: true`: over the focused pane's own terminal instead, till it ends |
| `rex.openDirectory(paths)` | Rex opens the folders as a workspace |
| `rex.dock(file, show)` | what that dock's key does (shown, switched to in its group, or hidden); with `show` true, never hidden |
| `rex.api(method, args)` | a promise of Rex's server's reply to any of its API methods (`rex api list` in a terminal) |
| `rex.block()` | the pane whose terminal last had the keyboard: `{block, session}` (what `$REX_BLOCK` and `$REX_SESSION` are in it) |
| `rex.paneData(block, key, value)` | a pane's own data, `pane.data` in a Panes file (null removes; kept across launches) |
| `rex.takePaste(on)`, `rex.paste(text, block)` | a paste into a terminal comes to the file's Dock as `onPaste(text, block, session)` instead; `paste` pastes into a terminal as one bracketed paste |
| `rex.takeLinks(on)` | a web link clicked in a terminal comes to the file's Dock as `onLink(url)` instead of the browser |
| `rex.terminal("copy" \| "paste")` | the focused terminal's own copy and paste (a context menu's items) |
| `rex.keymap()` | every binding Rex resolved: `[{keys, action, args, title, category, source, mode}]` |
| `rex.shortcuts()` | every menu item's shortcut by its title: `{"Split Right": "⌘D"}` |
| `rex.keyLayout()` | the keyboard layout's characters with ⌘, by key code (empty on a US layout) |
| `rex.modifiers()` | the keys held now: `{cmd, shift, alt, ctrl}` |
| `rex.menu(path)`, `rex.checked(path)` | chooses an item of Rex's menu bar by its titles (`["View", "Customize View", "Pane Style", "Compact"]`); the titles checked in that submenu |
| `rex.set(key, value)` | writes one of Rex's preferences (most show after a relaunch) |
| `rex.original(command)` | Rex's own window or editor for a command a Drawer takes over (`"client.diagnostics"`) |
| `rex.hosts()` | Rex's servers: `[{id, name, home, connection, version, sessions}]` |
| `rex.themes()` | `{light, dark, custom: [{id, name, appearance, colors}], palettes}`: Rex's themes and their colours |
| `rex.timeScale(n)` | Rex's animations and the docks' n times slower (`null`: their own pace) |
| `rex.setAppIcon(path)` | the Dock icon (`null`: rui-config.lua's `app_icon`; `""`: Rex's own) |
| `rex.fps` | how many frames a second Rex's main thread keeps up with, once a second (runs only while read) |

`rex.run`, `rex.api` and `rex.openPane` need Rex's Remote Control on (Rex's Settings: Server).

## theme

`theme.dark`, `theme.background`, `theme.foreground`: Rex's theme as it is now. The colour names `foreground`,
`background` and `accent` (macOS's accent, or the first Dock's `accent`) work in any colour property.

```qml
Rectangle { color: theme.dark ? "#10ffffff" : "#10000000" }
```

## conf

`conf.values`: every key rui-config.lua sets (rexui's options and the distro's own), by its name with dashes, as text:
`Number(conf.values["tab-peek-width"]) || 480`. A distro's own options are any keys of its own in its rui-config.lua.

## i18n

`i18n.language` (`en`, `ja`, ...) and `i18n.locale` (`en-GB`, `ja-JP`: rui-config.lua's `locales`, else macOS's), for
`qsTr` and dates: `now.toLocaleDateString(i18n.locale, { weekday: "long" })`.

## panes

| | |
|-|-|
| `panes.list` | every pane of the tab shown: `[{id, focused, floating, index, x, y, width, height, ...}]` (pt in the pane area, y down) |
| `panes.area` | the pane area's `{width, height}`: with `list`, a minimap of the layout |
| `panes.focused`, `panes.zoomed` | the focused pane's id; the zoomed one's |
| `panes.busy`, `panes.arriving` | Rex's pane commands in flight; a pane about to come in |
| `panes.fps` | each pane's frames a second: `{block: n}` |
| `panes.previews` | the copies of other tabs' panes drawn in tab previews |

A pane command that fails comes as a notice too.

## pane

In a `Panes` file's background and overlay, and in a widget shown in a pane: the pane it's for. See
[elements.md](elements.md#panes) for the fields (`pane.id`, `focused`, `shape`, `data`, ...) and [panes.md](panes.md)
for a widget's (`pane.id`, `pane.args`).

## context

`context.hoveredLink` (the link under the pointer in a terminal), `context.hasSelection` and `context.block` (in a
context menu: whether the terminal clicked has a selection, and its pane).

## keys

`keys.list`: every key there is, for a distro to show its own key overview: `[{key, title, kind, group, from, source}]`
(`from: "rexui"`: docks, Drawers, Shortcuts; `"init.lua"`: Rex's key bindings; `"rex"`: Rex's menu items).
`keys.pending`: Rex's half-typed key sequence (`{modes, keys: ["ctrl+x"]}`). `keys.hints`: Rex is showing its ⌘-held
tab hints.

## shared

`shared.set(key, value)` and `shared.values[key]`: values every file sees, live, in memory only (`null` removes).

## notices

Every notification and status message Rex makes (a terminal's OSC 9 or 777, a program finishing or waiting in a pane
you're not looking at, a config reload, an update), and the distro's own. Each new one also comes to every Dock's
`onNotice(notice)`.

| | |
|-|-|
| `notices.list` | newest first, the last 50: `{id, source, title, subtitle, body, tone, status, session, block, tab, progress, actions, time, to}` (`source`: `terminal`, `activity`, `notice`, `remote`, `rex`, `rexui`; `tone`: `standard`, `accent`, `success`, `warning`, `error`; `to`: who shows it, `rex` or `docks`) |
| `notices.badge`, `notices.setBadge(text)` | the Dock badge Rex sets; one of your own instead (`null`: Rex's again) |
| `notices.taking` | rui-config.lua's `notifications = "rexui"`: Rex shows none of them, the docks do |
| `notices.post({title, subtitle, body, tone, status, sound, system, rex, symbol, dismissible})` | one of the distro's own (`system: true`: a macOS notification too; `rex: true`: shown in Rex's own notice as well); its id |
| `notices.reveal(id)`, `notices.dismiss(id)`, `notices.clear()` | shows its pane; out of the list |
| `notices.play(sound)` | a macOS sound's name, a file, or `"none"` |
| `notices.delegate(fn)` | each of Rex's notices, before it shows, goes to `fn(notice)`, which returns `"rex"` (Rex shows it), `"docks"` (only the docks), `"drop"` (nobody), an object (Rex shows it changed: `{title, body, symbol, sound, glass, system}`), or nothing (as `notifications` says) |

```qml
Dock {
    Component.onCompleted: notices.delegate((n) => {
        if (n.source === "remote") return "drop"
        if (n.source === "terminal" || n.status === "done") return "docks"
    })
    onNotice: if (notice.to === "docks") toast(notice)
}
```

## activity

What every pane's program is doing (OSC 9;4 progress, agents' status reports):

| | |
|-|-|
| `activity.list` | newest first: `[{block, session, sessionLabel, tab, status, waitReason, progress, app, statusTitle, message, updatedAt, process, title, cwd, lastExit}]`; `status`: `idle`, `working`, `done`, `blocked` (waiting for you; `waitReason` `permission`, `question`, `authentication`), `error` |
| `activity.blocks` | the same by block: `activity.blocks[pane.id]` |
| `activity.urgent` | the one most in need (waiting, else failed, else working), or `null` |
| `activity.tabs` | by tab: its label, panes and most urgent status |
| `activity.markSeen(ids)` | marks those panes (or tabs) seen, as viewing them would |
| `activity.delegate(fn)` | Rex's Activity popover asked for: `fn({command})` returns `"rex"` (Rex's), `"docks"` (the Drawers whose `command` is `"client.sidebar.activity.toggle"`, and every Dock's `onActivityToggle()`), or nothing |

## windows

With rui-config.lua's `rex_windows = "rexui"`, every other window Rex would open (Diagnostics, About ...) is held back
and handed to the docks: the Drawer whose `command` names it opens (`"client.diagnostics"`, `"window:<identifier>"`),
and every Dock's `onWindow(window)` hears `{id, title, command}`.

| | |
|-|-|
| `windows.held`, `windows.clear()` | the last 20 held back: `{id, title, command, time}` |
| `windows.guarding` | `rex_windows = "rexui"` |
| `windows.delegate(fn)` | each window, before it shows: `"rex"` lets it open, `"docks"` holds it back, nothing as `rex_windows` says |
| `windows.open(id)` | Rex's own window past the guard (`"diagnostics"`) |

## files

What a file manager of the distro's own needs. With rui-config.lua's `file_manager = "rexui"`, every "show in Finder"
and folder Rex opens comes to it: the Drawer whose `command` takes `"client.files"` opens, and every Dock hears
`onReveal(paths)`. Paths may start with `~`; slow calls return a promise.

| | |
|-|-|
| `files.list(path, {hidden})` | `{path, name, parent, entries}`, folders first then by name as the Finder sorts; an entry is `{name, path, dir, package, hidden, link, size, modified, created, kind, type, uti, ext, tags, readable, writable}` |
| `files.stat(path)` | an entry, or `null` |
| `files.places()` | `{home, favourites: [{name, path, icon}], volumes: [{name, path, capacity, free, removable, internal}], trash}` |
| `files.watch(paths)` | those folders' changes come to the Dock as `onFilesChanged(path)` |
| `files.copy(paths, dest)`, `files.move(paths, dest)`, `files.trash(paths)` | `{done, failed: [{path, error}]}`; nothing is overwritten |
| `files.rename(path, name)`, `files.mkdir(parent, name)` | the new path |
| `files.undo()` | the last copy, move, rename, new folder or trash undone |
| `files.open(paths, app)`, `files.apps(path)` | opens them (with the default app, or `app`); what can open a file |
| `files.search(query, {scope, limit, content})` | Spotlight: names (and with `content`, contents) containing it |
| `files.read(path, max)` | `{text, binary}`: the start of a file, for a preview |
| `files.finder(path)`, `files.routing()` | the Finder itself for once; whether `file_manager = "rexui"` |

An Image's `source` takes `"icon:" + path` and `"thumb:" + path` for a file's icon and Quick Look thumbnail.

```qml
property var here: ({ entries: [] })
Component.onCompleted: files.list("~/Downloads").then((r) => here = r)
List { model: here.entries; delegate: Row { Image { source: "icon:" + modelData.path; width: 16; height: 16 } Text { text: modelData.name } } }
```

## clipboard

`clipboard.read()` (its text), `clipboard.write(text)`, `clipboard.clear()`, `clipboard.files()` (the paths of files
copied), `clipboard.changeCount()` (goes up with each change: nothing is told of a change, so a Timer watches it).

## power

`power.low` (Low Power Mode), `power.battery` (on battery), `power.thermal` (`nominal`, `fair`, `serious`,
`critical`), `power.saving` (rui-config.lua's `power_saving` is on and one of those calls for it). Each is told as it
changes: a file can slow its own Timers and Shaders by them (`running: !power.saving`).

## diagnostics

What Rex's Diagnostics window shows, for a dock to show instead, read every 2 s while a binding reads it:

| | |
|-|-|
| `diagnostics.binary` | the app (`name, path, bundleId, version, build, pid, cpu, memory`), the command-line tool, rexui's library |
| `diagnostics.server` | Rex's server: `{running, error, version, commit, pid, startedAt, sessions, apiRevision, config, socket, cpu, memory}` |
| `diagnostics.sync` | `{hosts, tailscale, apiRevision}` |
| `diagnostics.gpu` | `{device, utilization, renderer, tiler, memoryInUse, rex, windowServer, processes, history}` |
| `diagnostics.call(method, payload)`, `diagnostics.calls`, `clearCalls()` | a server API method called, and the last 100 calls with their outcome |
| `diagnostics.follow(on, session)`, `diagnostics.events`, `clearEvents()` | the server's events, live, while on |
| `diagnostics.refresh()`, `diagnostics.reveal(path)` | read again now; a path in the Finder |

## loading

rui-config.lua's `loading_screen = "ui/loading.rui"` covers the window from Rex UI's first frame while the distro's
docks load behind it. Every file has `loading.active`, `loading.progress` (0 to 1), `loading.ready` (the docks are
loaded and Rex has drawn), `loading.stage` (the dock loaded last), `loading.elapsed` (s), `loading.finish()` (the
loading screen plays its exit and goes; at `loading_max` s at the latest) and `loading.preview()` (shows it again, for a
look). `rexui loading` plays it without a relaunch (`--hold` keeps it in its loading state while you edit it).

## debug

The dev tools as an API, which rexui's own debug UI is built on (a distro's `debug/` folder replaces that UI):

| | |
|-|-|
| `debug.enabled`, `debug.toggle(on)` | debug mode |
| `debug.docs` | every file loaded: `[{file, path, type, side, nodes, error, devtools, pane, root}]` |
| `debug.tree(file)` | its elements in order: `[{uid, type, depth, children, id, comp, file, line, visible, shown, x, y, width, height}]` |
| `debug.inspect(file, uid)` | one element: its type, place, properties with their bindings, handlers |
| `debug.edit(file, uid, name, value)`, `debug.undo()` | sets a property from text, for a try; puts the newest edit back |
| `debug.eval(file, code)` | runs code in that file's scope: `{ok, text}` |
| `debug.complete(file, code)` | what `code` can go on with in that file's scope |
| `debug.select(file, uid)`, `debug.highlight(file, uid)`, `debug.pick(on)` | selects, outlines, or picks an element with the mouse; `debug.selected`, `debug.hovered`, `debug.picking` |
| `debug.console`, `debug.clear()` | the recent log: `[{n, t, file, level, text}]` |
| `debug.revision`, `debug.revisions[file]` | bump when a file loads, reloads or its elements change |
| `debug.perf()`, `debug.memory()` | what Rex UI and each file cost (CPU, memory, the engine's time, frames a second); what each file holds |
| `debug.options`, `debug.option(key, value)` | the debug UI's own settings, kept across launches |
| `debug.theme`, `debug.setTheme(t)` | the distro's look for the debug UI |
| `debug.spotlight(block)` | that pane picked out on screen (`""`: none) |
| `debug.openInPane(file, direction, side)`, `debug.openHere(file)`, `debug.openFloating(file, bounds)`, `debug.closePane(file)` | a .rui file in a pane beside the focused one, over the focused pane's terminal, or floating; the pane given back |

`console.log`, `console.warn` and `console.error` go to `~/Library/Logs/rexui.log` and the debug console.
