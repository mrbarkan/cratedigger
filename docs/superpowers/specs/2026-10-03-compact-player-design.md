# Compact Player — design

**Release line:** 2.3 (`v2.3`, cut from `main` on 2026-10-03)
**Status:** approved in conversation, awaiting written-spec review

## Intent

A third way to look at the app, between the full window and the floating Mini
Player: the main window collapses into a single "rack unit" that is the real
full display, the playing album's art and the real transport, and nothing
else. No sources, no browser, no inspector. It should read as a hardware
component on the desktop, not as a cut-down window.

What the user asked for, in their words: "an alternate small player (more of a
compact player) in which we see full display, album art and bottom controls.
Just no browser. As if it was a hardware media player." Later: "when the user
clicks on the album art it opens the album art viewer."

Decided along the way:

| Question | Decision |
|---|---|
| Relationship to existing windows | The **main window morphs** into compact. The Mini Player stays exactly as it is. |
| Shape | **Rack unit, landscape**: square art on the left, display over footer on the right. |
| Display content | **NOW only** while compact. |
| Window level | **Normal titled window**, no float option. Each mode keeps its own frame. |
| Commands that need the browser | ⌘F and ⌘L **expand first**; selection-based commands are **disabled**. |
| Art click | Opens the **album art viewer** (same route as View Artwork). |

Out of scope: a Keep on Top option, a DISPLAY key in compact, any change to
the Mini Player or Full Screen Player, a portrait layout.

## 1. Layout

```
┌──────────┬──────────────────────────────────────────────┐
│ ●●●      │  [ OLED · NOW screen, LED matrix, as today ] │  headerHeight (170)
│          │                                         ⤢    │
│   ART    ├──────────────────────────────────────────────┤  chassisRowGap (12)
│  square  │  ◯POSITION   ⤨ ⏮ ↺  ▶  ↻ ⏭ ⟳   VOLUME◯      │  footerHeight (92)
└──────────┴──────────────────────────────────────────────┘
```

Standard geometry: art 274 × 274, window content ~1220 × 302 at minimum width.

- **Chassis.** The same `ChassisLayer` and `.carbonThemed(mode:)` as the full
  window, so every theme, skin and appearance mode applies unchanged.
- **Art well.** A recessed square whose side is
  `headerHeight + chassisRowGap + footerHeight`, read from `CarbonGeometry`
  so a theme that retunes the rows retunes the art. It shows:
  - the playing track's cover;
  - a stream's thumbnail while radio plays;
  - the theme's empty-well treatment when nothing plays (no text; the OLED
    already says nothing is playing).

  The art well starts below the titlebar strip, so the traffic lights sit over
  chassis, never over the picture.
- **Display.** The real `OLEDDisplay`, at full header height, always showing
  the NOW screen (see §3, override), with whichever matrix animation is
  selected. Extra width spaces the matrix columns out as it already does.
- **Footer.** The real `FooterShell` without the locate key ("Go to Current
  Song", `scope`), since there is no browser to reveal into. That leaves three
  keys on each side of PLAY (shuffle, previous, −10 | PLAY | +10, next,
  repeat), so the dome centres with no trailing-padding offset.
- **Expand key.** A small `pip.exit` key in the OLED glass's top-right corner,
  styled like the brand block's Mini Player key. It returns to full.
- **Resizing.** Height is fixed. Width runs from the minimum (art + gap + the
  footer's narrowest, ~1220 in all) to the screen's width, and extra width goes
  to the display and the footer's two pods, as in the full window.

### Footer minimum width, for the record

Measured from the current code: horizontal padding 2 × 26, `PositionDial`
min 184, gap 28, transport 6 × 46 + 78 + 6 × 11 = 420 without locate, gap 28,
`VolumeKnob` min 184 = **896**. Window content minimum = 18 + 274 + 12 + 896 +
18 = **1218**. With locate the footer alone is ~1010, which is why it goes.

## 2. Behaviour

### Entering and leaving

- **Window ▸ Compact Player**, directly below Mini Player, shortcut **⌥⇧⌘M**
  (⇧⌘M is Mini Player; ⌥⌘M is the system's Minimize All alternate). It is a
  toggle with a checkmark showing the current layout.
- Leaving compact: the menu item, the expand key on the display, or the green
  zoom button. While compact, zoom means "go full" rather than maximising a
  strip one rack unit tall.
- The window animates between the two frames.
- Each mode has its own saved frame. Compact reopens where it was parked; full
  reopens at its own size and position.
- The layout persists across quit and relaunch.
- **Exception:** with no library chosen (`LibraryLocation.notChosen`), the app
  always launches full, whatever was saved, so the welcome flow has its window.

### Commands

Every menu command falls into one of three classes in compact (in full,
everything is available as today):

- **Expands first, then runs.** Find (⌘F) and Go to Current Song (⌘L). Asking
  for either is asking for the browser.
- **Disabled.** Anything that acts on the browser selection, because acting on
  a selection you cannot see is a trap. Convert Selected, Transfer to Device,
  Reveal Selection in Finder, Play Next, Play Last, Rate / Clear Rating,
  Select All, and the tag and artwork editors.
- **Available.** Everything else, in particular all of playback: Space,
  ⌘→ / ⌘←, ±8 s, volume, shuffle, repeat, sleep, EQ, output device, Full
  Screen Player, Mini Player, Dig Crate, Preferences.

The final per-command list lives in `CompactCommandPolicy` (§3); this list is
what it must encode.

### Art click

Clicking the art opens the **album art viewer** for the playing track's album,
through the same path as the browser's View Artwork (`model.artworkViewerAlbum`):
a PDF booklet opens the booklet reader, and everything else opens
`ArtworkViewerPresenter` (full-screen navigator with FLOAT). The album comes
from the library index by the playing track. When there is no `Album` (a
stream, a remote track, a track not in the current index), the art is not
clickable and shows no hover affordance.

### What keeps running

- Scans, rips, downloads and conversions keep running in compact. The display
  stays on NOW, and the titlebar status LED shows the activity.
- `model.oledView` keeps being set by the app as usual (scans, rips and search
  all set it), so on expand the display is on whatever screen the app last
  chose: if a rip started while compact, you land on DUB.
- A Finder drop onto the compact window still goes to the Prep Crate (the drop
  handler is on the shared root).
- Mini Player and Full Screen Player work from either layout, unchanged.

## 3. Architecture

Approach: **one window, two layouts inside the existing `CarbonRootView`.**
Rejected:
- swapping the window's content view controller, which duplicates the chassis,
  theming, drop target and theme-editor panel;
- keeping the full tree alive but hidden, which keeps a 14k-track browser
  rendering invisibly and lets focus land in hidden columns.

Accepted cost: the browser's view tree is rebuilt on expand, so its scroll
position resets. Selection, sorts and search live in `BrowserState` on the view
model and survive.

### Core (`CrateDiggerCore`, unit-tested)

- **`Models/PlayerLayout.swift`.** `enum PlayerLayout: String { case full, compact }`,
  plus `static func launchLayout(saved: PlayerLayout?, libraryChosen: Bool) -> PlayerLayout`:
  `full` when no library is chosen, else `saved ?? .full`.
- **`PreferencesStore.playerLayout`** (raw-value backed; unknown or missing
  resolves to `.full`) and **`PreferencesStore.savedCompactWindowFrame: CGRect?`**,
  stored beside `savedWindowFrame`.
- **`Models/CompactCommandPolicy.swift`.** `enum PlayerCommand` names every
  menu command that is not plain "available" (`find`, `goToCurrentSong`,
  `convertSelected`, `transferToDevice`, `revealSelection`, `playNext`,
  `playLast`, `rate`, `selectAll`, `editTags`, `editArtwork`; exactly the
  §2 lists, no others).
  `static func availability(_:in:) -> CommandAvailability` returns
  `.available` / `.expandsFirst` / `.disabled`, and uses an exhaustive
  `switch`, so a new `PlayerCommand` case won't compile until it is
  classified.

### App (`CrateDiggerApp`)

- **`LibraryViewModel+CompactPlayer.swift`** (new extension), holding:
  - `@Published var playerLayout` (stored on the main class, persisted in
    `didSet`);
  - `enterCompact()`, `expandToFull()` and `toggleCompactPlayer()`;
  - `nowPlayingAlbum: Album?`, the playing track's album in `index`, nil for
    streams and remote;
  - `showNowPlayingArtwork()`, which sets `artworkViewerAlbum`.
- **`CarbonRootView`.** Inside `ChassisLayer`, switch on `model.playerLayout`:
  today's Header / MainShell / Footer stack, or `CompactDeckView`. Every
  modifier already on the root stays shared.
- **Hoist from `MainShell` to `CarbonRootView`** the handlers that compact
  needs: `.onChange(of: artworkViewerAlbum)`,
  `.onChange(of: fullScreenPlayerRequested)` and the EQ editor sheet. Without
  this, the art click and the EQ key silently do nothing in compact, because
  `MainShell` is not in the tree. The tag-editor sheet is hoisted too, so
  sheet presentation lives in one place, even though compact disables its
  commands.
- **`UI/Carbon/Main/CompactDeck/CompactDeckView.swift`** (new). An `HStack`:
  the art well (`NowPlayingCover` in a recessed well, with a tap gesture when
  `nowPlayingAlbum != nil`) and a `VStack` of `OLEDDisplay` with the expand key
  overlay, over `FooterShell(showsLocate: false)`. Sizes come from
  `CarbonGeometry`.
- **`NowPlayingCover`** (extracted from `MiniPlayerView`). The cover-loading
  chain (stream `coverURL` thumbnail, then `artworkHash` thumbnail, then
  `resolveArtwork`) moves into one view used by both the Mini Player and the
  compact deck. The Mini Player behaves exactly as before.
- **`OLEDDisplay`.** A new `EnvironmentValues.oledScreenOverride: OLEDView?`.
  The display's reads of `model.oledView` go through one
  `screen = override ?? model.oledView`. The compact deck sets `.nowPlaying`.
  Writers of `oledView` are untouched.
- **`FooterShell` / `TransportCluster`.** `showsLocate: Bool = true`. The
  trailing padding that centres PLAY is computed from the actual key counts
  either side of the dome, replacing the literal `(4 - 3)`.
- **`WindowFramePlanner`.** `compactPlan(visibleFrame:currentFrame:geometry:)`
  returns a `PlannedWindowFrame` with:
  - a fixed content height (`2 × chassisInsetV + headerHeight + chassisRowGap + footerHeight`,
    plus titlebar);
  - a minimum width of `2 × chassisInsetH + artSide + mainGap + footerMinWidth`;
  - a maximum width of the visible frame;
  - a clamp of the saved frame onto the screen.

  The existing full plan is unchanged.
- **`MainWindowController`** observes `model.$playerLayout`:
  - sets `minSize` / `maxSize` for the mode;
  - animates to that mode's saved frame, or the planned default (compact's
    default is the full window's top-left corner);
  - routes `persistFrame()` to `savedWindowFrame` or
    `savedCompactWindowFrame` by layout;
  - implements `windowShouldZoom(_:toFrame:)` to expand when compact.

  At launch it applies `PlayerLayout.launchLayout`.
- **`AppDelegate`.**
  - Add the Window ▸ Compact Player item (⌥⇧⌘M, checkmark).
  - `validateMenuItem` maps each item's selector to a `PlayerCommand` and asks
    the policy.
  - The ⌘F and ⌘L actions call `expandToFull()` first when compact.

## 4. Testing

Core (`scripts/test.sh`):
- `PlayerLayoutTests`:
  - `launchLayout` across saved values {nil, full, compact} × library chosen
    or not;
  - raw values stay stable (`"full"`, `"compact"`), since they persist.
- `CompactCommandPolicyTests`:
  - every command is `.available` in full;
  - in compact, `find` and `goToCurrentSong` are `.expandsFirst`, each listed
    selection command is `.disabled`, and the rest are `.available`.
- `PreferencesStore` tests:
  - `playerLayout` round-trips, and an unknown value reads as full;
  - `savedCompactWindowFrame` round-trips independently of `savedWindowFrame`.

App (`Tests/CrateDiggerAppTests`):
- `WindowFramePlannerTests`:
  - the compact height tracks geometry (standard and a retuned theme);
  - the minimum width equals the derived footer sum;
  - a saved compact frame is restored and clamped;
  - a small screen clamps;
  - the full plan is unchanged.

Manual, in the running app (build, run `.build/debug/CrateDiggerApp`):
1. Toggle full ⇄ compact by the menu item, the shortcut, the expand key and the
   zoom button. Both frames persist independently.
2. Quit in compact and relaunch: the app opens compact.
3. Switch themes and light/dark in compact.
4. Play a local album: art shows, and a click opens the navigator (try one
   album with a PDF booklet and one without).
5. Play a stream: the thumbnail shows, and the art is not clickable.
6. Press ⌘F and ⌘L in compact: the window expands, then searches or reveals.
   Selection commands are greyed out.
7. Open the EQ editor and Full Screen Player from compact.
8. Start a rescan in compact: the display stays NOW, the status LED shows
   activity, and expanding shows SCAN.
9. Drop a Finder folder on the compact window: it lands in the Prep Crate.
10. Drag the window to its minimum width: nothing clips. Check the Mini Player
    still shows its cover as before.
11. Take screenshots of compact, light and dark.
