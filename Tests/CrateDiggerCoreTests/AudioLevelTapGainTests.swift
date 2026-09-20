#if canImport(XCTest)
import AVFoundation
import Foundation
import XCTest
@testable import CrateDiggerCore

/// Regression guard for a hypothesis raised while investigating "boost above
/// unity is inaudible" (2026-09-19 beta-3 volume brief, Task 3): does the
/// makeup gain (`AVPlayerEngine.setMasterGain`, backed by `AudioLevelTap`)
/// survive `attachLevelMetering` reattaching to a new item — the way every
/// ordinary track change (`replaceCurrentItem`, PlaybackService.swift:213)
/// and every gapless look-ahead (`prepareNextItem`, :252) does, since both
/// call the same `attachLevelMetering` (:433-443)? A tap that forgot the
/// gain on reattach would exactly explain "I push the fader past 0 dB and
/// nothing changes on the next track."
///
/// Drives `AVPlayerEngine` directly (not `AudioLevelTap` standalone) so the
/// test actually exercises `attachLevelMetering`'s reuse of `self.levelTap`
/// — the thing the hypothesis is about — rather than only proving
/// `AudioLevelTap`/`AudioTapLevelStore.reset()` preserves `masterGain` in
/// isolation. Same shape as the existing `AVPlayerEngineGaplessTests`
/// (`onItemReady`/`onItemFailed` callbacks, bounded `wait(for:timeout:)`,
/// `XCTSkip` if no audio stack answers), except that test mutes the player
/// and uses silent fixtures because it only cares about end-of-item timing;
/// this one needs a real, audible-to-the-tap signal, so it keeps a low but
/// nonzero `player.volume` and a real tone.
///
/// Reads `engine.currentLevels`, which folds a constant `player.volume` into
/// a nonlinear meter-position value via `PlaybackMeterScale` — see
/// `assertDeltaMatchesGain` below for why that is still exactly the right
/// thing to assert against, without hardcoding this machine's RMS numbers.
///
/// See `.superpowers/sdd/2026-09-19-beta-3-volume-prep-crate-stream-download/task-3-report.md`
/// for the full investigation and CLAUDE.md's "### Playback" section for the
/// standing rule this guards.
final class AudioLevelTapGainTests: XCTestCase {

    func testMasterGainSurvivesReattachToANewItem() throws {
        try withTemporaryDirectory(prefix: "gain-tap") { directory in
            let toneURL = directory.appendingPathComponent("tone.caf")
            do {
                try writeToneFile(to: toneURL, seconds: 1.5)
            } catch {
                throw XCTSkip("no audio stack available here: \(error.localizedDescription)")
            }

            let engine = AVPlayerEngine()
            engine.setVolume(0.15) // quiet, never muted: currentLevels folds player.volume, so 0 would always read 0

            // First item, still at the engine's default (unity) gain.
            try loadAndPlay(engine, url: toneURL)
            let unityLevel = try stableLevel(engine)

            // Fader pushed to the top, live, on the item already playing —
            // the same value LibraryViewModel.applyVolumeToEngines() would
            // pass for a fader at position 1.
            let boostGain = VolumeCurve.makeupGain(forPosition: 1)
            engine.setMasterGain(boostGain)
            let boostedLevelSameItem = try stableLevel(engine)
            assertDeltaMatchesGain(from: unityLevel, to: boostedLevelSameItem, gain: boostGain,
                                    "master gain must apply live to the currently playing item")

            // Simulate an ordinary track change WITHOUT touching the fader
            // again — replaceCurrentItem calls attachLevelMetering exactly
            // as production does, so this exercises the real reattachment
            // path, not a hand-rolled stand-in for it.
            try loadAndPlay(engine, url: toneURL)
            let levelNewItem = try stableLevel(engine)

            assertDeltaMatchesGain(from: unityLevel, to: levelNewItem, gain: boostGain,
                                    "a newly (re)attached item must inherit the current master gain, " +
                                    "not silently reset to unity")
        }
    }

    // MARK: - Helpers

    /// `PlaybackMeterScale.position` is `db → position`, i.e. linear in dB.
    /// For a fixed multiplicative gain applied to any reference amplitude,
    /// the *change* in position it produces is constant (dB is already a
    /// ratio), independent of that reference amplitude or of `player.volume`
    /// (also a constant multiplicative factor, present in both readings).
    /// So this computes, from `VolumeCurve` and `PlaybackMeterScale`
    /// themselves — never a number copied off this machine's RMS output —
    /// exactly what position delta a `gain`-sized boost should produce, and
    /// checks the measured delta against it. A regression that drops the
    /// gain back to unity measures a delta near 0, cleanly outside a ±30%
    /// band around a real +5 dB delta.
    private func assertDeltaMatchesGain(from unityPosition: Double, to boostedPosition: Double, gain: Double,
                                         _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        let reference = 0.1 // arbitrary; far from both the 0 floor and the 1.0 ceiling of position(fromLinear:)
        let expectedDelta = PlaybackMeterScale.position(fromLinear: reference * gain)
            - PlaybackMeterScale.position(fromLinear: reference)
        let measuredDelta = boostedPosition - unityPosition
        XCTAssertEqual(measuredDelta, expectedDelta, accuracy: expectedDelta * 0.3, message, file: file, line: line)
    }

    private func loadAndPlay(_ engine: AVPlayerEngine, url: URL, timeout: TimeInterval = 10) throws {
        var failureMessage: String?
        let ready = expectation(description: "item ready")
        engine.onItemReady = { ready.fulfill() }
        engine.onItemFailed = { failureMessage = $0; ready.fulfill() }
        engine.replaceCurrentItem(url: url)
        wait(for: [ready], timeout: timeout)
        if let failureMessage {
            throw XCTSkip("playback failed to become ready: \(failureMessage); no audio stack available here")
        }
        engine.play()
    }

    /// Poll (bounded — never blocks past `timeout`) for a *stable* level:
    /// three consecutive samples within 10% of each other, collected only
    /// after `warmup` has elapsed and only above a low noise floor — never a
    /// threshold biased toward "boost already applied", or a reading that
    /// settles at the unboosted level (exactly the regression this test
    /// exists to catch) would time out into a skip instead of failing.
    /// `warmup` exists for two independent, empirically observed reasons:
    /// this pipeline has a short, reproducible startup ramp before RMS
    /// converges, and swapping the engine's current item can leave the
    /// outgoing item's still-in-flight buffer visible for one more read,
    /// which can cross a threshold and then genuinely drop while the new
    /// item spins up. Skips — does not fail or hang — if the level never
    /// stabilizes, which is what a machine with no usable audio output route
    /// looks like.
    private func stableLevel(_ engine: AVPlayerEngine, timeout: TimeInterval = 5, warmup: TimeInterval = 0.3) throws -> Double {
        let start = Date()
        let deadline = start.addingTimeInterval(timeout)
        var recent: [Double] = []
        var last = 0.0
        while Date() < deadline {
            let levels = engine.currentLevels
            let level = max(levels.left, levels.right)
            last = level
            if Date().timeIntervalSince(start) >= warmup, level > 0.0001 {
                recent.append(level)
                if recent.count > 3 { recent.removeFirst() }
                if recent.count == 3, let lo = recent.min(), let hi = recent.max(), hi - lo <= hi * 0.1 {
                    return recent.last!
                }
            } else {
                recent.removeAll()
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        }
        throw XCTSkip("engine never reported a stable level (last \(last)) within \(timeout)s; " +
                      "no audio stack available here")
    }
}

/// A short 1 kHz sine tone, low amplitude so the +5 dB boost has headroom
/// before clipping.
private func writeToneFile(to url: URL, seconds: Double, frequency: Double = 1000) throws {
    let sampleRate = 44_100.0
    guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else {
        throw CocoaError(.fileWriteUnknown)
    }
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    let frameCount = AVAudioFrameCount(sampleRate * seconds)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
        throw CocoaError(.fileWriteUnknown)
    }
    buffer.frameLength = frameCount
    let amplitude: Float = 0.25
    for channel in 0..<Int(format.channelCount) {
        guard let data = buffer.floatChannelData?[channel] else { continue }
        for frame in 0..<Int(frameCount) {
            data[frame] = amplitude * sinf(2 * Float.pi * Float(frequency) * Float(frame) / Float(sampleRate))
        }
    }
    try file.write(from: buffer)
}
#endif
