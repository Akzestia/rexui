# rexui reference

rexui adds docks, drawers, styled panes and apps in panes to Rex. Everything you see is a `.rui` file: a tree of
elements written as in QML, its values JavaScript, reloaded as soon as it's saved. A folder of them is a distro, a whole
UI to switch to; programs it runs (backends) bring it data from the Mac.

| Page | |
|------|-|
| [language.md](language.md) | the `.rui` language: files and distros, members, bindings, components, models, translations, keys, drag and drop |
| [elements.md](elements.md) | every element, with its properties, signals and methods |
| [globals.md](globals.md) | what every file can read and call: `rex`, `theme`, `panes`, `notices`, `files`, ... |
| [kit.md](kit.md) | `use "rexui"`: Switch, Checkbox, RadioButton, Dropdown, Tabs, ProgressBar, Spinner, Dialog, Timeline |
| [backends.md](backends.md) | backends: the protocol and the SDKs for Swift, C/C++/Objective-C, Rust, Zig and Odin; frames in shared memory |
| [panes.md](panes.md) | widgets, web pages and native apps in panes: the pane SDK and its protocol, launcher.json |
| [embed.md](embed.md) | `rexui embed`: any app's window in a pane, games, Windows programs through CrossOver |

## A first dock

```sh
rexui new mine          # a distro in ~/.config/rex/distros/mine, from a template
rexui load mine         # shown at once
```

Save this as `~/.config/rex/distros/mine/ui/hello.rui`:

```qml
use "rexui"

Dock {
    side: "right"; width: 300; padding: 16; spacing: 12
    key: "cmd+shift+h"
    title: qsTr("Hello"); icon: "hand.wave.fill"

    property bool loud: false
    Text { text: qsTr("Hello from %1", rex.session || "rexui"); font.size: loud ? 22 : 15; animate: 200 }
    Row {
        spacing: 8
        Switch { checked: loud; onToggled: loud = checked }
        Text { text: qsTr("Louder") }
    }
    Button { text: qsTr("Split right"); onClicked: rex.run("pane.split.right") }
}
```

cmd+shift+h slides it out. Edit and save: it changes at once. `rexui check` prints a file's errors with their lines
(they're also in `~/Library/Logs/rexui.log`), and debug mode (cmd+alt+i) shows every element, its properties and
bindings, and a console that runs code in a file's scope.

## Where things go in a distro

| Path | |
|------|-|
| `ui/*.rui` | its docks (a small first letter) and components (a capital: `Card.rui`) |
| `panes/*.rui`, `panes/<name>/` | widgets and native apps shown in panes |
| `backends/<name>/BUILD.bazel` | its programs, built by Bazel (`rexui build`) |
| `rui-config.lua` | its options (rexui's and its own: `conf.values`) |
| `lang/<language>.json` | its translations (`qsTr`) |
| `fonts/`, `syntax/`, `debug/` | its fonts, its code-colouring languages, its own dev tools |
| `launcher.json` | the apps and widgets its launcher opens in panes |

`rexui list`, `rexui load <name>`, `rexui try <file|folder|distro>` (shows one for a while), `rexui default` (back to
Rex as it is), `rexui check [--perf]`, `rexui build`, `rexui pane`, `rexui embed`, `rexui launch`: `rexui --help` has
them all.
