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
    /// Smoothed 0...1 spectrum-band magnitudes (low→high) for the vertical meter.
    @Published private(set) var bands: [Double] = Array(repeating: 0, count: 12)

    /// Supplies the latest 0...1 L/R levels (from the audio tap). Set by the view.
    var levelsProvider: (() -> (left: Double, right: Double))?
    /// Supplies the latest 0...1 frequency bands (from the FFT). Set by the view.
    var spectrumProvider: (() -> [Double])?

    /// Time constants (seconds) for the meter ballistics. Fast attack (near
    /// instant) + a short release so the meter feels real-time / punchy.
    private let attackTau = 0.008
    private let releaseTau = 0.12
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

    /// Continuous ballistic state. Published values are quantized snapshots of
    /// these — publishing the raw Doubles re-rendered the meter views 60×/s
    /// even when no LED visibly changed, which (14 objectWillChange per tick)
    /// pegged a full core during playback.
    private var rawLeft: Double = 0
    private var rawRight: Double = 0
    private var rawBands: [Double] = Array(repeating: 0, count: 12)
    /// Publish at the LEDs' own resolution — the displays are discrete
    /// (6-segment spectrum columns, 18-segment L/R bars), so any finer publish
    /// re-renders identical pixels. A pass now happens only when an LED flips.
    /// The OLED RTA pane has taller columns, so it raises `bandQuantum` to its
    /// own segment count on appear; the footer keeps the 1/6 default.
    var bandQuantum = 1.0 / 6.0
    private let levelQuantum = 1.0 / 18.0

    private func ensureTimer() {
        guard timer == nil else { return }
        lastUpdate = Date()
        // 30fps: LED meters with ~120ms release ballistics look identical at
        // half the invalidation rate of the old 60fps tick.
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
    }

    private func tick() {
        let now = Date()
        let dt = now.timeIntervalSince(lastUpdate)
        lastUpdate = now

        // NOTE: the provider values are already meter positions — AVPlayerEngine
        // maps the tap's RMS through its dB curve (`meterPosition`, -48dBFS→0,
        // full scale→0.8). Do NOT re-map here: a second dB pass compresses the
        // whole scale into the top segments and the bar looks frozen.
        let target = active ? (levelsProvider?() ?? (left: 0, right: 0)) : (left: 0, right: 0)
        rawLeft = ballistic(current: rawLeft, target: target.left, dt: dt)
        rawRight = ballistic(current: rawRight, target: target.right, dt: dt)

        let targetBands = active ? (spectrumProvider?() ?? []) : []
        for i in rawBands.indices {
            let t = i < targetBands.count ? targetBands[i] : 0
            rawBands[i] = ballistic(current: rawBands[i], target: t, dt: dt)
        }

        // Publish batched and only on visible change: one objectWillChange per
        // value that actually moved an LED, zero when the meter is steady.
        let qLeft = quantize(rawLeft, to: levelQuantum)
        let qRight = quantize(rawRight, to: levelQuantum)
        if qLeft != leftLevel { leftLevel = qLeft }
        if qRight != rightLevel { rightLevel = qRight }
        let qBands = rawBands.map { quantize($0, to: bandQuantum) }
        if qBands != bands { bands = qBands }

        // Once idle and faded out, stop ticking to save CPU.
        if !active, rawLeft < restThreshold, rawRight < restThreshold {
            rawLeft = 0
            rawRight = 0
            rawBands = Array(repeating: 0, count: rawBands.count)
            leftLevel = 0
            rightLevel = 0
            bands = Array(repeating: 0, count: bands.count)
            timer?.invalidate()
            timer = nil
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
