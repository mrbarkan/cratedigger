import Combine
import Foundation

/// Drives the footer VU bars from the real per-channel audio levels exposed by
/// the playback engine's audio tap.
///
/// Runs at 60fps and uses exponential (RC-style) ballistics — a quick attack and
/// a slower release — so the bars track the music smoothly and **fade down**
/// gracefully when playback pauses rather than snapping to zero. The timer keeps
/// ticking through the fade-out, then halts itself once the bars settle so it
/// costs nothing while idle.
@MainActor
final class MeterDriver: ObservableObject {
    @Published private(set) var leftLevel: Double = 0
    @Published private(set) var rightLevel: Double = 0

    /// Supplies the latest 0...1 L/R levels (from the audio tap). Set by the view.
    var levelsProvider: (() -> (left: Double, right: Double))?

    /// Time constants (seconds) for the meter ballistics.
    private let attackTau = 0.05
    private let releaseTau = 0.30
    /// Below this the bars are treated as settled and the timer can stop.
    private let restThreshold = 0.0025

    private var timer: Timer?
    private var lastUpdate = Date()
    /// True while playing; false means release toward zero, then stop ticking.
    private var active = false

    /// Begin metering (playback started).
    func start() {
        active = true
        ensureTimer()
    }

    /// Stop metering — the bars fade down smoothly, then the timer halts.
    func stop() {
        active = false
        ensureTimer()
    }

    private func ensureTimer() {
        guard timer == nil else { return }
        lastUpdate = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
    }

    private func tick() {
        let now = Date()
        let dt = now.timeIntervalSince(lastUpdate)
        lastUpdate = now

        let target = active ? (levelsProvider?() ?? (left: 0, right: 0)) : (left: 0, right: 0)
        leftLevel = ballistic(current: leftLevel, target: target.left, dt: dt)
        rightLevel = ballistic(current: rightLevel, target: target.right, dt: dt)

        // Once idle and faded out, stop ticking to save CPU.
        if !active, leftLevel < restThreshold, rightLevel < restThreshold {
            leftLevel = 0
            rightLevel = 0
            timer?.invalidate()
            timer = nil
        }
    }

    /// Exponential smoothing toward `target`: fast attack, slower release.
    private func ballistic(current: Double, target: Double, dt: TimeInterval) -> Double {
        let tau = target > current ? attackTau : releaseTau
        let alpha = 1 - exp(-dt / tau)
        return current + (target - current) * alpha
    }
}
