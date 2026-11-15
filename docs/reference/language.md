# The `.rui` language

A `.rui` file is a tree of elements written as in QML, its values JavaScript expressions. Each file is one dock (or a
component, or a widget in a pane), with its own ids and bindings, and it reloads as soon as it's saved.

```qml
use "rexui"

Dock {
    id: root
    side: "right"; width: 300; padding: 16; spacing: 12
    key: "cmd+shift+o"

    property int clicks: 0
    property var now: new Date()
    signal tapped(int n)

    function greet(name) { return qsTr("Hello, %1", name) }

    Timer { interval: 1000; aligned: true; onTriggered: now = new Date() }

    Text { text: now.toLocaleTimeString(i18n.locale); font.size: 24; font.tabular: true }
    Text { text: greet(rex.session || "you") }
    Button {
        text: qsTr("Clicked %1 times", clicks)
        onClicked: { clicks = clicks + 1; root.tapped(clicks) }
    }
    onTapped: console.log("tapped", n)
}
```

## Files

- **Docks.** A file whose name starts with a small letter (`clock.rui`) is loaded as a dock: in a distro, the files at
  its top and in its `ui/`. Its top element is a `Dock` (a panel), a `Panes` (styles Rex's own panes) or, for a widget
  shown in a pane, a `Dock` too ([panes.md](panes.md)).
- **Components.** A file whose name starts with a capital (`Card.rui`) is a component, never loaded by itself: the
  other files use it as an element, `Card { }`.
- **Distros.** A folder of such files is a whole UI: `rexui new mine` makes one in `~/.config/rex/distros/mine`,
  `rexui load mine` shows it at once, `rexui check` loads every file as rexui would and prints its errors. A distro's
  layout: `ui/` (its docks and components), `panes/` (widgets and native apps shown in panes), `backends/` (its programs,
  [backends.md](backends.md)), `rui-config.lua` (its options), `lang/<language>.json` (its translations), `fonts/` (its
  fonts, registered while it's shown), `syntax/` (languages for code colouring).
- **Hot reload.** A save reloads that file only (and the files using a component saved). What code and typing set
  comes back after a reload as long as its element is still in the same place (a Drawer open, a page turned, a field's
  text); bindings start fresh; a Process whose command didn't change keeps running, its `state` with it. A save that
  doesn't load keeps the last good version running, its error logged.
- Errors and `console.log` go to `~/Library/Logs/rexui.log` and the debug console; a file whose first load fails shows
  its error in its dock.

## Structure

A file is any number of `use` lines, then one top element. An element is `Type { members }`; members are separated
by newlines, `;` or `,`.

| Member | |
|--------|-|
| `id: name` | names the element for every expression in the file |
| `prop: expr` | a binding; `font.size: 14` for a grouped property (or `font { size: 14; bold: true }`) |
| `onSignal: code` | a handler; the signal's arguments are in scope (`onReleased: seek(value)`) |
| `onPropChanged: code` | runs after `prop` changes, and for its first value: `initial` is true then |
| `property var name: expr` | a property of your own (`var`, `int`, `real`, `string`, `bool`, `list` all mean the same); `readonly property` can't be assigned |
| `function name(a, b) { ... }` | a function, callable from the element's expressions (the top element's: the whole file's) |
| `signal name(a, b)` | something the element (usually a component) says: calling it, `name(1, 2)`, runs its `onName` handlers |
| `delegate: Row { ... }` | an element as a value: a template (a List's rows, a Loader's body, a Panes' background) |
| `Type { ... }` | a child |
| `Component.onCompleted: code` | runs once everything is built |
| `Component.onDestruction: code` | runs when a model or a Loader destroys it, before its children |

**Values.** A value runs to the end of the line, or on to the next when the line ends with an operator or the next
starts with one (`? : . + - * / & | = < >`). `{ ... }` as a value is a block with `return`. Strings are `'…'`, `"…"` and
`` `…${expr}…` `` (only template literals span lines). `// comments` and `/* comments */` work.

## Bindings

A property's value is a JavaScript expression, evaluated when the element is made and again whenever anything it read
changes: `text: now.toLocaleTimeString()` follows the Timer, `text: player.state.title` a backend. Changes made in one
event, timer tick or backend message are applied together, each binding running at most once and never seeing a value
that isn't final yet. Assigning to a property in a handler (`count = count + 1`) replaces its binding: it no longer
follows what it read.

A name in an expression is looked up, first match wins, in:

1. the file's ids;
2. `parent`;
3. the element's own properties;
4. in a delegate, `modelData` and `index`;
5. the file's top element's properties and functions;
6. the globals: rexui's (`theme`, `rex`, `panes`, `conf`, ... [globals.md](globals.md)) and JavaScript's.

`onXChanged` runs for a property's first value too: a handler that acts on a change checks `if (!initial)`.

```qml
property string mode: "list"
onModeChanged: if (!initial) console.log("mode is now", mode)
```

## JavaScript

Expressions are JavaScript in full: arrow functions, spread, destructuring, template literals, regular expressions,
`?.` and `??`. Statements: `let`, `const`, `var`, `if`/`else`, `for`, `for…of`, `for…in`, `while`, `do…while`,
`switch`, `return`, `break`, `continue`, `try`/`catch`. `new Date(…)`, `new Set(…)`, `new Map(…)`. Not in the
language: `this`, classes, `async`/`await` (use `.then` on rexui's promises), generators, `eval`, `throw`, getters and
setters, `import`/`export`. A file using one fails to load, naming the line.

The library: numbers, strings, arrays, `Math`, `Object.keys`/`assign`/`entries`/`fromEntries`, `JSON`, `Date` (local
time; `toLocaleDateString(i18n.locale, {...})`), `Set`, `Map`, `RegExp`, `Promise`; and rexui's own:

| | |
|-|-|
| `qsTr(text, a, b, ...)` | `text` in the docks' language (`%1`, `%2` ... are the arguments); English when there's no translation |
| `qsTrn(singular, plural, n, ...)` | `plural` unless `n` is 1, translated as `qsTr`, `%1` being `n`: `qsTrn("%1 file", "%1 files", count)` |
| `rgba(r, g, b, a)` | a colour (0 to 255, alpha 0 to 1) |
| `alpha(color, a)`, `mix(a, b, t)` | a `"#..."` colour at opacity `a`; two colours mixed, `t` from 0 (`a`) to 1 (`b`) |
| `console.log`, `.warn`, `.error` | to the log and the debug console |

A script that runs too long is stopped and logged; the file goes on working. Expressions can't reach files or the
network: the only way out of a file is a `Process` command, which you can read before running it (a WebView shows web
pages, but the file's scripts can't read them).

## Components

`Card.rui` beside a dock is `Card { }` there. `use` at the top of a file brings in a folder's components (relative to
the file, or from `/` or `~`); `as` puts them under a name of their own.

```qml
use "components"            // components/Badge.rui: Badge { }
use "~/rex-kit" as Kit      // Kit.Card { }

Dock {
    Kit.Card { title: "CPU"; Text { text: sys.state.cpu + "%" } }
    Badge { label: "new"; onDismissed: console.log("gone") }
}
```

```qml
// ~/rex-kit/Card.rui
Column {
    id: card
    property string title: ""
    signal dismissed
    padding: 12; spacing: 8; radius: 12; color: theme.dark ? "#10ffffff" : "#10000000"
    Text { text: card.title; font.bold: true }
    Slot { }                         // what a use writes inside Kit.Card { ... } goes here
}
```

- A component file's top element is any element, a Dock too. Its `property` lines, functions, signals and its top
  element's properties are what a use sets and calls; what a use writes overrides the component's own, and a use's
  handlers run after the component's.
- Each use is an instance of its own: its ids are its own, and it sees only its own file's names, not the using file's
  (give it what it needs as properties).
- The elements written inside a use go where its `Slot` is (else after its own). `Slot { name: "header" }` takes what a
  use writes as `header: Row { }`; inside a delegate, once per row, with `modelData` in scope.
- An unqualified name is looked for in the file's folder, then in each `use` without an `as`, in order.
- `use "rexui"` brings in rexui's own controls ([kit.md](kit.md)).
- Saving a component reloads every file that uses it.

## Models and delegates

A List, Grid or Stack makes one element per entry of `model` (an array, or a count) from its `delegate`, with
`modelData` (the entry) and `index` in scope. Without `modelKey` entries are matched by index; with it (a property of
each entry, or `(entry, index) => key`) an entry keeps its element and that element's state as the model moves.

```qml
List {
    model: activity.list; modelKey: "block"
    delegate: Row { spacing: 8; Text { text: modelData.title; grow: 1 } Text { text: modelData.status } }
}
```

## Translations

Text shown in a dock goes through `qsTr`: `qsTr("New Tab")` is that text in the docks' language. The translations are
`lang/<language>.json` in the distro (or `~/.config/rex/ui/lang/`), one object from the English to that language,
shared by every file and re-read when saved:

```json
{ "New Tab": "新規タブ", "%1 of %2": "%2 中 %1" }
```

`i18n.language` (`en`, `ja`) and `i18n.locale` (for dates) are bindable; a binding with `qsTr` follows a change of
language at once. Keep data in English and translate where it's shown (`text: qsTr(modelData.label)`).

## Shared state

Each file is its own context. `shared.set(key, value)` puts a value where every file sees it as
`shared.values[key]` (live; `null` removes it; in memory only): one file's Drawer open, followed by another's.

## Focus and keys

The focus is an element: a TextField, TextArea, Button, Slider, List or MouseArea. Nothing takes the keyboard from a
terminal unless asked: a click on a Button doesn't, so the bar can be pressed while you type in a pane. A click on a
text field takes it, as do `forceActiveFocus()` and `autofocus`; `releaseFocus()`, Esc or a click on a terminal gives
it back. With the focus in a dock, Tab and shift+Tab go through what can take it (`focusable`, ordered by `tabIndex`),
a ring in the accent showing where (`focusRing: false` to draw your own by `focused`).

Elements with the focus hear `keyPressed(key, mods, text)` and `keyReleased(key, mods)` (`key` without its modifiers:
`a`, `enter`, `left`, `f5`). A handler that returns `true` takes the key: nothing else hears or acts on it. Order: a
file's `Shortcut`s, then the focused element's handlers, then Rex's own key bindings.

```qml
List {
    focusable: true
    onKeyPressed: { if (key === "enter") { open(selected); return true } }
}
```

A Dock's or Drawer's `key` takes modifiers (`cmd`, `ctrl`, `alt`/`opt`, `shift`) and one key (a letter or digit,
`space`, `tab`, `return`, `esc`, arrows, `f1` to `f12`), written as `"cmd+shift+k"`; it wins over Rex's own binding of
the same keys. `keys.list` is every key there is (the docks', the Drawers', Shortcuts, Rex's bindings and menu items),
for a distro to show its own key overview.

## Selecting text

`selectable: true` on a Text: a drag selects, two clicks a word, three the line, shift extends; `selectedText` follows.
`selectionGroup: "name"` on several Texts makes them select as one, top to bottom (a log), cmd+C copying a line each.

## Drag and drop

A MouseArea or Button with `dragData` (any JSON) or `dragText`, pressed and moved, is dragged: a picture of it
follows the pointer, `dragActive` is true, `dragStarted()` and `dragEnded(accepted)` say so, Esc cancels. A MouseArea
with an `onDrop` handler, in any file, takes it when its `dropKeys` include the source's `dragKey`: `dropHovered`
while over it, `dragEntered`, `dragMoved`, `dragExited`, and `drop(data, key, x, y)` at the release. `dragText` let go
over a terminal is pasted there.

Files: a Button's `dragFile` drags files (into a terminal their paths are typed; into Finder, a copy); any element with
`dropFiles: true` takes files dragged from rexui (`onFilesDropped(paths, copy)`).

```qml
MouseArea { dragData: { id: item.id }; dragKey: "card"; Rectangle { radius: 8; color: "#2a2a30" } }
MouseArea { dropKeys: ["card"]; onDrop: move(data.id, x, y)
            Rectangle { radius: 8; color: dropHovered ? "#3a7bd5" : "#1a1a1f" } }
```

## Syntax colours

`syntax` on a TextArea, TextField or Text names a language: built in, `cpp` (`c`, `h`, `cc`, `hpp`), `rust`, `zig`,
`odin`, `lua`, `js`, `conf`; or your own, `syntax/<name>.json`, looked for beside the file, then in the distro, then in
`~/.config/rex` (one named as a built-in replaces it; saved, it's used at once). `syntaxColors` gives each kind its
colour: `comment`, `string`, `keyword`, `number`, `key`, `call`, `type`, `meta`. Every field is optional:

```json
{
    "lineComments": ["//"],
    "blockComments": [{ "open": "/*", "close": "*/", "nested": true }],
    "strings": [{ "open": "\"", "close": "\"", "escape": "\\" },
                { "open": "`", "close": "`", "multiline": true, "holeOpen": "${", "holeClose": "}" }],
    "keywords": ["fn", "let", "if", "else", "return"],
    "types": ["int", "bool"],
    "calls": ["("],
    "preprocessor": "#",
    "typeCase": true,
    "members": true
}
```

The other fields: `lineStrings` (to the end of the line), `attributes` (`#[ … ]`), `sigils` (`{"@": "call"}`),
`callAfter` (the word after `fn` is a call), `keyBefore` (a line's first word before `=` is a key), `digitSeparator`,
`bitInts` (`i32`), `bangMacros` (`name!`), `rawStrings` (`"cpp"` or `"rust"`), `longBrackets` and `longComment`
(Lua's), `regex` (`/…/` literals), `values`, `wordChars`, `assign` (`key = value` lines, as config files have).
