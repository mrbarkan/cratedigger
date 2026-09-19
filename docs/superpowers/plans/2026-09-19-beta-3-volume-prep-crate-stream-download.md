# 2.2.0 beta 3 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship four independent items in 2.2.0 beta 3: a volume readout on the OLED (dB or percent) with two fader fixes, a symmetric footer, an empty Prep Crate that explains itself, and downloadable radio streams with a Downloads list.

**Architecture:** Every decidable value goes in `CrateDiggerCore` with an XCTest (`VolumeCurve`, `BrowserEmptyKind`, `RecordMarker.markers(from:)`, `StreamDownloader`, the `StreamSource` download link). The app target only wires those into `LibraryViewModel` extensions and SwiftUI views, which stay untested like the rest of the view layer. Stream downloads reuse what exists: yt-dlp through `ExternalToolLocator`, `loadFolders` into the Prep Crate (the SACD import's path), Record Divider markers for splitting, `trashTrackFile` for removal.

**Tech Stack:** Swift 5 / SwiftPM, AppKit + SwiftUI, XCTest, yt-dlp and ffmpeg as external tools.

**Spec:** `docs/superpowers/specs/2026-09-19-beta-3-volume-prep-crate-stream-download-design.md`

## Global Constraints

- Branch: `v2.2`. Do not branch from `v2` or `v2.1`. One commit per task, conventional prefixes (`feat(volume):`, `fix(footer):`...), ending with `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.
- Run tests with `scripts/test.sh`, never bare `swift test`. One class: `scripts/test.sh --filter VolumeCurveTests`.
- Test files are wrapped in `#if canImport(XCTest)` ... `#endif` and use `@testable import CrateDiggerCore`.
- Build with `swift build`; launch with `.build/arm64-apple-macosx/debug/CrateDiggerApp`; stop with `pkill -f CrateDiggerApp`.
- User-facing copy contains no em dashes and no en dashes. OLED notices are ALL CAPS and short.
- Anything that writes the index or an audio file starts with `guard !refuseWhileLibraryDisconnected() else { return }`.
- yt-dlp is never bundled or auto-installed. Every yt-dlp argument vector ends `"--", url`.
- No new dependencies. No new NotificationCenter names.
- The four items are independent. If one blocks, skip to the next item's tasks and report.

## File Structure

| File | Responsibility |
|---|---|
| `Sources/CrateDiggerCore/Services/VolumeCurve.swift` (modify) | + `VolumeReadoutUnit`, `percent`, `readout`, `stepped` |
| `Sources/CrateDiggerCore/Services/PreferencesStore.swift` (modify) | + `volumeReadoutUnit`, `hasAcknowledgedStreamDownloadNotice` |
| `Sources/CrateDiggerCore/Models/BrowserEmptyKind.swift` (create) | which empty state the browser draws |
| `Sources/CrateDiggerCore/Models/RecordMarker.swift` (modify) | + `markers(from:duration:)` |
| `Sources/CrateDiggerCore/Models/StreamSource.swift` (modify) | + `downloadedPath`, `isDownloaded`, `RadioCategory.downloaded` |
| `Sources/CrateDiggerCore/Services/StreamStore.swift` (modify) | + `repointDownload`, `setDownload` |
| `Sources/CrateDiggerCore/Services/StreamResolver.swift` (modify) | local-file branch, optional yt-dlp URL |
| `Sources/CrateDiggerCore/Services/StreamDownloader.swift` (create) | argv, progress parsing, folder planning, run |
| `Sources/CrateDiggerCore/Services/StreamingCommandRunner.swift` (create) | line-by-line process runner with terminate |
| `Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel+StreamDownload.swift` (create) | download, notice, import hook, remove download |
| `Sources/CrateDiggerApp/UI/Carbon/Controls/VolumeKnob.swift`, `Main/RadioListView.swift`, `Main/Browser/BrowserPane.swift`, `Footer/*`, `Preferences/PreferencesWindowController.swift` (modify) | views |

---

## Item 1: Volume

### Task 1: `VolumeCurve` readout, percent and stepping

**Files:**
- Modify: `Sources/CrateDiggerCore/Services/VolumeCurve.swift`
- Test: `Tests/CrateDiggerCoreTests/VolumeCurveTests.swift`

**Interfaces:**
- Produces: `public enum VolumeReadoutUnit: String, CaseIterable, Codable, Sendable { case decibels, percent; var label: String }`, `VolumeCurve.percent(forPosition: Double) -> Int`, `VolumeCurve.readout(forPosition: Double, unit: VolumeReadoutUnit, boostAvailable: Bool = true) -> String`, `VolumeCurve.stepped(from: Double, by: Double) -> Double`, `VolumeCurve.magnetWidth: Double`.

- [ ] **Step 1: Write the failing tests.** Append inside `VolumeCurveTests`:

```swift
    func testPercentIsOneHundredAtUnity() {
        XCTAssertEqual(VolumeCurve.percent(forPosition: VolumeCurve.unityPosition), 100)
        XCTAssertEqual(VolumeCurve.percent(forPosition: 0), 0)
        XCTAssertEqual(VolumeCurve.percent(forPosition: 1), 108)
        XCTAssertEqual(VolumeCurve.percent(forPosition: VolumeCurve.unityPosition / 2), 50)
    }

    func testReadoutInBothUnits() {
        XCTAssertEqual(VolumeCurve.readout(forPosition: 0, unit: .decibels), "VOL  MUTE")
        XCTAssertEqual(VolumeCurve.readout(forPosition: 0, unit: .percent), "VOL  MUTE")
        XCTAssertEqual(VolumeCurve.readout(forPosition: VolumeCurve.unityPosition, unit: .decibels), "VOL  0 dB")
        XCTAssertEqual(VolumeCurve.readout(forPosition: VolumeCurve.unityPosition, unit: .percent), "VOL  100%")
        XCTAssertEqual(VolumeCurve.readout(forPosition: 1, unit: .decibels), "VOL  +5 dB")
        XCTAssertEqual(VolumeCurve.readout(forPosition: 1, unit: .percent), "VOL  108%")
    }

    func testReadoutCapsAtUnityWhenBoostIsUnavailable() {
        // Streams and DSD never receive the makeup gain, so the number must not claim it.
        XCTAssertEqual(VolumeCurve.readout(forPosition: 1, unit: .decibels, boostAvailable: false), "VOL  0 dB")
        XCTAssertEqual(VolumeCurve.readout(forPosition: 1, unit: .percent, boostAvailable: false), "VOL  100%")
        XCTAssertEqual(VolumeCurve.readout(forPosition: 0.5, unit: .percent, boostAvailable: false),
                       VolumeCurve.readout(forPosition: 0.5, unit: .percent))
    }

    func testSteppingLandsOnUnityWhenCrossingIt() {
        let u = VolumeCurve.unityPosition
        XCTAssertEqual(VolumeCurve.stepped(from: 0.90, by: 0.05), u, accuracy: 0.0001)   // up across
        XCTAssertEqual(VolumeCurve.stepped(from: 0.95, by: -0.05), u, accuracy: 0.0001)  // down across
        XCTAssertEqual(VolumeCurve.stepped(from: u, by: 0.05), u + 0.05, accuracy: 0.0001) // leaving it is free
        XCTAssertEqual(VolumeCurve.stepped(from: 0.50, by: 0.05), 0.55, accuracy: 0.0001)
        XCTAssertEqual(VolumeCurve.stepped(from: 0.98, by: 0.05), 1)
        XCTAssertEqual(VolumeCurve.stepped(from: 0.02, by: -0.05), 0)
    }
```

- [ ] **Step 2: Run and see them fail.** `scripts/test.sh --filter VolumeCurveTests`. Expected: compile errors, `percent`, `readout`, `stepped` not found.

- [ ] **Step 3: Implement.** In `VolumeCurve.swift`, above `public enum VolumeCurve`:

```swift
/// What the OLED's transient volume readout shows (Settings ▸ Playback).
public enum VolumeReadoutUnit: String, CaseIterable, Codable, Sendable {
    case decibels
    case percent

    public var label: String {
        switch self {
        case .decibels: return "Decibels (dB)"
        case .percent:  return "Percent"
        }
    }
}
```

Inside `VolumeCurve`, before `clamp`:

```swift
    /// Half-width of the fader's magnetic pull onto the 0 dB detent. The boost
    /// zone above unity is only 0.077 of travel, so this has to stay small.
    public static let magnetWidth: Double = 0.012

    /// Percent of the travel up to unity: the 0 dB mark reads exactly 100, the
    /// top of travel 108. Where the fader is, not the amplitude (which would
    /// read under 5% for half the travel).
    public static func percent(forPosition position: Double) -> Int {
        Int((clamp(position) / unityPosition * 100).rounded())
    }

    /// The OLED's transient readout. `boostAvailable` is false while a stream or
    /// native DSD plays: neither gets the makeup gain, so the number stops at unity.
    public static func readout(forPosition position: Double,
                               unit: VolumeReadoutUnit,
                               boostAvailable: Bool = true) -> String {
        var p = clamp(position)
        if !boostAvailable { p = Swift.min(p, unityPosition) }
        if p <= 0.005 { return "VOL  MUTE" }
        switch unit {
        case .decibels: return "VOL  \(label(forPosition: p))"
        case .percent:  return "VOL  \(percent(forPosition: p))%"
        }
    }

    /// A Volume Up / Down step. Steps are 0.05 of travel and would walk straight
    /// over unity (0.90 → 0.95), so a step that crosses it stops on it.
    public static func stepped(from position: Double, by delta: Double) -> Double {
        let from = clamp(position)
        let to = clamp(from + delta)
        let crossesUp = from < unityPosition && to > unityPosition
        let crossesDown = from > unityPosition && to < unityPosition
        return (crossesUp || crossesDown) ? unityPosition : to
    }
```

- [ ] **Step 4: Run.** `scripts/test.sh --filter VolumeCurveTests`. Expected: PASS, all tests.

- [ ] **Step 5: Commit.** `git add -A Sources/CrateDiggerCore/Services/VolumeCurve.swift Tests/CrateDiggerCoreTests/VolumeCurveTests.swift && git commit -m "feat(volume): readout, percent and unity-aware stepping in VolumeCurve"`

### Task 2: Readout on the OLED, the setting, and the fader fixes

**Files:**
- Modify: `Sources/CrateDiggerCore/Services/PreferencesStore.swift` (key list near line 49; extension near line 848)
- Modify: `Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel.swift:639-644` (`playbackVolume`), `:2954-2957` (`setVolume`), `:1596-1597` (shortcut cases)
- Modify: `Sources/CrateDiggerApp/UI/MainWindowController.swift:296-298` (`adjustVolume`)
- Modify: `Sources/CrateDiggerApp/UI/Carbon/Controls/VolumeKnob.swift`
- Modify: `Sources/CrateDiggerApp/UI/Preferences/PreferencesWindowController.swift` (`PlaybackPreferencesView`)

**Interfaces:**
- Consumes: everything Task 1 produces.
- Produces: `PreferencesStore.volumeReadoutUnit: VolumeReadoutUnit`, `LibraryViewModel.stepVolume(by: Double)`.

- [ ] **Step 1: Preference.** In `PreferencesStore`'s `Key` enum add `static let volumeReadoutUnit = "cratedigger.ui.volumeReadoutUnit"`. Next to the `cdAnimationSpeed` extension add:

```swift
public extension PreferencesStore {
    /// dB or percent for the OLED's transient volume readout.
    var volumeReadoutUnit: VolumeReadoutUnit {
        get { defaults.string(forKey: Key.volumeReadoutUnit).flatMap(VolumeReadoutUnit.init(rawValue:)) ?? .decibels }
        set { defaults.set(newValue.rawValue, forKey: Key.volumeReadoutUnit) }
    }
}
```

- [ ] **Step 2: Readout from the one choke point.** Replace the `playbackVolume` declaration:

```swift
    @Published var playbackVolume: Double = 0.8 {
        didSet {
            applyVolumeToEngines()
            prefs.savedPlaybackVolume = playbackVolume
            // Every route (fader, menu, shortcut) lands here. The launch restore
            // assigns inside init, where observers don't fire, so it stays silent.
            guard oldValue != playbackVolume else { return }
            showOLEDNotice(
                VolumeCurve.readout(forPosition: playbackVolume,
                                    unit: prefs.volumeReadoutUnit,
                                    boostAvailable: volumeBoostAvailable),
                seconds: 1.2)
        }
    }

    /// Streams have no audio tap and native DSD is bit-perfect, so neither gets
    /// the makeup gain above unity. See `VolumeCurve.readout`.
    private var volumeBoostAvailable: Bool {
        !isStreamActive && !isPlayingNativeDSD
    }
```

For `isPlayingNativeDSD`: open `LibraryViewModel.swift` around line 3479, where `showOLEDNotice("DSD ► BIT-PERFECT")` is called, and reuse the exact boolean expression that guards that call. If it is an inline expression, lift it into `private var isPlayingNativeDSD: Bool` beside `volumeBoostAvailable` and use it in both places.

- [ ] **Step 3: Steps land on unity.** Add below `setVolume`:

```swift
    /// A Volume Up / Down step; stops on the 0 dB mark instead of walking over it.
    func stepVolume(by delta: Double) {
        playbackVolume = VolumeCurve.stepped(from: playbackVolume, by: delta)
    }
```

Change the two shortcut cases (`LibraryViewModel.swift:1596-1597`) to `stepVolume(by: 0.05)` / `stepVolume(by: -0.05)`, and `MainWindowController.adjustVolume(by:)` to `model.stepVolume(by: delta)`.

- [ ] **Step 4: Fader magnet and double-click.** In `VolumeKnob.swift` replace the `FaderTrack(...)` call and the `.onTapGesture(count: 2)` with:

```swift
            FaderTrack(
                progress: value,
                detents: [FaderDetent(fraction: Self.unityFraction, label: "0dB")],
                onScrub: { raw in
                    lastScrub = raw
                    // Magnetically snap to the 0 dB (unity) detent when close.
                    value = abs(raw - Self.unityFraction) < VolumeCurve.magnetWidth ? Self.unityFraction : raw
                }
            )
            .frame(height: 27)   // same content-box height as the EQ/VU LCDs so rail and LCD centers match
            .background(WindowDragGuard())
            .onTapGesture(count: 2) {
                // Only a double-click ON the mark resets to unity. Anywhere else
                // two clicks are two clicks: this used to yank a fader set to
                // full back to 0 dB.
                guard abs(lastScrub - Self.unityFraction) < 0.04 else { return }
                ClickPlayer.shared.play(.tick)
                value = Self.unityFraction
            }
```

Add `@State private var lastScrub: Double = 0` under `@Binding var value`. Replace the accessibility value with `.accessibilityValue(VolumeCurve.readout(forPosition: value, unit: .percent).replacingOccurrences(of: "VOL  ", with: ""))`.

- [ ] **Step 5: Setting.** In `PlaybackPreferencesView` add `@State private var volumeReadoutUnit = PreferencesStore.shared.volumeReadoutUnit`, and after the "Output Device" section:

```swift
            Section("Volume") {
                Picker("Volume readout", selection: $volumeReadoutUnit) {
                    ForEach(VolumeReadoutUnit.allCases, id: \.self) { unit in
                        Text(unit.label).tag(unit)
                    }
                }
                .onChange(of: volumeReadoutUnit) { newValue in
                    PreferencesStore.shared.volumeReadoutUnit = newValue
                }
                Text("Shown on the display for a moment whenever the volume changes. 100% is the 0 dB mark.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
```

If `PlaybackPreferencesView` has a `refresh()` like `InterfacePreferencesView`'s (line ~348), re-read `volumeReadoutUnit` there too.

- [ ] **Step 6: Verify in the app.** `swift build`, launch, then: drag the fader (OLED shows `VOL  -12 dB` style text and clears ~1 s after release); press ⌘↑ from 0.90 (lands on `VOL  0 dB`); drag to the far right and double-click there (stays at `+5 dB`); double-click on the 0dB tick (resets); switch the setting to Percent (tick reads `VOL  100%`, far end `VOL  108%`); relaunch (no readout at launch). Then `scripts/test.sh` for the whole suite. Expected: all pass.

- [ ] **Step 7: Commit.** `git commit -am "feat(volume): transient OLED readout in dB or percent; fader no longer snaps back from full"`

### Task 3: Find why boost above unity is inaudible on local files

This is an investigation with a required written finding. Use superpowers:systematic-debugging. Do not change `VolumeCurve.maxDB`.

**Files:**
- Read: `Sources/CrateDiggerCore/Services/AudioLevelTap.swift` (`setMasterGain` :43, tap flags :73, gain multiply :174-185), `PlaybackService.swift` (`attachLevelMetering` :433-443, call sites :213 and :252, `setMasterGain` :417, :912)
- Likely modify: one of the two above. Test: `Tests/CrateDiggerCoreTests/AudioLevelTapGainTests.swift` (create, if the fix is in the store)

- [ ] **Step 1: Make a known signal.** `ffmpeg -f lavfi -i "sine=frequency=1000:duration=60" -af "volume=-12dB" -c:a pcm_s16le "$TMPDIR/sine-12.wav"` (use the scratchpad dir). Drop it on the app, play it.

- [ ] **Step 2: Measure, do not listen.** The tap multiplies before it meters (`AudioLevelTap.swift:174-185`). With the fader on the 0dB tick note the VU level; drag to the far right. +5 dB must show on the meter. Record both readings.

- [ ] **Step 3: Branch on the result.**
  - Meter rises, output does not: the tap's writes do not reach the output. Turn the EQ on with one band at +12 dB. EQ inaudible too → the cause is `kMTAudioProcessingTapCreationFlag_PostEffects` at `:73`; change it to `kMTAudioProcessingTapCreationFlag_PreEffects`, rebuild, re-measure with a loopback or by ear against the EQ. EQ audible → the writes land, so log `store.gainValue()` once per second inside the process callback and find why it is 1.
  - Meter does not rise: `setMasterGain` never reaches this item's tap. Add a temporary `AppLog` line in `AudioLevelTap.setMasterGain` and in `attachLevelMetering`. Prime suspect: each `attachLevelMetering` builds a fresh tap/store at gain 1, and only a fader *movement* pushes the gain, so every new item (and every gapless look-ahead item, `:252`) plays at unity until the fader next moves. Fix: `AVPlayerEngine` keeps `private var masterGain: Double = 1`, sets it in `setMasterGain`, and applies it to the new tap at the end of `attachLevelMetering`.
  - Meter rises and output rises: the stage works and +5 dB over the last 7.7% of travel is simply subtle. STOP and report this to the user with the two meter readings; raising `maxDB` moves `unityPosition` and every saved fader position, so it is their decision.

- [ ] **Step 4: Test what is testable.** If the fix is "carry the gain to a new tap", write the failing test first against whatever pure seam holds the gain (the store type in `AudioLevelTap.swift`): create a store, set gain 1.5, create the next item's store through the same path the engine uses, assert it reads 1.5. Run `scripts/test.sh --filter AudioLevelTapGainTests`, see it fail, implement, see it pass.

- [ ] **Step 5: Remove the temporary logging, re-measure, run `scripts/test.sh`.**

- [ ] **Step 6: Record the finding.** Add two or three sentences to `CLAUDE.md` under "### Playback" stating the root cause and the rule that prevents it (for example: "a new item's tap must be handed the current master gain; the fader only pushes on change").

- [ ] **Step 7: Commit.** `git commit -am "fix(volume): <root cause in one line>"` with the before/after meter readings in the body.

---

## Item 2: Footer

### Task 4: Measure, then make the footer symmetric

**Files:**
- Read/modify: `Sources/CrateDiggerApp/UI/Carbon/Footer/FooterShell.swift:38-45`, `Footer/TransportCluster.swift:8-26`, `Footer/PositionDial.swift:57-59`, `Controls/VolumeKnob.swift:43-45`, `Controls/FaderTrack.swift:88`

The layout code is symmetric on paper (both pods: padding 12, `minWidth: 184, maxWidth: 380`, `maxWidth: .infinity` frames in one `HStack(spacing: 28)` padded 26). The user sees POSITION further from the window's left edge than VOLUME from the right. Measure before touching anything.

- [ ] **Step 1: Capture.** `swift build`, launch, and for window widths 1100, 1200 and 1440 set both faders to their extremes (seek to 0:00 with a track loaded; volume to far right) and capture the window: `screencapture -l $(osascript -e 'tell app "System Events" to id of window 1 of process "CrateDiggerApp"') "$SCRATCH/footer-1200.png"` (if the window id lookup fails, use `screencapture -w` and click the window). Save into the scratchpad directory, not the repo.

- [ ] **Step 2: Measure in pixels** (divide by the backing scale, 2 on Retina). For each capture record four numbers: window left edge → POSITION rail's first pixel; VOLUME rail's last pixel → window right edge; and the same two for the cap edges. Reading the PNG with the Read tool and zooming is enough; write the twelve numbers down.

- [ ] **Step 3a: If the rail gaps differ by more than 1 pt,** find the element breaking the symmetry. Temporarily add `.border(.red)` to the `HStack` in `FooterShell`, to each pod, and to `TransportCluster`, rebuild and re-capture. Expected culprits, in order: the `HStack` overflowing its width at narrow windows because the 477 pt transport plus two 184 pt minimums plus padding exceeds the footer (an overflowing HStack is centred on its content, not its frame); or the footer itself not centred in the chassis. Fix the element that is off, remove the borders.

- [ ] **Step 3b: If the rail gaps are equal,** the asymmetry is optical. `TransportCluster` has four keys before PLAY and three after, so PLAY sits 28.5 pt right of the footer's centre. In `FooterShell.swift` wrap the cluster so both pods keep equal slack:

```swift
                TransportCluster()
                    // Four keys sit left of PLAY and three right, which put the
                    // dome 28.5 pt right of centre and made the left fader look
                    // stranded. 57 pt of empty trailing width centres PLAY
                    // while both faders keep the same gap to the window edge.
                    .padding(.trailing, 57)
```

- [ ] **Step 4: Re-capture at all three widths and re-measure.** Done means left and right rail gaps match within 1 pt at each width and PLAY's centre is within 1 pt of the window's centre.

- [ ] **Step 5: Commit.** `git commit -am "fix(footer): <what was off>"` with the before and after numbers in the body.

---

## Item 3: Prep Crate guide

### Task 5: `BrowserEmptyKind` in Core

**Files:**
- Create: `Sources/CrateDiggerCore/Models/BrowserEmptyKind.swift`
- Test: `Tests/CrateDiggerCoreTests/BrowserEmptyKindTests.swift`

**Interfaces:**
- Produces: `public enum BrowserEmptyKind: Equatable, Sendable { case noLibrary, disconnected, prepCrate, emptyCrate(name: String) }` and `static func resolve(source: Source, disconnected: Bool) -> BrowserEmptyKind` where `public enum Source: Equatable, Sendable { case localAll, localCrate(name: String), prepCrate, other }`. (`LibrarySource` lives in the app target, so Core takes this small mirror.)

- [ ] **Step 1: Failing test.**

```swift
#if canImport(XCTest)
import XCTest
@testable import CrateDiggerCore

final class BrowserEmptyKindTests: XCTestCase {
    func testPrepCrateExplainsItself() {
        XCTAssertEqual(BrowserEmptyKind.resolve(source: .prepCrate, disconnected: false), .prepCrate)
    }

    func testEmptyNamedCrateIsNotNoLibrary() {
        XCTAssertEqual(BrowserEmptyKind.resolve(source: .localCrate(name: "Jazz"), disconnected: false),
                       .emptyCrate(name: "Jazz"))
    }

    func testAllRecordsWithNothingIsNoLibrary() {
        XCTAssertEqual(BrowserEmptyKind.resolve(source: .localAll, disconnected: false), .noLibrary)
        XCTAssertEqual(BrowserEmptyKind.resolve(source: .other, disconnected: false), .noLibrary)
    }

    func testDisconnectedWinsForLocalSourcesOnly() {
        XCTAssertEqual(BrowserEmptyKind.resolve(source: .localAll, disconnected: true), .disconnected)
        XCTAssertEqual(BrowserEmptyKind.resolve(source: .localCrate(name: "Jazz"), disconnected: true), .disconnected)
        // The Prep Crate and non-library sources keep their own message: that is
        // today's behaviour (`isLocalSource` excludes them) and it stays.
        XCTAssertEqual(BrowserEmptyKind.resolve(source: .prepCrate, disconnected: true), .prepCrate)
        XCTAssertEqual(BrowserEmptyKind.resolve(source: .other, disconnected: true), .noLibrary)
    }
}
#endif
```

- [ ] **Step 2:** `scripts/test.sh --filter BrowserEmptyKindTests` → FAIL, type not found.

- [ ] **Step 3: Implement.**

```swift
import Foundation

/// Which message an empty browser shows. An empty Prep Crate or an empty crate
/// is not "no library loaded", and saying so sent people off to re-open folders.
public enum BrowserEmptyKind: Equatable, Sendable {
    case noLibrary
    case disconnected
    case prepCrate
    case emptyCrate(name: String)

    /// The app's `LibrarySource`, reduced to what this decision needs.
    public enum Source: Equatable, Sendable {
        case localAll
        case localCrate(name: String)
        case prepCrate
        case other
    }

    public static func resolve(source: Source, disconnected: Bool) -> BrowserEmptyKind {
        switch source {
        case .localAll:              return disconnected ? .disconnected : .noLibrary
        case .localCrate(let name):  return disconnected ? .disconnected : .emptyCrate(name: name)
        case .prepCrate:             return .prepCrate
        case .other:                 return .noLibrary
        }
    }
}
```

- [ ] **Step 4:** run again → PASS. **Step 5: Commit** `feat(browser): BrowserEmptyKind decides which empty state to draw`.

### Task 6: The two new empty states

**Files:**
- Modify: `Sources/CrateDiggerApp/UI/Carbon/Main/Browser/BrowserPane.swift:81-131` (`BrowserEmptyState`)

**Interfaces:**
- Consumes: `BrowserEmptyKind.resolve(source:disconnected:)`.

- [ ] **Step 1: Pick the content from the kind.** In `BrowserEmptyState`, replace the `if model.isLibraryDisconnected, model.isLocalSource { disconnected } else { noLibrary }` block with:

```swift
            switch emptyKind {
            case .disconnected:         disconnected
            case .noLibrary:            noLibrary
            case .prepCrate:            prepCrateGuide
            case .emptyCrate(let name): emptyCrate(name)
            }
```

and add:

```swift
    private var emptyKind: BrowserEmptyKind {
        let source: BrowserEmptyKind.Source
        switch model.currentSource {
        case .localAll:              source = .localAll
        case .localCrate(let name):  source = .localCrate(name: name)
        case .prepCrate:             source = .prepCrate
        default:                     source = .other
        }
        return BrowserEmptyKind.resolve(source: source, disconnected: model.isLibraryDisconnected)
    }
```

Keep the existing comment about the unplugged drive above the `switch`.

- [ ] **Step 2: The Prep Crate guide.**

```swift
    @ViewBuilder
    private var prepCrateGuide: some View {
        Image(systemName: "tray.and.arrow.down")
            .font(.system(size: 38, weight: .light))
            .foregroundStyle(theme.ink3)
        Text("The Prep Crate is empty")
            .font(CarbonFont.sans(18, weight: .heavy))
            .foregroundStyle(theme.ink)
        Text("This is the staging area. Everything you dig lands here first, so you can look it over before it joins your library. Scanning only reads: nothing on disk moves unless you ask it to.")
            .font(CarbonFont.mono(11))
            .foregroundStyle(theme.ink3)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 380)
        VStack(alignment: .leading, spacing: 6) {
            guideStep(1, "DIG CRATE (\u{2318}O), or drop a folder anywhere on the window.")
            guideStep(2, "Check it over: FIX TAGS, TAGS, artwork, CLEANUP.")
            guideStep(3, "Select what is ready and press ADD TO CRATE. It leaves the Prep Crate when it is filed.")
        }
        .frame(maxWidth: 380, alignment: .leading)
        KeyButton(style: .glowingOrange, action: { model.openFolderViaPanel() }) {
            HStack(spacing: 8) {
                Image(systemName: "folder.fill.badge.plus")
                    .font(.system(size: 12, weight: .bold))
                Text("DIG CRATE…")
            }
            .padding(.horizontal, 16)
        }
        .frame(width: 220, height: 38)
    }

    private func guideStep(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number)")
                .font(CarbonFont.mono(11, weight: .bold))
                .foregroundStyle(theme.ink2)
            Text(text)
                .font(CarbonFont.mono(11))
                .foregroundStyle(theme.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func emptyCrate(_ name: String) -> some View {
        Image(systemName: "shippingbox")
            .font(.system(size: 38, weight: .light))
            .foregroundStyle(theme.ink3)
        Text("\u{201C}\(name)\u{201D} is empty")
            .font(CarbonFont.sans(18, weight: .heavy))
            .foregroundStyle(theme.ink)
        Text("Select albums or tracks in All Records or the Prep Crate and press ADD TO CRATE, or drag them onto this crate in the sidebar.")
            .font(CarbonFont.mono(11))
            .foregroundStyle(theme.ink3)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 380)
    }
```

If `theme.ink2` does not exist, use `theme.ink`. Before writing "drag them onto this crate in the sidebar", confirm crate rows accept track drags: `grep -n "onDrop\|dropDestination" Sources/CrateDiggerApp/UI/Carbon/Sources/SourcesSidebar.swift`. If they do not, cut the sentence after "ADD TO CRATE."

- [ ] **Step 3: Verify.** `swift build`, launch, Clear Prep Crate, select it: the guide shows and DIG CRATE… opens the folder panel. Create a new crate and select it: the empty-crate message shows. Select All Records with no library: "No library loaded" still shows. Check light and dark.

- [ ] **Step 4: Commit** `feat(browser): an empty Prep Crate explains itself; an empty crate stops saying "No library loaded"`.

---

## Item 4: Stream downloads

### Task 7: Chapters to markers

**Files:**
- Modify: `Sources/CrateDiggerCore/Models/RecordMarker.swift`
- Test: `Tests/CrateDiggerCoreTests/RecordMarkerFromChaptersTests.swift`

**Interfaces:**
- Produces: `RecordMarker.markers(from chapters: [StreamChapter], duration: Double?) -> [RecordMarker]`.

- [ ] **Step 1: Failing test.**

```swift
#if canImport(XCTest)
import XCTest
@testable import CrateDiggerCore

final class RecordMarkerFromChaptersTests: XCTestCase {
    private func ch(_ s: Double, _ e: Double?, _ t: String) -> StreamChapter {
        StreamChapter(startSeconds: s, endSeconds: e, title: t)
    }

    func testEachChapterClosesOnTheNextOnesStart() {
        let m = RecordMarker.markers(from: [ch(0, 200, "A"), ch(180, nil, "B"), ch(400, nil, "C")], duration: 600)
        XCTAssertEqual(m.map(\.startSeconds), [0, 180, 400])
        XCTAssertEqual(m.map(\.endSeconds), [180, 400, 600])   // never overlaps, last closes on the file
        XCTAssertEqual(m.map(\.title), ["A", "B", "C"])
    }

    func testLastChapterFallsBackToItsOwnEndWithoutADuration() {
        let m = RecordMarker.markers(from: [ch(0, nil, "A"), ch(100, 250, "B")], duration: nil)
        XCTAssertEqual(m.last?.endSeconds, 250)
    }

    func testOpenEndedLastChapterWithNoDurationIsDropped() {
        let m = RecordMarker.markers(from: [ch(0, nil, "A"), ch(100, nil, "B"), ch(200, nil, "C")], duration: nil)
        XCTAssertEqual(m.map(\.title), ["A", "B"])
    }

    func testUnsortedInputIsSorted() {
        let m = RecordMarker.markers(from: [ch(100, nil, "B"), ch(0, nil, "A")], duration: 300)
        XCTAssertEqual(m.map(\.title), ["A", "B"])
    }

    func testSubSecondChaptersAreDropped() {
        let m = RecordMarker.markers(from: [ch(0, nil, "A"), ch(100, nil, "blip"), ch(100.4, nil, "B")], duration: 300)
        XCTAssertEqual(m.map(\.title), ["A", "B"])
    }

    func testFewerThanTwoChaptersMeansUndivided() {
        XCTAssertTrue(RecordMarker.markers(from: [], duration: 300).isEmpty)
        XCTAssertTrue(RecordMarker.markers(from: [ch(0, nil, "Only")], duration: 300).isEmpty)
    }
}
#endif
```

- [ ] **Step 2:** `scripts/test.sh --filter RecordMarkerFromChaptersTests` → FAIL.

- [ ] **Step 3: Implement** at the end of `RecordMarker.swift`:

```swift
public extension RecordMarker {
    /// A downloaded stream's chapters as Record Divider markers, so it plays and
    /// exports track by track. A chapter closes on the next one's start (yt-dlp's
    /// own end times can overlap), the last on the file's real duration, else on
    /// its own end. Fewer than two usable chapters means an ordinary, undivided track.
    static func markers(from chapters: [StreamChapter], duration: Double?) -> [RecordMarker] {
        let sorted = chapters.sorted { $0.startSeconds < $1.startSeconds }
        var markers: [RecordMarker] = []
        for (i, chapter) in sorted.enumerated() {
            let next = sorted.indices.contains(i + 1) ? sorted[i + 1].startSeconds : nil
            guard let end = next ?? duration ?? chapter.endSeconds,
                  end - chapter.startSeconds >= 1 else { continue }
            markers.append(RecordMarker(startSeconds: chapter.startSeconds, endSeconds: end, title: chapter.title))
        }
        return markers.count >= 2 ? markers : []
    }
}
```

- [ ] **Step 4:** run → PASS. **Step 5: Commit** `feat(radio): stream chapters map onto Record Divider markers`.

### Task 8: The download link on `StreamSource`, the Downloads category, the offline resolver

**Files:**
- Modify: `Sources/CrateDiggerCore/Models/StreamSource.swift`, `Sources/CrateDiggerCore/Services/StreamStore.swift`, `Sources/CrateDiggerCore/Services/StreamResolver.swift`
- Test: `Tests/CrateDiggerCoreTests/StreamDownloadLinkTests.swift` (create); extend the existing `StreamResolverTests`

**Interfaces:**
- Produces: `StreamSource.downloadedPath: String?`; `StreamSource.isDownloaded(fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> Bool`; `RadioCategory.downloaded`; `StreamStore.setDownload(path: String?, forStreamID: String) -> [StreamSource]`; `StreamStore.repointDownload(from: String, to: String) -> [StreamSource]`; `StreamResolver.init(ytdlpURL: URL?, runner:)`; `StreamResolverError.toolMissing`.

- [ ] **Step 1: Failing tests.**

```swift
#if canImport(XCTest)
import XCTest
@testable import CrateDiggerCore

final class StreamDownloadLinkTests: XCTestCase {
    private func stream(_ id: String, kind: StreamKind = .mix, path: String? = nil) -> StreamSource {
        var s = StreamSource(id: id, url: "https://youtu.be/\(id)", title: id, channel: "Ch",
                             kind: kind, hue: 0, addedAt: Date(timeIntervalSince1970: 0))
        s.downloadedPath = path
        return s
    }

    func testBlobFromBeforeDownloadsStillDecodes() throws {
        let old = #"[{"id":"a","url":"u","title":"t","channel":"c","kind":"mix","hue":1,"provider":"youtube","addedAt":0}]"#
        let decoded = try JSONDecoder().decode([StreamSource].self, from: Data(old.utf8))
        XCTAssertNil(decoded[0].downloadedPath)
    }

    func testDownloadedNeedsThePathAndTheFile() {
        XCTAssertFalse(stream("a").isDownloaded(fileExists: { _ in true }))
        XCTAssertFalse(stream("a", path: "/x.m4a").isDownloaded(fileExists: { _ in false }))
        XCTAssertTrue(stream("a", path: "/x.m4a").isDownloaded(fileExists: { $0 == "/x.m4a" }))
    }

    func testDownloadsCategoryIsAFilterNotAHome() {
        let s = stream("a", path: "/x.m4a")
        XCTAssertEqual(RadioCategory.of(s), .youtubeRecords)   // its home does not change
        XCTAssertTrue(RadioCategory.youtubeRecords.contains(s))
        XCTAssertEqual(RadioCategory.downloaded.title, "Downloads")
    }

    func testRepointAndSetDownload() {
        let suite = "StreamDownloadLinkTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = StreamStore(prefs: PreferencesStore(defaults: defaults))
        store.save([stream("a"), stream("b", path: "/old/b.m4a")])

        XCTAssertEqual(store.setDownload(path: "/lib/a.m4a", forStreamID: "a").first { $0.id == "a" }?.downloadedPath, "/lib/a.m4a")
        XCTAssertEqual(store.repointDownload(from: "/old/b.m4a", to: "/new/b.m4a").first { $0.id == "b" }?.downloadedPath, "/new/b.m4a")
        XCTAssertNil(store.setDownload(path: nil, forStreamID: "a").first { $0.id == "a" }?.downloadedPath)
        XCTAssertEqual(store.repointDownload(from: "/nobody", to: "/x").count, 2)   // a miss changes nothing
    }
}
#endif
```

`RadioCategory.downloaded.contains` needs the filesystem, so it is covered through `isDownloaded` above. Check how other tests build a `PreferencesStore` on a private suite (`grep -rn "PreferencesStore(defaults" Tests | head -3`) and match that initializer's spelling.

In `StreamResolverTests` add (reuse that file's existing fake runner; it must record whether `run` was called):

```swift
    func testADownloadedStreamResolvesToItsFileWithoutRunningYtDlp() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).m4a")
        FileManager.default.createFile(atPath: file.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: file) }
        var s = StreamSource(id: "a", url: "https://youtu.be/a", title: "A", channel: "C", kind: .mix,
                             hue: 0, addedAt: Date(), durationSeconds: 300)
        s.downloadedPath = file.path

        // No yt-dlp at all: offline listening must not need it.
        let resolved = try StreamResolver(ytdlpURL: nil).resolve(s)
        XCTAssertEqual(resolved.playbackURL, file)
        XCTAssertFalse(resolved.isLive)
        XCTAssertEqual(resolved.durationSeconds, 300)
    }

    func testWithoutYtDlpAndWithoutADownloadResolvingFailsClearly() {
        let s = StreamSource(id: "a", url: "https://youtu.be/a", title: "A", channel: "C", kind: .mix, hue: 0, addedAt: Date())
        XCTAssertThrowsError(try StreamResolver(ytdlpURL: nil).resolve(s)) {
            XCTAssertEqual($0 as? StreamResolverError, .toolMissing)
        }
    }
```

- [ ] **Step 2:** `scripts/test.sh --filter StreamDownloadLinkTests` and `--filter StreamResolverTests` → FAIL.

- [ ] **Step 3: `StreamSource`.** Add the stored property after `chapters`:

```swift
    /// Path of the offline copy made by Download for Offline; nil = none. The
    /// file is an ordinary library track, so it can move: `StreamStore.repointDownload`
    /// follows it, and `isDownloaded` also checks the file is really there, so a
    /// missed repoint reads as "not downloaded", never as a wrong file.
    public var downloadedPath: String?
```

Add `downloadedPath: String? = nil` as the last `init` parameter and assign it. Add:

```swift
    public func isDownloaded(fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> Bool {
        guard let downloadedPath else { return false }
        return fileExists(downloadedPath)
    }
```

`RadioCategory`: add `case downloaded`; `title` → `"Downloads"`; `iconName` → `"arrow.down.circle"`; and:

```swift
    /// Whether a stream belongs to this category. `downloaded` is a filter over
    /// the other two, not a home: `of(_:)` never returns it.
    public func contains(_ stream: StreamSource) -> Bool {
        // ponytail: one stat per stream per sidebar draw; cache if lists reach hundreds.
        self == .downloaded ? stream.isDownloaded() : RadioCategory.of(stream) == self
    }
```

Build and fix any non-exhaustive `switch` over `RadioCategory` the compiler reports (`grep -rn "case .youtubeRecords" Sources`): in each, `.downloaded` behaves like `.youtubeRecords`.

- [ ] **Step 4: `StreamStore`.**

```swift
    /// Record (or clear, with nil) a stream's offline copy.
    @discardableResult
    public func setDownload(path: String?, forStreamID id: String) -> [StreamSource] {
        var list = all()
        guard let i = list.firstIndex(where: { $0.id == id }) else { return list }
        list[i].downloadedPath = path
        save(list)
        return list
    }

    /// Follow a downloaded file that a retag, rename or library move relocated.
    /// Called beside `ListeningStore.repoint(from:to:)`.
    @discardableResult
    public func repointDownload(from oldPath: String, to newPath: String) -> [StreamSource] {
        var list = all()
        guard let i = list.firstIndex(where: { $0.downloadedPath == oldPath }) else { return list }
        list[i].downloadedPath = newPath
        save(list)
        return list
    }
```

- [ ] **Step 5: `StreamResolver`.** `ytdlpURL` becomes `URL?` (property and `init`), add `case toolMissing` to `StreamResolverError`, and start `resolve` with:

```swift
        // An offline copy plays with no network and no yt-dlp.
        if stream.isDownloaded(), let path = stream.downloadedPath {
            return ResolvedStream(playbackURL: URL(fileURLWithPath: path), isLive: false,
                                  durationSeconds: stream.durationSeconds)
        }
        guard let ytdlpURL else { throw StreamResolverError.toolMissing }
```

- [ ] **Step 6:** run both filters → PASS, then `swift build` (the app's `StreamResolver(ytdlpURL: url)` call still compiles, `URL` promotes to `URL?`).

- [ ] **Step 7: Commit** `feat(radio): streams remember their offline copy; Downloads category; resolver plays the file offline`.

### Task 9: `StreamDownloader` and the streaming runner

**Files:**
- Create: `Sources/CrateDiggerCore/Services/StreamingCommandRunner.swift`, `Sources/CrateDiggerCore/Services/StreamDownloader.swift`
- Test: `Tests/CrateDiggerCoreTests/StreamDownloaderTests.swift`

**Interfaces:**
- Produces:
  - `protocol StreamingCommandRunning { func start(executableURL: URL, arguments: [String], onLine: @escaping @Sendable (String) -> Void, completion: @escaping @Sendable (Int32, String) -> Void) throws -> StreamingCommandHandle }`
  - `protocol StreamingCommandHandle: Sendable { func terminate() }`
  - `struct StreamDownloadPlan: Equatable, Sendable { folder: URL; baseName: String; var fileURL: URL }`
  - `enum StreamDownloadError: Error, Equatable { case notDownloadable(StreamKind), commandFailed(Int32, String), fileMissing }`
  - `StreamDownloader.plan(for: StreamSource, in: URL) throws -> StreamDownloadPlan`
  - `StreamDownloader.arguments(for: StreamSource, plan: StreamDownloadPlan, ffmpegURL: URL?) -> [String]`
  - `StreamDownloader.progress(fromLine: String) -> Double?`
  - `StreamDownloader(ytdlpURL:runner:).download(_:plan:ffmpegURL:onProgress:completion:) throws -> StreamingCommandHandle`

- [ ] **Step 1: Failing tests.**

```swift
#if canImport(XCTest)
import XCTest
@testable import CrateDiggerCore

final class StreamDownloaderTests: XCTestCase {
    private func stream(kind: StreamKind = .mix, title: String = "Deep House Mix", channel: String = "Some Channel") -> StreamSource {
        StreamSource(id: "abc", url: "https://youtu.be/abc", title: title, channel: channel,
                     kind: kind, hue: 0, addedAt: Date(timeIntervalSince1970: 0))
    }
    private let root = URL(fileURLWithPath: "/Music/Library")

    func testPlanIsChannelThenTitle() throws {
        let plan = try StreamDownloader.plan(for: stream(), in: root)
        XCTAssertEqual(plan.folder.path, "/Music/Library/Some Channel/Deep House Mix")
        XCTAssertEqual(plan.fileURL.path, "/Music/Library/Some Channel/Deep House Mix/Deep House Mix.m4a")
    }

    func testPlanSanitisesAndSurvivesAnEmptyChannel() throws {
        let plan = try StreamDownloader.plan(for: stream(title: "A/B: 100% live", channel: ""), in: root)
        XCTAssertFalse(plan.baseName.contains("/"))
        XCTAssertEqual(plan.folder.deletingLastPathComponent().lastPathComponent, "Unknown Channel")
    }

    func testLiveAndPlaylistAreRefused() {
        XCTAssertThrowsError(try StreamDownloader.plan(for: stream(kind: .live), in: root)) {
            XCTAssertEqual($0 as? StreamDownloadError, .notDownloadable(.live))
        }
        XCTAssertThrowsError(try StreamDownloader.plan(for: stream(kind: .playlist), in: root)) {
            XCTAssertEqual($0 as? StreamDownloadError, .notDownloadable(.playlist))
        }
    }

    func testArguments() throws {
        let s = stream(title: "100% live")
        let plan = try StreamDownloader.plan(for: s, in: root)
        let args = StreamDownloader.arguments(for: s, plan: plan, ffmpegURL: URL(fileURLWithPath: "/opt/ffmpeg"))
        XCTAssertEqual(Array(args.suffix(2)), ["--", "https://youtu.be/abc"])   // "--" so a URL is never a flag
        XCTAssertTrue(args.contains("--no-playlist"))
        XCTAssertTrue(args.contains("--newline"))
        XCTAssertEqual(args[args.firstIndex(of: "-f")! + 1], "bestaudio[ext=m4a]/bestaudio")
        XCTAssertEqual(args[args.firstIndex(of: "--audio-format")! + 1], "m4a")
        XCTAssertEqual(args[args.firstIndex(of: "--ffmpeg-location")! + 1], "/opt/ffmpeg")
        // A literal % in the title must not be read as an output-template field.
        let template = args[args.firstIndex(of: "-o")! + 1]
        XCTAssertTrue(template.hasSuffix("/100%% live.%(ext)s"), template)
    }

    func testArgumentsWithoutFfmpegOmitTheLocation() throws {
        let s = stream()
        let args = StreamDownloader.arguments(for: s, plan: try StreamDownloader.plan(for: s, in: root), ffmpegURL: nil)
        XCTAssertFalse(args.contains("--ffmpeg-location"))
    }

    func testProgressParsing() {
        XCTAssertEqual(StreamDownloader.progress(fromLine: "CDPROGRESS 500 1000 NA")!, 0.5, accuracy: 0.001)
        XCTAssertEqual(StreamDownloader.progress(fromLine: "CDPROGRESS 250 NA 1000")!, 0.25, accuracy: 0.001) // estimate
        XCTAssertEqual(StreamDownloader.progress(fromLine: "CDPROGRESS 2000 1000 NA")!, 1, accuracy: 0.001)   // clamped
        XCTAssertNil(StreamDownloader.progress(fromLine: "CDPROGRESS 500 NA NA"))
        XCTAssertNil(StreamDownloader.progress(fromLine: "CDPROGRESS 500 0 NA"))
        XCTAssertNil(StreamDownloader.progress(fromLine: "[download] Destination: x.m4a"))
        XCTAssertNil(StreamDownloader.progress(fromLine: ""))
    }
}
#endif
```

- [ ] **Step 2:** `scripts/test.sh --filter StreamDownloaderTests` → FAIL.

- [ ] **Step 3: The runner.** `StreamingCommandRunner.swift`:

```swift
import Foundation

public protocol StreamingCommandHandle: Sendable {
    /// Kill the process. Its completion still fires, with a non-zero status.
    func terminate()
}

/// Like `CommandRunning`, for a tool whose output is wanted while it runs.
/// `CommandRunning` reads to end of file, so it can neither report progress nor
/// be stopped; a download needs both.
public protocol StreamingCommandRunning {
    func start(executableURL: URL,
               arguments: [String],
               onLine: @escaping @Sendable (String) -> Void,
               completion: @escaping @Sendable (_ status: Int32, _ errorTail: String) -> Void) throws -> StreamingCommandHandle
}

public struct ProcessStreamingCommandRunner: StreamingCommandRunning {
    public init() {}

    private final class Handle: StreamingCommandHandle, @unchecked Sendable {
        let process: Process
        init(_ process: Process) { self.process = process }
        func terminate() { if process.isRunning { process.terminate() } }
    }

    /// Splits a byte stream into lines and remembers the last few for error reports.
    private final class LineBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var pending = Data()
        private var tail: [String] = []

        func feed(_ data: Data, emit: (String) -> Void) {
            lock.lock(); defer { lock.unlock() }
            pending.append(data)
            // yt-dlp redraws progress with \r when --newline is missing; treat both as ends of line.
            while let i = pending.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                let line = String(decoding: pending[pending.startIndex..<i], as: UTF8.self)
                pending.removeSubrange(pending.startIndex...i)
                guard !line.isEmpty else { continue }
                tail.append(line); if tail.count > 12 { tail.removeFirst() }
                emit(line)
            }
        }
        var errorTail: String { lock.lock(); defer { lock.unlock() }; return tail.joined(separator: "\n") }
    }

    public func start(executableURL: URL,
                      arguments: [String],
                      onLine: @escaping @Sendable (String) -> Void,
                      completion: @escaping @Sendable (Int32, String) -> Void) throws -> StreamingCommandHandle {
        // Same guard as ProcessCommandRunner: an embedded NUL raises an ObjC
        // exception Swift cannot catch.
        if let offending = ([executableURL.path] + arguments).first(where: { $0.utf8.contains(0) }) {
            throw ConversionServiceError.unrepresentableArgument(offending)
        }
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = ProcessCommandRunner.augmentedPATH(env["PATH"])   // yt-dlp needs deno/node and ffmpeg
        process.environment = env

        let pipe = Pipe()   // stdout and stderr together: yt-dlp's progress stream varies by mode
        process.standardOutput = pipe
        process.standardError = pipe
        let buffer = LineBuffer()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            buffer.feed(data, emit: onLine)
        }
        process.terminationHandler = { finished in
            pipe.fileHandleForReading.readabilityHandler = nil
            let rest = pipe.fileHandleForReading.readDataToEndOfFile()
            if !rest.isEmpty { buffer.feed(rest + Data([0x0A]), emit: onLine) }
            completion(finished.terminationStatus, buffer.errorTail)
        }
        try process.run()
        return Handle(process)
    }
}
```

- [ ] **Step 4: The downloader.** `StreamDownloader.swift`:

```swift
import Foundation

public struct StreamDownloadPlan: Equatable, Sendable {
    public let folder: URL
    public let baseName: String
    public var fileURL: URL { folder.appendingPathComponent(baseName).appendingPathExtension("m4a") }
}

public enum StreamDownloadError: Error, Equatable {
    /// Live streams never end and a playlist is many downloads.
    case notDownloadable(StreamKind)
    case commandFailed(Int32, String)
    /// yt-dlp exited 0 but the planned file is not there.
    case fileMissing
}

/// Saves a stream's audio for offline listening by running yt-dlp. The plan,
/// the argument vector and the progress parsing are pure; only `download` spawns.
public struct StreamDownloader: @unchecked Sendable {
    private let ytdlpURL: URL
    private let runner: StreamingCommandRunning

    public init(ytdlpURL: URL, runner: StreamingCommandRunning = ProcessStreamingCommandRunner()) {
        self.ytdlpURL = ytdlpURL
        self.runner = runner
    }

    /// `<root>/<Channel>/<Title>/<Title>.m4a`. One folder per download so its
    /// cover.jpg belongs to it alone.
    public static func plan(for stream: StreamSource, in root: URL) throws -> StreamDownloadPlan {
        guard stream.kind == .video || stream.kind == .mix else {
            throw StreamDownloadError.notDownloadable(stream.kind)
        }
        let channel = PathComponentSanitizer.sanitize(stream.channel, fallback: "Unknown Channel")
        let title = PathComponentSanitizer.sanitize(stream.title, fallback: stream.id)
        return StreamDownloadPlan(
            folder: root.appendingPathComponent(channel).appendingPathComponent(title),
            baseName: title)
    }

    /// Raw byte counts, not yt-dlp's formatted percent string, which carries
    /// colour codes and padding.
    static let progressTemplate =
        "download:CDPROGRESS %(progress.downloaded_bytes)s %(progress.total_bytes)s %(progress.total_bytes_estimate)s"

    public static func arguments(for stream: StreamSource, plan: StreamDownloadPlan, ffmpegURL: URL?) -> [String] {
        // The file name is ours, so a % in a title must not read as a template field.
        let output = plan.folder.appendingPathComponent(plan.baseName).path
            .replacingOccurrences(of: "%", with: "%%") + ".%(ext)s"
        var args = [
            "-f", "bestaudio[ext=m4a]/bestaudio",   // AAC as YouTube made it; AVPlayer cannot play Opus
            "-x", "--audio-format", "m4a",          // only re-encodes when the m4a rung missed
            "--embed-metadata",
            "--no-playlist", "--no-overwrites",
            "--newline", "--progress-template", progressTemplate,
            "-o", output,
        ]
        if let ffmpegURL { args += ["--ffmpeg-location", ffmpegURL.path] }
        // "--" ends option parsing so a stored URL can never be read as a flag.
        return args + ["--", stream.url]
    }

    /// 0...1 from one progress-template line; nil for any other line.
    public static func progress(fromLine line: String) -> Double? {
        let parts = line.split(separator: " ")
        guard parts.count == 4, parts[0] == "CDPROGRESS", let done = Double(parts[1]) else { return nil }
        guard let total = Double(parts[2]) ?? Double(parts[3]), total > 0 else { return nil }
        return Swift.min(1, Swift.max(0, done / total))
    }

    @discardableResult
    public func download(_ stream: StreamSource,
                         plan: StreamDownloadPlan,
                         ffmpegURL: URL?,
                         onProgress: @escaping @Sendable (Double) -> Void,
                         completion: @escaping @Sendable (Result<URL, StreamDownloadError>) -> Void) throws -> StreamingCommandHandle {
        try FileManager.default.createDirectory(at: plan.folder, withIntermediateDirectories: true)
        return try runner.start(
            executableURL: ytdlpURL,
            arguments: Self.arguments(for: stream, plan: plan, ffmpegURL: ffmpegURL),
            onLine: { line in if let p = Self.progress(fromLine: line) { onProgress(p) } },
            completion: { status, tail in
                guard status == 0 else { return completion(.failure(.commandFailed(status, tail))) }
                FileManager.default.fileExists(atPath: plan.fileURL.path)
                    ? completion(.success(plan.fileURL))
                    : completion(.failure(.fileMissing))
            })
    }
}
```

`PathComponentSanitizer.sanitize(_:fallback:)` lives at `OutputPathPlanner.swift:571`; read it once to confirm it returns the fallback for an empty or all-illegal string, which `testPlanSanitisesAndSurvivesAnEmptyChannel` relies on.

- [ ] **Step 5:** run → PASS.

- [ ] **Step 6: Prove the argv against the real tool** (needs network and the user's yt-dlp; if either is missing, say so in the task report rather than skipping silently). In the scratchpad directory run yt-dlp by hand with exactly the vector `arguments` produces for a short Creative Commons video, and confirm: `CDPROGRESS` lines appear with numbers, the file lands at the planned `.m4a` path, and `afinfo <file>` reports AAC. If progress lines do not appear, the fix belongs in `progressTemplate` and its test.

- [ ] **Step 7: Commit** `feat(radio): StreamDownloader and a streaming command runner`.

### Task 10: Download for Offline

**Files:**
- Create: `Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel+StreamDownload.swift`
- Modify: `Sources/CrateDiggerCore/Services/PreferencesStore.swift` (next to `hasSeenWelcomeTour`, ~line 491)
- Modify: `Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel.swift` (`handleImport` ~:3700; stored properties beside `streamStore` ~:1156)
- Modify: `Sources/CrateDiggerApp/UI/Carbon/Main/RadioListView.swift:30-42`

**Interfaces:**
- Consumes: Task 7 `RecordMarker.markers(from:duration:)`, Task 8 `streamStore.setDownload`, `isDownloaded()`, Task 9 `StreamDownloader`.
- Produces: `LibraryViewModel.downloadStream(id: String)`, `cancelStreamDownload()`, `isDownloadingStream: Bool`, `canDownload(_ stream: StreamSource) -> Bool`.

- [ ] **Step 1: Preference.** Key `static let hasAcknowledgedStreamDownloadNotice = "cratedigger.radio.downloadNoticeAcknowledged"` and:

```swift
    /// The personal-use notice shown before the first stream download. Set only
    /// when the user goes ahead; Cancel shows it again next time.
    public var hasAcknowledgedStreamDownloadNotice: Bool {
        get { defaults.bool(forKey: Key.hasAcknowledgedStreamDownloadNotice) }
        set { defaults.set(newValue, forKey: Key.hasAcknowledgedStreamDownloadNotice) }
    }
```

- [ ] **Step 2: State.** In `LibraryViewModel.swift` beside `let streamStore = StreamStore()`:

```swift
    /// The running yt-dlp download, if any. One at a time.
    var streamDownloadHandle: StreamingCommandHandle?
    @Published var downloadingStreamID: String?
    /// What to do with a downloaded file when its scan reaches `handleImport`,
    /// keyed by standardized file path. See `LibraryViewModel+StreamDownload`.
    var pendingStreamImports: [String: PendingStreamImport] = [:]
```

- [ ] **Step 3: The extension.**

```swift
import AppKit
import CrateDiggerCore
import Foundation

/// A downloaded stream waiting for its scan: the markers and tag defaults the
/// scanner cannot know, and the stream to link the file back to.
struct PendingStreamImport {
    let streamID: String
    let markers: [RecordMarker]
    let artist: String
    let album: String
}

/// Download for Offline: yt-dlp saves a stream's audio into the library, it
/// lands in the Prep Crate like any dig, and its chapters arrive as Record
/// Divider markers. yt-dlp is bring-your-own, as for playback.
extension LibraryViewModel {
    var isDownloadingStream: Bool { downloadingStreamID != nil }

    /// Live never ends and a playlist is many downloads.
    func canDownload(_ stream: StreamSource) -> Bool {
        (stream.kind == .video || stream.kind == .mix) && !stream.isDownloaded()
    }

    func downloadStream(id: String) {
        guard !refuseWhileLibraryDisconnected() else { return }
        guard let stream = streams.first(where: { $0.id == id }), canDownload(stream) else { return }
        guard !isDownloadingStream else { return showOLEDNotice("ONE DOWNLOAD AT A TIME") }
        guard let ytdlp = resolvedYtDlpURL() else {
            appAlert = .error(title: "yt-dlp Not Found",
                              message: "Downloading needs yt-dlp. Install it (for example with Homebrew: brew install yt-dlp) or set its path in Settings.")
            return
        }
        guard let root = currentConversionDestinationURL ?? managedLibraryFolderURL else {
            appAlert = .error(title: "No Destination Set",
                              message: "Configure a default output folder in Preferences first.")
            return
        }
        guard confirmPersonalUse() else { return }

        let plan: StreamDownloadPlan
        do { plan = try StreamDownloader.plan(for: stream, in: root) }
        catch { return appAlert = .error(title: "Can't Download", message: "Only single videos and mixes can be downloaded.") }
        guard !FileManager.default.fileExists(atPath: plan.fileURL.path) else {
            // Already on disk from an earlier run: adopt it instead of fetching again.
            return finishStreamDownload(stream, fileURL: plan.fileURL)
        }

        // A stream added but never opened has no chapters cached yet. Ask now;
        // `finishStreamDownload` reads the stream again when the file is ready.
        if stream.chapters == nil { fetchMetadata(for: id) }

        downloadingStreamID = id
        oledView = .cdRip
        conversionProgress = ConversionProgressSnapshot(jobsCompleted: 0, jobsTotal: 100,
                                                        currentFilename: stream.title, isRunning: true)
        let ffmpeg = ExternalToolLocator().resolveOptional(.ffmpeg)?.url
        do {
            streamDownloadHandle = try StreamDownloader(ytdlpURL: ytdlp).download(
                stream, plan: plan, ffmpegURL: ffmpeg,
                onProgress: { [weak self] fraction in
                    Task { @MainActor in
                        guard let self, self.downloadingStreamID == id else { return }
                        self.conversionProgress = ConversionProgressSnapshot(
                            jobsCompleted: Int(fraction * 100), jobsTotal: 100,
                            currentFilename: stream.title, isRunning: true)
                    }
                },
                completion: { [weak self] result in
                    Task { @MainActor in self?.streamDownloadEnded(stream, plan: plan, result: result) }
                })
        } catch {
            endStreamDownloadUI()
            appAlert = .error(title: "Download Failed", message: error.localizedDescription)
        }
    }

    /// Stops yt-dlp for real (unlike conversion) and clears its partial file.
    func cancelStreamDownload() {
        streamDownloadHandle?.terminate()
    }

    private func streamDownloadEnded(_ stream: StreamSource, plan: StreamDownloadPlan,
                                     result: Result<URL, StreamDownloadError>) {
        endStreamDownloadUI()
        switch result {
        case .success(let fileURL):
            finishStreamDownload(stream, fileURL: fileURL)
        case .failure(let error):
            // yt-dlp leaves "<name>.m4a.part" (and .ytdl) behind when killed.
            if let leftovers = try? FileManager.default.contentsOfDirectory(at: plan.folder, includingPropertiesForKeys: nil) {
                for url in leftovers where ["part", "ytdl"].contains(url.pathExtension) {
                    try? FileManager.default.removeItem(at: url)
                }
                if (try? FileManager.default.contentsOfDirectory(atPath: plan.folder.path))?.isEmpty == true {
                    try? FileManager.default.removeItem(at: plan.folder)
                }
            }
            if case .commandFailed(let status, let detail) = error, status != 15 {   // 15 = our own terminate
                // Same inline FIX panel a failed stream gets, not a throwaway alert.
                streamFailure = StreamFailureAdvisor.diagnose(detail: detail, ytdlpInstalled: true)
                AppLog.library.error("Stream download failed (\(status)): \(detail)")
            } else if error == .fileMissing {
                appAlert = .error(title: "Download Failed", message: "yt-dlp finished but the file was not written.")
            }
        }
    }

    private func endStreamDownloadUI() {
        streamDownloadHandle = nil
        downloadingStreamID = nil
        conversionProgress = .idle
        if oledView == .cdRip { oledView = .nowPlaying }
    }

    /// Cover, markers and tag defaults, then scan the folder into the Prep Crate.
    private func finishStreamDownload(_ stream: StreamSource, fileURL: URL) {
        // The copy captured when the download began may predate its metadata.
        let stream = streams.first(where: { $0.id == stream.id }) ?? stream
        let markers = RecordMarker.markers(from: stream.chapters ?? [], duration: stream.durationSeconds)
        pendingStreamImports[fileURL.standardizedFileURL.path] = PendingStreamImport(
            streamID: stream.id, markers: markers, artist: stream.channel, album: stream.title)

        let folder = fileURL.deletingLastPathComponent()
        let thumbnail = stream.thumbnailURL.flatMap(URL.init(string:))
        Task { [weak self] in
            // Folder art is resolveArtwork's second rung; embedding a thumbnail in
            // m4a needs yt-dlp extras we cannot count on.
            if let thumbnail, let (data, _) = try? await URLSession.shared.data(from: thumbnail), !data.isEmpty {
                try? data.write(to: folder.appendingPathComponent("cover.jpg"), options: .atomic)
            }
            await MainActor.run {
                guard let self else { return }
                self.loadFolders([folder])
                self.appAlert = .info(
                    title: "Downloaded",
                    message: markers.isEmpty
                        ? "\u{201C}\(stream.title)\u{201D} is in the Prep Crate."
                        : "\u{201C}\(stream.title)\u{201D} is in the Prep Crate, divided into \(markers.count) tracks. Convert it, or transfer it with a converting device profile, to get one file per track.")
            }
        }
    }

    /// Called from `handleImport` before staging. Gives a just-downloaded file its
    /// chapter markers and the tags yt-dlp left blank, and links the stream to it.
    func applyingPendingStreamImports(to tracks: [LoadedTrack]) -> [LoadedTrack] {
        guard !pendingStreamImports.isEmpty else { return tracks }
        return tracks.map { loaded in
            let path = loaded.track.fileURL.standardizedFileURL.path
            guard let pending = pendingStreamImports.removeValue(forKey: path) else { return loaded }
            var metadata = loaded.metadata
            if (metadata.artist ?? "").isEmpty { metadata.artist = pending.artist }
            if (metadata.album ?? "").isEmpty { metadata.album = pending.album }
            streams = streamStore.setDownload(path: path, forStreamID: pending.streamID)
            return LoadedTrack(track: loaded.track, metadata: metadata,
                               recordMarkers: pending.markers.isEmpty ? nil : pending.markers)
        }
    }

    private func confirmPersonalUse() -> Bool {
        guard !prefs.hasAcknowledgedStreamDownloadNotice else { return true }
        let alert = NSAlert()
        alert.messageText = "Downloads are for personal use"
        alert.informativeText = "Downloading keeps a copy of this stream on your Mac for your own offline listening. You are responsible for having the right to keep it. Do not share or redistribute what you download."
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        prefs.hasAcknowledgedStreamDownloadNotice = true
        return true
    }
}
```

Compile notes: `AudioTrack`'s displayed artist/album come from the scan; if the browser shows `AudioTrack` fields rather than `metadata` for these, also rebuild `loaded.track` with the same defaults (look for a `withArtist`/memberwise path beside `withFileURL` in `AudioTrack`; if none exists, leave the display to the user's TAGS panel and say so in the task report). If `streamFailure`'s setter or `AppLog.library.error` differ in spelling, match the existing uses in `LibraryViewModel+Radio.swift` and `+LibraryLocation.swift`.

- [ ] **Step 4: Hook the import.** In `handleImport`, make the first line after the empty guard:

```swift
        let tracks = applyingPendingStreamImports(to: tracks)
```

(shadowing the parameter), so `stageIntoPrepCrate` receives the enriched tracks.

- [ ] **Step 5: Menu.** In `RadioListView.swift`, between the "Copy Link" button and the `Divider()`:

```swift
                                    if model.downloadingStreamID == stream.id {
                                        Button("Cancel Download") { model.cancelStreamDownload() }
                                    } else if !stream.isDownloaded() {
                                        Button("Download for Offline…") { model.downloadStream(id: stream.id) }
                                            .disabled(!model.canDownload(stream) || model.isDownloadingStream)
                                            .help(stream.kind == .live ? "A live stream has no end to download."
                                                  : stream.kind == .playlist ? "Playlists can't be downloaded yet. Add a single video or mix."
                                                  : "")
                                    }
```

- [ ] **Step 6: Verify in the app.** `swift build`, launch. With a chaptered mix in YT Records: Download for Offline… shows the notice once (Cancel, retry: shown again; Download: never again); the OLED shows progress; Cancel Download stops it and leaves no folder behind; a completed download switches to the Prep Crate with one track that has cover art, artist = channel, album = title, and Record Divider shows the chapters; playing it steps track by track. With the library drive unplugged the action is refused on the OLED. `scripts/test.sh` → all pass.

- [ ] **Step 7: Commit** `feat(radio): download a stream for offline listening, chapters become track markers`.

### Task 11: The Downloads list

**Files:**
- Modify: `Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel+StreamDownload.swift`, `LibraryViewModel+Radio.swift` (`removeStream` :146, `makeEngine`/`resolveActiveEngineKind` :262-288), `LibraryViewModel.swift` (the repoint choke points), `Main/RadioListView.swift` (row + menu + header keys)

**Interfaces:**
- Consumes: Task 8 (`isDownloaded`, `RadioCategory.downloaded`, `repointDownload`, `StreamResolver(ytdlpURL: URL?)`), existing `trashTrackFile`-style removal (`LibraryCleanupService().deleteTracks(_:useTrash:)`, `purgeTracksFromLibraryState(paths:)`), `revealTrack`.
- Produces: `removeDownload(streamID: String)`, `showDownloadInLibrary(streamID: String)`.

- [ ] **Step 1: The sidebar row comes for free.** `streamCategories` filters `RadioCategory.allCases` by `contains`, so Downloads appears with its count as soon as one stream `isDownloaded()` and disappears with the last. Build, run, confirm. If the row shows in the wrong position, order `allCases` by declaring `downloaded` last (it is).

- [ ] **Step 2: Offline playback needs the native engine.** In `LibraryViewModel+Radio.swift`:

```swift
    func resolveActiveEngineKind() -> RadioEngineKind {
        // An offline copy is a local file: only the native engine can play it,
        // whatever the preference says and whether or not yt-dlp is installed.
        if selectedStream?.isDownloaded() == true { return .native }
        ...existing switch unchanged...
    }
```

and in `makeEngine(for:)`'s `.native` case replace the `guard let url = resolvedYtDlpURL() else { return YouTubeEmbedStreamEngine() }` with:

```swift
            let url = resolvedYtDlpURL()
            // No yt-dlp is fine for an offline copy; the resolver never runs it then.
            guard url != nil || selectedStream?.isDownloaded() == true else {
                return YouTubeEmbedStreamEngine()
            }
            let engine = YtDlpStreamEngine(resolver: StreamResolver(ytdlpURL: url))
```

`ensureRadioEngine` reuses an engine only when the kind matches, so moving between a webview stream and a downloaded one rebuilds it. Verify: turn Wi-Fi off, play a downloaded stream from Downloads: it plays, the chapter tracklist seeks.

- [ ] **Step 3: Remove Download and Show in Library.** Append to the `+StreamDownload` extension:

```swift
    /// The downloaded file as the library knows it, wherever it is filed.
    private func downloadedTrack(for stream: StreamSource) -> LoadedTrack? {
        guard let path = stream.downloadedPath else { return nil }
        let match: (LoadedTrack) -> Bool = { $0.track.fileURL.standardizedFileURL.path == path }
        return prepCrateTracks.first(where: match) ?? localIndex.allTracks.first(where: match)
    }

    /// Trash the offline copy; the stream stays and plays online again.
    func removeDownload(streamID: String) {
        guard !refuseWhileLibraryDisconnected() else { return }
        guard let stream = streams.first(where: { $0.id == streamID }), let path = stream.downloadedPath else { return }

        let alert = NSAlert()
        alert.messageText = "Move the offline copy of \u{201C}\(stream.title)\u{201D} to the Trash?"
        alert.informativeText = "The stream stays in your list and plays online."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        // Let go of the file before it moves: the radio engine if it is playing
        // this offline copy, the library player if the track was started from a crate.
        if selectedStreamID == streamID, radioEngine != nil { stopRadio() }
        if let current = nowPlayingTrack, current.track.fileURL.standardizedFileURL.path == path { playback.pause() }

        let fileURL = URL(fileURLWithPath: path)
        do {
            if let track = downloadedTrack(for: stream) {
                try LibraryCleanupService().deleteTracks([track], useTrash: true)
            } else if FileManager.default.fileExists(atPath: path) {
                try FileManager.default.trashItem(at: fileURL, resultingItemURL: nil)
            }
        } catch {
            // Link left intact: the file is still there and still the download.
            appAlert = .error(title: "Trash Failed", message: error.localizedDescription)
            return
        }
        purgeTracksFromLibraryState(paths: [path])

        // The folder was made for this download; take it too when only the cover is left.
        let folder = fileURL.deletingLastPathComponent()
        let rest = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0 != "cover.jpg" && $0 != ".DS_Store" }
        if rest.isEmpty { try? FileManager.default.trashItem(at: folder, resultingItemURL: nil) }

        streams = streamStore.setDownload(path: nil, forStreamID: streamID)
        showOLEDNotice("DOWNLOAD REMOVED")
    }

    func showDownloadInLibrary(streamID: String) {
        guard let stream = streams.first(where: { $0.id == streamID }),
              let track = downloadedTrack(for: stream) else { return }
        let inPrep = prepCrateTracks.contains { $0.track.fileURL == track.track.fileURL }
        selectSource(inPrep ? .prepCrate : .localAll)
        revealTrack(track)
    }
```

`nowPlayingTrack` is at `LibraryViewModel.swift:1727` and `localIndex` at `:1167`. Read `purgeTracksFromLibraryState(paths:)` (`LibraryViewModel.swift:4391`) and confirm it takes standardized paths and drops the `ListeningStore` entry; if it does not drop listening stats, leave that as is (that is what Remove from Library does today) and note it.

- [ ] **Step 4: Follow a moved file.** The single-track choke point is `updateTrackURLInIndex` (`LibraryViewModel.swift:4630`): inside its `if oldKey != newKey` block, after `currentListeningStore().repoint(from: oldKey, to: newKey)`, add `streams = streamStore.repointDownload(from: oldKey, to: newKey)`. Both keys are `url.standardizedFileURL.path`, the same form `downloadedPath` is stored in. Then find the batch paths: `grep -rn "\.repoint\|ListeningStore" Sources/CrateDiggerApp | grep -v "func "` shows where `updateTrackURLsInIndex`, `moveLibrary` and `consolidateLibrary` carry listening stats across a path change; add the same one line beside each, with the old and new keys that code already holds. Inside batch loops (`updateTrackURLsInIndex`, move and consolidate) this re-saves a small JSON blob per moved file that is a download, and returns early for every other file, so it is cheap; do not batch it.

- [ ] **Step 5: Row chip and menu.** In `RadioListView.swift`'s `RadioRow`, where the kind badge or subtext is drawn, add for a downloaded stream an `OFFLINE` chip styled exactly like the existing badge in that row (copy its modifiers), and extend the subtext with the size:

```swift
    private var offlineSize: String? {
        guard stream.isDownloaded(), let path = stream.downloadedPath,
              let bytes = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int64 else { return nil }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
```

Context menu, replacing the `else if !stream.isDownloaded()` branch's absence for downloaded streams: after the Download item add

```swift
                                    if stream.isDownloaded() {
                                        Button("Show in Library") { model.showDownloadInLibrary(streamID: stream.id) }
                                        Button("Remove Download…") { model.removeDownload(streamID: stream.id) }
                                    }
```

and change Remove Stream to confirm when there is a download (in `removeStream(id:)`, before removing):

```swift
        if let stream = streams.first(where: { $0.id == id }), stream.isDownloaded() {
            let alert = NSAlert()
            alert.messageText = "Remove \u{201C}\(stream.title)\u{201D}?"
            alert.informativeText = "Its downloaded file stays in your library as an ordinary track. To delete the file too, use Remove Download first."
            alert.addButton(withTitle: "Remove Stream")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
```

In the header (`RadioListView.swift:64-77`) hide BROWSE and the add-stream key when `model.radioCategoryFilter == .downloaded`.

- [ ] **Step 6: Verify in the app.** Download a mix: Downloads row appears with count 1; the row shows OFFLINE and a size in all three lists. Show in Library lands on the track in the Prep Crate. File it into a crate, rename it via TAGS so the file moves: the stream is still OFFLINE (repoint worked). Remove Download… while it plays: playback stops, file and folder are in the Trash, the track is gone from the crate, the stream is still in YT Records and plays online, the Downloads row is gone. Delete another download's file in Finder: it silently stops being OFFLINE. `scripts/test.sh` → all pass.

- [ ] **Step 7: Commit** `feat(radio): Downloads list, offline playback, Remove Download keeps the stream`.

---

### Task 12: Docs and release notes

**Files:**
- Modify: `CLAUDE.md`, `CHANGELOG.md`, the What's New source for 2.2.0 (`grep -rn "full-screen player" Sources docs website | head` finds where commit `8652b5f` added the last entries)

- [ ] **Step 1: `CLAUDE.md`.** Radio section: add a paragraph "Downloads" covering `StreamDownloader`, `StreamingCommandRunning` (why it exists beside `CommandRunning`), `StreamSource.downloadedPath` + `isDownloaded` (path and file), `RadioCategory.downloaded` being a filter `of(_:)` never returns, `pendingStreamImports` consumed in `handleImport`, the resolver's offline branch forcing the native engine, and the rule "anything that moves a track's path calls `streamStore.repointDownload` beside `ListeningStore.repoint`". Browser section: `BrowserEmptyKind`. Playback: `VolumeCurve.readout/percent/stepped` and the readout firing from `playbackVolume`'s `didSet`. Remove the stale `ExternalDeviceTransferSheetController` example from "AppKit ↔ SwiftUI bridge" after confirming with `grep -rn ExternalDeviceTransferSheetController Sources` that the type is gone. Add `+StreamDownload` to the extension list and bump its count.
- [ ] **Step 2: What's New (2.2.0)** gains three lines, no dashes: "The display shows the volume as you change it, in dB or percent (Settings, Playback).", "An empty Prep Crate now tells you what it is for and what to do next.", "Download a YouTube mix or video for offline listening. Chapters become tracks, and a Downloads list under Radio shows what you have saved."
- [ ] **Step 3: `CHANGELOG.md`** under the unreleased 2.2.0 beta 3 heading: the three features plus the fixes (fader no longer snaps back from full; Volume Up/Down stop on 0 dB; boost above 0 dB, worded from Task 3's finding; footer symmetry; empty crates no longer say "No library loaded").
- [ ] **Step 4:** `grep -nP "[\x{2013}\x{2014}]"` over the What's New and changelog lines you added → no matches. `scripts/test.sh` → all pass.
- [ ] **Step 5: Commit** `docs: beta 3 notes, CLAUDE.md for stream downloads, volume readout and empty states`.

Cutting the beta itself (version bump to build 93, merge `main`, DMG, feed) is the `press-the-record` skill's job and is not part of this plan.
