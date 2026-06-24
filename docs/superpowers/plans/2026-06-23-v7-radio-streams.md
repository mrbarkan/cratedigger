# CrateDigger v7 — Radio / Streams Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a "Radio / Streams" source that plays YouTube channels/playlists/live/videos, implementing the v7 UI and two user-selectable playback engines (WebView embed + bring-your-own yt-dlp → AVPlayer), and disabling the Inspector Disc tab.

**Architecture:** A new `LibrarySource.radio(channel:)` mode renders an engine-agnostic UI (sidebar section, radio list, OLED radio mode, inspector radio-info, Add-Stream sheet). Stream metadata lives in Core (`StreamSource`/`StreamURLParser`/`StreamStore`). A `RadioPlaybackEngine` protocol abstracts two backends — `YouTubeEmbedStreamEngine` (hidden `WKWebView`, default) and `YtDlpStreamEngine` (resolves a playable URL via `StreamResolver`/yt-dlp, then reuses the existing `PlaybackService`/AVPlayer).

**Tech Stack:** Swift / SwiftUI / AppKit, Swift Package Manager, two targets (`CrateDiggerCore` pure library + `CrateDiggerApp`). XCTest via `scripts/test.sh`. AVFoundation, WebKit.

## Global Constraints

- Two-target boundary: testable logic in `CrateDiggerCore` (no AppKit views); UI glue in `CrateDiggerApp`. (CLAUDE.md)
- Run tests with `scripts/test.sh` (forces `--enable-xctest --disable-swift-testing`), not bare `swift test`. Filter: `scripts/test.sh --filter StreamURLParserTests`.
- Build with `swift build`; debug binary at `.build/arm64-apple-macosx/debug/CrateDiggerApp`.
- New Core types: `public`, `Sendable`, `Codable` where they cross the boundary.
- yt-dlp is **bring-your-own** — do NOT add it to `scripts/package-app.sh`.
- AVPlayer cannot decode WebM/Opus → native resolver must select HLS (`.m3u8`) or m4a/AAC.
- `LibraryViewModel` is `@MainActor`; long work (yt-dlp subprocess) runs off-main in a `Task` and hops back via `@MainActor`.
- Preserve the skeuomorphic "Carbon" look; UI changes are verified visually by the user in the running app.
- Many user-facing messages use `appAlert = .error(title:…)` even for info — match that convention.

---

## File Structure

**Create (Core):**
- `Sources/CrateDiggerCore/Models/StreamSource.swift` — `StreamSource`, `StreamKind`, `StreamProvider`.
- `Sources/CrateDiggerCore/Services/StreamURLParser.swift` — pure URL classifier (`ParsedStream`).
- `Sources/CrateDiggerCore/Services/StreamStore.swift` — persist `[StreamSource]` via `PreferencesStore`.
- `Sources/CrateDiggerCore/Services/StreamResolver.swift` — yt-dlp arg builder + stdout parser (`ResolvedStream`).

**Create (App):**
- `Sources/CrateDiggerApp/UI/Carbon/Main/RadioListView.swift` — stream-row browser.
- `Sources/CrateDiggerApp/UI/Carbon/Inspector/RadioInfoView.swift` — inspector radio-info panel.
- `Sources/CrateDiggerApp/Playback/RadioPlaybackEngine.swift` — protocol + shared types.
- `Sources/CrateDiggerApp/Playback/YouTubeEmbedStreamEngine.swift` — WKWebView IFrame engine.
- `Sources/CrateDiggerApp/Playback/YtDlpStreamEngine.swift` — native engine.
- `Sources/CrateDiggerApp/UI/Carbon/Sheets/AddStreamSourceSheetController.swift` — AppKit sheet.
- `Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel+Radio.swift` — radio state/behavior extension.

**Create (Tests):**
- `Tests/CrateDiggerCoreTests/StreamURLParserTests.swift`
- `Tests/CrateDiggerCoreTests/StreamStoreTests.swift`
- `Tests/CrateDiggerCoreTests/StreamResolverTests.swift`

**Modify:**
- `Sources/CrateDiggerCore/Services/PreferencesStore.swift` — keys + accessors (`streamSourcesData`, `streamEngine`, `customYtDlpPath`).
- `Sources/CrateDiggerCore/Services/ExternalToolLocator.swift` — add `case ytdlp`.
- `Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel.swift` — `LibrarySource.radio`, radio @Published state, engine wiring, scrobble guard.
- `Sources/CrateDiggerApp/UI/Carbon/Main/SourcesSidebar.swift` — Radio/Streams section.
- `Sources/CrateDiggerApp/UI/Carbon/Main/MainShell.swift` — render `RadioListView` in radio mode.
- `Sources/CrateDiggerApp/UI/Carbon/Header/OLEDDisplay.swift` — radio NowPlaying variant.
- `Sources/CrateDiggerApp/UI/Carbon/Inspector/InspectorPane.swift` — radio-info + remove Disc tab.
- `Sources/CrateDiggerApp/AppDelegate.swift` (or menu file) — Stream Engine menu (Phase 4).

---

# PHASE 1 — Core model, persistence, URL parser (fully TDD)

### Task 1: `StreamSource` model

**Files:**
- Create: `Sources/CrateDiggerCore/Models/StreamSource.swift`
- Test: `Tests/CrateDiggerCoreTests/StreamStoreTests.swift` (codable test added here, store tests in Task 3)

**Interfaces — Produces:**
```swift
public enum StreamKind: String, Codable, Sendable, CaseIterable { case live, video, mix, playlist }
public enum StreamProvider: String, Codable, Sendable { case youtube }
public struct StreamSource: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var url: String
    public var title: String
    public var channel: String
    public var kind: StreamKind
    public var hue: Int
    public var provider: StreamProvider
    public var addedAt: Date
    public var viewers: String?
    public var durationSeconds: Double?
    public init(id: String, url: String, title: String, channel: String, kind: StreamKind,
                hue: Int, provider: StreamProvider = .youtube, addedAt: Date,
                viewers: String? = nil, durationSeconds: Double? = nil)
    public var isLive: Bool { kind == .live }
}
```

- [ ] **Step 1: Write the failing test** in `Tests/CrateDiggerCoreTests/StreamStoreTests.swift`

```swift
import XCTest
@testable import CrateDiggerCore

final class StreamSourceCodableTests: XCTestCase {
    func testRoundTripPreservesAllFields() throws {
        let s = StreamSource(id: "s1", url: "https://youtube.com/@safeplace", title: "24/7 lofi",
                             channel: "safe place", kind: .live, hue: 18,
                             addedAt: Date(timeIntervalSince1970: 1_700_000_000),
                             viewers: "1.4K", durationSeconds: nil)
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(StreamSource.self, from: data)
        XCTAssertEqual(back, s)
        XCTAssertTrue(back.isLive)
    }
}
```

- [ ] **Step 2: Run to verify it fails** — `scripts/test.sh --filter StreamSourceCodableTests` → FAIL (StreamSource undefined).
- [ ] **Step 3: Create `StreamSource.swift`** with the Produces interface above.
- [ ] **Step 4: Run to verify it passes** — `scripts/test.sh --filter StreamSourceCodableTests` → PASS.
- [ ] **Step 5: Commit** — `git add Sources/CrateDiggerCore/Models/StreamSource.swift Tests/CrateDiggerCoreTests/StreamStoreTests.swift && git commit -m "feat(core): add StreamSource model"`

---

### Task 2: `StreamURLParser`

**Files:**
- Create: `Sources/CrateDiggerCore/Services/StreamURLParser.swift`
- Test: `Tests/CrateDiggerCoreTests/StreamURLParserTests.swift`

**Interfaces — Produces:**
```swift
public struct ParsedStream: Equatable, Sendable {
    public var isValidHost: Bool   // true only for youtube.com / youtu.be
    public var kind: StreamKind
    public var suggestedTitle: String
    public var channel: String
    public var host: String
}
public enum StreamURLParser {
    /// Returns nil when the string can't be interpreted as a URL at all.
    public static func parse(_ raw: String) -> ParsedStream?
}
```

Port of v7 `parseYT` (CrateDigger_v7.html:2512). Rules, evaluated in order:
1. Trim; prepend `https://` if no scheme; `URL` parse fails → return `nil`.
2. host = hostname minus leading `www.`. `isValidHost = host matches /(youtube\.com|youtu\.be)$/`.
   If not valid AND host has no dot → return `nil` (garbage). Otherwise continue (so a typo'd
   host still classifies but `isValidHost=false`).
3. `?list=` present OR path contains `playlist` → `.playlist`, title "YouTube Playlist", channel "Playlist".
4. else path `/channel/<id>` → `.live`, channel = id (truncated to 14 chars + "…" if >16), title "YouTube Channel".
5. else path contains `/@<handle>` → `.live`, channel = "@handle", title = handle with `-`/`_`→space.
6. else path `/c/<name>` or `/user/<name>` → `.live`, channel = last path component, title = same.
7. else path contains `/live` → `.live`, title "Live Stream", channel "YouTube".
8. else `?v=` present OR host == "youtu.be" → `.video`, title "YouTube Video", channel "YouTube".
9. else default → `.video`, title "YouTube Video", channel "YouTube".

- [ ] **Step 1: Write failing tests** in `StreamURLParserTests.swift`

```swift
import XCTest
@testable import CrateDiggerCore

final class StreamURLParserTests: XCTestCase {
    func testHandleChannelIsLive() {
        let p = StreamURLParser.parse("https://youtube.com/@safeplace")!
        XCTAssertTrue(p.isValidHost); XCTAssertEqual(p.kind, .live); XCTAssertEqual(p.channel, "@safeplace")
    }
    func testPlaylist() {
        let p = StreamURLParser.parse("https://www.youtube.com/playlist?list=PL123")!
        XCTAssertEqual(p.kind, .playlist); XCTAssertEqual(p.channel, "Playlist")
    }
    func testChannelIdTruncated() {
        let p = StreamURLParser.parse("youtube.com/channel/UCabcdefghijklmnopqrstuv")!
        XCTAssertEqual(p.kind, .live); XCTAssertTrue(p.channel.hasSuffix("…"))
    }
    func testCUserPath() {
        XCTAssertEqual(StreamURLParser.parse("https://youtube.com/c/NightDrive")!.kind, .live)
        XCTAssertEqual(StreamURLParser.parse("https://youtube.com/user/NightDrive")!.channel, "NightDrive")
    }
    func testWatchVideo() {
        let p = StreamURLParser.parse("https://youtube.com/watch?v=abc123")!
        XCTAssertEqual(p.kind, .video)
    }
    func testYoutuBeShortVideo() {
        let p = StreamURLParser.parse("https://youtu.be/abc123")!
        XCTAssertEqual(p.kind, .video); XCTAssertTrue(p.isValidHost)
    }
    func testLivePath() {
        XCTAssertEqual(StreamURLParser.parse("https://youtube.com/@x/live")!.kind, .live)
    }
    func testMissingSchemeStillParses() {
        XCTAssertNotNil(StreamURLParser.parse("youtube.com/@x"))
    }
    func testNonYouTubeHostFlaggedInvalidButClassifies() {
        let p = StreamURLParser.parse("https://vimeo.com/watch?v=1")!
        XCTAssertFalse(p.isValidHost)
    }
    func testGarbageReturnsNil() {
        XCTAssertNil(StreamURLParser.parse("not a url at all"))
    }
}
```

- [ ] **Step 2: Run to verify fail** — `scripts/test.sh --filter StreamURLParserTests` → FAIL.
- [ ] **Step 3: Implement `StreamURLParser`** per the ordered rules.
- [ ] **Step 4: Run to verify pass** — `scripts/test.sh --filter StreamURLParserTests` → PASS (10 tests).
- [ ] **Step 5: Commit** — `git add Sources/CrateDiggerCore/Services/StreamURLParser.swift Tests/CrateDiggerCoreTests/StreamURLParserTests.swift && git commit -m "feat(core): add StreamURLParser"`

---

### Task 3: `PreferencesStore` keys + `StreamStore`

**Files:**
- Modify: `Sources/CrateDiggerCore/Services/PreferencesStore.swift` (add keys after line 47; accessors before Reset section)
- Create: `Sources/CrateDiggerCore/Services/StreamStore.swift`
- Test: `Tests/CrateDiggerCoreTests/StreamStoreTests.swift` (extend)

**Interfaces — Consumes:** `StreamSource` (Task 1), `PreferencesStore`.
**Produces:**
```swift
// PreferencesStore additions:
public var streamSourcesData: Data?            // raw JSON of [StreamSource]
public var streamEngine: String                // "auto" | "native" | "webview"  (default "auto")
public var customYtDlpPath: String?            // nil/empty clears

public final class StreamStore {
    public init(prefs: PreferencesStore = .shared)
    public func all() -> [StreamSource]
    public func save(_ streams: [StreamSource])
    @discardableResult public func add(_ stream: StreamSource) -> [StreamSource]  // prepend
    @discardableResult public func remove(id: String) -> [StreamSource]
    public func channels() -> [String]   // distinct channel values, stable insertion order
    public func liveChannels() -> Set<String>
}
```

`PreferencesStore.streamEngine` getter returns `defaults.string(forKey:) ?? "auto"`.
`StreamStore` (de)serializes with `JSONEncoder`/`JSONDecoder`; tolerates corrupt data by returning `[]`.

- [ ] **Step 1: Write failing tests** (append to `StreamStoreTests.swift`)

```swift
final class StreamStoreTests: XCTestCase {
    private func freshStore() -> StreamStore {
        let d = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        return StreamStore(prefs: PreferencesStore(defaults: d))
    }
    private func make(_ id: String, _ chan: String, live: Bool = false) -> StreamSource {
        StreamSource(id: id, url: "https://youtube.com/@\(chan)", title: id, channel: chan,
                     kind: live ? .live : .video, hue: 1, addedAt: Date())
    }
    func testAddPrependsAndPersists() {
        let s = freshStore()
        s.add(make("a", "safe place"))
        s.add(make("b", "night drive fm", live: true))
        XCTAssertEqual(s.all().map(\.id), ["b", "a"])
    }
    func testRemove() {
        let s = freshStore(); s.add(make("a", "x")); s.add(make("b", "y"))
        s.remove(id: "a")
        XCTAssertEqual(s.all().map(\.id), ["b"])
    }
    func testChannelsDistinctInOrder() {
        let s = freshStore()
        s.save([make("a", "x"), make("b", "y"), make("c", "x")])
        XCTAssertEqual(s.channels(), ["x", "y"])
    }
    func testLiveChannels() {
        let s = freshStore()
        s.save([make("a", "x", live: true), make("b", "y")])
        XCTAssertEqual(s.liveChannels(), ["x"])
    }
    func testCorruptDataYieldsEmpty() {
        let d = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        let prefs = PreferencesStore(defaults: d)
        prefs.streamSourcesData = Data([0x00, 0x01])
        XCTAssertEqual(StreamStore(prefs: prefs).all(), [])
    }
}
```

- [ ] **Step 2: Run to verify fail** — `scripts/test.sh --filter StreamStoreTests` → FAIL.
- [ ] **Step 3: Add PreferencesStore keys/accessors and create `StreamStore.swift`.**
  Keys to add in the `Key` enum: `streamSources = "cratedigger.radio.streamSources"`,
  `streamEngine = "cratedigger.radio.engine"`, `customYtDlpPath = "cratedigger.tools.ytdlpPath"`.
- [ ] **Step 4: Run to verify pass** — `scripts/test.sh --filter StreamStoreTests` → PASS.
- [ ] **Step 5: Commit** — `git add -A && git commit -m "feat(core): add StreamStore + prefs keys"`

**Phase 1 gate:** `scripts/test.sh` (full suite) green; `swift build` green.

---

# PHASE 2 — Engine-agnostic UI (build-verify; UI untested per conventions)

> Each task ends with `swift build` green and is visually verified by the user in the running
> app at the phase gate. Read each target file before editing.

### Task 4: `LibrarySource.radio` + radio state on `LibraryViewModel`

**Files:**
- Modify: `Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel.swift` (enum at :51; add state near :215)
- Create: `Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel+Radio.swift`

**Interfaces — Consumes:** `StreamSource`, `StreamStore`, `StreamURLParser`.
**Produces (on `LibraryViewModel`):**
```swift
// enum case added:
case radio(channel: String?)            // nil == All Streams

// new @Published / state:
@Published var streams: [StreamSource]                 // all, from StreamStore
@Published var radioChannelFilter: String?             // nil == all
@Published var selectedStreamID: String?
@Published var radioEngineLabel: String                // "AUTO"/"NATIVE"/"WEB" for OLED/menu
var filteredStreams: [StreamSource] { … }              // streams filtered by radioChannelFilter
var selectedStream: StreamSource? { … }
var isRadioMode: Bool { if case .radio = currentSource { true } else { false } }

// behaviour (in +Radio.swift):
func enterRadio(channel: String?)        // sets currentSource=.radio, filter, selects first/persisted
func selectStream(id: String)            // updates selection, drives OLED/inspector, calls play (Phase 3)
func addStream(fromURL raw: String)      // StreamURLParser → StreamSource → StreamStore.add → enterRadio + select
func removeStream(id: String)
```

- [ ] **Step 1:** Add `case radio(channel: String?)` to `LibrarySource` (`Hashable` synthesises).
- [ ] **Step 2:** Add the `@Published` state + computed helpers; init `streams` from `StreamStore().all()`.
- [ ] **Step 3:** In `selectSource(_:)` (:529) handle `.radio`: set published `index = .empty` (browser
  uses `RadioListView`, not `index`) and set `radioChannelFilter` from the case payload.
- [ ] **Step 4:** Implement `LibraryViewModel+Radio.swift` behaviours. `addStream` maps `ParsedStream`
  → `StreamSource` (random hue 0–359 via `Int.random(in:0...359)`, `id = "u" + UUID().uuidString`,
  `addedAt = Date()`, `viewers = isLive ? "0" : nil`). `selectStream` updates `selectedStreamID`
  and calls `playSelectedStream()` (stubbed in Phase 2 to no-op; implemented Phase 3).
- [ ] **Step 5:** `swift build` → green.
- [ ] **Step 6: Commit** — `git add -A && git commit -m "feat(app): LibrarySource.radio + radio view-model state"`

---

### Task 5: Sources sidebar "Radio / Streams" section

**Files:** Modify `Sources/CrateDiggerApp/UI/Carbon/Main/SourcesSidebar.swift` (add section after Remote, before Playlists, ~line 122). Reuse existing `sectionHeader` (:291) and `sidebarItem()` (:305) helpers.

- [ ] **Step 1:** Add a "Radio / Streams" `sectionHeader` with a trailing `+` button calling
  `presentAddStream()` (Task 9 wires the sheet; in this task the `+` calls a `model` method that
  for now opens nothing — wire in Task 9). Use the `plus` affordance pattern from "Local Library" (:39).
- [ ] **Step 2:** Row "All Streams" → `model.enterRadio(channel: nil)`, selected when
  `model.currentSource == .radio(channel: nil)`, count = `model.streams.count`. Icon: radio SVG
  (reuse a Carbon icon or the existing `Image(systemName: "dot.radiowaves.left.and.right")`).
- [ ] **Step 3:** `ForEach(model.streamChannels)` rows (add `var streamChannels: [String]` =
  distinct channels) → `model.enterRadio(channel: name)`; show `LIVE` badge when channel ∈
  `model.liveStreamChannels`. Selected check matches `.radio(channel: name)`.
- [ ] **Step 4:** `swift build` → green. Verify the section appears.
- [ ] **Step 5: Commit** — `git add -A && git commit -m "feat(app): Radio/Streams sidebar section"`

---

### Task 6: `RadioListView` + MainShell wiring

**Files:**
- Create: `Sources/CrateDiggerApp/UI/Carbon/Main/RadioListView.swift`
- Modify: `Sources/CrateDiggerApp/UI/Carbon/Main/MainShell.swift` (browser switch ~:75)

`RadioListView` mirrors `.radio-list` (v7 html:1607). Each row (`.rrow`): left thumb (rounded
rect filled with the stream's hue via `Color(hue: Double(s.hue)/360, saturation: 0.55,
brightness: 0.6)`) with a play triangle overlay + a duration/`LIVE` badge; middle = title (1 line)
+ a type badge (`s.kind` uppercased) + channel; right = "YouTube" + (live ? "● N watching" :
addedAt/kind). Selected row (`model.selectedStreamID == s.id`) highlighted + playing dot. Tap →
`model.selectStream(id:)`. Header: channel name (or "All Streams") + "N SOURCES" + an "ADD URL"
button → `presentAddStream()`.

- [ ] **Step 1:** Create `RadioListView` bound to `@EnvironmentObject model`, iterating
  `model.filteredStreams`.
- [ ] **Step 2:** In `MainShell`, where it currently switches `showArtworkGallery ?
  ArtworkGalleryView() : BrowserPane()` (:75), add a leading branch:
  `if model.isRadioMode { RadioListView() } else if model.showArtworkGallery { … } else { … }`.
  Update the browser title to `"Browser · Radio"` when `isRadioMode`.
- [ ] **Step 3:** `swift build` → green; verify list renders when a radio source is selected.
- [ ] **Step 4: Commit** — `git add -A && git commit -m "feat(app): RadioListView + MainShell radio branch"`

---

### Task 7: OLED radio NowPlaying variant

**Files:** Modify `Sources/CrateDiggerApp/UI/Carbon/Header/OLEDDisplay.swift` (`NowPlayingView` :67).

Mirror v7 `.np-radio` (html:1390) and live state (html:1031). When `model.isRadioMode` and a stream
is selected:
- Replace the file spec cells (Track/Format/Bitrate/Sample/Size) with stream cells:
  Source ("YouTube"), Codec, Bitrate, Buffer, Tuned-In (`s.viewers` or kind). Under the WebView
  engine show honest values — Codec/Bitrate/Buffer render as "—" / "Embedded" (see `model.radioEngineKind`).
- Headline: title = `s.title`, sub = `"<channel> · YouTube Live Stream"` (live) or
  `"<channel> · <kind>"`. Tag = "ON AIR" (live) / "STREAMING" (vod).
- Live → hide elapsed/total clock; show "ON AIR" + "UPTIME" (drive uptime from a 1s timer on the
  view model when live + playing). VOD keeps the clock.

- [ ] **Step 1:** Add a `radioCells`/`radioHeadline` branch in `NowPlayingView.body` gated on
  `model.isRadioMode && model.selectedStream != nil`.
- [ ] **Step 2:** Add `@Published var radioUptimeSeconds: Int` + a timer in the view model that
  increments while live+playing+radio; format `HH:MM:SS`.
- [ ] **Step 3:** `swift build` → green; verify OLED shows stream info in radio mode.
- [ ] **Step 4: Commit** — `git add -A && git commit -m "feat(app): OLED radio now-playing variant"`

---

### Task 8: Inspector radio-info + disable Disc tab

**Files:**
- Create: `Sources/CrateDiggerApp/UI/Carbon/Inspector/RadioInfoView.swift`
- Modify: `Sources/CrateDiggerApp/UI/Carbon/Inspector/InspectorPane.swift` (tab enum :12; tab loop :48; info panes :91 & :128; remove disc branches :108 & :153)

`RadioInfoView` mirrors `.insp-radio-info` (html:1636): thumb (hue), name, channel, specs
(Source, Type, Codec, Bitrate, Sample, Latency, Added), chips (`LIVE`/kind, `NO DRM`). Reuse the
existing `SpecRows`/`TagChips`/spec styling so it matches the album INFO pane.

- [ ] **Step 1:** Remove `case disc` from `InspectorTab` (:15) and delete the `.disc` branches in
  both `narrowLayout` (:108–115) and `wideLayout` (:153–161). Tab loop at :48 now yields INFO/ART only.
- [ ] **Step 2:** In the `.info` pane, when `model.isRadioMode && model.selectedStream != nil`,
  render `RadioInfoView(stream:)` instead of the album caption/specs/tools block.
- [ ] **Step 3:** Update inspector title/count: `"Inspector"` / `"STREAM"` in radio mode.
- [ ] **Step 4:** `swift build` → green; verify Disc tab is gone and radio-info shows for streams.
- [ ] **Step 5: Commit** — `git add -A && git commit -m "feat(app): inspector radio-info; disable Disc tab"`

---

### Task 9: Add-Stream AppKit sheet

**Files:**
- Create: `Sources/CrateDiggerApp/UI/Carbon/Sheets/AddStreamSourceSheetController.swift`
- Modify: `SourcesSidebar.swift` (`+`), `RadioListView.swift` ("ADD URL"), `LibraryViewModel+Radio.swift` (`presentAddStream`).

Mirror v7 modal (html:1908): title "ADD STREAM SOURCE", a URL `NSTextField`
(placeholder `https://youtube.com/@channel · /playlist?list=… · /watch?v=…`), a live detect row
showing `StreamURLParser.parse(...)` result (name + kind badge + host; "valid" styling only when
`isValidHost`), CANCEL + ADD SOURCE (disabled until a non-nil parse). `onDecision: (String?) -> Void`
returns the URL or nil. Follow the existing sheet pattern (e.g. `ConversionOptionsSheetController`,
presented via `presentAsSheet` from `MainWindowController`).

- [ ] **Step 1:** Create the controller with the input, live detection (reuse `StreamURLParser`),
  and `onDecision` closure.
- [ ] **Step 2:** Add `presentAddStream()` to the view model (or `MainWindowController` per the
  sheet-presentation pattern) that presents the sheet and on a non-nil result calls
  `model.addStream(fromURL:)`.
- [ ] **Step 3:** Wire the sidebar `+` (Task 5) and the radio-list "ADD URL" (Task 6) to it.
- [ ] **Step 4:** `swift build` → green; verify the sheet adds a source and enters radio mode.
- [ ] **Step 5: Commit** — `git add -A && git commit -m "feat(app): Add-Stream sheet"`

**Phase 2 gate:** `swift build` green; **user verifies** sidebar/list/OLED/inspector/sheet visually
(selection + add work; playback is a no-op stub until Phase 3).

---

# PHASE 3 — WebView engine (default; streams actually play)

### Task 10: `RadioPlaybackEngine` protocol + `YouTubeEmbedStreamEngine`

**Files:**
- Create: `Sources/CrateDiggerApp/Playback/RadioPlaybackEngine.swift`
- Create: `Sources/CrateDiggerApp/Playback/YouTubeEmbedStreamEngine.swift`

**Interfaces — Produces:**
```swift
enum RadioEngineState: Equatable { case idle, loading, playing, paused, failed(String) }
protocol RadioPlaybackEngine: AnyObject {
    var onStateChange: ((RadioEngineState) -> Void)? { get set }
    var onTimeChange: ((Double, Double) -> Void)? { get set }   // current, duration (0 for live)
    func play(_ stream: StreamSource)
    func pause(); func resume(); func stop()
    func setVolume(_ v: Double)         // 0...1
    func seek(toSeconds s: Double)      // ignored for live
}
final class YouTubeEmbedStreamEngine: RadioPlaybackEngine { init() }  // owns a hidden WKWebView
```

`YouTubeEmbedStreamEngine` loads an inline HTML document hosting the YouTube IFrame Player API,
extracting the video/playlist/channel id from `stream.url`. Configure
`WKWebViewConfiguration.mediaTypesRequiringUserActionForPlayback = []` for autoplay. Bridge
play/pause/volume/seek via `evaluateJavaScript`; receive state via a `WKScriptMessageHandler`
("onStateChange"). The webview is added off-screen to the window's content view (size 1×1, hidden)
so media is allowed to play.

- [ ] **Step 1:** Create the protocol + `RadioEngineState`.
- [ ] **Step 2:** Implement `YouTubeEmbedStreamEngine` (id extraction, IFrame HTML, JS bridge,
  message handler → `onStateChange`). For a playlist URL use `playerVars: { listType:'playlist',
  list:<id> }`; for `@handle`/channel, resolve to the channel's live/uploads via the IFrame
  `list` = channel uploads is not directly supported → fall back to opening the channel's
  `live` watch id when present, else load the channel page id as a video; document this limitation.
- [ ] **Step 3:** `swift build` → green.
- [ ] **Step 4: Commit** — `git add -A && git commit -m "feat(app): RadioPlaybackEngine + WebView engine"`

---

### Task 11: Wire engine into the view model + transport routing

**Files:** Modify `LibraryViewModel.swift` / `LibraryViewModel+Radio.swift`; footer transport (`FooterTransport`/`DomeButton`) and Space-key handler in `AppDelegate`.

- [ ] **Step 1:** Add `private var radioEngine: RadioPlaybackEngine?` + `var radioEngineKind:
  RadioEngineKind` (`.webview`/`.native`). Phase 3 always uses `YouTubeEmbedStreamEngine`.
  Implement `playSelectedStream()` to stop the file `playback`, create/reuse the engine, call
  `play(stream)`, and mirror `RadioEngineState` → `playbackState`/OLED.
- [ ] **Step 2:** Route transport: when `isRadioMode && selectedStream != nil`, `togglePlayPause`/
  `setVolume`/`seek` go to `radioEngine`; otherwise to `playback` (existing). Guard
  `checkScrobbleProgress` with `!isRadioMode` (no scrobbling for streams).
- [ ] **Step 3:** Exiting radio (selecting a non-radio source) calls `radioEngine?.stop()`.
- [ ] **Step 4:** `swift build` → green; **user verifies** a YouTube stream actually plays/pauses
  and the OLED reflects state.
- [ ] **Step 5: Commit** — `git add -A && git commit -m "feat(app): play streams via WebView engine + transport routing"`

**Phase 3 gate:** streams play through the WebView engine; transport + OLED work; user-verified.

---

# PHASE 4 — Native engine (bring-your-own yt-dlp)

### Task 12: `ExternalToolLocator.ytdlp`

**Files:** Modify `Sources/CrateDiggerCore/Services/ExternalToolLocator.swift`; Test:
`Tests/CrateDiggerCoreTests/StreamResolverTests.swift` (add a locator test).

- [ ] **Step 1: Failing test**

```swift
func testYtDlpEnvOverrideResolves() {
    let fm = FileManager.default
    // create a temp executable
    let dir = NSTemporaryDirectory() + UUID().uuidString
    try! fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let exe = dir + "/yt-dlp"; fm.createFile(atPath: exe, contents: Data())
    try! fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe)
    let locator = ExternalToolLocator(environment: ["CRATEDIGGER_YTDLP_PATH": exe], bundle: .main,
                                      defaultSystemSearchDirectories: [])
    XCTAssertEqual(locator.resolveOptional(.ytdlp)?.url.path, exe)
}
```

- [ ] **Step 2:** Run → FAIL (`.ytdlp` undefined).
- [ ] **Step 3:** Add `case ytdlp` to `ExternalTool`; `executableName` for ytdlp returns `"yt-dlp"`
  (rawValue `ytdlp` ≠ binary name, so override `executableName`); env key `CRATEDIGGER_YTDLP_PATH`.
- [ ] **Step 4:** Run → PASS.
- [ ] **Step 5: Commit** — `git add -A && git commit -m "feat(core): ExternalTool.ytdlp"`

---

### Task 13: `StreamResolver`

**Files:** Create `Sources/CrateDiggerCore/Services/StreamResolver.swift`; extend `StreamResolverTests.swift`.

**Interfaces — Consumes:** `CommandRunning`, `CommandOutput`, `StreamSource`.
**Produces:**
```swift
public struct ResolvedStream: Sendable, Equatable {
    public let playbackURL: URL
    public let isLive: Bool
    public let durationSeconds: Double?
}
public enum StreamResolverError: Error, Equatable { case emptyOutput, commandFailed(Int32, String) }
public struct StreamResolver {
    public init(ytdlpURL: URL, runner: CommandRunning = ProcessCommandRunner())
    public func arguments(for stream: StreamSource) -> [String]   // pure; unit-tested
    public func resolve(_ stream: StreamSource) throws -> ResolvedStream
}
```

`arguments(for:)`:
- live: `["-g", "-f", "bestaudio/best", "--no-playlist", stream.url]`
- vod (video/mix): `["-g", "-f", "ba[ext=m4a]/bestaudio[acodec^=mp4a]/best", "--no-playlist", stream.url]`
- playlist: `["-g", "-f", "ba[ext=m4a]/bestaudio[acodec^=mp4a]/best", "--yes-playlist", "--playlist-items", "1", stream.url]`

`resolve`: run; if `terminationStatus != 0` → `.commandFailed`; take the first non-empty stdout
line as the URL; empty → `.emptyOutput`; `isLive = stream.isLive`; `durationSeconds = nil` (Phase 4
keeps duration unknown; AVPlayer reports it once loaded).

- [ ] **Step 1: Failing tests**

```swift
final class StreamResolverTests: XCTestCase {
    final class FakeRunner: CommandRunning {
        var output: CommandOutput
        private(set) var lastArgs: [String] = []
        init(_ o: CommandOutput) { output = o }
        func run(executableURL: URL, arguments: [String]) throws -> CommandOutput { lastArgs = arguments; return output }
    }
    private func stream(_ kind: StreamKind) -> StreamSource {
        StreamSource(id: "1", url: "https://youtu.be/x", title: "t", channel: "c", kind: kind, hue: 1, addedAt: Date())
    }
    func testLiveArgsSelectBestAudio() {
        let r = StreamResolver(ytdlpURL: URL(fileURLWithPath: "/bin/yt-dlp"), runner: FakeRunner(.init(terminationStatus: 0, standardOutput: "", standardError: "")))
        XCTAssertEqual(r.arguments(for: stream(.live)), ["-g", "-f", "bestaudio/best", "--no-playlist", "https://youtu.be/x"])
    }
    func testVodArgsPreferM4A() {
        let r = StreamResolver(ytdlpURL: URL(fileURLWithPath: "/bin/yt-dlp"), runner: FakeRunner(.init(terminationStatus: 0, standardOutput: "", standardError: "")))
        XCTAssertTrue(r.arguments(for: stream(.video)).contains("ba[ext=m4a]/bestaudio[acodec^=mp4a]/best"))
    }
    func testResolveReturnsFirstURL() throws {
        let runner = FakeRunner(.init(terminationStatus: 0, standardOutput: "https://cdn/audio.m4a\n", standardError: ""))
        let r = StreamResolver(ytdlpURL: URL(fileURLWithPath: "/bin/yt-dlp"), runner: runner)
        XCTAssertEqual(try r.resolve(stream(.video)).playbackURL, URL(string: "https://cdn/audio.m4a"))
    }
    func testResolveEmptyThrows() {
        let runner = FakeRunner(.init(terminationStatus: 0, standardOutput: "  \n", standardError: ""))
        let r = StreamResolver(ytdlpURL: URL(fileURLWithPath: "/bin/yt-dlp"), runner: runner)
        XCTAssertThrowsError(try r.resolve(stream(.video)))
    }
    func testResolveNonZeroThrows() {
        let runner = FakeRunner(.init(terminationStatus: 1, standardOutput: "", standardError: "ERROR: unavailable"))
        let r = StreamResolver(ytdlpURL: URL(fileURLWithPath: "/bin/yt-dlp"), runner: runner)
        XCTAssertThrowsError(try r.resolve(stream(.video)))
    }
}
```

- [ ] **Step 2:** Run → FAIL.
- [ ] **Step 3:** Implement `StreamResolver`.
- [ ] **Step 4:** Run → PASS (5 tests).
- [ ] **Step 5: Commit** — `git add -A && git commit -m "feat(core): StreamResolver (yt-dlp)"`

---

### Task 14: `YtDlpStreamEngine`

**Files:** Create `Sources/CrateDiggerApp/Playback/YtDlpStreamEngine.swift`.

Implements `RadioPlaybackEngine` using `StreamResolver` (off-main `Task`) → builds a 1-item
`PlaybackQueueItem(url: resolved.playbackURL, title: stream.title, artist: stream.channel,
album: "YouTube", durationSeconds: resolved.durationSeconds ?? 0)` → loads it into a
`PlaybackService` instance (or reuses the shared one) via `load(queue:startIndex:0,autoPlay:true)`.
Maps `PlaybackState` → `RadioEngineState` and forwards `onTimeChange`. Emits `.loading` ("TUNING
IN…") during resolution and `.failed` on resolver error.

- [ ] **Step 1:** Create the engine; inject `StreamResolver` + a `PlaybackServiceProtocol`.
- [ ] **Step 2:** `swift build` → green.
- [ ] **Step 3: Commit** — `git add -A && git commit -m "feat(app): YtDlpStreamEngine"`

---

### Task 15: Engine selection (Auto/Native/WebView) + yt-dlp path setting + menu

**Files:** Modify `LibraryViewModel(+Radio)`, `AppDelegate.swift` (menu), the Settings surface, `PreferencesStore` already has `streamEngine`/`customYtDlpPath`.

- [ ] **Step 1:** Add `func resolveActiveEngineKind() -> RadioEngineKind`: read `prefs.streamEngine`
  — `"native"` → native (if yt-dlp resolvable, else webview + one-time `appAlert` "yt-dlp not found");
  `"webview"` → webview; `"auto"` → native if `ExternalToolLocator().resolveOptional(.ytdlp,
  explicitOverride: customYtDlpPath URL) != nil`, else webview. Set `radioEngineLabel` accordingly.
- [ ] **Step 2:** `playSelectedStream()` builds the engine from `resolveActiveEngineKind()`.
- [ ] **Step 3:** Add a "Stream Engine" submenu (Auto/Native/WebView) in `AppDelegate` menu
  (pattern like Appearance), writing `prefs.streamEngine` and re-resolving; add a yt-dlp path
  field to the existing tools/settings surface (mirror custom-ffmpeg path).
- [ ] **Step 4:** `swift build` + `scripts/test.sh` → green; **user verifies** switching engines and
  (if yt-dlp installed) native playback with full transport/output-device integration.
- [ ] **Step 5: Commit** — `git add -A && git commit -m "feat(app): stream engine selection + yt-dlp path setting"`

**Phase 4 gate:** both engines selectable and working; full suite green; user-verified.

---

## Self-Review (against the spec)

- **Spec coverage:** model/persistence/parser → Tasks 1–3; sidebar → 5; radio list → 6; OLED → 7;
  inspector + Disc-tab disable → 8; Add-Stream modal → 9; WebView engine → 10–11; native engine
  (yt-dlp BYO, resolver, locator, picker, path) → 12–15; scrobble guard → 11; engine default
  `.auto` → 15. All covered.
- **Placeholders:** none — Core steps carry full test + impl detail; UI steps carry exact files,
  interfaces, and the v7 reference lines.
- **Type consistency:** `StreamSource`/`StreamKind`/`StreamProvider`, `ParsedStream`,
  `ResolvedStream`, `RadioPlaybackEngine`/`RadioEngineState`/`RadioEngineKind`,
  `streamSourcesData`/`streamEngine`/`customYtDlpPath` used consistently across tasks.
