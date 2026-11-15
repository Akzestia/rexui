# The kit: `use "rexui"`

rexui's own controls, written in `.rui` on the same elements and language as any file (so they're also examples of
components). Bring them in at the top of a file:

```qml
use "rexui"            // Switch { }, Dropdown { } ...
use "rexui" as Ui      // or by a name of your own: Ui.Switch { }
```

They take the theme's colours by default (`"accent"` is macOS's accent, or the first Dock's `accent`), and each is an
ordinary component: set its properties, handle its signals, and write elements inside the ones that hold them
(Dialog). The tables come from the controls' own files (`src/ui/kit/`).

## Switch

An on/off switch. `checked` is what it shows: bind it to your state and set the state in `onToggled`.

```qml
Ui.Switch { checked: wifi; onToggled: wifi = checked }
```

<!-- rx:kit Switch -->
| Property | Type | Default |
|----------|------|---------|
| `checked` | bool | `false` |
| `enabled` | bool | `true` |
| `onColor` | var | `"accent"` |
| `offColor` | var | `theme.dark ? "#4d4d4d" : "#c4c4c4"` |
| `knobColor` | var | `"#ffffff"` |

**Signals:** `toggled(checked)`.
<!-- rx:end -->

## Checkbox

A box to tick, its label beside it.

```qml
Ui.Checkbox { text: qsTr("Show hidden files"); checked: hidden; onToggled: hidden = checked }
```

<!-- rx:kit Checkbox -->
| Property | Type | Default |
|----------|------|---------|
| `text` | string | `""` |
| `checked` | bool | `false` |
| `enabled` | bool | `true` |
| `tint` | var | `"accent"` |

**Signals:** `toggled(checked)`.
<!-- rx:end -->

## RadioButton

One of several: whoever holds the choice sets `checked`.

```qml
Column {
    spacing: 4
    Ui.RadioButton { text: qsTr("Dark"); checked: scheme === "dark"; onClicked: scheme = "dark" }
    Ui.RadioButton { text: qsTr("Light"); checked: scheme === "light"; onClicked: scheme = "light" }
}
```

<!-- rx:kit RadioButton -->
| Property | Type | Default |
|----------|------|---------|
| `text` | string | `""` |
| `checked` | bool | `false` |
| `enabled` | bool | `true` |
| `tint` | var | `"accent"` |

**Signals:** `clicked()`.
<!-- rx:end -->

## Dropdown

A choice from a list, unfolding in place. `items` are strings or `{label, value}` objects; `current` is the index
shown; `picked(index, value)` says what was chosen.

```qml
Ui.Dropdown { items: [{ label: qsTr("Small"), value: 12 }, { label: qsTr("Large"), value: 16 }]
              current: size === 16 ? 1 : 0; onPicked: size = value }
```

<!-- rx:kit Dropdown -->
| Property | Type | Default |
|----------|------|---------|
| `items` | var | `[]` |
| `current` | int | `0` |
| `opened` | bool | `false` |
| `enabled` | bool | `true` |
| `fill` | var | `theme.dark ? "#1fffffff" : "#14000000"` |

**Signals:** `picked(index, value)`.
<!-- rx:end -->

## Tabs

A row of tabs with a bar under the current one, gliding as it changes. Pair it with `Pages` for the content.

```qml
Ui.Tabs { id: tabs; tabs: [qsTr("General"), qsTr("Keys")]; onSelected: page = index }
Pages { current: tabs.current; Column { /* General */ } Column { /* Keys */ } }
```

<!-- rx:kit Tabs -->
| Property | Type | Default |
|----------|------|---------|
| `tabs` | var | `[]` |
| `current` | int | `0` |
| `tint` | var | `"accent"` |

**Signals:** `selected(index)`.
<!-- rx:end -->

## ProgressBar

How far along, `value` from 0 to 1, in `tint` over `track`.

```qml
Ui.ProgressBar { value: done / total }
```

<!-- rx:kit ProgressBar -->
| Property | Type | Default |
|----------|------|---------|
| `value` | real | `0` |
| `tint` | var | `"accent"` |
| `track` | var | `theme.dark ? "#26ffffff" : "#1a000000"` |
<!-- rx:end -->

## Spinner

Something under way: an arc going round while `running`.

```qml
Ui.Spinner { running: loading; width: 22; height: 22 }
```

<!-- rx:kit Spinner -->
| Property | Type | Default |
|----------|------|---------|
| `running` | bool | `true` |
| `tint` | var | `"accent"` |
<!-- rx:end -->

## Dialog

A question over the window while `open`: a `title`, the elements written inside it, and two buttons (`acceptText`,
`rejectText`) that say `accepted` or `rejected`.

```qml
Ui.Dialog {
    open: asking; title: qsTr("Delete this file?")
    onAccepted: { files.trash([path]); asking = false }
    onRejected: asking = false
    Text { text: path; wrap: true }
}
```

<!-- rx:kit Dialog -->
| Property | Type | Default |
|----------|------|---------|
| `open` | bool | `false` |
| `title` | string | `""` |
| `acceptText` | string | `qsTr("OK")` |
| `rejectText` | string | `qsTr("Cancel")` |
| `fill` | var | `theme.background` |
| `boxWidth` | real | `380` |
| `boxHeight` | real | `200` |

**Signals:** `accepted()`, `rejected()`.
<!-- rx:end -->

## Timeline

What happens when, from the moment `running` goes true: `steps` is a list of `[ms, function]`, each run that long
after the start; `loop` starts again after the last; `finished` says it's done. An entrance staged over a second, a
demo's sequence.

```qml
Ui.Timeline {
    running: shown
    steps: [[0, () => title.opacity = 1], [350, () => body.opacity = 1], [900, () => hint.visible = true]]
}
```

<!-- rx:kit Timeline -->
| Property | Type | Default |
|----------|------|---------|
| `steps` | var | `[]` |
| `running` | bool | `false` |
| `loop` | bool | `false` |

**Signals:** `finished()`.
<!-- rx:end -->
