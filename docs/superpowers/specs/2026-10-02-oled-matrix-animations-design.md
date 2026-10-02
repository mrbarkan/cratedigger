# OLED matrix animations — design

2026-10-02. Builds on the NOW-screen rework of the same day (NOW PLAYING on
the rail, the small time reading under the artist line, the spectrum where
the big clock was).

## What

The NOW screen's spectrum becomes a **12 × 6 LED matrix** that fills the
right of the glass, from the NOW annunciator to the right edge, top of the
title to the progress line. It plays one of four animations, all driven by
the real audio:

1. **Vertical VU** — the spectrum: one column per band, 20 Hz left to
   20 kHz right, rising from the bottom, with a peak segment.
2. **Horizontal VU** — classic stereo bars: left channel on the top three
   rows, right channel on the bottom three, filling left to right.
3. **Explosions** — light bursts from the centre: loudness sets the radius
   of a lit core, and each bass hit launches a ring that travels outward and
   fades.
4. **Frame** — light closes in from the border: loudness sets how many rings
   are lit from the edge inward, and each ring's brightness follows its own
   part of the spectrum (outer bass, middle mids, inner treble).

Clicking the **titlebar status LED** steps Vertical → Horizontal →
Explosions → Frame → Off → Vertical. **View ▸ Display Animation** lists the
same five with a checkmark. The choice survives relaunch. Off gives the
title the full width of the glass again.

User-made animations are **out of scope**. The design leaves the seam for
them (`MatrixAnimation`, below) and nothing more.

## Why the old spectrum looked anchored in a corner

The drawing was right side up; the analyser was not weighted. Music's
energy falls by roughly 3–6 dB per octave, so an unweighted FFT always
slopes down to the right, and with a −62 dB floor the treble bands rarely
lit at all. Whatever was playing, the meter read as a staircase growing out
of the bottom-left corner. Analysers compensate with a spectral tilt; this
one had none. The fix is in `SpectrumProcessor`, not in the view.

## Pieces

### Core: `Sources/CrateDiggerCore/Services/Matrix/` (new)

Everything here is pure, `Sendable` and tested. No SwiftUI, no timers.

```swift
public struct MatrixCell: Equatable, Sendable {
    public var intensity: Double   // 0 = unlit, 1 = peak
    public var heat: Double        // 0…1 along the cyan → Meter High ramp
}

public struct MatrixFrame: Equatable, Sendable {
    public static let columns = 12
    public static let rows = 6
    public var cells: [MatrixCell]           // row-major, row 0 = bottom
    public subscript(column: Int, row: Int) -> MatrixCell { get set }
    public static let dark: MatrixFrame
}

public struct MatrixInput: Sendable {
    public var bands: [Double]     // 12, 0…1, low → high, already smoothed
    public var left: Double        // 0…1
    public var right: Double       // 0…1
    public var dt: TimeInterval    // since the previous frame
    public var loudness: Double { /* mean of bands */ }
}

public protocol MatrixAnimation: Sendable {
    mutating func frame(for input: MatrixInput) -> MatrixFrame
    /// True when nothing is moving and the last frame was dark, so the
    /// driver may stop its timer.
    var isAtRest: Bool { get }
    /// The heat a cell lights with, which also tints its print while dark.
    static func restingHeat(column: Int, row: Int) -> Double
}

public enum MatrixAnimationKind: String, CaseIterable, Sendable {
    case vertical, horizontal, explosions, frame, off
    public var next: MatrixAnimationKind      // the click order above
    public var label: String                  // "Vertical VU", …, "Off"
    public func make() -> (any MatrixAnimation)?   // nil for .off
    public init(persisted: String?)           // unknown or nil → .vertical
    public func restingHeat(column: Int, row: Int) -> Double  // its animation's; 0 for .off
}
```

Each animation sets **heat** as well as intensity, so it picks its own
colour direction and the view never needs to know which one is running.
That is also what a future user animation would rely on.

An unlit cell keeps heat 0 in the frame, so that silence compares equal to
`.dark` (the driver's halt and publish-on-change both rest on that). The
heat a dark cell prints in comes from the animation's static
`restingHeat(column:row:)` instead, which is the same heat the cell lights
with; each animation's "Heat =" rule below is that function.

**`VerticalVUAnimation`** — column *c* lights `round(bands[c] × 6)`
segments from the bottom. The top lit segment has intensity 1 (peak), the
segments under it 0.75. Heat = row / 5.

**`HorizontalVUAnimation`** — rows 3–5 show `left`, rows 0–2 show `right`.
Each bar lights `round(level × 12)` columns from the left, with the last
lit column as its peak. Heat = column / 11.

**`ExplosionsAnimation`** — distance from the grid's centre (5.5, 2.5) is
elliptical, `d = √((dx/6)² + (dy/3)²)`, clamped to 0…1, so a ring fills the
wide grid evenly. The core lights cells with `d ≤ loudness`. A **bass hit**
is the mean of bands 0–2 rising more than 0.15 above its own running average
(time constant 0.3 s). Each hit spawns a ring at radius 0 that grows at
2.0 per second and fades linearly from 1 to 0 over 0.5 s. A ring lights
cells within 0.18 of its radius. At most four rings exist at once; the
oldest is dropped. A cell takes the brightest of the core and any ring.
Heat = 1 − d. At rest when there are no rings and the loudness is zero.

**`FrameAnimation`** — a cell's ring is `min(c, 11 − c, r, 5 − r)`: 0 at
the border, 2 at the centre. `depth = loudness × 3`, so rings 0 up to
⌈depth⌉ − 1 are lit, and the innermost lit one is scaled by the fractional
part. A lit ring's intensity is the mean of its band group: bands 0–3 for
ring 0, 4–7 for ring 1, 8–11 for ring 2. Heat = ring / 2.

### Core: `SpectrumProcessor` tilt

Each band gets a fixed gain of `4.5 × log2(fc / 1000)` dB before the
dB → 0…1 mapping, where *fc* is the band's centre frequency (the geometric
mean of its edges). That is 0 dB at 1 kHz, about −24 dB at the lowest band
(centre ≈ 27 Hz) and about +18 dB at the highest (centre ≈ 15 kHz). The floor and ceiling are then retuned against one
test target: **pink noise at −18 dBFS RMS lights every band to 3 ± 1
segments.** The gains are computed once in `init`, beside the band ranges,
so the audio thread does no extra work.

`currentPlaybackSpectrum` has no other consumer, so nothing else changes.

### App: `MeterDriver`

It keeps its ballistics, its 30 fps timer, the hidden-window halt and
`halt()`. What changes:

- It also smooths `left` and `right` from `currentPlaybackLevels`, using
  the same constants.
- It owns `var animation: (any MatrixAnimation)?`, set from the view. Each
  tick builds a `MatrixInput` from the smoothed values and publishes
  `@Published private(set) var frame: MatrixFrame`, **only when it differs
  from the last one** (the same rule that quantised `bands` to whole
  segments today). Intensities are rounded to steps of 1/8 before
  comparing (`MatrixFrame.quantize(step:)`, in Core), so a fade doesn't
  republish on every tick; a cell that rounds to 0 drops its heat too, so a
  faded picture equals `.dark`.
- The timer stops when the levels have settled **and**
  `animation.isAtRest`. A ring still travelling after the music pauses
  keeps the timer alive until the ring has faded.
- Swapping the animation resets the frame to `.dark`.

### App: `OLEDMatrix` (replaces `OLEDSpectrum` in `OLEDDisplay.swift`)

One `Canvas` that draws `meters.frame`. An unlit cell (intensity 0) is the
ramp colour at the current kind's `restingHeat` for that cell, at 10%
opacity, so the dark grid shades the way the animation does. A lit cell is the ramp colour at
its heat, with brightness following its intensity and the same glow layers
as today; intensity 1 uses the bright ramp (`cyanGlow` → `meterHotHi`). The
ramp is cyan → `meterHot`, interpolated by heat. On a monochrome panel
(`theme.oledMonochrome`) it uses ink only: 7% unlit, then 0.55–0.85 by
intensity: 0.55 at the VU body's 0.75 and below, rising linearly to 0.85 at
1, so the VU bars keep their old two levels and a lit cell never fades to
where it passes for an unlit one. Cells sharing a colour are filled as one
path, as the old spectrum's three paths were, not one fill per cell. Decorative, so hidden from VoiceOver.

### App: alignment with NOW

`DisplayRail` tags the NOW annunciator with a preference key reporting its
leading x in a named coordinate space on the glass (`"oledGlass"`).
`OLEDDisplay` stores it in `@State` and hands it down as an environment
value. `NowPlayingScaffold` lays out the headline and the matrix in an
`HStack`, with the matrix frame running from that x to the trailing edge.
Until the first layout pass reports a value, the matrix takes half the
width. Theme fonts or a narrower window move the NOW lamp, and the matrix
follows. The title scales down to its existing 0.55 minimum and then
truncates.

When the kind is `.off`, the scaffold leaves out the matrix entirely (no
`MeterDriver` exists, so no timer runs).

### App: state, LED, menu

- `PreferencesStore.oledMatrixAnimation: String?`, in the pattern of
  `savedOLEDView`.
- `LibraryViewModel.matrixAnimation: MatrixAnimationKind` (`@Published`,
  loaded through `init(persisted:)`, saved in `didSet`) and
  `cycleMatrixAnimation()`.
- `StatusLED` becomes a `Button` with a plain style that calls
  `cycleMatrixAnimation()`. Its hit area is padded to 18 × 18 pt, while the
  lamp itself stays 9 pt. The busy glow is unchanged. The tooltip reads
  `Animation: Explosions. Click to change.`, followed by the activity
  labels when the app is working. The VoiceOver label is "Display
  animation", with the current label as its value.
- AppDelegate: **View ▸ Display Animation** submenu, after the display
  items. It has five items in click order, each tagged with its kind's raw
  value, using one `selectMatrixAnimation(_:)` action. `validateMenuItem`
  sets the checkmark.

## Error handling

Nothing here can fail at run time. A saved value the app no longer knows
(say, a removed or future user animation) falls back to Vertical VU, which
keeps the screen working rather than blank. An empty or short `bands`
array (a stream tap that has not delivered yet) reads as zeros for the
missing bands, and `MatrixInput` pads it.

## Testing

Core, XCTest (`Tests/CrateDiggerCoreTests`):

- `SpectrumTiltTests` — the tilt is 0 dB at 1 kHz and +4.5 dB per octave.
  Synthesised pink noise at −18 dBFS RMS, fed through `compute`, lights
  every band to 3 ± 1 segments.
- `MatrixAnimationTests`:
  - every kind: silence gives `.dark` and `isAtRest`;
  - Vertical: all bands at 1 lights every cell, with row 5 as the peak;
    `bands[0] = 0.5` and the rest at 0 lights three cells in column 0 only;
  - Horizontal: L = 1, R = 0 lights rows 3–5 completely and rows 0–2 not
    at all;
  - Explosions: a bass step spawns a ring; its radius grows across
    successive `dt`; it reaches rest within 0.6 s once the bass falls back;
  - Frame: bass only lights ring 0 alone, and full bands light every ring;
  - Kind: `next` follows the click order, `init(persisted:)` maps nil and
    `"bogus"` to `.vertical`, and `.off.make()` is nil.

App (`Tests/CrateDiggerAppTests/MeterDriverTests`): the existing three
tests are reworked onto `frame`: lights up, fades to `.dark` and halts, and
`halt()` is immediate. A new case checks that the timer outlives a pause
while an Explosions ring is still travelling.

Not automated, checked by eye in the running app: alignment with NOW
across two themes and a narrow window, each animation with music playing,
the monochrome rendering, the LED click cycle and the menu checkmark.

## Out of scope

- User-made animations: a file format, an editor, sharing. This design
  only keeps them possible.
- Changing the band count or the row count. 12 × 6 is the hardware.
- Any matrix on screens other than NOW.
