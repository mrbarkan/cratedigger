# SACD ISO Import + DoP Native Output Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Import SACD ISO archives as tagged per-track DSF albums (via a user-installed `sacd_extract`, yt-dlp-style locate-only), and play DSD files bit-perfectly to a DoP-capable DAC (xDuoo XD05) via a new native output mode.

**Architecture:** Part A adds `sacd_extract` as a fourth locate-only external tool and a Core `SACDExtractService` (magic-byte ISO detection, `-P` metadata parse, per-track stereo DSF extraction) driven by a File-menu action that mirrors the CD-rip flow (OLED progress → `loadFolders` import). Part B adds a second `PlaybackEngineProtocol` conformer, `DoPPlaybackEngine`, that memory-maps a DSF and packs its DSD bytes into DoP frames through an `AVAudioSourceNode` connected straight to the output node at 176.4/352.8 kHz; `PlaybackService` routes each track to the native engine or the existing ffmpeg-decode path via a pure `DSDOutputPolicy` (mode × DSD rate × device-supported rates).

**Tech Stack:** Swift, CoreAudio (device sample-rate query/set — new), AVAudioEngine (`AVAudioSourceNode`), existing `CommandRunning`/`ExternalToolLocator`, XCTest via `scripts/test.sh`.

## Global Constraints

- **Platform:** macOS 13+. Swift Package Manager, two targets: `CrateDiggerCore` (testable) / `CrateDiggerApp` (UI glue).
- **Tests:** run with `scripts/test.sh` (NOT bare `swift test`). Single class: `scripts/test.sh --filter <ClassName>`.
- **Locate-only tool (user decision 2026-07-23):** `sacd_extract` is NEVER bundled or committed — GPL + SACD-DRM circumvention vs public MIT repo. Resolution follows the yt-dlp pattern exactly (env var / PATH / graceful degrade + install-help alert).
- **Blocking subprocess rule (hard):** `CommandRunning.run` blocks its thread. It MUST run on a dedicated `DispatchQueue`, never on the Swift cooperative pool (see `FFmpegDSDDecoder.decodeQueue`, same lesson).
- **Bit-perfect rule (hard):** on the DoP path no volume scaling, no EQ, no sample-rate conversion, no mixing may touch samples — a corrupted DoP marker stream makes the DAC play it as PCM noise. `setVolume`/`setEqualizer`/`setMasterGain` are deliberate no-ops on `DoPPlaybackEngine`.
- **Archive read-only:** ISO and DSF sources are never modified.
- **Evidence (captured 2026-07-23, this session):**
  - Real ISO magic: bytes at offset `510 × 2048 = 1_044_480` are exactly `"SACDMTOC"`.
  - `sacd_extract -P -i <iso>` output captured to scratchpad `sacd-print-output.txt`; structure used by the parser fixture in Task 4.
  - Extraction recipe `-s -2 -c -t N -i ISO -y OUT` produces `<OUT>/<Album>/Stereo/NN - Title.dsf`, fully tagged (title/artist/album/track/date/ISRC), ~1 s/track from a local SSD. Success output is quiet (empty log).
  - Real DSF probes as codec `dsd_lsbf_planar`, **`sample_rate=352800`** — ffprobe reports DSD rates in BYTES/sec (bit rate ÷ 8). The shipped `DSDFormat.label` only maps bit-rates → Task 1 fixes this.
- **Commit trailer:** end every commit message with
  `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`

---

## File Structure

**Part A — SACD ISO import**
- Modify `Sources/CrateDiggerCore/Services/DSDFormat.swift` — accept ffprobe byte-rates (Task 1).
- Modify `Sources/CrateDiggerCore/Services/ExternalToolLocator.swift` — `case sacdExtract` (Task 2).
- Create `Sources/CrateDiggerCore/Services/SACDExtractService.swift` — ISO detection + `-P` parser + extraction service (Tasks 3–5, one file: one subsystem, mirrors `StreamResolver` layout).
- Modify `Sources/CrateDiggerApp/AppDelegate.swift`, `Sources/CrateDiggerApp/UI/MainWindowController.swift`, create `Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel+SACDImport.swift` (Task 6).

**Part B — DoP native output**
- Modify `Sources/CrateDiggerCore/Services/AudioOutputManager.swift` — device-ID/sample-rate CoreAudio APIs (Task 7).
- Create `Sources/CrateDiggerCore/Services/DSFFile.swift` — DSF header reader (Task 8).
- Create `Sources/CrateDiggerCore/Services/DoPPacker.swift` — DoP word packing + popcount VU level (Task 9).
- Create `Sources/CrateDiggerCore/Services/DSDOutputPolicy.swift` — `DSDOutputMode` + routing decision (Task 10).
- Create `Sources/CrateDiggerCore/Services/DoPPlaybackEngine.swift` — the native engine (Task 11).
- Modify `Sources/CrateDiggerCore/Services/PlaybackService.swift` — dual-engine routing + `meterPosition` hoist (Tasks 9, 12).
- Modify `Sources/CrateDiggerCore/Services/PreferencesStore.swift`, `Sources/CrateDiggerApp/AppDelegate.swift`, `Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel.swift` (Task 13).

---

## Task 1: Fix DSD labeling for real-world ffprobe rates

**Files:**
- Modify: `Sources/CrateDiggerCore/Services/DSDFormat.swift`
- Test: `Tests/CrateDiggerCoreTests/DSDFormatTests.swift`

**Interfaces:**
- Produces: `DSDFormat.label(sampleRateHz:)` additionally maps `352_800 / 705_600 / 1_411_200` (byte-rates) → `"DSD64"/"DSD128"/"DSD256"`. Everything else unchanged.

**Why:** ffprobe reports a real DSF (`dsd_lsbf_planar`) with `sample_rate=352800` — the DSD bit rate ÷ 8 — verified against a freshly extracted SACD track this session. The shipped mapping only knows bit-rates, so every real DSF labels as `DSD_LSBF_PLANAR` instead of `DSD64`. The call site is gated on `DSDFormat.isDSDCodec`, so byte-rate mapping cannot misfire on PCM (a 352.8 kHz DXD FLAC never reaches `label`).

- [ ] **Step 1: Write the failing test** — append to `DSDFormatTests`:

```swift
    func testFfprobeByteRatesMapToLabels() {
        // ffprobe reports DSD sample_rate in bytes/sec (bit rate ÷ 8) for
        // dsd_*_planar codecs — verified against a real sacd_extract DSF.
        XCTAssertEqual(DSDFormat.label(sampleRateHz: 352_800), "DSD64")
        XCTAssertEqual(DSDFormat.label(sampleRateHz: 705_600), "DSD128")
        XCTAssertEqual(DSDFormat.label(sampleRateHz: 1_411_200), "DSD256")
        // Below the DSD64 byte-rate stays non-DSD (192k PCM etc.).
        XCTAssertNil(DSDFormat.label(sampleRateHz: 192_000))
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `scripts/test.sh --filter DSDFormatTests`
Expected: FAIL — `352_800` returns `nil`.

- [ ] **Step 3: Implement** — in `DSDFormat.label`, replace the body:

```swift
    public static func label(sampleRateHz: Int?) -> String? {
        guard let rate = sampleRateHz else { return nil }
        // ffprobe reports DSD streams either as the 1-bit rate (2 822 400 Hz for
        // DSD64) or, for the *_planar codecs real DSF files use, as bytes/sec
        // (352 800 Hz for DSD64). Accept both; callers gate on isDSDCodec so a
        // PCM rate like 352.8 kHz DXD never reaches this mapping.
        let byteBase = base / 8
        switch rate {
        case base, byteBase: return "DSD64"
        case base * 2, byteBase * 2: return "DSD128"
        case base * 4, byteBase * 4: return "DSD256"
        default: return rate >= base ? "DSD" : nil
        }
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `scripts/test.sh --filter DSDFormatTests`
Expected: PASS (all, including the 3 pre-existing tests — `2_822_400` cases still map, `44_100`/`176_400`/`nil` still return nil, `3_000_000` still returns `"DSD"`).

- [ ] **Step 5: Commit**

```bash
git add Sources/CrateDiggerCore/Services/DSDFormat.swift Tests/CrateDiggerCoreTests/DSDFormatTests.swift
git commit -m "fix(dsd): label real-world DSFs — ffprobe reports DSD rates in bytes/sec

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 2: `sacd_extract` as a locate-only external tool

**Files:**
- Modify: `Sources/CrateDiggerCore/Services/ExternalToolLocator.swift`
- Test: `Tests/CrateDiggerCoreTests/ExternalToolLocatorTests.swift`

**Interfaces:**
- Produces: `ExternalTool.sacdExtract` with `executableName == "sacd_extract"` and `environmentOverrideKey == "CRATEDIGGER_SACD_EXTRACT_PATH"`. Resolution (bundle → override → env → PATH) is generic and needs no further change.

- [ ] **Step 1: Write the failing test** — append to `ExternalToolLocatorTests` (match the file's existing fixture style for env/fileManager injection; the two assertions below are the contract):

```swift
    func testSacdExtractToolNamesFollowConvention() {
        XCTAssertEqual(ExternalTool.sacdExtract.executableName, "sacd_extract")
        XCTAssertEqual(ExternalTool.sacdExtract.environmentOverrideKey, "CRATEDIGGER_SACD_EXTRACT_PATH")
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `scripts/test.sh --filter ExternalToolLocatorTests`
Expected: FAIL — `type 'ExternalTool' has no member 'sacdExtract'` (compile error is the expected RED here; the enum case doesn't exist).

- [ ] **Step 3: Implement** — in `ExternalToolLocator.swift`:
  - Add `case sacdExtract` to `ExternalTool`.
  - In `executableName`, add `case .sacdExtract: return "sacd_extract"` (binary name differs from the case name, same as `.ytdlp`).
  - In `environmentOverrideKey`, add `case .sacdExtract: return "CRATEDIGGER_SACD_EXTRACT_PATH"`.

- [ ] **Step 4: Run test to verify it passes**

Run: `scripts/test.sh --filter ExternalToolLocatorTests`
Expected: PASS (existing tests too — resolution logic untouched).

- [ ] **Step 5: Commit**

```bash
git add Sources/CrateDiggerCore/Services/ExternalToolLocator.swift Tests/CrateDiggerCoreTests/ExternalToolLocatorTests.swift
git commit -m "feat(sacd): sacd_extract as a locate-only external tool (yt-dlp pattern)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 3: SACD ISO detection (magic bytes)

**Files:**
- Create: `Sources/CrateDiggerCore/Services/SACDExtractService.swift` (started here; Tasks 4–5 extend it)
- Test: `Tests/CrateDiggerCoreTests/SACDExtractServiceTests.swift`

**Interfaces:**
- Produces: `public enum SACDISOInspector { public static func isSACDISO(_ url: URL) -> Bool }`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/CrateDiggerCoreTests/SACDExtractServiceTests.swift
import XCTest
@testable import CrateDiggerCore

final class SACDISOInspectorTests: XCTestCase {
    /// Writes `magic` at the SACD Master TOC offset (sector 510 × 2048 bytes).
    private func makeISO(magic: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString).iso")
        let handle: FileHandle
        FileManager.default.createFile(atPath: url.path, contents: Data())
        handle = try FileHandle(forWritingTo: url)
        try handle.seek(toOffset: 510 * 2048)
        try handle.write(contentsOf: Data(magic.utf8))
        try handle.close()
        return url
    }

    func testRecognizesSACDMagic() throws {
        let iso = try makeISO(magic: "SACDMTOC")
        defer { try? FileManager.default.removeItem(at: iso) }
        XCTAssertTrue(SACDISOInspector.isSACDISO(iso))
    }

    func testRejectsOrdinaryISOAndShortFile() throws {
        let plain = try makeISO(magic: "CD001___")
        defer { try? FileManager.default.removeItem(at: plain) }
        XCTAssertFalse(SACDISOInspector.isSACDISO(plain))

        let tiny = FileManager.default.temporaryDirectory
            .appendingPathComponent("tiny-\(UUID().uuidString).iso")
        try Data("hi".utf8).write(to: tiny)
        defer { try? FileManager.default.removeItem(at: tiny) }
        XCTAssertFalse(SACDISOInspector.isSACDISO(tiny))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `scripts/test.sh --filter SACDISOInspectorTests`
Expected: FAIL — `cannot find 'SACDISOInspector' in scope`.

- [ ] **Step 3: Implement**

```swift
// Sources/CrateDiggerCore/Services/SACDExtractService.swift
import Foundation

/// SACD ISOs can't be mounted by macOS; the reliable tell is the Master TOC
/// magic "SACDMTOC" at sector 510 (verified against a real disc image).
public enum SACDISOInspector {
    private static let magic = Data("SACDMTOC".utf8)
    private static let masterTOCOffset: UInt64 = 510 * 2048

    public static func isSACDISO(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: masterTOCOffset)) != nil,
              let bytes = try? handle.read(upToCount: magic.count) else { return false }
        return bytes == magic
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `scripts/test.sh --filter SACDISOInspectorTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/CrateDiggerCore/Services/SACDExtractService.swift Tests/CrateDiggerCoreTests/SACDExtractServiceTests.swift
git commit -m "feat(sacd): detect SACD ISOs by Master TOC magic

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 4: Parse `sacd_extract -P` disc metadata

**Files:**
- Modify: `Sources/CrateDiggerCore/Services/SACDExtractService.swift`
- Test: `Tests/CrateDiggerCoreTests/SACDExtractServiceTests.swift`

**Interfaces:**
- Produces:
  - `public struct SACDTrackInfo: Equatable, Sendable { public let number: Int; public let title: String; public let performer: String; public let durationSeconds: Double }`
  - `public struct SACDDiscInfo: Equatable, Sendable { public let albumTitle: String; public let albumArtist: String; public let year: Int?; public let stereoTracks: [SACDTrackInfo] }`
  - `public enum SACDMetadataParser { public static func parse(_ output: String) -> SACDDiscInfo? }`
- Format facts (from the captured real output): tab-indented `Key: Value` lines; an `Album Information:` block with `Title:`/`Artist:`; `Creation date: 2011-03-05` in `Disc Information:`; per-area blocks starting `Area Information [N]:` containing `Speaker config: 2 Channel` (stereo) or `6 Channel`, then `Title[i]:`, `Performer[i]:`, `Duration: MM:SS:FF [mins:secs:frames]` (75 frames/sec). Only the stereo area's tracks matter; track numbers are `i + 1` (matches `-t` and the extractor's `NN - Title.dsf` naming).

- [ ] **Step 1: Write the failing test** — append (fixture is trimmed real output):

```swift
final class SACDMetadataParserTests: XCTestCase {
    private let fixture = """
    sacd_extract client 0.3.9.3

    Disc Information:
    \tVersion:  1.20
    \tCreation date: 2011-03-05
    \tTitle: Wish You Were Here
    \tArtist: Pink Floyd

    Album Information:
    \tAlbum Catalog Number: B0000254SA
    \tTitle: Wish You Were Here
    \tArtist: Pink Floyd

    Area count: 2
    \tArea Information [0]:

    \tVersion:  1.20
    \tTrack Count: 2
    \tSpeaker config: 2 Channel
    \tTrack list [0]:
    \t\tTitle[0]: Shine On You Crazy Diamond (Parts I - V)
    \t\tPerformer[0]: Pink Floyd
    \t\tDuration: 13:30:50 [mins:secs:frames]

    \t\tTitle[1]: Welcome To The Machine
    \t\tPerformer[1]: Pink Floyd
    \t\tDuration: 07:25:29 [mins:secs:frames]

    \tArea Information [1]:

    \tTrack Count: 2
    \tSpeaker config: 6 Channel
    \tTrack list [1]:
    \t\tTitle[0]: Multichannel Ghost
    \t\tPerformer[0]: Pink Floyd
    \t\tDuration: 13:30:50 [mins:secs:frames]
    """

    func testParsesAlbumStereoTracksAndYear() throws {
        let disc = try XCTUnwrap(SACDMetadataParser.parse(fixture))
        XCTAssertEqual(disc.albumTitle, "Wish You Were Here")
        XCTAssertEqual(disc.albumArtist, "Pink Floyd")
        XCTAssertEqual(disc.year, 2011)
        // Only the 2-channel area's tracks — the 6-channel ghost is excluded.
        XCTAssertEqual(disc.stereoTracks.count, 2)
        XCTAssertEqual(disc.stereoTracks[0].number, 1)
        XCTAssertEqual(disc.stereoTracks[0].title, "Shine On You Crazy Diamond (Parts I - V)")
        // 13 min 30 sec 50 frames @ 75 fps
        XCTAssertEqual(disc.stereoTracks[0].durationSeconds, 13 * 60 + 30 + 50.0 / 75.0, accuracy: 0.001)
        XCTAssertEqual(disc.stereoTracks[1].number, 2)
        XCTAssertEqual(disc.stereoTracks[1].title, "Welcome To The Machine")
    }

    func testNoStereoAreaReturnsNil() {
        XCTAssertNil(SACDMetadataParser.parse("Disc Information:\n\tTitle: X\n"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `scripts/test.sh --filter SACDMetadataParserTests`
Expected: FAIL — `cannot find 'SACDMetadataParser' in scope`.

- [ ] **Step 3: Implement** — append to `SACDExtractService.swift`:

```swift
public struct SACDTrackInfo: Equatable, Sendable {
    public let number: Int
    public let title: String
    public let performer: String
    public let durationSeconds: Double
}

public struct SACDDiscInfo: Equatable, Sendable {
    public let albumTitle: String
    public let albumArtist: String
    public let year: Int?
    public let stereoTracks: [SACDTrackInfo]
}

/// Parses `sacd_extract -P` text output. Line-oriented on purpose — the tool's
/// format is stable, tab-indented `Key: Value` lines with per-area blocks.
public enum SACDMetadataParser {
    public static func parse(_ output: String) -> SACDDiscInfo? {
        var albumTitle = "", albumArtist = ""
        var year: Int?
        var inAlbumBlock = false
        var inStereoArea = false
        var sawAnyArea = false
        var tracks: [SACDTrackInfo] = []
        // Track fields arrive as Title[i]: / Performer[i]: / Duration: runs.
        var pendingTitle: String?, pendingPerformer = ""

        func value(of line: Substring, after key: String) -> String? {
            guard line.hasPrefix(key) else { return nil }
            return line.dropFirst(key.count).trimmingCharacters(in: .whitespaces)
        }
        func flushTrack() {
            if let title = pendingTitle {
                tracks.append(SACDTrackInfo(number: tracks.count + 1, title: title,
                                            performer: pendingPerformer, durationSeconds: 0))
            }
            pendingTitle = nil
            pendingPerformer = ""
        }

        for raw in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.drop(while: { $0 == "\t" || $0 == " " })
            if line.hasPrefix("Disc Information:") { inAlbumBlock = false }
            if line.hasPrefix("Album Information:") { inAlbumBlock = true }
            if line.hasPrefix("Area Information [") {
                flushTrack()
                sawAnyArea = true
                inStereoArea = false   // until this area proves 2 Channel
            }
            if let config = value(of: line, after: "Speaker config:") {
                inStereoArea = config.hasPrefix("2 Channel")
            }
            if let date = value(of: line, after: "Creation date:"), year == nil {
                year = Int(date.prefix(4))
            }
            if let title = value(of: line, after: "Title:") {
                // Disc block first, Album block overrides (both carry Title:).
                if inAlbumBlock || albumTitle.isEmpty { albumTitle = title }
            }
            if let artist = value(of: line, after: "Artist:") {
                if inAlbumBlock || albumArtist.isEmpty { albumArtist = artist }
            }
            guard inStereoArea else { continue }
            if line.hasPrefix("Title["), let range = line.range(of: "]: ") {
                flushTrack()
                pendingTitle = String(line[range.upperBound...])
            }
            if line.hasPrefix("Performer["), let range = line.range(of: "]: ") {
                pendingPerformer = String(line[range.upperBound...])
            }
            if let duration = value(of: line, after: "Duration:"), pendingTitle != nil {
                // "MM:SS:FF [mins:secs:frames]", 75 frames/sec (SACD, like CD).
                let parts = duration.split(separator: " ").first?.split(separator: ":") ?? []
                if parts.count == 3, let m = Double(parts[0]), let s = Double(parts[1]),
                   let f = Double(parts[2]) {
                    let seconds = m * 60 + s + f / 75.0
                    if let title = pendingTitle {
                        tracks.append(SACDTrackInfo(number: tracks.count + 1, title: title,
                                                    performer: pendingPerformer,
                                                    durationSeconds: seconds))
                        pendingTitle = nil
                        pendingPerformer = ""
                    }
                }
            }
        }
        flushTrack()
        guard !tracks.isEmpty else { return nil }
        return SACDDiscInfo(albumTitle: albumTitle, albumArtist: albumArtist,
                            year: year, stereoTracks: tracks)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `scripts/test.sh --filter SACDMetadataParserTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Sanity-check against the FULL real capture** (not just the trimmed fixture):

Run a one-off in the test or a scratch swift file is overkill — instead add one assertion-free smoke check manually: `scripts/test.sh --filter SACDMetadataParserTests` already passed; optionally paste the full `sacd-print-output.txt` into a temporary test locally to confirm 5 stereo tracks parse. Do not commit that temporary test.

- [ ] **Step 6: Commit**

```bash
git add Sources/CrateDiggerCore/Services/SACDExtractService.swift Tests/CrateDiggerCoreTests/SACDExtractServiceTests.swift
git commit -m "feat(sacd): parse sacd_extract -P disc/track metadata

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 5: SACD extraction service (args, per-track runs, relocation, progress)

**Files:**
- Modify: `Sources/CrateDiggerCore/Services/SACDExtractService.swift`
- Test: `Tests/CrateDiggerCoreTests/SACDExtractServiceTests.swift`

**Interfaces:**
- Consumes: `CommandRunning`/`CommandOutput` (ConversionService.swift), `SACDMetadataParser` (Task 4).
- Produces:
  - `public enum SACDExtractError: Error { case toolFailed(String), noMetadata, noOutputProduced }`
  - `public final class SACDExtractService`
    - `public init(toolURL: URL, commandRunner: CommandRunning = ProcessCommandRunner())`
    - `public static func printArguments(iso: URL) -> [String]`
    - `public static func extractArguments(iso: URL, trackNumber: Int, outputDir: URL) -> [String]`
    - `public func readDiscInfo(iso: URL, completion: @escaping (Result<SACDDiscInfo, Error>) -> Void)`
    - `public func extractStereoTracks(iso: URL, trackNumbers: [Int], to destination: URL, onTrackDone: @escaping (Int, Int) -> Void, completion: @escaping (Result<[URL], Error>) -> Void)` — runs one `sacd_extract` per track on a dedicated queue; after each run moves any new `.dsf` found under the staging dir's `*/Stereo/` into `destination` (flattening the tool's `<Album>/Stereo/` nesting); `onTrackDone(completed, total)` after each; `isCancelled` checked between tracks.
    - `public func cancel()`

- [ ] **Step 1: Write the failing test** — append:

```swift
/// CommandRunning fake that records invocations and simulates sacd_extract's
/// on-disk behavior (writes "<Album>/Stereo/NN - Title.dsf" under -y dir).
private final class FakeSACDRunner: CommandRunning {
    var invocations: [[String]] = []
    var failOnCall: Int? = nil
    func run(executableURL: URL, arguments: [String]) throws -> CommandOutput {
        invocations.append(arguments)
        if let failOn = failOnCall, invocations.count == failOn {
            return CommandOutput(terminationStatus: 1, standardOutput: "", standardError: "bad sector")
        }
        // Simulate the extraction side effect for "-t N ... -y DIR" calls.
        if let tIndex = arguments.firstIndex(of: "-t"), let yIndex = arguments.firstIndex(of: "-y") {
            let track = arguments[tIndex + 1]
            let outDir = URL(fileURLWithPath: arguments[yIndex + 1])
            let stereo = outDir.appendingPathComponent("Album/Stereo", isDirectory: true)
            try FileManager.default.createDirectory(at: stereo, withIntermediateDirectories: true)
            try Data("dsf".utf8).write(to: stereo.appendingPathComponent("0\(track) - T\(track).dsf"))
        }
        return CommandOutput(terminationStatus: 0, standardOutput: "", standardError: "")
    }
}

final class SACDExtractServiceTests: XCTestCase {
    private let tool = URL(fileURLWithPath: "/usr/local/bin/sacd_extract")

    func testArgumentBuilders() {
        XCTAssertEqual(SACDExtractService.printArguments(iso: URL(fileURLWithPath: "/a/d.iso")),
                       ["-P", "-i", "/a/d.iso"])
        XCTAssertEqual(SACDExtractService.extractArguments(iso: URL(fileURLWithPath: "/a/d.iso"),
                                                           trackNumber: 4,
                                                           outputDir: URL(fileURLWithPath: "/out")),
                       ["-s", "-2", "-c", "-t", "4", "-i", "/a/d.iso", "-y", "/out"])
    }

    func testExtractRunsPerTrackMovesFilesAndReportsProgress() throws {
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("sacd-dest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dest) }
        let runner = FakeSACDRunner()
        let service = SACDExtractService(toolURL: tool, commandRunner: runner)

        let exp = expectation(description: "extract")
        var progress: [(Int, Int)] = []
        var extracted: [URL] = []
        service.extractStereoTracks(iso: URL(fileURLWithPath: "/a/d.iso"),
                                    trackNumbers: [1, 2],
                                    to: dest,
                                    onTrackDone: { progress.append(($0, $1)) }) { result in
            if case .success(let urls) = result { extracted = urls }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5)

        XCTAssertEqual(runner.invocations.count, 2)
        XCTAssertEqual(progress.map { $0.0 }, [1, 2])
        XCTAssertEqual(extracted.count, 2)
        // Files are flattened out of "<Album>/Stereo/" into the destination.
        XCTAssertEqual(Set(extracted.map { $0.deletingLastPathComponent().path }), [dest.path])
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.appendingPathComponent("01 - T1.dsf").path))
    }

    func testExtractFailureSurfacesStderr() throws {
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("sacd-dest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dest) }
        let runner = FakeSACDRunner()
        runner.failOnCall = 1
        let service = SACDExtractService(toolURL: tool, commandRunner: runner)

        let exp = expectation(description: "extract")
        var failure: Error?
        service.extractStereoTracks(iso: URL(fileURLWithPath: "/a/d.iso"), trackNumbers: [1],
                                    to: dest, onTrackDone: { _, _ in }) { result in
            if case .failure(let error) = result { failure = error }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5)
        guard case .some(SACDExtractError.toolFailed(let message)) = failure else {
            return XCTFail("expected toolFailed, got \(String(describing: failure))")
        }
        XCTAssertTrue(message.contains("bad sector"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `scripts/test.sh --filter SACDExtractServiceTests`
Expected: FAIL — `cannot find 'SACDExtractService' in scope`.

- [ ] **Step 3: Implement** — append to `SACDExtractService.swift`:

```swift
public enum SACDExtractError: Error, LocalizedError {
    case toolFailed(String)
    case noMetadata
    case noOutputProduced

    public var errorDescription: String? {
        switch self {
        case .toolFailed(let stderr): return "sacd_extract failed: \(stderr)"
        case .noMetadata: return "Could not read the SACD's table of contents."
        case .noOutputProduced: return "sacd_extract completed but produced no DSF files."
        }
    }
}

/// Drives a user-installed sacd_extract binary: reads disc metadata (-P) and
/// extracts stereo tracks to tagged DSF files, one subprocess run per track so
/// progress and cancellation land between tracks (the ConversionService model).
public final class SACDExtractService {
    private let toolURL: URL
    private let commandRunner: CommandRunning
    private let fileManager = FileManager.default
    /// sacd_extract blocks its thread (spawn + wait). Keep it OFF the Swift
    /// cooperative pool — same rule as FFmpegDSDDecoder.decodeQueue.
    private static let workQueue = DispatchQueue(label: "com.cratedigger.sacd-extract",
                                                 qos: .userInitiated)
    private var isCancelled = false

    public init(toolURL: URL, commandRunner: CommandRunning = ProcessCommandRunner()) {
        self.toolURL = toolURL
        self.commandRunner = commandRunner
    }

    public static func printArguments(iso: URL) -> [String] {
        ["-P", "-i", iso.path]
    }

    /// -s DSF output, -2 stereo area, -c DST→DSD decompress, one track per run.
    public static func extractArguments(iso: URL, trackNumber: Int, outputDir: URL) -> [String] {
        ["-s", "-2", "-c", "-t", String(trackNumber), "-i", iso.path, "-y", outputDir.path]
    }

    public func cancel() {
        Self.workQueue.async { self.isCancelled = true }
    }

    public func readDiscInfo(iso: URL, completion: @escaping (Result<SACDDiscInfo, Error>) -> Void) {
        let runner = commandRunner
        let tool = toolURL
        Self.workQueue.async {
            do {
                let output = try runner.run(executableURL: tool,
                                            arguments: Self.printArguments(iso: iso))
                guard output.terminationStatus == 0 else {
                    return completion(.failure(SACDExtractError.toolFailed(output.standardError)))
                }
                guard let disc = SACDMetadataParser.parse(output.standardOutput) else {
                    return completion(.failure(SACDExtractError.noMetadata))
                }
                completion(.success(disc))
            } catch {
                completion(.failure(error))
            }
        }
    }

    public func extractStereoTracks(iso: URL,
                                    trackNumbers: [Int],
                                    to destination: URL,
                                    onTrackDone: @escaping (Int, Int) -> Void,
                                    completion: @escaping (Result<[URL], Error>) -> Void) {
        let runner = commandRunner
        let tool = toolURL
        let fm = fileManager
        Self.workQueue.async { [weak self] in
            self?.isCancelled = false
            // Extract into a private staging dir, then flatten "<Album>/Stereo/"
            // into the destination — callers shouldn't inherit the tool's layout.
            let staging = fm.temporaryDirectory
                .appendingPathComponent("cratedigger-sacd-\(UUID().uuidString)", isDirectory: true)
            defer { try? fm.removeItem(at: staging) }
            var produced: [URL] = []
            do {
                try fm.createDirectory(at: staging, withIntermediateDirectories: true)
                try fm.createDirectory(at: destination, withIntermediateDirectories: true)
                for (index, track) in trackNumbers.enumerated() {
                    if self?.isCancelled == true { break }
                    let output = try runner.run(
                        executableURL: tool,
                        arguments: Self.extractArguments(iso: iso, trackNumber: track,
                                                         outputDir: staging))
                    guard output.terminationStatus == 0 else {
                        throw SACDExtractError.toolFailed(output.standardError)
                    }
                    produced.append(contentsOf: try Self.relocateNewDSFs(from: staging,
                                                                         to: destination,
                                                                         fileManager: fm))
                    onTrackDone(index + 1, trackNumbers.count)
                }
                guard !produced.isEmpty else { throw SACDExtractError.noOutputProduced }
                completion(.success(produced))
            } catch {
                completion(.failure(error))
            }
        }
    }

    /// Move every .dsf anywhere under `staging` into `destination` (flat).
    private static func relocateNewDSFs(from staging: URL, to destination: URL,
                                        fileManager fm: FileManager) throws -> [URL] {
        var moved: [URL] = []
        let files = fm.enumerator(at: staging, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension.lowercased() == "dsf" } ?? []
        for file in files {
            let dest = destination.appendingPathComponent(file.lastPathComponent)
            // Never overwrite an existing rip; the import dedupe handles re-runs.
            if fm.fileExists(atPath: dest.path) {
                try fm.removeItem(at: file)
            } else {
                try fm.moveItem(at: file, to: dest)
                moved.append(dest)
            }
        }
        return moved
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `scripts/test.sh --filter SACDExtractServiceTests`
Expected: PASS (3 tests). If a Sendable warning appears on `runner` capture, do NOT add conformance to `CommandRunning` (it is not `Sendable` today and other conformers exist) — silence via a local `let` capture as written.

- [ ] **Step 5: Commit**

```bash
git add Sources/CrateDiggerCore/Services/SACDExtractService.swift Tests/CrateDiggerCoreTests/SACDExtractServiceTests.swift
git commit -m "feat(sacd): extraction service — per-track DSF rips with progress + cancel

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 6: App wiring — File ▸ Import SACD ISO…

**Files:**
- Create: `Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel+SACDImport.swift`
- Modify: `Sources/CrateDiggerApp/AppDelegate.swift` (File menu item), `Sources/CrateDiggerApp/UI/MainWindowController.swift` (forwarder)

**Interfaces:**
- Consumes: `SACDISOInspector`, `SACDExtractService`, `ExternalToolLocator().resolveOptional(.sacdExtract)`, `conversionProgress`/`oledView = .cdRip` (the CD-rip OLED pattern, `LibraryViewModel.swift:1571-1572`), `currentConversionDestinationURL`, `loadFolders(_:)`, `PathComponentSanitizer`.
- No new Core logic here (all tested in Tasks 3–5); this is the untested UI-glue layer per CLAUDE.md. Manual verification below.

- [ ] **Step 1: Menu + forwarder**

In `AppDelegate` where the File menu is built (near the existing open/import items), add:

```swift
        fileMenu.addItem(makeItem(title: "Import SACD ISO…", action: #selector(importSACDISO(_:)),
                                  keyEquivalent: ""))
```
(match the file's actual item-construction helper; if items are built inline, follow that style) and the action + `validateMenuItem` enablement (enabled whenever a library window exists):

```swift
    @objc func importSACDISO(_ sender: Any?) {
        mainWindowController?.importSACDISO()
    }
```

In `MainWindowController`:

```swift
    func importSACDISO() {
        libraryViewModel.beginSACDImport(presentingWindow: window)
    }
```
(match the controller's actual view-model property name.)

- [ ] **Step 2: The import flow** — create `LibraryViewModel+SACDImport.swift`:

```swift
import AppKit
import CrateDiggerCore
import UniformTypeIdentifiers

/// SACD ISO → per-track DSF import ("rip as physical album"). Mirrors the CD
/// rip flow: OLED shows rip progress, results land via loadFolders (Prep Crate).
/// sacd_extract is bring-your-own (GPL) — resolved like yt-dlp, never bundled.
@MainActor
extension LibraryViewModel {

    func beginSACDImport(presentingWindow: NSWindow?) {
        guard let tool = ExternalToolLocator().resolveOptional(.sacdExtract)?.url else {
            presentSACDExtractMissing()
            return
        }
        let panel = NSOpenPanel()
        panel.title = "Choose an SACD ISO"
        panel.allowedContentTypes = [UTType(filenameExtension: "iso") ?? .data]
        panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in
            guard response == .OK, let iso = panel.url else { return }
            Task { @MainActor in self?.importSACDISO(at: iso, toolURL: tool) }
        }
    }

    private func importSACDISO(at iso: URL, toolURL: URL) {
        guard SACDISOInspector.isSACDISO(iso) else {
            appAlert = .error(title: "Not an SACD ISO",
                              message: "“\(iso.lastPathComponent)” has no SACD table of contents. Only SACD images can be imported this way.")
            return
        }
        guard let destRoot = currentConversionDestinationURL ?? managedLibraryFolderURL else {
            appAlert = .error(title: "No Destination Set",
                              message: "Configure a default output folder in Preferences first.")
            return
        }
        let service = SACDExtractService(toolURL: toolURL)
        oledView = .cdRip
        conversionProgress = ConversionProgressSnapshot(jobsCompleted: 0, jobsTotal: 1,
                                                        currentFilename: iso.lastPathComponent,
                                                        isRunning: true)
        service.readDiscInfo(iso: iso) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .failure(let error):
                    self.finishSACDImport(alert: .error(title: "SACD Read Failed",
                                                        message: error.localizedDescription))
                case .success(let disc):
                    self.confirmAndExtract(disc: disc, iso: iso, service: service, destRoot: destRoot)
                }
            }
        }
    }

    private func confirmAndExtract(disc: SACDDiscInfo, iso: URL,
                                   service: SACDExtractService, destRoot: URL) {
        let artist = PathComponentSanitizer.sanitize(disc.albumArtist, fallback: "Unknown Artist")
        let albumPart = PathComponentSanitizer.sanitize(disc.albumTitle, fallback: "Unknown Album")
        let albumFolder = disc.year.map { "[\($0)] - \(albumPart)" } ?? albumPart
        let destination = destRoot.appendingPathComponent(artist, isDirectory: true)
            .appendingPathComponent(albumFolder, isDirectory: true)

        let alert = NSAlert()
        alert.messageText = "Rip “\(disc.albumTitle)”?"
        alert.informativeText = """
        \(disc.albumArtist) — \(disc.stereoTracks.count) stereo tracks (DSD64).
        DSF files will be written to:
        \(destination.path)
        """
        alert.addButton(withTitle: "Rip")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else {
            finishSACDImport(alert: nil)
            return
        }

        conversionProgress = ConversionProgressSnapshot(jobsCompleted: 0,
                                                        jobsTotal: disc.stereoTracks.count,
                                                        currentFilename: disc.albumTitle,
                                                        isRunning: true)
        service.extractStereoTracks(
            iso: iso,
            trackNumbers: disc.stereoTracks.map(\.number),
            to: destination,
            onTrackDone: { [weak self] done, total in
                Task { @MainActor in
                    self?.conversionProgress = ConversionProgressSnapshot(
                        jobsCompleted: done, jobsTotal: total,
                        currentFilename: disc.stereoTracks.indices.contains(done)
                            ? disc.stereoTracks[done].title : nil,
                        isRunning: true)
                }
            },
            completion: { [weak self] result in
                Task { @MainActor in
                    guard let self else { return }
                    switch result {
                    case .success(let files):
                        // Scan the album folder in — lands in the Prep Crate
                        // like any dig, then files into a crate as usual.
                        self.loadFolders([destination])
                        self.finishSACDImport(alert: .info(
                            title: "SACD Ripped!",
                            message: "\(files.count) DSF tracks imported from “\(disc.albumTitle)”."))
                    case .failure(let error):
                        self.finishSACDImport(alert: .error(title: "SACD Rip Failed",
                                                            message: error.localizedDescription))
                    }
                }
            })
    }

    private func finishSACDImport(alert: AppAlert?) {
        conversionProgress = .idle
        if oledView == .cdRip { oledView = .nowPlaying }
        if let alert { appAlert = alert }
    }

    /// Bring-your-own binary, like yt-dlp — but there is no brew formula, so
    /// offer the verified source-build recipe instead.
    private func presentSACDExtractMissing() {
        let recipe = """
        git clone https://github.com/sacd-ripper/sacd-ripper.git
        cd sacd-ripper/tools/sacd_extract
        cmake -DCMAKE_POLICY_VERSION_MINIMUM=3.5 . && cmake --build .
        sudo cp sacd_extract /usr/local/bin/
        """
        let alert = NSAlert()
        alert.messageText = "sacd_extract Not Found"
        alert.informativeText = """
        Importing SACD ISOs needs the open-source sacd_extract tool, which CrateDigger can't bundle for licensing reasons.

        Build it once with the commands below (needs Xcode command-line tools + cmake), or set CRATEDIGGER_SACD_EXTRACT_PATH.
        """
        alert.addButton(withTitle: "Copy Build Commands")
        alert.addButton(withTitle: "OK")
        if alert.runModal() == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(recipe, forType: .string)
        }
    }
}
```

Adjust to the real names on contact: `AppAlert` case spelling (`.info`/`.error` as used elsewhere in the file), `managedLibraryFolderURL`, `ConversionProgressSnapshot` field order. Match, don't invent.

- [ ] **Step 3: Build**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 4: Manual verification with the real ISO** (needs `/Volumes/DBKN_M1` mounted)

1. `swift build && .build/arm64-apple-macosx/debug/CrateDiggerApp`
2. Ensure `sacd_extract` resolves (e.g. `export CRATEDIGGER_SACD_EXTRACT_PATH=<scratchpad>/sacd_extract` before launching, or a PATH install).
3. File ▸ Import SACD ISO… → pick the Wish You Were Here ISO.
4. Confirm dialog shows "Pink Floyd — 5 stereo tracks", destination `…/Pink Floyd/[2011] - Wish You Were Here`.
5. Rip → OLED shows RIPPING progress 1→5 → "SACD Ripped!" → album appears in the Prep Crate with 5 tracks labeled `DSD64` (Task 1's fix visible here), fully tagged.
6. Play a track — decode-on-play path works as before.

- [ ] **Step 5: Commit**

```bash
git add Sources/CrateDiggerApp
git commit -m "feat(sacd): File ▸ Import SACD ISO — rip stereo DSF album via sacd_extract

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 7: AudioOutputManager — device IDs and sample rates (CoreAudio)

**Files:**
- Modify: `Sources/CrateDiggerCore/Services/AudioOutputManager.swift`
- Test: `Tests/CrateDiggerCoreTests/AudioOutputManagerRateTests.swift` (create)

**Interfaces:**
- Produces (all on `AudioOutputManager`):
  - `public func defaultOutputDeviceID() -> AudioDeviceID?`
  - `public func deviceID(forUID uid: String?) -> AudioDeviceID?` — nil/unknown UID → default output device
  - `public func availableSampleRates(deviceID: AudioDeviceID) -> [Double]` — flattened from `AudioValueRange` (a discrete rate has min == max; a true range contributes both endpoints)
  - `public func nominalSampleRate(deviceID: AudioDeviceID) -> Double?`
  - `@discardableResult public func setNominalSampleRate(_ rate: Double, deviceID: AudioDeviceID) -> Bool`
- None of this exists today (verified — the class is enumerate-only).

- [ ] **Step 1: Write the failing test**

```swift
// Tests/CrateDiggerCoreTests/AudioOutputManagerRateTests.swift
import XCTest
@testable import CrateDiggerCore

/// Integration-level: runs against the machine's real default output device.
/// Every Mac has one, and every output device supports at least one rate.
final class AudioOutputManagerRateTests: XCTestCase {
    func testDefaultDeviceReportsRates() throws {
        let manager = AudioOutputManager()
        let device = try XCTUnwrap(manager.defaultOutputDeviceID())
        let rates = manager.availableSampleRates(deviceID: device)
        XCTAssertFalse(rates.isEmpty)
        let nominal = try XCTUnwrap(manager.nominalSampleRate(deviceID: device))
        XCTAssertGreaterThan(nominal, 0)
    }

    func testNilUIDResolvesToDefaultDevice() throws {
        let manager = AudioOutputManager()
        XCTAssertEqual(manager.deviceID(forUID: nil), manager.defaultOutputDeviceID())
        XCTAssertEqual(manager.deviceID(forUID: "no-such-uid-ever"), manager.defaultOutputDeviceID())
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `scripts/test.sh --filter AudioOutputManagerRateTests`
Expected: FAIL — no member `defaultOutputDeviceID`.

- [ ] **Step 3: Implement** — append to `AudioOutputManager` (uses the same `AudioObjectGetPropertyData` style already in the file):

```swift
    public func defaultOutputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                                &address, 0, nil, &size, &deviceID)
        return status == noErr && deviceID != 0 ? deviceID : nil
    }

    /// nil (or unknown) UID means "system default output".
    public func deviceID(forUID uid: String?) -> AudioDeviceID? {
        guard let uid else { return defaultOutputDeviceID() }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                             &address, 0, nil, &size) == noErr else {
            return defaultOutputDeviceID()
        }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &ids) == noErr else {
            return defaultOutputDeviceID()
        }
        for id in ids {
            var uidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            var deviceUID: Unmanaged<CFString>?
            var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            if AudioObjectGetPropertyData(id, &uidAddress, 0, nil, &uidSize, &deviceUID) == noErr,
               let value = deviceUID?.takeRetainedValue() as String?, value == uid {
                return id
            }
        }
        return defaultOutputDeviceID()
    }

    public func availableSampleRates(deviceID: AudioDeviceID) -> [Double] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyAvailableNominalSampleRates,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        var ranges = [AudioValueRange](repeating: AudioValueRange(),
                                       count: Int(size) / MemoryLayout<AudioValueRange>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &ranges) == noErr else {
            return []
        }
        var rates: Set<Double> = []
        for range in ranges {
            rates.insert(range.mMinimum)
            rates.insert(range.mMaximum)
        }
        return rates.sorted()
    }

    public func nominalSampleRate(deviceID: AudioDeviceID) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var rate: Double = 0
        var size = UInt32(MemoryLayout<Double>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &rate) == noErr,
              rate > 0 else { return nil }
        return rate
    }

    @discardableResult
    public func setNominalSampleRate(_ rate: Double, deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value = rate
        return AudioObjectSetPropertyData(deviceID, &address, 0, nil,
                                          UInt32(MemoryLayout<Double>.size), &value) == noErr
    }
```

Add `import CoreAudio` at the top if not already imported (the file already uses CoreAudio types; keep imports as-is if it compiles).

- [ ] **Step 4: Run test to verify it passes**

Run: `scripts/test.sh --filter AudioOutputManagerRateTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/CrateDiggerCore/Services/AudioOutputManager.swift Tests/CrateDiggerCoreTests/AudioOutputManagerRateTests.swift
git commit -m "feat(audio): CoreAudio device-ID + sample-rate query/set APIs

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 8: DSF header reader

**Files:**
- Create: `Sources/CrateDiggerCore/Services/DSFFile.swift`
- Test: `Tests/CrateDiggerCoreTests/DSFFileTests.swift`

**Interfaces:**
- Produces:
  - `public struct DSFInfo: Equatable, Sendable` — `channelCount: Int`, `dsdSampleRateHz: Int` (the true 1-bit rate, e.g. 2_822_400), `lsbFirst: Bool`, `sampleCountPerChannel: Int64` (bits), `blockSizeBytes: Int`, `dataOffset: Int64`, `dataByteCountPerChannel: Int64`, computed `durationSeconds: Double`, computed `dopFrameRateHz: Double` (`dsdSampleRateHz / 16`)
  - `public enum DSFReadError: Error { case notDSF, malformedHeader }`
  - `public enum DSFFile { public static func readInfo(url: URL) throws -> DSFInfo }`
- DSF layout (all little-endian): `"DSD "` chunk (28 bytes: magic 4, chunkSize 8, totalFileSize 8, metadataOffset 8) → `"fmt "` chunk (52 bytes: magic 4, chunkSize 8, formatVersion 4, formatID 4, channelType 4, channelCount 4, samplingFrequency 4, bitsPerSample 4 [1 = LSB-first, 8 = MSB-first], sampleCount 8, blockSizeBytes 4, reserved 4) → `"data"` chunk (magic 4, chunkSize 8, then per-channel-interleaved blocks of `blockSizeBytes`).

- [ ] **Step 1: Write the failing test**

```swift
// Tests/CrateDiggerCoreTests/DSFFileTests.swift
import XCTest
@testable import CrateDiggerCore

final class DSFFileTests: XCTestCase {
    /// Minimal valid stereo DSD64 DSF: header + one 4096-byte block per channel.
    private func makeDSF(samplingFrequency: UInt32 = 2_822_400,
                         channels: UInt32 = 2,
                         bitsPerSample: UInt32 = 1,
                         magic: String = "DSD ") throws -> URL {
        var data = Data()
        func le32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func le64(_ value: UInt64) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let blockSize: UInt32 = 4096
        let dataPayload = Int(channels) * Int(blockSize)
        let totalSize = UInt64(28 + 52 + 12 + dataPayload)

        data.append(contentsOf: magic.utf8)          // "DSD "
        le64(28); le64(totalSize); le64(0)
        data.append(contentsOf: "fmt ".utf8)
        le64(52); le32(1); le32(0)                   // version, format id (DSD raw)
        le32(2)                                       // channel type: stereo
        le32(channels)
        le32(samplingFrequency)
        le32(bitsPerSample)
        le64(UInt64(blockSize) * 8)                  // sample count (bits/channel)
        le32(blockSize); le32(0)
        data.append(contentsOf: "data".utf8)
        le64(UInt64(12 + dataPayload))
        data.append(Data(repeating: 0x69, count: dataPayload))   // DSD silence

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString).dsf")
        try data.write(to: url)
        return url
    }

    func testReadsStereoDSD64Header() throws {
        let url = try makeDSF()
        defer { try? FileManager.default.removeItem(at: url) }
        let info = try DSFFile.readInfo(url: url)
        XCTAssertEqual(info.channelCount, 2)
        XCTAssertEqual(info.dsdSampleRateHz, 2_822_400)
        XCTAssertTrue(info.lsbFirst)
        XCTAssertEqual(info.blockSizeBytes, 4096)
        XCTAssertEqual(info.sampleCountPerChannel, 4096 * 8)
        XCTAssertEqual(info.dataOffset, 28 + 52 + 12)
        XCTAssertEqual(info.dopFrameRateHz, 176_400, accuracy: 0.01)
        XCTAssertEqual(info.durationSeconds, Double(4096 * 8) / 2_822_400, accuracy: 1e-9)
    }

    func testRejectsNonDSF() throws {
        let url = try makeDSF(magic: "RIFF")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try DSFFile.readInfo(url: url)) { error in
            guard case DSFReadError.notDSF = error else { return XCTFail("wrong error: \(error)") }
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `scripts/test.sh --filter DSFFileTests`
Expected: FAIL — `cannot find 'DSFFile' in scope`.

- [ ] **Step 3: Implement**

```swift
// Sources/CrateDiggerCore/Services/DSFFile.swift
import Foundation

public enum DSFReadError: Error {
    case notDSF
    case malformedHeader
}

public struct DSFInfo: Equatable, Sendable {
    public let channelCount: Int
    /// The true 1-bit DSD rate (2 822 400 for DSD64) — from the header, NOT
    /// ffprobe's bytes/sec convention.
    public let dsdSampleRateHz: Int
    public let lsbFirst: Bool
    public let sampleCountPerChannel: Int64
    public let blockSizeBytes: Int
    public let dataOffset: Int64
    public let dataByteCountPerChannel: Int64

    public var durationSeconds: Double {
        Double(sampleCountPerChannel) / Double(dsdSampleRateHz)
    }
    /// DoP carries 16 DSD bits per PCM frame: DSD64 → 176.4k, DSD128 → 352.8k.
    public var dopFrameRateHz: Double { Double(dsdSampleRateHz) / 16.0 }
}

public enum DSFFile {
    public static func readInfo(url: URL) throws -> DSFInfo {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let header = try handle.read(upToCount: 28 + 52 + 12), header.count == 92 else {
            throw DSFReadError.notDSF
        }
        func le32(_ offset: Int) -> UInt32 {
            header.subdata(in: offset..<offset + 4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
        }
        func le64(_ offset: Int) -> UInt64 {
            header.subdata(in: offset..<offset + 8).withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }.littleEndian
        }
        guard header.prefix(4) == Data("DSD ".utf8) else { throw DSFReadError.notDSF }
        guard header.subdata(in: 28..<32) == Data("fmt ".utf8),
              header.subdata(in: 80..<84) == Data("data".utf8) else {
            throw DSFReadError.malformedHeader
        }
        let channelCount = Int(le32(28 + 24))
        let samplingFrequency = Int(le32(28 + 28))
        let bitsPerSample = le32(28 + 32)
        let sampleCount = Int64(le64(28 + 36))
        let blockSize = Int(le32(28 + 44))
        guard channelCount > 0, samplingFrequency > 0, blockSize > 0,
              bitsPerSample == 1 || bitsPerSample == 8 else {
            throw DSFReadError.malformedHeader
        }
        return DSFInfo(channelCount: channelCount,
                       dsdSampleRateHz: samplingFrequency,
                       lsbFirst: bitsPerSample == 1,
                       sampleCountPerChannel: sampleCount,
                       blockSizeBytes: blockSize,
                       dataOffset: 92,
                       dataByteCountPerChannel: (sampleCount + 7) / 8)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `scripts/test.sh --filter DSFFileTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/CrateDiggerCore/Services/DSFFile.swift Tests/CrateDiggerCoreTests/DSFFileTests.swift
git commit -m "feat(dop): DSF header reader — true DSD rate, layout, DoP frame rate

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 9: DoP word packing + DSD VU level (+ meterPosition hoist)

**Files:**
- Create: `Sources/CrateDiggerCore/Services/DoPPacker.swift`
- Modify: `Sources/CrateDiggerCore/Services/PlaybackService.swift` — hoist `AVPlayerEngine`'s private `meterPosition(fromDecibels:)` to `static func PlaybackMeterScale.position(fromDecibels:)` (internal enum in the same file) so both engines share the exact same meter mapping (MeterDriver depends on its scale).
- Test: `Tests/CrateDiggerCoreTests/DoPPackerTests.swift`

**Interfaces:**
- Produces:
  - `public enum DoPPacker`
    - `public static let markers: [UInt8] = [0x05, 0xFA]`
    - `public static func word(marker: UInt8, older: UInt8, newer: UInt8, lsbFirst: Bool) -> Int32` — 24-bit signed word `marker<<16 | older'<<8 | newer'` (bytes bit-reversed when `lsbFirst`, because DSF stores the earliest bit in the LSB while DoP wants it in the MSB), sign-extended to Int32.
    - `public static func float(fromWord word: Int32) -> Float` — `Float(word) / 8_388_608` (2²³ — exact in Float32 for 24-bit ints).
  - `public enum DSDLevelMeter { public static func amplitude(of bytes: some Sequence<UInt8>) -> Double }` — mean of `|ones(byte)/4 − 1|` (a DSD stream's duty cycle ≈ instantaneous amplitude; 0x69 silence → 0).
  - `PlaybackMeterScale.position(fromDecibels:)` (internal) — moved verbatim from `AVPlayerEngine.meterPosition`.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/CrateDiggerCoreTests/DoPPackerTests.swift
import XCTest
@testable import CrateDiggerCore

final class DoPPackerTests: XCTestCase {
    func testMarkerAlternation() {
        XCTAssertEqual(DoPPacker.markers, [0x05, 0xFA])
    }

    func testWordPacksMarkerAndBitReversedPayload() {
        // LSB-first byte 0x01 (earliest bit set) must become MSB-first 0x80.
        let word = DoPPacker.word(marker: 0x05, older: 0x01, newer: 0x00, lsbFirst: true)
        XCTAssertEqual(word, 0x05_80_00)
        // MSB-first (DFF-style) bytes pass through unreversed.
        XCTAssertEqual(DoPPacker.word(marker: 0x05, older: 0x01, newer: 0x00, lsbFirst: false),
                       0x05_00_01 << 8 >> 8)   // 0x050001, positive
    }

    func testWordWithHighMarkerIsNegative24Bit() {
        // 0xFA in the top byte makes the 24-bit word negative after sign extension.
        let word = DoPPacker.word(marker: 0xFA, older: 0, newer: 0, lsbFirst: true)
        XCTAssertEqual(word, Int32(bitPattern: 0xFFFA_0000))
        XCTAssertLessThan(word, 0)
    }

    func testFloatEncodingIsExactFor24Bit() {
        XCTAssertEqual(DoPPacker.float(fromWord: 0x05_80_00), Float(0x058000) / 8_388_608)
        XCTAssertEqual(DoPPacker.float(fromWord: -8_388_608), -1.0)
    }

    func testDSDSilenceMeasuresZeroAmplitude() {
        // 0x69 = 01101001 — four 1s of eight: the standard DSD idle pattern.
        XCTAssertEqual(DSDLevelMeter.amplitude(of: [UInt8](repeating: 0x69, count: 64)), 0, accuracy: 1e-9)
        // All-ones (DC full positive) and all-zeros both measure full scale.
        XCTAssertEqual(DSDLevelMeter.amplitude(of: [UInt8](repeating: 0xFF, count: 8)), 1, accuracy: 1e-9)
        XCTAssertEqual(DSDLevelMeter.amplitude(of: [UInt8](repeating: 0x00, count: 8)), 1, accuracy: 1e-9)
        XCTAssertEqual(DSDLevelMeter.amplitude(of: []), 0)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `scripts/test.sh --filter DoPPackerTests`
Expected: FAIL — `cannot find 'DoPPacker' in scope`.

- [ ] **Step 3: Implement**

```swift
// Sources/CrateDiggerCore/Services/DoPPacker.swift
import Foundation

/// DoP (DSD over PCM, spec 1.1): each 24-bit PCM frame carries a marker byte
/// (0x05/0xFA alternating per frame) in bits 23–16 and 16 DSD bits — two bytes,
/// chronologically older in bits 15–8 — below it. A DAC that sees the marker
/// sequence unpacks the DSD stream bit-perfectly; anything that modifies the
/// samples (volume, EQ, SRC) destroys the markers, so the DoP path must stay
/// untouched end to end.
public enum DoPPacker {
    public static let markers: [UInt8] = [0x05, 0xFA]

    /// Bit-reversal LUT: DSF stores each byte LSB-first (earliest bit = LSB);
    /// DoP wants MSB-first.
    static let reversed: [UInt8] = (0...255).map { value in
        var v = UInt8(value), r: UInt8 = 0
        for _ in 0..<8 { r = (r << 1) | (v & 1); v >>= 1 }
        return r
    }

    public static func word(marker: UInt8, older: UInt8, newer: UInt8, lsbFirst: Bool) -> Int32 {
        let hi = lsbFirst ? reversed[Int(older)] : older
        let lo = lsbFirst ? reversed[Int(newer)] : newer
        let raw = UInt32(marker) << 16 | UInt32(hi) << 8 | UInt32(lo)
        // Sign-extend 24-bit → 32-bit.
        return Int32(bitPattern: raw << 8) >> 8
    }

    public static func float(fromWord word: Int32) -> Float {
        Float(word) / 8_388_608
    }
}

/// A DSD stream's 1-bit duty cycle tracks instantaneous amplitude: 50% ones is
/// silence, all-ones/all-zeros is full scale. Mean |duty − ½| × 2 over a window
/// gives an honest, decode-free VU level for the bit-perfect path.
public enum DSDLevelMeter {
    static let onesCount: [Double] = (0...255).map { Double($0.nonzeroBitCount) }

    public static func amplitude(of bytes: some Sequence<UInt8>) -> Double {
        var sum = 0.0
        var count = 0
        for byte in bytes {
            sum += abs(onesCount[Int(byte)] / 4.0 - 1.0)
            count += 1
        }
        return count == 0 ? 0 : sum / Double(count)
    }
}
```

Then in `PlaybackService.swift`, hoist the meter map — replace `AVPlayerEngine`'s private `meterPosition(fromDecibels:)` with a call to a new shared scale (move the existing body verbatim):

```swift
/// The single dB → meter-position map (-48 dBFS → 0, 0 dBFS → 0.80). MeterDriver
/// calibrates against this exact scale — every engine must use it.
enum PlaybackMeterScale {
    static func position(fromDecibels db: Double) -> Double {
        // (body moved verbatim from AVPlayerEngine.meterPosition)
    }
}
```
and update `AVPlayerEngine`'s call sites to `PlaybackMeterScale.position(fromDecibels:)`.

- [ ] **Step 4: Run tests**

Run: `scripts/test.sh --filter "DoPPackerTests|PlaybackServiceTests"`
Expected: PASS — packer tests green, playback suite untouched by the hoist.

- [ ] **Step 5: Commit**

```bash
git add Sources/CrateDiggerCore/Services/DoPPacker.swift Sources/CrateDiggerCore/Services/PlaybackService.swift Tests/CrateDiggerCoreTests/DoPPackerTests.swift
git commit -m "feat(dop): DoP word packer + popcount DSD VU level; shared meter scale

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 10: DSD output policy

**Files:**
- Create: `Sources/CrateDiggerCore/Services/DSDOutputPolicy.swift`
- Test: `Tests/CrateDiggerCoreTests/DSDOutputPolicyTests.swift`

**Interfaces:**
- Produces:
  - `public enum DSDOutputMode: String, CaseIterable, Sendable { case auto, pcm, native }`
  - `public enum DSDPlaybackRoute: Equatable, Sendable { case native(dopFrameRateHz: Double); case pcmDecode }`
  - `public enum DSDOutputPolicy { public static func route(mode: DSDOutputMode, dsdRateHz: Int, channelCount: Int, deviceSampleRates: [Double]) -> DSDPlaybackRoute }`
- Rules: `.pcm` mode → `.pcmDecode`. Non-stereo → `.pcmDecode` (DoP v1 is stereo-only). Otherwise `frameRate = dsdRateHz / 16`; if `deviceSampleRates` contains it (±0.5 Hz) → `.native(frameRate)`, else `.pcmDecode` (XD05: 176.4k+352.8k present → DSD64/128 native, DSD256 needs 705.6k → falls back).

- [ ] **Step 1: Write the failing test**

```swift
// Tests/CrateDiggerCoreTests/DSDOutputPolicyTests.swift
import XCTest
@testable import CrateDiggerCore

final class DSDOutputPolicyTests: XCTestCase {
    // The xDuoo XD05 Basic's USB rates (no 705.6k → no DSD256 DoP).
    private let xd05: [Double] = [44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000]

    func testAutoRoutesSupportedRatesNative() {
        XCTAssertEqual(DSDOutputPolicy.route(mode: .auto, dsdRateHz: 2_822_400,
                                             channelCount: 2, deviceSampleRates: xd05),
                       .native(dopFrameRateHz: 176_400))
        XCTAssertEqual(DSDOutputPolicy.route(mode: .auto, dsdRateHz: 5_644_800,
                                             channelCount: 2, deviceSampleRates: xd05),
                       .native(dopFrameRateHz: 352_800))
    }

    func testUnsupportedRateFallsBackToPCM() {
        // DSD256 needs 705.6k the XD05 doesn't expose.
        XCTAssertEqual(DSDOutputPolicy.route(mode: .auto, dsdRateHz: 11_289_600,
                                             channelCount: 2, deviceSampleRates: xd05),
                       .pcmDecode)
        // Built-in output (max 96k) never goes native.
        XCTAssertEqual(DSDOutputPolicy.route(mode: .native, dsdRateHz: 2_822_400,
                                             channelCount: 2, deviceSampleRates: [44100, 48000, 96000]),
                       .pcmDecode)
    }

    func testPCMModeAndNonStereoAlwaysDecode() {
        XCTAssertEqual(DSDOutputPolicy.route(mode: .pcm, dsdRateHz: 2_822_400,
                                             channelCount: 2, deviceSampleRates: xd05),
                       .pcmDecode)
        XCTAssertEqual(DSDOutputPolicy.route(mode: .auto, dsdRateHz: 2_822_400,
                                             channelCount: 6, deviceSampleRates: xd05),
                       .pcmDecode)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `scripts/test.sh --filter DSDOutputPolicyTests`
Expected: FAIL — `cannot find 'DSDOutputPolicy' in scope`.

- [ ] **Step 3: Implement**

```swift
// Sources/CrateDiggerCore/Services/DSDOutputPolicy.swift
import Foundation

public enum DSDOutputMode: String, CaseIterable, Sendable {
    case auto, pcm, native
}

public enum DSDPlaybackRoute: Equatable, Sendable {
    case native(dopFrameRateHz: Double)
    case pcmDecode
}

/// Decides how a DSD track reaches the DAC: bit-perfect DoP when the mode
/// allows it and the output device exposes the required PCM frame rate,
/// otherwise the existing ffmpeg decode-to-PCM path.
public enum DSDOutputPolicy {
    public static func route(mode: DSDOutputMode,
                             dsdRateHz: Int,
                             channelCount: Int,
                             deviceSampleRates: [Double]) -> DSDPlaybackRoute {
        guard mode != .pcm, channelCount == 2 else { return .pcmDecode }
        let frameRate = Double(dsdRateHz) / 16.0
        guard deviceSampleRates.contains(where: { abs($0 - frameRate) < 0.5 }) else {
            return .pcmDecode
        }
        return .native(dopFrameRateHz: frameRate)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `scripts/test.sh --filter DSDOutputPolicyTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/CrateDiggerCore/Services/DSDOutputPolicy.swift Tests/CrateDiggerCoreTests/DSDOutputPolicyTests.swift
git commit -m "feat(dop): output policy — mode × DSD rate × device rates → route

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 11: DoPPlaybackEngine

**Files:**
- Create: `Sources/CrateDiggerCore/Services/DoPPlaybackEngine.swift`
- Test: `Tests/CrateDiggerCoreTests/DoPPlaybackEngineTests.swift`

**Interfaces:**
- Consumes: `DSFFile.readInfo`, `DoPPacker`, `DSDLevelMeter`, `PlaybackMeterScale`, `AudioOutputManager` rate APIs (Task 7), `PlaybackEngineProtocol` (internal — same module).
- Produces: `final class DoPPlaybackEngine: PlaybackEngineProtocol` (internal, like `AVPlayerEngine`). Behavior:
  - `replaceCurrentItem(url:)` — reads the DSF header, memory-maps the file (`Data(contentsOf:options:.mappedIfSafe)`), resets the frame cursor, fires `onItemReady` (or `onItemFailed` on any error). DSF only; DFF is a documented non-goal (`canPlay` is decided by the caller via policy anyway).
  - `play()` — resolves the output device (stored UID → `AudioDeviceID`), sets the device's nominal rate to `info.dopFrameRateHz`, builds an `AVAudioEngine` with an `AVAudioSourceNode` (Float32, 2 ch, non-interleaved, at the DoP frame rate) connected **directly to `outputNode`** (no mixer — nothing may touch the samples), starts it. The render block packs DoP words straight from the mapped file at the cursor.
  - `pause()` — stops the engine (DAC drops DoP lock momentarily; acceptable v1 ceiling — proper DoP-silence idling is a follow-up).
  - `seek(toSeconds:)` — cursor = `seconds × dopFrameRateHz` frames, clamped.
  - `setVolume(_:)` / `setEqualizer` / `setMasterGain` — **deliberate no-ops** (bit-perfect; protocol defaults cover EQ/gain, volume is overridden to a no-op with a comment).
  - `setOutputDeviceUID(_:)` — stores the UID; if playing, tears down and rebuilds the engine on the new device.
  - `currentLevels` — `DSDLevelMeter.amplitude` over the block at the cursor per channel → dB (`20·log10`) → `PlaybackMeterScale.position`. `currentSpectrum` — `[]` (no PCM to FFT; the OLED VU shows levels only in native mode).
  - `onPeriodicTime` — a 0.2 s main-queue timer while playing, mirroring `AVPlayerEngine`.
  - End of data → stop + `onItemEnded` on main.
  - DSF block layout honored: channel-interleaved blocks of `blockSizeBytes` — byte for channel c at channel-byte-index i lives at `dataOffset + (i / blockSize) × blockSize × channels + c × blockSize + (i % blockSize)`.

- [ ] **Step 1: Write the failing test** (logic-level: header/cursor/seek/level math — no audio hardware started):

```swift
// Tests/CrateDiggerCoreTests/DoPPlaybackEngineTests.swift
import XCTest
@testable import CrateDiggerCore

final class DoPPlaybackEngineTests: XCTestCase {
    /// Stereo DSD64 DSF, 2 blocks per channel: ch0 = 0xFF, ch1 = 0x69.
    private func makeDSF() throws -> URL {
        var data = Data()
        func le32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func le64(_ v: UInt64) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let block = 4096
        data.append(contentsOf: "DSD ".utf8); le64(28); le64(UInt64(92 + 4 * block)); le64(0)
        data.append(contentsOf: "fmt ".utf8); le64(52); le32(1); le32(0); le32(2); le32(2)
        le32(2_822_400); le32(1); le64(UInt64(2 * block * 8)); le32(UInt32(block)); le32(0)
        data.append(contentsOf: "data".utf8); le64(UInt64(12 + 4 * block))
        data.append(Data(repeating: 0xFF, count: block))   // ch0 block 0
        data.append(Data(repeating: 0x69, count: block))   // ch1 block 0
        data.append(Data(repeating: 0xFF, count: block))   // ch0 block 1
        data.append(Data(repeating: 0x69, count: block))   // ch1 block 1
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dop-\(UUID().uuidString).dsf")
        try data.write(to: url)
        return url
    }

    func testLoadReportsDurationAndReady() throws {
        let url = try makeDSF()
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = DoPPlaybackEngine()
        let ready = expectation(description: "ready")
        engine.onItemReady = { ready.fulfill() }
        engine.replaceCurrentItem(url: url)
        wait(for: [ready], timeout: 5)
        XCTAssertEqual(engine.durationSeconds, Double(2 * 4096 * 8) / 2_822_400, accuracy: 1e-6)
        XCTAssertEqual(engine.currentTimeSeconds, 0)
    }

    func testSeekClampsAndMoves() throws {
        let url = try makeDSF()
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = DoPPlaybackEngine()
        let ready = expectation(description: "ready")
        engine.onItemReady = { ready.fulfill() }
        engine.replaceCurrentItem(url: url)
        wait(for: [ready], timeout: 5)
        engine.seek(toSeconds: engine.durationSeconds / 2)
        XCTAssertEqual(engine.currentTimeSeconds, engine.durationSeconds / 2, accuracy: 0.001)
        engine.seek(toSeconds: 999)
        XCTAssertEqual(engine.currentTimeSeconds, engine.durationSeconds, accuracy: 0.001)
        engine.seek(toSeconds: -5)
        XCTAssertEqual(engine.currentTimeSeconds, 0)
    }

    func testLevelsReflectChannelContent() throws {
        let url = try makeDSF()
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = DoPPlaybackEngine()
        let ready = expectation(description: "ready")
        engine.onItemReady = { ready.fulfill() }
        engine.replaceCurrentItem(url: url)
        wait(for: [ready], timeout: 5)
        let levels = engine.currentLevels
        // ch0 all-ones = full scale; ch1 0x69 = DSD silence.
        XCTAssertGreaterThan(levels.left, 0.5)
        XCTAssertEqual(levels.right, 0, accuracy: 0.01)
    }

    func testFailedLoadFiresOnItemFailed() {
        let engine = DoPPlaybackEngine()
        let failed = expectation(description: "failed")
        engine.onItemFailed = { _ in failed.fulfill() }
        engine.replaceCurrentItem(url: URL(fileURLWithPath: "/no/such/file.dsf"))
        wait(for: [failed], timeout: 5)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `scripts/test.sh --filter DoPPlaybackEngineTests`
Expected: FAIL — `cannot find 'DoPPlaybackEngine' in scope`.

- [ ] **Step 3: Implement**

```swift
// Sources/CrateDiggerCore/Services/DoPPlaybackEngine.swift
import AVFoundation
import Foundation

/// Bit-perfect DSD playback via DoP: memory-maps a DSF, packs DoP frames in the
/// render callback, and feeds them through an AVAudioSourceNode wired STRAIGHT
/// to the output node at the DoP frame rate. Nothing on this path may modify
/// samples — volume, EQ, and master gain are deliberate no-ops (a corrupted
/// marker stream degrades to PCM noise on the DAC).
final class DoPPlaybackEngine: PlaybackEngineProtocol {
    var onItemReady: (() -> Void)?
    var onItemFailed: ((String) -> Void)?
    var onItemEnded: (() -> Void)?
    var onPeriodicTime: ((Double, Double) -> Void)?

    private let outputManager = AudioOutputManager()
    private var audioEngine: AVAudioEngine?
    private var sourceNode: AVAudioSourceNode?
    private var timeTimer: Timer?
    private var outputDeviceUID: String?

    private var info: DSFInfo?
    private var mapped: Data?
    /// Current playback position in DoP frames (16 DSD bits per frame/channel).
    /// Accessed from the render thread and main thread; monotonic Int64 ops on
    /// a serial "one writer" pattern (render advances, seek stores) — protected
    /// by a lock kept deliberately tiny.
    private let cursorLock = NSLock()
    private var frameCursor: Int64 = 0
    private var isPlaying = false

    private var totalFrames: Int64 {
        guard let info else { return 0 }
        return info.dataByteCountPerChannel / 2
    }

    var currentTimeSeconds: Double {
        guard let info else { return 0 }
        cursorLock.lock(); defer { cursorLock.unlock() }
        return Double(frameCursor) / info.dopFrameRateHz
    }

    var durationSeconds: Double { info?.durationSeconds ?? 0 }

    func replaceCurrentItem(url: URL) {
        stopEngine()
        do {
            let info = try DSFFile.readInfo(url: url)
            guard info.channelCount == 2, info.lsbFirst else {
                throw DSFReadError.malformedHeader   // stereo LSB-first DSF only (v1)
            }
            self.mapped = try Data(contentsOf: url, options: .mappedIfSafe)
            self.info = info
            cursorLock.lock(); frameCursor = 0; cursorLock.unlock()
            DispatchQueue.main.async { self.onItemReady?() }
        } catch {
            self.info = nil
            self.mapped = nil
            DispatchQueue.main.async { self.onItemFailed?("DSD native load failed: \(error.localizedDescription)") }
        }
    }

    func play() {
        guard let info, mapped != nil else { return }
        if audioEngine == nil {
            do { try buildEngine(frameRate: info.dopFrameRateHz) } catch {
                onItemFailed?("DSD native output failed: \(error.localizedDescription)")
                return
            }
        }
        isPlaying = true
        startTimeTimer()
    }

    func pause() {
        isPlaying = false
        timeTimer?.invalidate(); timeTimer = nil
    }

    func seek(toSeconds seconds: Double) {
        guard let info else { return }
        let target = Int64((seconds * info.dopFrameRateHz).rounded())
        cursorLock.lock()
        frameCursor = max(0, min(target, totalFrames))
        cursorLock.unlock()
    }

    /// Bit-perfect: the volume knob must not scale DoP samples.
    func setVolume(_ volume: Double) {}

    func setOutputDeviceUID(_ uid: String?) {
        outputDeviceUID = uid
        if audioEngine != nil {
            stopEngine()
            if isPlaying { play() }
        }
    }

    var currentLevels: (left: Double, right: Double) {
        guard let info, let mapped else { return (0, 0) }
        cursorLock.lock(); let frame = frameCursor; cursorLock.unlock()
        let window = info.blockSizeBytes
        func level(channel: Int) -> Double {
            let start = channelByteOffset(channelByteIndex: frame * 2, channel: channel, info: info)
            guard start + window <= mapped.count else { return 0 }
            let amplitude = DSDLevelMeter.amplitude(of: mapped[start..<start + window])
            guard amplitude > 0 else { return 0 }
            return PlaybackMeterScale.position(fromDecibels: 20 * log10(amplitude))
        }
        return (level(channel: 0), level(channel: 1))
    }

    var currentSpectrum: [Double] { [] }

    // MARK: - Engine plumbing

    private func buildEngine(frameRate: Double) throws {
        // Lock the DEVICE to the DoP rate first — any SRC destroys the markers.
        if let deviceID = outputManager.deviceID(forUID: outputDeviceUID) {
            outputManager.setNominalSampleRate(frameRate, deviceID: deviceID)
        }
        let engine = AVAudioEngine()
        if let deviceID = outputManager.deviceID(forUID: outputDeviceUID),
           let audioUnit = engine.outputNode.audioUnit {
            var mutableID = deviceID
            AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_CurrentDevice,
                                 kAudioUnitScope_Global, 0, &mutableID,
                                 UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: frameRate,
                                         channels: 2, interleaved: false) else {
            throw DSFReadError.malformedHeader
        }
        let node = AVAudioSourceNode(format: format) { [weak self] _, _, frameCount, buffers -> OSStatus in
            self?.render(frameCount: Int(frameCount), buffers: buffers) ?? noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.outputNode, format: format)
        try engine.start()
        audioEngine = engine
        sourceNode = node
    }

    private func stopEngine() {
        timeTimer?.invalidate(); timeTimer = nil
        if let engine = audioEngine {
            engine.stop()
            if let node = sourceNode { engine.detach(node) }
        }
        audioEngine = nil
        sourceNode = nil
    }

    /// DSF interleaves fixed-size per-channel blocks: [ch0 4096][ch1 4096]….
    private func channelByteOffset(channelByteIndex: Int64, channel: Int, info: DSFInfo) -> Int {
        let block = Int64(info.blockSizeBytes)
        let blockIndex = channelByteIndex / block
        let within = channelByteIndex % block
        return Int(info.dataOffset
            + blockIndex * block * Int64(info.channelCount)
            + Int64(channel) * block
            + within)
    }

    private func render(frameCount: Int, buffers: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        let abl = UnsafeMutableAudioBufferListPointer(buffers)
        guard abl.count >= 2,
              let left = abl[0].mData?.assumingMemoryBound(to: Float.self),
              let right = abl[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
        guard isPlaying, let info, let mapped else {
            for i in 0..<frameCount { left[i] = 0; right[i] = 0 }
            return noErr
        }
        cursorLock.lock()
        var frame = frameCursor
        cursorLock.unlock()
        var ended = false
        mapped.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            for i in 0..<frameCount {
                if frame >= totalFrames {
                    // DoP idle: keep valid markers with DSD silence so the DAC
                    // holds lock instead of clicking out.
                    let marker = DoPPacker.markers[Int(frame & 1)]
                    let silence = DoPPacker.float(fromWord: DoPPacker.word(
                        marker: marker, older: 0x69, newer: 0x69, lsbFirst: false))
                    left[i] = silence; right[i] = silence
                    ended = true
                    continue
                }
                let marker = DoPPacker.markers[Int(frame & 1)]
                let byteIndex = frame * 2
                let l0 = bytes[channelByteOffset(channelByteIndex: byteIndex, channel: 0, info: info)]
                let l1 = bytes[channelByteOffset(channelByteIndex: byteIndex + 1, channel: 0, info: info)]
                let r0 = bytes[channelByteOffset(channelByteIndex: byteIndex, channel: 1, info: info)]
                let r1 = bytes[channelByteOffset(channelByteIndex: byteIndex + 1, channel: 1, info: info)]
                left[i] = DoPPacker.float(fromWord: DoPPacker.word(
                    marker: marker, older: l0, newer: l1, lsbFirst: info.lsbFirst))
                right[i] = DoPPacker.float(fromWord: DoPPacker.word(
                    marker: marker, older: r0, newer: r1, lsbFirst: info.lsbFirst))
                frame += 1
            }
        }
        cursorLock.lock()
        frameCursor = frame
        cursorLock.unlock()
        if ended {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isPlaying else { return }
                self.pause()
                self.onItemEnded?()
            }
        }
        return noErr
    }

    private func startTimeTimer() {
        timeTimer?.invalidate()
        timeTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.onPeriodicTime?(self.currentTimeSeconds, self.durationSeconds)
        }
    }

    deinit {
        stopEngine()
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `scripts/test.sh --filter DoPPlaybackEngineTests`
Expected: PASS (4 tests — none of them start the AVAudioEngine; hardware behavior is Task 14).

- [ ] **Step 5: Commit**

```bash
git add Sources/CrateDiggerCore/Services/DoPPlaybackEngine.swift Tests/CrateDiggerCoreTests/DoPPlaybackEngineTests.swift
git commit -m "feat(dop): DoPPlaybackEngine — mmap DSF, pack DoP frames straight to the output node

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 12: PlaybackService dual-engine routing

**Files:**
- Modify: `Sources/CrateDiggerCore/Services/PlaybackService.swift`
- Test: `Tests/CrateDiggerCoreTests/PlaybackServiceDoPTests.swift` (create)

**Interfaces:**
- Consumes: `DSDOutputPolicy`, `DSFFile`, `DoPPlaybackEngine`, `AudioOutputManager` (rates).
- Produces on `PlaybackService`:
  - `init(engine:decoder:nativeDSDEngine:deviceRatesProvider:)` — new optional params, defaults `nil` / AudioOutputManager-backed provider; convenience `init()` gains `nativeDSDEngine: DoPPlaybackEngine()`.
  - `public var dsdOutputMode: DSDOutputMode` (default `.auto`)
  - `public private(set) var isNativeDSDActive: Bool`
  - Also added to `PlaybackServiceProtocol`: `var dsdOutputMode: DSDOutputMode { get set }`, `var isNativeDSDActive: Bool { get }`.
- Routing in `startItem`: a `.dsf` URL whose policy says `.native` goes to the native engine (raw URL, no decode, no temp file); everything else follows the existing decode-or-direct path on the AVPlayer engine. The inactive engine is paused on every switch. Transport (`play/pause/seek/setVolume/setOutputDeviceUID/currentLevels/currentSpectrum`) forwards to the ACTIVE engine (`setOutputDeviceUID` also updates the stored UID and reaches both engines). `setEqualizer`/`setMasterGain` stay on the AVPlayer engine only. Native-engine `onItemFailed` falls back to the PCM decode path once per generation (resilience: a DoP failure must not kill playback).

- [ ] **Step 1: Write the failing test**

```swift
// Tests/CrateDiggerCoreTests/PlaybackServiceDoPTests.swift
import XCTest
@testable import CrateDiggerCore

private final class SpyEngine: PlaybackEngineProtocol {
    var onItemReady: (() -> Void)?
    var onItemFailed: ((String) -> Void)?
    var onItemEnded: (() -> Void)?
    var onPeriodicTime: ((Double, Double) -> Void)?
    var currentTimeSeconds: Double = 0
    var durationSeconds: Double = 0
    private(set) var replacedURLs: [URL] = []
    private(set) var playCount = 0
    private(set) var pauseCount = 0
    private(set) var seeks: [Double] = []
    func replaceCurrentItem(url: URL) { replacedURLs.append(url) }
    func play() { playCount += 1 }
    func pause() { pauseCount += 1 }
    func seek(toSeconds seconds: Double) { seeks.append(seconds) }
    func setVolume(_ volume: Double) {}
    func setOutputDeviceUID(_ uid: String?) {}
}

private func dsfFixture() throws -> URL {
    var data = Data()
    func le32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    func le64(_ v: UInt64) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    data.append(contentsOf: "DSD ".utf8); le64(28); le64(UInt64(92 + 8192)); le64(0)
    data.append(contentsOf: "fmt ".utf8); le64(52); le32(1); le32(0); le32(2); le32(2)
    le32(2_822_400); le32(1); le64(4096 * 8); le32(4096); le32(0)
    data.append(contentsOf: "data".utf8); le64(12 + 8192)
    data.append(Data(repeating: 0x69, count: 8192))
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("route-\(UUID().uuidString).dsf")
    try data.write(to: url)
    return url
}

final class PlaybackServiceDoPTests: XCTestCase {
    private func makeService(rates: [Double]) throws -> (PlaybackService, SpyEngine, SpyEngine, URL) {
        let av = SpyEngine()
        let native = SpyEngine()
        let dsf = try dsfFixture()
        let service = PlaybackService(engine: av, decoder: nil, nativeDSDEngine: native,
                                      deviceRatesProvider: { _ in rates })
        return (service, av, native, dsf)
    }

    func testDSFRoutesToNativeEngineWhenDeviceSupportsRate() throws {
        let (service, av, native, dsf) = try makeService(rates: [176_400])
        defer { try? FileManager.default.removeItem(at: dsf) }
        service.load(queue: [PlaybackQueueItem(url: dsf, title: "t", artist: "a",
                                               album: "b", durationSeconds: 10)],
                     startIndex: 0, autoPlay: false)
        XCTAssertEqual(native.replacedURLs, [dsf], "raw DSF goes to the native engine")
        XCTAssertTrue(av.replacedURLs.isEmpty)
        XCTAssertTrue(service.isNativeDSDActive)
    }

    func testDSFFallsBackToAVEngineWhenDeviceLacksRate() throws {
        let (service, av, native, dsf) = try makeService(rates: [44_100, 48_000])
        defer { try? FileManager.default.removeItem(at: dsf) }
        service.load(queue: [PlaybackQueueItem(url: dsf, title: "t", artist: "a",
                                               album: "b", durationSeconds: 10)],
                     startIndex: 0, autoPlay: false)
        // No decoder injected → the DSF goes to the AV engine directly (the
        // decode path is exercised by PlaybackServiceDSDTests).
        XCTAssertEqual(av.replacedURLs, [dsf])
        XCTAssertTrue(native.replacedURLs.isEmpty)
        XCTAssertFalse(service.isNativeDSDActive)
    }

    func testPCMModeNeverRoutesNative() throws {
        let (service, av, native, dsf) = try makeService(rates: [176_400])
        defer { try? FileManager.default.removeItem(at: dsf) }
        service.dsdOutputMode = .pcm
        service.load(queue: [PlaybackQueueItem(url: dsf, title: "t", artist: "a",
                                               album: "b", durationSeconds: 10)],
                     startIndex: 0, autoPlay: false)
        XCTAssertEqual(av.replacedURLs, [dsf])
        XCTAssertTrue(native.replacedURLs.isEmpty)
    }

    func testTransportForwardsToActiveEngineAndSwitchPausesOther() throws {
        let (service, av, native, dsf) = try makeService(rates: [176_400])
        defer { try? FileManager.default.removeItem(at: dsf) }
        let flac = URL(fileURLWithPath: "/x/song.flac")
        service.load(queue: [PlaybackQueueItem(url: dsf, title: "t", artist: "a",
                                               album: "b", durationSeconds: 10),
                             PlaybackQueueItem(url: flac, title: "t2", artist: "a",
                                               album: "b", durationSeconds: 10)],
                     startIndex: 0, autoPlay: false)
        service.play()
        XCTAssertEqual(native.playCount, 1)
        XCTAssertEqual(av.playCount, 0)
        service.seek(toSeconds: 3)
        XCTAssertEqual(native.seeks, [3])

        service.next()   // flac → AV engine becomes active, native pauses
        XCTAssertEqual(av.replacedURLs, [flac])
        XCTAssertGreaterThanOrEqual(native.pauseCount, 1)
        XCTAssertFalse(service.isNativeDSDActive)
        service.play()
        XCTAssertEqual(av.playCount, 1)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `scripts/test.sh --filter PlaybackServiceDoPTests`
Expected: FAIL — no `init(engine:decoder:nativeDSDEngine:deviceRatesProvider:)`.

- [ ] **Step 3: Implement** — in `PlaybackService.swift`:

Protocol additions (`PlaybackServiceProtocol`):

```swift
    /// How DSD files reach the output: bit-perfect DoP when possible (.auto/.native)
    /// or always decode to PCM (.pcm).
    var dsdOutputMode: DSDOutputMode { get set }
    /// True while the current track plays through the native (DoP) engine.
    var isNativeDSDActive: Bool { get }
```

Stored properties + init changes on `PlaybackService`:

```swift
    private let nativeDSDEngine: PlaybackEngineProtocol?
    private let deviceRatesProvider: (String?) -> [Double]
    private var activeEngine: PlaybackEngineProtocol
    private var lastOutputDeviceUID: String?
    /// One PCM fallback per generation when the native engine fails.
    private var nativeFallbackGeneration = -1
    public var dsdOutputMode: DSDOutputMode = .auto
    public private(set) var isNativeDSDActive = false

    public convenience init() {
        self.init(engine: AVPlayerEngine(), decoder: FFmpegDSDDecoder(),
                  nativeDSDEngine: DoPPlaybackEngine())
    }

    init(engine: PlaybackEngineProtocol,
         decoder: DSDPlaybackDecoding? = nil,
         nativeDSDEngine: PlaybackEngineProtocol? = nil,
         deviceRatesProvider: ((String?) -> [Double])? = nil) {
        self.engine = engine
        self.decoder = decoder
        self.nativeDSDEngine = nativeDSDEngine
        self.activeEngine = engine
        self.deviceRatesProvider = deviceRatesProvider ?? { uid in
            let manager = AudioOutputManager()
            guard let id = manager.deviceID(forUID: uid) else { return [] }
            return manager.availableSampleRates(deviceID: id)
        }
        bindEngineCallbacks(to: engine)
        if let nativeDSDEngine { bindEngineCallbacks(to: nativeDSDEngine) }
    }
```

`bindEngineCallbacks` becomes per-engine, and every callback body starts with a stale-engine guard so the inactive engine can't drive state:

```swift
    private func bindEngineCallbacks(to boundEngine: PlaybackEngineProtocol) {
        boundEngine.onItemReady = { [weak self, weak boundEngine] in
            guard let self, let boundEngine, boundEngine === self.activeEngine else { return }
            // (existing onItemReady body)
        }
        boundEngine.onItemFailed = { [weak self, weak boundEngine] message in
            guard let self, let boundEngine, boundEngine === self.activeEngine else { return }
            // NEW: native failure → one-shot PCM fallback for this generation.
            if boundEngine === self.nativeDSDEngine,
               self.nativeFallbackGeneration != self.loadGeneration,
               let index = self.currentIndex, self.queue.indices.contains(index) {
                self.nativeFallbackGeneration = self.loadGeneration
                self.switchActiveEngine(to: self.engine)
                self.startPCMItem(url: self.queue[index].url, generation: self.loadGeneration)
                return
            }
            // (existing onItemFailed body)
        }
        // …same guard pattern for onItemEnded and onPeriodicTime…
    }

    private func switchActiveEngine(to newEngine: PlaybackEngineProtocol) {
        guard newEngine !== activeEngine else { return }
        activeEngine.pause()
        activeEngine = newEngine
        isNativeDSDActive = newEngine === nativeDSDEngine
    }
```

`startItem` grows the native branch (rename the existing decode-or-direct body to `startPCMItem(url:generation:)` and call it from the else):

```swift
    private func startItem(url: URL, generation: Int) {
        if let native = nativeDSDEngine,
           url.pathExtension.lowercased() == "dsf",
           dsdOutputMode != .pcm,
           let dsfInfo = try? DSFFile.readInfo(url: url),
           case .native = DSDOutputPolicy.route(mode: dsdOutputMode,
                                                dsdRateHz: dsfInfo.dsdSampleRateHz,
                                                channelCount: dsfInfo.channelCount,
                                                deviceSampleRates: deviceRatesProvider(lastOutputDeviceUID)) {
            switchActiveEngine(to: native)
            replaceTemp(with: nil)
            native.replaceCurrentItem(url: url)
            return
        }
        switchActiveEngine(to: engine)
        isNativeDSDActive = false
        startPCMItem(url: url, generation: generation)
    }
```

Transport forwarding: change every direct `engine.play()/pause()/seek/setVolume` call in the service's public methods to `activeEngine.…`; `setOutputDeviceUID(_ uid:)` stores `lastOutputDeviceUID = uid` and forwards to BOTH engines; `currentLevels()`/`currentSpectrum()` read from `activeEngine`; `setEqualizer`/`setMasterGain` keep targeting `engine` (the AVPlayer one — EQ never applies to the bit-perfect path).

- [ ] **Step 4: Run the playback suites**

Run: `scripts/test.sh --filter "PlaybackServiceDoPTests|PlaybackServiceDSDTests|PlaybackServiceTests"`
Expected: PASS — new routing green, existing decode-interception and transport suites unchanged (they construct `PlaybackService(engine:decoder:)` with no native engine → routing never triggers).

- [ ] **Step 5: Commit**

```bash
git add Sources/CrateDiggerCore/Services/PlaybackService.swift Tests/CrateDiggerCoreTests/PlaybackServiceDoPTests.swift
git commit -m "feat(dop): route DSD tracks to the native engine by output policy

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 13: Preference, Playback menu, OLED notice (App)

**Files:**
- Modify: `Sources/CrateDiggerCore/Services/PreferencesStore.swift` — key + accessor
- Modify: `Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel.swift` — published mode, push into playback, restore at launch, notice
- Modify: `Sources/CrateDiggerApp/AppDelegate.swift` — Playback ▸ DSD Output submenu

**Interfaces:**
- Consumes: `DSDOutputMode` (Task 10), `playback.dsdOutputMode`/`isNativeDSDActive` (Task 12), the `AppearanceMode` menu pattern (representedObject rawValue + `validateMenuItem` checkmark), `showOLEDNotice(_:)`.
- No Core logic — UI glue layer; verified in Task 14.

- [ ] **Step 1: PreferencesStore** — add to `Key`: `static let dsdOutputMode = "cratedigger.playback.dsdOutputMode"` and the accessor (house pattern):

```swift
    public var savedDSDOutputMode: String? {
        get { defaults.string(forKey: Key.dsdOutputMode) }
        set {
            if let value = newValue { defaults.set(value, forKey: Key.dsdOutputMode) }
            else { defaults.removeObject(forKey: Key.dsdOutputMode) }
        }
    }
```

- [ ] **Step 2: LibraryViewModel** — published property with `didSet` (next to `repeatMode`):

```swift
    @Published var dsdOutputMode: DSDOutputMode = .auto {
        didSet {
            prefs.savedDSDOutputMode = dsdOutputMode.rawValue
            playback.dsdOutputMode = dsdOutputMode
        }
    }
```

Restore in the launch-restore block (next to the `savedRepeatMode` restore):

```swift
        if let saved = prefs.savedDSDOutputMode, let mode = DSDOutputMode(rawValue: saved) {
            dsdOutputMode = mode
        }
```

In `wirePlaybackBindings()`'s `onStateChange`, extend the existing DSD notice: when `.loading`/`.playing` of a DSD track and `playback.isNativeDSDActive`, show `showOLEDNotice("DSD ► BIT-PERFECT")` instead of the decode notice (native path does not decode).

- [ ] **Step 3: AppDelegate** — in the Playback menu build, add a "DSD Output" submenu with three items (`Auto`, `PCM (Compatible)`, `Native (Bit-Perfect)`), each `representedObject = DSDOutputMode.<case>.rawValue`, action:

```swift
    @objc func setDSDOutputMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = DSDOutputMode(rawValue: raw) else { return }
        mainWindowController?.setDSDOutputMode(mode)
    }
```

`validateMenuItem`: checkmark the item whose rawValue matches the view model's current mode (mirror the `setStreamEngine` reflect pattern). `MainWindowController.setDSDOutputMode(_:)` forwards to `libraryViewModel.dsdOutputMode = mode`. Import `CrateDiggerCore` where needed.

- [ ] **Step 4: Build + full suite**

Run: `swift build && scripts/test.sh`
Expected: build complete, all tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/CrateDiggerCore/Services/PreferencesStore.swift Sources/CrateDiggerApp
git commit -m "feat(dop): Playback ▸ DSD Output menu (Auto / PCM / Native) + OLED notice

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 14: End-to-end verification on the XD05 (manual)

**Files:** none (verification only). Needs the xDuoo XD05 connected via USB and a real DSF (Task 6 produced `…/Pink Floyd/[2011] - Wish You Were Here/`).

- [ ] **Step 1: Sanity-check the device rates the policy will see**

Temporarily via a scratch test or `swift repl` is overkill — instead verify in-app: with the XD05 selected, Auto mode, play a DSF and observe the route (Step 2). If it unexpectedly PCM-decodes, print `AudioOutputManager().availableSampleRates(deviceID:)` for the XD05 from a scratch XCTest to confirm 176 400 is reported.

- [ ] **Step 2: DoP lock check**

1. Launch the app, select the XD05 as output, DSD Output = Auto.
2. Play a DSD64 track. Expected: the XD05's display/LED shows **DSD** (DoP lock), not PCM 176.4 — this is the bit-perfect proof. OLED shows "DSD ► BIT-PERFECT".
3. Music sounds correct (no hiss/noise — noise means corrupted markers).

- [ ] **Step 3: Transport + fallback matrix**

- Seek ±8s during native playback — position moves, audio continues, DoP lock holds.
- Track auto-advance DSF → DSF (stays native) and DSF → FLAC (switches to AVPlayer engine; EQ/meters return).
- Volume knob during native playback: audio level does NOT change (bit-perfect — document this as intended in the commit).
- DSD Output = PCM: same track now decodes (OLED "DECODING DSD…", XD05 shows PCM 88.2).
- Switch output to built-in speakers, Auto mode: DSF falls back to PCM decode (no 176.4k on built-in).
- Pause/resume native playback.

- [ ] **Step 4: Record results**

Note DoP lock confirmation, any latency/clicks on start/seek/track-change, and the fallback behaviors in the PR description. Any hardware misbehavior (no lock, noise) → stop and reassess before merging; the `.pcm` mode is the safe escape hatch.

---

## Self-Review

**Spec coverage:**
- Phase 1 "SACD ISO → DSF import, rip as physical album, locate-only tool" → Tasks 2 (locator) + 3 (detection) + 4 (metadata) + 5 (extraction) + 6 (menu flow, CD-rip-style OLED progress, Prep Crate landing, missing-tool recipe alert). ✅
- User decision "locate-only, never bundle" → Global Constraints + Task 6 alert copy. ✅
- Phase 3B "DoP Native mode, Auto/PCM/Native, capability detection + fallback" → Tasks 7 (device rates) + 10 (policy) + 11 (engine) + 12 (routing + failure fallback) + 13 (menu/pref). ✅
- "VU/EQ need rework off the mixer" → resolved as: EQ/volume deliberately inert on the bit-perfect path (Global Constraints), VU via popcount duty-cycle metering (Tasks 9, 11), spectrum empty in native mode. ✅
- Latent bug found during evidence gathering (ffprobe byte-rates) → Task 1. ✅
- Blocking-subprocess rule → `SACDExtractService.workQueue` (Task 5). ✅

**Placeholder scan:** Task 9's `PlaybackMeterScale` body says "moved verbatim" — that is a move instruction of existing code, not a placeholder. Task 12 shows the changed regions and names the untouched existing bodies as "(existing … body)" — acceptable for a modify-in-place task where the executor sees the real file. No TBDs.

**Type consistency:** `DSFInfo.dopFrameRateHz` (Task 8) consumed by Tasks 11–12; `DSDOutputPolicy.route(mode:dsdRateHz:channelCount:deviceSampleRates:)` signature identical in Tasks 10 and 12; `DoPPacker.word(marker:older:newer:lsbFirst:)`/`float(fromWord:)` identical in Tasks 9 and 11; `SACDExtractService.extractStereoTracks(iso:trackNumbers:to:onTrackDone:completion:)` identical in Tasks 5 and 6; `ExternalTool.sacdExtract` (Task 2) used in Task 6. ✅

**Known ceilings (deliberate, documented in code):** DoP v1 is stereo DSF only (DFF native → PCM path); pause drops DoP lock momentarily; end-of-track idles with DoP silence; `sacd_extract` failure mid-album leaves already-extracted tracks in place (re-running skips existing files).
