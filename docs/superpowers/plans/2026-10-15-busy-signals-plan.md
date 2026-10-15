# Busy Signals Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** While a job runs, the OLED draws an animated line-art scene of it (CD rip, Secure read, Convert, Scan, Download, Transfer). Every other screen shows a 96 × 12 pt "source - - - - destination" mini of it on the annunciator rail.

**Architecture:**
- **Core** (`Services/BusySignals/`): a pure drawing type, scenes as stateless functions of their input, and a `BusyLedger` that owns lifecycle and the "seen" rule. Also the rail policy, all unit-tested.
- **App**: one `Canvas` renderer behind a visibility-gated `TimelineView`. Panes host the picture, the rail hosts the minis, and `LibraryViewModel+BusySignals` stamps jobs where they start and finish.

**Tech Stack:** Swift 5.9 tools / SwiftPM, AppKit + SwiftUI (macOS 13+), XCTest via `scripts/test.sh`.

**Spec:** `docs/superpowers/specs/2026-10-15-busy-signals-design.md`. Read it first; section numbers below (§n) point into it.

**Visual source of truth:** `CrateDigger_DESIGN/busy-signals/busy-signals.html`. `html:NNN` means a line in that file. Port the look, not the JS.

## Global Constraints

- **Branch and commits.**
  - Branch: `feature/busy-signals`. Never commit to `main`, `v2.3` or `v2.2`. Do not push.
  - Commit after each task. Commit messages end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- **Building and testing.**
  - Build with `swift build`. The debug binary is `.build/debug/CrateDiggerApp`.
  - Test with `scripts/test.sh [--filter X]`, never bare `swift test`.
  - Parallel agents share `.build/tests` and serialise on its lock. That is expected, not a failure.
- **The user's running app.** The installed `/Applications/CrateDigger.app` is running. **Never `pkill -f CrateDiggerApp`.** If you launch the debug binary, stop it by its own PID (`kill <pid>`).
- **Core rules.**
  - Core stays pure: no SwiftUI, no timers, no app state.
  - New Core types are `public`, `Sendable` and `Equatable`. Tuning constants are internal `static let`, reached from tests through `@testable`.
- **Scenes.**
  - Scenes are stateless and take time only through `BusySceneInput`. Never call `Date()` inside Core scene code.
  - Scene units are y-down. Scene space is 240 × 100 and mini space is 96 × 12.
- **App rules.**
  - Do not infer the running job from `oledView`, `pendingDeviceConversion` or `downloadingStreamID`. Stamp it at the start and finish sites listed in spec §3.1.
  - `OLEDPaneScaffold` with `picture == nil` must keep today's exact code path.

## Review Focus

1. **Finished-state reachability.**
   - A rip that ends on DUB must still show its finished frame through the mini after `loadFolders` switches to SCAN. This is the chained case, covered by `BusyLedgerTests.testChainedRipThenScanLeavesRipUnseen`.
   - Removing the four jump-to-NOW sites (Task 16) is a user-visible behaviour change. It and the other departures in spec §15 are put to the user **before** Task 16 (its Step 0), not reported afterwards.
2. **Monochrome.** Llama '97 pins `meterHot` red. Under its monochrome glass, no picture may draw red. Covered by Task 13's `MonochromeGlassTests` and Task 14's Llama row.
3. **Pane overflow.** At the default 170 pt header, a picture must not push the cell rail off the glass. Covered by Task 5's `BusyPictureLayoutTests` and Task 17's manual capture at header 170 and 120.
4. **Rail width at the 1200 pt minimum.** Annunciators must never clip. Covered by Task 5's width ladder and Task 18's manual capture.
5. **Idle cost.** No timeline may tick while the window is hidden, under Reduce Motion, or after a picture settles, and the settle task must not loop (`settle` never returns a past date). Checked in Task 4 and Task 19.
6. **Launch screen.** After relaunching onto a saved job screen, a job started there must not get a mini on its own rail. `wireBusySignals()` seeds the ledger's screen (Task 15). Check by hand: save CNVRT, relaunch the debug binary with `CRATEDIGGER_BUSY=convert` and no `CRATEDIGGER_OLED`, and confirm the rail shows no convert mini.

---

## File map

| File | Status | Task |
|---|---|---|
| `Sources/CrateDiggerCore/Services/BusySignals/BusyDrawing.swift` | create | 1 |
| `Sources/CrateDiggerCore/Services/BusySignals/BusySignalTiming.swift` | create | 2 |
| `Sources/CrateDiggerCore/Services/BusySignals/BusyNoise.swift` | create | 2 |
| `Sources/CrateDiggerCore/Services/BusySignals/BusyJob.swift` | create | 3 |
| `Sources/CrateDiggerCore/Services/BusySignals/BusyLedger.swift` | create | 4 |
| `Sources/CrateDiggerCore/Services/BusySignals/BusyRail.swift` | create | 5 |
| `Sources/CrateDiggerCore/Services/BusySignals/BusyPictureLayout.swift` | create | 5 |
| `Sources/CrateDiggerCore/Services/BusySignals/BusyScenes.swift` | create | 6 |
| `Sources/CrateDiggerCore/Services/BusySignals/BusyGlyphs.swift` | create | 6 |
| `Sources/CrateDiggerCore/Services/BusySignals/Scenes/{Rip,SecureRead,Convert,Scan,Download,Transfer}Scene.swift` | create (stubs in 6, filled in 7–12) | 6–12 |
| `Sources/CrateDiggerApp/UI/Theme/CarbonTheme.swift` | modify (`monochromeGlass`) | 13 |
| `Sources/CrateDiggerApp/UI/Carbon/Header/BusySignals/BusyCanvas.swift` | create | 13 |
| `Sources/CrateDiggerApp/UI/Carbon/Header/BusySignals/BusyPictureView.swift` | create | 17 |
| `Sources/CrateDiggerApp/UI/Carbon/Header/BusySignals/BusyRailMinis.swift` | create | 18 |
| `Sources/CrateDiggerApp/UI/Carbon/Header/OLEDDisplay.swift` | modify | 17, 18 |
| `Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel+BusySignals.swift` | create | 15 |
| `Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel.swift` | modify | 15, 16 |
| `Sources/CrateDiggerApp/UI/Conversion/LibraryViewModel+Conversion.swift` | modify | 16 |
| `Sources/CrateDiggerApp/UI/ExternalDevices/LibraryViewModel+ExternalDeviceTransfer.swift` | modify | 16 |
| `Sources/CrateDiggerApp/UI/ExternalDevices/LibraryViewModel+DeviceSync.swift` | modify | 16 |
| `Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel+StreamDownload.swift` | modify | 16 |
| `Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel+SACDImport.swift` | modify | 16 |
| `Sources/CrateDiggerApp/AppDelegate.swift` | modify (DEBUG hook) | 19 |
| `Tests/CrateDiggerCoreTests/Busy*Tests.swift`, `*SceneTests.swift` | create | 1–12 |
| `Tests/CrateDiggerAppTests/BusyInkPaletteTests.swift`, `MonochromeGlassTests.swift` | create | 13 |
| `Tests/CrateDiggerAppTests/BusySignalSnapshotTests.swift` | create | 14 |
| `Tests/CrateDiggerAppTests/BusyScreenMappingTests.swift` | create | 15 |
| `CLAUDE.md`, `CrateDigger_DESIGN/busy-signals/README.md` | modify | 20 |

## Dependency graph and parallelism

```
1 ─┬─ 2 ─┬─ 3 ── 4 ── 5
   │     └─ 6 ─┬─ 7 ┐
   │           ├─ 8 │
   │           ├─ 9 │   (7–12 touch disjoint files: run in parallel)
   │           ├─ 10│
   │           ├─ 11│
   │           └─ 12┘── 14
   └─ 13 ──────────────┘
4 ── 15 ── 16
13 + 15 ── 17 ── 18 ── 19 ── 20
```

| Tasks | Can run in parallel because |
|---|---|
| 7, 8, 9, 10, 11, 12 | Each writes only its own `Scenes/XScene.swift` and `XSceneTests.swift`. |
| 13 | Touches App files only; needs Task 1 alone. It can run beside 2–12. |
| 15 | Needs Task 4. It can run beside 6–14 (App VM files, disjoint from the Core scenes). |
| 17 and 18 | Both edit `OLEDDisplay.swift`, so they run **sequentially**. |
| 16 | Edits several VM files. Run it alone, after 15. |

Task 6 depends on Task 3 for `BusyProgress` and `BusyLabels`, and on Task 4 for `BusySceneInput`, which is declared in `BusyScenes.swift`. Order 1 → 2 → 3 → 4 → 5 → 6 sequentially, then fan out.

---

### Task 0: Baseline

- [ ] **Step 1:** Run `git -C /Volumes/EX_3/Code/CrateDigger status` and confirm the branch is `feature/busy-signals`. The only changes allowed are the two untracked docs, `docs/superpowers/specs/2026-10-15-busy-signals-design.md` and `docs/superpowers/plans/2026-10-15-busy-signals-plan.md`. Commit them first (`docs(busy): Busy Signals spec and plan`), then confirm the tree is clean.
- [ ] **Step 2:** Run `swift build` and `scripts/test.sh`. Record the test count (≈ 1,379) and any failures that already exist, so they are not blamed on this work.

---

### Task 1: `BusyDrawing`, `BusyInk`, `BusyShape` (Core)

**Files:**
- Create `Sources/CrateDiggerCore/Services/BusySignals/BusyDrawing.swift`.
- Test `Tests/CrateDiggerCoreTests/BusyDrawingTests.swift`.

**Interfaces:** see spec §2.1, "Drawing". Implement exactly those signatures.

**Implementation notes:**
- `bounds` is the union of each shape's geometric box.
  - line: the two points
  - path: its points
  - circle: center ± r
  - arc: its swept range, i.e. the two endpoints plus every axis extreme (0, π/2, π, 3π/2, mod 2π) inside the sweep. Not the full circle box: that bound puts the download mini's antenna arc (r 3.2 at (6, 2.2), −0.7…0.7) at minY −1.0, outside the generic test's −0.5 tolerance, when the real arc only reaches y ≈ 0.14.
  - ellipse: center ± max(rx, ry)
  - quadCurve: its three points
  - rect and roundedRect: the rect
  - text: estimated width `count × size × 0.6`, offset by alignment, and box `y − size … y + size × 0.25`
  - clip markers: no box; every shape between a `clipBegin` and its `clipEnd` is intersected with the clip rect (nested clips intersect in turn)
- `clipped(to:radius:_:)` appends `.clipBegin`, runs the body on `self`, then appends `.clipEnd`.
- Every `CGFloat` input is sanitised: non-finite becomes 0, so a NaN can never reach the renderer.

- [ ] **Step 1: Write the failing tests**

```swift
#if canImport(XCTest)
import CoreGraphics
import XCTest
@testable import CrateDiggerCore

/// The drawing is the contract between the scenes and the renderer, so its
/// recording is checked here shape by shape.
final class BusyDrawingTests: XCTestCase {
    func testEachPenCallRecordsOneShape() {
        var d = BusyDrawing(size: BusyDrawing.sceneSize)
        d.line(0, 0, 10, 0, .cool)
        d.dot(5, 5, 1, .hot)
        d.block(1, 1, 2, 2, .dim)
        d.rect(0, 0, 4, 4, .foreground, fill: .background)
        XCTAssertEqual(d.shapes.count, 4)
        XCTAssertEqual(d.inks, [.cool, .hot, .dim, .foreground, .background])
    }

    func testBoundsCoverLinesCirclesAndText() {
        var d = BusyDrawing(size: BusyDrawing.sceneSize)
        d.line(10, 20, 30, 20)
        d.circle(50, 50, 10)
        d.text("OK", 100, 60, .hot, size: 8, align: .center)
        let b = d.bounds
        XCTAssertEqual(b.minX, 10, accuracy: 0.01)
        XCTAssertEqual(b.minY, 20, accuracy: 0.01)
        XCTAssertGreaterThanOrEqual(b.maxX, 104.8 - 0.01)   // 2 × 8 × 0.6 / 2 past centre
        XCTAssertEqual(b.maxY, 62, accuracy: 0.01)          // baseline + size × 0.25
    }

    func testClippedBracketsItsShapes() {
        var d = BusyDrawing(size: BusyDrawing.sceneSize)
        d.clipped(to: CGRect(x: 0, y: 0, width: 20, height: 10), radius: 5) { $0.circle(5, 5, 8, .cool) }
        guard case .clipBegin = d.shapes.first, case .clipEnd = d.shapes.last else {
            return XCTFail("clip not bracketed: \(d.shapes)")
        }
        XCTAssertEqual(d.shapes.count, 3)
    }

    func testArcBoundsFollowTheSweep() {
        var d = BusyDrawing(size: BusyDrawing.miniSize)
        d.arc(6, 2.2, 3.2, -0.7, 0.7, .cool)          // the download mini's antenna arc
        XCTAssertEqual(d.bounds.minY, 2.2 - 3.2 * sin(0.7), accuracy: 0.01)   // ≈ 0.14, not −1.0
        XCTAssertEqual(d.bounds.maxX, 9.2, accuracy: 0.01)                    // passes through angle 0
    }

    func testClippedShapesAreBoundedByTheClip() {
        var d = BusyDrawing(size: BusyDrawing.sceneSize)
        d.clipped(to: CGRect(x: 0, y: 0, width: 240, height: 100), radius: 0) { $0.rect(-78, 32, 88, 60) }
        XCTAssertEqual(d.bounds.minX, 0, accuracy: 0.01)
    }

    func testNonFiniteInputIsSanitised() {
        var d = BusyDrawing(size: BusyDrawing.miniSize)
        d.line(.nan, 1, .infinity, 2)
        XCTAssertTrue(d.bounds.minX.isFinite && d.bounds.maxX.isFinite)
    }

    func testEqualDrawingsCompareEqual() {
        func make() -> BusyDrawing { var d = BusyDrawing(size: BusyDrawing.miniSize); d.arc(6, 6, 3, -0.7, 0.7, .cool); return d }
        XCTAssertEqual(make(), make())
    }
}
#endif
```

- [ ] **Step 2:** Run `scripts/test.sh --filter BusyDrawingTests`. Expected: compile failure, because the types do not exist yet.
- [ ] **Step 3:** Implement `BusyDrawing.swift`. Add a type doc comment that explains why inks are semantic (monochrome and theming are the renderer's job) and why there is no transform primitive.
- [ ] **Step 4:** Run `scripts/test.sh --filter BusyDrawingTests`. Expected: pass.
- [ ] **Step 5:** Commit with `feat(busy): BusyDrawing, the scene primitive list`.

---

### Task 2: `BusySignalTiming` and `BusyNoise` (Core)

**Files:**
- Create `BusySignals/BusySignalTiming.swift` and `BusySignals/BusyNoise.swift`.
- Test `Tests/CrateDiggerCoreTests/BusySignalTimingTests.swift`.

**Interfaces:** spec §2.1, "Timing and noise".
- `cadence(_:)` needs `BusySceneInput`, which is not written until Task 6. Leave `cadence` out of this task and add it in Task 6. That keeps this task compilable alone.

- [ ] **Step 1: Write the failing tests**

```swift
final class BusySignalTimingTests: XCTestCase {
    func testQuantizedFloorsToEighths() {
        XCTAssertEqual(BusySignalTiming.quantized(0.124), 0)
        XCTAssertEqual(BusySignalTiming.quantized(0.125), 0.125)
        XCTAssertEqual(BusySignalTiming.quantized(1.99), 1.875)
        XCTAssertEqual(BusySignalTiming.step(1.99), 15)
    }

    func testDegenerateTimeReadsAsZero() {
        for t in [TimeInterval.nan, -3, .infinity, -.infinity] {
            XCTAssertEqual(BusySignalTiming.quantized(t), 0, "\(t)")
            XCTAssertEqual(BusySignalTiming.step(t), 0, "\(t)")
        }
    }

    func testBlinkTogglesEveryHalfSecondAtTwoHertz() {
        XCTAssertTrue(BusySignalTiming.blink(0))
        XCTAssertTrue(BusySignalTiming.blink(0.49))
        XCTAssertFalse(BusySignalTiming.blink(0.5))
        XCTAssertTrue(BusySignalTiming.blink(1.0))
    }

    func testNoiseIsTheSketchHashAndStaysInUnitRange() {
        for i in 0..<500 { let u = BusyNoise.unit(Double(i)); XCTAssert(u >= 0 && u < 1, "\(i)") }
        // fract(sin(311.7) × 43758.5453), computed by hand from html:222.
        let x = sin(311.7) * 43758.5453
        XCTAssertEqual(BusyNoise.unit(0), x - floor(x), accuracy: 1e-12)
    }

    func testRingClosesOnItself() {
        let r = BusyNoise.ring(0, 0, 10, segments: 16)
        XCTAssertEqual(r.count, 17)
        XCTAssertEqual(r.first!.x, r.last!.x, accuracy: 1e-9)
    }
}
```

- [ ] **Step 2:** Run `scripts/test.sh --filter BusySignalTimingTests`. Expected: fail to compile.
- [ ] **Step 3:** Implement both files. `unit` is `x - floor(x)` with `x = sin(i * 127.1 + 311.7) * 43758.5453`, exactly as in html:222.
- [ ] **Step 4:** Run `scripts/test.sh --filter BusySignalTimingTests`. Expected: pass.
- [ ] **Step 5:** Commit with `feat(busy): 8 fps timing and the sketch's noise`.

---

### Task 3: Job model: kinds, screens, outcome, labels, progress (Core)

**Files:**
- Create `BusySignals/BusyJob.swift`.
- Test `Tests/CrateDiggerCoreTests/BusyProgressTests.swift`.

**Interfaces:** spec §2.1, "Jobs and progress": `BusyJobKind`, `BusyScreen`, `BusyOutcome`, `BusyJobID`, `BusyLabels`, `BusySecureRead`, `BusyProgress`.

**Implementation notes:**
- **`BusyJobKind`:** add `var defaultScreen: BusyScreen`:
  - `rip`, `secureRead` and `download` → `.dub`
  - `convert` → `.conversion`
  - `scan` → `.scan`
  - `transfer` → `.devices`
- **`BusyProgress`:** use stored private backing with `didSet` sanitising, as `MatrixInput` does. `completed` becomes `max(0, completed)`; a `total ≤ 0` reads as nil from `fraction` but is stored as given.
- **`BusySecureRead.overall`:** copy `DubPane.secureOverall` (`OLEDDisplay.swift:2008-2017`) verbatim. Leave DubPane's private copy in place until Task 17, which switches it to `BusySecureRead(p).overall` and deletes the duplicate.
- **`BusyLabels.init`:** uppercase, trim, cut to 12 characters, and turn an empty string into nil.

- [ ] **Step 1: Write the failing tests**
  - `testFractionIsNilWithoutATotal`: `total` of nil, 0 and −5 each give `fraction == nil`.
  - `testFractionClampsAndIgnoresNaN`: `completed` 150 of 100 gives 1. Feeding `phaseFraction = .nan` into `BusySecureRead` gives a finite `overall`.
  - `testWithKeepsLosslessAndSecure`.
  - `testSecureOverallMatchesTheDubPaneFormula`: a table. Take track 2 of 4:
    - pass1 at 0.5 gives `(1 + 0.24) / 4`
    - pass2 at 0 gives `(1 + 0.48) / 4`
    - retry at 1 gives `(1 + 1.0) / 4`
  - `testLabelsAreUppercasedAndCut`: "flac" gives "FLAC". A 20-character channel is cut to 12. "" gives nil.
  - `testDefaultScreens`: loop over `allCases`.
- [ ] **Step 2:** Run `scripts/test.sh --filter BusyProgressTests`. Expected: fail.
- [ ] **Step 3:** Implement `BusyJob.swift`.
- [ ] **Step 4:** Run `scripts/test.sh --filter BusyProgressTests`. Expected: pass.
- [ ] **Step 5:** Commit with `feat(busy): job kinds, screens and sanitised progress`.

---

### Task 4: `BusyLedger` (Core)

**Files:**
- Create `BusySignals/BusyLedger.swift`.
- Test `Tests/CrateDiggerCoreTests/BusyLedgerTests.swift`.

**Interfaces:** spec §2.1, "The ledger", and §8.
- `sceneInput(for:at:still:)` returns `BusySceneInput`. Declare `BusySceneInput` in **this** task, at the top of `BusyLedger.swift`, and move it to `BusyScenes.swift` in Task 6. Alternatively, create `BusyScenes.swift` now holding only `BusySceneInput`. Either way, Task 6 owns the dispatcher.

**Rules to implement (spec §8 and §10):**
- **`begin`.**
  - Assigns `id = nextID` (monotonic) and sets `unitStartedAt = progressEpoch = startedAt = date`.
  - Retires every *finished* record with the same `screen`.
  - Retires every *running* record with the same `kind` and `screen`.
- **`update`.**
  - Ignored for unknown ids and finished records.
  - When `progress.completed` changes, sets `unitStartedAt = date`.
- **`handOver`.** Changes `kind`, replaces `progress`, and resets `unitStartedAt` and `progressEpoch` to `date`. `startedAt` stays (ordering and scene time).
- **`finish`.** `.completed` sets `finishedAt`; `.cancelled` and `.failed` remove the record.
- **`show(screen, at:)`.** Sets `screen` and `screenSince`, but only if the screen changed. A no-op `show` must not restart the seen timer. Then it removes every record with `seenAt != nil && record.screen != screen`.
- **`settle(at:)`.** For finished, unseen records with `record.screen == screen`: if `date − max(finishedAt, screenSince) ≥ seenAfter`, set `seenAt = date`. It returns the earliest pending `max(finishedAt, screenSince) + seenAfter` across the remaining unseen-on-screen records. It also returns the earliest picture-blink end (`max(finishedAt, screenSince) + pictureBlinkDuration`) of a seen-or-on-screen finished record, so the view model republishes once the blink ends. **Only candidates strictly after `date` count**; with none, it returns nil. A blink end already in the past must not be returned: the view model would sleep its 0.05 s floor, settle again, get the same past date, and republish the whole `LibraryViewModel` at ~20 Hz for as long as a finished picture stays on its screen.
- **`picture(on:)`.** The last running record with that screen, else the last finished record with that screen.
- **`sceneInput`.**
  - `time = quantized((finishedAt ?? date) − startedAt)`, or `BusyScenes.keyTime(kind)` when `still`. Until Task 6, use a `keyTime` stub returning 0 inside the ledger file; Task 6 replaces it.
  - `unitTime = quantized(date − unitStartedAt)`; **0.5 when `still`**.
  - `unitFraction = min(0.95, unitTime / average)`, where `average` is `(unitStartedAt − progressEpoch) / completed` when `completed > 0`, else 30. It is 1 when finished, and **0.5 when `still`** (and not finished). Measuring from `progressEpoch`, not `startedAt`, keeps a secure read's long first phase out of the encode's per-track average. The `still` values keep Reduce Motion from freezing on the transient frame drawn when a track completes (falling slab at the file, file empty), because under `still` the view only redraws when `busy` publishes, which is exactly that moment.
  - `finished = finishedAt.map { quantized(date − $0) }`.
  - `markLit`, for a finished record:
    - `still` gives true.
    - Otherwise, an unseen record off its screen (the mini case) gives `blink(date − finishedAt)`.
    - Otherwise, the record is on its screen. Let `anchor = max(finishedAt, screenSince)`. If `date − anchor < pictureBlinkDuration`, `markLit = blink(date − anchor)`. If not, it is true (steady).
  - `blinking` is true while that blink is pending.

- [ ] **Step 1: Write the failing tests.** Use a fixed `t0 = Date(timeIntervalSinceReferenceDate: 0)` and `t0 + n`; never `Date()`.

```swift
final class BusyLedgerTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 0)
    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    func testCompletedOnItsOwnScreenIsSeenAfterADelayAndRetiredOnLeaving() {
        var l = BusyLedger(screen: .conversion, at: t0)
        let id = l.begin(.convert, on: .conversion, at: at(0))
        l.finish(id, .completed, at: at(10))
        XCTAssertEqual(l.settle(at: at(10.5)), at(11.5))
        XCTAssertNil(l.record(id)?.seenAt)
        _ = l.settle(at: at(11.5))
        XCTAssertNotNil(l.record(id)?.seenAt)
        XCTAssertEqual(l.picture(on: .conversion)?.id, id, "stays while you stay")
        l.show(.other, at: at(20))
        XCTAssertNil(l.record(id), "leaving retires a seen job")
    }

    /// A rip ends on DUB and loadFolders flips the glass to SCAN in the same
    /// turn. The rip must stay unseen, so its mini blinks on SCAN.
    func testChainedRipThenScanLeavesRipUnseen() {
        var l = BusyLedger(screen: .dub, at: t0)
        let rip = l.begin(.rip, on: .dub, at: at(0))
        l.finish(rip, .completed, at: at(100))
        let scan = l.begin(.scan, on: .scan, at: at(100))
        l.show(.scan, at: at(100))
        _ = l.settle(at: at(200))
        XCTAssertNil(l.record(rip)?.seenAt)
        XCTAssertEqual(BusyRail.entries(l).map(\.id), [rip], "scan is on its own screen")
        _ = scan
    }

    func testCancelledAndFailedLeaveNoTrace() {
        var l = BusyLedger(at: t0)
        let a = l.begin(.download, on: .dub, at: at(0)); l.finish(a, .cancelled, at: at(1))
        let b = l.begin(.convert, on: .conversion, at: at(2)); l.finish(b, .failed, at: at(3))
        XCTAssertTrue(l.records.isEmpty)
    }

    func testLateUpdateAfterFinishIsIgnored() {
        var l = BusyLedger(at: t0)
        let id = l.begin(.rip, on: .dub, progress: BusyProgress(completed: 0, total: 5), at: at(0))
        l.finish(id, .completed, at: at(10))
        l.update(id, progress: BusyProgress(completed: 2, total: 5), at: at(11))
        XCTAssertEqual(l.record(id)?.progress.completed, 0)
    }

    func testBeginSupersedesFinishedOnSameScreenAndRestartsSameKind() { /* … */ }
    func testHandOverKeepsIdentityAndStart() { /* secureRead → rip: same id, same startedAt, kind == .rip */ }
    func testPicturePrefersRunningThenNewest() { /* … */ }
    func testNoOpShowDoesNotRestartTheSeenTimer() { /* … */ }
    func testUnitFractionEstimatesFromAverageAndCaps() {
        // completed 0 → 30 s fallback; completed 2 after 120 s → 60 s average; cap 0.95
    }
    func testHandOverRestartsTheUnitAverage() {
        // secureRead begun at 0, handOver at 1200, first track completes at 1260:
        // average is 60 s (from the handover), not 1260 s; at 1290 unitFraction ≈ 0.5
    }
    func testPictureBlinkCountsFromArrivalNotFromFinish() {
        // finished at 10 off-screen, arrive at 100 → markLit blinks until 108, steady after
    }
    func testSettleNeverReturnsAPastDate() {
        // seen record on its own screen: settle(at: blinkEnd + 1) == nil; every non-nil result is > date
    }
    func testStillInputIsSteadyAndUsesKeyTime() {
        // still: time == keyTime, unitTime == 0.5, unitFraction == 0.5 at any date
    }
}
```

  Fill in the bodies marked `/* … */` with concrete assertions, following the rules above. The `BusyRail.entries` call in the chained test needs Task 5. Either write that assertion in Task 5, or do Tasks 4 and 5 in one sitting.

- [ ] **Step 2:** Run `scripts/test.sh --filter BusyLedgerTests`. Expected: fail.
- [ ] **Step 3:** Implement `BusyLedger.swift`.
- [ ] **Step 4:** Run `scripts/test.sh --filter BusyLedgerTests`. Expected: pass.
- [ ] **Step 5:** Commit with `feat(busy): BusyLedger, lifecycle and the seen rule`.

---

### Task 5: `BusyRail` and `BusyPictureLayout` (Core)

**Files:**
- Create `BusySignals/BusyRail.swift` and `BusySignals/BusyPictureLayout.swift`.
- Test `Tests/CrateDiggerCoreTests/BusyRailTests.swift` and `Tests/CrateDiggerCoreTests/BusyPictureLayoutTests.swift`.

**Rules:**

`BusyRail.entries(ledger)`:
- Keep records with `record.screen != ledger.screen`, and with `isRunning || seenAt == nil`, in start order.

`BusyRail.layout(entries, available:, overflowLabelWidth:)`:
- For `n` from `min(2, count)` down to 0:
  - `overflow = count − n`
  - `w = n·96 + max(0, n−1)·12 + (overflow > 0 ? (n > 0 ? 12 : 0) + overflowLabelWidth : 0)`, plus 14 when the cluster is non-empty
  - return the first layout where `w ≤ available`
- If none fits, return `shown: [], overflow: 0, width: 0`.

`BusyPictureLayout.frame(bandSize:leading:topInset:)`:
- `h = min(84, bandSize.height − topInset)`; nil if `h < 40`.
- `w = 220`; nil if `bandSize.width − (leading + w) < 174`.
- Return `CGRect(x: leading, y: topInset, width: w, height: h)`.

- [ ] **Step 1: Write the failing tests.**
  - **`BusyRailTests`:**
    - own screen excluded;
    - seen excluded and unseen included;
    - start order;
    - `.other` qualifies all jobs (the compact case);
    - the width ladder. Three entries with label width 16:

      | `available` | Result |
      |---|---|
      | 300 | 2 shown + 1 overflow (w = 96 + 12 + 96 + 12 + 16 + 14 = 246) |
      | 240 | 1 + 2 (96 + 12 + 16 + 14 = 138) |
      | 100 | 0 + 3 (16 + 14 = 30) |
      | 20 | empty |

    - two entries at `available` 218 gives 2 and no label;
    - zero entries gives width 0.
  - **`BusyPictureLayoutTests`:**
    - band 838 × 85, leading 345, inset 9 gives `(345, 9, 220, 76)`;
    - band height 45 gives nil;
    - band width 700 gives nil, because 700 − 565 = 135 < 174.
- [ ] **Step 2:** Run `scripts/test.sh --filter 'BusyRailTests|BusyPictureLayoutTests'`. Expected: fail. If the filter regex is not accepted, run each filter separately.
- [ ] **Step 3:** Implement both files.
- [ ] **Step 4:** Run the same filters again, plus `BusyLedgerTests` if the chained test waited on this task. Expected: pass.
- [ ] **Step 5:** Commit with `feat(busy): rail policy and picture layout`.

---

### Task 6: Scene dispatcher, shared glyphs, scene stubs, generic invariants (Core)

**Files:**
- Create `BusySignals/BusyScenes.swift`, which owns `BusySceneInput` (moved here if Task 4 put it elsewhere), `BusyScenes` and `BusySignalTiming.cadence`.
- Create `BusySignals/BusyGlyphs.swift`.
- Create `BusySignals/Scenes/RipScene.swift`, `SecureReadScene.swift`, `ConvertScene.swift`, `ScanScene.swift`, `DownloadScene.swift` and `TransferScene.swift`. Each is a **stub**:

  ```swift
  enum RipScene {
      static func picture(_ input: BusySceneInput) -> BusyDrawing { BusyDrawing(size: BusyDrawing.sceneSize) }
      static func mini(_ input: BusySceneInput) -> BusyDrawing {
          var d = BusyDrawing(size: BusyDrawing.miniSize); BusyGlyphs.miniTrack(&d, input); return d
      }
      static let keyTime: TimeInterval = 0
  }
  ```

- Test `Tests/CrateDiggerCoreTests/BusySceneTests.swift`, the generic invariants.

**`BusyGlyphs`, ported from the sketch:**
- `note(_ d: inout BusyDrawing, x:y:kind:ink:scale:)`, from html:237-251. Apply translate and scale to the coordinates yourself. Note heads are filled ellipses, rotation −0.35, rx 2.8, ry 2. The flag is a `quadCurve`. The beam is a `line` with `weight: 2.2`.
- `disc(_:cx:cy:radius:angle:)`, from html:253-265.
- `miniTrack(_:_:)`, from html:268-273.
  - `lit = isFinished ? 8 : Int(floor((fraction ?? 0) × 8))`
  - packet at `step % 8` while running
- `miniEndInk(_ input) -> BusyInk`, from html:275: `.hot` when `isFinished && markLit`, else `.foreground`.

**`BusySignalTiming.cadence(_ input)`:**

| Input | Result |
|---|---|
| `still` | nil |
| running (`!isFinished`) | 1/16 |
| `blinking` | 1/8 |
| otherwise | nil |

Half a step on purpose (spec §2.1): the animation schedule fires on display frames at least `minimumInterval` apart, so 1/8 s on 60 Hz gives 7.5 fps and skips a step every ~2 s, and 1/2 s aliases a 2 Hz blink. Quantization plus an `Equatable` `BusyCanvas` make the extra ticks free.

`BusySceneInput` gets a **public memberwise init** with defaults (spec §2.1), because the App-target snapshot harness imports Core without `@testable`.

**The generic invariants** run over every kind and states {running at fraction 0, 0.1, 0.5, 0.9, 1 and nil; finished lit; finished unlit; still}, at times {0, 0.7, 3.3, 19.9}. They are written now so they bind each scene as it lands:

```swift
final class BusySceneTests: XCTestCase {
    static func input(_ kind: BusyJobKind, fraction: Double?, time: TimeInterval,
                      finished: TimeInterval? = nil, lit: Bool = true, still: Bool = false) -> BusySceneInput { … }

    func testPicturesStayInsideSceneSpace() {
        for kind in BusyJobKind.allCases { for input in Self.matrix(kind) {
            let d = BusyScenes.picture(kind, input)
            XCTAssertEqual(d.size, BusyDrawing.sceneSize, "\(kind)")
            XCTAssertTrue(CGRect(origin: .zero, size: d.size).insetBy(dx: -0.5, dy: -0.5).contains(d.bounds) || d.shapes.isEmpty,
                          "\(kind) \(input): \(d.bounds)")
        } }
    }
    func testMinisStayInsideMiniSpace() { … }
    func testSameInputSameDrawing() { … }
    func testTimesInsideOneStepDrawTheSame() {
        // the input built from raw times 3.30 and 3.36 quantizes to 3.25 for both
    }
    func testBackgroundInkOnlyEverFills() { … }  // walk shapes; .background never as stroke/line/text ink
}
```

  Two invariants wait for real scenes, so add them now with `try XCTSkipIf(BusyScenes.picture(kind, …).shapes.isEmpty, "\(kind) not drawn yet")`: `testFinishedDiffersFromRunning` and `testMarkLitOnAndOffDiffer`. The skip disappears once each scene task lands. **`testMarkLitOnAndOffDiffer` excludes the `.download` picture** (it still checks the download *mini*): the approved finished cassette has no blinking element, only a steady hot DONE (html:702, README "Hubs stop, label reads DONE"), so on and off are rightly identical there. Do not add a blink to make it pass.

  The in-bounds tests rely on Task 1's sweep-aware arc bounds and clip-aware bounds. At time 19.9 (quantized 19.875) the cyclic scan is mid-swap (u = 0.75) and the outgoing crate is centred at x = −34; it passes only because Task 10 wraps the crates in a clip to the scene rect.

- [ ] **Step 1:** Write `BusySceneTests` and the glyph tests:
  - `testMiniTrackLightsDashesWithProgress`: fraction 0.5 gives 4 cool dashes, 4 dim ones and 1 hot packet.
  - `testMiniTrackLightsNothingWithoutAFraction`.
  - `testMiniEndInkIsHotOnlyWhenFinishedAndLit`.
- [ ] **Step 2:** Run `scripts/test.sh --filter BusySceneTests`. Expected: fail to compile.
- [ ] **Step 3:** Implement the files. In `BusyLedger.sceneInput`, swap the `keyTime` stub for `BusyScenes.keyTime(kind)`.
- [ ] **Step 4:** Run `scripts/test.sh --filter 'BusySceneTests|BusyLedgerTests'`. Expected: pass, with skips for the undrawn scenes.
- [ ] **Step 5:** Commit with `feat(busy): scene dispatcher, shared glyphs and invariants`.

---

### Tasks 7–12: one scene and its mini each (Core, parallel)

Every scene task has the same shape. **Each touches only its own two files.**

- **Files:** modify `BusySignals/Scenes/<Name>Scene.swift` (replace the stub). Create `Tests/CrateDiggerCoreTests/<Name>SceneTests.swift`.
- **Port.** Translate the sketch's `draw(g, s)` and the `MINI` helpers it uses line by line. `g.pal.X` maps to the ink; `g.line(...)` maps to `d.line(...)`.
- **Inputs.** Substitute the sketch's state with `BusySceneInput` per the per-scene table in spec §3.2:

  | Sketch | Swift |
  |---|---|
  | `s.local` | `input.time` |
  | `s.done` | `input.isFinished` |
  | `blink(s.dt)` | `input.markLit` |
  | `s.step` | `input.step` |
  | `s.p` | `input.progress.fraction ?? 0` |

- **`keyTime`.** Choose it so the still frame reads, and justify it in a one-line comment.
- **Step 1:** Write the scene's invariant tests below. They must fail against the stub.
- **Step 2:** Run `scripts/test.sh --filter <Name>SceneTests`. Expected: fail.
- **Step 3:** Port the picture and the mini.
- **Step 4:** Run `scripts/test.sh --filter '<Name>SceneTests|BusySceneTests'`. Expected: pass, and this kind no longer skips in the generic tests.
- **Step 5:** Commit with `feat(busy): <name> scene and mini`.

#### Task 7: `RipScene`

From html:358-389 (picture), html:357 (mini), plus `MINI.disc` and `MINI.file` (html:276-285).

- **Inputs.**
  - Disc angle: `time × 4.7`.
  - Notes: every 0.6 s, life 2 s, using `BusyGlyphs.note`.
  - `k` = `min(completed, total)`, with `total = progress.total ?? max(completed + 1, 1)`.
  - `tp` = `unitFraction`, and `since` = `unitTime`.
- **Stack.** `shown(k) = total > 5 ? Int(ceil(Double(k) × 5 / Double(total))) : k`, at `slabY(j) = 85 − j·5`. The cap is **5**, the sketch's own maximum: a sixth slab at `slabY(5) = 60` (y 60-63) would contain the check's vertex (210, 61).
- **Falling slab** (spec §3.2): only when `k ≥ 1`, `shown(k) > shown(k − 1)` and `unitTime < 0.5`. It moves in 1/8 s steps (html:384-387) to `slabY(shown(k) − 1)`, with `shown(k) − 1` static slabs drawn meanwhile. Otherwise draw `shown(k)` static slabs and nothing falls.
- **Finished.** OK inside the file, and the check at (205,56)–(210,61)–(221,48) when `markLit`.
- **`keyTime`:** 1.25 (three notes in flight: notes 0, 1 and 2, ages 1.25, 0.65 and 0.05 s).
- **"Tnn" label:** `min(completed + 1, total)` (spec §3.2).
- **Tests:**
  - `testStackShowsAtMostFiveSlabsAndStaysBelowTheCheck`: total 20 and completed 20 give 5 slab rects, all with `minY > 61` (the check's lowest point). Also total 6, completed 6.
  - `testCompletionThatKeepsTheShownCountDropsNothing`: total 20, completed 2, `unitTime` 0.1 draws 1 slab and no cool falling slab.
  - `testDiscStopsWhenFinished`: two finished inputs at different `finished` times draw the disc identically.
  - `testCheckOnlyWhenFinishedAndLit`.
  - `testMiniFileFillFollowsUnitFraction`: 0 gives 1 cool fill line (the sketch's loop starts at the bottom line, html:284), 0.95 gives 4.

#### Task 8: `SecureReadScene`

From html:420-447, html:419 (mini) and `MINI.grid` (html:286-291).

- **Inputs.** `k` = `trackOrdinal − 1`, `total` = `trackCount`, `pp` = `phaseFraction`. Pass is 1 for `.pass1` and 2 otherwise.
- **Labels.** The sled reads `"P1"`, `"P2"` or `"RE"`. The header reads `"TRK nn · PASS n"`, or `"TRK nn · RE-READ"`.
- **Band rings.** `bands = min(trackCount, 12)`, and track `k` maps to band `k·bands/trackCount`.
- **Filled cells.** `floor(pp·60)` on `.pass1` and `.pass2`; all 60 (solid) on `.retry`. The sled position uses `pp` in every phase (in `.retry` that is `settled / retryList.count`).
- **Orange cells: `.retry` only** (spec §3.2). `SecureRipEngine` posts `rereads: 0` throughout pass 1 and pass 2 (SecureRipEngine.swift:168, :174, :210, :222) and counts one per sector per attempt during retry (:241), so it is not a cell count. In `.retry`, take all 60 indices sorted by `BusyNoise.unit(Double(k·100 + i))` ascending and draw the first `min(rereads, 6)` hot. Pass 1 and pass 2 never draw hot cells.
- **Mini grid.** `n = isFinished ? 4 : floor(pp·4)`.
- **`keyTime`:** 0. The sled position comes from progress, so the still frame is honest.
- **Tests** (only states the engine really emits):
  - `testFilledCellsFollowPhaseFraction`: pass 1 at 0.5 gives 30 cool outline rects; pass 2 at 0.5 gives 30 solid cool blocks.
  - `testPassesNeverDrawOrange`: pass 1 and pass 2 inputs (rereads 0, as the engine sends) draw no hot block.
  - `testRetryDrawsAFullMapWithCappedOrange`: `.retry` with rereads 3 gives 60 blocks, 3 of them hot; rereads 40 gives exactly 6 hot.
  - `testAtMostTwelveBandRings`: 30 tracks give ≤ 12 dim rings between radius 13 and 36.
  - `testFinishedMapIsFullAndOKBlinks`.

#### Task 9: `ConvertScene`

From html:451-528 (draw at :471-526, mini at :470), `MINI.tall` and `MINI.flat` (html:292-296).

- **Inputs.** `u = (time mod 2.4) / 2.4` and `item = floor(time / 2.4)`. `lossy = !progress.lossless`.
- **Labels.** Before the press, `labels.source` in dim. After it, `labels.target` in hot. Each is omitted when nil.
- **Mini.** `flat(x: 87)` must centre on y = 6. Lossy is a rect at y 3.8, h 4.4, so its midY is 6.
- **`keyTime`:** 1.32 (u ≈ 0.55: squashed lossy, reboxed lossless).
- **Tests:**
  - `testLossyFlattensTheFileUnderThePress`: at u = 0.55 the file rect's height is ≤ 14.
  - `testLosslessReboxesWithoutSquashing`: at u = 0.55 the height is 40 and a cool rect encloses it.
  - `testMiniFlatBlockIsCentredOnTheLine`: the lossy destination rect's midY is 6 ± 0.05.
  - `testLabelsOmittedWhenMissing`.
  - `testPressParksAndOKBlinksWhenFinished`.

#### Task 10: `ScanScene`

From html:530-657 (draw at :548-655, mini at :547), `MINI.folder` and `MINI.crate` (html:297-307).

- **Port changes from the sketch:**
  - Cyclic crates: `crateT = 12·0.375 + 0.5`, `counter = floor(time / crateT)`, `divider = ["A–F","G–M","N–S","T–Z"][counter % 4]`, `rec(i) = counter·12 + i`.
  - Swaps always slide to the next crate, including T–Z to A–F.
  - **Clip the crates.** Wrap both `crate(...)` calls in `d.clipped(to: CGRect(x: 0, y: 0, width: 240, height: 100), radius: 0) { … }`. A swap slides crates up to 160 units sideways (at u = 0.75 the outgoing crate spans x −78…10); the sketch relied on its canvas edge, and the generic in-bounds test relies on this clip.
  - **Finished** (spec §3.2): the crate on screen at the frozen `time` stays: `crate = counter`, or `counter + 1` if `time` is inside a swap. Divider `DIVIDERS[crate % 4]`, `f = 12`, phase 0. The pile counts finds among ids `< (crate + 1)·12`. DONE when `markLit`. Not "always T–Z": in the cyclic port that would make the crate jump at the finish.
- **Keep the sketch's draw order exactly.** The back record rects end at `F + 4`, then the front wall rect is drawn *after* them with a background fill. That ordering is what hides record bottoms; do not reorder. The flipped records leaning on the wall (html:621-626) come *after* the wall and reach y ≈ 80; that is the approved look, keep it.
- **`keyTime`:** 1.5 (four flipped and the front record standing with its cover).
- **Tests:**
  - `testRecordBottomsAreHiddenBehindTheFrontWall`. Every record-shaped rect drawn before the wall has `maxY ≤ F + 4 = 76`. The wall rect `(cx−44, 72, 88, 20)` has a `.background` fill, and it comes later in `shapes` than every such rect.
  - `testPickedPileRecordsAreCrateRecordWidth`: each pile quad's bottom edge spans 2 × 44 × 0.9 = 79.2 ± 0.1.
  - `testDividersCycleInOrder`.
  - `testFinishedHoldsTheCrateOnScreen`: finished at `time` 6.0 (counter 1, flipping) shows "G–M"; finished at `time` 4.75 (inside the first swap) shows "G–M" too; finished at 16.0 shows "T–Z".
  - `testSwapIsClippedToTheScene`: at `time` 19.875 the drawing's `bounds.minX ≥ −0.5`.
  - `testMiniFallenRecordStaysInsideTheCrate`: at `step % 3 == 2` the fallen line's x-span lies within [85, 95.4].

#### Task 11: `DownloadScene`

From html:659-727 (draw at :676-725, mini at :675) and `MINI.antenna` / `MINI.cassette` (html:308-322).

- **The clipped window.** The sketch's clipped window (html:705-712; html:308-312 is `MINI.antenna`) becomes `d.clipped(to: CGRect(x: 137, y: 36, width: 62, height: 18), radius: 9) { … }`.
- **Label.** `labels.source ?? "STREAM"`, or "DONE" in hot when finished.
- **`keyTime`:** 0.5.
- **Tests:**
  - `testCassetteIsOnePointFiveSevenToOne`: the outer rounded rect is 104 × 66, ratio 1.576 ± 0.01.
  - `testWindowIsAStadiumWithAHubInEachEnd`: the window's rounded rect radius = height / 2, and the hub circle centres are at (146, 45) and (190, 45).
  - `testPacksFollowFraction`: the take-up radius at fraction 1 is greater than at 0.1, and the supply radius is smaller.
  - `testHubsStopAndLabelReadsDoneWhenFinished`: DONE in hot, and the finished picture is **equal** with `markLit` true and false (no blink in the approved look; spec §3.2).
  - `testMiniDestinationBlinks`: the finished mini differs between `markLit` true and false.

#### Task 12: `TransferScene`

From html:729-771 (draw at :745-769, mini at :744) and `MINI.laptop` / `MINI.ipod` (html:323-329).

- **Tests:**
  - `testRunningScreenShowsOnlyTheNoEntrySign`. Inside the screen rect (167, 15, 38, 28), the only shapes are one hot circle of r 8 at (186, 29) and one hot diagonal.
  - `testFinishedScreenShowsABlinkingCheck`: lit gives a check polyline and no circle; unlit gives an empty screen.
  - `testClickWheelIsBare`: exactly two foreground circles at (186, 64), r 16 and r 5.5.
  - `testMiniIPodHasSolidScreenAndWheel`: a foreground `block` at (88, 2, 4.6, 2.8) and a foreground dot at (90.3, 7.9).
- **`keyTime`:** 0.

---

### Task 13: Ink palette, renderer, and the monochrome fix (App)

**Files:**
- Modify `Sources/CrateDiggerApp/UI/Theme/CarbonTheme.swift` (`monochromeGlass`, near line 554).
- Create `Sources/CrateDiggerApp/UI/Carbon/Header/BusySignals/BusyCanvas.swift`.
- Test `Tests/CrateDiggerAppTests/MonochromeGlassTests.swift` and `Tests/CrateDiggerAppTests/BusyInkPaletteTests.swift`.

**Interfaces:**

```swift
struct BusyInkPalette: Equatable {
    var foreground, cool, hot, dim, background: Color
    init(theme: CarbonTheme)
    func color(_ ink: BusyInk) -> Color
}

struct BusyCanvas: View {
    let drawing: BusyDrawing
    /// Screen points: 1.15 for a picture, 0.95 for a mini (html:950, :962).
    let lineWidth: CGFloat
    static let glowRadius: CGFloat = 1.5
}
```

**Renderer rules** (spec §2.2):
- **Fit.** `k = min(w/size.w, h/size.h)`, `origin = ((w − size.w·k)/2, (h − size.h·k)/2)`, and `T = CGAffineTransform(translationX: origin.x, y: origin.y).scaledBy(x: k, y: k)`. Build each `Path` in unit space, then `.applying(T)`.
- **Stroking.** Use `StrokeStyle(lineWidth: lineWidth × weight, lineCap: .round, lineJoin: .round)`.
- **Batching.** Walk the shapes in order, batching consecutive shapes with the same (ink, stroke-or-fill, glow, weight). Glowing batches go through `context.drawLayer { l in l.addFilter(.shadow(color: c, radius: Self.glowRadius)); … }`.
- **Arcs.** `Path.addArc(center:radius:startAngle:endAngle:clockwise: false)`. In SwiftUI's flipped coordinates this matches canvas `arc(a0, a1)`. Verify on the contact sheet with the download rings, which must open left and right of the mast.
- **Text.** `context.resolve(Text(s).font(CarbonFont.mono(size·k, weight: .semibold)))`, drawn at the transformed baseline point with anchor `.bottomLeading`, `.bottom` or `.bottomTrailing` per alignment, then nudged down by the descender. The approximation is checked on the contact sheet.
- **Clips.** On `clipBegin`, open a nested `drawLayer` whose context clips to the transformed rounded rect, and draw until the matching `clipEnd`. Implement this recursively over the shape slice.
- **Scene clip.** Clip the whole drawing to the letterboxed scene rect (`origin`, `size·k`), as the sketch's canvas edge did, so nothing off-scene draws into the margins.
- **Equatable.** `BusyCanvas: View, Equatable` on `(drawing, lineWidth)`; callers use `.equatable()`, so a 1/16 s tick inside the same 1/8 s step does not redraw.
- **Background.** The canvas fills nothing itself; the glass behind it shows through. `.background` fills use `theme.oledSurface` for now; whether they read as flat patches on the gradient glass is decided in Task 14 (spec §2.2).
- `.accessibilityHidden(true)`.

- [ ] **Step 1: Write the failing tests**

```swift
@MainActor
final class MonochromeGlassTests: XCTestCase {
    func testMonochromeGlassClearsThePinnedMeterHot() {
        var def = ThemeDefinition(/* as OLEDSurfaceShadeTests builds one */)
        // pin meterHot red and turn monochrome on, as Llama '97 does
        let theme = CarbonTheme(definition: def, resolvedBase: .carbon)
        XCTAssertNotNil(theme.meterHotOverride)
        let glass = theme.monochromeGlass
        XCTAssertNil(glass.meterHotOverride)
        XCTAssertEqual(glass.meterHot, glass.oledForeground)
    }
}

@MainActor
final class BusyInkPaletteTests: XCTestCase {
    func testInksMapOntoTheGlassTheme() { /* foreground/cool/hot/background from .carbon */ }
    func testMonochromeCollapsesCoolAndHotOntoForeground() { /* palette(theme.monochromeGlass) */ }
}
```

  Read `Tests/CrateDiggerAppTests/OLEDSurfaceShadeTests.swift` for how to build a `ThemeDefinition` with overrides, and copy that pattern.
- [ ] **Step 2:** Run `scripts/test.sh --filter 'MonochromeGlassTests|BusyInkPaletteTests'`. Expected: fail.
- [ ] **Step 3:** Add `copy.meterHotOverride = nil` to `monochromeGlass`, with a comment explaining why (it is a pin, like the lamp pins, and outranks `orange`). Then implement `BusyCanvas.swift`.
- [ ] **Step 4:** Run the same filters, plus `swift build`. Expected: pass. Also run `scripts/test.sh --filter MeterDriverTests` to confirm the matrix is unaffected.
- [ ] **Step 5:** Commit with `feat(busy): Canvas renderer; monochrome glass clears pinned Meter High`.

---

### Task 14: Snapshot harness and visual comparison (App)

**Files:** create `Tests/CrateDiggerAppTests/BusySignalSnapshotTests.swift`.

**Interfaces:**

```swift
@MainActor
final class BusySignalSnapshotTests: XCTestCase {
    override func setUp() { FontRegistrar.registerBundledFonts() }
    func testEveryPictureAndMiniRendersInk() throws { … }      // always on
    func testWriteContactSheets() throws {                       // gated
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CRATEDIGGER_BUSY_SNAPSHOTS"] != nil)
        …
    }
}
```

**Implementation:**
- **Repo root:** `URL(fileURLWithPath: #filePath)` up three directories (see `BundledThemeTests.swift:22`).
- **Out dir:** `<root>/.build/busy-signals/`, created when missing.
- **Themes.** Use `.carbon`, and Llama '97 decoded from `Sources/CrateDiggerApp/Resources/Themes/Llama 97.cdtheme/theme.json`, the same way `BundledThemeTests` loads it. **Flatten it first**: its `meterHot: #FF0000` pin and `oledMonochrome` live only inside the `dark` and `light` layers (theme.json:12-94, :95-…), so build `CarbonTheme(definition: llama.resolved(for: .dark), resolvedBase: .carbon)` (and `.light` with `.linen`), as `BundledThemeTests.render` (:156-162) does. Assert `meterHotOverride != nil` before applying the glass, or the R1 row passes without testing anything. Each theme then goes through `theme.oledMonochrome ? theme.monochromeGlass : theme` by hand, because nothing outside `OLEDDisplay` applies the glass theme. Add one pale LCD-style bundled theme as a further row, for the background-fill decision below.
- **Inputs.** Build each `BusySceneInput` directly with its public init (spec §2.1), not through a ledger: `time = p × run`, with the sketch run lengths rip 18, secure 20, convert 22, scan 20, download 16, transfer 18. Use realistic progress:
  - rip: 5 tracks
  - secure: track 3 of 8, pass 2 (rereads 0, as the engine sends), plus one `.retry` cell with rereads 2
  - convert: lossy, labels FLAC → MP3
  - download: label KEXP
- **Cells.** Each is `ZStack { glassBackground; BusyCanvas(...) }.frame(220, 84).environment(\.carbon, glass)`, rendered by `ImageRenderer` at scale 3. `glassBackground` is the real glass: `oledSurface` with the same diagonal gradient `OLEDDisplay` lays over it (:107-124), not a flat fill. Compose a sheet with one row per theme plus a Reduce Motion row, and columns p 0.1 / 0.5 / 0.9 / finished lit / finished unlit / still. Caption each cell in mono 9.
- **Background-fill decision.** On the Carbon and pale-theme rows, check whether the `.background` occluders (cassette, crate, records, file, iPod body) read as flat patches against the gradient. If they do, switch `BusyInkPalette.background` to `oledSurface` composited with the gradient sampled at the picture's centre (spec §2.2). Record the outcome either way in `BusyCanvas`'s doc comment.
- **Minis.** A `minis.png` sheet with every kind at 1× and 4×: running 0.5, finished lit, finished unlit.
- **PNGs.** Write through `NSBitmapImageRep(cgImage:).representation(using: .png, properties: [:])` (see `LogoRenderer.swift`).
- **`index.html`.** List the sheets with "compare with `CrateDigger_DESIGN/busy-signals/busy-signals.html` § <scene>".
- **Smoke test.** Render each picture and mini once on `.carbon`, and assert at least 1% of pixels differ from the surface colour by more than 10/255.

- [ ] **Step 1:** Write the smoke test first and run `scripts/test.sh --filter BusySignalSnapshotTests`. Expected: pass once Tasks 7–13 have landed.
- [ ] **Step 2:** Add the gated sheet writer, then run:

  ```bash
  CRATEDIGGER_BUSY_SNAPSHOTS=1 scripts/test.sh --filter BusySignalSnapshotTests/testWriteContactSheets
  ls .build/busy-signals/
  ```

- [ ] **Step 3: Visual comparison.** Open each PNG with the Read tool. Open the sketch in a browser (claude-in-chrome, or `open CrateDigger_DESIGN/busy-signals/busy-signals.html`) and compare scene by scene against the user-feedback list in spec §1:
  - scan: no record bottoms, pile record size, dividers;
  - mini scan: record inside the crate;
  - mini iPod: solid screen and wheel;
  - big iPod: only the sign;
  - mini convert: centred;
  - cassette: 1.57 : 1, stadium window, hubs in its ends;
  - the Llama row: no red anywhere;
  - arcs open the right way;
  - text sits on its baseline.

  Fix scene or renderer code, re-run, and repeat until each matches. Tune `BusyCanvas.glowRadius` here, and record the final value in its doc comment.
- [ ] **Step 4:** Run `scripts/test.sh --filter 'Busy'`. Expected: every Busy test passes.
- [ ] **Step 5:** Commit with `test(busy): ImageRenderer contact sheets for every scene and mini`. Do not commit the PNGs: `.build/` is ignored.

---

### Task 15: View-model glue (App)

**Files:**
- Create `Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel+BusySignals.swift`.
- Modify `LibraryViewModel.swift` in four places:
  1. Add the stored properties beside `deviceSyncProgress` (≈ :385): `@Published var busy` with an **internal** setter (not `private(set)`: every mutator lives in `LibraryViewModel+BusySignals.swift`, and `private(set)` would only let `LibraryViewModel.swift` write it, so nothing would compile), `busySettleTask`, `busyChannelCancellables`, `busySafetyArmed`, `streamDownloadBusyJob` and `sacdBusyJob` (spec §2.3).
  2. In `oledView.didSet` (:341), call `noteBusyScreenChanged()` **before** the `.search` early return.
  3. In `playerLayout.didSet` (:534), call `noteBusyScreenChanged()`.
  4. In `init`, call `wireBusySignals()` beside `wirePlaybackBindings()`, **after** the saved `oledView` (:1454-1456) and `playerLayout` are restored. `didSet` does not run for those stores inside `init`, so `wireBusySignals()` ends with `busy.show(busyVisibleScreen, at: Date())` to seed the ledger's screen; without it a relaunch onto CNVRT, DUB, SCAN or DEV leaves the ledger on `.other`.
- Test `Tests/CrateDiggerAppTests/BusyScreenMappingTests.swift`.

**Interfaces:** spec §2.3, exactly.

**Implementation notes:**
- **`beginBusyJob`.** Mutate `busy` through its `begin`, passing `kind`, `screen.busyScreen`, `labels` and `BusyProgress(lossless:)`. Then call `rescheduleBusySettle()`. It returns the id.
- **`endBusyJob(nil, _)`** is a no-op, so call sites can pass an optional.
- **`showBusyJob(id)`.**
  - Look up the record and its `screen.oledView`. If there is none, return.
  - If `CompactCommandPolicy.availability(.selectDisplay, in: playerLayout) == .expandsFirst`, call `expandToFull()`.
  - Then set `oledView = target`.
- **`rescheduleBusySettle()`.** Cancel `busySettleTask`. Compute `next = busy.settle(at: Date())`, which mutates and publishes. If `next` is non-nil, start a `Task { @MainActor in try? await Task.sleep(until:…) ; self.rescheduleBusySettle() }`. Use `Task.sleep(nanoseconds:)` computed from `next.timeIntervalSinceNow`, clamped to ≥ 0.05 s. This terminates only because `settle` never returns a date at or before its argument (Task 4, `testSettleNeverReturnsAPastDate`). To avoid republishing the whole view model for nothing, assign `busy` only when the settled copy differs (`var copy = busy; let next = copy.settle(at:); if copy != busy { busy = copy }`).
- **`wireBusySignals()`.**
  - Four `sink`s on `$conversionProgress`, `$secureRipProgress`, `$scanProgress` and `$deviceSyncProgress`, mapping per the spec §2.3 table into `busy.update(record.id, progress: record.progress.with(...), at: Date())`.
  - The conversion sink finds its record with `busy.records.last { $0.isRunning && ([.rip, .convert, .download].contains($0.kind) || ($0.kind == .transfer && $0.screen == .conversion)) }`.
  - **The safety net, conversion and sync sinks only** (spec §2.3). Track each channel's previous `isRunning`. On a false → true edge, store the matching running record's id in `busySafetyArmed[channel]`. On a true → false edge, wait 3 s; if that armed record is still running and the channel is still idle, call `endBusyJob(id, .failed)` (removed silently, never a fake success) and `AppLog.ui.warning(...)`.
  - **Scan sink: log only.** Unstamped moves, consolidate, copy-to-library and the Adding → crate status share `scanProgress` and can finish while a dig runs, so the scan sink never ends a record. If a scan record is still running 30 s after the channel went idle and stayed idle, it logs the warning and leaves the record for the next `begin` to retire.
- **`debugSimulateBusyJobs(_ kinds: [BusyJobKind], finished: Bool)`**, under `#if DEBUG`. Begin each kind on its `defaultScreen.oledView!`, and give each a `Task` that updates progress `i/40` every 0.5 s for 20 s, then `.completed`. With `finished`, complete immediately.

- [ ] **Step 1: Write the failing test.**

```swift
final class BusyScreenMappingTests: XCTestCase {
    func testEveryOLEDViewMapsToItsBusyScreen() {
        let expected: [OLEDView: BusyScreen] = [.dub: .dub, .conversion: .conversion, .scan: .scan, .devices: .devices,
                                                .nowPlaying: .other, .remoteSync: .other, .search: .other, .stats: .other]
        for view in OLEDView.allCases { XCTAssertEqual(view.busyScreen, expected[view], "\(view)") }
    }
    func testJobScreensMapBack() {
        for s in BusyScreen.allCases where s != .other { XCTAssertEqual(s.oledView?.busyScreen, s) }
        XCTAssertNil(BusyScreen.other.oledView)
    }
}
```

- [ ] **Step 2:** Run `scripts/test.sh --filter BusyScreenMappingTests`. Expected: fail.
- [ ] **Step 3:** Implement the extension and the four `LibraryViewModel.swift` edits.
- [ ] **Step 4:** Run `swift build` and `scripts/test.sh --filter 'BusyScreenMappingTests|OLEDViewCycleTests'`. Expected: pass.
- [ ] **Step 5:** Commit with `feat(busy): view-model ledger, progress sinks and mini navigation`.

---

### Task 16: Stamp the start and finish sites (App)

**Files:**
- `LibraryViewModel.swift`: `ripCD`, `loadFolders`, `selectDevice`, `importDroppedURLs`, `addURLsToCrate`.
- `+Conversion.swift`: `runConversionQueue`.
- `+ExternalDeviceTransfer.swift`: `runCopyTransferQueue`.
- `+DeviceSync.swift`: `syncQueuedTransfers`.
- `+StreamDownload.swift`: `downloadStream`, `streamDownloadEnded`, `endStreamDownloadUI`.
- `+SACDImport.swift`: `importSACDISO`, `finishSACDImport`.

Follow spec §3.1's table exactly. Read each function whole before editing; the line numbers are approximate.

- [ ] **Step 0: User sign-off gate. Do not start this task without it.** Put spec §15's five decisions to the user (the jump-to-NOW removal, copy transfer on CNVRT, the 8 s picture blink cap, the unreachable secure finished frame, the SACD BUSY guard) and record the answers in spec §15. Build each item as answered. A "no" to item 1 means: skip the deletions in Steps 1, 5 and 6 and the Step 8 grep. A "no" to item 3 means changing `pictureBlinkDuration` to "while on screen" in Core first. Tasks 1-15 do not depend on the answers.
- [ ] **Step 1: `ripCD`.**
  - Before the `Task`, `let busyJob = beginBusyJob(secure ? .secureRead : .rip, on: .dub)`.
  - Where the secure read completes and `conversionProgress` is reset for the encode (≈ :2647-2658), call `handBusyJob(busyJob, to: .rip)`.
  - In the final `MainActor.run`, call `endBusyJob(busyJob, outcome)` with the outcome computed as in §3.1. Place it **before** `loadFolders`, so the rip is finished before the scan begins.
  - In the `catch`, map `CancellationError` to `.cancelled` and anything else to `.failed`.
  - If the user signed off on spec §15 item 1: **delete** `self.oledView = .nowPlaying` in both places (:2741, :2767), and leave a comment that the finished frame needs DUB to stay put (spec §5).
- [ ] **Step 2: `runConversionQueue`.**
  - After the initial snapshot: `let busyJob = beginBusyJob(.convert, on: .conversion, labels: BusyLabels(source: dominantExtension(jobs), target: preset.outputFormat.shortLabel), lossless: preset.outputFormat.isLossless)`.
  - `dominantExtension` is a small private helper: the most common `sourceURL.pathExtension`.
  - Use `OutputFormat.rawValue.uppercased()` if `OutputFormat` has no short display name. Check `ConversionModels.swift` first, and reuse anything that exists.
  - After the outcome counts, `endBusyJob(busyJob, cancelled > 0 ? .cancelled : (succeeded == 0 && failed > 0 ? .failed : .completed))`.
- [ ] **Step 3: `runCopyTransferQueue`.** Call `beginBusyJob(.transfer, on: .conversion)`. After the terminal snapshot, capture `let wasCancelled = conversionTask?.isCancelled ?? false` **before** `conversionTask = nil`, then end it `.cancelled` if `wasCancelled`, `.failed` if nothing succeeded, else `.completed`. The loop counts cancelled items as failures (:388-390), so without the flag a cancelled partial copy would blink a finished check.
- [ ] **Step 4: `syncQueuedTransfers`.** Call `beginBusyJob(.transfer, on: .devices)` beside `deviceSyncProgress = …` (:289). After the terminal snapshot (:451), end it `.failed` if `outcome.failed == total && total > 0`, else `.completed`.
- [ ] **Step 5: Download.**
  - Store the id in a new stored `var streamDownloadBusyJob: BusyJobID?` (it must go in `LibraryViewModel.swift`, because extensions cannot hold storage). Set it in `downloadStream` with `labels: BusyLabels(source: stream.channel ?? "STREAM")`. Use whichever channel or uploader property `StreamSource` really has; check `Models/StreamSource.swift`.
  - In `streamDownloadEnded`, before `endStreamDownloadUI()`, end it with `.completed` on success, `.cancelled` if `streamDownloadCancelled`, else `.failed`.
  - In the `catch` around `StreamDownloader(...).download(...)` in `downloadStream` (:93-96), end it `.failed` before `endStreamDownloadUI()`. That path never reaches `streamDownloadEnded`.
  - Clear `streamDownloadBusyJob` after ending it.
  - If the user signed off on spec §15 item 1: in `endStreamDownloadUI`, delete `if oledView == .dub { oledView = .nowPlaying }`.
- [ ] **Step 6: SACD.**
  - If signed off (spec §15 item 5): add `guard !isConversionRunning else { return showOLEDNotice("BUSY") }` at the top of `importSACDISO`, like `requestCDRip` (:2552) and `downloadStream` (:41). Today it has no guard and can start beside a convert or a rip.
  - `beginBusyJob(.rip, on: .dub)` in `importSACDISO`, stored in `sacdBusyJob` (a stored property).
  - `finishSACDImport(alert:outcome:)`, where each caller passes its outcome.
  - If signed off (spec §15 item 1): delete the jump to NOW (:117).
- [ ] **Step 7: Scans.** `beginBusyJob(.scan, on: .scan)`:
  - in `loadFolders` only when `!isRestore`, captured into the `Task` and ended `.completed` after `handleImport`;
  - in `selectDevice`'s scan, ended at its `.idle` write (:2493);
  - in `importDroppedURLs`, ended `.failed` on the empty branch and `.completed` after staging;
  - in `addURLsToCrate`, at its terminal write.

  A cancelled `loadFolders` returns early without ending; the next `begin` retires it.
- [ ] **Step 8:** (Only if spec §15 item 1 was signed off.) Run `grep -n "oledView = .nowPlaying" Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel.swift Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel+StreamDownload.swift Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel+SACDImport.swift`. Expected: only the playback and remote-sync sites remain (:3227 and :2250/:2255); none in `ripCD`, download or SACD.
- [ ] **Step 9:** Run `swift build` and `scripts/test.sh`. Expected: the full suite passes.
- [ ] **Step 10:** Commit with `feat(busy): stamp every job's start and finish; keep DUB on screen after a job ends`.

---

### Task 17: Picture in the panes (App)

**Files:**
- Create `Sources/CrateDiggerApp/UI/Carbon/Header/BusySignals/BusyPictureView.swift`.
- Modify `OLEDDisplay.swift`: `OLEDPaneScaffold` (:419), `DubPane`, `ConversionPane`, `ScanPane` and `DevicesPane`.

**`BusyPictureView(recordID: BusyJobID)`:**
- `@EnvironmentObject model`, `@ObservedObject private var visibility = AppVisibility.shared`, `@Environment(\.accessibilityReduceMotion) reduceMotion`.
- Body:
  - `if let record = model.busy.record(recordID)`, compute `let probe = model.busy.sceneInput(for: record, at: Date(), still: reduceMotion)` and `let cadence = BusySignalTiming.cadence(probe)`.
  - Then `TimelineView(.animation(minimumInterval: cadence ?? 1, paused: cadence == nil || !visibility.isVisible)) { ctx in BusyCanvas(drawing: BusyScenes.picture(record.kind, model.busy.sceneInput(for: record, at: ctx.date, still: reduceMotion)), lineWidth: 1.15).equatable() }`. `cadence` is 1/16 s running and 1/8 s blinking (spec §2.1).

**Scaffold:**
- Add `var picture: BusyJobRecord? = nil` to `OLEDPaneScaffold`. Keep the generic builders.
- When `picture == nil`, the body is today's `VStack`, untouched.
- When it is set:

```swift
VStack(alignment: .leading, spacing: 0) {
    GeometryReader { geo in
        let leading = OLEDCells.textLeading(ofColumn: 2, in: geo.size.width)
        if let frame = BusyPictureLayout.frame(bandSize: geo.size, leading: leading, topInset: NPTitles.capTopInset()) {
            let textWidth = frame.minX - OLEDCells.cellPadding * 2   // stop at the rail's own gutter
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .bottom, spacing: 0) {
                    headline().frame(maxWidth: textWidth, alignment: .leading)
                    Spacer(minLength: 0)
                    readout()
                }
                Spacer(minLength: 8)
                ticker().frame(maxWidth: textWidth, alignment: .leading)
            }
            .overlay(alignment: .topLeading) {
                BusyPictureView(recordID: picture.id)
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX, y: frame.minY)
                    .id(picture.id)
            }
        } else {
            todaysTopPart   // same as the nil path's top part
        }
    }
    cells()
}
```

  The headline and the ticker stop at `frame.minX − 2 × cellPadding`, through an explicit `maxWidth`, not trailing padding: the readout sits in the same HStack, so a padding of `width − frame.minX` would subtract the readout and its gap a second time (spec §5). The sketch above is the intent; choose the simplest correct form.
- **The ticker's meta.** `DSPTicker`'s prefix and meta are `.fixedSize()`, so they cannot shrink to the ≈ 325 pt beside the picture. In `ConversionPane.previewBody` the prefix plus "TEMPLATE · {ARTIST}/{YEAR} {ALBUM}" alone is ≈ 384 pt. Every pane that passes a picture passes `meta: nil` to its `DSPTicker` while the picture is non-nil (`meta` is already optional). The path between prefix and meta truncates from the head as today.
- **`NPTitles.capTopInset()`** must be reachable. It is in the same file, so this works.

**Panes:** pass `picture: model.busyPicture(on: .dub)` (or the pane's own screen) from every body listed in spec §5. In `DubPane`, replace `secureOverall` with `BusySecureRead(secure).overall` and delete the private copy.

- [ ] **Step 1:** Implement both files, then run `swift build`.
- [ ] **Step 2: Manual capture**, never pkill. Each run below launches the debug binary in the background, waits 10 s, then stops it by its PID. The hook's timing decides this: `CRATEDIGGER_OLED` is applied at +7.0 s and the snapshots land at +4.0 s (`dub.png`, still the saved screen) and +8.0 s (`dub.late.png`, the one to read). Killing at 6 s would leave only the useless first one. The snapshot hook needs `CRATEDIGGER_BUSY` from Task 19; if Task 19 has not landed, do this step after it.

```bash
mkdir -p /Volumes/EX_3/Code/CrateDigger/.build/busy-signals
CRATEDIGGER_BUSY=rip CRATEDIGGER_OLED=cdRip CRATEDIGGER_SNAPSHOT_PATH=/Volumes/EX_3/Code/CrateDigger/.build/busy-signals/dub.png /Volumes/EX_3/Code/CrateDigger/.build/debug/CrateDiggerApp & PID=$!; sleep 10; kill $PID
# read .build/busy-signals/dub.late.png
```

  Repeat for `convert` / `conversion`, `scan` / `scan` and `transfer` / `devices`. Read each `.late.png` and confirm:
  - the picture sits between the headline and the readout;
  - the cell rail is fully visible;
  - the headline does not run under the picture;
  - on CNVRT with the template layout, the ticker shows no meta beside the picture and does not run under it.

  Also repeat once with a theme whose header is 120 pt (or temporarily `CarbonLayout.headerHeight`), and confirm the picture drops out cleanly.
- [ ] **Step 3:** Run `scripts/test.sh`. Expected: pass.
- [ ] **Step 4:** Commit with `feat(busy): picture window on DUB, CNVRT, SCAN and DEV`.

---

### Task 18: Rail minis and the notice plate (App)

**Files:**
- Create `Sources/CrateDiggerApp/UI/Carbon/Header/BusySignals/BusyRailMinis.swift`.
- Modify `OLEDDisplay.swift`: `DisplayRail` (:155-249), and the `oledNotice` overlay (:198-213).

**`BusyRailMinis(available: CGFloat)`:**
- `@EnvironmentObject model`, plus visibility and reduce motion as in Task 17.
- It reads `let entries = BusyRail.entries(model.busy)` and `let layout = BusyRail.layout(entries, available:, overflowLabelWidth: 16)`.
- For each shown id it draws a `Button { model.showBusyJob(id) } label: { BusyMiniView(record:) }`, styled `.buttonStyle(.plain)`, with `.frame(width: 96, height: 12)`, `.contentShape(Rectangle())`, `.background(WindowDragGuard())` and the accessibility label and hint from spec §4.
- Then, if `overflow > 0`, `Text("+\(overflow)")` in mono 8 bold, `oledFGo(0.5)`.
- The cluster is `HStack(spacing: 12)` with `.padding(.trailing, layout.shown.isEmpty && layout.overflow == 0 ? 0 : 14)` and `.fixedSize()`.
- **It must not change the rail's height** (spec §4). The rail is one text line tall, 11.88 pt by default and ≈ 9.8 pt on Llama '97, so a 12 pt mini in the flow would grow it and make the pane jump whenever a mini comes or goes. In `DisplayRail`, insert a zero-height slot, `Color.clear.frame(width: layout.width, height: 0)`, and draw the cluster in its `.overlay(alignment: .center)`, unclipped. The slot gives the cluster its width and contributes no height.

**`BusyMiniView(record:)`** is the same `TimelineView` pattern as `BusyPictureView`, with `BusyScenes.mini` and `lineWidth: 0.95`.

**`DisplayRail`:**
- Measure the rail width with `.background(GeometryReader { Color.clear.preference(key: RailWidthKey.self, value: $0.size.width) })`.
- Measure the annunciator `HStack` the same way, with `AnnunciatorWidthKey`.
- Store both in `@State`.
- `available = railWidth − annunciatorWidth − (v == .nowPlaying ? 86 : 178)`, using named constants with the measurement comment from spec §4.
- Insert the zero-height slot carrying `BusyRailMinis(available:)` between `RailLive(...)…padding(.trailing, 14)` and the annunciator `HStack`.
- **Notice plate:** wrap the notice `Text` in `.padding(.horizontal, 6).padding(.vertical, 2).background(theme.oledSurface)`.

- [ ] **Step 1:** Implement, then run `swift build`.
- [ ] **Step 2: Manual capture** with the Task 19 hook, using Task 17's recipe (run 10 s, `kill $PID`, read the `.late.png`). Check each of these:
  - `CRATEDIGGER_BUSY=rip,scan,download CRATEDIGGER_OLED=nowPlaying`: two minis plus "+1", and the annunciators are intact.
  - The same on `conversion`.
  - `CRATEDIGGER_COMPACT=1`: minis in compact.
  - A 1200 pt window, set with `CRATEDIGGER_WINDOW_WIDTH` if such a hook exists; otherwise resize by hand: nothing clips.
  - `CRATEDIGGER_BUSY=rip:done CRATEDIGGER_OLED=nowPlaying CRATEDIGGER_SNAP_EXTRA=1`: the destination blinks. Compare `.late.png` (+8.0 s) with `.late2.png` (+8.5 s), half a 2 Hz blink apart; one should show the destination hot and the other not. The base snaps are 4 s apart, a whole number of blink periods, so they always show the same phase.
  - The rail's height is the same with and without minis: compare a capture with `CRATEDIGGER_BUSY` against one without, on Carbon and on Llama '97, and confirm the cell rail sits at the same y.
- [ ] **Step 3: Interactive check** (a human or computer-use, on the debug binary only):
  - clicking a mini switches the screen;
  - clicking its top 3 pt does not drag the window;
  - in compact, a click expands the window and then switches.
- [ ] **Step 4:** Run `scripts/test.sh`. Expected: pass.
- [ ] **Step 5:** Commit with `feat(busy): rail minis with +N, click to the job's screen; notice gets a backing plate`.

---

### Task 19: DEBUG hook and idle-cost check (App)

**Files:** modify `Sources/CrateDiggerApp/AppDelegate.swift` (`installSnapshotHookIfRequested`, :485).

- [ ] **Step 1: Add the hook** (spec §12).
  - It parses `CRATEDIGGER_BUSY`: comma-separated `BusyJobKind` raw values, with an optional `:done` suffix on the whole value, and calls `controller.model.debugSimulateBusyJobs(kinds, finished:)` once the model exists.
  - **Install it before the `CRATEDIGGER_SNAPSHOT_PATH` guard** (AppDelegate.swift:487), which today returns early and would make the hook inert in the idle-cost run below. When `CRATEDIGGER_BUSY` is set, also apply `CRATEDIGGER_OLED` at +1 s outside the guard; the existing +7.0 s application inside the guard stays for snapshot runs.
  - Add `CRATEDIGGER_SNAP_EXTRA=1` inside the guard: one more `snap("late2")` at +8.5 s, for blink phases.
  - Document all three in the hook's header comment beside the other `CRATEDIGGER_*` switches.
- [ ] **Step 2:** Run `swift build`. Launch `CRATEDIGGER_BUSY=convert CRATEDIGGER_OLED=conversion /Volumes/EX_3/Code/CrateDigger/.build/debug/CrateDiggerApp &` (no snapshot path needed after Step 1), and note `PID=$!`.
- [ ] **Step 3: Idle-cost check.**
  - With the window visible, run `top -pid $PID -l 3 -stats cpu` and record the CPU while the scene runs.
  - Then minimise **this process's** window, never a global keystroke (the frontmost app may be the user's running `/Applications/CrateDigger.app`): `osascript -e "tell application \"System Events\" to tell (first process whose unix id is $PID) to set value of attribute \"AXMinimized\" of window 1 to true"`, or by hand. Record the CPU again. It must drop back to the idle baseline.
  - Turn on Reduce Motion (System Settings ▸ Accessibility ▸ Display) and confirm a still frame and idle CPU. If the setting can't be changed, note it as unverified.
  - `kill $PID`.
- [ ] **Step 4:** Commit with `feat(busy): CRATEDIGGER_BUSY debug hook`.

---

### Task 20: Documentation

**Files:**
- `CLAUDE.md`: a "Busy Signals" paragraph under the UI section, covering:
  - the ledger as the one truth;
  - stamping at start and finish sites, and that a new job needs both stamps or the safety net logs it;
  - stateless scenes;
  - the contact-sheet command;
  - `CRATEDIGGER_BUSY`;
  - the removed jumps to NOW, and why.

  Also add `+BusySignals` to the extension list.
- `CrateDigger_DESIGN/busy-signals/README.md`: set the status line to "Specced and built 2026-10-15; spec at docs/superpowers/specs/2026-10-15-busy-signals-design.md".

- [ ] **Step 1:** Edit both files. Keep the CLAUDE.md voice: dense, and explaining why.
- [ ] **Step 2:** Run `scripts/test.sh`. Expected: the full suite passes with the new count. Run `swift build -c release`. Expected: success.
- [ ] **Step 3:** Commit with `docs(busy): document Busy Signals in CLAUDE.md`.

---

## Final verification

- [ ] `scripts/test.sh`: everything passes, and the count is the baseline plus the new tests.
- [ ] Run `CRATEDIGGER_BUSY_SNAPSHOTS=1 scripts/test.sh --filter BusySignalSnapshotTests` and have every sheet compared against the sketch by eye.
- [ ] Manual captures of DUB, CNVRT, SCAN, DEV, NOW with minis, compact with minis, and the Llama '97 theme.
- [ ] Summary for the user that restates spec §15's decisions as they were answered at Task 16 Step 0 (jump to NOW, copy transfer's screen, picture blink cap, secure finished frame, SACD guard), so the summary confirms what was agreed rather than announcing it.
