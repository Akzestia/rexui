# Endfield's UI language: the reference endfield is built against

Values and structure only, gathered 2026-11-03 from: fan teardowns of the game's UI (MarioLealP/endfield-design:
GAME-UI-NOTES.md from a 77-screen tour, endfield.css v1.1; ArkEndfield/endfield-ui's design docs, measured on the
official site 2026-10-08..14 plus community-sampled game colours), Harry Huang's essay on Endfield's UI, the official
site's CSS, and official screenshots (looked at, never copied). It's a terminal theme in the game's design language (the
owner's personal, non-commercial customisation of their own Rex), not a game clone; README.md's Provenance has the line.
No game artwork, fonts, logos or wordmark are in this repo: every mark here is rexui's own Path, layer or shader, and the
game's exact pictures (its marks, a loading screen capture) come only from the owner's own copies in assets/brand/.

## Registers

- **Exploration HUD**: nearly invisible. Thin white outlines, transparent panels, very little fill; faceted (octagon)
  frames for the minimap, portraits and skills (never a plain circle); tiny mono telemetry at the edges; key hints by
  every prompt. The mission tracker's name tag slides in left to right and wipes out on completion.
- **Menus and the terminal hub**: a dark ground with frosted pale tiles, big yellow angled slabs for the primary info,
  a dense badge system; a left nav list (3 pt rail; the active item filled yellow, dark text, bold).
- **Loading and title**: pale or monochrome, grain, contour lines, dot matrix, a yellow structural band.
- **DOC (light)**: administrative reports, medal albums: stark white, faint wireframe, dark left blocks per data row.

## Colour (dark)

| Role | Hex | | Role | Hex |
|---|---|---|---|---|
| ground | `#0F0F10` | | signal (structure, focus, selection, progress) | `#FFFA00` (game client samples `#FCEA00`) |
| surface | `#17181A` | | signal hot / pressed | `#FDFD1F` / `#EEEA00` |
| surface-2 | `#1E2024` | | yellow as text on light | `#6B5D00` |
| well (inputs, tracks) | `#0A0A0B` | | notice (badges, needs you, power draw) | `#FF7A1A` (`#FC6C00`) |
| line, "the steel" | `#33363C` | | confirm, online | `#7BE04B` (`#00D872`) |
| line-2 (hover edge) | `#4A4E56` | | data, numbers | `#4FA8FF` (`#2A84B4`) |
| ink / ink-2 / ink-3 / ink-4 | `#F0F0F2` / `#A8ABB2` / `#6C6F76` / `#44474D` | | alert, critical | `#FF1AAC` magenta |
| | | | danger, deficit | `#D91E36` crimson (`#F62A2A`) |
| | | | cyan (connectivity, OK) | `#00FFA2` |

DOC (light): ground `#F6F6F3`, surface `#FFFFFF`, surface-2 `#ECECE8`, well `#E2E2DD`, line `#BFC1C7`, line-2 `#8E9098`,
ink `#141519` / `#34363D` / `#55575F` / `#7E818A`; the marker deepens to `#7A6D00`, orange `#C85A00`, green `#2E7D32`,
blue `#1565C0`. Rarity: `#24BAFC`, `#904EF6`, `#FCBA00`, `#FC6C00` (a bottom edge, not an outline).

Rules: one yellow primary action per view; neutrals carry the layout; yellow is never text on light; red danger, orange
notification, green confirm, never swapped; inverse blocks for secondary emphasis; the triband (magenta, cyan, yellow,
3 pt) and the glitch strip at most once per view.

## Shape

- Radius 0. Chamfers cut the **top-right and bottom-left** corners: panels 10 (large 16), buttons 7, icon plates 6.
- Hairline 1 pt steel on most containers; 2 pt for emphasis; a 3 pt rail on an active leading edge.
- Skewed tiles (-8°) for menu lists and event cards; a yellow slab with its bottom-right corner cut (14).
- Padding: panels 24, cards 16; spacing in 4 pt steps (4 8 12 16 24 36 56 88).
- No lift, no shadows beyond zero-offset ambience; glow `0 0 9px rgba(255,250,0,.4)` on hot things only.

## Motifs

- Diamonds ◇ (available) ◆ (active), often nested in a faint larger one; checkboxes and radios are diamonds.
- Chevron runs `<<<` `>>>` (navigation; animated .25→1 opacity, 2 pt, 1.4 s cycle, 0.12 s per glyph), `》》》` promotion.
- Registration crosshairs `+` (1 pt, ~9 pt) with a tiny code label: survey marks.
- Corner brackets: 14 pt arms, 2 pt, yellow at 55%; four corners for a survey frame.
- Hatch: 45°, 2 on 5 (claimed, done, blocked, deficit). Dot matrix: 1 pt dots every ~17 pt, ink at 14%, fading at the
  edges. Contours on title bands and round viewports.
- Micro telemetry: 7 pt mono, ink-4, true values only (coordinates, versions, times), never noise.
- Numbering: `SEC.NN // TITLE` (yellow index, `//` in ink-4); pages `01 / 04`; dates `2026.10.07`.
- Ghost letters: a giant wide-caps word, outlined, behind a section (tracking -0.04em).
- Glitch echo: a display heading repeated over itself at ~18%, offset 2 pt.
- Datastrip: an 8 pt band of 3 and 1 pt bars along an edge.
- Notification square: orange, small, tilted 12°, at a menu entry's top right.
- Key hints: a tiny mono box, 1 pt border with a 2 pt bottom border (`ESC`, `TAB`, `[E]`).
- Stat values right-aligned after a pipe: `| 179`.

## Elements

- **Button**: outline by default (1 pt line-2, chamfer 7, mono 12 bold caps .1em); hover: yellow border and text, 6%
  yellow fill; pressed 12%; primary: yellow fill, dark text. In dialogs: the double-outline pill (screenshots).
- **Tabs**: mono 12 bold caps; inactive ink-3; active yellow text and a 2 pt yellow underline; or a yellow block.
- **Nav list**: rows with a 3 pt left rail; the active one filled yellow, dark bold text.
- **Toggle**: a track 2.7 × 1.35 rem; on: yellow track, dark chamfered thumb that turns 90° as it crosses (0.28 s).
- **Slider**: a 4 pt steel track, a pentagon thumb with a yellow glow.
- **Input**: a well, steel border; on focus a yellow line draws in left to right (300 ms; 200 ms out).
- **Meters**: a 6 pt track (well, steel border), yellow fill over 0.6 s; segmented: cells 2 pt apart; diagonal-slash
  pips `////////` with a MAX badge for levels.
- **Task row**: 3 pt left rail in the state's colour, a 2 pt progress line under it.
- **Inventory**: a dense square grid (1 pt steel cells, rarity as a bottom edge); the selected cell a bright yellow
  chamfered border plus a diamond; a detail drawer on the right (name in display caps, stat rows with pipe values).
- **Tooltip**: a yellow header block over a light body.
- **Split modal**: a dark top half (context), a light bottom half (choices).
- **Toast**: dark (`rgba(0,0,0,.8)`), or the yellow "!" pill seen in game.
- **Empty state**: faint diagonal pinstripes and a slashed circle Ø.
- **Settings**: long rows; hardware load as segmented bars (red high, green moderate).

## Motion

Durations 0.12, 0.28, 0.6 s; colour and opacity 200 ms, movement 300, entrances 300 and exits 200 (arrive visibly,
leave fast). Curves: snap `cubic-bezier(1, 0, 0.7, 1)`, settle `cubic-bezier(0.16, 1, 0.3, 1)`. No bounce, no lift.
Shifts of 4 pt for things tied to a trigger, 8 pt for big ones. The loader: a yellow layer sweeps across (scaleX 0→1,
0.5 s delay, 0.6 s, snap), then fades (1.4 s delay, 1 s). Entrances flicker (opacity 0 .5 0 .5 0 .5 1 at
10/11/20/21/40/41%).
