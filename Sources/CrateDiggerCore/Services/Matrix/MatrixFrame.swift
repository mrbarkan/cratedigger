import Foundation

/// One LED of the NOW screen's matrix.
///
/// Heat travels with the lit cell, not with the view, so each animation picks
/// its own colour direction (up a column, along a bar, out from the centre)
/// and the view only ever decides which of the panel's two inks it means.
public struct MatrixCell: Equatable, Sendable {
    /// 0 = unlit, 1 = peak.
    public var intensity: Double
    /// 0 (coolest) … 1 (hottest).
    public var heat: Double

    /// The heat at and above which a cell lights in the hot ink (Meter High)
    /// instead of the cool one (cyan). A hardware meter has colour zones, not
    /// a gradient, and a straight blend from cyan to orange went through a
    /// muddy grey-green on the way. At 0.75 a vertical VU's top two rows are
    /// hot and a horizontal one's last three columns.
    public static let hotHeat = 0.75

    public static func isHot(heat: Double) -> Bool { heat >= hotHeat }

    public init(intensity: Double = 0, heat: Double = 0) {
        self.intensity = intensity
        self.heat = heat
    }
}

/// One picture on the 12 × 6 matrix.
///
/// Row 0 is the bottom, as on a hardware meter, so an animation can say "rise
/// from the bottom" without flipping coordinates. Unlit cells keep heat 0:
/// that is what lets silence compare equal to `.dark`, which the driver relies
/// on to tell when it may stop its timer and to skip republishing a frame that
/// has not changed. The tint a dark cell prints in comes from its animation's
/// `restingHeat` instead, so it never has to live in the frame.
public struct MatrixFrame: Equatable, Sendable {
    public static let columns = 12
    public static let rows = 6

    /// Row-major, row 0 = bottom: cell (column, row) is `cells[row × 12 + column]`.
    public var cells: [MatrixCell]

    public init() {
        cells = Array(repeating: MatrixCell(), count: Self.columns * Self.rows)
    }

    public subscript(column column: Int, row row: Int) -> MatrixCell {
        get { cells[row * Self.columns + column] }
        set { cells[row * Self.columns + column] = newValue }
    }

    public static let dark = MatrixFrame()

    /// Rounds each intensity to the nearest multiple of `step`, in place. A
    /// cell that rounds to unlit drops its heat too, as an unlit cell must, so
    /// a picture that has faded out compares equal to `.dark` rather than
    /// differing by the heat of cells nobody can see lit.
    ///
    /// The driver compares frames at this step: a fade moves an intensity by
    /// a little each tick, and without it every one of those ticks would be a
    /// new frame to publish and redraw.
    public mutating func quantize(step: Double) {
        guard step > 0 else { return }
        for i in cells.indices {
            let intensity = (cells[i].intensity / step).rounded() * step
            cells[i].intensity = intensity
            if intensity == 0 { cells[i].heat = 0 }
        }
    }
}

/// What an animation hears on one tick: the smoothed spectrum and channel
/// levels the meter driver already keeps, plus the time since the last tick.
///
/// Values are sanitised on the way in rather than in every animation. A
/// stream tap that has not delivered yet hands over an empty or short band
/// array, and a missing band reads as a quiet one rather than a crash.
public struct MatrixInput: Sendable {
    /// 12 levels, 0…1, low → high, already smoothed.
    public var bands: [Double] {
        didSet { bands = Self.normalised(bands) }
    }
    /// 0…1.
    public var left: Double {
        didSet { left = Self.unit(left) }
    }
    /// 0…1.
    public var right: Double {
        didSet { right = Self.unit(right) }
    }
    /// Seconds since the previous frame; never negative.
    public var dt: TimeInterval {
        didSet { dt = Self.step(dt) }
    }

    public init(bands: [Double], left: Double, right: Double, dt: TimeInterval) {
        self.bands = Self.normalised(bands)
        self.left = Self.unit(left)
        self.right = Self.unit(right)
        self.dt = Self.step(dt)
    }

    /// The mean of the bands: one number for "how much is playing".
    public var loudness: Double {
        bands.reduce(0, +) / Double(MatrixFrame.columns)
    }

    private static func normalised(_ bands: [Double]) -> [Double] {
        let count = MatrixFrame.columns
        if bands.count == count, bands.allSatisfy({ $0 >= 0 && $0 <= 1 }) { return bands }
        return (0..<count).map { $0 < bands.count ? unit(bands[$0]) : 0 }
    }

    /// Clamps to 0…1; NaN reads as 0 so one bad sample can't light the grid.
    private static func unit(_ value: Double) -> Double {
        value.isNaN ? 0 : min(max(value, 0), 1)
    }

    private static func step(_ dt: TimeInterval) -> TimeInterval {
        dt.isNaN ? 0 : max(dt, 0)
    }
}
