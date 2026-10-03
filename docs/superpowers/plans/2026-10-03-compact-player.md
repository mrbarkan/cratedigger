# Compact Player Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the main window collapse into a one-rack-unit "compact player": the playing album's art on the left, the real OLED display (NOW screen) over the real transport footer on the right, with no sources, browser or inspector.

**Architecture:**
- One window and one `LibraryViewModel`. A published `playerLayout` (`.full` / `.compact`) makes `CarbonRootView` draw either today's Header / MainShell / Footer stack or a new `CompactDeckView` inside the same chassis.
- `MainWindowController` follows the layout. It swaps min/max size and animates between two independently saved frames.
- The pure decisions (launch layout, which menu commands work in compact, compact window geometry) live in Core or in `WindowFramePlanner`, each with a test.

**Tech Stack:** Swift 6 / SwiftPM, AppKit + SwiftUI (macOS), XCTest via `scripts/test.sh`.

**Spec:** `docs/superpowers/specs/2026-10-03-compact-player-design.md`. Read the **Amendments** section at the end, because it overrides §1–§3 where they differ.

## Global Constraints

- Branch: all work lands on `v2.3` (cut from `main`, no upstream set). Never commit to `v2.2` or `main`. Do not push.
- Run tests with `scripts/test.sh` (optionally `--filter <Class>`), never bare `swift test`. Build with `swift build`. The debug binary is `.build/debug/CrateDiggerApp`.
- Core stays free of AppKit views and app state. New Core types are `public` and `Sendable`.
- The persisted raw values `"full"` and `"compact"` must never change.
- Shortcut: Window ▸ Compact Player is **⌥⇧⌘M**. It must not collide: ⇧⌘M is Mini Player, and ⌥⌘M is the system's Minimize All.
- Standard-geometry numbers (from `CarbonGeometry.standard`):
  - art side **230**;
  - footer minimum **896**;
  - compact window height **302**;
  - compact minimum width **1174**.

  All are derived from geometry, never hard-coded in views.
- The display in compact always shows NOW. `model.oledView` is never written to make that happen.
- Mini Player and Full Screen Player behaviour is unchanged.
- Commit messages end with `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`.

## Review Focus

1. **A panel open when entering compact** (Edit Tags, Match Tags Online). After expanding, the same command must reopen it. Covered by Task 5's hoist and its manual check.
2. **A theme whose geometry differs** (taller header or footer), selected while compact. The window must re-plan its fixed height, and the art must stay square. Covered by Task 3's `testCompactHeightFollowsGeometry` and Task 9's theme observer.
3. **A screen narrower than the compact minimum.** The window must stay fully on screen, clamped, and never placed off-screen. Covered by Task 3's `testCompactPlanClampsOnNarrowScreen`.
4. **Quitting in compact, then launching with no library chosen** (fresh install, or a reset index folder). The app must open full for onboarding. Covered by Task 1's `testLaunchIsFullWhenNoLibraryChosen`.
5. **Frames crossing slots.** A saved compact frame must never be applied to, or written over, the full frame, and a saved compact frame wins over the anchor. Covered by Task 3's `testCompactPlanRestoresSavedFrameOverAnchor` and Task 9's slot routing.

---

## File map

| File | Status | Responsibility |
|---|---|---|
| `Sources/CrateDiggerCore/Models/PlayerLayout.swift` | create | `PlayerLayout` enum + `launchLayout` rule |
| `Sources/CrateDiggerCore/Models/CompactCommandPolicy.swift` | create | `PlayerCommand`, `CommandAvailability`, the policy |
| `Sources/CrateDiggerCore/Services/PreferencesStore.swift` | modify | `playerLayout`, `savedCompactWindowFrame` |
| `Sources/CrateDiggerApp/UI/Carbon/Footer/FooterShell.swift` | modify | `FooterMetrics`, `showsLocate`, computed centring |
| `Sources/CrateDiggerApp/UI/Carbon/Footer/TransportCluster.swift` | modify | `showsLocate`, `keyCounts(showsLocate:)` |
| `Sources/CrateDiggerApp/UI/Carbon/Footer/PositionDial.swift`, `Controls/VolumeKnob.swift` | modify | read `FooterMetrics.podMinWidth` |
| `Sources/CrateDiggerApp/UI/CompactDeckMetrics.swift` | create | all compact geometry, derived from `CarbonGeometry` |
| `Sources/CrateDiggerApp/UI/WindowFramePlanner.swift` | modify | `compactPlan(...)`, `CompactWindowPlan` |
| `Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel.swift` | modify | stored `playerLayout`, sheet `didSet`s, `searchFocusPending` |
| `Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel+CompactPlayer.swift` | create | toggle / expand / `nowPlayingAlbum` / `showNowPlayingArtwork` |
| `Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel+Search.swift` | modify | `requestSearchFocus` sets pending, `consumeSearchFocusRequest` |
| `Sources/CrateDiggerApp/UI/Carbon/LibraryPresentations.swift` | create | every sheet/panel/trigger both layouts need |
| `Sources/CrateDiggerApp/UI/Carbon/Main/MainShell.swift` | modify | presentations removed (moved) |
| `Sources/CrateDiggerApp/UI/Carbon/Inspector/InspectorPane.swift` | modify | Fix Tags / Match panels removed (moved) |
| `Sources/CrateDiggerApp/UI/Carbon/Main/NowPlayingCover.swift` | create | cover loading shared by Mini Player and compact deck |
| `Sources/CrateDiggerApp/UI/Carbon/Main/MiniPlayer/MiniPlayerView.swift` | modify | uses `NowPlayingCover` |
| `Sources/CrateDiggerApp/UI/Carbon/Header/OLEDDisplay.swift` | modify | `oledScreenOverride` environment value |
| `Sources/CrateDiggerApp/UI/Carbon/Main/CompactDeck/CompactDeckView.swift` | create | the rack unit |
| `Sources/CrateDiggerApp/UI/Carbon/CarbonRootView.swift` | modify | layout switch + presentations |
| `Sources/CrateDiggerApp/UI/MainWindowController.swift` | modify | layout observer, per-mode frames, zoom |
| `Sources/CrateDiggerApp/AppDelegate.swift` | modify | menu item, policy in `validateMenuItem`, expand-first |
| `Sources/CrateDiggerApp/UI/Carbon/Main/Browser/BrowserSearchBar.swift` | modify | focus on appear when pending |
| `Sources/CrateDiggerApp/UI/Carbon/Main/Browser/ColumnList.swift` | modify | scroll to target on appear |
| `Tests/CrateDiggerCoreTests/PlayerLayoutTests.swift` | create | |
| `Tests/CrateDiggerCoreTests/CompactCommandPolicyTests.swift` | create | |
| `Tests/CrateDiggerAppTests/CompactDeckMetricsTests.swift` | create | |
| `Tests/CrateDiggerAppTests/WindowFramePlannerTests.swift` | modify | compact plan tests |
| `CLAUDE.md` | modify | document the compact layout |

---

### Task 1: `PlayerLayout` and its preferences (Core)

**Files:**
- Create: `Sources/CrateDiggerCore/Models/PlayerLayout.swift`
- Modify: `Sources/CrateDiggerCore/Services/PreferencesStore.swift` (the `Key` enum near line 24; a new section after `savedWindowFrame`, near line 107)
- Test: `Tests/CrateDiggerCoreTests/PlayerLayoutTests.swift`

**Interfaces:**
- Produces:
  - `public enum PlayerLayout: String, CaseIterable, Sendable { case full, compact }`
  - `public static func launchLayout(saved: PlayerLayout?, libraryChosen: Bool) -> PlayerLayout`
  - `PreferencesStore.playerLayout: PlayerLayout?`
  - `PreferencesStore.savedCompactWindowFrame: CGRect?`

- [ ] **Step 1: Write the failing tests**

```swift
#if canImport(XCTest)
import CoreGraphics
import XCTest
@testable import CrateDiggerCore

final class PlayerLayoutTests: XCTestCase {
    func testRawValuesAreStableBecauseTheyArePersisted() {
        XCTAssertEqual(PlayerLayout.full.rawValue, "full")
        XCTAssertEqual(PlayerLayout.compact.rawValue, "compact")
    }

    func testLaunchFollowsSavedLayoutWhenLibraryChosen() {
        XCTAssertEqual(PlayerLayout.launchLayout(saved: .compact, libraryChosen: true), .compact)
        XCTAssertEqual(PlayerLayout.launchLayout(saved: .full, libraryChosen: true), .full)
        XCTAssertEqual(PlayerLayout.launchLayout(saved: nil, libraryChosen: true), .full)
    }

    func testLaunchIsFullWhenNoLibraryChosen() {
        for saved in [nil, PlayerLayout.full, .compact] {
            XCTAssertEqual(PlayerLayout.launchLayout(saved: saved, libraryChosen: false), .full)
        }
    }

    func testPreferenceRoundTripsAndUnknownReadsAsNil() {
        let defaults = makeScratchDefaults()
        let prefs = PreferencesStore(defaults: defaults)
        XCTAssertNil(prefs.playerLayout)
        prefs.playerLayout = .compact
        XCTAssertEqual(prefs.playerLayout, .compact)
        defaults.set("portrait", forKey: "cratedigger.ui.playerLayout")
        XCTAssertNil(prefs.playerLayout)
        prefs.playerLayout = nil
        XCTAssertNil(defaults.object(forKey: "cratedigger.ui.playerLayout"))
    }

    func testCompactFrameIsStoredApartFromTheFullFrame() {
        let prefs = PreferencesStore(defaults: makeScratchDefaults())
        let full = CGRect(x: 10, y: 20, width: 1400, height: 920)
        let compact = CGRect(x: 30, y: 40, width: 1300, height: 302)
        prefs.savedWindowFrame = full
        prefs.savedCompactWindowFrame = compact
        XCTAssertEqual(prefs.savedWindowFrame, full)
        XCTAssertEqual(prefs.savedCompactWindowFrame, compact)
        prefs.savedCompactWindowFrame = nil
        XCTAssertNil(prefs.savedCompactWindowFrame)
        XCTAssertEqual(prefs.savedWindowFrame, full)
    }
}
#endif
```

- [ ] **Step 2: Run to verify failure**

Run: `scripts/test.sh --filter PlayerLayoutTests`
Expected: compile failure, "cannot find 'PlayerLayout' in scope".

- [ ] **Step 3: Implement**

`Sources/CrateDiggerCore/Models/PlayerLayout.swift`:

```swift
import Foundation

/// How the main window is laid out: the whole console, or the compact
/// player — one rack unit of art, display and transport with no browser.
/// The raw values are persisted; never rename them.
public enum PlayerLayout: String, CaseIterable, Sendable {
    case full
    case compact

    /// The layout to open in. A compact player has nowhere to put the
    /// first-run flow, so without a chosen library the app always opens full,
    /// whatever was saved.
    public static func launchLayout(saved: PlayerLayout?, libraryChosen: Bool) -> PlayerLayout {
        guard libraryChosen else { return .full }
        return saved ?? .full
    }
}
```

In `PreferencesStore.swift`, add to `private enum Key` (after `windowFrame`):

```swift
        static let compactWindowFrame = "cratedigger.window.compactFrame"
        static let playerLayout = "cratedigger.ui.playerLayout"
```

Add after the `savedWindowFrame` property:

```swift
    /// The compact player's frame, kept apart from `savedWindowFrame` so each
    /// layout reopens where it was left.
    public var savedCompactWindowFrame: CGRect? {
        get {
            guard let data = defaults.data(forKey: Key.compactWindowFrame) else { return nil }
            return try? decoder.decode(CGRect.self, from: data)
        }
        set {
            if let value = newValue, let data = try? encoder.encode(value) {
                defaults.set(data, forKey: Key.compactWindowFrame)
            } else {
                defaults.removeObject(forKey: Key.compactWindowFrame)
            }
        }
    }

    // MARK: - Player layout

    /// Nil when never set or when the stored value is not a known layout.
    public var playerLayout: PlayerLayout? {
        get { defaults.string(forKey: Key.playerLayout).flatMap(PlayerLayout.init(rawValue:)) }
        set {
            if let value = newValue {
                defaults.set(value.rawValue, forKey: Key.playerLayout)
            } else {
                defaults.removeObject(forKey: Key.playerLayout)
            }
        }
    }
```

- [ ] **Step 4: Run to verify pass**

Run: `scripts/test.sh --filter PlayerLayoutTests`
Expected: 5 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/CrateDiggerCore/Models/PlayerLayout.swift Sources/CrateDiggerCore/Services/PreferencesStore.swift Tests/CrateDiggerCoreTests/PlayerLayoutTests.swift
git commit -m "feat(core): PlayerLayout and its persisted frame and layout prefs"
```

---

### Task 2: `CompactCommandPolicy` (Core)

**Files:**
- Create: `Sources/CrateDiggerCore/Models/CompactCommandPolicy.swift`
- Test: `Tests/CrateDiggerCoreTests/CompactCommandPolicyTests.swift`

**Interfaces:**
- Consumes: `PlayerLayout` (Task 1).
- Produces:
  - `public enum PlayerCommand: CaseIterable, Sendable { case find, goToCurrentSong, selectDisplay, revealSelection, convertSelected, transferToDevice, playNextSelection, playLastSelection, rate }`
  - `public enum CommandAvailability: Sendable, Equatable { case available, expandsFirst, disabled }`
  - `public enum CompactCommandPolicy { public static func availability(_ command: PlayerCommand, in layout: PlayerLayout) -> CommandAvailability }`

Commands not named here are always available; that is the point of naming only the exceptions.

- [ ] **Step 1: Write the failing tests**

```swift
#if canImport(XCTest)
import XCTest
@testable import CrateDiggerCore

final class CompactCommandPolicyTests: XCTestCase {
    func testEverythingIsAvailableInTheFullLayout() {
        for command in PlayerCommand.allCases {
            XCTAssertEqual(CompactCommandPolicy.availability(command, in: .full), .available, "\(command)")
        }
    }

    func testBrowserCommandsExpandFirstInCompact() {
        for command in [PlayerCommand.find, .goToCurrentSong, .selectDisplay] {
            XCTAssertEqual(CompactCommandPolicy.availability(command, in: .compact), .expandsFirst, "\(command)")
        }
    }

    func testSelectionCommandsAreDisabledInCompact() {
        let selection: [PlayerCommand] = [.revealSelection, .convertSelected, .transferToDevice,
                                          .playNextSelection, .playLastSelection, .rate]
        for command in selection {
            XCTAssertEqual(CompactCommandPolicy.availability(command, in: .compact), .disabled, "\(command)")
        }
    }

    func testEveryCommandIsClassified() {
        // A new case must land in one of the two compact lists above.
        XCTAssertEqual(PlayerCommand.allCases.count, 9)
    }
}
#endif
```

- [ ] **Step 2: Run to verify failure**

Run: `scripts/test.sh --filter CompactCommandPolicyTests`
Expected: compile failure, "cannot find 'PlayerCommand' in scope".

- [ ] **Step 3: Implement**

```swift
import Foundation

/// Menu commands that behave differently in the compact player. Everything
/// not listed here works the same in both layouts — playback above all.
public enum PlayerCommand: CaseIterable, Sendable {
    case find
    case goToCurrentSong
    case selectDisplay
    case revealSelection
    case convertSelected
    case transferToDevice
    case playNextSelection
    case playLastSelection
    case rate
}

public enum CommandAvailability: Sendable, Equatable {
    case available
    /// Asking for it is asking for the full window: expand, then run.
    case expandsFirst
    /// Acts on a browser selection the compact player cannot show.
    case disabled
}

public enum CompactCommandPolicy {
    public static func availability(_ command: PlayerCommand, in layout: PlayerLayout) -> CommandAvailability {
        guard layout == .compact else { return .available }
        switch command {
        case .find, .goToCurrentSong, .selectDisplay:
            return .expandsFirst
        case .revealSelection, .convertSelected, .transferToDevice,
             .playNextSelection, .playLastSelection, .rate:
            return .disabled
        }
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `scripts/test.sh --filter CompactCommandPolicyTests`
Expected: 4 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/CrateDiggerCore/Models/CompactCommandPolicy.swift Tests/CrateDiggerCoreTests/CompactCommandPolicyTests.swift
git commit -m "feat(core): which menu commands expand or disable in the compact player"
```

---

### Task 3: Footer metrics, `CompactDeckMetrics` and the compact frame plan (App)

**Files:**
- Modify: `Sources/CrateDiggerApp/UI/Carbon/Footer/FooterShell.swift`
- Modify: `Sources/CrateDiggerApp/UI/Carbon/Footer/TransportCluster.swift`
- Modify: `Sources/CrateDiggerApp/UI/Carbon/Footer/PositionDial.swift:59`
- Modify: `Sources/CrateDiggerApp/UI/Carbon/Controls/VolumeKnob.swift:53`
- Create: `Sources/CrateDiggerApp/UI/CompactDeckMetrics.swift`
- Modify: `Sources/CrateDiggerApp/UI/WindowFramePlanner.swift`
- Test: `Tests/CrateDiggerAppTests/CompactDeckMetricsTests.swift`
- Test: `Tests/CrateDiggerAppTests/WindowFramePlannerTests.swift` (append)

**Interfaces:**
- Produces:
  - `enum FooterMetrics { static let horizontalPadding: CGFloat = 26; static let podGap: CGFloat = 28; static let podMinWidth: CGFloat = 184; static let transportKeySpacing: CGFloat = 11 }`
  - `TransportCluster(showsLocate: Bool = true)`
  - `static func TransportCluster.keyCounts(showsLocate: Bool) -> (left: Int, right: Int)`
  - `FooterShell(showsLocate: Bool = true)`
  - `struct CompactDeckMetrics { init(geometry: CarbonGeometry); var rowHeight, artSide, transportWidth, footerMinWidth, windowHeight, minWindowWidth: CGFloat }`
  - `struct CompactWindowPlan: Equatable { let frame: CGRect; let minimumSize: CGSize; let maximumSize: CGSize }`
  - `static func WindowFramePlanner.compactPlan(visibleFrame: CGRect, savedFrame: CGRect?, anchor: CGRect?, metrics: CompactDeckMetrics) -> CompactWindowPlan`

- [ ] **Step 1: Write the failing tests**

`Tests/CrateDiggerAppTests/CompactDeckMetricsTests.swift`:

```swift
#if canImport(XCTest)
import CoreGraphics
import XCTest
@testable import CrateDiggerApp

final class CompactDeckMetricsTests: XCTestCase {
    func testStandardGeometryNumbers() {
        let m = CompactDeckMetrics(geometry: .standard)
        XCTAssertEqual(m.rowHeight, 274, accuracy: 0.001)        // 170 + 12 + 92
        XCTAssertEqual(m.artSide, 230, accuracy: 0.001)          // 274 - 18 - 20 - 6
        XCTAssertEqual(m.transportWidth, 420, accuracy: 0.001)   // 6×46 + 78 + 6×11
        XCTAssertEqual(m.footerMinWidth, 896, accuracy: 0.001)   // 52 + 2×184 + 2×28 + 420
        XCTAssertEqual(m.windowHeight, 302, accuracy: 0.001)     // 2×14 + 274
        XCTAssertEqual(m.minWindowWidth, 1174, accuracy: 0.001)  // 2×18 + 230 + 12 + 896
    }

    func testLocateKeyIsTheOnlyAsymmetry() {
        XCTAssertEqual(TransportCluster.keyCounts(showsLocate: true).left, 4)
        XCTAssertEqual(TransportCluster.keyCounts(showsLocate: true).right, 3)
        XCTAssertEqual(TransportCluster.keyCounts(showsLocate: false).left, 3)
        XCTAssertEqual(TransportCluster.keyCounts(showsLocate: false).right, 3)
    }
}
#endif
```

Append to `WindowFramePlannerTests` (inside the class, before its closing brace):

```swift
    // MARK: - Compact player

    private func tallGeometry() -> CarbonGeometry {
        var g = CarbonGeometry.standard
        g.headerHeight = 190
        g.footerHeight = 100
        return g
    }

    func testCompactHeightFollowsGeometry() {
        let visible = CGRect(x: 0, y: 0, width: 1800, height: 1100)
        let standard = WindowFramePlanner.compactPlan(
            visibleFrame: visible, savedFrame: nil, anchor: nil,
            metrics: CompactDeckMetrics(geometry: .standard))
        XCTAssertEqual(standard.frame.height, 302, accuracy: 0.001)
        XCTAssertEqual(standard.minimumSize.height, 302, accuracy: 0.001)
        XCTAssertEqual(standard.maximumSize.height, 302, accuracy: 0.001)

        let tallMetrics = CompactDeckMetrics(geometry: tallGeometry())
        let tall = WindowFramePlanner.compactPlan(
            visibleFrame: visible, savedFrame: standard.frame, anchor: nil, metrics: tallMetrics)
        XCTAssertEqual(tall.frame.height, tallMetrics.windowHeight, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(tall.minimumSize.width, tallMetrics.minWindowWidth - 0.001)
    }

    func testCompactPlanAnchorsToTheFullWindowsTopLeft() {
        let visible = CGRect(x: 0, y: 0, width: 1800, height: 1100)
        let full = CGRect(x: 100, y: 120, width: 1400, height: 920)
        let plan = WindowFramePlanner.compactPlan(
            visibleFrame: visible, savedFrame: nil, anchor: full,
            metrics: CompactDeckMetrics(geometry: .standard))
        XCTAssertEqual(plan.frame.minX, full.minX, accuracy: 0.001)
        XCTAssertEqual(plan.frame.maxY, full.maxY, accuracy: 0.001)
        XCTAssertEqual(plan.frame.width, 1400, accuracy: 0.001)
        XCTAssertEqual(plan.minimumSize.width, 1174, accuracy: 0.001)
    }

    func testCompactPlanRestoresSavedFrameOverAnchor() {
        let visible = CGRect(x: 0, y: 0, width: 1800, height: 1100)
        let saved = CGRect(x: 300, y: 40, width: 1250, height: 302)
        let plan = WindowFramePlanner.compactPlan(
            visibleFrame: visible, savedFrame: saved,
            anchor: CGRect(x: 0, y: 0, width: 1400, height: 920),
            metrics: CompactDeckMetrics(geometry: .standard))
        XCTAssertEqual(plan.frame, saved)
    }

    func testCompactPlanClampsOnNarrowScreen() {
        let visible = CGRect(x: 0, y: 0, width: 1100, height: 700)
        let plan = WindowFramePlanner.compactPlan(
            visibleFrame: visible,
            savedFrame: CGRect(x: 900, y: 650, width: 1300, height: 302),
            anchor: nil,
            metrics: CompactDeckMetrics(geometry: .standard))
        XCTAssertGreaterThanOrEqual(plan.frame.minX, visible.minX)
        XCTAssertGreaterThanOrEqual(plan.frame.minY, visible.minY)
        XCTAssertLessThanOrEqual(plan.frame.maxX, visible.maxX)
        XCTAssertLessThanOrEqual(plan.frame.maxY, visible.maxY)
        XCTAssertLessThanOrEqual(plan.minimumSize.width, plan.frame.width)
        XCTAssertEqual(plan.frame.height, 302, accuracy: 0.001)
    }

    func testCompactWidthNeverDropsBelowItsMinimumOnALargeScreen() {
        let visible = CGRect(x: 0, y: 0, width: 1800, height: 1100)
        let plan = WindowFramePlanner.compactPlan(
            visibleFrame: visible,
            savedFrame: CGRect(x: 0, y: 0, width: 600, height: 302),
            anchor: nil,
            metrics: CompactDeckMetrics(geometry: .standard))
        XCTAssertEqual(plan.frame.width, 1174, accuracy: 0.001)
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `scripts/test.sh --filter CompactDeckMetricsTests` and `scripts/test.sh --filter WindowFramePlannerTests`
Expected: compile failures, "cannot find 'CompactDeckMetrics' in scope".

- [ ] **Step 3: Implement the footer metrics and locate switch**

In `FooterShell.swift`, add above `struct FooterShell` and replace the literals:

```swift
/// The footer's fixed measures, named once so the compact player's minimum
/// width (`CompactDeckMetrics`) is derived from the same numbers the footer
/// is laid out with.
enum FooterMetrics {
    static let horizontalPadding: CGFloat = 26
    /// Between each pod and the transport.
    static let podGap: CGFloat = 28
    /// POSITION and VOLUME both have this floor.
    static let podMinWidth: CGFloat = 184
    /// `TransportCluster`'s own key spacing.
    static let transportKeySpacing: CGFloat = 11
}
```

Change `FooterShell`:
- Add a stored property `var showsLocate: Bool = true`.
- Replace `HStack(alignment: .center, spacing: 28)` with `HStack(alignment: .center, spacing: FooterMetrics.podGap)`.
- Replace `TransportCluster()` and its `.padding(.trailing, ...)` with the code below.
- Replace `.padding(.horizontal, 26)` with `.padding(.horizontal, FooterMetrics.horizontalPadding)`.

```swift
                TransportCluster(showsLocate: showsLocate)
                    // PLAY lands dead centre when both sides of the dome are
                    // the same width: pad the short side by the keys it lacks.
                    // With the locate key there are four keys left of PLAY and
                    // three right; without it (the compact player) the two
                    // sides match and this is zero.
                    .padding(.trailing, transportCentringPadding)
```

and inside `FooterShell`:

```swift
    private var transportCentringPadding: CGFloat {
        let keys = TransportCluster.keyCounts(showsLocate: showsLocate)
        return CGFloat(keys.left - keys.right) * (geometry.transportButtonSize + FooterMetrics.transportKeySpacing)
    }
```

Delete the long comment that explained the `(4 - 3)` literal; the new comment replaces it.

In `TransportCluster.swift`, add `var showsLocate: Bool = true` and wrap the locate key:

```swift
        HStack(alignment: .center, spacing: FooterMetrics.transportKeySpacing) {
            if showsLocate {
                transportButton(systemName: "scope", label: "Go to Current Song (⌘L)") {
                    model.revealNowPlaying()
                }
                .disabled(model.nowPlayingTrack == nil)
                .opacity(model.nowPlayingTrack == nil ? 0.45 : 1)
            }
            // … the rest unchanged
```

Add:

```swift
    /// Keys either side of the PLAY dome. The footer centres the dome from
    /// this, and the compact player sizes itself from it.
    static func keyCounts(showsLocate: Bool) -> (left: Int, right: Int) {
        (left: showsLocate ? 4 : 3, right: 3)
    }
```

In `PositionDial.swift:59` and `VolumeKnob.swift:53`, replace `minWidth: 184` with `minWidth: FooterMetrics.podMinWidth`.

- [ ] **Step 4: Implement `CompactDeckMetrics`**

`Sources/CrateDiggerApp/UI/CompactDeckMetrics.swift`:

```swift
import CoreGraphics

/// Every measure of the compact player, derived from the active theme's
/// geometry. `CompactDeckView` lays out from it and `WindowFramePlanner`
/// sizes the window from it, so the two cannot disagree.
///
/// The art column copies the brand column's grid: the traffic lights sit in
/// the chassis's top `HeaderKeyMetrics.topInset`, a brand row (lockup plus
/// the expand key) comes next, and the art square takes what is left of the
/// row's height.
struct CompactDeckMetrics: Equatable {
    let geometry: CarbonGeometry

    init(geometry: CarbonGeometry) {
        self.geometry = geometry
    }

    /// Display + gap + footer: the right-hand column's height.
    var rowHeight: CGFloat {
        geometry.headerHeight + geometry.chassisRowGap + geometry.footerHeight
    }

    var artSide: CGFloat {
        rowHeight - HeaderKeyMetrics.topInset - HeaderKeyMetrics.brandRowHeight - HeaderKeyMetrics.rowGap
    }

    /// The transport without the locate key.
    var transportWidth: CGFloat {
        let keys = TransportCluster.keyCounts(showsLocate: false)
        let sideKeys = CGFloat(keys.left + keys.right)
        return sideKeys * geometry.transportButtonSize
            + geometry.playButtonSize
            + sideKeys * FooterMetrics.transportKeySpacing
    }

    var footerMinWidth: CGFloat {
        2 * FooterMetrics.horizontalPadding
            + 2 * FooterMetrics.podMinWidth
            + 2 * FooterMetrics.podGap
            + transportWidth
    }

    /// The window draws under its transparent titlebar, so this is both the
    /// content height and the frame height.
    var windowHeight: CGFloat {
        2 * geometry.chassisInsetV + rowHeight
    }

    var minWindowWidth: CGFloat {
        2 * geometry.chassisInsetH + artSide + geometry.mainGap + footerMinWidth
    }
}
```

- [ ] **Step 5: Implement `compactPlan`**

In `WindowFramePlanner.swift`, add after `PlannedWindowFrame`:

```swift
struct CompactWindowPlan: Equatable {
    let frame: CGRect
    let minimumSize: CGSize
    let maximumSize: CGSize
}
```

and inside `enum WindowFramePlanner`:

```swift
    /// The compact player's frame: a fixed height from the theme's geometry,
    /// a width between the deck's minimum and the screen, placed where it was
    /// last left (`savedFrame`), else folded up under the full window's
    /// top-left corner (`anchor`), else centred — and always clamped on screen.
    static func compactPlan(
        visibleFrame: CGRect,
        savedFrame: CGRect?,
        anchor: CGRect?,
        metrics: CompactDeckMetrics
    ) -> CompactWindowPlan {
        let availableWidth = max(1, visibleFrame.width - (outerMargin * 2))
        let height = min(metrics.windowHeight, max(1, visibleFrame.height))
        let minWidth = min(metrics.minWindowWidth, availableWidth)
        let maxWidth = max(minWidth, visibleFrame.width)

        let wanted = savedFrame?.width ?? anchor?.width ?? targetSize.width
        let width = min(max(wanted, minWidth), max(minWidth, availableWidth))
        let size = CGSize(width: width, height: height)

        let origin: CGPoint
        if let savedFrame {
            origin = savedFrame.origin
        } else if let anchor {
            origin = CGPoint(x: anchor.minX, y: anchor.maxY - height)
        } else {
            origin = centeredOrigin(for: size, in: visibleFrame)
        }

        return CompactWindowPlan(
            frame: CGRect(origin: clampedOrigin(for: CGRect(origin: origin, size: size), in: visibleFrame), size: size),
            minimumSize: CGSize(width: minWidth, height: height),
            maximumSize: CGSize(width: maxWidth, height: height)
        )
    }
```

A saved frame that already fits comes back exactly as saved, which `testCompactPlanRestoresSavedFrameOverAnchor` checks. The saved width is still clamped, so a narrower save widens to the minimum, which `testCompactWidthNeverDropsBelowItsMinimumOnALargeScreen` checks.

- [ ] **Step 6: Run to verify pass**

Run: `scripts/test.sh --filter CompactDeckMetricsTests` then `scripts/test.sh --filter WindowFramePlannerTests`
Expected: all pass, including the existing full-window planner tests (the full plan is unchanged).

- [ ] **Step 7: Build and eyeball the full footer**

Run: `swift build && pkill -f CrateDiggerApp; .build/debug/CrateDiggerApp &`
Expected: the full window's footer is pixel-identical to before. The locate key is present, and PLAY sits centred under the display.

- [ ] **Step 8: Commit**

```bash
git add Sources/CrateDiggerApp/UI/Carbon/Footer Sources/CrateDiggerApp/UI/Carbon/Controls/VolumeKnob.swift Sources/CrateDiggerApp/UI/CompactDeckMetrics.swift Sources/CrateDiggerApp/UI/WindowFramePlanner.swift Tests/CrateDiggerAppTests/CompactDeckMetricsTests.swift Tests/CrateDiggerAppTests/WindowFramePlannerTests.swift
git commit -m "feat(app): compact deck metrics and frame plan; footer measures named once"
```

---

### Task 4: View-model layout state

**Files:**
- Modify: `Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel.swift` (near `artworkViewerAlbum` at line ~478 for the new property; the `showingWhatsNew` line 466, `showingOnboarding` 571 and `showingWelcomeTour` 575 declarations; `searchFocusTick` near 1691)
- Create: `Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel+CompactPlayer.swift`
- Modify: `Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel+Search.swift:116-124`

**Interfaces:**
- Consumes: `PlayerLayout`, `PreferencesStore.playerLayout` (Task 1).
- Produces:
  - `@Published var playerLayout: PlayerLayout` on `LibraryViewModel`
  - `var isCompactPlayer: Bool`
  - `func toggleCompactPlayer()`
  - `func expandToFull()`
  - `var nowPlayingAlbum: Album?`
  - `func showNowPlayingArtwork()`
  - `var searchFocusPending: Bool`
  - `func consumeSearchFocusRequest() -> Bool`

No unit test: `LibraryViewModel` has no test target. The decisions it forwards to (`launchLayout`) are tested in Task 1. Verification is a build here and the manual pass in Task 11.

- [ ] **Step 1: Add the stored property**

In `LibraryViewModel.swift`, next to `@Published var fullScreenPlayerRequested = false`:

```swift
    /// Full console or compact player (`+CompactPlayer`). The window
    /// controller follows it; `CarbonRootView` draws from it.
    @Published var playerLayout: PlayerLayout = PlayerLayout.launchLayout(
        saved: PreferencesStore.shared.playerLayout,
        libraryChosen: PreferencesStore.shared.cratesIndexFolderBookmark != nil
    ) {
        didSet { PreferencesStore.shared.playerLayout = playerLayout }
    }
```

- [ ] **Step 2: Large sheets expand the window**

Change the three declarations to:

```swift
    @Published var showingWhatsNew: Bool = false {
        // A 302 pt compact window cannot host this sheet.
        didSet { if showingWhatsNew { expandToFull() } }
    }
```

```swift
    @Published var showingOnboarding: Bool = false {
        didSet { if showingOnboarding { expandToFull() } }
    }
```

```swift
    @Published var showingWelcomeTour: Bool = false {
        didSet { if showingWelcomeTour { expandToFull() } }
    }
```

Keep each declaration's existing doc comment above it.

- [ ] **Step 3: Pending search focus**

Next to `searchFocusTick`:

```swift
    /// Set with every ⌘F. A field that already exists takes focus from the
    /// tick; one that is only about to be built (the browser coming back from
    /// the compact player) has no tick change to see, so it takes it from
    /// this on appear. Whichever reads it first clears it.
    var searchFocusPending = false

    func consumeSearchFocusRequest() -> Bool {
        defer { searchFocusPending = false }
        return searchFocusPending
    }
```

In `LibraryViewModel+Search.swift`, `requestSearchFocus()`, insert `searchFocusPending = true` before `bumpSearchFocusTick()`.

- [ ] **Step 4: Create the extension**

`LibraryViewModel+CompactPlayer.swift`:

```swift
import CrateDiggerCore
import Foundation

/// The compact player: the main window folded down to art, display and
/// transport. The layout is one published value; the window controller and
/// `CarbonRootView` follow it, so every route in and out (menu, expand key,
/// zoom button, a sheet that needs room) is just a write to it.
@MainActor
extension LibraryViewModel {

    var isCompactPlayer: Bool { playerLayout == .compact }

    func toggleCompactPlayer() {
        playerLayout = isCompactPlayer ? .full : .compact
    }

    func expandToFull() {
        guard isCompactPlayer else { return }
        playerLayout = .full
    }

    /// The album the art well opens in the artwork viewer. Nil for a stream,
    /// a remote track, or a track the browsed index does not hold — the art
    /// is not clickable then. `album(containing:)` returns a grouped release's
    /// member pressing, which is the right one for artwork.
    var nowPlayingAlbum: Album? {
        guard !isStreamActive, let playing = nowPlayingTrack else { return nil }
        return album(containing: playing.track.id)
    }

    /// Same route as the browser's View Artwork: the presenter (hoisted to
    /// `LibraryPresentations`) picks the booklet reader or the navigator.
    func showNowPlayingArtwork() {
        guard let album = nowPlayingAlbum else { return }
        artworkViewerAlbum = album
    }
}
```

- [ ] **Step 5: Build**

Run: `swift build`
Expected: builds with no new warnings.

- [ ] **Step 6: Commit**

```bash
git add Sources/CrateDiggerApp/UI/Carbon/Library
git commit -m "feat(app): player layout state on the view model"
```

---

### Task 5: Hoist presentations to the shared root

The art click, the EQ key and every sheet must keep working when `MainShell` is not in the tree. This is a move with no behaviour change in the full layout.

**Files:**
- Create: `Sources/CrateDiggerApp/UI/Carbon/LibraryPresentations.swift`
- Modify: `Sources/CrateDiggerApp/UI/Carbon/Main/MainShell.swift` (remove the modifiers from `.sheet(isPresented: $model.showingAddStreamSheet)` through the end of `.onChange(of: model.fullScreenPlayerRequested)`; keep the `.frame` and four `.animation` lines)
- Modify: `Sources/CrateDiggerApp/UI/Carbon/Inspector/InspectorPane.swift` (remove the two `.carbonPanel` blocks, Fix Tags and Match Tags Online)
- Modify: `Sources/CrateDiggerApp/UI/Carbon/CarbonRootView.swift`

**Interfaces:**
- Consumes: `LibraryViewModel` (environment object), `\.carbon` environment.
- Produces: `extension View { func libraryPresentations() -> some View }`

- [ ] **Step 1: Create `LibraryPresentations.swift`**

Move the code, don't rewrite it. Cut each modifier from `MainShell.body` and from `InspectorPane` and paste it into the modifier below, in the same order, with its comments. The listing shows the resulting structure; the bodies in it are the ones currently in those files.

```swift
import CrateDiggerCore
import SwiftUI

/// Every sheet, panel and one-shot window trigger the app presents from
/// model state. They live on the root, above the layout switch, because the
/// compact player removes `MainShell` and the inspector from the tree: a
/// sheet attached there would never show, and a `carbonPanel` would close
/// on disappear but leave its model flag set, so it could never reopen.
private struct LibraryPresentations: ViewModifier {
    @Environment(\.carbon) private var theme
    @EnvironmentObject private var model: LibraryViewModel

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $model.showingAddStreamSheet) {
                AddStreamSheet()
            }
            .sheet(isPresented: $model.showingRecordDividerSheet) {
                RecordDividerSheet()
            }
            .sheet(isPresented: $model.showingOnboarding) {
                OnboardingView()
            }
            .sheet(isPresented: $model.showingWelcomeTour,
                   onDismiss: { model.welcomeTourDidDismiss() }) {
                WelcomeTourView()
            }
            .sheet(isPresented: $model.showingWhatsNew,
                   onDismiss: { model.whatsNewDidDismiss() }) {
                WhatsNewView()
            }
            // (moved verbatim from MainShell) Edit Tags carbonPanel
            // (moved verbatim from MainShell) .sheet(isPresented: $model.showingEQEditor)
            // (moved verbatim from MainShell) .onChange(of: model.artworkViewerAlbum)
            // (moved verbatim from MainShell) .onChange(of: model.fullScreenPlayerRequested)
            // (moved verbatim from InspectorPane) Fix Tags carbonPanel
            // (moved verbatim from InspectorPane) Match Tags Online carbonPanel
    }
}

extension View {
    func libraryPresentations() -> some View {
        modifier(LibraryPresentations())
    }
}
```

The six `// (moved verbatim …)` lines mark where the cut blocks go. Paste the real blocks there and delete those lines; none may remain in the committed file. Check whether `MainShell` still uses its `theme` environment after the move (the `artworkViewerAlbum` handler was its user); if nothing else reads it, delete the property.

- [ ] **Step 2: Apply it at the root**

In `CarbonRootView.body`, apply the modifier to the chassis **before** `.environmentObject(model)` and `.carbonThemed(mode:)`, so it sits inside both scopes, as it did inside `MainShell`:

```swift
        ChassisLayer {
            VStack(spacing: geometry.chassisRowGap) {
                HeaderShell()
                    .frame(height: geometry.headerHeight)
                MainShell()
                    .frame(maxHeight: .infinity)
                FooterShell()
                    .frame(height: geometry.footerHeight)
            }
        }
        .libraryPresentations()
        // The activity lamp is a titlebar accessory …
        .environmentObject(model)
        .carbonThemed(mode: mode)
```

- [ ] **Step 3: Build and run tests**

Run: `swift build && scripts/test.sh`
Expected: builds; the full suite passes (no test touches these views).

- [ ] **Step 4: Smoke-test the full layout**

Run: `pkill -f CrateDiggerApp; .build/debug/CrateDiggerApp &`. Check each of these in the full window:
- Help ▸ What's New opens and closes;
- the EQ key opens the editor;
- View Artwork on an album opens the navigator;
- ⇧⌘F opens the Full Screen Player;
- Edit Tags on a track opens the panel; close it with the red button, then Edit Tags again reopens it;
- FIX TAGS on a selection with a match opens Match Tags Online.

Expected: everything behaves as before the move.

- [ ] **Step 5: Commit**

```bash
git add Sources/CrateDiggerApp/UI/Carbon
git commit -m "refactor(app): present sheets and panels from the root, not MainShell

The compact player removes MainShell and the inspector from the tree. Sheets
attached there would never show, and a carbonPanel closes on disappear while
leaving its model flag set, so Edit Tags or Match Tags could never reopen."
```

---

### Task 6: `NowPlayingCover`, shared with the Mini Player

**Files:**
- Create: `Sources/CrateDiggerApp/UI/Carbon/Main/NowPlayingCover.swift`
- Modify: `Sources/CrateDiggerApp/UI/Carbon/Main/MiniPlayer/MiniPlayerView.swift`. Remove `@State coverImage` (line 184), `.task(id: coverKey)` (line 201), `coverKey` and `loadCoverImage()` (lines ~365-396). In `localArtContent`, the `.cover` case uses the new view.

**Interfaces:**
- Consumes: `model.nowPlayingTrack`, `model.isStreamActive`, `model.selectedStream`, `model.selectedStreamID`, `model.album(containing:)`, `model.artworkService`, `loadThumbnail(url:maxPixelSize:)`, `StreamThumbnail(stream:)`.
- Produces: `struct NowPlayingCover<Placeholder: View>: View { init(model: LibraryViewModel, maxPixel: Int = 480, @ViewBuilder placeholder: () -> Placeholder) }`

- [ ] **Step 1: Create the view**

```swift
import AppKit
import CrateDiggerCore
import SwiftUI

/// The picture of whatever is playing: a stream's thumbnail, else the album's
/// cover — the cover file on disk, then cached bytes by hash, then the audio
/// file's own art (same order as AlbumPoster). Shared by the Mini Player and
/// the compact player so the two can never disagree about which picture is on.
struct NowPlayingCover<Placeholder: View>: View {
    @ObservedObject var model: LibraryViewModel
    var maxPixel: Int = 480
    @ViewBuilder var placeholder: () -> Placeholder

    @State private var coverImage: NSImage?

    var body: some View {
        Group {
            if model.isStreamActive, let stream = model.selectedStream {
                StreamThumbnail(stream: stream)
            } else if let image = coverImage {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                placeholder()
            }
        }
        .task(id: coverKey) { await loadCoverImage() }
    }

    /// Reload key: track change or a freshly committed cover (hash change).
    private var coverKey: String {
        if model.isStreamActive { return "stream-\(model.selectedStreamID ?? "none")" }
        let track = model.nowPlayingTrack?.track
        return "\(track?.id.uuidString ?? "none")-\(track?.artworkHash ?? "")"
    }

    private func loadCoverImage() async {
        guard let loaded = model.nowPlayingTrack else {
            coverImage = nil
            return
        }
        if let album = model.album(containing: loaded.track.id),
           let coverURL = album.booklet?.frontCoverURL,
           let image = await loadThumbnail(url: coverURL, maxPixelSize: maxPixel) {
            coverImage = image
            return
        }
        if let hash = loaded.track.artworkHash,
           let image = await model.artworkService.thumbnailAsync(artworkHash: hash, maxPixel: maxPixel) {
            coverImage = image
            return
        }
        if loaded.track.fileURL.isFileURL,
           let asset = await model.artworkService.resolveArtwork(trackURL: loaded.track.fileURL) {
            coverImage = await model.artworkService.thumbnailAsync(artworkHash: asset.hash, maxPixel: maxPixel)
            return
        }
        coverImage = nil
    }
}
```

- [ ] **Step 2: Use it in the Mini Player**

In `MiniPlayerView.swift`, the `.cover` case of `localArtContent` becomes:

```swift
        case .cover:
            NowPlayingCover(model: model) {
                LinearGradient(colors: [Color(hex: 0xD97757), Color(hex: 0xC14A2E)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
```

Delete the now-unused `coverImage` state, `.task(id: coverKey)`, `coverKey` and `loadCoverImage()`. Before deleting, grep the file for `coverImage` and confirm nothing else reads it.

- [ ] **Step 3: Build and check the Mini Player**

Run: `swift build && pkill -f CrateDiggerApp; .build/debug/CrateDiggerApp &`. Open ⇧⌘M, set the art button to Album Cover, then:
- play an album: its cover shows;
- skip to a track from another album: the cover changes;
- play a stream: its thumbnail shows.

Expected: same as before.

- [ ] **Step 4: Commit**

```bash
git add Sources/CrateDiggerApp/UI/Carbon/Main
git commit -m "refactor(app): NowPlayingCover, lifted out of the Mini Player"
```

---

### Task 7: OLED screen override

**Files:**
- Modify: `Sources/CrateDiggerApp/UI/Carbon/Header/OLEDDisplay.swift` (`DisplayContext` line ~120, `DisplayRail.v` line 141, `RailLive.showMini` line 293)

**Interfaces:**
- Produces: `EnvironmentValues.oledScreenOverride: OLEDView?` (default nil)

- [ ] **Step 1: Add the environment value**

Near the top of `OLEDDisplay.swift`, after the palette helpers:

```swift
// MARK: - Screen override

private struct OLEDScreenOverrideKey: EnvironmentKey {
    static let defaultValue: OLEDView? = nil
}

extension EnvironmentValues {
    /// Pins the glass to one screen regardless of `model.oledView`. The
    /// compact player sets `.nowPlaying`: the app keeps switching screens
    /// underneath (scans, rips, search) and the full window shows whichever
    /// it last chose when it comes back.
    var oledScreenOverride: OLEDView? {
        get { self[OLEDScreenOverrideKey.self] }
        set { self[OLEDScreenOverrideKey.self] = newValue }
    }
}
```

- [ ] **Step 2: Route the three reads through it**

In `DisplayContext`:

```swift
    @Environment(\.oledScreenOverride) private var screenOverride

    var body: some View {
        ZStack {
            switch screenOverride ?? model.oledView {
```

In `DisplayRail`:

```swift
    @Environment(\.oledScreenOverride) private var screenOverride

    private var v: OLEDView { screenOverride ?? model.oledView }
```

In `RailLive`:

```swift
    @Environment(\.oledScreenOverride) private var screenOverride

    private var showMini: Bool { (screenOverride ?? model.oledView) != .nowPlaying }
```

Then run `grep -n "model.oledView" Sources/CrateDiggerApp/UI/Carbon/Header/OLEDDisplay.swift`. Every remaining hit must be inside one of the three `?? model.oledView` expressions.

- [ ] **Step 3: Build**

Run: `swift build`
Expected: builds; the full window's display is unchanged (no override is set anywhere yet).

- [ ] **Step 4: Commit**

```bash
git add Sources/CrateDiggerApp/UI/Carbon/Header/OLEDDisplay.swift
git commit -m "feat(app): an environment override that pins the OLED to one screen"
```

---

### Task 8: `CompactDeckView` and the layout switch

**Files:**
- Create: `Sources/CrateDiggerApp/UI/Carbon/Main/CompactDeck/CompactDeckView.swift`
- Modify: `Sources/CrateDiggerApp/UI/Carbon/CarbonRootView.swift`

**Interfaces:**
- Consumes:
  - `CompactDeckMetrics` (Task 3);
  - `FooterShell(showsLocate:)` (Task 3);
  - `isCompactPlayer`, `expandToFull()`, `nowPlayingAlbum`, `showNowPlayingArtwork()` (Task 4);
  - `NowPlayingCover` (Task 6);
  - `\.oledScreenOverride` (Task 7);
  - `RecessedWell`, `BrandLockup`, `ChromeChassis`, `HeaderKeyMetrics`, `ClickPlayer`, `.carbonTip`, `.carbonHover`.
- Produces: `struct CompactDeckView: View`

- [ ] **Step 1: Create the view**

```swift
import AppKit
import CrateDiggerCore
import SwiftUI

/// The compact player: one rack unit. Art on the left under a brand row
/// that carries the expand key; the console's own display (pinned to NOW)
/// over its own footer on the right. Every measure comes from
/// `CompactDeckMetrics`, which the window controller sizes the window from.
struct CompactDeckView: View {
    @Environment(\.carbon) private var theme
    @Environment(\.carbonGeometry) private var geometry
    @EnvironmentObject private var model: LibraryViewModel

    var body: some View {
        let metrics = CompactDeckMetrics(geometry: geometry)
        HStack(alignment: .top, spacing: geometry.mainGap) {
            artColumn(metrics)
                .frame(width: metrics.artSide)
            VStack(spacing: geometry.chassisRowGap) {
                OLEDDisplay()
                    .frame(maxWidth: .infinity)
                    .frame(height: geometry.headerHeight)
                    .environment(\.oledScreenOverride, .nowPlaying)
                FooterShell(showsLocate: false)
                    .frame(height: geometry.footerHeight)
            }
        }
    }

    // MARK: Art column

    private func artColumn(_ metrics: CompactDeckMetrics) -> some View {
        VStack(alignment: .leading, spacing: HeaderKeyMetrics.rowGap) {
            HStack(spacing: 8) {
                BrandLockup(typeSize: 11)
                Spacer(minLength: 0)
                expandKey
            }
            .frame(height: HeaderKeyMetrics.brandRowHeight)
            artWell
                .frame(width: metrics.artSide, height: metrics.artSide)
        }
        .padding(.top, HeaderKeyMetrics.topInset)
    }

    /// pip.exit: the same switch as the brand block's Mini Player pip, the
    /// other way — back to the whole console.
    private var expandKey: some View {
        Button {
            ClickPlayer.shared.play(.key)
            model.expandToFull()
        } label: {
            Image(systemName: "pip.exit")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(theme.chassisInk)
                .padding(.horizontal, 6)
                .frame(height: 20)
                .background(ChromeChassis(theme: theme, cornerRadius: geometry.keyCornerRadius))
        }
        .buttonStyle(.carbonHover)
        .carbonTip("Full console (⌥⇧⌘M)")
        .accessibilityLabel("Expand to the full console")
    }

    private var artWell: some View {
        let clickable = model.nowPlayingAlbum != nil
        return RecessedWell(padding: 0) {
            // An empty well when nothing plays: the display already says so.
            NowPlayingCover(model: model, maxPixel: 600) { Color.clear }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: geometry.wellCornerRadius, style: .continuous))
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard clickable else { return }
            ClickPlayer.shared.play(.key)
            model.showNowPlayingArtwork()
        }
        .onHover { inside in
            if inside && clickable { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .carbonTip(clickable ? "View artwork" : "")
        .accessibilityAddTraits(clickable ? .isButton : [])
        .accessibilityLabel(clickable ? "Album artwork. Opens the artwork viewer." : "Album artwork")
    }
}
```

Before relying on `.carbonTip("")`, check that an empty tip shows nothing: `grep -rn "func carbonTip" Sources/CrateDiggerApp`. If an empty string still shows an empty bubble, apply the tip only when `clickable` (for example with a `Group` and `if`).

- [ ] **Step 2: Switch the layout in `CarbonRootView`**

```swift
        ChassisLayer {
            switch model.playerLayout {
            case .full:
                VStack(spacing: geometry.chassisRowGap) {
                    HeaderShell()
                        .frame(height: geometry.headerHeight)
                    MainShell()
                        .frame(maxHeight: .infinity)
                    FooterShell()
                        .frame(height: geometry.footerHeight)
                }
            case .compact:
                CompactDeckView()
            }
        }
        .libraryPresentations()
```

- [ ] **Step 3: Build and check by forcing the layout**

Run:
```bash
swift build && pkill -f CrateDiggerApp
defaults write CrateDiggerApp cratedigger.ui.playerLayout compact 2>/dev/null; .build/debug/CrateDiggerApp &
```
If the debug binary uses a different defaults domain, find it with `defaults find cratedigger.window.frame`. The window keeps its full size because Task 9 hasn't landed yet. Expected:
- the deck draws top-aligned;
- the brand row clears the traffic lights;
- the art is square;
- the display shows NOW;
- the footer has no locate key, and PLAY is centred.

Afterwards run `defaults delete <domain> cratedigger.ui.playerLayout`.

- [ ] **Step 4: Commit**

```bash
git add Sources/CrateDiggerApp/UI/Carbon
git commit -m "feat(app): the compact deck view and the root's layout switch"
```

---

### Task 9: Window controller follows the layout

**Files:**
- Modify: `Sources/CrateDiggerApp/UI/MainWindowController.swift`

**Interfaces:**
- Consumes: `model.$playerLayout`, `model.expandToFull()`, `model.toggleCompactPlayer()`, `model.isCompactPlayer` (Task 4); `WindowFramePlanner.compactPlan`, `CompactDeckMetrics` (Task 3); `PreferencesStore.savedCompactWindowFrame` (Task 1); `PreferencesStore.themesDidChange`; `ThemeRegistry.shared.resolvedTheme(for:)`.
- Produces: `MainWindowController.isCompact: Bool`, `func toggleCompactPlayer()`, `func expandToFull()`

- [ ] **Step 1: State and observers**

Add `import Combine` at the top. Add the properties:

```swift
    /// The layout the window is currently sized for. Trails `model.playerLayout`
    /// by one runloop turn, which is what lets `switchLayout` save the
    /// outgoing frame into the outgoing layout's slot.
    private var layout: PlayerLayout = .full
    private var layoutObserver: AnyCancellable?
```

At the end of `init()`, after the existing observers:

```swift
        layout = hostingController.model.playerLayout
        layoutObserver = hostingController.model.$playerLayout
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.switchLayout(to: $0) }

        // A theme can change the header or footer height; the compact window
        // is exactly that tall, so it re-plans.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleThemesDidChange),
            name: PreferencesStore.themesDidChange,
            object: nil
        )
```

- [ ] **Step 2: Switching, planning, persisting**

Add:

```swift
    var isCompact: Bool { hostingController.model.isCompactPlayer }

    func toggleCompactPlayer() {
        showWindow(nil)
        hostingController.model.toggleCompactPlayer()
    }

    func expandToFull() {
        hostingController.model.expandToFull()
    }

    private func switchLayout(to newLayout: PlayerLayout) {
        guard newLayout != layout, let window else { return }
        persistFrame()          // into the outgoing layout's slot
        layout = newLayout
        applyLayoutPlan(restoring: true, animated: window.isVisible)
    }

    /// `restoring` reads the layout's saved frame (a switch, or launch);
    /// otherwise the current frame is re-clamped (screen or theme change).
    private func applyLayoutPlan(restoring: Bool, animated: Bool) {
        guard let window else { return }
        switch layout {
        case .full:
            window.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            if restoring {
                let saved = prefs.savedWindowFrame
                applyWindowPlan(context: saved == nil ? .initialLaunch : .clampToVisibleFrame,
                                animated: animated, baseline: saved)
            } else {
                applyWindowPlan(context: .clampToVisibleFrame, animated: animated)
            }
        case .compact:
            let plan = WindowFramePlanner.compactPlan(
                visibleFrame: visibleFrame(for: window),
                savedFrame: restoring ? prefs.savedCompactWindowFrame : window.frame,
                anchor: window.frame,
                metrics: CompactDeckMetrics(geometry: activeGeometry())
            )
            // Minimum first: the full window's 1200 × 820 floor would refuse the shrink.
            window.minSize = NSSize(width: plan.minimumSize.width, height: plan.minimumSize.height)
            window.maxSize = NSSize(width: plan.maximumSize.width, height: plan.maximumSize.height)
            window.setFrame(plan.frame, display: true, animate: animated)
        }
    }

    private func visibleFrame(for window: NSWindow) -> CGRect {
        window.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
    }

    /// Resolved the way `CarbonRootView` resolves it.
    private func activeGeometry() -> CarbonGeometry {
        MainActor.assumeIsolated {
            ThemeRegistry.shared.resolvedTheme(for: prefs.selectedThemeID)?.geometry
        } ?? .standard
    }

    @objc private func handleThemesDidChange() {
        guard layout == .compact else { return }
        applyLayoutPlan(restoring: false, animated: window?.isVisible ?? false)
    }

    /// Zoom while compact means "the whole console", not a maximised strip.
    func windowShouldZoom(_ window: NSWindow, toFrame newFrame: NSRect) -> Bool {
        guard layout == .compact else { return true }
        expandToFull()
        return false
    }
```

If `MainActor.assumeIsolated` fails to compile because the controller is already main-actor isolated, call `ThemeRegistry.shared.resolvedTheme(for:)` directly.

- [ ] **Step 3: Route the existing frame code**

Replace `persistFrame()`:

```swift
    private func persistFrame() {
        guard let window else { return }
        switch layout {
        case .full:    prefs.savedWindowFrame = window.frame
        case .compact: prefs.savedCompactWindowFrame = window.frame
        }
    }
```

Give `applyWindowPlan` a baseline override and compute `visibleFrame` through the helper:

```swift
    private func applyWindowPlan(context: WindowFramePlanningContext, animated: Bool, baseline override: CGRect? = nil) {
        guard let window else { return }
        let visibleFrame = visibleFrame(for: window)

        let baselineFrame: CGRect?
        if let override {
            baselineFrame = override
        } else if context == .clampToVisibleFrame, prefs.savedWindowFrame != nil, !window.isVisible {
            // First-launch restoration path: prefer the persisted frame over
            // the (uninitialized) current frame.
            baselineFrame = prefs.savedWindowFrame ?? window.frame
        } else {
            baselineFrame = window.frame
        }
        // … rest unchanged (plan, minSize, setFrame)
    }
```

In `showWindow(_:)`, the first-show branch becomes:

```swift
        if !didApplyRestoredFrame {
            didApplyRestoredFrame = true
            if layout == .compact {
                applyLayoutPlan(restoring: true, animated: false)
            } else if prefs.savedWindowFrame != nil {
                applyWindowPlan(context: .clampToVisibleFrame, animated: false)
            } else {
                applyWindowPlan(context: .initialLaunch, animated: false)
            }
        }
```

In `windowDidChangeScreen` and `windowDidChangeBackingProperties`, replace the body with `applyLayoutPlan(restoring: false, animated: false)`.

- [ ] **Step 4: Build and run the planner tests again**

Run: `swift build && scripts/test.sh --filter WindowFramePlannerTests`
Expected: builds; all pass.

- [ ] **Step 5: Manual check of the window behaviour**

There's no menu item yet. Drive the layout with the defaults key from Task 8, Step 3, and with the expand key:
- launch compact: the window is 302 tall and anchored or centred;
- the expand key restores the full frame;
- relaunch with the key set back to compact: the compact frame comes back where it was left;
- the green button in compact expands.

- [ ] **Step 6: Commit**

```bash
git add Sources/CrateDiggerApp/UI/MainWindowController.swift
git commit -m "feat(app): the main window follows the player layout with a frame per layout"
```

---

### Task 10: Menus, the command policy and expand-first

**Files:**
- Modify: `Sources/CrateDiggerApp/AppDelegate.swift`:
  - Window menu, line ~1557 (Mini Player item);
  - `validateMenuItem`, line ~1179;
  - actions `selectOLEDView` (~187), `goToCurrentSong` (~199) and `findInLibrary` (~207).
- Modify: `Sources/CrateDiggerApp/UI/Carbon/Main/Browser/BrowserSearchBar.swift:29`
- Modify: `Sources/CrateDiggerApp/UI/Carbon/Main/Browser/ColumnList.swift` (the `ScrollViewReader` block, ~line 124)

**Interfaces:**
- Consumes: `PlayerCommand`, `CompactCommandPolicy` (Task 2); `MainWindowController.isCompact`, `toggleCompactPlayer()`, `expandToFull()` (Task 9); `consumeSearchFocusRequest()` (Task 4).

- [ ] **Step 1: The menu item and its action**

After the Mini Player item in the Window menu:

```swift
        let compactItem = makeItem(title: "Compact Player", action: #selector(toggleCompactPlayer(_:)), key: "m")
        compactItem.keyEquivalentModifierMask = [.command, .option, .shift]
        windowMenu.addItem(compactItem)
```

Next to `toggleMiniPlayer`:

```swift
    @objc private func toggleCompactPlayer(_ sender: Any?) {
        mainWindowController?.toggleCompactPlayer()
    }
```

- [ ] **Step 2: Map selectors to commands and gate them**

Add to `AppDelegate`:

```swift
    /// Menu actions the compact player treats differently; see
    /// `CompactCommandPolicy`. Anything not mapped works in both layouts.
    private static func playerCommand(for action: Selector?) -> PlayerCommand? {
        switch action {
        case #selector(findInLibrary(_:)):           return .find
        case #selector(goToCurrentSong(_:)):         return .goToCurrentSong
        case #selector(selectOLEDView(_:)):          return .selectDisplay
        case #selector(revealSelectionInFinder(_:)): return .revealSelection
        case #selector(convertSelected(_:)):         return .convertSelected
        case #selector(transferToDevice(_:)):        return .transferToDevice
        case #selector(queuePlayNext(_:)):           return .playNextSelection
        case #selector(queuePlayLast(_:)):           return .playLastSelection
        case #selector(setRating(_:)):               return .rate
        default:                                     return nil
        }
    }

    private var currentLayout: PlayerLayout {
        (mainWindowController?.isCompact ?? false) ? .compact : .full
    }

    /// For the expand-first commands: bring the console back, then let the
    /// action run as it always has.
    private func expandIfNeeded(for command: PlayerCommand) {
        guard CompactCommandPolicy.availability(command, in: currentLayout) == .expandsFirst else { return }
        mainWindowController?.expandToFull()
    }
```

At the very top of `validateMenuItem`, before the `switch`:

```swift
        if let command = Self.playerCommand(for: menuItem.action),
           CompactCommandPolicy.availability(command, in: currentLayout) == .disabled {
            return false
        }
```

and a case inside the `switch`:

```swift
        case #selector(toggleCompactPlayer(_:)):
            menuItem.state = currentLayout == .compact ? .on : .off
            return true
```

- [ ] **Step 3: Expand-first in the three actions**

```swift
    @objc private func selectOLEDView(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let view = OLEDView(rawValue: raw) else { return }
        expandIfNeeded(for: .selectDisplay)
        mainWindowController?.setOLEDView(view)
    }

    @objc private func goToCurrentSong(_ sender: Any?) {
        expandIfNeeded(for: .goToCurrentSong)
        mainWindowController?.revealNowPlaying()
    }

    @objc private func findInLibrary(_ sender: Any?) {
        expandIfNeeded(for: .find)
        mainWindowController?.focusSearch()
    }
```

- [ ] **Step 4: The rebuilt browser takes focus and scrolls to its selection**

`BrowserSearchBar.swift`, replacing the `.onChange(of: model.searchFocusTick)` line:

```swift
            .onChange(of: model.searchFocusTick) { _ in
                _ = model.consumeSearchFocusRequest()
                focused = true
            }
            // Built after ⌘F asked (the browser returning from the compact
            // player): there is no tick change to see, so take it from here.
            // Deferred a turn: focus set during appear is dropped on macOS.
            .onAppear {
                guard model.consumeSearchFocusRequest() else { return }
                DispatchQueue.main.async { focused = true }
            }
```

`ColumnList.swift`, after the `.onChange(of: ScrollRequest(...))` block inside the `ScrollViewReader`:

```swift
                // Built with a selection already in place (launch, a view
                // switch, the browser returning from the compact player):
                // land on it rather than on the top of the list. The gallery
                // already does the same.
                .onAppear {
                    guard let scrollTarget else { return }
                    proxy.scrollTo(scrollTarget, anchor: .center)
                }
```

- [ ] **Step 5: Build and run the whole suite**

Run: `swift build && scripts/test.sh`
Expected: builds; the whole suite passes, and the count printed has grown by the new tests (5 + 4 + 2 + 5 = 16).

- [ ] **Step 6: Commit**

```bash
git add Sources/CrateDiggerApp/AppDelegate.swift Sources/CrateDiggerApp/UI/Carbon/Main/Browser
git commit -m "feat(app): Window ▸ Compact Player, with browser commands expanding or disabled"
```

---

### Task 11: Verify in the running app, document, final review

**Files:**
- Modify: `CLAUDE.md` (UI section, after the Mini Player / OLEDView paragraph)

- [ ] **Step 1: Launch clean**

Run: `swift build && pkill -f CrateDiggerApp; .build/debug/CrateDiggerApp &`

- [ ] **Step 2: Walk the spec's manual checklist**

Do each item and note pass or fail. Fix any failure in the task that owns the code, re-run `scripts/test.sh`, and commit the fix before moving on.
1. Toggle full ⇄ compact by the menu item, the ⌥⇧⌘M shortcut, the expand key and the zoom button. Each layout reopens at its own frame.
2. Quit in compact and relaunch: the app opens compact.
3. In compact, switch themes (at least one with a different header or footer height, if one is installed) and switch light/dark. The height re-plans and the art stays square.
4. Play a local album and click the art. Try an album with a PDF booklet (the booklet reader opens) and one without (the navigator opens; FLOAT works).
5. Play a stream: the thumbnail shows, clicking does nothing, and there's no pointing-hand cursor.
6. Press ⌘F in compact: the window expands and the search field has focus. ⌘L: it expands and reveals the playing track, scrolled into view. ⌘2: it expands onto CNVRT. Convert Selected, Transfer, Reveal, Play Next, Play Last and Rating are greyed out in compact.
7. Open the EQ editor (Playback menu or key) and the Full Screen Player (⇧⌘F) from compact.
8. Open Edit Tags in full, then enter compact. The panel stays open, because it is hoisted to the root. Close it, expand, and press Edit Tags again: it reopens.
9. Start a rescan in compact: the display stays on NOW and the titlebar LED shows activity. Expand: the display is on SCAN.
10. Drop a Finder folder onto the compact window: it lands in the Prep Crate.
11. Drag the compact window to its minimum width: nothing clips, and the footer pods sit at their floor.
12. Help ▸ What's New from compact: the window expands first, then the sheet opens.
13. Mini Player (⇧⌘M) from compact: the cover shows, and its expand key returns to the compact window.

- [ ] **Step 3: Screenshots**

Capture the compact player in light and dark with something playing, using `screencapture -l <windowid>` or `screencapture -i`. Save them in the scratchpad, not the repo.

- [ ] **Step 4: Document in CLAUDE.md**

Add after the paragraph that ends "`DubPane` branches per source: a download is its own body, not the rip's with the wrong nouns in it.":

```markdown
**Compact player** (2.3): the main window can fold into one rack unit — art, the display pinned to NOW, and the footer without its locate key — via Window ▸ Compact Player (⌥⇧⌘M). It is one window and one view model: `LibraryViewModel.playerLayout` (Core's `PlayerLayout`, persisted; `launchLayout` forces full with no library chosen) picks what `CarbonRootView` draws, and `MainWindowController` follows it with a frame per layout (`savedWindowFrame` / `savedCompactWindowFrame`) sized by `WindowFramePlanner.compactPlan` from `CompactDeckMetrics`. Three rules keep it working:
- **Present from the root.** Sheets, model-driven `carbonPanel`s and one-shot window triggers live in `LibraryPresentations`, on the root above the layout switch. One attached to `MainShell` or the inspector silently never shows in compact, and a `carbonPanel` whose host disappears closes while leaving its model flag set, so it can never reopen.
- **Never write `oledView` for the compact display.** It pins NOW through the `\.oledScreenOverride` environment value. The app keeps switching screens underneath, and the full window shows the latest one on return.
- **Classify new menu commands.** Ones that act on the browser selection or need the browser go in Core's `CompactCommandPolicy` (`.disabled` or `.expandsFirst`) and in `AppDelegate.playerCommand(for:)`.
```

- [ ] **Step 5: Full suite and commit**

Run: `scripts/test.sh`
Expected: all pass.

```bash
git add CLAUDE.md
git commit -m "docs: the compact player in CLAUDE.md"
```

- [ ] **Step 6: Whole-branch review**

Use superpowers:requesting-code-review on `git diff origin/main...v2.3`. Give the reviewer the spec, this plan and the Review Focus list above.
