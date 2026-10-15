import Foundation

/// Everything a Busy Signals scene reads to draw one frame.
///
/// Scenes are stateless, so this is the whole of their world: any frame is a
/// pure function of it. Every time in it is already quantized to the 8 fps
/// grid (`BusySignalTiming`), so two dates inside one step build equal inputs
/// and equal drawings. `BusyLedger.sceneInput(for:at:still:)` is what builds
/// one in the app; tests and the snapshot harness build them directly.
public struct BusySceneInput: Equatable, Sendable {
    public var progress: BusyProgress
    public var labels: BusyLabels
    /// Quantized seconds since the job started, frozen at the finish (still
    /// or not); the scene's key time when `still` and running.
    public var time: TimeInterval
    /// Quantized seconds since the current unit (track, file) began; 0.5 when
    /// `still`, so a still frame never depends on the wall clock.
    public var unitTime: TimeInterval
    /// Estimated 0…0.95 inside the current unit, from the average unit so
    /// far; 1 once finished, 0.5 when `still`.
    public var unitFraction: Double
    /// Quantized seconds since the finish; nil while running.
    public var finished: TimeInterval?
    /// The finished mark (check, OK, DONE) is lit this frame.
    public var markLit: Bool
    /// Reduce Motion: draw the still key frame.
    public var still: Bool
    /// A blink is still pending, which keeps the view's timeline ticking.
    public var blinking: Bool

    /// Which 8 fps step `time` falls in.
    public var step: Int { BusySignalTiming.step(time) }
    public var isFinished: Bool { finished != nil }

    /// Public memberwise init, so the App-target snapshot harness (which
    /// imports Core without `@testable`) can build inputs directly.
    public init(progress: BusyProgress = .init(), labels: BusyLabels = .init(),
                time: TimeInterval = 0, unitTime: TimeInterval = 0, unitFraction: Double = 0,
                finished: TimeInterval? = nil, markLit: Bool = true,
                still: Bool = false, blinking: Bool = false) {
        self.progress = progress
        self.labels = labels
        self.time = time
        self.unitTime = unitTime
        self.unitFraction = unitFraction
        self.finished = finished
        self.markLit = markLit
        self.still = still
        self.blinking = blinking
    }
}

/// The scene dispatcher: the one switch over `BusyJobKind`, so the App's
/// renderer and the snapshot harness never name a scene type.
///
/// Each kind's scene lives in its own file under `Scenes/` and exposes the
/// same three members (`picture`, `mini`, `keyTime`). They are stateless
/// functions of `BusySceneInput`, the opposite of `MatrixAnimation`'s
/// stepped state, and on purpose: any frame can be rebuilt for a test or a
/// snapshot, and a window coming back from hiding draws the current frame
/// with nothing to replay.
public enum BusyScenes {
    /// The OLED picture, in 240 × 100 scene units.
    public static func picture(_ kind: BusyJobKind, _ input: BusySceneInput) -> BusyDrawing {
        switch kind {
        case .rip: return RipScene.picture(input)
        case .secureRead: return SecureReadScene.picture(input)
        case .convert: return ConvertScene.picture(input)
        case .scan: return ScanScene.picture(input)
        case .download: return DownloadScene.picture(input)
        case .transfer: return TransferScene.picture(input)
        }
    }

    /// The rail mini, in 96 × 12 mini units: source glyph, the shared dashed
    /// track, destination glyph.
    public static func mini(_ kind: BusyJobKind, _ input: BusySceneInput) -> BusyDrawing {
        switch kind {
        case .rip: return RipScene.mini(input)
        case .secureRead: return SecureReadScene.mini(input)
        case .convert: return ConvertScene.mini(input)
        case .scan: return ScanScene.mini(input)
        case .download: return DownloadScene.mini(input)
        case .transfer: return TransferScene.mini(input)
        }
    }

    /// The scene time a still (Reduce Motion) frame is drawn at, chosen per
    /// scene so the one frame reads (a squashed file under the press, the
    /// front record showing its cover). `BusyLedger.sceneInput` uses it in
    /// place of the job's elapsed time when `still` and running; a finished
    /// still keeps the time frozen at the finish, the frame the job ended on.
    public static func keyTime(_ kind: BusyJobKind) -> TimeInterval {
        switch kind {
        case .rip: return RipScene.keyTime
        case .secureRead: return SecureReadScene.keyTime
        case .convert: return ConvertScene.keyTime
        case .scan: return ScanScene.keyTime
        case .download: return DownloadScene.keyTime
        case .transfer: return TransferScene.keyTime
        }
    }
}

extension BusySignalTiming {
    /// How often the App's `TimelineView` should ask for a frame, or nil to
    /// pause it.
    ///
    /// Half a step on purpose. The animation schedule fires on display frames
    /// at least `minimumInterval` apart, so asking every 1/8 s on a 60 Hz
    /// display lands at 7.5 fps and drops a step every ~2 s, and asking every
    /// 1/2 s would alias against the 2 Hz blink. Asking twice as often costs
    /// nothing: inputs are quantized to the 8 fps grid, so the second ask in a
    /// step builds an equal input and the `Equatable` canvas skips the redraw.
    ///
    /// - still (Reduce Motion): nil. Progress redraws through ordinary SwiftUI
    ///   invalidation when the ledger publishes.
    /// - running: 1/16 s, for the motion.
    /// - finished with a blink pending: 1/8 s, which samples a 2 Hz blink
    ///   four times per phase.
    /// - finished and settled: nil, so a finished picture costs nothing.
    public static func cadence(_ input: BusySceneInput) -> TimeInterval? {
        if input.still { return nil }
        if !input.isFinished { return 1.0 / (2 * framesPerSecond) }
        if input.blinking { return 1.0 / framesPerSecond }
        return nil
    }
}
