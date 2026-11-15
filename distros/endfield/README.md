# endfield

Rex in Arknights: Endfield's interface: a HUD in parts instead of a bar, a radial wheel in the middle of the window that
the panes bend round, the game's terminal, squad, depot, missions and AIC screens rebuilt for a terminal. Everything is
drawn by rexui's own layers and shaders after the game's design language (`DESIGN-NOTES.md`: the research, values and
structure only).

## Provenance

endfield is a theme for a terminal, made for the owner's own Rex (a closed beta) and shared as one of rexui's distros:
not a game, not a clone of one, and of no commercial use. Following Endfield's design language (its palette, chamfers,
type scale, motifs, layouts and motion) is the point of it, and done freely.

Two kinds of material, kept apart:

- **rexui's own, in the repo**: every screen, mark and animation drawn by rexui's layers, Paths and shaders, composed
  after that language (the loading screen, the wheel, the HUD, the emblem). No game artwork, logo, wordmark, font,
  capture or screen is in this folder.
- **The game's own, never in the distro**: where you want the game's exact picture, it comes from your own copy, never
  redrawn: the wordmark and emblem (`assets/marks.sh`, opt-in: run it once and it saves them as the official site draws
  them, checked against the shapes it was made for; endfield draws them in its own colours on screen,
  `ui/shaders/mark.metal`, and no copy is recoloured; `endfield_logo = "game"`; without them, endfield's own emblem), a
  capture of the loading screen (`endfield_loading`), all in `assets/brand/` (gitignored); and your account's pictures (operators' portraits and art, weapons, skills, banners, rewards), downloaded by `endfield-skport` from SKPort's own image server into `assets/skport/` (gitignored). Hand-redrawing a specific game screen or artwork 1:1 isn't
  how endfield gets one: the owner's own capture is.

```sh
distros/endfield/fonts/fetch.sh     # once: the four open fonts (registered for Rex UI alone while endfield is shown)
rexui try endfield                  # a look (rexui try stop puts the last one back)
rexui load endfield                 # make it yours
```

It needs a dylib from 2026-11-03 or later (`font.width`, text glow/outline/scramble, `appear`, Drawer `shape`/`flare`,
Panes `hole`, `shared`, `rex.dock`, distro fonts).

## What's where

| Endfield screen | Here | File | Key |
|---|---|---|---|
| Exploration HUD | A rail down the window's left (not a bar): the sessions as a column of slots under the time (the tab slots' plate cut at the other corner, a three-letter code, the current one outlined; a click goes to it, the dashed + opens the sessions menu beside the rail), the emblem at its foot (the command palette; it thinks while the Mac is busy), the tabs as squad slots down it (the current one's signal block glides to it; a slot previews its tab, live, in brackets, beside the rail; an orange ◆ when panes wait for you); CPU, memory, disk as stacked segmented gauges, the battery; at its foot the time, the hour over the minutes, over the date (it opens the Terminal beside it). Tabs slide up and down, sessions sideways (`tab_slide_axis`) | `ui/bar.rui` | |
| The wheel (radial) | Endfield's emblem in the middle of the window: three triangles (Terminal, Squad, System) round the time, each taking the mouse only inside itself; one under the pointer slides out from the middle and the signal floods it from there (`shaders/wedge.metal`, gliding both ways), a place's showing its keys; the wedges fill in outward as it opens; a click flies its name into the middle and its three places (Terminal, Controls, Command; Squad, Missions, AIC; Depot, Wiki, Settings) take the wedges with their keys; the middle goes back, or opens the command palette. The panes bend round it, the hole irising open and shut; it never drags | `ui/bar.rui` (`wheel`), `ui/WheelWedge.rui`, `ui/panes.rui` (`hole`) | cmd+e |
| Terminal, Regional Development | The Terminal drawer (760 pt pages; the Overview: the Endministrator over the check-in, the operators, the AIC strip (Headhunting and Regional Development are the Account's alone: the owner found the Overview oversaturated with them); the account's cards made 1.5 s after the HUD loads, in a run of their own), your Endfield account from the Account dock's SKPort read, each card under the same head (`SecHead`: its index, the title in wide caps, a rule led in yellow), the cards wiping in one after another. Overview: 01 the Endministrator as the game's profile (the dark part: the portrait framed in white with a corner bracket and the orange diamond, the name, Awakening Day, the UID, Authority and Exploration Level on yellow-marked rows, the main mission as a chapter card on moving contours; the pale part to its right: Operators, Weapons, Files as tiles, achievements, the pass as slash pips drawn in); 02 this month's check-in (each day's reward, claimed days solid, today framed, today's reward); 03 the operators, the roster's first eight as squad cards (`OperatorCard`, flickering on in turn); the AIC strip. Operation: the sanity dial (counting up between reads), a point every, the next one, full at; the day's activity and the pass; the missions. Archive: what endfield is made of. Rarity as the game colours and marks it: 6★ orange, 5★ gold, 4★ violet, 3★ blue, each star the game's mark, a triangle cut by a Y of gaps into three bent pieces (`Stars`: white on the night, dark on the pale panel; the rarity's colour is the bottom edge and the glow); potential as the game's X, four blades and a centre filled one a level (`Potential`) | `ui/bar.rui` (`terminal`), `ui/components/` | cmd+shift+space, or hover the time |
| Loading screen | Over the whole window at launch: drifting contours and a dot matrix on the night ground, the mark (`endfield_logo`), the structural band edge to edge filling yellow as the docks load (the count in its slab, a marching diamond at its end), the docks coming in as a log, a tip from endfield's keys; the content fades and the ground lifts off Rex. Settings > endfield previews it, as does `rexui loading` (`--hold` keeps it loading till `rexui loading stop`) | `ui/loading.rui` | `loading_screen` |
| Loading | The boot: once per load (as the loading screen lifts) a yellow rule wipes along the HUD, its parts flicker on, the time decodes | `ui/bar.rui` | `endfield_boot` |
| Controls and key hints | Controls: every key there is, as keycaps under each group | `ui/bar.rui` (`controls`) | cmd+shift+? |
| Settings | Settings and the command palette restyled: the cut panel, the selected section a signal block, ON/OFF pills, square chips, a SEC heading per page; the endfield section | `ui/settings.rui` + `backends/rex` | cmd+, |
| Interaction prompts | The right-click menu: pane actions with key hints; this pane's Background, Frame, Media and Debug | `ui/menu.rui` | right click |
| Mission toasts | Status messages as the yellow "!" toast; notifications as cut cards with a state rail | `ui/notices.rui` | |
| Operator roster | Squad: every pane's program as an operator card (its pane live in brackets, its state, an HP-style gauge), grouped by what it needs of you; in each group other tabs' panes active in the last 10 min, then this tab's by pane number (THIS TAB; hovered or chosen, its pane is lit), then the rest. A card goes to its session, tab and pane. Keys (Dvorak by default, `endfield_squad_keys`): t/n a card (QWERTY: j/k), h, s a group (QWERTY: l; past the last opens Standby), z or Tab shows or hides Standby, / searches by session, tab or name (↑/↓ among the matches, Enter goes, Esc leaves the field with the filter kept; Esc again clears it; the filter stays applied when the panel is closed and opened again), g/G, Enter/Space go, Esc closes; the panel has them as it opens, the side dock once clicked; a panel and a side dock | `ui/activity.rui`, `ui/squad.rui`, `ui/SquadRoster.rui` | cmd+. ; cmd+j |
| Settings > Performance | Device load: Rex's Diagnostics (the app, Rex Server, the API, RexSync, the GPU's load in the game's green, yellow, red) | `ui/diagnostics.rui` | cmd+shift+, |
| Backpack and depot | The Depot: the file manager (places and volumes with their capacity, a manifest or a grid of item cells, an item detail) | `ui/files.rui` + `ui/DepotBrowser.rui`, `panes/depot.rui` | cmd+shift+e; cmd+alt+e in a pane |
| AIC factory | The AIC monitor: one conveyor lane per core, the battery as the power grid, memory as the depot, the disk as the warehouse, the network as transport, the busiest processes as machines | `ui/aic.rui` (leads the side group), `ui/AicMonitor.rui`, `panes/aic.rui` | cmd+shift+i |
| Operational Manual | Missions: Daily, Weekly and Once in `missions.md`; done rows get a yellow wipe and a DONE stamp; a streak | `ui/missions.rui`, `ui/MissionList.rui`, `panes/mission.rui`, `backends/missions` | cmd+shift+j |
| Endministrator profile | The Account: your own account, read from SKPort (below): sanity counting up to full with the time it's full, daily activity, the pass, the counts, the main mission; this month's check-in; every operator you own as `OperatorCard`s six across (the 396 x 554 portrait on its rarity's glow, element, LV, promotion, rarity as the bottom edge and the game's stars, potential's ring; hovered, a sweep of light and a viewfinder; picked, a yellow frame and a diamond), and the picked one's file over the list as the game's operator screen (the art on the left on its rarity's glow and moving contours, in a viewfinder; on the right a frosted pale panel: the class in its box, the name, the element's badge, the stars; LV large on a grid of cells, yellow to the promotion's cap, LEVEL/cap; Elite with promotion's four diamonds and potential's X; the tags; the skills round with RANK under each, the ultimate in the element's colour; the weapon as the game tags one, its skills; the gear; from the Terminal's roster too); the regions as `RegionPanel`s (a faceted level frame, settlements as stat rows, the finds as four tiles, on a survey map's moving contours); the regions with their settlements and finds; the banners now (readable before SKPort has a character). The HUD shows sanity as a SAN gauge over CPU | `ui/account.rui`, `backends/skport`; `ui/bar.rui` (SAN) | cmd+shift+o |
| Region map, viewfinders | Pane frames (cut at two corners; the focused pane's brackets and number) and backgrounds (blueprint, survey, dots, curtain, ribbon, hatch, your own picture or movie) | `ui/panes.rui` | |
| Region map, as the day | Survey: the day on a 24-hour dial over contours and a grid | `panes/survey.rui` | `rexui pane survey` |
| Wiki | The Endfield wiki beside the panes | `ui/wiki.rui` | |
| Dev tools | rexui's Elements, Console and FPS meter in endfield's colours | `ui/menu.rui` (`devTheme`) | |
| Title screen | The Dock icon: the emblem on a cut plate with the tri-band | `assets/icon.png` | |

The side group (AIC, Missions, Account, Squad, Wiki) shares the right edge with a floating bar at the bottom centre (cmd+alt+s keeps
it up; cmd+shift+s shows or hides the group). cmd+s opens the web search over the middle of the focused pane
(websearch.rui): Return searches DuckDuckGo, or opens an address as it is, and the page shows in that pane over its
terminal (cmd+q in it and the terminal is back); Esc closes it. Its pages have no scroll bars (`web_scrollbars = false`).

## Options (`rui-config.lua`; Settings > endfield)

| Key | Default | |
|---|---|---|
| `endfield_accent` | `"valley"` | the signal: `valley` (yellow `#FFFA00`), `wuling` (teal), `grey` |
| `endfield_motion` | `true` | shaders move, elements flicker on, figures decode; `false`: all still |
| `endfield_boot` | `true` | the yellow rule wiping along the HUD once per load |
| `endfield_loading` | `""` | your own capture of a loading screen (a movie, GIF or picture; relative to the distro or `~`) played full window by the loading screen instead of endfield's own: keep it in `assets/brand/` (gitignored); empty: endfield's own |
| `endfield_callsign` | `""` | what the Terminal calls you; empty: your login name |
| `endfield_logo` | `""` | a picture of your own (your copy of a logo) where the emblem is: the HUD, the Terminal's masthead, the wheel's hub; empty: endfield's emblem. Nothing of it is in the repo; `app_icon` can point at it too |
| `endfield_pane_background` | `"blueprint"` | every pane's: `blueprint`, `survey`, `dots`, `curtain`, `ribbon`, `hatch`, `none` (a pane's own from the context menu wins) |
| `endfield_pane_frame` | `"cut"` | every pane's corners: `sharp`, `cut`, `notch`, `round` |
| `endfield_pane_dim` | `0.72` | how much a picture or movie behind a pane is dimmed, 0 (as it is) to 1 (gone); never the shaders (a pane's own from the context menu's Dim wins; its All panes sets this) |
| `endfield_pane_blur` | `0` | how much a picture or movie behind a pane is blurred, in pt; never the shaders (a pane's own from the context menu's Blur wins; its All panes sets this) |
| `endfield_activity` | `"endfield"` | cmd+. opens the Squad panel; `"rex"`: Rex's own Activity popover |
| `endfield_squad_keys` | `"dvorak"` | Squad's keys: `dvorak` h t n s, `qwerty` h j k l (the arrows either way) |
| `missions_folder` | `"~/Documents/Missions"` | where `missions.md` is kept (made with the first mission) |
| `endfield_game_keys` | `"qwerty"` (this config: `"dvorak"`) | cmd+alt+g's Endfield: `qwerty` its keys by their place with macOS on any layout; `dvorak` for a keyboard typing Dvorak itself (its firmware, macOS on ABC): every key as typed (your F is the game's F, in its settings too) but the movement keys, its `,` `o` `e` (where W S D are) sent as W S D, so the game's E, O and `,` are on no key (Endfield's combo skill, on E, wants another key in its Controls); `system` as typed. Steam starts again for another one |
| `skport_browser` | `"zen"` | the browser you're logged in to SKPort in (`zen`, `firefox` or a profile folder): the Account uses that login |
| `skport_demo` | `true` | the default: a made-up account in the Account and the Terminal (operators, check-in, regions, banners, sanity counting up), for anyone without an SKPort login; nothing is read or sent, and there are no pictures. `false`: your own account, read with your browser's SKPort login (`endfield-skport`, below) |
| `skport_every` | `5` | minutes between the Account's reads of SKPort (2 to 60) |

rexui's own options it sets: a see-through blurred window without traffic lights or tab bar; the tab slide and pane
glide on the out-expo curve (260 and 240 ms); endfield's palette, notices, Rex's windows (Device load) and file manager
(the Depot) taking over Rex's; the Dock icon.

## The design system

The research is `DESIGN-NOTES.md`; every file carries the same palette block. Not the components made once per card (`OperatorCard`, `Potential`, `Stars`): the whole block is ~50 bindings an instance, and 8 cards, each with a Potential of five Diamonds and a Brackets, put the HUD past the 2 s script limit as the account came in (2026-11-04). They carry the few tokens they use, draw diamonds, brackets, stars and potential as Paths, and the lists cards are made from are kept as their JSON text (`rosterJson`, `opsJson`...), so a read that leaves one the same, or a tick of the clock, doesn't make its cards again.

- **Colour.** The game's greys: ground `#0F0F10`, surface `#17181A`, raised `#1E2024`, well `#0A0A0B`, the steel
  `#33363C` for every 1 pt line, ink `#F0F0F2` / `#A8ABB2` / `#7F828A`. One signal, `#FFFA00`, for structure,
  selection, progress and the one primary action per view (dark ink on it, never yellow text on light). Semantic:
  orange `#FF7A1A` needs you, crimson `#D91E36` danger, green `#7BE04B` done, blue `#4FA8FF` data, lime `#BCE41D`
  working; the tri-band (yellow, cyan `#00FFA2`, magenta `#FF1AAC`) once per panel.
- **Type.** HarmonyOS Sans for the interface, Saira at `font.width: "expanded"` for wide caps labels (Novecento's
  place), Space Grotesk for numerals (tabular, light when large), Iosevka for data, micro lines and key hints.
- **Shape.** Radius 0. Chamfers cut the top right and bottom left: panels 16, cards 10, buttons 7, plates 6. Hairlines
  first, cards second, no shadows. Triangles (the wheel: the emblem) and octagons instead of circles.
- **Motifs.** `SEC.01 // TITLE` heads, `// micro` lines that always say something true (the date, counts, a pane's
  number), ghost words outlined behind titles, ◇/◆ diamonds, corner brackets (14 pt, 2 pt, the signal at 55%), key
  hints with a heavier bottom edge, `| value` stat rows, `!!!` for what needs you, hazard hatch, dot grids, contours.
- **Motion.** Out-expo (0.16, 1, 0.3, 1) for place and size, 200–300 ms; things flicker on (opacity 0 .5 0 .5 0 .5 1)
  as a drawer opens or a page arrives, toasts wipe in, the time and titles decode; nothing bounces.

## Shaders (`ui/shaders/`)

| File | Draws | params / colors |
|---|---|---|
| `emblem.metal` | endfield's own mark: a broken rhombus, an inner facet, a turning glint | busy, turns a minute, glint, line width / mark, glint, facet |
| `hatch.metal` | hazard or fine diagonal hatch, faded along x, marching if asked | angle, period, duty, march pt/s, fade start, fade end / stripes, ground |
| `dots.metal` | a dot grid fading at the top and bottom | cell, radius, fade top, fade bottom / dots |
| `contour.metal` | survey contours, every fifth heavier, optionally only in two corners | lines, pt per hill, speed, width, corner reach, fade / lines, near the pointer |
| `grid.metal` | a blueprint grid with + at the major crossings, an optional scan | minor cell, major every, + arm, scan s / minor, major, +, scan |
| `belt.metal` | conveyor lanes, cubes by each lane's load at one speed, >> chevrons | 12 loads, lanes, speed, lane height / outline, glow, cubes, chevrons |
| `curtain.metal` | a light curtain: short vertical lines, a brightness wave | pitch, height, wave speed / light |
| `ribbon.metal` | Regional Development's ribbons with contours etched in | count, angle, drift / ribbon, edge, field |
| `foil.metal` | a notched hexagon medal of brushed metal, holographic bands under the pointer | notch, bands, glow / metal, rarity, ground |
| `card.metal` | an operator card's ground (its rarity's glow rising from the foot, faint hatching, scanlines) or, over the portrait, the band of light that sweeps it while hovered | mode (0 ground, 1 sweep), glow height, sweep period, hovered / rarity, ground, light |

All take their angle and phase from the clock alone; Panes backgrounds are `running: false` unless chosen to move.

## Backends (`backends/`, Swift; `rexui build endfield`)

| Binary | What |
|---|---|
| `endfield-sys` | the Mac once a second: CPU and each core, memory, disk, network in and out, battery, thermal state, the four busiest of your own processes, the login name. Reads only |
| `endfield-missions` | `missions.md` in `missions_folder`: Daily / Weekly / Once, done stamped with the day, the streak; writes only when you add, finish or remove a mission |
| `endfield-files` | the newest pictures and movies in ~/Downloads, ~/Pictures, ~/Movies, for the context menu's Media (only while it's open) |
| `endfield-game` | cmd+alt+g: Arknights: Endfield in the focused pane, a one-off. It starts `rexui embed` in the background with the pane's `$REX_BLOCK` (as rexui-launch does: nothing typed, the game covers the pane until it quits): Steam from CrossOver's Steam bottle with `-applaunch 4732690`, the game adopted by `REXUI_EMBED_EXE=Endfield.exe`, on `~/Applications/CrossOver_Endfield_Patch.app` with DXMT. Not when the game runs already. A Steam it started before (it stays after the game quits) gets the launch handed to it, nothing quit: the game finds its pane in `REXUI_EMBED_TARGET`'s file, written at each launch. Any other Steam (started from CrossOver) is asked to quit (`steam.exe -shutdown`, then the bottle ended after 15 s) and starts again from the pane. While it starts, the pane shows endfield's loading screen (panes.rui: the phase, a percentage) till the game's window is in (cmd+q in that pane meanwhile stops the launch, not Rex; a mark left by a relaunch mid-way comes off as the HUD loads); cmd+q in the game shows a closing screen over its last frame till it's gone (a second cmd+q within 20 s ends it). The keys go by `endfield_game_keys`. Its output: `~/Library/Logs/endfield-game.log` |
| `endfield-skport` | your Endfield account from SKPort (`zonai.skport.com`, Gryphline's companion site: the API its own pages call), every `skport_every` minutes and on Read again. **It goes on the network**, with your login: the browser's SKPort cookie, read from a private copy of its `cookies.sqlite` (never the file itself), sent only to `zonai.skport.com` as the browser sends it, never printed or kept. Reads only (GETs: the account, the linked role, its card, this month's check-in, the banners, the enums); never checks in. The art it names loads from `static.skport.com`. Only with `skport_demo = false`; by default (`true`), `endfield-skport demo`: a made-up account, no browser, no network | The pictures (static.skport.com's: SKPort's square avatars are 144 px, so the docks draw the 396 x 554 portraits and the art) are downloaded once into `assets/skport/`, six at a time, by a session of their own without the cookie, and the state names the files; one not there yet goes as its URL till it has come
| `rexui-rex` | Settings: Rex's preferences, the config files, the command list (as the main distro's) |

## Fonts

`fonts/fetch.sh` downloads, once and into this folder only: HarmonyOS Sans (Regular, Medium, Bold, Light; the
OpenHarmony project's copy), Saira and Space Grotesk (variable, from google/fonts), Iosevka (Regular, Medium, Bold, read
out of its release zip by range requests). Each is checked; nothing is installed system-wide. Licences in
`fonts/LICENSES/`: the SIL Open Font License for Saira, Space Grotesk and Iosevka; **this distro uses HarmonyOS Sans
Fonts** under the HarmonyOS Sans Fonts License Agreement (unmodified copies, this notice kept). Without them each role
falls back to the system's fonts.

## Keys

cmd+e the wheel · cmd+shift+space the Terminal · cmd+shift+? Controls · cmd+, Settings · cmd+shift+, Device load ·
cmd+. Squad · cmd+shift+e the Depot · cmd+alt+e the Depot in a pane · cmd+shift+i AIC · cmd+shift+j Missions · cmd+shift+o Account · cmd+alt+g Endfield in the focused pane · cmd+j
Squad dock · cmd+s web search in the focused pane · cmd+alt+s the side group's bar · cmd+shift+s the side group. None of them is Rex's or init.lua's.
