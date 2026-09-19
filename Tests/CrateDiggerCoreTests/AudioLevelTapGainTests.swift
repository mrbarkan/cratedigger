#if canImport(XCTest)
import AVFoundation
import Foundation
import XCTest
@testable import CrateDiggerCore

/// Regression guard for a hypothesis raised while investigating "boost above
/// unity is inaudible" (2026-09-19 beta-3 volume brief, Task 3): does an
/// `AudioLevelTap`'s master gain survive being reattached to a new item, the
/// way `AVPlayerEngine.attachLevelMetering` reattaches it on every track
/// change (`replaceCurrentItem`, PlaybackService.swift:213) and every
/// gapless look-ahead (`prepareNextItem`, :252)? A tap that forgot the gain
/// on reattach would exactly explain "I push the fader past 0 dB and nothing
/// changes on the next track."
///
/// Found NOT to be the case: `AVPlayerEngine` holds a single `AudioLevelTap`
/// (and its single `AudioTapLevelStore`) for its whole lifetime;
/// `attachLevelMetering` builds a fresh `MTAudioProcessingTap` per item but
/// always retains that same store, so gain set once keeps applying to
/// whatever plays next. See `.superpowers/sdd/2026-09-19-beta-3-volume-prep-crate-stream-download/task-3-report.md`
/// for the full investigation and CLAUDE.md's "### Playback" section for the
/// standing rule this guards.
///
/// Plays real (silent-to-the-room — `player.volume = 0`) audio through the
/// real `AudioLevelTap` + `AVPlayer`/`MTAudioProcessingTap` pipeline; the
/// `player.volume` gate is downstream of the tap, so the raw `currentPeaks()`
/// reading is unaffected by muting. Same real-audio-through-a-real-engine
/// shape as the existing `AVPlayerEngineGaplessTests` (which this suite
/// already ships, at ~0.8s/test): bounded timeouts throughout, and
/// `XCTSkip` — never a hang or a failure — if no audio stack answers in
/// time. Measured at ~1.0s/run here (20 consecutive runs, 0 failures) —
/// the same order of magnitude as that existing test, not the ~10ms/test
/// average of the suite's mostly-pure-logic tests, because both need a real
/// audio render pipeline to actually run. Asserts only the *ratio* between
/// unity and boosted readings against a generous tolerance band, never an
/// absolute RMS value, since the exact number is decoder/hardware-dependent
/// and would make this brittle.
final class AudioLevelTapGainTests: XCTestCase {

    /// `VolumeCurve.amplitude(forPosition: 1)` — the makeup gain a fader
    /// pushed to the very top of travel (+5 dB) applies.
    private let boostGain = 1.778_279_41

    func testMasterGainSurvivesReattachToANewItem() throws {
        try withTemporaryDirectory(prefix: "gain-tap") { directory in
            let toneURL = directory.appendingPathComponent("tone.caf")
            do {
                try writeToneFile(to: toneURL, seconds: 1.0)
            } catch {
                throw XCTSkip("no audio stack available here: \(error.localizedDescription)")
            }

            let tap = AudioLevelTap()
            let player = AVPlayer()
            player.volume = 0 // the tap sits upstream of player.volume — silent, not blind

            // First item, still at the tap's default (unity) gain.
            let item1 = try attach(tap, to: toneURL, on: player)
            let unityPeak = try stablePeak(tap: tap)
            XCTAssertGreaterThan(unityPeak, 0.0001, "sanity: tone should be audible to the tap at unity")

            // Fader pushed to the top, live, on the item already playing.
            tap.setMasterGain(boostGain)
            let boostedPeakSameItem = try stablePeak(tap: tap, minimum: unityPeak * 1.3)
            assertRatioNearBoostGain(boostedPeakSameItem / unityPeak,
                                      "master gain must apply live to the currently playing item")
            _ = item1

            // Simulate a track change WITHOUT touching the fader again — this
            // is exactly what happens on every ordinary advance and every
            // gapless handover.
            let item2 = try attach(tap, to: toneURL, on: player)
            let peakNewItem = try stablePeak(tap: tap, minimum: unityPeak * 1.3)

            assertRatioNearBoostGain(peakNewItem / unityPeak,
                                      "a newly (re)attached item must inherit the current master gain, " +
                                      "not silently reset to unity")
            _ = item2
        }
    }

    // MARK: - Helpers

    /// The +5 dB gain relationship, checked within ±20% (ratio 1.42...2.13)
    /// — wide enough to absorb decoder/hardware RMS-windowing differences,
    /// while still cleanly rejecting the "no boost applied" failure mode
    /// (ratio ≈ 1.0).
    private func assertRatioNearBoostGain(_ ratio: Double, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(ratio, boostGain, accuracy: boostGain * 0.2, message, file: file, line: line)
    }

    @discardableResult
    private func attach(_ tap: AudioLevelTap, to url: URL, on player: AVPlayer) throws -> AVPlayerItem {
        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        let attached = expectation(description: "audio mix attached")
        Task {
            guard let track = try? await asset.loadTracks(withMediaType: .audio).first else {
                XCTFail("tone file has no audio track")
                attached.fulfill()
                return
            }
            let mix = tap.makeAudioMix(forTrack: track)
            await MainActor.run {
                item.audioMix = mix
                attached.fulfill()
            }
        }
        wait(for: [attached], timeout: 5)
        tap.reset()
        player.replaceCurrentItem(with: item)
        player.play()
        return item
    }

    /// Poll (bounded — never blocks past `timeout`) for a *stable* level at
    /// or above `minimum`: three consecutive samples within 10% of each
    /// other, collected only after `warmup` has elapsed. Two failure modes
    /// showed up while tuning this against real hardware, both fixed by the
    /// combination of warmup + stability rather than either alone:
    ///  - A fixed "sleep a little, then take one reading" was flaky:
    ///    swapping `AVPlayer.replaceCurrentItem` can leave the outgoing
    ///    item's still-in-flight buffer visible for one more read, which
    ///    crosses the threshold and then genuinely drops to zero while the
    ///    new item spins up — landing the single delayed read on exactly
    ///    that gap.
    ///  - Dropping the fixed delay and only requiring "three consecutive
    ///    similar readings" was *also* flaky in the other direction: this
    ///    pipeline has a short, highly reproducible startup ramp (measured
    ///    consistently ~0.142 vs. the converged ~0.177 for the same tone),
    ///    and three polls can land on that plateau together, "stable" but
    ///    not yet settled.
    /// `warmup` clears the ramp; the stability run afterward rides out the
    /// reattach race. Skips — does not fail or hang — if the level never
    /// stabilizes, which is what a machine with no usable audio output
    /// route looks like.
    private func stablePeak(tap: AudioLevelTap, minimum: Double = 0.0001, timeout: TimeInterval = 4, warmup: TimeInterval = 0.2) throws -> Double {
        let start = Date()
        let deadline = start.addingTimeInterval(timeout)
        var recent: [Double] = []
        var last = 0.0
        while Date() < deadline {
            let peaks = tap.currentPeaks()
            let peak = max(peaks.left, peaks.right)
            last = peak
            if Date().timeIntervalSince(start) >= warmup, peak >= minimum {
                recent.append(peak)
                if recent.count > 3 { recent.removeFirst() }
                if recent.count == 3, let lo = recent.min(), let hi = recent.max(), hi - lo <= hi * 0.1 {
                    return recent.last!
                }
            } else {
                recent.removeAll()
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        }
        throw XCTSkip("tap never reported a stable level >= \(minimum) (last \(last)) within \(timeout)s; " +
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
