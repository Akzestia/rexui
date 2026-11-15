# main

A rexui distro in Caelestia's style: a bar across the top with the dashboard (the clock, a calendar, the media card,
the visualiser, the lyrics), a launcher for apps and widgets in panes, a side group of docks (a browser, chat, music,
web docks) and rexui's Settings. Its colours are the dashboard's scheme: Caelestia's or one of Rex's themes, picked in
the dashboard's Schemes tab.

```sh
rexui load main        # shows it
rexui build main       # its backends (Bazel; just install builds them)
```

It's under GPL-3.0 (`LICENSE`): some of it is translated from the Caelestia shell (`THIRD-PARTY.md`).

## Web docks and your browser's logins

The browser (`ui/browser.rui`) and the web docks (`discord.rui`, `github.rui`, `proton.rui`, `twitch.rui`, `x.rui`)
set `cookies: "zen"`, and some `storage: [...]`: as each loads, and every 30 minutes after, rexui copies Zen's cookies
(and those sites' local storage) into its own web views' store, so the sites are logged in as they are in Zen. Zen's
files are only read, from a private copy that's deleted afterwards; nothing is sent anywhere but to the sites
themselves, as your browser sends it. Without Zen, nothing is copied. To change it, edit those files: `cookies:
"firefox"` takes Firefox's instead, and without `cookies` and `storage` a dock keeps logins of its own.

## Chat as someone else

The chat dock (cmd+j) keeps its room, token and name on this Mac and joins again at launch. Drag its tile off the bar
onto a pane (or `rexui pane ~/.config/rex/distros/main/ui/chat.rui`) and that pane is a participant of its own: the
room and token start as the dock's, its name is its own (`guest-NNN` when empty), nothing it's given is kept, and it
leaves the room as the pane closes. Two of them are two people in the room: a way to try a room by yourself.

## Your own apps in panes

The launcher (cmd+shift+a, `ui/launcher.rui`) opens apps and widgets in the pane you're in. Its widgets are the
`.rui` files in `panes/`; its apps are yours to add, in `launcher.json` (none by default):

```json
{
  "apps": [
    { "name": "Blender", "path": "/Applications/Blender.app" },
    { "name": "Doom", "subtitle": "Freedoom", "command": ["dsda-doom", "-iwad", "~/Games/freedoom2.wad"],
      "relative": true, "symbol": "flame.fill" }
  ],
  "widgets": [{ "path": "~/notes/board.rui", "name": "Board", "symbol": "square.grid.2x2" }],
  "keys": ["ctrl+z", "ctrl+shift+z", "ctrl+r", "alt+z", "alt+shift+z", "alt+r"]
}
```

An app is a `path` (an `.app`) or a `command` (a program and its arguments); `relative` is for games that turn with
the mouse (the cursor is locked while the pointer is in the pane, and the game reads its movement); `symbol` is an SF
Symbol for one without an icon. `keys` are the chords an app in a pane gets instead of Rex (every app's, or one
app's in its own `keys`). The launcher reads the file each time it opens.

## A picture behind the panes

`background_gif` in `rui-config.lua` puts a GIF in a corner of the pane area (its black made transparent): empty by
default; give it a path (`"~/Pictures/cat.gif"`) and `background_gif_height`, `background_gif_position` (top-left,
top-right, bottom-left, bottom-right, center), `background_gif_margin` and `background_gif_opacity` place it.
