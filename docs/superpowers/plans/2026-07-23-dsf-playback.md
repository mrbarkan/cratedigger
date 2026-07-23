# DSF Playback (Phases 2 + 3A) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make DSF/DFF (DSD) files first-class in the library and play them directly — originals never converted — by decoding DSD→PCM on the fly and feeding the existing AVPlayer path.

**Architecture:** DSF is added to the scanner's supported set so it browses like any other format, with a clean "DSD64/DSD128" label derived from the DSD sample rate. Playback stays on `AVPlayer` (so VU meters, the 12-band EQ, seek, scrobble, and output-device selection keep working unchanged): a new `DSDPlaybackDecoding` seam in `PlaybackService` intercepts a DSD URL, decodes it to a temporary PCM file with the already-bundled ffmpeg **on a dedicated queue** (never the Swift cooperative pool), and hands AVPlayer the temp file. The user's `.dsf` archive is read-only throughout; the temp is discarded on track change.

**Tech Stack:** Swift, AVFoundation (`AVPlayer`), bundled `ffmpeg` (DSD decoders `dsd_msbf`/`dsd_lsbf` confirmed present), `CommandRunning` (existing injectable subprocess runner), XCTest via `scripts/test.sh`.

## Global Constraints

- **Platform:** macOS 13+. Swift Package Manager, two targets.
- **Two-target boundary:** testable logic goes in `CrateDiggerCore` (`Sources/CrateDiggerCore`); UI glue in `CrateDiggerApp`. New Core types are `public`.
- **Tests:** run with `scripts/test.sh` (NOT bare `swift test`). Single class: `scripts/test.sh --filter <ClassName>`.
- **No new dependencies:** ffmpeg is already resolved via `ExternalToolLocator` (`ExternalTool.ffmpeg`) and bundled in the packaged app.
- **Blocking subprocess rule (hard):** ffmpeg's `CommandRunning.run` blocks its thread. It MUST run on a dedicated `DispatchQueue`, never awaited on the Swift cooperative pool — parking pool threads deadlocks the app (this exact class of bug was fixed 2026-07-22 in `LibraryScanService.probeQueue`).
- **Archive is read-only:** never write to, move, or convert the source `.dsf`. All decode output goes to `NSTemporaryDirectory()`.
- **Decode target (fixed for v1):** 24-bit PCM in a CAF container at **88.2 kHz** (transparent for DSD64/DSD128, half the size of 176.4 kHz; AVFoundation-native, no 4 GB WAV limit). Tunable later.
- **Commit trailer:** end every commit message with
  `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`

---

## File Structure

**Phase 2 — DSF as a first-class format**
- Create `Sources/CrateDiggerCore/Services/DSDFormat.swift` — pure helper: is-a-DSD-codec test + `DSD64/DSD128/DSD256` labeling from sample rate.
- Modify `Sources/CrateDiggerCore/Services/LibraryScanService.swift` — add `dsf`/`dff` to `defaultSupportedExtensions`; use `DSDFormat` for `formatName` in `loadTrack`.
- Create `Tests/CrateDiggerCoreTests/DSDFormatTests.swift`.
- Modify `Tests/CrateDiggerCoreTests/LibraryScanServiceTests.swift` — add DSF recognition/labeling test.

**Phase 3A — decode-on-play**
- Create `Sources/CrateDiggerCore/Services/DSDDecoder.swift` — `DSDPlaybackDecoding` protocol + `FFmpegDSDDecoder` (arg building, `canDecode`, off-pool decode via `CommandRunning`).
- Modify `Sources/CrateDiggerCore/Services/PlaybackService.swift` — inject an optional decoder; intercept DSD URLs in the load path with a generation guard + temp-file lifecycle.
- Create `Tests/CrateDiggerCoreTests/DSDDecoderTests.swift`.
- Create `Tests/CrateDiggerCoreTests/PlaybackServiceDSDTests.swift`.
- Modify `Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel.swift` — surface a "DECODING DSD…" OLED notice while a DSD track loads (cosmetic).

---

## Task 1: DSD format labeling (Core)

**Files:**
- Create: `Sources/CrateDiggerCore/Services/DSDFormat.swift`
- Test: `Tests/CrateDiggerCoreTests/DSDFormatTests.swift`

**Interfaces:**
- Produces:
  - `public enum DSDFormat`
  - `public static func isDSDCodec(_ codecName: String?) -> Bool`
  - `public static func label(sampleRateHz: Int?) -> String?` — returns `"DSD64"`, `"DSD128"`, `"DSD256"`, or a generic `"DSD"` for a DSD-range rate that isn't a standard multiple; `nil` for non-DSD rates.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/CrateDiggerCoreTests/DSDFormatTests.swift
import XCTest
@testable import CrateDiggerCore

final class DSDFormatTests: XCTestCase {
    func testStandardRatesMapToLabels() {
        XCTAssertEqual(DSDFormat.label(sampleRateHz: 2_822_400), "DSD64")
        XCTAssertEqual(DSDFormat.label(sampleRateHz: 5_644_800), "DSD128")
        XCTAssertEqual(DSDFormat.label(sampleRateHz: 11_289_600), "DSD256")
    }

    func testNonDSDRateReturnsNil() {
        XCTAssertNil(DSDFormat.label(sampleRateHz: 44_100))
        XCTAssertNil(DSDFormat.label(sampleRateHz: 176_400))
        XCTAssertNil(DSDFormat.label(sampleRateHz: nil))
    }

    func testGenericDSDForNonStandardHighRate() {
        // A DSD-range rate that isn't a clean 64x multiple still reads as DSD.
        XCTAssertEqual(DSDFormat.label(sampleRateHz: 3_000_000), "DSD")
    }

    func testCodecNameDetection() {
        XCTAssertTrue(DSDFormat.isDSDCodec("dsd_lsbf"))
        XCTAssertTrue(DSDFormat.isDSDCodec("DSD_MSBF_PLANAR"))
        XCTAssertFalse(DSDFormat.isDSDCodec("flac"))
        XCTAssertFalse(DSDFormat.isDSDCodec(nil))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `scripts/test.sh --filter DSDFormatTests`
Expected: FAIL — `cannot find 'DSDFormat' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/CrateDiggerCore/Services/DSDFormat.swift
import Foundation

/// Labels DSD streams for display. ffprobe reports a DSD file's audio stream
/// with a `dsd_*` codec and a sample rate that is the 1-bit rate itself
/// (DSD64 = 2 822 400 Hz), not a PCM rate — so the generic format inference
/// would show "DSD_LSBF" / a nonsense kHz. This maps that to "DSD64" etc.
public enum DSDFormat {
    /// Standard 1-bit DSD rates: base 2 822 400 Hz (= 44 100 × 64) × 1/2/4.
    private static let base = 2_822_400

    public static func isDSDCodec(_ codecName: String?) -> Bool {
        guard let name = codecName?.lowercased() else { return false }
        return name.hasPrefix("dsd")
    }

    /// "DSD64" / "DSD128" / "DSD256" for the standard rates, generic "DSD" for
    /// any other rate at or above the DSD64 base, `nil` for ordinary PCM rates.
    public static func label(sampleRateHz: Int?) -> String? {
        guard let rate = sampleRateHz, rate >= base else { return nil }
        switch rate {
        case base: return "DSD64"
        case base * 2: return "DSD128"
        case base * 4: return "DSD256"
        default: return "DSD"
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `scripts/test.sh --filter DSDFormatTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/CrateDiggerCore/Services/DSDFormat.swift Tests/CrateDiggerCoreTests/DSDFormatTests.swift
git commit -m "feat(dsd): DSD sample-rate → DSD64/128/256 labeling helper

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: Recognize DSF/DFF in scanning + apply DSD label

**Files:**
- Modify: `Sources/CrateDiggerCore/Services/LibraryScanService.swift:36-37` (extension set) and `:264-270` (`inferredFormatName` in `loadTrack`)
- Test: `Tests/CrateDiggerCoreTests/LibraryScanServiceTests.swift`

**Interfaces:**
- Consumes: `DSDFormat.isDSDCodec`, `DSDFormat.label` (Task 1).
- Produces: `LibraryScanService.defaultSupportedExtensions` now contains `"dsf"`, `"dff"`. A scanned DSD track's `AudioTrack.formatName` is `"DSD64"` (etc.).

- [ ] **Step 1: Write the failing test**

Add to `Tests/CrateDiggerCoreTests/LibraryScanServiceTests.swift`. This reuses the existing `TitleProbe` fake pattern in that file; here we add a probe that reports a DSD stream. Append this test class to the file:

```swift
final class LibraryScanServiceDSDTests: XCTestCase {
    /// Fake probe that reports a DSD64 audio stream, like ffprobe does for .dsf.
    private final class DSDProbe: MetadataProbing {
        func probe(url: URL) throws -> ProbedMetadata {
            ProbedMetadata(
                formatName: "dsf",
                formatBitRateBps: nil,
                formatTags: ["title": "Test DSD", "artist": "A", "album": "B"],
                streams: [ProbedStreamMetadata(
                    index: 0, codecType: "audio", codecName: "dsd_lsbf",
                    sampleRateHz: 2_822_400, bitRateBps: nil, tags: [:], dispositions: [:])]
            )
        }
    }

    func testDSFExtensionIsSupported() {
        XCTAssertTrue(LibraryScanService.defaultSupportedExtensions.contains("dsf"))
        XCTAssertTrue(LibraryScanService.defaultSupportedExtensions.contains("dff"))
    }

    func testScannedDSFGetsDSDLabel() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dsdscan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // Empty stand-in file; the fake probe supplies the metadata.
        try Data().write(to: dir.appendingPathComponent("01 Track.dsf"))

        let scanner = LibraryScanService(metadataProbe: DSDProbe())
        let tracks = await scanner.scanFolder(dir)

        XCTAssertEqual(tracks.count, 1)
        XCTAssertEqual(tracks.first?.track.formatName, "DSD64")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `scripts/test.sh --filter LibraryScanServiceDSDTests`
Expected: FAIL — `testDSFExtensionIsSupported` fails (set lacks `dsf`), and `testScannedDSFGetsDSDLabel` either finds 0 tracks or `formatName == "DSD_LSBF"`.

- [ ] **Step 3a: Add the extensions**

In `Sources/CrateDiggerCore/Services/LibraryScanService.swift`, change:

```swift
    public static let defaultSupportedExtensions: Set<String> =
        ["mp3", "aac", "m4a", "flac", "wav", "aiff", "ogg", "opus", "caf"]
```

to:

```swift
    public static let defaultSupportedExtensions: Set<String> =
        ["mp3", "aac", "m4a", "flac", "wav", "aiff", "ogg", "opus", "caf", "dsf", "dff"]
```

- [ ] **Step 3b: Prefer the DSD label in `loadTrack`**

In `loadTrack`, the current `inferredFormatName` is:

```swift
        let inferredFormatName = normalizedString(probedMetadata?.primaryAudioStream?.codecName)?.uppercased()
            ?? normalizedString(probedMetadata?.formatName)?
                .split(separator: ",")
                .first
                .map(String.init)?
                .uppercased()
            ?? fileURL.pathExtension.uppercased()
```

Replace it with (DSD wins first, so a `dsd_lsbf` stream shows as `DSD64`, not `DSD_LSBF`):

```swift
        let dsdLabel = DSDFormat.isDSDCodec(probedMetadata?.primaryAudioStream?.codecName)
            ? DSDFormat.label(sampleRateHz: probedMetadata?.primaryAudioStream?.sampleRateHz)
            : nil
        let inferredFormatName = dsdLabel
            ?? normalizedString(probedMetadata?.primaryAudioStream?.codecName)?.uppercased()
            ?? normalizedString(probedMetadata?.formatName)?
                .split(separator: ",")
                .first
                .map(String.init)?
                .uppercased()
            ?? fileURL.pathExtension.uppercased()
```

- [ ] **Step 4: Run test to verify it passes**

Run: `scripts/test.sh --filter LibraryScanServiceDSDTests`
Expected: PASS (2 tests). Then run the whole scan suite to confirm no regression:
Run: `scripts/test.sh --filter LibraryScanServiceTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/CrateDiggerCore/Services/LibraryScanService.swift Tests/CrateDiggerCoreTests/LibraryScanServiceTests.swift
git commit -m "feat(dsd): scan .dsf/.dff and label them DSD64/128/256

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: DSD decoder (Core)

**Files:**
- Create: `Sources/CrateDiggerCore/Services/DSDDecoder.swift`
- Test: `Tests/CrateDiggerCoreTests/DSDDecoderTests.swift`

**Interfaces:**
- Consumes: `CommandRunning`, `CommandOutput`, `ProcessCommandRunner`, `ExternalToolLocator`/`ExternalTool.ffmpeg` (all existing in `ConversionService.swift` / `ExternalToolLocator.swift`).
- Produces:
  - `public protocol DSDPlaybackDecoding: AnyObject`
    - `func canDecode(_ url: URL) -> Bool`
    - `func decode(_ url: URL, completion: @escaping (Result<URL, Error>) -> Void)`
  - `public final class FFmpegDSDDecoder: DSDPlaybackDecoding`
    - `public init(ffmpegURL: URL, commandRunner: CommandRunning = ProcessCommandRunner(), targetSampleRateHz: Int = 88_200)`
    - `public convenience init?(commandRunner: CommandRunning = ProcessCommandRunner())` — resolves ffmpeg; `nil` if missing.
    - `public static let decodableExtensions: Set<String> = ["dsf", "dff"]`
    - `public static func decodeArguments(input: URL, output: URL, sampleRateHz: Int) -> [String]`
  - `public enum DSDDecodeError: Error { case ffmpegFailed(String) }`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/CrateDiggerCoreTests/DSDDecoderTests.swift
import XCTest
@testable import CrateDiggerCore

private struct FakeRunner: CommandRunning {
    let status: Int32
    let stderr: String
    var captured: (@Sendable (URL, [String]) -> Void)?
    func run(executableURL: URL, arguments: [String]) throws -> CommandOutput {
        captured?(executableURL, arguments)
        return CommandOutput(terminationStatus: status, standardOutput: "", standardError: stderr)
    }
}

final class DSDDecoderTests: XCTestCase {
    private let ffmpeg = URL(fileURLWithPath: "/usr/bin/ffmpeg")

    func testCanDecodeOnlyDSD() {
        let d = FFmpegDSDDecoder(ffmpegURL: ffmpeg)
        XCTAssertTrue(d.canDecode(URL(fileURLWithPath: "/x/a.dsf")))
        XCTAssertTrue(d.canDecode(URL(fileURLWithPath: "/x/a.DFF")))
        XCTAssertFalse(d.canDecode(URL(fileURLWithPath: "/x/a.flac")))
    }

    func testDecodeArgumentsAre24BitCAFAtTargetRate() {
        let args = FFmpegDSDDecoder.decodeArguments(
            input: URL(fileURLWithPath: "/in.dsf"),
            output: URL(fileURLWithPath: "/out.caf"),
            sampleRateHz: 88_200)
        // -y -i /in.dsf -map 0:a:0 -c:a pcm_s24le -ar 88200 -f caf /out.caf
        XCTAssertEqual(args, [
            "-y", "-i", "/in.dsf", "-map", "0:a:0",
            "-c:a", "pcm_s24le", "-ar", "88200", "-f", "caf", "/out.caf",
        ])
    }

    func testDecodeSuccessReturnsTempURL() {
        let runner = FakeRunner(status: 0, stderr: "", captured: nil)
        let d = FFmpegDSDDecoder(ffmpegURL: ffmpeg, commandRunner: runner)
        let exp = expectation(description: "decode")
        var out: URL?
        d.decode(URL(fileURLWithPath: "/x/a.dsf")) { result in
            if case .success(let url) = result { out = url }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5)
        XCTAssertEqual(out?.pathExtension, "caf")
        XCTAssertTrue(out?.path.hasPrefix(FileManager.default.temporaryDirectory.path) ?? false)
    }

    func testDecodeFailurePropagatesError() {
        let runner = FakeRunner(status: 1, stderr: "boom", captured: nil)
        let d = FFmpegDSDDecoder(ffmpegURL: ffmpeg, commandRunner: runner)
        let exp = expectation(description: "decode")
        var failed = false
        d.decode(URL(fileURLWithPath: "/x/a.dsf")) { result in
            if case .failure = result { failed = true }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5)
        XCTAssertTrue(failed)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `scripts/test.sh --filter DSDDecoderTests`
Expected: FAIL — `cannot find 'FFmpegDSDDecoder' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/CrateDiggerCore/Services/DSDDecoder.swift
import Foundation

public enum DSDDecodeError: Error {
    case ffmpegFailed(String)
}

/// Resolves a format AVFoundation can't decode (DSD/DSF) to a temporary file it
/// can play. The source is never modified.
public protocol DSDPlaybackDecoding: AnyObject {
    func canDecode(_ url: URL) -> Bool
    /// Decodes `url` to a temp PCM file. `completion` runs on an arbitrary queue.
    func decode(_ url: URL, completion: @escaping (Result<URL, Error>) -> Void)
}

public final class FFmpegDSDDecoder: DSDPlaybackDecoding {
    public static let decodableExtensions: Set<String> = ["dsf", "dff"]

    private let ffmpegURL: URL
    private let commandRunner: CommandRunning
    private let targetSampleRateHz: Int

    // ffmpeg's DSD decode blocks its thread (spawn + waitUntilExit). Keep it OFF
    // the Swift cooperative pool — parking pool threads deadlocks the app
    // (see LibraryScanService.probeQueue, same lesson).
    private static let decodeQueue = DispatchQueue(
        label: "com.cratedigger.dsd-decode", qos: .userInitiated, attributes: .concurrent)

    public init(ffmpegURL: URL,
                commandRunner: CommandRunning = ProcessCommandRunner(),
                targetSampleRateHz: Int = 88_200) {
        self.ffmpegURL = ffmpegURL
        self.commandRunner = commandRunner
        self.targetSampleRateHz = targetSampleRateHz
    }

    public convenience init?(commandRunner: CommandRunning = ProcessCommandRunner()) {
        guard let resolved = ExternalToolLocator().resolveOptional(.ffmpeg) else { return nil }
        self.init(ffmpegURL: resolved.url, commandRunner: commandRunner)
    }

    public func canDecode(_ url: URL) -> Bool {
        Self.decodableExtensions.contains(url.pathExtension.lowercased())
    }

    public static func decodeArguments(input: URL, output: URL, sampleRateHz: Int) -> [String] {
        ["-y", "-i", input.path, "-map", "0:a:0",
         "-c:a", "pcm_s24le", "-ar", String(sampleRateHz), "-f", "caf", output.path]
    }

    public func decode(_ url: URL, completion: @escaping (Result<URL, Error>) -> Void) {
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("cratedigger-dsd-\(UUID().uuidString).caf")
        let args = Self.decodeArguments(input: url, output: output, sampleRateHz: targetSampleRateHz)
        let runner = commandRunner
        let ffmpeg = ffmpegURL
        Self.decodeQueue.async {
            do {
                let result = try runner.run(executableURL: ffmpeg, arguments: args)
                if result.terminationStatus == 0 {
                    completion(.success(output))
                } else {
                    completion(.failure(DSDDecodeError.ffmpegFailed(result.standardError)))
                }
            } catch {
                completion(.failure(error))
            }
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `scripts/test.sh --filter DSDDecoderTests`
Expected: PASS (4 tests).

**Heads-up (non-blocking):** capturing `runner` (an `any CommandRunning`) into `decodeQueue.async` may emit a Sendable *warning* (the package has no strict-concurrency flag, so it's a warning, not an error). Resolve it the same way the 2026-07-22 scan-hang fix resolved the identical case for `MetadataProbing`: mark `public protocol CommandRunning: Sendable` in `ConversionService.swift` (its conformer `ProcessCommandRunner` is already a value-type struct; the test fakes are stateless, so they satisfy it). Only do this if the warning appears.

- [ ] **Step 5: Commit**

```bash
git add Sources/CrateDiggerCore/Services/DSDDecoder.swift Tests/CrateDiggerCoreTests/DSDDecoderTests.swift
git commit -m "feat(dsd): FFmpegDSDDecoder — decode DSF to temp PCM off the pool

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: PlaybackService decode interception

**Files:**
- Modify: `Sources/CrateDiggerCore/Services/PlaybackService.swift`
- Test: `Tests/CrateDiggerCoreTests/PlaybackServiceDSDTests.swift`

**Interfaces:**
- Consumes: `DSDPlaybackDecoding` (Task 3), existing `PlaybackEngineProtocol`.
- Produces: `PlaybackService.init(engine:decoder:)` (decoder optional, default nil); a load path that, for a decodable URL, decodes first and only then calls `engine.replaceCurrentItem(url:)` with the temp URL. Stale decodes (superseded by a newer load) are dropped via a generation counter; the prior temp file is deleted on each new item and on `deinit`.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/CrateDiggerCoreTests/PlaybackServiceDSDTests.swift
import XCTest
@testable import CrateDiggerCore

private final class FakeEngine: PlaybackEngineProtocol {
    var onItemReady: (() -> Void)?
    var onItemFailed: ((String) -> Void)?
    var onItemEnded: (() -> Void)?
    var onPeriodicTime: ((Double, Double) -> Void)?
    var currentTimeSeconds: Double = 0
    var durationSeconds: Double = 0
    private(set) var replacedURLs: [URL] = []
    func replaceCurrentItem(url: URL) { replacedURLs.append(url) }
    func play() {}
    func pause() {}
    func seek(toSeconds: Double) {}
    func setVolume(_ volume: Double) {}
    func setOutputDeviceUID(_ uid: String?) {}
}

/// Decoder whose completion we fire manually, to exercise the async seam.
private final class ManualDecoder: DSDPlaybackDecoding {
    var pending: ((Result<URL, Error>) -> Void)?
    let tempURL = URL(fileURLWithPath: "/tmp/decoded.caf")
    func canDecode(_ url: URL) -> Bool { url.pathExtension.lowercased() == "dsf" }
    func decode(_ url: URL, completion: @escaping (Result<URL, Error>) -> Void) { pending = completion }
    func fireSuccess() { pending?(.success(tempURL)); pending = nil }
}

private func item(_ path: String) -> PlaybackQueueItem {
    PlaybackQueueItem(url: URL(fileURLWithPath: path), title: "t", artist: "a", album: "b", durationSeconds: 100)
}

final class PlaybackServiceDSDTests: XCTestCase {
    func testNonDSDLoadsDirectly() {
        let engine = FakeEngine(); let decoder = ManualDecoder()
        let svc = PlaybackService(engine: engine, decoder: decoder)
        svc.load(queue: [item("/x/song.flac")], startIndex: 0, autoPlay: false)
        XCTAssertEqual(engine.replacedURLs, [URL(fileURLWithPath: "/x/song.flac")])
    }

    func testDSDDecodesBeforeReplacingItem() {
        let engine = FakeEngine(); let decoder = ManualDecoder()
        let svc = PlaybackService(engine: engine, decoder: decoder)
        svc.load(queue: [item("/x/song.dsf")], startIndex: 0, autoPlay: false)
        // Nothing handed to the engine until decode finishes.
        XCTAssertTrue(engine.replacedURLs.isEmpty)
        decoder.fireSuccess()
        XCTAssertEqual(engine.replacedURLs, [decoder.tempURL])
    }

    func testStaleDecodeIsDropped() {
        let engine = FakeEngine(); let decoder = ManualDecoder()
        let svc = PlaybackService(engine: engine, decoder: decoder)
        svc.load(queue: [item("/x/a.dsf"), item("/x/b.flac")], startIndex: 0, autoPlay: false)
        let staleCompletion = decoder.pending          // decode of a.dsf in flight
        svc.next()                                      // user skips to b.flac
        XCTAssertEqual(engine.replacedURLs, [URL(fileURLWithPath: "/x/b.flac")])
        staleCompletion?(.success(decoder.tempURL))     // a.dsf decode lands late
        // The late decode must NOT replace the now-current flac.
        XCTAssertEqual(engine.replacedURLs, [URL(fileURLWithPath: "/x/b.flac")])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `scripts/test.sh --filter PlaybackServiceDSDTests`
Expected: FAIL — `PlaybackService` has no `init(engine:decoder:)`.

- [ ] **Step 3: Modify `PlaybackService`**

In `PlaybackService.swift`, add stored properties next to `private let engine` / `pendingAutoPlay`:

```swift
    private let decoder: DSDPlaybackDecoding?
    /// Bumped on every load/track change; a decode completion is applied only if
    /// its generation still matches, so a superseded decode is dropped.
    private var loadGeneration = 0
    /// The temp file the current item is playing from (nil for a native file).
    /// Deleted when replaced so decodes don't accumulate in the temp dir.
    private var currentTempURL: URL?
```

Replace the two initializers:

```swift
    public convenience init() {
        self.init(engine: AVPlayerEngine())
    }

    init(engine: PlaybackEngineProtocol) {
        self.engine = engine
        bindEngineCallbacks()
    }
```

with:

```swift
    public convenience init() {
        self.init(engine: AVPlayerEngine(), decoder: FFmpegDSDDecoder())
    }

    init(engine: PlaybackEngineProtocol, decoder: DSDPlaybackDecoding? = nil) {
        self.engine = engine
        self.decoder = decoder
        bindEngineCallbacks()
    }

    deinit {
        if let currentTempURL { try? FileManager.default.removeItem(at: currentTempURL) }
    }
```

Add a private helper that routes a URL through the decoder when needed:

```swift
    /// Hand `url` to the engine, decoding DSD to a temp file first when the URL
    /// is a format AVFoundation can't play. `generation` guards against a decode
    /// that finishes after the user has already moved to another track.
    private func startItem(url: URL, generation: Int) {
        if let decoder, decoder.canDecode(url) {
            decoder.decode(url) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self, self.loadGeneration == generation else {
                        // Superseded: drop the result and clean up its temp file.
                        if case .success(let stale) = result {
                            try? FileManager.default.removeItem(at: stale)
                        }
                        return
                    }
                    switch result {
                    case .success(let tempURL):
                        self.replaceTemp(with: tempURL)
                        self.engine.replaceCurrentItem(url: tempURL)
                    case .failure(let error):
                        self.onItemFailedFromDecode(error.localizedDescription)
                    }
                }
            }
        } else {
            replaceTemp(with: nil)
            engine.replaceCurrentItem(url: url)
        }
    }

    private func replaceTemp(with newTemp: URL?) {
        if let currentTempURL, currentTempURL != newTemp {
            try? FileManager.default.removeItem(at: currentTempURL)
        }
        currentTempURL = newTemp
    }

    /// Route a decode failure through the same fallback path AVPlayer failures
    /// use (skip to the next track, or surface the error).
    private func onItemFailedFromDecode(_ message: String) {
        errorMessage = message
        notify { self.onError?(message) }
        if let currentIndex, queue.indices.contains(currentIndex + 1) {
            load(queue: queue, startIndex: currentIndex + 1, autoPlay: pendingAutoPlay)
            return
        }
        state = .failed(message: message)
    }
```

Finally, in `load(...)`, bump the generation and route through `startItem`. Change the final line of the non-empty branch:

```swift
        state = .loading
        engine.replaceCurrentItem(url: queue[clampedIndex].url)
```

to:

```swift
        state = .loading
        loadGeneration += 1
        startItem(url: queue[clampedIndex].url, generation: loadGeneration)
```

Also bump the generation at the top of the empty-queue guard so a pending decode can't fire into an emptied queue. Change:

```swift
        guard !queue.isEmpty else {
            engine.pause()
```

to:

```swift
        guard !queue.isEmpty else {
            loadGeneration += 1
            replaceTemp(with: nil)
            engine.pause()
```

- [ ] **Step 4: Run test to verify it passes**

Run: `scripts/test.sh --filter PlaybackServiceDSDTests`
Expected: PASS (3 tests). Then confirm no playback regressions:
Run: `scripts/test.sh --filter PlaybackServiceTests`
Expected: PASS (existing suite unchanged — non-DSD path still calls `replaceCurrentItem` directly).

- [ ] **Step 5: Commit**

```bash
git add Sources/CrateDiggerCore/Services/PlaybackService.swift Tests/CrateDiggerCoreTests/PlaybackServiceDSDTests.swift
git commit -m "feat(dsd): decode-on-play — PlaybackService routes DSD through ffmpeg to temp PCM

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: "Decoding DSD…" OLED notice (App)

**Files:**
- Modify: `Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel.swift` (playback binding that reacts to `PlaybackState.loading`)

**Interfaces:**
- Consumes: `FFmpegDSDDecoder.decodableExtensions` (Task 3), `showOLEDNotice(_:)` (`LibraryViewModel.swift:1662`), the existing `wirePlaybackBindings()` state handler.

**Note:** No new test — this is a cosmetic notice on an existing `@Published`/callback path, which the CLAUDE.md notes is the untested UI-glue layer. Verified manually in Task 6.

- [ ] **Step 1: Locate the state handler**

Run: `grep -n "onStateChange\|\.loading\|func wirePlaybackBindings" Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel.swift`
Read the `onStateChange` closure inside `wirePlaybackBindings()` so the new branch matches the surrounding style.

- [ ] **Step 2: Add the notice on load of a DSD track**

Inside the `playback.onStateChange` handler, where it maps `PlaybackState` to view-model state, add — when the state becomes `.loading` and the current track is a DSD file — a notice (decode can take a beat, so this tells the user why):

```swift
            if case .loading = state,
               let url = self.currentPlayingTrackURL(),
               FFmpegDSDDecoder.decodableExtensions.contains(url.pathExtension.lowercased()) {
                self.showOLEDNotice("DECODING DSD…")
            }
```

If a `currentPlayingTrackURL()` helper does not already exist, use the current queue item the view model tracks for now-playing (the same source `wirePlaybackBindings` already uses to resolve the playing track — reuse that expression rather than adding a new accessor). The condition only needs the current track's file extension.

- [ ] **Step 3: Build the app**

Run: `swift build`
Expected: `Build complete!` (no errors; the pre-existing `BrandBlock.swift` `#selector` warning is unrelated).

- [ ] **Step 4: Commit**

```bash
git add Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel.swift
git commit -m "feat(dsd): show DECODING DSD… on the OLED while a DSD track loads

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: End-to-end verification with a real DSF (manual)

**Files:** none (verification only).

This is the real proof: a DSF actually plays, with meters, EQ, and seek, on the XD05. It needs one real DSF file — produced from a SACD ISO with the `sacd_extract` binary already built in the scratchpad during the spike.

- [ ] **Step 1: Produce a test DSF** (permission-gated — run yourself with a leading `!` if the classifier blocks it)

```bash
S=/private/tmp/claude-501/-Users-mrbarkan-Development-Code-CrateDigger/751a7eef-7560-4d45-98fe-adbee93aa707/scratchpad
"$S/sacd-ripper/tools/sacd_extract/sacd_extract" -s -2 -c -t 4 \
  -i "/Volumes/DBKN_M1/DOWNS/complete/mfugsilo/Pink Floyd - Wish You Were Here Analogue Productions SACD [CAPP 33453 SA]/Pink Floyd Music Ltd. - Wish You Were Here.iso" \
  -y "$S/sacd-out"
find "$S/sacd-out" -iname "*.dsf"
```

- [ ] **Step 2: Confirm ffprobe reads it as expected**

```bash
ffprobe -v error -show_format -show_streams -of json "<path to .dsf>" | grep -iE "codec_name|sample_rate|duration|TITLE|ARTIST|ALBUM"
```
Expected: a `dsd_lsbf`/`dsd_msbf` audio stream at `sample_rate=2822400`, a real `duration`, and title/artist/album tags. (Confirms Task 2's label + metadata path against a real file.)

- [ ] **Step 3: Confirm the decode command works and produces a playable file**

```bash
S=/private/tmp/.../scratchpad
time ffmpeg -y -i "<path to .dsf>" -map 0:a:0 -c:a pcm_s24le -ar 88200 -f caf "$S/decoded.caf"
afplay "$S/decoded.caf"   # should be audible; note the decode time from `time`
```
Expected: exit 0, an audible CAF. Note the decode duration — if a ~5-min track takes more than a few seconds, capture that number and flag it (the follow-up would be progressive/streamed decode; not in this plan's scope).

- [ ] **Step 4: Play it in the app on the XD05 (PCM)**

1. `swift build && .build/arm64-apple-macosx/debug/CrateDiggerApp` (or launch via Xcode ⌘R).
2. Dig the folder containing the `.dsf` (it now scans in; browser shows it as `DSD64`).
3. Select the XD05 as output device.
4. Press play. Confirm: audio plays, VU meters move, the 12-band EQ affects the sound, and ±8s seek works. The `.dsf` on disk is unchanged (check its mtime).

- [ ] **Step 5: Record the result**

Note in the PR/commit description: decode latency for the test track, that meters/EQ/seek work through the decoded path, and that the source DSF was untouched. If decode latency is high, open a follow-up issue for streamed decode.

---

## Self-Review

**Spec coverage:**
- Phase 2 "DSF as a first-class format" → Tasks 1 (label) + 2 (scan recognition + label applied). ✅
- Phase 3A "decode-on-play, keep originals, reuse AVPlayer stack" → Tasks 3 (decoder, off-pool) + 4 (PlaybackService interception, temp lifecycle, stale-drop) + 5 (loading notice). ✅
- "Archive never modified" → decode writes only to `NSTemporaryDirectory()`; Task 6 Step 4 verifies source mtime unchanged. ✅
- "Works on any output incl. XD05 in PCM" → AVPlayer path unchanged; Task 6 verifies on the XD05. ✅
- "Blocking subprocess off the cooperative pool" → `FFmpegDSDDecoder.decodeQueue` (Task 3). ✅

**Out of scope (fast-follows, by the agreed slice):** Phase 1 SACD-ISO→DSF import; Phase 3B DoP "Native" mode to the XD05; streamed/progressive decode; gapless across decoded tracks.

**Placeholder scan:** none — every code step shows full code; Task 5's one soft spot (`currentPlayingTrackURL()` may not exist verbatim) is explicitly flagged with the fallback (reuse the existing now-playing track expression).

**Type consistency:** `DSDPlaybackDecoding.canDecode/decode`, `FFmpegDSDDecoder.decodableExtensions/decodeArguments`, `PlaybackService.init(engine:decoder:)`, `DSDFormat.isDSDCodec/label` are used with identical signatures across Tasks 1–5. `CommandRunning.run`/`CommandOutput` match the existing `ConversionService.swift` definitions.
