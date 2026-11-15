# Elements

Every element a `.rui` file can use, with its properties, signals and methods. The tables come from rexui's element
schema (`src/schema/elements.rxs`), so they're exactly what the engine checks a file against; the text around them
says what each one is for. The language itself (bindings, ids, handlers, components) is in [language.md](language.md),
the globals every file has (`rex`, `theme`, `files`, ...) in [globals.md](globals.md), and the controls of
`use "rexui"` (Switch, Dropdown, ...) in [kit.md](kit.md).

<!-- rx:elements -->
[`Slot`](#slot), [`MouseArea`](#mousearea), [`Dock`](#dock), [`Panes`](#panes), [`Column`](#column), [`Row`](#row), [`Stack`](#stack), [`Item`](#item), [`Rectangle`](#rectangle), [`Text`](#text), [`Image`](#image), [`Icon`](#icon), [`TabPreview`](#tabpreview), [`Button`](#button), [`Slider`](#slider), [`Visualiser`](#visualiser), [`Canvas`](#canvas), [`Graph`](#graph), [`Shapes`](#shapes), [`PanePreview`](#panepreview), [`Video`](#video), [`Path`](#path), [`Shader`](#shader), [`Arc`](#arc), [`Process`](#process), [`Timer`](#timer), [`Shortcut`](#shortcut), [`FileDialog`](#filedialog), [`Drawer`](#drawer), [`Loader`](#loader), [`Pages`](#pages), [`Grid`](#grid), [`List`](#list), [`Scroll`](#scroll), [`TextArea`](#textarea), [`TextField`](#textfield), [`WebView`](#webview)
<!-- rx:end -->

Types in the tables: a `number` is a JavaScript number (points for sizes, milliseconds for times, unless the text says
otherwise); a `colour` is `"#rgb"`, `"#rrggbb"`, `"#aarrggbb"` (QML's order: alpha first), `rgba(r, g, b, a)` (0 to 255,
alpha 0 to 1), or a name: `white`, `black`, `red`, `green`, `blue`, `orange`, `yellow`, `pink`, `purple`, `gray`,
`accent`, `foreground`, `background`, `transparent`. *unset* means the element decides (its content's size, its
parent's alignment). Properties written `font.size` are grouped: `font.size: 14` or `font { size: 14; bold: true }`.

## Properties every element shares

### visual

Every element that's drawn has these: its size, whether it shows, how it moves and fades.

- `width`, `height`: fixed sizes; unset, the element is as big as its content (or as its parent stretches it).
  `grow: 1` takes a share of the room left along a Row or Column (`Item { grow: 1 }` is a spacer); `shrink` gives room
  up when the children don't fit (a Text in a Row shrinks by 1 by default, so it's cut short rather than pushing the
  rest out). `minWidth`, `maxWidth`, `minHeight`, `maxHeight` limit it.
- `animate` (ms): changes to its place, size and opacity glide there, on Material 3's expressive curve (a little past,
  then settling). `easing` picks another: `"standard"` (no overshoot), `"expo"`, `"rex"` (as Rex moves its tab rows),
  `"bezier x1 y1 x2 y2"` (CSS's cubic-bezier), `"spring stiffness damping"` (`"spring 300 30"`). `opacityAnimation`
  fades opacity alone; `colorAnimation` fades colour changes, and a Text's new text crossfades in.
- `appear` (`"flicker"`, `"wipe"`, `"fade"`): how it comes on screen each time it does, after `appearDelay` ms, over
  `appearDuration` ms. `disappear` is the same on the way out (it leaves the layout at once and stays drawn till it's done).
- `expanded: false` folds it away into its top or bottom edge (`expandFrom`) as a dropdown closes; it keeps its place in
  the layout unless `collapse: true`, which gives the room up too.
- `transform.x`, `transform.y`, `transform.scale`, `transform.rotation` (degrees) move what's shown after layout (hit
  testing follows), gliding with `animate`; `z` draws it over its siblings.
- `tip` and `tipKeys` (`"cmd+shift+k"`, drawn as keycaps): a tooltip once the pointer rests on it.
- `moveKey`: a shared-element move. An element arriving with a key that another one leaving had glides from where that
  one was to its own place.
- `layoutWidth`, `layoutHeight` (read only): the size layout gave it, for a binding (`width: other.layoutWidth / 2`).
- `dropFiles: true`: files dragged over it make `dropHovered` true and their release is `onFilesDropped(paths, copy)`.
- `tabIndex`: its place in Tab's order. `columnSpan`: how many of a Grid's columns it takes.
- `onPressedOutside`: runs on a press anywhere else while it's on screen (a dropdown closing itself).

```qml
Rectangle {
    width: open ? 240 : 120; height: 40; radius: 10; color: "accent"
    animate: 320; easing: "standard"
    appear: "fade"; appearDelay: index * 40
    tip: qsTr("Opens the panel"); tipKeys: "cmd+shift+o"
}
```

<!-- rx:group visual -->
| Property | Type | Default |
|----------|------|---------|
| `width` | number | unset |
| `height` | number | unset |
| `visible` | bool | `true` |
| `opacity` | number | `1` |
| `grow` | number | `0` |
| `animate` | number | `0` |
| `easing` | one of `standard`, `expo`, `rex`, `bezier …`, `spring …` | `""` |
| `colorAnimation` | number | `0` |
| `opacityAnimation` | number | `0` |
| `expanded` | bool | `true` |
| `expandFrom` | one of `top`, `bottom` | `"top"` |
| `collapse` | bool | `false` |
| `tip` | string | `""` |
| `tipKeys` | string | `""` |
| `appear` | one of `flicker`, `wipe`, `fade` | `""` |
| `appearDelay` | number | `0` |
| `appearDuration` | number | `0` |
| `dropFiles` | bool | `false` |
| `dropHovered` | bool | `false` |
| `shrink` | number | unset |
| `minWidth` | number | unset |
| `maxWidth` | number | unset |
| `minHeight` | number | unset |
| `maxHeight` | number | unset |
| `columnSpan` | number | unset |
| `layoutWidth` | number | `0` |
| `layoutHeight` | number | `0` |
| `transform.x` | number | unset |
| `transform.y` | number | unset |
| `transform.scale` | number | unset |
| `transform.rotation` | number | unset |
| `z` | number | unset |
| `disappear` | one of `flicker`, `wipe`, `fade` | unset |
| `disappearDuration` | number | unset |
| `tabIndex` | number | unset |
| `moveKey` | string | unset |
<!-- rx:end -->

### box

Containers (Column, Row, Stack, Rectangle, Grid, List, a Dock, a Drawer ...) lay out their children and can be drawn
as a box.

- `padding` (or `horizontalPadding`, `verticalPadding`), `spacing` between children.
- `halign`, `valign`: how the children sit (`left`, `center`, `right`, `stretch`; `top`, `center`, `bottom`,
  `stretch`). They align the container's children, not the container in its parent.
- `color`, `radius`, `border.color`, `border.width`; `border.dash` (`[on, off]` pt), `border.dashSpeed` (pt/s: the dashes
  march round), `border.start` and `border.end` (0 to 1: part of the border, gliding).
- `shape`: an outline instead of `radius`'s, its fill, children and border clipped to it: `"round 12"`, `"cut 10"`
  (chamfered), `"scoop 14"` (concave), `"squircle 18"`, `"square"`, one per corner (`"cut 16, round 4, cut 16, round 4"`:
  top left, top right, bottom right, bottom left), or `"svg M0 0 H1 V0.9 L0.9 1 H0 Z"` (an SVG path in units of the box).
- `gradient` (colours from one edge to the other) and `gradientAngle` (degrees, 0 going down, clockwise); `shadow.color`,
  `shadow.radius`, `shadow.x`, `shadow.y`; `backdropBlur` (pt: what's behind it blurred).
- `clips: true` cuts the children at its edges (one with a `radius` always does). `detachHidden: true` takes hidden
  children out of the drawing until they're shown (prebuilt pages cost nothing while hidden).
- `reorder: "name"` (Row, Column, Grid): the children can be dragged into another order, kept across launches.

```qml
Rectangle {
    padding: 14; spacing: 8; radius: 16; color: "#1f1f24"
    shape: "cut 14, round 6, cut 14, round 6"
    border.color: "#30ffffff"; border.width: 1
    shadow.color: "#80000000"; shadow.radius: 18; shadow.y: 6
    Text { text: "A card" }
}
```

<!-- rx:group box -->
| Property | Type | Default |
|----------|------|---------|
| `padding` | number | `0` |
| `horizontalPadding` | number | unset |
| `verticalPadding` | number | unset |
| `spacing` | number | `0` |
| `halign` | one of `left`, `center`, `right`, `stretch` | unset |
| `valign` | one of `top`, `center`, `bottom`, `stretch` | unset |
| `color` | colour | `""` |
| `radius` | number | `0` |
| `border.color` | colour | `""` |
| `border.width` | number | `0` |
| `shape` | string | `""` |
| `border.dash` | list | `[]` |
| `border.dashSpeed` | number | `0` |
| `border.start` | number | `0` |
| `border.end` | number | `1` |
| `detachHidden` | bool | `false` |
| `reorder` | string | `""` |
| `clips` | any | unset |
| `gradient` | any | unset |
| `gradientAngle` | number | unset |
| `shadow.color` | any | unset |
| `shadow.radius` | number | unset |
| `shadow.x` | number | unset |
| `shadow.y` | number | unset |
| `backdropBlur` | number | unset |

With the [visual](#visual) properties.
<!-- rx:end -->

### font

Text, Button, TextField, TextArea and Icon take these. `font.family` is a family's name (a distro's own `fonts/` folder
is registered while it's shown, so its families can be named), or macOS's own designs: `serif`, `rounded`, `mono`.
`font.width` picks a family's width (SF Pro's `compressed` to `expanded`, a variable font's `wdth`); `font.tabular`
makes every figure the same width (a clock that doesn't shift).

<!-- rx:group font -->
| Property | Type | Default |
|----------|------|---------|
| `font.size` | number | `13` |
| `font.bold` | bool | `false` |
| `font.weight` | one of `thin`, `ultralight`, `light`, `regular`, `medium`, `semibold`, `bold`, `heavy`, `black` | `""` |
| `font.family` | string | `""` |
| `font.mono` | bool | `false` |
| `font.italic` | bool | `false` |
| `font.tabular` | bool | `false` |
| `font.letterSpacing` | number | `0` |
| `font.width` | one of `compressed`, `condensed`, `standard`, `expanded` | `""` |
<!-- rx:end -->

## Docks and panes

### Dock

The top element of every dock file: a panel beside the panes (`side: "left"`, `"right"`, `"top"`, `"bottom"`) that
takes room from them, or a corner dock over them (`"top-left"`, `"bottom-right"`, ...) that takes none. `key` slides it
out and back in. Docks with the same `group` share one place and an app bar of their `icon`s; the group's first file
sets its `side`, `bar` and `animation`, and `groupKey` (on any of them) shows the group on the dock shown last. A
dock's inner edge drags to resize it (`resizable`); the size is kept across launches.

- `bar`: the group's app bar, `bottom`, `top`, `none`, or `float` (at the window's bottom centre, shown while the
  pointer is near it; `barKey` keeps it shown). `search` gives the bar a search tile (a URL the query is appended to, or
  put in place of `%s`): what's typed opens in a new web dock of the group.
- `title`, `icon` (an SF Symbol's name, or an image file: a path with a `.`), `iconColor`: its app bar tile.
  The lead dock of a group styles the whole bar: `tileShape`, `tileFill`, `tileActive`, `tileActiveInk`, `barRadius`,
  `barShape`, `barColor`, `tileRadius`, `iconInk`.
- `transition: "melt"`: shown and hidden by melting in columns instead of sliding. `iconFly: true`: a tile clicked grows
  out of the bar into the dock.
- `span: "window"`: a top or bottom bar across the whole window. `margin`: a corner dock's distance from the panes'
  corner. `reveal` (pt): a corner dock shown only while the pointer is that near it.
- `accent`: the colour rexui's own marks take (the drop indicator of a pane drag).

```qml
Dock {
    side: "right"; width: 320; padding: 16; spacing: 12
    key: "cmd+shift+m"; group: "side"; title: qsTr("Music"); icon: "music.note"

    property var now: new Date()
    Timer { interval: 1000; aligned: true; onTriggered: now = new Date() }
    Text { text: now.toLocaleTimeString(i18n.locale); font.size: 24; font.tabular: true }

    onNotice: console.log("a notification:", notice.title)
}
```

Its signals come from Rex: `notice(notice)` for every notification ([globals.md](globals.md#notices)),
`focusEdge(direction)` when Rex's pane focus can't go further that way, `link(url)` and `paste(text, block, session)`
while the file takes them (`rex.takeLinks(true)`, `rex.takePaste(true)`), `window(window)` for a window held back
(`rex_windows = "rexui"`), `activityToggle()`, `filesChanged(path)` and `reveal(paths)` (the `files` global).

<!-- rx:element Dock -->
| Property | Type | Default |
|----------|------|---------|
| `side` | one of `right`, `left`, `top`, `bottom`, `bottom-left`, `bottom-right`, `top-left`, `top-right` | `"right"` |
| `key` | string | `""` |
| `groupKey` | string | `""` |
| `animation` | number | `220` |
| `group` | string | `""` |
| `title` | string | `""` |
| `icon` | string | `""` |
| `iconColor` | colour | `""` |
| `bar` | one of `bottom`, `top`, `none`, `float` | `"bottom"` |
| `barKey` | string | `""` |
| `barColor` | colour | `""` |
| `searchKey` | string | `""` |
| `search` | string | `""` |
| `searchColor` | colour | `""` |
| `span` | one of `panes`, `window` | `"panes"` |
| `resizable` | bool | `true` |
| `tileRadius` | number | `10` |
| `iconInk` | colour | `""` |
| `barRadius` | number | `18` |
| `tileShape` | string | `""` |
| `tileFill` | string | `""` |
| `tileActive` | string | `""` |
| `tileActiveInk` | string | `""` |
| `barShape` | string | `""` |
| `accent` | colour | `""` |
| `margin` | number | `12` |
| `reveal` | number | `0` |
| `keyTitle` | string | `""` |
| `transition` | one of `slide`, `melt` | `"slide"` |
| `iconFly` | bool | `false` |

Also: the [box](#box) properties, the [visual](#visual) properties.

**Signals:** `notice(notice)`, `focusEdge(direction)`, `link(url)`, `paste(text, block, session)`, `window(window)`, `activityToggle()`, `filesChanged(path)`, `reveal(paths)` (a handler is `on` + the name: `onClicked`).
<!-- rx:end -->

### Panes

A file whose top element is `Panes` (instead of a Dock) styles Rex's own panes. Its `background` is made once per
pane behind the terminal (a see-through pane shows it) and its `overlay` over it, never taking the mouse; each is as big
as the pane plus `margin`, and follows it as it moves and resizes. In both, `pane` describes the pane drawn:

| `pane.` | |
|---------|-|
| `id` | the pane's block id |
| `focused`, `floating`, `zoomed`, `covered` | its state (`covered`: a tiled pane under a zoomed one) |
| `index`, `width`, `height`, `tabPanes` | its place among its tab's panes, its size, how many panes its tab has |
| `shape` | its outline as cut (the file's `shape`, the pane's own, a `hole`): give the overlay's border `shape: pane.shape` |
| `preview`, `key` | a copy drawn in a tab preview (a tab sliding in looks as it will) |
| `rui`, `app`, `appDrawn`, `quitting` | a .rui file or an app shown in it instead of its terminal ([panes.md](panes.md)) |
| `data` | the pane's own data, set from any file by `rex.paneData(pane.id, key, value)` (kept across launches) |
| `spotlight`, `devtools` | the pane picked out by the dev tools; a pane showing the dev tools |

`radius` rounds the panes themselves; `shape` cuts them to any outline (as a Rectangle's), gliding over `animation`;
`hole: {x, y, r}` (x and y fractions of the window, r in pt) cuts a round hole out of every pane it covers. While a
Panes file is loaded Rex's own pane border is hidden (`rexBorder: true` keeps it). Layers only: no WebView, TextArea
or working Buttons inside.

```qml
Panes {
    radius: 12
    background: Shader { source: "shaders/paper.metal"; running: false; params: [0, pane.focused ? 0.55 : 0.25] }
    overlay: Rectangle {
        radius: 12; color: "transparent"
        border.width: pane.focused ? 1.5 : 1; border.color: pane.focused ? "#d97757" : "#22faf9f5"; colorAnimation: 220
    }
}
```

<!-- rx:element Panes -->
| Property | Type | Default |
|----------|------|---------|
| `radius` | number | `-1` |
| `shape` | string | `""` |
| `animation` | number | `300` |
| `margin` | number | `0` |
| `rexBorder` | bool | `false` |
| `spotlight` | bool | `true` |
| `hole` | object | `{}` |
| `model` | list | `[]` |

Takes an element as a value: `background`, `overlay`.
<!-- rx:end -->

### Drawer

A panel that slides out of its Dock over the panes, centred under the element it's written in, its top corners
flaring into the bar. `open` (bind it, or set it), `key` toggles it, `hover: true` opens it as the pointer comes onto
that element (in a thin bar, anywhere in the bar's thickness) and closes it 0.15 s after the pointer has left the
element and the drawer. Esc or a click elsewhere closes it.

- `placement`: `"edge"` (the default: out of the dock's edge), `"center"` (a panel in the middle of the window, dragged
  by its empty parts and resized by its edges unless `movable`/`resizable` are false), `"top"` (a palette: centred, its
  top held), `"pointer"` (a menu where the last right click was), `"pane"` (centred on the focused pane), `"side"` (a
  sub-dropdown beside the Drawer it's in).
- `command`: Rex commands it takes over, so it opens instead of Rex's own window: `"client.settings"` (Settings…),
  `"client.config.open"`, `"client.diagnostics"`, `"client.sidebar.activity.toggle"`, `"context.menu"` (a right click
  in a terminal), `"client.files"`.
- `exclusive: "name"`: opening it closes every other open Drawer of that name, in any file.
- `animation` (ms) and `closeAnimation` (ms to close, when that's different); `opening: "grow"` makes an edge one grow
  out of a square under its element instead of dropping. `flare` (`round`, `cut`, `none`), `rounding`, `shape`.
- `shift`: an edge one's centre that many points right of its element (one Drawer following the pointer along a row).
- `lazy: true` (written as a literal): its elements are made the first time it opens.

```qml
Button {
    text: qsTr("Menu")
    Drawer {
        id: menu; hover: true; padding: 14; color: "#1c1c22"
        Column {
            spacing: 4
            Button { text: qsTr("Split right"); onClicked: { rex.run("pane.split.right"); menu.open = false } }
            Button { text: qsTr("Settings"); onClicked: rex.run("client.settings") }
        }
    }
}
```

<!-- rx:element Drawer -->
| Property | Type | Default |
|----------|------|---------|
| `open` | bool | `false` |
| `key` | string | `""` |
| `hover` | bool | `false` |
| `animation` | number | `500` |
| `rounding` | number | `25` |
| `placement` | one of `edge`, `center`, `top`, `pointer`, `side`, `pane` | `"edge"` |
| `command` | list | `[]` |
| `resizable` | bool | `true` |
| `movable` | bool | `true` |
| `shift` | number | `0` |
| `keyTitle` | string | `""` |
| `exclusive` | string | `""` |
| `flare` | one of `round`, `cut`, `none` | `"round"` |
| `opening` | one of `drop`, `grow` | `"drop"` |
| `closeAnimation` | number | `-1` |
| `lazy` | bool | `false` |

Also: the [box](#box) properties, the [visual](#visual) properties.

**Signals:** `opened()`, `closed()`, `commanded(name)` (a handler is `on` + the name: `onClicked`).
<!-- rx:end -->

## Layout

### Column

Stacks its children top to bottom, `spacing` apart. Its children stretch to its width unless `halign` says otherwise.

```qml
Column { spacing: 6; Text { text: "One" } Text { text: "Two" } }
```

<!-- rx:element Column -->
No properties of its own.

Also: the [box](#box) properties, the [visual](#visual) properties.
<!-- rx:end -->

### Row

Puts its children side by side, centred vertically by default. `flow: true` goes on to a new line when they don't fit
(`rowSpacing` between lines).

```qml
Row { spacing: 8; Icon { name: "bolt.fill" } Text { text: qsTr("Charging"); grow: 1 } Text { text: "82%" } }
```

<!-- rx:element Row -->
| Property | Type | Default |
|----------|------|---------|
| `flow` | any | unset |
| `rowSpacing` | number | unset |

Also: the [box](#box) properties, the [visual](#visual) properties.
<!-- rx:end -->

### Stack

Lays its children over each other (the last on top), each stretched to its size by default. With a `model` and a
`delegate` (as a List's) it makes one child per entry: pages built once and shown one at a time by `visible`.

```qml
Stack {
    Image { source: "cover.jpg"; fit: "cover" }
    Text { text: "Over the picture"; halign: "center"; valign: "bottom" }
}
```

<!-- rx:element Stack -->
| Property | Type | Default |
|----------|------|---------|
| `model` | list | `[]` |
| `modelKey` | any | unset |

Also: the [box](#box) properties, the [visual](#visual) properties.

Takes an element as a value: `delegate`.
<!-- rx:end -->

### Item

A Stack with nothing drawn: a spacer (`Item { grow: 1 }`) or a plain group of elements.

<!-- rx:element Item -->
No properties of its own.

Also: the [box](#box) properties, the [visual](#visual) properties.
<!-- rx:end -->

### Rectangle

A Stack drawn as a box: `color`, `radius`, a border, a `shape`, a gradient, a shadow (every container takes them; a
Rectangle is the usual one to write).

```qml
MouseArea { id: area; width: 120; height: 32
            Rectangle { radius: 16; color: area.hovered ? "#3a7bd5" : "#2a2a30"; colorAnimation: 150 } }
```

<!-- rx:element Rectangle -->
No properties of its own.

Also: the [box](#box) properties, the [visual](#visual) properties.
<!-- rx:end -->

### Grid

Its children, or one per `model` entry, in `columns` equal columns. `columnWidths` gives each column's width (points, or
0 to share what's left), `minColumnWidth` makes as many equal columns as fit; a child's `columnSpan` takes several.

```qml
Grid { columns: 3; spacing: 8; model: ["a", "b", "c", "d"]
       delegate: Rectangle { height: 48; radius: 8; color: "#22ffffff"; Text { text: modelData; halign: "center"; valign: "center" } } }
```

<!-- rx:element Grid -->
| Property | Type | Default |
|----------|------|---------|
| `columns` | number | `2` |
| `columnWidths` | any | unset |
| `minColumnWidth` | number | unset |
| `model` | list | `[]` |
| `modelKey` | any | unset |

Also: the [box](#box) properties, the [visual](#visual) properties.

Takes an element as a value: `delegate`.
<!-- rx:end -->

### List

A scrolling column of rows, one per `model` entry (an array, or a count), each made from `delegate` with `modelData`
and `index` in scope. `modelKey` (a property of each entry, or `(entry, index) => key`) keeps each entry's element and
its state as the model moves; without it rows go by index. `follow: true` stays at the end as it grows; `reveal: i`
scrolls row `i` into view; `fade` fades its top and bottom while there's more to scroll.

`virtualized: true` makes only the rows near the view (`rowHeight`, or measured; `overscan` pt kept past each edge):
a million rows cost what thirty do, and `window(first, count)` says which exist.

```qml
List {
    grow: 1; spacing: 2; follow: true; modelKey: "id"
    model: chat.state.messages || []
    delegate: Row { spacing: 6; Text { text: modelData.from; font.bold: true } Text { text: modelData.text; wrap: true; grow: 1 } }
}
```

<!-- rx:element List -->
| Property | Type | Default |
|----------|------|---------|
| `model` | list | `[]` |
| `modelKey` | any | unset |
| `follow` | bool | `false` |
| `maxHeight` | number | `0` |
| `reveal` | number | `-1` |
| `revealAlign` | one of `center` | `""` |
| `revealAnimation` | number | `0` |
| `fade` | number | `0` |
| `gutter` | number | `10` |
| `virtualized` | bool | `false` |
| `rowHeight` | number | `0` |
| `overscan` | number | `-1` |
| `orientation` | one of `vertical`, `horizontal` | unset |
| `contentX` | number | unset |
| `contentY` | number | unset |
| `focusable` | bool | `false` |
| `focusRing` | bool | `true` |
| `focused` | bool | `false` |

Also: the [box](#box) properties, the [visual](#visual) properties.

Takes an element as a value: `delegate`.

**Signals:** `window(first, count)`, `scrolled(x, y)`, `keyPressed(key, mods, text)`, `keyReleased(key, mods)` (a handler is `on` + the name: `onClicked`).

**Methods:** `forceActiveFocus()`, `releaseFocus()`, `scrollTo()`.
<!-- rx:end -->

### Scroll

A scrolling container of the children written in it (a List without a model): `orientation`, `contentX` and
`contentY` (set one to scroll), `scrollTo(x, y)`, `follow`, `fade`, `gutter`.

```qml
Scroll { grow: 1; fade: 0.1; Column { spacing: 8; Text { text: longText; wrap: true } } }
```

<!-- rx:element Scroll -->
| Property | Type | Default |
|----------|------|---------|
| `orientation` | one of `vertical`, `horizontal` | unset |
| `contentX` | number | unset |
| `contentY` | number | unset |
| `follow` | bool | `false` |
| `fade` | number | `0` |
| `gutter` | number | `10` |

Also: the [box](#box) properties, the [visual](#visual) properties.

**Signals:** `scrolled(x, y)` (a handler is `on` + the name: `onClicked`).

**Methods:** `scrollTo()`.
<!-- rx:end -->

### Pages

Its children side by side, each at its own size, sliding to `current` over `animation` ms; as big as the current one.
In a Drawer, the drawer glides to each page's size on the same clock (tabs in a dashboard).

```qml
Pages { current: tabs.current; Column { Text { text: "First" } } Column { Text { text: "Second" } } }
```

<!-- rx:element Pages -->
| Property | Type | Default |
|----------|------|---------|
| `current` | number | `0` |
| `animation` | number | `500` |

Also: the [box](#box) properties, the [visual](#visual) properties.
<!-- rx:end -->

### Loader

An element made after its file has loaded, in a job of its own, and only while `active`: a `delegate`, or `source`
(a component file). A large, rarely shown part of a file goes in one so the file loads fast.

```qml
Loader { active: dashboard.open; source: "Dashboard.rui"; onLoaded: console.log("made") }
```

<!-- rx:element Loader -->
| Property | Type | Default |
|----------|------|---------|
| `active` | bool | `true` |
| `source` | string | `""` |
| `ready` | bool | `false` |
| `loadNow` | bool | `false` |

Also: the [box](#box) properties, the [visual](#visual) properties.

Takes an element as a value: `delegate`.

**Signals:** `loaded()` (a handler is `on` + the name: `onClicked`).
<!-- rx:end -->

### Slot

In a component's file, where the elements written inside a use of it go. `Slot { name: "header" }` takes what a use
writes as `header: Row { }`. See [language.md](language.md#components).

<!-- rx:element Slot -->
| Property | Type | Default |
|----------|------|---------|
| `name` | string | `""` |
<!-- rx:end -->

## Content

### Text

Text, typeset by Core Text: `text`, `color` (the theme's foreground by default), the [font](#font) properties,
`wrap`, `maxLines`, `align`, `lineHeight`. `spans` instead of `text` gives styled runs
(`[{text, color, bold, italic, underline, link}]`; a click on a run with a `link` is `linkActivated(url)`).

- `selectable: true`: a drag selects, two clicks a word, three a line; `selectionGroup: "name"` makes a file's Texts
  select as one (a log).
- `syntax` and `syntaxColors`: code coloured as a TextArea's (see TextArea).
- Effects: `glow` (a colour, `glowRadius` pt), `outline` (pt of stroke, `outlineColor`), `scramble` (ms: a new text
  decodes left to right out of random characters, from `scrambleSet`).

```qml
Text { text: qsTr("%1 of %2", done, total); font.size: 15; font.weight: "semibold"; color: "accent"; maxLines: 1 }
Text { spans: [{ text: "rexui ", bold: true }, { text: "docs", link: "https://example.com" }]; onLinkActivated: web.load(url) }
```

<!-- rx:element Text -->
| Property | Type | Default |
|----------|------|---------|
| `text` | string | `""` |
| `selectable` | bool | `false` |
| `selectionGroup` | string | `""` |
| `selectedText` | string | `""` |
| `color` | colour | `""` |
| `font.underline` | any | unset |
| `font.strikeout` | any | unset |
| `lineHeight` | number | unset |
| `spans` | any | unset |
| `wrap` | bool | `false` |
| `maxLines` | number | `0` |
| `align` | one of `left`, `center`, `right` | `"left"` |
| `syntax` | string | `""` |
| `syntaxColors` | object | `{}` |
| `glow` | colour | `""` |
| `glowRadius` | number | `6` |
| `outline` | number | `0` |
| `outlineColor` | colour | `""` |
| `scramble` | number | `0` |
| `scrambleSet` | string | `""` |

Also: the [visual](#visual) properties, the [font](#font) properties.

**Signals:** `linkActivated(url)` (a handler is `on` + the name: `onClicked`).
<!-- rx:end -->

### Icon

An [SF Symbol](https://developer.apple.com/sf-symbols/) by its `name`, in `color`, sized by `font.size`.

```qml
Icon { name: "wifi"; font.size: 14; color: online ? "accent" : "gray" }
```

<!-- rx:element Icon -->
| Property | Type | Default |
|----------|------|---------|
| `name` | string | `""` |
| `color` | colour | `""` |
| `font.size` | number | `13` |
| `font.bold` | bool | `false` |

Also: the [visual](#visual) properties.
<!-- rx:end -->

### Image

A picture: `source` (a path relative to the .rui file or with `~`, an http(s) URL, `"icon:" + path` for the Finder's
icon of a file, `"thumb:" + path` for its Quick Look thumbnail), `fit` (`cover`, `contain`, `fill`), `radius`, `shape`
(`circle`, or Material 3's `cookie4` ... `cookie12`) and `spin` (ms per turn of the shape). GIFs play (`playing`,
`speed`); `blur` blurs the picture, its edges kept solid. Without a `height` it keeps the picture's aspect.

```qml
Image { source: player.state.artwork; width: 96; height: 96; shape: "cookie9"; spin: player.state.playing ? 12000 : 0 }
```

<!-- rx:element Image -->
| Property | Type | Default |
|----------|------|---------|
| `source` | string | `""` |
| `radius` | number | `0` |
| `fit` | one of `cover`, `contain`, `fill` | `"cover"` |
| `color` | colour | `""` |
| `shape` | string | `""` |
| `spin` | number | `0` |
| `playing` | bool | `true` |
| `speed` | number | `1` |
| `blur` | number | `0` |
| `status` | string | `""` |

Also: the [visual](#visual) properties.

**Signals:** `loaded()`, `failed(error)` (a handler is `on` + the name: `onClicked`).
<!-- rx:end -->

### Video

A movie: `source` (a file or a URL), `playing`, `loop`, `muted` (true by default), `rate`, `fit`, `radius`, `shape`,
`blur`. Paused while it's off screen. `status`, `position` and `duration` (s) follow it; `seek(s)` jumps.

```qml
Video { source: "loop.mp4"; fit: "cover"; radius: 12; blur: 18; opacity: 0.6 }
```

<!-- rx:element Video -->
| Property | Type | Default |
|----------|------|---------|
| `source` | string | `""` |
| `playing` | bool | `true` |
| `loop` | bool | `true` |
| `muted` | bool | `true` |
| `rate` | number | `1` |
| `fit` | one of `cover`, `contain`, `fill` | `"cover"` |
| `radius` | number | `0` |
| `shape` | string | `""` |
| `color` | colour | `""` |
| `blur` | number | `0` |
| `status` | string | `""` |
| `position` | number | `0` |
| `duration` | number | `0` |

Also: the [visual](#visual) properties.

**Signals:** `ended()`, `failed(error)` (a handler is `on` + the name: `onClicked`).

**Methods:** `seek()`.
<!-- rx:end -->

### Path

Lines and shapes of your own: `d`, an SVG path (`M L H V C Q Z`, absolute) in units of the element (0 to 1; `units:
"pt"` for points), `stroke`, `strokeWidth`, `fill`, `dash` and `dashSpeed`, `start` and `end` (trim it, gliding),
`cap`, `join`.

```qml
Path { width: 24; height: 24; d: "M0 0.3 V0 H0.3"; stroke: "accent"; strokeWidth: 1.5 }   // a corner bracket
```

<!-- rx:element Path -->
| Property | Type | Default |
|----------|------|---------|
| `d` | string | `""` |
| `units` | one of `box`, `pt` | `"box"` |
| `stroke` | colour | `""` |
| `strokeWidth` | number | `1` |
| `fill` | colour | `""` |
| `dash` | list | `[]` |
| `dashSpeed` | number | `0` |
| `start` | number | `0` |
| `end` | number | `1` |
| `cap` | one of `butt`, `round`, `square` | `"butt"` |
| `join` | one of `miter`, `round`, `bevel` | `"miter"` |

Also: the [visual](#visual) properties.
<!-- rx:end -->

### Canvas

Many marks in one element, with no element per stroke (gauges, sparklines, ticks): `draw` is a list of shapes in points
from its top left: `{shape: "rect", x, y, width, height, radius, color}`, `{shape: "line", x0, y0, x1, y1, width,
color}`, `{shape: "arc", x, y, radius, thickness, start, sweep, color, amplitude, waves, phase}` (degrees from 3
o'clock, clockwise), `{shape: "circle", x, y, radius, color, scallops, turn}`. Drawn once per change, off the main
thread. Or `frames`: a backend's shared-memory region of 16 floats a shape ([backends.md](backends.md#frames-in-shared-memory)).

```qml
Canvas { width: 120; height: 40
         draw: values.map((v, i) => ({ shape: "rect", x: i * 6, y: 40 - v * 40, width: 4, height: v * 40, radius: 2, color: "accent" })) }
```

<!-- rx:element Canvas -->
| Property | Type | Default |
|----------|------|---------|
| `draw` | list | `[]` |
| `frames` | string | `""` |

Also: the [visual](#visual) properties.
<!-- rx:end -->

### Graph

A history of values in one element: `values` (oldest first; the newest 512 drawn) or `frames` (a backend's
shared-memory series), drawn as `style` `line`, `area` or `bars` in `color`, scaled between `min` and `max` when both
are given.

```qml
Graph { height: 36; values: cpuHistory; style: "area"; color: "accent"; min: 0; max: 100 }
```

<!-- rx:element Graph -->
| Property | Type | Default |
|----------|------|---------|
| `values` | list | `[]` |
| `frames` | string | `""` |
| `style` | one of `line`, `area`, `bars` | `"line"` |
| `color` | colour | `""` |
| `min` | number | unset |
| `max` | number | unset |
| `thickness` | number | `1.5` |
| `gap` | number | `1` |

Also: the [visual](#visual) properties.
<!-- rx:end -->

### Arc

A progress ring: `value` (0 to 1, gliding) from `start` over `sweep` degrees (0 at 3 o'clock, clockwise; -90 is the
top), `thickness`, `color`, then a `gap` and the rest in `track`, with a `dot` at the end. `wavy` (with `waves`,
`waving`, `wavePeriod`) makes its line wave; `line: true` draws it straight (a wavy slider). `seekable: true` lets a
click or drag move it, reported by `moved(value)` and `released(value)`.

```qml
Arc { width: 64; height: 64; value: battery / 100; thickness: 5; color: "accent"; start: -90; wavy: true }
```

<!-- rx:element Arc -->
| Property | Type | Default |
|----------|------|---------|
| `value` | number | `0` |
| `start` | number | `-90` |
| `sweep` | number | `360` |
| `thickness` | number | `6` |
| `color` | colour | `""` |
| `track` | colour | `""` |
| `gap` | number | `8` |
| `wavy` | bool | `false` |
| `waves` | number | `8` |
| `waving` | bool | `true` |
| `wavePeriod` | number | `2000` |
| `dot` | bool | `true` |
| `line` | bool | `false` |
| `seekable` | bool | `false` |

Also: the [visual](#visual) properties.

**Signals:** `moved(value)`, `released(value)` (a handler is `on` + the name: `onClicked`).
<!-- rx:end -->

### Visualiser

A music visualiser: bars standing out of a shape in the middle. `frames` (a backend's shared-memory frames, read every
display frame with no JavaScript in between) or `values` (0 to 1 each, clockwise from 3 o'clock), `bars`, `cover` (the
shape's size), `shape`, `spin`, `gap`, `barWidth`, `color`.

```qml
Visualiser { width: 220; height: 220; frames: vis.state.frames; cover: 120; shape: "cookie9"; color: "accent" }
```

<!-- rx:element Visualiser -->
| Property | Type | Default |
|----------|------|---------|
| `values` | list | `[]` |
| `frames` | string | `""` |
| `bars` | number | `60` |
| `color` | colour | `""` |
| `shape` | string | `"circle"` |
| `cover` | number | `0` |
| `gap` | number | `12` |
| `barWidth` | number | unset |
| `spin` | number | `0` |

Also: the [visual](#visual) properties.
<!-- rx:end -->

### Shapes

A drifting background of shapes: `count` shapes (`shapes`: `circle`, `cookieN`) from `minSize` to `maxSize` pt,
drifting at `minSpeed` to `maxSpeed` pt/s and turning up to `turn` deg/s while `moving`, each a colour of `colors` at its
opacity in `opacities`. As big as it's given: put it behind a Stack's content.

```qml
Stack { Shapes { count: 12; colors: ["#d97757", "#7aa2f7"]; moving: player.state.playing } Column { /* ... */ } }
```

<!-- rx:element Shapes -->
| Property | Type | Default |
|----------|------|---------|
| `count` | number | `14` |
| `colors` | list | `[]` |
| `opacities` | list | `[]` |
| `shapes` | list | `[]` |
| `minSize` | number | `36` |
| `maxSize` | number | `124` |
| `minSpeed` | number | `4` |
| `maxSpeed` | number | `18` |
| `turn` | number | `12` |
| `moving` | bool | `true` |

Also: the [visual](#visual) properties.
<!-- rx:end -->

### Shader

A Metal fragment shader over the element's bounds, on the GPU. Its `source` (a `.metal` file, relative to the .rui file;
saved, it's compiled again within a second) or `code` defines one function:

```metal
// p: the point drawn, in pt from the element's top left (y down). Returns straight sRGB and alpha.
float4 shade(float2 p, constant Shader &u) {
    float2 uv = p / u.size;
    float n = rx_fbm(uv * 3 + u.time * 0.05);
    return float4(mix(u.colors[0].rgb, u.colors[1].rgb, n), 1);
}
```

`u` has `size` (pt), `time` (s), `mouse` and `hover` (the pointer over it, 0 to 1 eased), `scale`, `seed`, `params[16]`
and `colors[8]` (the element's `params` and `colors`), and with `frames` a backend's newest frame (`rx_frame(u, i)`),
with `image` a picture (`rx_image(u, uv)`, `rx_image_fill(u, p)`), with `feedback` the frame before (`rx_last(u, uv)`),
with `passes` the earlier passes' results (`rx_pass(u, i, uv)`: a blur, then a composite). Helpers: `rx_hash`,
`rx_noise`, `rx_gnoise`, `rx_fbm`, `rx_fill`, `rx_stroke`, `rx_circle`, `rx_box`, `rx_segment`, `rx_over`, `rx_rotate`,
`rx_grain` ([shader_prelude.h](../../src/ui/elements/shader_prelude.h) has them all).

`running: false` draws it once per change (a still backdrop costs nothing at rest); `fps` caps a running one;
`paramsAnimation` (ms) glides new `params` there. `error` is the last compile's, with its line.

```qml
Shader { source: "shaders/aurora.metal"; colors: ["#1e1e2e", "#cba6f7"]; params: [0.4]; running: shown; fps: 30; scale: 0.5 }
```

<!-- rx:element Shader -->
| Property | Type | Default |
|----------|------|---------|
| `source` | string | `""` |
| `code` | string | `""` |
| `params` | list | `[]` |
| `colors` | list | `[]` |
| `running` | bool | `true` |
| `fps` | number | `60` |
| `scale` | number | `1` |
| `radius` | number | `0` |
| `shape` | string | `""` |
| `error` | string | `""` |
| `paramsAnimation` | number | `0` |
| `frames` | string | `""` |
| `image` | string | `""` |
| `feedback` | bool | `false` |
| `passes` | list | `[]` |

Also: the [visual](#visual) properties.
<!-- rx:end -->

## Rex's tabs and panes, live

### TabPreview

One of Rex's tabs, live, drawn by rexui from Rex's server: `tab` (from 1; 0 none), `radius`, `zoom`. A new `tab`
crossfades with the one before. `interactive: true` makes it a live terminal at the element's size (keys, mouse,
selection, scrollback, links): a tab torn off into a dock. `session` (a label starting `rexui-`) shows that session's
tab instead, made with `command` in `cwd` when the server has no such session: an editor inside a panel.

```qml
TabPreview { width: 420; tab: hovered; radius: 12 }
TabPreview { session: "rexui-notes"; command: ["nvim", "~/notes.md"]; height: 360; radius: 10 }
```

<!-- rx:element TabPreview -->
| Property | Type | Default |
|----------|------|---------|
| `tab` | number | `0` |
| `radius` | number | `0` |
| `zoom` | number | `0` |
| `session` | string | `""` |
| `interactive` | bool | `false` |
| `command` | list | `[]` |
| `cwd` | string | `""` |

Also: the [visual](#visual) properties.
<!-- rx:end -->

### PanePreview

One of Rex's panes, live and nearly free (a portal of where Rex draws it): `block` (a block id from `panes.list`,
`activity` or a notice), `radius`, `fit` (`contain`, `cover`). As wide as it's given, in its pane's shape.

```qml
PanePreview { width: 280; block: activity.urgent ? activity.urgent.block : ""; radius: 10; fit: "cover" }
```

<!-- rx:element PanePreview -->
| Property | Type | Default |
|----------|------|---------|
| `block` | string | `""` |
| `radius` | number | `0` |
| `fit` | one of `cover`, `contain`, `fill` | `"contain"` |

Also: the [visual](#visual) properties.
<!-- rx:end -->

## Input

### Button

A button with `text` and/or `icon` (an SF Symbol), `style` (`plain`, `bordered`), `enabled`; `hovered` and `pressed`
follow the pointer. A Material state layer tints it while hovered or pressed (`stateColor`, `stateRadius`;
`stateLayer: false` turns it off), shaped as the Rectangle under it in its Stack. A Button never takes the keyboard from
a terminal by being clicked.

- `drag: true`: held and moved, it reports `dragged(dx, dy)` and `dropped(dx, dy)` instead of a click (a splitter).
- `cursor`: the pointer over it (`resizeLeftRight`, `resizeUpDown`, `pointer`, `move`, `crosshair`).
- `shape`: hovered and clicked only inside that outline.
- `dragFile` (a path or a list): pressed and moved, those files are dragged (into a terminal their paths are typed;
  into Finder, a copy). `dragData`/`dragText`: a drag within rexui ([language.md](language.md#drag-and-drop)).
- `recordKey()`: the next key pressed with a modifier comes as `keyRecorded(key)` instead (a shortcut picker).
- A right click is `rightClicked()`; a Drawer with `placement: "pointer"` opened then is a context menu.

```qml
Stack {
    Rectangle { radius: 10; color: "#2a2a30" }
    Button { text: qsTr("Play"); icon: "play.fill"; onClicked: player.send({ cmd: "toggle" }) }
}
```

<!-- rx:element Button -->
| Property | Type | Default |
|----------|------|---------|
| `dragFile` | string | `""` |
| `text` | string | `""` |
| `icon` | string | `""` |
| `color` | colour | `""` |
| `style` | one of `plain`, `bordered` | `""` |
| `enabled` | bool | `true` |
| `hovered` | bool | `false` |
| `pressed` | bool | `false` |
| `stateLayer` | bool | `true` |
| `stateColor` | string | `""` |
| `stateRadius` | number | `-1` |
| `drag` | bool | `false` |
| `cursor` | one of `resizeLeftRight`, `resizeUpDown`, `pointer`, `move`, `crosshair`, `arrow`, `text` | `""` |
| `shape` | string | `""` |
| `focusable` | bool | `true` |
| `focusRing` | bool | `true` |
| `focused` | bool | `false` |
| `dragData` | any | unset |
| `dragKey` | string | unset |
| `dragText` | string | unset |
| `dragActive` | bool | `false` |

Also: the [visual](#visual) properties, the [font](#font) properties.

**Signals:** `clicked()`, `doubleClicked()`, `keyRecorded(key)`, `dragged(dx, dy)`, `dropped(dx, dy)`, `rightClicked()`, `keyPressed(key, mods, text)`, `keyReleased(key, mods)`, `dragStarted()`, `dragEnded(accepted)` (a handler is `on` + the name: `onClicked`).

**Methods:** `recordKey()`, `forceActiveFocus()`, `releaseFocus()`.
<!-- rx:end -->

### MouseArea

A container that takes the pointer, with what's in it: `hovered`, `pressed`, `mouseX`/`mouseY` (`trackMouse: true` to
follow it always), `cursor`, `shape`. Any button: its signals give `button` (`left`, `right`, `middle`, `back`,
`forward`) and `mods` (`"cmd+shift"`). `moved` and `wheel` cost nothing without a handler. `focusable: true` lets a
click give it the keyboard (`keyPressed`). It's also the drop target for drags within rexui (`onDrop`, `dropKeys`).

```qml
MouseArea {
    id: card; height: 64; cursor: "pointer"
    onClicked: if (button === "right") menu.open = true; else open(item)
    onWheel: zoom = Math.max(0.5, zoom - dy / 200)
    Rectangle { radius: 12; color: card.hovered ? "#2f2f36" : "#25252a"; colorAnimation: 120 }
}
```

<!-- rx:element MouseArea -->
| Property | Type | Default |
|----------|------|---------|
| `enabled` | bool | `true` |
| `cursor` | one of `resizeLeftRight`, `resizeUpDown`, `pointer`, `move`, `crosshair`, `arrow`, `text` | `""` |
| `trackMouse` | bool | `false` |
| `hovered` | bool | `false` |
| `pressed` | bool | `false` |
| `mouseX` | number | `0` |
| `mouseY` | number | `0` |
| `focusable` | bool | `false` |
| `focusRing` | bool | `true` |
| `focused` | bool | `false` |
| `autofocus` | bool | `false` |
| `dragData` | any | unset |
| `dragKey` | string | unset |
| `dragText` | string | unset |
| `dragFile` | any | unset |
| `dragActive` | bool | `false` |
| `dropKeys` | list | `[]` |

Also: the [box](#box) properties, the [visual](#visual) properties.

**Signals:** `press(x, y, button, mods)`, `release(x, y, button, mods)`, `clicked(x, y, button, mods)`, `doubleClicked(x, y, button, mods)`, `longPressed(x, y)`, `entered()`, `exited()`, `moved(x, y)`, `dragged(dx, dy, x, y)`, `dropped(dx, dy)`, `wheel(dx, dy, mods)`, `keyPressed(key, mods, text)`, `keyReleased(key, mods)`, `dragStarted()`, `dragEnded(accepted)`, `dragEntered(data, key)`, `dragExited()`, `dragMoved(x, y)`, `drop(data, key, x, y)` (a handler is `on` + the name: `onClicked`).

**Methods:** `forceActiveFocus()`, `releaseFocus()`.
<!-- rx:end -->

### Slider

`value` between `from` and `to` (by `step`, or smoothly), `color`, `trackColor`, `knobColor`. Updates to `value` wait
while it's dragged; `moved(value)` while dragging, `released(value)` at the end. Arrows move it when it has the focus.

```qml
Slider { value: player.state.volume; onMoved: player.send({ volume: value }) }
```

<!-- rx:element Slider -->
| Property | Type | Default |
|----------|------|---------|
| `value` | number | `0` |
| `from` | number | `0` |
| `to` | number | `1` |
| `enabled` | bool | `true` |
| `step` | number | unset |
| `color` | any | unset |
| `trackColor` | any | unset |
| `knobColor` | any | unset |
| `focusable` | bool | `true` |
| `focusRing` | bool | `true` |
| `focused` | bool | `false` |

Also: the [visual](#visual) properties.

**Signals:** `moved(value)`, `released(value)`, `keyPressed(key, mods, text)`, `keyReleased(key, mods)` (a handler is `on` + the name: `onClicked`).

**Methods:** `forceActiveFocus()`, `releaseFocus()`.
<!-- rx:end -->

### TextField

One line of text: `text` (typing replaces its binding, as in QML), `placeholder`, `color`, the font, `enabled`,
`readOnly`, `secure` (bullets, never copied), `maxLength`. `accepted()` on Return, `cancelled()` on Esc. `autofocus`
takes the keyboard when its dock or Drawer shows; `arrows: true` makes ↑ and ↓ `arrow(direction)` (a field picking
from a list). `autoPairs`, `syntax` as a TextArea's. `cursorPosition`, `selectionStart`, `selectionEnd`, `select(from,
to)`, `selectAll()`, `insert(text)`.

```qml
TextField { id: q; placeholder: qsTr("Search"); autofocus: true; onAccepted: search(text); onCancelled: drawer.open = false }
```

<!-- rx:element TextField -->
| Property | Type | Default |
|----------|------|---------|
| `text` | string | `""` |
| `placeholder` | string | `""` |
| `color` | colour | `""` |
| `enabled` | bool | `true` |
| `autofocus` | bool | `false` |
| `arrows` | bool | `false` |
| `autoPairs` | bool | `false` |
| `syntax` | string | `""` |
| `syntaxColors` | object | `{}` |
| `readOnly` | any | unset |
| `secure` | any | unset |
| `maxLength` | number | unset |
| `focused` | bool | `false` |
| `cursorPosition` | number | `0` |
| `selectionStart` | number | `0` |
| `selectionEnd` | number | `0` |

Also: the [visual](#visual) properties, the [font](#font) properties.

**Signals:** `accepted()`, `cancelled()`, `arrow(direction)`, `keyPressed(key, mods, text)`, `keyReleased(key, mods)` (a handler is `on` + the name: `onClicked`).

**Methods:** `forceActiveFocus()`, `releaseFocus()`, `select()`, `selectAll()`, `insert()`.
<!-- rx:end -->

### TextArea

Several lines of text, scrolling, of any size (only what's near the view is laid out): `text`, `editable`, `wrap`,
`follow`, `append(text)` (a log). `source` reads a file into it and `save()` writes it back (`edited()`, `saved(ok)`).
`find(text, backwards)` selects the next match (`found(ok)`).

`syntax` colours code as it's typed: built in, `cpp`, `rust`, `zig`, `odin`, `lua`, `js`, `conf`; or a language of your
own, `syntax/<name>.json` beside the file or in the distro (comments, strings, keywords, types and more: see
[language.md](language.md#syntax-colours)). `syntaxColors` gives each kind its colour: `comment`, `string`, `keyword`,
`number`, `key`, `call`, `type`, `meta`.

```qml
TextArea { grow: 1; source: "~/.config/rex/init.lua"; syntax: "lua"; autoPairs: true
           syntaxColors: ({ comment: "#6c7086", string: "#a6e3a1", keyword: "#cba6f7", number: "#fab387" }) }
```

<!-- rx:element TextArea -->
| Property | Type | Default |
|----------|------|---------|
| `text` | string | `""` |
| `color` | colour | `""` |
| `font.size` | number | `13` |
| `font.bold` | bool | `false` |
| `font.weight` | string | `""` |
| `font.family` | string | `""` |
| `font.mono` | bool | `true` |
| `font.italic` | bool | `false` |
| `font.tabular` | bool | `false` |
| `font.letterSpacing` | number | `0` |
| `font.width` | string | `""` |
| `editable` | bool | `true` |
| `wrap` | bool | `true` |
| `source` | string | `""` |
| `follow` | bool | `false` |
| `syntax` | string | `""` |
| `syntaxColors` | object | `{}` |
| `autoPairs` | bool | `false` |
| `focused` | bool | `false` |
| `cursorPosition` | number | `0` |
| `selectionStart` | number | `0` |
| `selectionEnd` | number | `0` |

Also: the [visual](#visual) properties.

**Signals:** `edited()`, `saved(ok)`, `found(ok)`, `keyPressed(key, mods, text)`, `keyReleased(key, mods)` (a handler is `on` + the name: `onClicked`).

**Methods:** `forceActiveFocus()`, `releaseFocus()`, `append()`, `save()`, `select()`, `selectAll()`, `insert()`, `find()`.
<!-- rx:end -->

### Shortcut

A key of the file's own that does something (a Dock's or Drawer's `key` only shows and hides it), taken before Rex's
keymap, and listed in `keys.list` with its `keyTitle`. `enabled: false` lets the key through.

```qml
Shortcut { key: "cmd+alt+e"; keyTitle: qsTr("Files in a pane"); onActivated: rex.openPane("files") }
```

<!-- rx:element Shortcut -->
| Property | Type | Default |
|----------|------|---------|
| `key` | string | `""` |
| `keyTitle` | string | `""` |
| `enabled` | bool | `true` |

**Signals:** `activated()` (a handler is `on` + the name: `onClicked`).
<!-- rx:end -->

### FileDialog

A file picker over the window, shown by `open()`: `title`, `types` (extensions or UTType identifiers, `["public.image"]`),
`folder` (where it starts), `mode` (`open`; `folder`; `save`, with `name` the first name), `multiple`. `accepted(path)`
(or `acceptedAll(paths)`), `rejected()`.

```qml
FileDialog { id: pick; title: qsTr("A picture"); types: ["public.image"]; onAccepted: face = path }
Button { text: qsTr("Choose…"); onClicked: pick.open() }
```

<!-- rx:element FileDialog -->
| Property | Type | Default |
|----------|------|---------|
| `title` | string | `""` |
| `types` | list | `[]` |
| `folder` | string | `""` |
| `mode` | one of `open`, `save`, `folder` | unset |
| `multiple` | any | unset |
| `name` | string | unset |

**Signals:** `accepted(path)`, `acceptedAll(paths)`, `rejected()` (a handler is `on` + the name: `onClicked`).

**Methods:** `open()`.
<!-- rx:end -->

## Programs, time and the web

### Process

Runs a program. One that speaks rexui's protocol is a backend ([backends.md](backends.md)): its `state` merges what
it sends, `send(obj)` sends it a message, `call(value)` is a promise of its answer, and `message(message)` hears what
it sends. Any other program's output lines reach `message` too (parsed as JSON when they are). `command` is an array
(or a string run by `sh -c`); `running` starts and stops it; `restart` (true) starts it again after it exits (1 s, then
backing off). The only way a .rui file reaches files or the network is a Process's command, which you can read.

```qml
Process { id: sys; command: ["rexui-sys"] }
Text { text: qsTr("CPU %1%", Math.round(sys.state.cpu || 0)) }
Process { id: once; command: ["/usr/bin/say", "done"]; running: false; restart: false }
Button { text: qsTr("Say it"); onClicked: once.running = true }
```

<!-- rx:element Process -->
| Property | Type | Default |
|----------|------|---------|
| `command` | list | `[]` |
| `running` | bool | `true` |
| `restart` | bool | `true` |
| `state` | object | `{}` |

**Signals:** `message(message)`, `exited(code)` (a handler is `on` + the name: `onClicked`).

**Methods:** `send()`, `call()`.
<!-- rx:end -->

### Timer

`triggered()` every `interval` ms while `running` (once, without `repeat`). `aligned: true` fires just past each
multiple of `interval` on the wall clock: a clock showing seconds that never skips one. `start()`, `stop()`,
`restart()`.

```qml
Timer { interval: 1000; aligned: true; onTriggered: now = new Date() }
```

<!-- rx:element Timer -->
| Property | Type | Default |
|----------|------|---------|
| `interval` | number | `1000` |
| `running` | bool | `true` |
| `repeat` | bool | `true` |
| `aligned` | bool | `false` |

**Signals:** `triggered()` (a handler is `on` + the name: `onClicked`).

**Methods:** `start()`, `stop()`, `restart()`.
<!-- rx:end -->

### WebView

A web page. Its WebViews share their logins and cookies; each loads only once it's first on screen (`lazy`), and one
hidden for `suspend` seconds (300) gives its memory back, its page, history and scroll kept and restored when it's
shown. Its page and history come back after a relaunch too.

- `url`, `zoom`, `search` (where text that isn't an address goes), `css` (a style sheet for every page),
  `adblock` (true: uBlock Origin Lite), `cookies` (`"zen"`, `"firefox"` or a profile folder: that browser's cookies
  copied in, read only, when the file loads and every 30 minutes, so you're logged in as you are there) and `storage`
  (sites whose local storage comes over the same way: a login kept there, not in a cookie).
- `title`, `currentUrl`, `loading`, `canGoBack`, `canGoForward`, `favicon` and `error` follow the page;
  `back()`, `forward()`, `reload()` (with nothing loaded yet, its `url`), `stop()`, `load(text)`.
- With the keyboard in it, cmd+r reloads, cmd+[ / cmd+] go back and forward, cmd+= / cmd+- / cmd+0 zoom, and cmd+l
  is `command("address")` for an address bar of the file's own. The mouse's back and forward buttons work on it.
- A page's fullscreen fills the WebView, not the screen.

```qml
Dock {
    side: "right"; width: 520; group: "side"; title: web.title; icon: web.favicon || "safari"
    WebView { id: web; url: "https://github.com"; cookies: "firefox"; grow: 1
              onCommand: if (name === "address") editing = true }
}
```

<!-- rx:element WebView -->
| Property | Type | Default |
|----------|------|---------|
| `cookies` | string | `""` |
| `storage` | list | `[]` |
| `adblock` | bool | `true` |
| `css` | string | `""` |
| `url` | string | `""` |
| `search` | string | `""` |
| `zoom` | number | `1` |
| `lazy` | bool | `true` |
| `suspend` | number | `300` |
| `title` | string | `""` |
| `currentUrl` | string | `""` |
| `loading` | bool | `false` |
| `canGoBack` | bool | `false` |
| `canGoForward` | bool | `false` |
| `favicon` | string | `""` |
| `error` | string | `""` |

Also: the [visual](#visual) properties.

**Signals:** `loaded()`, `failed(error)`, `command(name)` (a handler is `on` + the name: `onClicked`).

**Methods:** `back()`, `forward()`, `reload()`, `stop()`, `load()`, `adblockSettings()`, `forceActiveFocus()`.
<!-- rx:end -->
