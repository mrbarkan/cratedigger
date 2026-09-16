import Combine
import Foundation

/// Drives the NOW screen's spectrum from the frequency bands the playback
/// engine measures (`LibraryViewModel.currentPlaybackSpectrum`).
///
/// Exponential (RC-style) ballistics, a quick attack and a slower release, so
/// the columns track the music and fade down when playback pauses instead of
/// snapping to zero. The timer keeps ticking through the fade, then halts once
/// the columns settle, so it costs nothing while idle.
@MainActor
final class MeterDriver: ObservableObject {
    /// Smoothed 0...1 band magnitudes (low → high), quantized to whole segments.
    @Published private(set) var bands: [Double] = Array(repeating: 0, count: 12)

    /// Supplies the latest 0...1 frequency bands (from the FFT). Set by the view.
    var spectrumProvider: (() -> [Double])?

    /// Time constants (seconds) for the ballistics: near-instant attack and a
    /// short release, so the meter feels real-time.
    private let attackTau = 0.008
    private let releaseTau = 0.12
    /// Below this every column is treated as settled and the timer can stop.
    private let restThreshold = 0.0025

    private var timer: Timer?
    private var lastUpdate = Date()
    /// True while playing; false means release toward zero, then stop ticking.
    private var active = false
    private var visibilitySub: AnyCancellable?

    init() {
        // Segments nobody can see do not need redrawing 30 times a second. The
        // bands keep being measured on the audio thread, so the columns are
        // correct the moment the window comes back.
        visibilitySub = AppVisibility.shared.$isVisible.sink { [weak self] visible in
            MainActor.assumeIsolated {
                guard let self else { return }
                if visible { self.ensureTimer() } else { self.haltTimer() }
            }
        }
    }

    /// Begin metering (playback started).
    func start() {
        active = true
        ensureTimer()
    }

    /// Stop metering: the columns fade down smoothly, then the timer halts.
    func stop() {
        active = false
        ensureTimer()
    }

    /// Stop at once, with no fade: the view that shows the columns is going
    /// away, so nobody would see it, and a timer left behind would keep firing.
    func halt() {
        active = false
        haltTimer()
        rawBands = Array(repeating: 0, count: rawBands.count)
        bands = Array(repeating: 0, count: bands.count)
    }

    private func haltTimer() {
        timer?.invalidate()
        timer = nil
    }

    /// Continuous ballistic state. `bands` publishes quantized snapshots of it:
    /// publishing the raw values re-rendered the meter every tick even when no
    /// segment visibly changed.
    private var rawBands: [Double] = Array(repeating: 0, count: 12)
    /// One step per segment of the 6-segment columns, so a publish happens only
    /// when a segment flips.
    private let bandQuantum = 1.0 / 6.0

    private func ensureTimer() {
        // Nothing to drive while no window is on screen to draw the columns.
        guard timer == nil, AppVisibility.shared.isVisible else { return }
        lastUpdate = Date()
        // 30fps: segment meters with ~120ms release ballistics look identical at
        // half the invalidation rate of a 60fps tick.
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
    }

    private func tick() {
        let now = Date()
        let dt = now.timeIntervalSince(lastUpdate)
        lastUpdate = now

        // The provider's bands are already meter positions; the engine applies
        // the dB curve. Do NOT re-map here, or the scale compresses into the top
        // segments and the columns look frozen.
        let targetBands = active ? (spectrumProvider?() ?? []) : []
        for i in rawBands.indices {
            let target = i < targetBands.count ? targetBands[i] : 0
            rawBands[i] = ballistic(current: rawBands[i], target: target, dt: dt)
        }

        let quantized = rawBands.map { quantize($0, to: bandQuantum) }
        if quantized != bands { bands = quantized }

        // Once idle and faded out, stop ticking to save CPU.
        if !active, rawBands.allSatisfy({ $0 < restThreshold }) {
            rawBands = Array(repeating: 0, count: rawBands.count)
            bands = Array(repeating: 0, count: bands.count)
            haltTimer()
        }
    }

    private func quantize(_ value: Double, to quantum: Double) -> Double {
        (value / quantum).rounded() * quantum
    }

    /// Exponential smoothing toward `target`: fast attack, slower release.
    private func ballistic(current: Double, target: Double, dt: TimeInterval) -> Double {
        let tau = target > current ? attackTau : releaseTau
        let alpha = 1 - exp(-dt / tau)
        return current + (target - current) * alpha
    }
}
