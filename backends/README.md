# Backends

rexui is the UI; backends are plugins. A backend is any program a `.rui` file runs with `Process` that speaks rexui's
protocol (2: binary frames on its stdin and stdout). rexui knows nothing about any of them: the main distro's
(`distros/main/backends/`) are built the way your own would be. This folder is what they share: the contract,
`include/rexui_proto.h` (the format) and `include/rexui_frames.h`, the SDKs (`sdk/`), and the `rexui` Bazel module (the
repo's MODULE.bazel) a distro's backends build on.

## The contract (protocol 2)

- **The hello.** A backend's first stdout line asks: `{"rexui":{"protocol":2,"features":["patch","call","credit"]}}`.
  rexui answers on its stdin with the same shape and the features it took (`"credit": 64`). Lines rexui sent before
  its answer are messages too (the SDKs keep them). From the answer on, both pipes carry frames.
- **Frames:** a 16-byte header (`u32 len | u16 type | u16 flags | u64 seq`, little endian), then the payload:
  - `STATE_PATCH` (out): the state keys that changed, typed (null, booleans, numbers, strings, any JSON). Merged into
    the element's `state` (bind to it: `text: player.state.title`); `onMessage` hears it as `{"state": {...}}`.
  - `MESSAGE` (both ways): one JSON value: `onMessage(message)` in the dock; `send(obj)` from it.
  - `CALL` / `REPLY`: a dock's `call(value)` (a promise) and the backend's answer, by seq (`REXUI_REPLY_ERROR`: a
    rejection, its reason a JSON string).
  - `CREDIT` (in): more frames the backend may send. Out of it, a backend keeps its latest state and sends one patch
    when credit comes: nothing queues while rexui's reader is behind.
  A frame that breaks the format stops the backend (rexui.log says why).
- **Exit when stdin closes.** That's how rexui stops a backend: the dock reloaded, or Rex quit.
- **stderr** goes to `~/Library/Logs/rexui.log`.
- A backend that exits is restarted (1 s, then backing off to 30 s after quick exits), and one whose program file
  changes is restarted with the new build.

Protocol 1 (state as `{"state": ...}` JSON lines) is gone (2026-11-05). A program that never says hello is a plain
program, not a backend: each of its stdout lines reaches `onMessage` (parsed, or as a string), and nothing merges into
`state` (`sh -c`, `caffeinate`, `nvim` as a Process are such).

## The SDKs

One file each, std/core only, the same API in every language, each run against the same two-process test:

| Language | File | |
|----------|------|-|
| Swift | `sdk/swift/RexuiBackend.swift` | `let rexui = RexuiBackend()`, `rexui.state([...])` / `rexui.emit(obj)`, `rexui.message(v)`, `rexui.readLine()` or `rexui.run()` with `onMessage`, `onCall` |
| C, C++, Objective-C | `sdk/c/rexui_backend.h` (with `include/rexui_proto.h`) | `rexui_begin()`, `rexui_state_json(obj, n)`, `rexui_message`, `rexui_read` / `rexui_read_for(ms)`, `rexui_on_call` + `rexui_reply` |
| Rust | `sdk/rust/rexui.rs` (`mod rexui;`) | `rexui::begin()`, `state_json`, `message`, `next(timeout)`, `on_call` |
| Zig | `sdk/zig/rexui.zig` | `rexui.begin()`, `stateJson`, `message`, `next(ms)`, `onCall` + `reply` |
| Odin | `sdk/odin/rexui.odin` (the same package) | `rexui_begin()`, `rexui_state_json`, `rexui_message`, `rexui_next(ms)`, `rexui_on_call` + `rexui_reply` |

`state_json` takes a state object as JSON text and sends only the keys whose value changed since; `state([...])`
(Swift) the same from a dictionary. A distro that depends on the `rexui` module (`bazel_dep(name = "rexui")` and a
`local_path_override` to the checkout: every distro here) takes its SDK file by label
(`srcs = ["main.swift", "@rexui//backends/sdk/swift:RexuiBackend.swift"]`; in Rust, a genrule copying
`@rexui//backends/sdk/rust:rexui.rs` to `rexui.rs` beside its `main.rs` in its `src` folder, as main's chat); one elsewhere keeps a
copy beside its source (`srcs = ["main.swift", "RexuiBackend.swift"]`).

## Frames in shared memory (optional)

For data that changes every display frame (a visualiser's bars), even a patch costs a parse and a binding per
frame. `backends/include/rexui_frames.h` (C, header only) is a wait-free triple buffer in POSIX shared memory:
the backend creates `/rexui.<pid>.<what>`, writes each frame into its back buffer and publishes it (one atomic
exchange), and announces the name once in its state (`rexui.state(["frames": "/rexui.123.bars"])`). Bound to an
element (`Visualiser { frames: vis.state.frames }`), rexui maps the region, unlinks the name, and takes the
newest frame on each display frame (one atomic exchange; a slow reader skips to the newest, nothing queues).
rexui checks the region's sizes, version and indices before using them and copies each frame out
(`rexui_frames_copy`: anything not finite made 0). A writer and a reader in two processes, 200,000 frames: none torn,
none out of order.

## Back pressure

A backend whose output waits for its dock more than a second (it sends faster than the dock takes it in) is held back
(its pipe fills, its writes wait: memory never grows) and gets one line in rexui.log, at most every 10 s.

## Where rexui finds them

A bare command name (`command: "rexui-sys"`) is looked up in the distro's own built backends first (below),
then the shown distro's, then `~/.config/rex/backends/`
(your own, outside a distro), `~/.local/bin`, Homebrew, and the system's `PATH`. A relative path
(`./my-backend`) is next to the `.rui` file. Anything else is used as given.

## In a distro, built by Bazel

A distro (`rexui new` makes one) carries its backends as source: the distro's folder is a Bazel module
(`MODULE.bazel`, and a `BUILD.bazel` at its top, empty), each backend a package `backends/<name>/` whose
`BUILD.bazel` has a binary target named as the command the `.rui` files run:

```starlark
# backends/clock/BUILD.bazel in the distro mine
load("@rules_swift//swift:swift_binary.bzl", "swift_binary")

swift_binary(name = "mine-clock", srcs = ["main.swift"])   # Process { command: "mine-clock" }
```

A distro's native apps in panes (`panes/<name>/`, beside its `.rui` widgets, on `@rexui//apps/sdk:RexPane.swift`) build the same way, beside them.

`rexui build` (and `rexui load` in a terminal, and Rex UI itself the first time it shows a distro whose
backends changed) builds `//backends/...` and `//apps/...` with `-c opt` (and the distro's `.bazelrc`: the main one's says macOS 15) and copies every `*_binary` target's file into
`~/Library/Caches/rexui/distros/<the distro's path, / as %>/bin` by its name (a script with its runfiles), only
those that changed: a running backend whose program changed restarts on it. Bazel's server goes after five idle
minutes. Rules come from the Bazel Central Registry; what the main distro uses:

| Language | Rule | |
|----------|------|-|
| Swift | `rules_swift`'s `swift_binary` | `sys`, `music`, `prefs`, `rex`, `launch`; `visualiser` with `rexui_frames.h` as its bridging header |
| Objective-C | `rules_cc`'s `objc_library` + `cc_binary(linkshared)` | `media`'s library (`alwayslink`: nothing in it calls its entry point), on `@rexui//src/web:profile` |
| shell | `rules_shell`'s `sh_binary` | `media`'s script, with the library as data |
| Rust | `rules_rust`'s `rust_binary`, crates by `crate_universe` from its Cargo.toml and Cargo.lock | `chat` (moq's crates from crates.io) |

The `rexui` module (the repo's top; a distro outside this checkout points at it with `local_path_override`,
or a `git_override`) has `@rexui//backends/include:frames` (`rexui_frames.h`) and `@rexui//src/web:profile`
(reading Zen's and Firefox's profiles). Bazel runs every action in its sandbox; a BUILD file runs no
script of its own unless it says so (a `genrule`, a `cargo_build_script`), and that runs in the sandbox too.

`just backends::install` builds the main distro's.

## The main distro's

In `distros/main/backends/<folder>`:

| Folder | Program | Used by |
|--------|---------|---------|
| `rex/` (Swift) | `rexui-rex`: Rex's preferences (`set`), `rui-config.lua` (`conf`), `init.lua`'s bindings (`bind`, `unbind`), whole files (`write`), Rex's actions (`run`, and the list), monospaced fonts | `settings.rui` |
| `sys/` (Swift) | `rexui-sys`: CPU, memory, disk, network, battery, uptime, once a second (protocol 2, on `sdk/swift`: what changed) | `clock.rui`'s dashboard |
| `prefs/` (Swift) | `rexui-prefs [name]`: a dock's settings as JSON in `~/Library/Application Support/rexui/prefs/<name>.json`; `{"set": {...}}` merges (null removes), `{"keep": {"face": path}}` copies a file in and sets the key to the copy; saved at once; another instance's change to the same name is emitted too | `clock.rui`'s Schemes tab and profile picture |
| `media/` (Objective-C) | `rexui-media`: what's playing in any app (MediaRemote, through `/usr/bin/perl`: macOS 15.4+ answers only Apple's programs) and in osu! (its log and files, read only: the beatmap, its difficulty, the place, the length, the best rank from its replays; covers from assets.ppy.sh when its files don't tell), the apps with a media session, the track's synced lyrics from LRCLIB (sends it the title, artist, album and length; cached) and the line sung now; play/pause/next/previous/seek/shuffle/repeat, picking the player shown, and muting an app (a Core Audio process tap on its processes, muteBehavior muted; kept till it's unmuted, across restarts). Writes only the keys that changed | `clock.rui`'s media card and Media tab |
| `visualiser/` (Swift) | `rexui-visualiser`: the system's audio (a Core Audio process tap), or one app's (`{"bundle": ..., "muted": [...]}` on stdin: the player the dock shows; never the apps rexui-media mutes), as 60 bars through cava's core with Caelestia's settings (half cava's windows, bars lifted; `--cava`: exactly Caelestia's), a frame per block of sound, and its tempo; `--file f [--fast]` for tuning | `clock.rui`'s Media tab |
| `music/` (Swift) | `rexui-music`: plays the audio files under `~/Music` (AVFoundation) | `music.rui` |
| `launch/` (Swift) | `rexui-launch`: what a pane can show (`~/.config/rex/launcher.json`'s apps and programs, and widgets: the `.rui` files in the shown distro's `panes/` and its `widgets`) with their icons, the recent and running ones; starts `rexui embed` (an app) or `rexui pane` (a widget) in a pane (`$REX_BLOCK`) without typing into it | `launcher.rui` |
| `chat/` (Rust) | `rexui-chat`: chat in a moq-room room (moq's crates from crates.io) | `chat.rui` |

A new one: a folder with a `BUILD.bazel` there, then `rexui build main` (or `just backends::install`).
