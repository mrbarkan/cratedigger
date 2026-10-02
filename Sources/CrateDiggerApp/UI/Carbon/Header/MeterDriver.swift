import Combine
import CrateDiggerCore
import Foundation

/// Drives the NOW screen's LED matrix from what the playback engine measures:
/// the frequency bands (`LibraryViewModel.currentPlaybackSpectrum`) and the
/// channel levels (`currentPlaybackLevels`).
///
/// Exponential (RC-style) ballistics, a quick attack and a slower release, so
/// the matrix tracks the music and fades down when playback pauses instead of
/// snapping to dark. The smoothed values go through whichever
/// `MatrixAnimation` the view hands over, and the picture it answers with is
/// published as `frame`. The timer keeps ticking through the fade and through
/// anything the animation still has moving, then halts, so it costs nothing
/// while idle.
@MainActor
final class MeterDriver: ObservableObject {
    /// The matrix as it should look now, with intensities rounded to steps of
    /// 1/8. Published only when it changes.
    @Published private(set) var frame = MatrixFrame.dark

    /// Supplies the latest 0...1 frequency bands (from the FFT). Set by the view.
    var spectrumProvider: (() -> [Double])?
    /// Supplies the latest 0...1 left and right levels. Set by the view.
    var levelsProvider: (() -> (left: Double, right: Double))?

    /// What turns the smoothed audio into a picture. Set by the view; nil
    /// draws nothing. Swapping it starts the new one from a dark matrix
    /// rather than leaving the last one's picture up until the next tick.
    var animation: (any MatrixAnimation)? {
        get { currentAnimation }
        set {
            currentAnimation = newValue
            frame = .dark
        }
    }

    /// The stored animation, mutated in place each tick. Kept apart from
    /// `animation` because a setter on the property the tick mutates would
    /// run (and blank the matrix) on every frame.
    private var currentAnimation: (any MatrixAnimation)?

    /// True while the timer is ticking. For tests: the timer is the only cost
    /// the driver has, so whether it has stopped is the promise worth pinning.
    var isTicking: Bool { timer != nil }

    /// Time constants (seconds) for the ballistics: near-instant attack and a
    /// short release, so the meter feels real-time.
    private let attackTau: TimeInterval
    private let releaseTau: TimeInterval
    /// Below this every band and channel is treated as settled.
    private let restThreshold = 0.0025
    /// A fade moves an intensity by a little each tick; comparing at this
    /// step keeps it from republishing (and redrawing) on every one of them.
    private let intensityQuantum = 1.0 / 8.0

    private var timer: Timer?
    private var lastUpdate = Date()
    /// True while playing; false means release toward zero, then stop ticking.
    private var active = false
    private var visibilitySub: AnyCancellable?

    /// Continuous ballistic state. The animation reads these; `frame` is what
    /// it makes of them.
    private var rawBands = Array(repeating: 0.0, count: MatrixFrame.columns)
    private var rawLeft = 0.0
    private var rawRight = 0.0

    /// The release is a parameter so a test can make the levels settle at
    /// once and see what else keeps the timer running.
    init(attackTau: TimeInterval = 0.008, releaseTau: TimeInterval = 0.12) {
        self.attackTau = attackTau
        self.releaseTau = releaseTau
        // A matrix nobody can see does not need redrawing 30 times a second.
        // The bands keep being measured on the audio thread, and the first
        // tick back carries the whole hidden gap as its time step, so the
        // picture is correct the moment the window comes back: the ballistics
        // land on the current level, rings launched before the gap have
        // expired, and a `LoudnessFollower` re-seeds instead of measuring the
        // music against a chorus nobody saw.
        visibilitySub = AppVisibility.shared.$isVisible.sink { [weak self] visible in
            MainActor.assumeIsolated {
                guard let self else { return }
                if visible { self.ensureTimer(carryingGap: true) } else { self.haltTimer() }
            }
        }
    }

    /// Begin metering (playback started).
    func start() {
        active = true
        ensureTimer()
    }

    /// Stop metering: the matrix fades down smoothly, then the timer halts.
    func stop() {
        active = false
        ensureTimer()
    }

    /// Stop at once, with no fade: the view that shows the matrix is going
    /// away, so nobody would see it, and a timer left behind would keep firing.
    func halt() {
        active = false
        haltTimer()
        settle()
        frame = .dark
    }

    private func haltTimer() {
        timer?.invalidate()
        timer = nil
    }

    /// Starts the timer if it is not running. `carryingGap` keeps the clock
    /// from the last tick, so the first new tick's step spans the time the
    /// timer was off; only the return from a hidden window wants that. A
    /// start or stop restarts the clock, so the step from an idle halt is not
    /// read as the music having run on.
    private func ensureTimer(carryingGap: Bool = false) {
        // Nothing to drive while no window is on screen to draw the matrix.
        guard timer == nil, AppVisibility.shared.isVisible else { return }
        if !carryingGap { lastUpdate = Date() }
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
        advance(by: dt)
    }

    /// One tick's work with the time step handed in. The timer passes the
    /// wall-clock step; tests call it directly, so what they pin (a ring
    /// outliving a pause, a stateless animation halting at once) does not
    /// hang on how promptly a loaded machine fires a real timer.
    func advance(by dt: TimeInterval) {
        // The provider's bands are already meter positions; the engine applies
        // the dB curve. Do NOT re-map here, or the scale compresses into the top
        // segments and the matrix looks frozen.
        let targetBands = active ? (spectrumProvider?() ?? []) : []
        for i in rawBands.indices {
            let target = i < targetBands.count ? targetBands[i] : 0
            rawBands[i] = ballistic(current: rawBands[i], target: target, dt: dt)
        }
        let targetLevels: (left: Double, right: Double) = active ? (levelsProvider?() ?? (0, 0)) : (0, 0)
        rawLeft = ballistic(current: rawLeft, target: targetLevels.left, dt: dt)
        rawRight = ballistic(current: rawRight, target: targetLevels.right, dt: dt)

        // Settled values snap to exactly zero before the animation hears them:
        // an exponential release never gets there by itself, and an animation
        // only calls itself at rest on a true silence.
        let settled = !active
            && rawLeft < restThreshold && rawRight < restThreshold
            && rawBands.allSatisfy { $0 < restThreshold }
        if settled { settle() }

        if currentAnimation != nil {
            let input = MatrixInput(bands: rawBands, left: rawLeft, right: rawRight, dt: dt)
            if var next = currentAnimation?.frame(for: input) {
                next.quantize(step: intensityQuantum)
                if next != frame { frame = next }
            }
        }

        // Once idle, faded out and with nothing still travelling across the
        // matrix (an Explosions ring outlives the beat that launched it),
        // stop ticking to save CPU.
        if settled, currentAnimation?.isAtRest ?? true {
            frame = .dark
            haltTimer()
        }
    }

    private func settle() {
        for i in rawBands.indices { rawBands[i] = 0 }
        rawLeft = 0
        rawRight = 0
    }

    /// Exponential smoothing toward `target`: fast attack, slower release.
    private func ballistic(current: Double, target: Double, dt: TimeInterval) -> Double {
        let tau = target > current ? attackTau : releaseTau
        let alpha = 1 - exp(-dt / tau)
        return current + (target - current) * alpha
    }
}
