# Busy Signals: design

2026-10-15. Branch `feature/busy-signals`. Builds on the OLED matrix
animations (2026-10-02) and the compact player (2026-10-03).

## 1. Goal and the approved look

While a job runs, the OLED draws a small animated line-art scene of it. On
every other screen, a 96 × 12 pt "source - - - - destination" mini of the
same job sits on the annunciator rail. Six jobs: CD rip, Secure read,
Convert, Scan, Download, Transfer.

The look was approved on 2026-10-12. Two files define it, and both bind this
spec:

- `CrateDigger_DESIGN/busy-signals/README.md`: the decisions, the six scenes,
  their finished states, and the mini rules.
- `CrateDigger_DESIGN/busy-signals/busy-signals.html`: the throwaway sketch.
  Its `SCENES[].draw` and `MINI` functions are the **visual source of truth**:
  geometry in 240 × 100 scene units and 96 × 12 mini units, timing and inks.
  The Swift port reproduces that look, not the JS architecture. Line numbers
  below (`html:NNN`) point into this file.

User feedback is already folded into the sketch and binds it:

- **Scan:** a high camera over the crate, so records' bottom edges are never
  visible. The picked pile uses records the same size as the crate's, and the
  top one shows a cover. Crates slide out and in with dividers A–F, G–M, N–S
  and T–Z. The mini scan's fallen record stays inside the crate's width.
- **iPod:** the mini is an outline, a solid white screen and a solid white
  click wheel. The big one is an outline, a plain screen showing only Apple's
  no-entry "do not disconnect" sign, and a bare click wheel.
- **Convert mini:** the flat block is centred on the dashed line.
- **Cassette:** 1.57 : 1, with a stadium window and a hub in each round end.
- **Throughout:** 8 fps, stepped motion with no easing. Two inks (cyan and
  hot) that collapse to one under the theme editor's monochrome glass. OLED
  only, with no copies in the panels.

## 2. Architecture

Three layers, matching how the LED matrix was built:

- **Core:** a pure scene model. Progress goes in and line primitives come
  out, unit-tested frame by frame.
- **App:** one `Canvas` renderer, ticked at 8 fps only while the window is
  visible.
- **View model:** a thin extension that stamps jobs at the places they
  already start and finish.

### 2.1 Core: `Sources/CrateDiggerCore/Services/BusySignals/`

Everything here is pure, `Sendable` and `Equatable`, with no SwiftUI and no
timers. Geometry uses CoreGraphics types in y-down unit space, as
`MatrixLayout` does. The style is the matrix's: `public` API, internal
tuning constants that tests reach through `@testable`, and dense *why*
comments.

#### Drawing: `BusyDrawing.swift`

```swift
/// What a stroke or fill is drawn in. Semantic, so the renderer maps it onto
/// whatever glass theme is active (and monochrome falls out of that map).
public enum BusyInk: String, CaseIterable, Sendable {
    case foreground   // the OLED phosphor
    case cool         // theme.cyan
    case hot          // theme.meterHot
    case dim          // phosphor at 0.26
    case background   // theme.oledSurface; used only as an occluding fill
}

public enum BusyTextAlign: Sendable { case left, center, right }

public enum BusyShape: Equatable, Sendable {
    case line(from: CGPoint, to: CGPoint, ink: BusyInk, weight: CGFloat)
    case path(points: [CGPoint], closed: Bool, stroke: BusyInk?, fill: BusyInk?)
    case circle(center: CGPoint, radius: CGFloat, stroke: BusyInk?, fill: BusyInk?)
    /// Radians, canvas convention (y-down, increasing angle turns clockwise).
    case arc(center: CGPoint, radius: CGFloat, start: Double, end: Double, ink: BusyInk)
    case ellipse(center: CGPoint, radii: CGSize, rotation: Double, fill: BusyInk)
    case quadCurve(from: CGPoint, control: CGPoint, to: CGPoint, ink: BusyInk)
    case rect(CGRect, stroke: BusyInk?, fill: BusyInk?)
    case roundedRect(CGRect, radius: CGFloat, stroke: BusyInk?, fill: BusyInk?)
    /// `at` is the alphabetic baseline point, as in the sketch's fillText.
    case text(String, at: CGPoint, size: CGFloat, align: BusyTextAlign, ink: BusyInk)
    case clipBegin(CGRect, radius: CGFloat)
    case clipEnd
}

public struct BusyDrawing: Equatable, Sendable {
    public static let sceneSize = CGSize(width: 240, height: 100)
    public static let miniSize  = CGSize(width: 96, height: 12)
    public let size: CGSize
    public private(set) var shapes: [BusyShape]
    public init(size: CGSize)

    // The pen. Named and ordered like the sketch's `pen()` (html:185) so a
    // port reads line for line. Default ink is .foreground, as in the sketch.
    public mutating func line(_ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat,
                              _ ink: BusyInk = .foreground, weight: CGFloat = 1)
    public mutating func poly(_ points: [CGPoint], _ ink: BusyInk? = .foreground,
                              closed: Bool = false, fill: BusyInk? = nil)
    public mutating func circle(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat,
                                _ ink: BusyInk? = .foreground, fill: BusyInk? = nil)
    public mutating func dot(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat, _ ink: BusyInk = .foreground)
    public mutating func arc(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat,
                             _ a0: Double, _ a1: Double, _ ink: BusyInk = .foreground)
    public mutating func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat,
                              _ ink: BusyInk? = .foreground, fill: BusyInk? = nil)
    public mutating func block(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat,
                               _ ink: BusyInk = .foreground)
    public mutating func roundedRect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat,
                                     _ r: CGFloat, _ ink: BusyInk? = .foreground, fill: BusyInk? = nil)
    public mutating func ellipse(_ x: CGFloat, _ y: CGFloat, rx: CGFloat, ry: CGFloat,
                                 rotation: Double, _ ink: BusyInk)
    public mutating func quadCurve(from: CGPoint, control: CGPoint, to: CGPoint, _ ink: BusyInk)
    public mutating func text(_ s: String, _ x: CGFloat, _ y: CGFloat, _ ink: BusyInk = .foreground,
                              size: CGFloat = 6, align: BusyTextAlign = .left)
    public mutating func clipped(to rect: CGRect, radius: CGFloat, _ body: (inout BusyDrawing) -> Void)

    /// Union of every shape's geometric box (text estimated at 0.6 em a
    /// character). Arcs are bounded by their swept range (both endpoints
    /// plus any axis extreme inside the sweep), not the full circle. Shapes
    /// between a clipBegin and its clipEnd are intersected with the clip
    /// rect. What the in-bounds tests check.
    public var bounds: CGRect { get }
    public var inks: Set<BusyInk> { get }
}
```

**Clipping.** The sketch draws into a 220 × 84 canvas, so anything off the
scene is cut at the canvas edge, which is the frame, not the 201.6 × 84
scene letterboxed inside it. The port does the same: `BusyCanvas` clips every
picture to the view's whole frame. The one scene whose content legitimately
leaves the scene, the scan's crate swap (it slides a crate 160 units
sideways, html:631-633), is drawn unclipped, so the sliding crates run on
into the margins beside the picture and are cut only at the frame's edge.
Every other picture and mini stays inside its unit space (§11), so for them
the frame clip and the scene clip are the same. (A unit-box clip on the scan,
plus a letterbox clip in the canvas, cut the sliding crates with a hard
vertical edge 9 pt inside a 220 × 84 frame and 19 pt a side inside the
220 × 76 band; the visual review caught it.)

`dot` is a filled circle and `block` is a filled rect. The sketch's
`translate` + `scale` (html:238, the note glyph) is not a primitive: the
glyph helper applies its offset and scale to the coordinates before emitting
them, so the drawing never carries a transform. `weight` multiplies the line
width, and exists for the note beam's ×2.2 (html:248).

**Glow rule** (from html:187-215): strokes glow, and so do fills that have no
stroke (`dot`, `block`, note heads). A fill under a stroke does not glow, a
`.background` fill never glows, and text never glows.

#### Timing and noise: `BusySignalTiming.swift`, `BusyNoise.swift`

```swift
public enum BusySignalTiming {
    public static let framesPerSecond: Double = 8
    /// floor(t × 8) / 8. NaN, infinite and negative read as 0.
    public static func quantized(_ t: TimeInterval) -> TimeInterval
    public static func step(_ t: TimeInterval) -> Int              // floor(t × 8)
    /// The sketch's blink (html:234): floor(t × hz) even = lit.
    public static func blink(_ t: TimeInterval, hz: Double = 2) -> Bool
    /// How long a finished picture blinks once you are looking at it.
    static let pictureBlinkDuration: TimeInterval = 8
    /// How long a finished job's screen must be on the glass to count as seen.
    static let seenAfter: TimeInterval = 1.5
    /// The redraw interval the view needs, or nil when the frame is still.
    public static func cadence(_ input: BusySceneInput) -> TimeInterval?
}

enum BusyNoise {
    /// The sketch's hash (html:222), ported exactly so finds, bar heights
    /// and re-read cells land where the sketch puts them.
    static func unit(_ i: Double) -> Double   // fract(sin(i·127.1 + 311.7) · 43758.5453)
    static func lerp(_ a: CGFloat, _ b: CGFloat, _ u: CGFloat) -> CGFloat
    static func polar(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat, _ a: Double) -> CGPoint
    static func ring(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat, segments: Int = 16) -> [CGPoint]
}
```

`cadence` answers as follows:

| State | Interval |
|---|---|
| running and not still | 1/16 s |
| a blink still pending (an unseen mini, or a picture inside its blink window) | 1/8 s |
| anything else | nil, so the view pauses |

The intervals are half the step they serve on purpose. `TimelineView`'s
animation schedule fires on display frames at least `minimumInterval` apart,
so 1/8 s on a 60 Hz display lands every 8/60 s (7.5 fps) and skips a step
about every 2 s; 1/2 s sampling a 2 Hz square wave aliases into lit-lit or
unlit-unlit pairs. Asking twice as often costs nothing extra on the glass,
because time is quantized in Core and `BusyCanvas` is `Equatable` on its
drawing, so a tick inside the same step redraws nothing.

#### Jobs and progress: `BusyJob.swift`

```swift
public enum BusyJobKind: String, CaseIterable, Sendable {
    case rip, secureRead, convert, scan, download, transfer
    public var label: String        // "CD-RIP", "SECURE READ", "CONVERT", "SCAN", "DOWNLOAD", "TRANSFER"
}

/// Core's mirror of the app's OLEDView (which Core cannot see), the same
/// way BrowserEmptyKind.Source mirrors LibrarySource. `other` is every
/// screen that never hosts a job: NOW, SYNC, SRCH, STAT, and compact.
public enum BusyScreen: String, CaseIterable, Sendable { case dub, conversion, scan, devices, other }

public enum BusyOutcome: Sendable, Equatable { case completed, cancelled, failed }

public struct BusyJobID: Hashable, Sendable { public let rawValue: Int }

/// Short words a scene prints: the codec on a converted file, the channel
/// on a cassette label. Uppercased and cut to 12 characters on init.
public struct BusyLabels: Equatable, Sendable {
    public var source: String?
    public var target: String?
    public init(source: String? = nil, target: String? = nil)
}

public struct BusySecureRead: Equatable, Sendable {
    public var trackOrdinal: Int          // 1-based
    public var trackCount: Int
    public var phase: SecureRipEngine.Phase
    public var phaseFraction: Double      // 0…1 within the phase
    public var rereads: Int               // this track
    public init(_ progress: SecureDiscRip.Progress)
    /// The disc-wide fraction. Moved here verbatim from DubPane.secureOverall
    /// (OLEDDisplay.swift:2008): 0.48 / 0.48 / 0.04 of a track per phase.
    public var overall: Double { get }
}

public struct BusyProgress: Equatable, Sendable {
    public var completed: Int             // ≥ 0
    public var total: Int?                // nil or ≤ 0 = unknown
    public var lossless: Bool             // convert only; decided by the running preset
    public var secure: BusySecureRead?
    /// 0…1, or nil while the total is unknown. NaN never escapes: inputs are
    /// sanitised on init and on every set, like MatrixInput.
    public var fraction: Double? { get }
    public init(completed: Int = 0, total: Int? = nil, lossless: Bool = false, secure: BusySecureRead? = nil)
    /// The same progress with new counts, keeping lossless and secure.
    public func with(completed: Int, total: Int?) -> BusyProgress
}
```

`fraction` is `secure.overall` when `secure` is set. Otherwise it is
`completed / total`, clamped, or nil when the total is unknown or zero.

#### The ledger: `BusyLedger.swift`

The ledger is the single answer to "what is running, what has finished, and
has anyone seen it". It is a value type, so every rule in §4 and §8 is a
Core test.

```swift
public struct BusyJobRecord: Equatable, Sendable, Identifiable {
    public let id: BusyJobID
    public internal(set) var kind: BusyJobKind      // changes once: secureRead → rip
    public let screen: BusyScreen
    public let labels: BusyLabels
    public let startedAt: Date                      // ordering and scene time; never reset
    public internal(set) var progress: BusyProgress
    public internal(set) var unitStartedAt: Date    // when progress.completed last changed
    /// When the current kind's units began counting: set by begin and reset
    /// by handOver. The rip's per-track average is measured from here, so a
    /// secure rip's long read never inflates the encode's estimate.
    public internal(set) var progressEpoch: Date
    public internal(set) var finishedAt: Date?
    public internal(set) var seenAt: Date?
    public var isRunning: Bool { finishedAt == nil }
}

public struct BusyLedger: Equatable, Sendable {
    public private(set) var records: [BusyJobRecord]   // in start order
    public private(set) var screen: BusyScreen         // what the glass shows now
    public private(set) var screenSince: Date
    public init(screen: BusyScreen = .other, at date: Date)

    /// Starts a job. Retires any finished record on the same screen (it was
    /// superseded) and any running record of the same kind on the same
    /// screen (a restart, e.g. a second dig cancelling the first).
    @discardableResult
    public mutating func begin(_ kind: BusyJobKind, on screen: BusyScreen,
                               labels: BusyLabels = .init(), progress: BusyProgress = .init(),
                               at date: Date) -> BusyJobID
    /// Ignored for unknown or finished ids, so a late progress hop that lands
    /// after the finish (risk §4 of the progress report) cannot revive a job.
    public mutating func update(_ id: BusyJobID, progress: BusyProgress, at date: Date)
    /// Secure read → rip, in place: same id, same startedAt, no finished
    /// state. Resets unitStartedAt and progressEpoch to `date`.
    public mutating func handOver(_ id: BusyJobID, to kind: BusyJobKind,
                                  progress: BusyProgress, at date: Date)
    /// .completed keeps the record as finished; .cancelled and .failed remove
    /// it at once (the app already reports those its own way).
    public mutating func finish(_ id: BusyJobID, _ outcome: BusyOutcome, at date: Date)
    /// The glass changed screen. Retires seen records whose screen it left.
    public mutating func show(_ screen: BusyScreen, at date: Date)
    /// Marks finished records seen once their screen has been on the glass
    /// for `seenAfter` since max(finishedAt, screenSince). Returns the next
    /// date, strictly after `date`, at which settling could change something
    /// (a pending seen mark, or the end of a picture's blink window), or nil.
    /// Never a date at or before `date`: a past date would make the view
    /// model's settle task re-fire at its 0.05 s floor forever and republish
    /// the whole LibraryViewModel at ~20 Hz.
    public mutating func settle(at date: Date) -> Date?

    public func record(_ id: BusyJobID) -> BusyJobRecord?
    /// A running job of `kind` on `screen`. What the progress sinks feed.
    public func running(_ kind: BusyJobKind, on screen: BusyScreen) -> BusyJobRecord?
    /// What a pane draws: the newest running record on that screen, else the
    /// newest finished, unretired one.
    public func picture(on screen: BusyScreen) -> BusyJobRecord?
    /// The frame inputs for a record at `date`. `still` is Reduce Motion.
    public func sceneInput(for record: BusyJobRecord, at date: Date, still: Bool) -> BusySceneInput
}
```

#### Rail and picture layout: `BusyRail.swift`, `BusyPictureLayout.swift`

```swift
public struct BusyRailLayout: Equatable, Sendable {
    public var shown: [BusyJobID]     // 0…2, in start order
    public var overflow: Int          // the "+N"; 0 = no label
    public var width: CGFloat         // what the cluster occupies, trailing padding included
}

public enum BusyRail {
    static let maxShown = 2
    static let miniWidth: CGFloat = 96, miniHeight: CGFloat = 12
    static let spacing: CGFloat = 12, trailing: CGFloat = 14     // html:76
    /// Every record that belongs on the rail now: not on the glass's current
    /// screen, and either running or finished but not yet seen.
    public static func entries(_ ledger: BusyLedger) -> [BusyJobRecord]
    /// As many minis as fit in `available` (most 2), plus "+N" for the rest.
    /// If even "+N" won't fit, the cluster is empty rather than clipped.
    public static func layout(_ entries: [BusyJobRecord], available: CGFloat,
                              overflowLabelWidth: CGFloat) -> BusyRailLayout
}

public enum BusyPictureLayout {
    static let maxSize = CGSize(width: 220, height: 84)
    static let minimumHeight: CGFloat = 40     // below this the scene is unreadable
    static let readoutClearance: CGFloat = 174 // a 150 pt readout plus the 24 pt row gap
    /// The picture's frame inside a pane's top band, or nil when it doesn't
    /// fit. `leading` is OLEDCells.textLeading(ofColumn: 2, in: width).
    public static func frame(bandSize: CGSize, leading: CGFloat, topInset: CGFloat) -> CGRect?
}
```

#### Scenes: `BusyScenes.swift`, `BusyGlyphs.swift`, `Scenes/*.swift`

```swift
public struct BusySceneInput: Equatable, Sendable {
    public var progress: BusyProgress
    public var labels: BusyLabels
    public var time: TimeInterval         // quantized seconds since start; frozen at finish (still or not); keyTime when still and running
    public var unitTime: TimeInterval     // quantized seconds since the current unit began
    public var unitFraction: Double       // estimated 0…0.95 inside the current unit (see §3, rip)
    public var finished: TimeInterval?    // quantized seconds since finish; nil while running
    public var markLit: Bool              // the finished mark (check, OK, DONE) is lit this frame
    public var still: Bool                // Reduce Motion
    public var blinking: Bool             // a blink is still pending (drives cadence)
    public var step: Int { BusySignalTiming.step(time) }
    public var isFinished: Bool { finished != nil }
    /// Public memberwise init, so the App-target snapshot harness (which
    /// imports Core without @testable) can build inputs directly.
    public init(progress: BusyProgress = .init(), labels: BusyLabels = .init(),
                time: TimeInterval = 0, unitTime: TimeInterval = 0, unitFraction: Double = 0,
                finished: TimeInterval? = nil, markLit: Bool = true,
                still: Bool = false, blinking: Bool = false)
}

public enum BusyScenes {
    public static func picture(_ kind: BusyJobKind, _ input: BusySceneInput) -> BusyDrawing   // 240 × 100
    public static func mini(_ kind: BusyJobKind, _ input: BusySceneInput) -> BusyDrawing      // 96 × 12
    /// The scene time a still (Reduce Motion) frame is drawn at.
    public static func keyTime(_ kind: BusyJobKind) -> TimeInterval
}
```

Each job is its own file under `Scenes/`: `RipScene`, `SecureReadScene`,
`ConvertScene`, `ScanScene`, `DownloadScene` and `TransferScene`. Each
exposes `static func picture(_:) -> BusyDrawing` and
`static func mini(_:) -> BusyDrawing`. `BusyGlyphs` holds what more than one
scene shares:

- `note`, which is `noteGlyph` (html:237)
- `disc` (html:253)
- `miniTrack`, the eight dashes plus the walking packet (html:268)
- `miniEndInk` (html:275)

Scenes are **stateless**: any frame is a pure function of its input. That is
the opposite of `MatrixAnimation`, and it is deliberate. Every frame is
reproducible for snapshots and tests, and a hidden window coming back needs
no catch-up.

### 2.2 App

| File | What |
|---|---|
| `UI/Carbon/Header/BusySignals/BusyCanvas.swift` | `BusyInkPalette` and `BusyCanvas`, the one renderer |
| `UI/Carbon/Header/BusySignals/BusyPictureView.swift` | the pane picture: a `TimelineView` around `BusyCanvas` |
| `UI/Carbon/Header/BusySignals/BusyRailMinis.swift` | the rail cluster: mini buttons plus "+N" |
| `UI/Carbon/Library/LibraryViewModel+BusySignals.swift` | the glue (§2.3) |
| `UI/Carbon/Header/OLEDDisplay.swift` | modified: scaffold picture slot, panes, rail, notice plate |
| `UI/Theme/CarbonTheme.swift` | modified: `monochromeGlass` also clears `meterHotOverride` |
| `UI/Carbon/Library/LibraryViewModel.swift` and the job files | modified: stored ledger, `didSet` hooks, stamp sites (§3) |
| `AppDelegate.swift` | modified: DEBUG `CRATEDIGGER_BUSY` hook |

**`BusyInkPalette(theme: CarbonTheme)`** maps the inks:

| Ink | Colour |
|---|---|
| foreground | `theme.oledForeground` |
| cool | `theme.cyan` |
| hot | `theme.meterHot` |
| dim | `theme.oledForeground.opacity(0.26)` |
| background | `theme.oledSurface` |

It reads the environment's theme, never the `ActiveOLEDPalette` global, so
snapshots are deterministic.

**`BusyCanvas(drawing:lineWidth:)`** is one `Canvas`.

- **Fit.** `k = min(w / size.width, h / size.height)`, centred and
  letterboxed, never stretched (html:943). A 220 × 84 frame draws the scene
  at 201.6 × 84.
- **Points, not units.** Geometry is transformed into view points *before*
  stroking. Line widths (1.15 pt picture, 0.95 pt mini, html:950/962) and the
  glow radius (`glowRadius = 0.75` pt, tuned by snapshot in Task 14) are therefore in
  screen points at any scale. Caps and joins are round.
- **Order is kept.** Background fills occlude, so shapes are never regrouped
  by ink. Consecutive shapes that share ink, style and glow are batched into
  one `Path`. A glowing batch is drawn in a `drawLayer` with
  `.shadow(color: ink, radius: glowRadius)`.
- **Text.** `CarbonFont.mono(size × k, weight: .semibold)`, placed so that
  `at` is the baseline (the top sits at baseline − the font's ascender).
- **Clip.** `clipBegin` / `clipEnd` push and pop a rounded-rect clip with
  `context.drawLayer { $0.clip(to:) }`. The whole drawing is also clipped to
  the view's frame (not the letterboxed `size × k` rect), as the sketch's
  canvas edge did (§2.1, Clipping).
- **Equatable.** `BusyCanvas` is `Equatable` on `(drawing, lineWidth)` and is
  used with `.equatable()`, so a timeline tick that lands in the same 1/8 s
  step produces an equal drawing and no redraw.
- **Background fills on the real glass.** The OLED's background is not flat:
  `OLEDDisplay` (:107-124) lays a diagonal gradient (white 0.04 → clear →
  `oledSurfaceShade`, black 0.28 on Carbon) over `oledSurface`. A plain
  `oledSurface` occluder can therefore read as a slightly lighter patch,
  most on pale LCD-style themes. The sketch's glass was flat #0A0A0A, so it
  never showed this. **Decision point, Task 14:** the contact sheet renders
  cells over the real glass background (gradient included) on Carbon and on
  one pale theme. If patches are visible, the fallback is for `BusyCanvas`
  to resolve `.background` to `oledSurface` composited with the gradient
  sampled at the picture's centre (one constant per picture). The outcome
  is recorded in `BusyCanvas`'s doc comment.
- **Accessibility.** `accessibilityHidden(true)`; the pane's text already
  says what is happening.

**`BusyPictureView(recordID:)`** reads `model.busy`.

- It wraps `BusyCanvas` in
  `TimelineView(.animation(minimumInterval: cadence ?? 1, paused: paused))`,
  with `cadence` from §2.1's table (1/16 s running, 1/8 s blinking).
- `paused` is true when `!AppVisibility.shared.isVisible` (observed), or
  when `cadence == nil`.
- Each tick builds its input with
  `ledger.sceneInput(for:at: context.date, still: reduceMotion)` and draws
  `BusyScenes.picture`.

`TimelineView(.animation(minimumInterval:paused:))` is macOS 12+ and the
package targets 13. It replaces a `MeterDriver`-style object because it
pauses declaratively, and there are at most three of these views on the
glass.

### 2.3 View-model glue: `LibraryViewModel+BusySignals.swift`

Stored properties, which must live in `LibraryViewModel.swift`:

```swift
// Internal setter, not private(set): every mutator lives in
// LibraryViewModel+BusySignals.swift, and Swift's private(set) only lets the
// declaring file write it. Views only read it; the extension is the writer.
@Published var busy = BusyLedger(at: Date())
var busySettleTask: Task<Void, Never>?
var busyChannelCancellables: Set<AnyCancellable> = []
/// The record each safety-netted channel armed at its false → true edge.
var busySafetyArmed: [BusyChannel: BusyJobID] = [:]
var streamDownloadBusyJob: BusyJobID?
var sacdBusyJob: BusyJobID?
```

In the extension:

```swift
extension OLEDView { var busyScreen: BusyScreen }          // .dub/.conversion/.scan/.devices, else .other
extension BusyScreen { var oledView: OLEDView? }            // nil for .other
enum BusyChannel: Hashable { case conversion, sync }       // the safety-netted channels

extension LibraryViewModel {
    /// What the glass shows: compact always shows NOW.
    var busyVisibleScreen: BusyScreen { isCompactPlayer ? .other : oledView.busyScreen }

    @discardableResult
    func beginBusyJob(_ kind: BusyJobKind, on screen: OLEDView,
                      labels: BusyLabels = .init(), lossless: Bool = false) -> BusyJobID
    func endBusyJob(_ id: BusyJobID?, _ outcome: BusyOutcome)
    func handBusyJob(_ id: BusyJobID?, to kind: BusyJobKind)
    func busyPicture(on screen: OLEDView) -> BusyJobRecord?
    /// A mini was clicked: expand first in compact (CompactCommandPolicy says
    /// .selectDisplay expands first), then switch to the job's screen.
    func showBusyJob(_ id: BusyJobID)
    /// From oledView.didSet and playerLayout.didSet.
    func noteBusyScreenChanged()
    /// Called once from init beside wirePlaybackBindings(), after oledView
    /// and playerLayout have been restored. Seeds the ledger's screen.
    func wireBusySignals()
}
```

**Seeding the screen at launch.** `init` restores the saved screen with
`oledView = view` (LibraryViewModel.swift:1454-1456) and `playerLayout` from
`launchLayout`, and Swift runs no `didSet` for a class's own stores in its
initializer. So `noteBusyScreenChanged` never runs at launch, and without a
seed the ledger would believe the glass shows `.other`. After relaunching
onto CNVRT, DUB, SCAN or DEV, a job started there would then get a mini on its
own rail, against the README's "never shown on the job's own screen", and
finishing there would never count as seen. A job that never writes
`oledView` (a Finder-drop scan through `importDroppedURLs`, :4011-4053) is
the easiest way to hit it. `wireBusySignals()` therefore ends with
`busy.show(busyVisibleScreen, at: Date())`.

`noteBusyScreenChanged` calls `busy.show(busyVisibleScreen, at: Date())` and
then reschedules the settle task. The settle task is one `Task` that sleeps
until the date `settle` returns, settles, and reschedules itself. It is also
rescheduled after every `begin`, `finish` and `show`.

`wireBusySignals` subscribes to the four published progress channels and
turns each change into `busy.update(...)` on the matching running record:

| Channel | Feeds the running record of | Mapping |
|---|---|---|
| `$conversionProgress` | `rip`, `convert` or `download` on any screen, or `transfer` on `.conversion` (the BUSY guards make these mutually exclusive) | `.with(completed: jobsCompleted, total: jobsTotal)` |
| `$secureRipProgress` (non-nil) | `secureRead` | `BusyProgress(secure: BusySecureRead(p))` |
| `$scanProgress` | `scan` | `.with(completed: filesProbed, total: totalCandidates)` |
| `$deviceSyncProgress` | `transfer` on `.devices` | `.with(completed: completed, total: total)` |

For the download, `jobsTotal` is already 100 and `jobsCompleted` is the
percent (`+StreamDownload.swift:71`), so one mapping serves all of them.

**Safety net (conversion and sync channels).** The conversion and sync sinks
also watch their channel's `isRunning`.

- **Armed per record.** At the channel's false → true edge, the sink stores
  the id of the matching running record in `busySafetyArmed[channel]`.
- **Fires per record.** At the true → false edge it waits 3 s. If the armed
  record is still running and the channel is still idle, the sink ends it
  as **`.failed`**, which removes it silently, and logs
  `AppLog.ui.warning("Busy job \(kind) ended by the safety net: a finish site is missing")`.
- **Why `.failed`, not `.completed`.** A missed site is as likely to be a
  failure path as a success (the download's `catch`, §3.1, was one). Ending
  it `.completed` would turn every missed failure into a blinking success
  animation. Removed plus logged is honest either way.
- **Why armed per record.** `conversionProgress` carries several jobs, but
  the BUSY guards (§10) make them exclusive, so the record running at the
  true edge is the one that edge belongs to.
- It is edge-triggered, so a record with no channel (the DEBUG simulation)
  is never touched.

**No safety net on `scanProgress`.** Unstamped work shares that channel and
can run beside a stamped dig: album moves (:4759/4776), copy-to-library
(:4932/4978), the Adding → crate status (:5034-5050), library and index moves
(:5211/5253, :5319/5349) and consolidate (:5389/5416). Any of them going idle
while a dig runs would end the dig early with a false warning. For scan, the
sink only **logs** (it never ends anything) when a scan record is still
running 30 s after the channel went idle and stayed idle. A missed scan finish
is then retired by the next scan's `begin`. Those writers' counts also feed the
running dig's mini dashes while they overlap. That is accepted: it lasts only
as long as the overlap, and the picture is clock-driven.

Secure read has no safety net either: its phase ends in exactly two places,
both stamped.

## 3. Data flow per job

**Jobs are stamped explicitly at the sites that start and finish them.**
Nothing is inferred from `oledView`, `pendingDeviceConversion` or
`downloadingStreamID`. As the progress report showed, `conversionProgress`
carries five different jobs, and `scanProgress` carries eight different
kinds of work. Each stamp is a line or two:

```swift
let busyJob = beginBusyJob(.convert, on: .conversion, labels: …, lossless: preset.outputFormat.isLossless)
…
endBusyJob(busyJob, outcome)
```

### 3.1 Start and finish sites

| Job | Start site | Screen | Finish site and outcome |
|---|---|---|---|
| **Secure read** | `ripCD` when `secure` is set, right after `secureRipCancellation = cancellation` (`LibraryViewModel.swift:~2604`) | DUB | Read done (:~2647): `handBusyJob(id, to: .rip)`. `SecureReadFailure`: `.failed`. `CancellationError`: `.cancelled`. |
| **CD rip** | `ripCD` when not secure, right after `conversionProgress = …` (:2584). Also a secure rip after the handover. | DUB | Final `MainActor.run` (:2739): `wasCancelled` → `.cancelled`; `fails` non-empty → `.failed`; else `.completed`. The `catch` block (:2763): `.cancelled` or `.failed`. |
| **SACD import** | `importSACDISO` (`+SACDImport.swift:39`), stamped as `.rip`, since DUB already draws it as one. It gains the missing BUSY guard first (`guard !isConversionRunning else { return showOLEDNotice("BUSY") }`), like `requestCDRip` and `downloadStream`: today it can start beside a convert or a rip and overwrite their `conversionProgress`, and `begin` would retire a running `.rip` on DUB. | DUB | `finishSACDImport(alert:)` gains an `outcome` parameter that its callers pass. |
| **Convert** | `runConversionQueue` (`+Conversion.swift:732`). Covers the Patch Bay convert and the device pre-convert (`convertQueuedTransfers`), both of which really are conversions. | CNVRT | After the terminal snapshot (:777): `cancelled > 0` → `.cancelled`; `succeeded == 0 && failed > 0` → `.failed`; else `.completed`. |
| **Transfer (copy)** | `runCopyTransferQueue` (`+ExternalDeviceTransfer.swift:375`) | CNVRT, where the app already shows it | After the terminal snapshot (:425), with `let wasCancelled = conversionTask?.isCancelled ?? false` captured **before** `conversionTask = nil`: `wasCancelled` → `.cancelled`; all failed → `.failed`; else `.completed`. The loop counts cancelled items as failures (:388-390), so without the flag a cancelled partial copy would end `.completed` and blink a check. |
| **Transfer (sync)** | `syncQueuedTransfers` (`+DeviceSync.swift:289`) | DEV | After the terminal snapshot (:451): `failed == total` → `.failed`, else `.completed`. It cannot be cancelled. |
| **Download** | `downloadStream` (`+StreamDownload.swift:70`) | DUB | Two end paths. (1) `streamDownloadEnded`, **before** `endStreamDownloadUI()`: success → `.completed`; `streamDownloadCancelled` → `.cancelled`; else `.failed`. (2) The `catch` around `StreamDownloader.download(...)` (:93-96), which calls `endStreamDownloadUI()` directly and never reaches `streamDownloadEnded`: `.failed`, before `endStreamDownloadUI()`. |
| **Scan** | `loadFolders` when `!isRestore` (:2060), `selectDevice`'s catalog scan (:2473), `importDroppedURLs` (:4016) and `addURLsToCrate` (:4881) | SCAN | The `MainActor.run` that writes each one's terminal snapshot: `.completed`. Nothing found (`importDroppedURLs`'s empty branch, an empty `handleImport`, or an `addURLsToCrate` drop that scans no files) → `.failed`. An empty device catalog scan stays `.completed`: a device with no music on it is a legitimate result, not a failed scan. A superseded scan is retired by the next `begin`. |

These are **not** stamped, so they play no scene:

- the launch-restore scan (housekeeping the user did not start)
- remote sync
- album, library and index moves
- consolidate
- copy-to-library
- the "Adding → crate" status
- Fix device art

**Labels:**

- **Convert:** `source` is the batch's most common source extension,
  uppercased (FLAC, WAV…). `target` is the output format's short name (MP3,
  AAC, ALAC, FLAC, WAV, AIFF).
- **Download:** `source` is the stream's channel, or "STREAM" when there is
  none. It goes on the cassette label.
- **Other jobs:** no labels.

### 3.2 What feeds each scene element

Notation is `input.*` from `BusySceneInput`. "Clock" means `input.time`, so
the element moves at 8 fps whatever the progress is.

**CD rip** (html:337-391)
- **Disc angle:** clock × 4.7 rad, frozen at finish.
- **Notes:** a new note every 0.6 s, flight time 2 s, from the clock.
- **File fill:** `unitFraction`. A serial rip reports whole tracks only, so
  the fill inside the current track is estimated as
  `min(0.95, unitTime / averageTrack)`. `averageTrack` is
  `(unitStartedAt − progressEpoch) / completed`, or 30 s before the first
  track finishes. It is measured from `progressEpoch`, not `startedAt`:
  `handOver` keeps `startedAt` from the start of a secure read, which can take
  tens of minutes, and an average that included it would leave the file
  nearly empty for the whole encode. The ledger computes it in Core, and it
  is tested (including secureRead → handOver → first track complete).
- **The file at fill 0** still shows one cool line, as the sketch's loop
  does (it starts at the bottom line, html:375-376 and html:284).
- **"Tnn" label:** `min(completed + 1, total)`. The clamp keeps the label
  from reading one past the disc in the moment `completed` reaches `total`
  before the finish is stamped; the sketch never shows a label past the
  total while running.
- **Stack:** `shown(k)` slabs, where `shown(k) = total > 5 ? ceil(k × 5 / total) : k`,
  at `slabY(j) = 85 − 5j`. The cap is **5**, the sketch's own maximum
  (html:344 `total = 5`). A sixth slab (`slabY(5) = 60`, y 60-63, x 198-226)
  would hold the check's vertex (210, 61), so it would collide with the
  finished mark.
- **Falling slab:** only when a completion raises the shown count
  (`shown(k) > shown(k − 1)`), while `unitTime < 0.5`. It lands at
  `slabY(shown(k) − 1)`, and `shown(k) − 1` static slabs are drawn meanwhile.
  A completion that leaves the shown count unchanged (20 tracks: k = 1 and
  k = 2 both show 1) drops nothing.
- **Finished:** disc stopped, file reads OK, check blinks over the stack.

**Secure read** (html:393-449)
- **Track band:** `trackOrdinal − 1` of `trackCount`. At most 12 dim band
  rings are drawn; track *k* maps to band ⌊k × bands / trackCount⌋.
- **Pass:** `phase`. `.pass1` draws outlines, `.pass2` draws solids. `.retry`
  draws the pass 2 map full (all 60 cells solid), with the sled label "RE".
- **Sled radius:** `phaseFraction` across the band, in every phase. In
  `.retry` that fraction is `settled / retryList.count`, so the sled walks the
  band as doubtful sectors settle.
- **Filled cells:** `phaseFraction × 60` on `.pass1` and `.pass2`; 60 on
  `.retry`.
- **Orange cells appear in `.retry` only.** `SecureRipEngine` reports
  `rereads: 0` for every pass 1 and pass 2 progress (SecureRipEngine.swift:168,
  :174, :210, :222). It only counts in the retry loop, and there it counts
  one per sector per attempt (:241), up to 20 attempts per sector, so it is
  not a cell count. Mapping: in `.retry`, the first `min(rereads, 6)` cells,
  taken in the order of `BusyNoise.unit(k·100 + i)` ascending, are drawn hot.
  The cap of 6 (10 % of the map) is about the sketch's density (≈ 5 % of
  cells orange, html:406/444), so a bad sector reads as a few orange cells,
  not a map that floods orange. A clean disc never enters `.retry` and never
  shows orange, which is the truth. Pass 2 never draws orange.
- **Spindle tick:** clock × 6.2 rad.
- **Finished:** full map, OK blinks.

**Convert** (html:451-528)
- **Belt, press and item:** all from the clock (2.4 s per file). The batch's
  count is in the readout, not the picture.
- **Lossy squash or lossless re-box:** `progress.lossless`, which comes from
  the running preset (`preset.outputFormat.isLossless`), not from
  `isLosslessSelectedFormat`.
- **Labels on the file:** `labels.source` before the press and
  `labels.target` after it. If a label is missing, nothing is printed.
- **Finished:** press parked, OK blinks.

**Scan** (html:530-657)
- **Crates, flips and finds:** cyclic, from the clock. 12 flips of 0.375 s
  plus a 0.5 s swap make a 5 s crate. Dividers cycle A–F → G–M → N–S → T–Z →
  A–F…. A record's id is `crateCounter × 12 + i`, so every lap has different
  finds.
- **Why not progress:** a scan's total is nil for its first phase, and in a
  multi-folder dig it can drop when the scanner moves on (progress report
  §3), so crates tied to the fraction would stall or run backwards. Progress
  drives the mini's dashes and the pane's readout instead.
- **Picked pile:** finds among the records flipped so far, at most 8 shown.
  The top one shows the cover of the last find.
- **Finished:** the crate on screen at the finish stays (README: "Last crate
  stays"). With `counter = floor(time / crateT)` at the frozen `time`, that is
  crate `counter`, or `counter + 1` when `time` falls inside a swap (the
  incoming crate). Its divider is `DIVIDERS[crate % 4]`, `f = 12` (every
  record flipped, so the flipped ones lean on the wall), phase 0. The pile
  counts finds among ids `< (crate + 1) × 12`, i.e. the whole finished crate,
  as the sketch's finished pile counts every record (html:641 with c = last,
  f = N). DONE blinks. The spec used to say "the T–Z crate", which is the
  sketch's last crate only because the sketch stops after four; in the cyclic
  port it would make the crate jump at the finish.
- **Off-scene crates:** the swap slides crates up to 160 units sideways
  (html:631-633). They are drawn unclipped and cut by the canvas's frame,
  not the scene rect, so they slide on into the margins as in the sketch
  (§2.1, Clipping).

**Download** (html:659-727)
- **Rings, data blocks and hub spin:** from the clock.
- **Take-up and supply packs:** `fraction` (0 if unknown).
- **Label:** `labels.source`.
- **Finished:** hubs stopped, and the label reads DONE in steady hot. The
  picture has **no blinking element**, in the sketch (html:702, no `blink`
  call) and in the README ("Hubs stop, label reads DONE"). `markLit` therefore
  does not change the download picture; its mini still blinks through
  `miniEndInk`.

**Transfer** (html:729-771)
- **Laptop row, packets and sign:** from the clock.
- **Finished:** the sign becomes a blinking check.

**Minis** (html:267-335; one per scene line)
- **Dashes:** ⌊fraction × 8⌋ lit cool, or 0 while the fraction is unknown.
  The packet walks `step % 8` while running. Finished lights all 8.
- **Destination ink:** `miniEndInk`, which is hot while
  `isFinished && markLit`, otherwise foreground.
- **Per-scene details, as in the sketch:**
  - rip: the file fill is `unitFraction` (one cool line at fill 0, four at
    0.95, html:284)
  - secure: grid cells are ⌊phaseFraction × 4⌋
  - scan: the crate's three frames, `step % 3`
  - download: hub spin
  - convert: lossy or lossless

## 4. Rail minis

- **Placement.** A fixed-size `HStack(spacing: 12)` sits between `RailLive`
  and the annunciators (OLEDDisplay.swift:172-177), with `.padding(.trailing, 14)`.
  Each mini is `.frame(width: 96, height: 12)`.
- **The rail's height never changes.** The rail is as tall as its text line,
  which is 11.88 pt for JetBrains Mono at 9 pt and about 9.8 pt for Llama '97's
  PixelOperatorMono8 (measured hhea metrics), so a 12 pt mini in the flow would
  make the rail grow, by about 2.2 pt on Llama, whenever a mini appears, and
  the pane and cell rail would jump each time. The cluster therefore occupies
  a **zero-height slot**: `Color.clear.frame(width: layout.width, height: 0)`
  in the HStack reserves the width, and the cluster is drawn in that slot's
  `.overlay(alignment: .center)`, unclipped. It contributes width to the rail
  and nothing to its height, and it is centred on the text line like the
  annunciators.
- **Which minis.** `BusyRail.entries(busy)` gives every record not on the
  glass's current screen, running or finished-unseen, in start order. Start
  order is stable: nothing reshuffles when a job finishes.
- **How many.** `BusyRail.layout(entries, available:, overflowLabelWidth:)`.
  - `available` is the rail width, minus the annunciator block's measured
    width (a background `GeometryReader` and a preference key), minus
    `RailLive`'s floor.
  - That floor is the part of `RailLive` that never shrinks, plus its 14 pt
    trailing. It is **measured, not assumed**: `RailLiveContent` lays out a
    hidden copy of its fixed parts (the clock or the "NOW PLAYING" label,
    the "NOW PLAYING:" prefix when a track is loaded, the 12 and 6 pt gaps,
    and the title cut to its "…") and reports the width under
    `RailLiveFloorKey`; `AnnunciatorRailRow` adds the 14 pt. The floor counts
    the title even while a notice hides it, so a notice never makes a mini
    blink in and out.
  - The fixed 86 / 178 pt first planned here left out the 1.08 tracking and
    a theme's mono. CoreText, with tracking: on JetBrains Mono, ≈ 85 pt on
    NOW ("NOW PLAYING" 71.3 + 14) and ≈ 184 pt elsewhere (clock 67.4 + 12 +
    "NOW PLAYING:" 77.8 + 6 + "…" 6.5 + 14). On Llama '97's
    PixelOperatorMono8, a full em per glyph, ≈ 125 pt on NOW (110.9 + 14)
    and ≈ 270 pt elsewhere (107 + 12 + 121 + 6 + 10 + 14), with an
    annunciator block of ≈ 532 pt. The old 178 let a mini in at an 838 pt
    rail and pushed the clock and ON AIR ≈ 32 pt past each side of the glass.
    `BusyRailMinisTests.testTheRailRowNeverOverflowsTheGlass` lays out the
    real row in both fonts at 838–1238 pt with one to three jobs.
  - The title keeps whatever is left, so it is the title that gives way,
    never the clock.
  - At the 1200 pt minimum window off NOW this gives two minis and no title
    with one job over (≈ 26 pt), or one mini plus "+1" with three. That is
    on Carbon; on Llama '97 the same rail has ≈ 22 pt to spare off NOW and
    shows no minis until the window is ≈ 90 pt wider (on NOW, ≈ 181 pt: one
    mini, or "+N" beside it once the window allows).
- **"+N"** is mono 8 bold in `oledFGo(0.5)` (html:79).
- **Finished minis.** The destination blinks hot at 2 Hz until the job is
  seen (§8, "seen"). A seen job leaves the rail.
- **Clicking a mini.** Each mini is a `Button(.plain)` that calls
  `model.showBusyJob(id)`. In compact that is
  `expandToFull()`, then `oledView = screen`, matching
  `CompactCommandPolicy.availability(.selectDisplay, in:) == .expandsFirst`.
  It writes `oledView` like the screen keys do, so it persists
  `savedOLEDView` and drops an armed `pendingCDRip` exactly as pressing DUB
  would. That is accepted as the same act.
- **Hit-testing.** The top ≈ 6 pt of the rail is inside the transparent
  titlebar strip. Each button gets `.background(WindowDragGuard())`, and its
  `contentShape` is the mini's full 96 × 12 frame. This is verified by hand
  in Task 18, and if the top band still drags the window, the bottom half
  always clicks.
- **Accessibility.** Label "<label>, <n> percent" ("CD-RIP, 40 percent"), or
  "<label>, finished". Hint "Shows the <SCREEN> screen".
- **Notices.** `oledNotice` stays a centred overlay but gains a backing plate:
  `theme.oledSurface`, with 6 × 2 pt padding. It occludes whatever it lands
  on, minis included. The alternative, hiding the minis while a notice is
  up, would blink them on every volume nudge and every FIX TAGS tick.

## 5. Picture placement per pane

`OLEDPaneScaffold` gains `picture: BusyJobRecord? = nil`. **With nil, its
body is today's code path unchanged**, so every idle body stays
pixel-identical.

With a record, the top part (headline row, spacer, ticker) is laid out the
way `NowPlayingScaffold` lays out its band:

- **The band.** A `GeometryReader` wraps the whole pane and *measures* the
  band: what is left above the 48 pt cell rail (`OLEDCells.footprint`) and
  the 6 pt top inset, ≈ 85 pt at the default 170 pt header. The band is
  never imposed on the content: the text column is the same stack as the
  plain pane's, with the picture an overlay on it, so text taller than the
  band overflows as today (rail pushed down, clipped at the glass) and never
  prints over the rail.
- **Where the picture goes.** `BusyPictureLayout.frame(bandSize:leading:topInset:)`
  places it:
  - leading at `OLEDCells.textLeading(ofColumn: 2, in: width)`, so the
    glass keeps one set of verticals;
  - top at `NPTitles.capTopInset()`, like the matrix;
  - size `min(220, …) × min(84, band − topInset)`.

  At the defaults that is 220 × 76, and the scene draws at k = 0.76.
- **When it is dropped.** `frame` returns nil when the height is under
  40 pt, or when the readout would have less than 174 pt to the picture's
  right. That covers a drag-shrunk window and a short theme header. The
  scaffold then falls back to today's body.
- **The headline, readout and ticker.**
  - **Headline:** an explicit `.frame(maxWidth: frame.minX − 2 × OLEDCells.cellPadding, alignment: .leading)`,
    so its text stops at the rail's own gutter before the picture. Not
    trailing padding: the readout sits in the same `HStack`, so a padding of
    `width − pictureLeading` would subtract the readout and the 24 pt gap a
    second time (at 838 pt with a 150 pt readout the headline would get
    ≈ 151 pt instead of ≈ 325).
  - **Readout:** keeps its place at the right, bottom-aligned with the
    headline as today.
  - **Ticker:** framed to the same `maxWidth` as the headline, and
    `DSPTicker` drops its meta while a picture is *laid out* beside it (the
    `busyPictureShown` environment value, set from the frame actually drawn,
    not from the record). `DSPTicker`'s prefix
    and meta are `.fixedSize()` (:810-840), so they cannot shrink. In
    `ConversionPane.previewBody` (:1296) the prefix "PREVIEW · 01 / 12"
    (≈ 119 pt) plus the template meta "TEMPLATE · {ARTIST}/{YEAR} {ALBUM}"
    (≈ 241 pt) plus spacing come to ≈ 384 pt, more than the ≈ 325 pt left
    beside the picture, and that body still shows a finished convert picture.
    The path between them truncates from the head, as it does today. The
    meta returns as soon as the picture leaves, including when it is dropped
    for room.
  - **Below the window minimum** (a drag past 1200 pt) the text column can
    narrow to ≈ 260 pt, less than a long fixed-size prefix such as
    "SECURE READ · TRACK 10/14 · RE-READ · 45%". The headline and the ticker
    are therefore masked at the gutter: a part that cannot shrink is cut
    there rather than drawn under the picture.
- **Identity.** The picture is an overlay keyed by `record.id`. DubPane's
  1 s `TimelineView` re-evaluates its content every second without
  restarting the picture's own timeline.

**Which bodies pass a picture.** Every body of a job screen passes
`model.busyPicture(on: <its screen>)`. Whether a picture shows is then the
ledger's decision alone: while the job runs, and after it finishes until it
is seen and the screen is left.

| Pane | Bodies |
|---|---|
| DubPane | `downloadingBody`, `rippingBody`, `secureReadingBody`, `insertedBody`, `emptyBody` |
| ConversionPane | `runningBody`, `previewBody` |
| ScanPane | its one body |
| DevicesPane | `syncBody`, `deviceBody`, `emptyBody` |

On DEV, `DevGlyph` stays in the headline; the narrower headline column
absorbs it.

The pane's own words do not change: titles, readouts and tickers stay as
they are (see §11). After a finished download, DUB shows its idle body with
the finished cassette beside it.

**Removing the jump to NOW.** Four sites force `oledView = .nowPlaying` when
a job ends. Without that change, DUB's finished frames could never be seen:

- `LibraryViewModel.swift:2741` and `:2767` (rip)
- `+StreamDownload.swift:135` (download)
- `+SACDImport.swift:117` (SACD)

The design removes all four, so the user stays on DUB. A successful rip
still moves to SCAN, because `loadFolders` switches the glass for the import
it chains (:2756). The rip's finished state is then picked up by its mini
(§8, chained jobs). **This is a behaviour change for the user to confirm.**
It is listed in §15, and the plan does not remove these sites until the user
has signed off.

## 6. Timing

- **8 fps.** Core quantizes every time input to 1/8 s, so two dates inside
  one step give equal inputs, equal drawings and no redraw. The `TimelineView`
  asks for at most one frame per `cadence`: 1/16 s running, 1/8 s for a
  blink, and paused when still (§2.1 says why the intervals are half a step).
- **Visibility gate.** `paused` includes `!AppVisibility.shared.isVisible`,
  the same app-level occlusion signal that halts `MeterDriver` and the
  spinning record. Because scenes are stateless, coming back draws the
  current frame directly; nothing replays.
- **Reduce Motion** (`@Environment(\.accessibilityReduceMotion)`). Every view
  draws a still frame:
  - while running, `time = BusyScenes.keyTime(kind)`, chosen per scene so it
    reads (for example a squashed file under the press, or the front record
    showing its cover);
  - once finished, `time` is the elapsed time frozen at the finish,
    `q(finishedAt − startedAt)`, exactly as with motion on. It is as fixed as
    the key time (it never depends on when the view redraws), and it is the
    frame the job ended on: a finished scan holds the crate that was on
    screen and the whole picked pile, where the key time would show crate
    A–F with a pile of two or three;
  - progress-driven parts still follow real progress, as state changes
    rather than motion;
  - **wall-clock unit inputs are fixed too.** Under `still`, `sceneInput`
    sets `unitTime = 0.5` and `unitFraction = 0.5`. Otherwise the rip would
    freeze in a transient frame: with `cadence` nil the view redraws only
    when `busy` publishes, which for a rip is the moment a track completes,
    when `unitTime ≈ 0`. That frame is the falling slab still sitting at the
    file with the file at its minimum, and it would stay up until the next
    track, minutes later. With 0.5 the slab is already on the stack and the
    file reads half written, so the still frame depends only on progress;
  - finished marks are drawn steady-on, and an unseen mini's destination
    holds steady hot.

  Under Reduce Motion `cadence` is always nil, so nothing ticks. Progress
  changes redraw through ordinary SwiftUI invalidation when `busy`
  publishes.
- **Blink budget.** A finished picture blinks for `pictureBlinkDuration`
  (8 s), counted from `max(finishedAt, screenSince)`, so it blinks when you
  arrive and not only when the job ended. After that it holds steady, and its
  timeline pauses. The blink's job is to call you to the screen; once you are
  on it, it only has to mark the moment.

  The README says the finished marks blink ("check blinks", "OK blinks",
  "DONE blinks") without a limit, so this 8 s cap is a departure from the
  approved look and is listed for the user's sign-off in §15.

  An unseen mini blinks for as long as it stays unseen, which is the
  README's rule. At 2 Hz on a 96 × 12 canvas, paused while hidden, that is a
  negligible cost. It is not a `repeatForever` Core Animation, which is what
  made the old pulse expensive (OLEDDisplay.swift:2426).

## 7. Theming

- The inks are mapped in `BusyInkPalette` from the glass theme, which
  `OLEDDisplay` already injects with `.environment(\.carbon, glassTheme)`
  (:87). The palette's values are §2.2's table.
- **Monochrome is made free by fixing its cause.** `monochromeGlass` leaves
  `meterHotOverride` set, and `meterHot` is `meterHotOverride ?? orange`.
  The bundled Llama '97 theme sets `"oledMonochrome": 1` and pins
  `"meterHot": "#FF0000"`, so a naive hot ink would draw red on a
  monochrome glass. `monochromeGlass` now also sets
  `copy.meterHotOverride = nil`, under a test.
  - This is safe for the LED matrix, which already branches on
    `theme.oledMonochrome` (OLEDDisplay.swift:616) and so never reads
    `meterHot` under monochrome.
  - Under monochrome, cool, hot and foreground are one ink. What separates
    them is the dim print and intensity, as everywhere else on the glass.
- **Glow** is the ink colour at full strength, radius 0.75 pt. The sketch's
  `shadowBlur 3` device pixels is 1.5 pt at 2×, but canvas blur is twice its
  σ while SwiftUI's shadow radius is about σ, so 0.75 pt is what matches. It
  is a constant in `BusyCanvas`, tuned against the contact sheets (Task 14).

## 8. Rules for finished, seen and retired jobs

- **Seen.** A finished record is *seen* once its screen has been on the
  glass (`busyVisibleScreen`) for 1.5 s, counted from
  `max(finishedAt, screenSince)`.
- **Retired.** A seen record is *retired* (removed) as soon as the glass
  leaves its screen.
- **Why the 1.5 s.** Without the delay, two real flows would mark a finished
  job seen in the same turn it finished, so its finished state would never
  be shown:
  - a rip ends on DUB and `loadFolders` switches to SCAN in the same turn;
  - the user flicks past a screen.
- **What the rules produce.**
  - **On the job's screen when it finishes:** the finished frame blinks,
    then holds while you stay, and leaving clears it. No mini ever appears.
  - **On another screen when it finishes:** the mini's destination blinks
    until you visit (click the mini or press the screen key). The picture
    then blinks for 8 s, and leaving clears it.
  - **Chained rip → scan:** the rip mini blinks on SCAN beside the running
    scan's picture. One click on the mini shows "disc stopped, check over
    the stack".
- **Compact.** The glass is always NOW (`.other`), so nothing can be seen
  there. A finished job blinks in compact until the user expands and visits
  its screen, and clicking the mini does exactly that.

## 9. Compact player

**Decision (README "Not decided yet"): yes, the minis show.** `CompactDeckView`
hosts the same `OLEDDisplay`, and so the same `DisplayRail`, under
`oledScreenOverride = .nowPlaying`. The rail's screen is therefore NOW, and
every job qualifies.

- `RailLive` is narrower there (≈ 85 pt on JetBrains Mono, ≈ 125 pt on
  Llama '97, measured), so at the 1174 pt compact minimum the rail has
  ≈ 359 pt free on Carbon: two minis plus "+N" fit.
- Pictures never appear in compact, because the display is pinned to NOW.
- `busyVisibleScreen` treats compact as `.other`, even when `oledView` is
  `.dub` underneath. Expanding counts as arriving on `oledView`'s screen
  (`playerLayout.didSet` calls `noteBusyScreenChanged`).

## 10. Errors and edge cases

| Case | Behaviour |
|---|---|
| Cancel | `.cancelled` removes the record at once: no finished state, no blink. The existing "RIP CANCELLED" notice or summary sheet says it. A cancelled copy transfer that copied some files is still `.cancelled` (§3.1 reads `conversionTask?.isCancelled`), not `.completed`. |
| Failure | `.failed` removes it at once. A blinking check after "Rip Failed" would be a lie. |
| Partial success (convert with some errors) | `.completed`. The summary sheet carries the errors. |
| Total of zero or unknown | `fraction == nil`. The mini lights no dashes and its packet walks. Clock-driven scenes are unaffected. The rip falls back to `max(completed + 1, 1)` tracks for its label. |
| NaN or negative progress | Sanitised in `BusyProgress` init and setters. Tests feed NaN, −1 and `Int.max`. |
| Late progress hop after finish | `update` ignores finished and unknown ids. |
| Two jobs at once | The BUSY guards (`requestCDRip` :2552, `downloadStream` :41, `+Conversion` :14, `+ExternalDeviceTransfer` :25, and the one §3.1 adds to `importSACDISO`) make rip, SACD import, convert, download and copy-transfer exclusive on `conversionProgress`. Without the SACD guard this was false: `importSACDISO` had none. Scan and sync can run beside any of them, so at most three run at once. Each screen draws one picture: running beats finished, and newest beats oldest. |
| Restart (a new dig while one runs) | `begin` retires the running record of the same kind and screen. The scene restarts from time 0. This includes a Finder drop (`importDroppedURLs`, `addURLsToCrate`) landing while a folder dig runs: neither cancels `scanTask`, so the dig keeps working, but its picture is replaced by the drop's and its own `end` is a no-op. Accepted: the SCAN screen shows the newest scan, and the dig still lands its tracks. |
| A new job on a screen holding a finished one | `begin` retires the finished one silently: it was superseded, so there is no blink. |
| Secure read → rip | `handOver` changes the kind in place: same id and start, no finished state, so the rail never reorders or blinks. The secure scene's finished frame (full map, OK) is still built in Core for the README's completeness and the contact sheet, but the app never reaches it: a secure rip ends with the rip's finished frame. The README's "Full map, OK blinks" is therefore not seen in the app; listed for sign-off in §15. |
| Hidden window | Paused, and on return the current frame is drawn (stateless). |
| Quit while running | The ledger is not persisted. Unseen blinks do not survive a relaunch. |
| Missed finish site | On the conversion and sync channels, the safety net (§2.3) ends the armed record as `.failed` (silently removed) 3 s after its channel stops, and logs it. On scan it only logs; the next scan's `begin` retires the orphan. |
| Themes with short headers | `BusyPictureLayout.frame` returns nil, so there is no picture and the minis still show. |

## 11. Testing and visual verification

### 11.1 Core XCTests (`Tests/CrateDiggerCoreTests/`)

The style is `MatrixAnimationTests`: sentence-named tests, loops over
`allCases` with the kind in the message, and degenerate input tested
explicitly.

- **`BusyDrawingTests`:**
  - each primitive records one shape with its inks;
  - `bounds` covers lines, circles, arcs, text;
  - an arc's bounds follow its sweep (the download mini's antenna arc,
    r 3.2 at (6, 2.2) over −0.7…0.7, has minY ≈ 0.14, not −1.0);
  - shapes inside a clip are bounded by the clip rect;
  - `clipped` brackets its shapes;
  - equality.
- **`BusySignalTimingTests`:**
  - `quantized` and `step` at boundaries, NaN, negative and infinite;
  - `blink` toggles every 0.5 s;
  - `cadence` returns 1/16 running, 1/8 blinking, and nil when still or
    settled.
- **`BusyNoiseTests`:**
  - `unit` stays in [0, 1);
  - three values pinned against the sketch's formula, computed by hand.
- **`BusyProgressTests`:**
  - sanitising;
  - `fraction` is nil for a nil or zero total;
  - `with(completed:total:)` keeps `lossless` and `secure`;
  - `BusySecureRead.overall` matches the old `DubPane.secureOverall` on a
    table of phases.
- **`BusyLedgerTests`:**
  - lifecycle;
  - `update` ignored after finish;
  - cancelled and failed are removed;
  - completed on the current screen is seen after 1.5 s and retired on
    leaving;
  - completed off-screen is unseen until visited;
  - the chained rip → scan case;
  - `begin` supersedes a finished record and restarts a running one;
  - `handOver` keeps the id;
  - `picture(on:)` priority;
  - `settle` returns the right next date, and nil once nothing is pending:
    `settle(at: blinkEnd + 1)` for a seen record still on screen is nil;
  - the rip's `unitFraction` estimate (30 s fallback, average, 0.95 cap);
  - after secureRead → `handOver` → the first track completing, the
    average is measured from the handover, not from the read's start;
  - under `still`, `unitTime` and `unitFraction` are 0.5 whatever the date;
  - the picture blink window counts from `max(finishedAt, screenSince)`.
- **`BusyRailTests`:**
  - the own screen is excluded;
  - running and unseen are included, seen is excluded;
  - start order;
  - at most 2 plus overflow;
  - a width ladder: 2 + N, 1 + N, N only, then empty;
  - `.other` (compact) qualifies every job.
- **`BusyPictureLayoutTests`:** 220 × 76 at the default band, nil under
  40 pt, nil when the readout lacks 174 pt, leading as given.
- **`BusySceneTests`**, generic over every kind and every progress in
  {0, 0.1, 0.5, 0.9, 1, nil}, running and finished:
  - the drawing's size is right, and `bounds` stays inside 240 × 100 or
    96 × 12 (≤ 0.5 unit tolerance for round caps). This relies on sweep-aware
    arc bounds and on clip-aware bounds. The one exception is the scan's
    crate swap, which leaves the scene sideways on purpose (§2.1) and is
    held only inside the scene's height;
  - deterministic: the same input gives an equal drawing;
  - two times inside one 1/8 s step give equal drawings;
  - the finished drawing differs from the running one at the same time;
  - `markLit` on and off differ, for every picture **except `.download`**,
    whose finished picture has no blinking element in the approved look
    (§3.2), and for every mini;
  - the still key frame draws the same at any wall time;
  - only `.foreground`, `.cool`, `.hot`, `.dim` and `.background` appear,
    and `.background` only as a fill.
- **Per-scene invariants**, one test class per scene file, encoding the
  user's feedback:
  - **Rip:** slab count equals `shown(completed)`, at most 5; every slab's
    `minY > 61`, below the check's lowest point (its vertex at (210, 61));
    disc angle frozen after finish; the file shows one cool line at
    `unitFraction` 0 and four at 0.95; a completion that leaves `shown`
    unchanged drops no slab.
  - **SecureRead:** filled cells equal ⌊phaseFraction × 60⌋ on pass 1 and
    pass 2; no hot cell on pass 1 or pass 2, whatever `rereads` says; in
    `.retry` the map is full and exactly `min(rereads, 6)` cells are hot;
    at most 12 band rings.
  - **Convert:**
    - lossy: the file under the press is at most 14 units tall;
    - lossless: a cool box surrounds the file after the press;
    - mini: the flat block is centred on y = 6 (its rect's midY = 6 ± 0.05).
  - **Scan:**
    - record bottoms are hidden: every standing record shape (the back
      record rects, the front record's face or tipping quad) is drawn
      *before* the front wall and ends at or above F + 4 = 76, and the wall's
      `.background`-filled rect `(cx − 44, 72, 88, 20)` comes after all of
      them in `shapes`. The flipped records leaning forward over the wall
      (a background-filled quad from F − 3 down to F + 1.5 + shown × 1.3, plus
      dim lines, html:621-626) are drawn *after* the wall on purpose and are
      exempt: they are the approved look, not record bottoms;
    - picked-pile records are as wide as a crate record (2 × 44 × 0.9);
    - the dividers cycle in order;
    - finished holds the crate that was on screen at the finish;
    - mini: the fallen record lies within the crate's x-span
      [x, x + 10.4].
  - **Download:** the cassette's outer rounded rect is 104 × 66, which is
    1.576 : 1; the window is a stadium (radius = height / 2) with hub
    centres at its round ends; take-up radius grows and supply shrinks with
    fraction; the finished picture reads DONE in hot and is identical with
    `markLit` on and off.
  - **Transfer:**
    - running: the screen holds a hot circle plus a diagonal (the no-entry
      sign) and nothing else;
    - finished with the mark lit: a check and no circle;
    - the click wheel is two bare circles;
    - mini: the screen is a foreground block and the wheel a foreground
      dot.

### 11.2 App XCTests (`Tests/CrateDiggerAppTests/`)

- **`BusyInkPaletteTests`:**
  - the five mappings;
  - under a monochrome definition with `meterHot` pinned, cool, hot and
    foreground resolve to the same colour.
- **`MonochromeGlassTests`:** `monochromeGlass.meterHotOverride == nil`, and
  `meterHot == oledForeground` under it. Uses the `OLEDSurfaceShadeTests`
  pattern, `ThemeDefinition` + `CarbonTheme(definition:resolvedBase: .carbon)`.
- **`BusyScreenMappingTests`:** every `OLEDView` maps to the expected
  `BusyScreen`, and every non-other `BusyScreen` maps back.
- **`BusySignalSnapshotTests`:**
  - Always on: `testEveryPictureAndMiniRendersInk` renders each kind through
    `ImageRenderer` and asserts some pixels differ from the surface.
  - Gated: `testWriteContactSheets` is skipped unless
    `CRATEDIGGER_BUSY_SNAPSHOTS=1`.

### 11.3 The contact-sheet harness

```bash
CRATEDIGGER_BUSY_SNAPSHOTS=1 scripts/test.sh --filter BusySignalSnapshotTests
open .build/busy-signals/
```

- **Setup.** `@MainActor`, `FontRegistrar.registerBundledFonts()` in
  `setUp` (or the text falls back to the system mono), repo root from
  `#filePath`.
- **One `.build/busy-signals/<kind>.png` per kind.** `ImageRenderer` at
  scale 3. Rows:
  1. Carbon, the default two-ink glass
  2. Llama '97 from `Sources/CrateDiggerApp/Resources/Themes/Llama 97.cdtheme`, monochrome with `meterHot` pinned:
     the R1 regression. Its `meterHot: #FF0000` pin and `oledMonochrome`
     live only inside the theme's `dark` and `light` layers (theme.json:34,
     :119), so the definition must be flattened first, as
     `BundledThemeTests.render` does:
     `CarbonTheme(definition: llama.resolved(for: .dark), resolvedBase: .carbon)`.
     The harness asserts `meterHotOverride != nil` on that theme before
     applying `monochromeGlass`, or the row would pass without testing
     anything.
  3. Reduce Motion

  Plus one row on a pale LCD-style bundled theme, for the background-fill
  decision in §2.2.

  Columns, each a 220 × 84 picture on the real glass background
  (`oledSurface` plus the diagonal gradient `OLEDDisplay` lays over it,
  :107-124) with a 1 px frame and a mono caption:
  - p = 0.1, 0.5 and 0.9, at the sketch-equivalent times (`time = p × run`,
    with the sketch's run lengths 18 / 20 / 22 / 20 / 16 / 18)
  - finished with the mark lit
  - finished with the mark unlit
  - the still key frame
- **`minis.png`.** Every mini at 1× and 4×: running at p = 0.5, finished
  lit, finished unlit.
- **`index.html`.** A local page placing each sheet beside a note of the
  sketch section to compare it with. The sketch itself is opened in a
  browser alongside.
- **Never launches the app.** The user's `/Applications/CrateDigger.app` is
  running and must not be disturbed. **Never `pkill -f CrateDiggerApp`.**

In-context checks of the rail and panes use the DEBUG hook (§12) on the
debug binary, captured with the existing `CRATEDIGGER_SNAPSHOT_PATH`. Stop
the launched debug process by its PID only. The existing hook's timings
matter: `CRATEDIGGER_OLED` is applied at +7.0 s, and the snapshots are taken
at +4.0 s (`<path>`) and +8.0 s (`<name>.late.png`). A capture therefore has to
let the process live at least 10 s and read the `.late.png`; the +4.0 s
snapshot still shows the saved screen.

## 12. DEBUG hook

`CRATEDIGGER_BUSY=<kind>[,<kind>…][:done]`, for example `rip,scan` or
`download:done`, sits in `installSnapshotHookIfRequested` (AppDelegate:485).

- It calls `model.debugSimulateBusyJobs(_:finished:)`, which `begin`s each
  kind on its default screen and drives synthetic progress from 0 to 1 over
  20 s, then finishes it. With `:done` it finishes at once.
- The simulation touches only the ledger, never a real channel or file.
- Combine it with `CRATEDIGGER_OLED=cdRip|conversion|scan|devices|nowPlaying` (raw values; DUB is `cdRip`)
  and `CRATEDIGGER_COMPACT=1` to frame any case for a window snapshot.
- **It works without `CRATEDIGGER_SNAPSHOT_PATH`.** Today the whole hook
  returns early unless that path is set (AppDelegate.swift:487). The
  `CRATEDIGGER_BUSY` handling, and a `CRATEDIGGER_OLED` application at +1 s
  when `CRATEDIGGER_BUSY` is set, are installed **before** that guard, so an
  idle-cost run with no snapshot still simulates the job and frames it.
- **`CRATEDIGGER_SNAP_EXTRA=1`** adds one more snapshot at +8.5 s
  (`<name>.late2.png`). With the +8.0 s `.late.png` that gives two frames
  half a 2 Hz blink apart, so a blinking destination is caught in both
  phases.

## 13. Resolutions of the README's "Not decided yet"

- **Architecture.** §2: a Core scene model and ledger, one `Canvas`, and a
  `TimelineView` gated on `AppVisibility`.
- **Which progress fields feed each scene.** §2.3's channel table and §3,
  with explicit start and finish stamps rather than inference.
- **How "blink until visited" is tracked.** §8: `BusyLedger` seen and
  retired, with "seen" meaning 1.5 s on the screen, and screen changes from
  `oledView.didSet` and `playerLayout.didSet`.
- **Compact shows the minis.** Yes (§9). A click expands, then switches.
- **Transfer's screen** (README said DEV). Sync shows on DEV. The copy
  transfer shows on CNVRT, where the app already runs it. The device
  pre-convert is a Convert. The kind follows what the job does; the screen
  follows where the app already shows it. This departs from the README's
  table and is listed for sign-off in §15.
- **Monochrome "should be free".** Made true by fixing `monochromeGlass` (§7).
- **Ideas mapped but not sketched** (Record Divider, remote sync, Deep Scan /
  Fix Tags, disc-inserted idle). Out of scope. Each would be one
  `BusyJobKind` case, one scene file and one stamp pair. Nothing in this
  design blocks them.

## 14. Out of scope

- The sketch's per-job headline, readout and ticker copy (RIPPED, SAVED,
  "SAME BITS, NEW BOX"…). Panes keep their text; only the picture is added.
- The sketch's NOW picture (a ticking VU). NOW keeps the LED matrix.
- Panel or inspector copies of the scenes, which were dropped in the design
  review.
- The lo-res dot-pitch toggle, which was only for comparison.
- A settings switch to turn Busy Signals off. Reduce Motion already gives a
  still frame. A switch would be a `PreferencesStore` key plus a tolerant
  `init(persisted:)`, if wanted later.
- Moving the copy transfer to DEV.
- Persisting the ledger across launches.
- Mini Player and full-screen player windows. They host no OLED.

## 15. Decisions awaiting the user's sign-off

The README is the approved look, and CLAUDE.md says "Don't Assume, Ask".
These points depart from it, or change behaviour the user already has, so
they are put to the user **before** the plan's Task 16 (the first task that
changes user-visible behaviour) and recorded here with the answer. Tasks 1-15
do not depend on the answers: item 3 is one Core constant
(`pictureBlinkDuration`) and its blink-window rule, which a "no" turns into
"blink while on screen", and items 1, 2, 4 and 5 all land in Task 16 or later.

| # | Decision | Spec default | If the user says no |
|---|---|---|---|
| 1 | Remove the four jumps to NOW after a rip, download or SACD import (§5), so DUB stays put and its finished frame can be seen | Remove them | Keep the jumps. The finished rip, download or SACD picture is then seen only through its blinking mini, which appears on NOW straight away. |
| 2 | Copy transfers run on CNVRT, not DEV as the README's table says (§13) | CNVRT, where the app already shows them | Move the copy transfer's screen to DEV (out of scope today, §14), or show its picture on CNVRT anyway and accept the README mismatch |
| 3 | A finished picture blinks for 8 s after you arrive, then holds steady (§6). The README's marks blink with no limit | 8 s, then steady | Blink for as long as the screen shows the finished picture (a 1/8 s timeline per finished picture while it is on the glass) |
| 4 | The secure read's finished frame ("Full map, OK blinks") is never shown, because a secure rip hands over to the rip and ends with the rip's frame (§10) | Hand over; the frame exists for the contact sheet only | Show the secure finished frame briefly at the handover, before the encode's picture takes over |
| 5 | `importSACDISO` gains a BUSY guard (§3.1), so an SACD import can no longer start while a rip, convert, download or copy transfer runs | Add the guard | Leave it out, and accept that an SACD import started beside another job overwrites that job's progress and retires a running rip's picture |

Answers (user, 2026-10-15): all five spec defaults accepted.

1. Remove the four jumps to NOW; DUB stays put so its finished frame can be seen.
2. Copy transfers stay on CNVRT.
3. A finished picture blinks for 8 s after you arrive, then holds steady.
4. A secure rip hands straight over; its finished frame exists for the contact sheet only.
5. `importSACDISO` gains the BUSY guard.

The user also approved local commits on `feature/busy-signals` as tasks pass
review (nothing pushed or merged).
