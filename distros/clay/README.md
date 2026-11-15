# clay

A rexui distro after Anthropic's design: ivory paper and slate ink, clay for what's live; a serif to read and a sans
to work; hairlines instead of boxes; motion that settles rather than bounces. Its surfaces are drawn by Metal shaders
(the `Shader` element): paper with a grain, a spark that thinks while the Mac is busy, a map of contours that warm
under the pointer, the day's sun as a halftone print, a pomodoro that fills a vessel with ink.

```sh
rexui load clay        # shows it (a link: ln -s "$PWD/distros/clay" ~/.config/rex/distros/clay)
rexui build clay       # its backends (Bazel; rexui load builds them first)
rexui pane spark       # a widget, in the pane it's typed in: spark, daylight, focus
```

| File | Key | |
|------|-----|-|
| `ui/bar.rui` | | the bar across the top: the spark (the command palette), the session (hover or click: every session, ✕ to end one, a new one), the tabs as roman numerals (each previews its tab, live), the date and time, Claude's 5-hour limit (opens the Desk), CPU, memory, disk, the battery when there is one |
| | `cmd+shift+space` | the **Desk**, from the time (hover or click): the day and a greeting under the spark; **Claude usage** (the 5-hour and weekly limits as Claude Code last saw them); then **Today** (the month, the day's light, this Mac), **Focus** (25 minutes filling a vessel, rest draining it) and the **Colophon** (the palette, the type, the shaders) |
| | `cmd+?` | **Which key**: every key there is (clay's docks, init.lua's, Rex's menus) as a book's index, searchable |
| `ui/ask.rui` | `cmd+shift+k` | **Ask Claude**: the key (or Ask in a terminal's right-click menu) opens a window of its own: **Inline** (the answer streamed here by `claude -p`, no tools; each question goes on from the last), **New tab** or **New session** (claude with the question there; Rex goes to it); the limits along its foot |
| `ui/panes.rui` | | Rex's panes in clay's hand (rexui's `Panes`): rounded at 12 pt, a hairline round each, the focused one's edge easing to clay with a clay rule gliding out along its top; behind each terminal its own background (contours, paper, daylight, ink, spark, an image, a picture, GIF or movie of one's own, none: chosen per pane from its right-click menu, whose Media row offers the newest in ~/Downloads, ~/Pictures and ~/Movies) |
| `ui/claude.rui` | `cmd+j` | claude.ai, logged in as in Zen (its cookies; Zen's files only read) |
| `ui/docs.rui` | | Claude's docs |
| `ui/journal.rui` | `cmd+shift+j` | a page a day in the serif, saved as you pause: `journal_folder/2026-11-02.md` |
| `ui/notices.rui` | | Rex's notifications as slips at the panes' top right (`notifications = "rexui"`): a status message one line, a notification two, a glyph in its accent; a click shows its pane |
| `ui/diagnostics.rui` | `cmd+shift+,` | **Diagnostics**, instead of Rex's window (`rex_windows = "rexui"`): Rex Binary, Rex Server, Rex API (invoke a method, the calls, the server's events live), RexSync, GPU (the last two minutes, by process), and the windows of Rex's held back |
| `ui/activity.rui` | `cmd+.` | **Activity**, instead of Rex's popover (cmd+., View > Toggle Activity, the sidebar's button): every pane's program grouped as Needs you (waiting, failed), Working (its progress), Done and Quiet (folded); a row shows its pane, Mark seen clears the done ones. `clay_activity = "rex"` gives Rex's popover back |
| `ui/files.rui` | `cmd+shift+e` | **Files**, clay's own file manager (and where "show in Finder" goes: `file_manager = "rexui"`): places and volumes, back, forward, up and the path, Spotlight under the folder, a list or a grid of thumbnails, the selection previewed (what opens it, a text's start), open, rename, copy, cut, paste, new folder, Trash, undo |
| `ui/settings.rui` | `cmd+,`, the palette's key | Rex's settings, rexui's and clay's options, the config files in nvim; the command palette |
| | `cmd+shift+s`, `cmd+s` | the side group (Claude, Docs, Journal): shown or hidden; its floating app bar kept up |
| `panes/spark.rui` | | the spark, large, over drifting contours; the time |
| `panes/daylight.rui` | | the sun (or the moon) as a halftone across the pane, the time, the day gone |
| `panes/focus.rui` | | Focus in a pane |
| `panes/files.rui` | | Files in a pane: `rexui pane files` (home) or `rexui pane files .` (any folder); the same browser as the panel, `ui/FileBrowser.rui` |

## Claude in a dock, logged in

`ui/claude.rui` (claude.ai in a web dock) sets `cookies: "zen"`: as it loads, and every 30 minutes after, rexui copies
Zen's cookies into its own web views' store, so claude.ai is logged in as it is in Zen. Zen's files are only read,
from a private copy that's deleted afterwards; nothing is sent anywhere but to claude.ai, as your browser sends it.
Without Zen, nothing is copied. `cookies: "firefox"` takes Firefox's instead; without `cookies`, the dock keeps a login
of its own.

## Options (rui-config.lua)

rexui's own (README: Options), and clay's, read by the docks as `conf.values`:

| Key | Default | |
|-----|---------|-|
| `clay_scheme` | `"auto"` | `ivory`, `slate`, or `auto`: Rex's theme (a light one ivory, a dark one slate) |
| `clay_motion` | `true` | `false`: every shader still, drawn once per change (no GPU work while idle) |
| `journal_folder` | `"~/Documents/Journal"` | the Journal's pages; made with the first one written |
| `claude_folder` | `"~/.claude"` | Claude Code's config folder (`CLAUDE_CONFIG_DIR`): the Desk's usage limits are read from it (for `~/.claude`, Claude Code's own `~/.claude.json`), and Ask's `claude` (a tab, a session, an inline answer) runs with it |
| `clay_pane_background` | `"contour"` | a pane's background until one is chosen for it (its right-click menu's Background row): `contour`, `paper`, `daylight`, `ink`, `spark`, `image`, `none` |
| `clay_pane_image` | `background_gif` | the picture (a GIF plays) a pane's `image` background shows |
| `clay_pane_dim` | `0.7` | how much a picture or movie behind a pane (`image` or one of one's own) is dimmed, 0 (as it is) to 1 (gone); never the shaders (a pane's own from the right-click menu's Dim wins; its All panes sets this) |
| `clay_pane_blur` | `0` | how much that picture or movie is blurred, in pt; never the shaders (a pane's own from the right-click menu's Blur wins; its All panes sets this) |

Rex's own themes that sit well under it: `terracotta-noon` or `coastal-linen` (light), `charcoal-atelier` (dark,
its accent nearly clay).

Settings… (cmd+,) and the command palette are clay's own: `ui/settings.rui`, the main distro's panel and palette in
clay's colours and type, with a section for clay's options; `rexui-rex` (`backends/rex`, the main distro's) reads and
writes Rex's preferences and the files.

## The design system

**Colour.** Two schemes of the same roles (each file defines them as `main`'s widgets do) and the brand's accents,
the same in both.

| Role | Ivory | Slate | |
|------|-------|-------|-|
| `surface` | `#faf9f5` | `#1f1e1d` | the page |
| `container` | `#f0eee6` | `#262624` | a card on it |
| `containerHigh` | `#e8e6dc` | `#30302e` | pressed, open |
| `primary` | `#c6613f` | `#d97757` | clay as text and marks (deeper on ivory, to read) |
| `onPrimary` | `#ffffff` | `#ffffff` | on a clay fill |
| `ink` | `#141413` | `#f5f4ef` | text |
| `inkDim` | `#5e5d59` | `#c2c0b6` | secondary text |
| `outline` | `#87867f` | `#8e8c85` | tertiary text, idle marks |
| `hairline` | slate at 12% | ivory at 11% | rules and borders, 1 pt |

Accents: clay `#d97757` (what's live: today, the tab shown, a running timer), kraft `#d4a27f`, manilla `#ebdbbc`,
olive `#788c5d` (rest), sky `#6a9bcc`, fig `#c46686` (a warning: a disk over 90%), heather `#cbcadb` (night),
cactus `#bcd1ca`. One accent per thing; never two clays side by side.

**Type.** A serif to read: macOS's New York (`font.family: "serif"`), in the place of Anthropic's Tiempos, for the
greeting, the date, numbers you look at (`font.tabular: true`: a clock doesn't shift) and titles; italics for what's
idle or aside. A sans to work: SF Pro, in Styrene's place, for controls and data. Labels over a section are small
capitals: 10.5 pt semibold, `font.letterSpacing: 1.4`, upper case, in `primary`. Sizes: 64 and 34 display, 18 and 16
titles, 13 body, 12 and 11 secondary.

**Space and shape.** A 4 pt grid (8, 12, 16, 24, 28 for a panel's margin). Corners: 8 for controls, 12 to 14 for
cards, 18 to 22 for drawers; buttons are pills. Separation by space and a hairline before a filled box; cards on
the Desk are `container` with a hairline border, no shadows.

**Motion.** Material's standard curve (`easing: "standard"`), never the expressive one: 140 to 160 ms for a colour,
220 to 320 for a place, 420 to 460 for a drawer or a page. Tab slides and pane glides use the same curve
(`{ 0.2, 0, 0, 1 }`). Shaders move slowly (contours drift at 0.012, the spark turns once a minute, at that pace always: a speed that changed
with a param jumped its angle); they stir only to say something (a wave runs round the spark's rays while the Mac is
busy, claude.ai loads or an answer comes).

**Words.** Plain and warm, in sentence case: "Good evening, ada.", "One thing at a time.", "Not written yet".
Japanese in `lang/ja.json`.

## Shaders

In `ui/shaders/` (the widgets reach them as `../ui/shaders/`).

| File | params | colors |
|------|--------|--------|
| `paper.metal` | light (0 to 1), grain (0 to 1), vignette (0 to 1), the light's drift | the sheet (its alpha too), the light |
| `spark.metal` | rays (12), thinking (0 to 1), turns a minute (1), width (1) | the rays, their tips |
| `contour.metal` | lines per unit height (16), pt per hill (220), speed (0.015), line width (0.75 pt), fade toward the bottom (0 to 1) | the lines (alpha: strength), near the pointer |
| `halftone.metal` | the day's fraction (0.5 noon), pt between dots (6), the horizon (0 to 1 down, 0.8) | dots by day, by night, the horizon |
| `vessel.metal` | level (0 to 1), swirl speed (1), rim width (1 pt) | ink, ink, meniscus, rim, the empty glass |

The bar's paper is still (`running: false`: drawn once per change); the rest run only while on screen (a closed
Desk, a page slid away and a hidden dock draw nothing), at 24 to 30 frames a second except the Desk's spark.

## Backends

`backends/<name>/main.swift`, built by Bazel (`rexui build`):

- `clay-sys`: CPU, memory, disk, battery, uptime, the login name (for the greeting; never the account's full name),
  the host and macOS, once a second.
- `clay-claude [config folder]`: Claude's usage limits, read from the cache Claude Code keeps in the config folder's
  `.claude.json` (`claude_folder`, default `~/.claude`, whose file is `~/.claude.json`; `cachedUsageUtilization`, nothing
  fetched, nothing else read out), as `{"state": {"usage": {fetched, session, weekly}}}`; in, `{"ask": {"text",
  "session", "new": "tab" | "session"}}` opens claude through Rex's `rex run` / `rex session new`, and `{"inline": ...}`
  answers in Ask's window by `claude -p`; every claude it starts runs with that config folder.
- `clay-files [folders]`: the newest pictures and movies in ~/Downloads, ~/Pictures and ~/Movies (names and dates only),
  for a pane's background: `{"state": {"media": [{path, name, kind}]}}`; runs only while the context menu is open.
- `rexui-rex`: the main distro's (Settings: Rex's preferences, rui-config.lua, init.lua, the action list).
- `clay-journal [folder]`: the Journal's pages. In `{"open": "2026-11-02"}`, `{"save": {"day", "text"}}`; out
  `{"page": {"day", "text"}}` and `{"state": {"folder", "day", "words", "saved", "days"}}`. Writes only what's
  written: a page saved empty removes its file.
