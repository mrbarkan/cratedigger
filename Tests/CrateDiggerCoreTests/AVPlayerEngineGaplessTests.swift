#if canImport(XCTest)
import AVFoundation
import Foundation
import XCTest
@testable import CrateDiggerCore

/// The service half of gapless is covered by `PlaybackServiceGaplessTests`
/// against a mock engine. This is the other half, and the only place the
/// AVFoundation assumptions are actually checked: that an `AVQueuePlayer`
/// really does advance to the item queued behind the playing one, that the
/// end notification arrives naming the item that finished, and that the engine
/// reports the handover as gapless rather than as a plain end.
///
/// It plays real audio, so the files are short and silent and the player is
/// muted. Skipped where no audio device can be opened.
final class AVPlayerEngineGaplessTests: XCTestCase {

    func testAdvancingToAPreparedItemReportsAGaplessHandover() throws {
        try withShortSilentTracks { first, second in
            let engine = AVPlayerEngine()
            engine.setVolume(0)

            let ready = expectation(description: "first item ready")
            let ended = expectation(description: "first item ended")
            var gaplessAtEnd: Bool?

            engine.onItemReady = { ready.fulfill() }
            engine.onItemFailed = { XCTFail("playback failed: \($0)") }
            engine.onItemEnded = {
                // Read exactly where the service reads it.
                gaplessAtEnd = engine.didAdvanceGaplessly
                ended.fulfill()
            }

            engine.replaceCurrentItem(url: first)
            wait(for: [ready], timeout: 10)

            engine.prepareNextItem(url: second)
            engine.play()
            wait(for: [ended], timeout: 10)

            XCTAssertEqual(gaplessAtEnd, true,
                           "the queued item should take over without a reload")
            engine.pause()
        }
    }

    func testEndingWithNothingPreparedIsNotReportedAsGapless() throws {
        try withShortSilentTracks { first, _ in
            let engine = AVPlayerEngine()
            engine.setVolume(0)

            let ready = expectation(description: "item ready")
            let ended = expectation(description: "item ended")
            var gaplessAtEnd: Bool?

            engine.onItemReady = { ready.fulfill() }
            engine.onItemFailed = { XCTFail("playback failed: \($0)") }
            engine.onItemEnded = {
                gaplessAtEnd = engine.didAdvanceGaplessly
                ended.fulfill()
            }

            engine.replaceCurrentItem(url: first)
            wait(for: [ready], timeout: 10)
            engine.play()
            wait(for: [ended], timeout: 10)

            XCTAssertEqual(gaplessAtEnd, false,
                           "with nothing queued the service must reload as before")
            engine.pause()
        }
    }

    func testClearingAPreparedItemPutsTheBoundaryBackOnTheReloadPath() throws {
        try withShortSilentTracks { first, second in
            let engine = AVPlayerEngine()
            engine.setVolume(0)

            let ready = expectation(description: "item ready")
            let ended = expectation(description: "item ended")
            var gaplessAtEnd: Bool?

            engine.onItemReady = { ready.fulfill() }
            engine.onItemFailed = { XCTFail("playback failed: \($0)") }
            engine.onItemEnded = {
                gaplessAtEnd = engine.didAdvanceGaplessly
                ended.fulfill()
            }

            engine.replaceCurrentItem(url: first)
            wait(for: [ready], timeout: 10)

            engine.prepareNextItem(url: second)
            engine.prepareNextItem(url: nil)
            engine.play()
            wait(for: [ended], timeout: 10)

            XCTAssertEqual(gaplessAtEnd, false)
            engine.pause()
        }
    }

    // MARK: - Fixtures

    /// Two half-second silent CAF files. Silence keeps the suite quiet; the
    /// duration only has to be long enough for the item to become ready and
    /// short enough that the test does not drag.
    private func withShortSilentTracks(_ body: (URL, URL) throws -> Void) throws {
        try withTemporaryDirectory(prefix: "gapless-engine") { directory in
            let first = directory.appendingPathComponent("first.caf")
            let second = directory.appendingPathComponent("second.caf")
            do {
                try writeSilence(to: first, seconds: 0.5)
                try writeSilence(to: second, seconds: 0.5)
            } catch {
                throw XCTSkip("no audio stack available here: \(error.localizedDescription)")
            }
            try body(first, second)
        }
    }

    private func writeSilence(to url: URL, seconds: Double) throws {
        let sampleRate = 44_100.0
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(sampleRate * seconds)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            throw CocoaError(.fileWriteUnknown)
        }
        buffer.frameLength = frames
        // A fresh buffer is already zeroed; writing it as-is gives silence.
        try file.write(from: buffer)
    }
}
#endif
