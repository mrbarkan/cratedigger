import Foundation

/// How a scanned image is framed inside the round disc face.
///
/// A flatbed scan of a CD is never centred and rarely square to the platen: the
/// disc sits wherever it landed, usually rotated, often with a margin of scanner
/// lid around it. Drawn straight into a circular clip that reads as a tilted,
/// off-centre label with the spindle hole in the wrong place — which is exactly
/// what it looks like, because the renderer has no way to know where the disc
/// actually is in the picture.
///
/// This is the correction: a rotation, a zoom, and a nudge, stored per image so
/// it survives relaunches and travels with the album folder in the manifest.
/// Deliberately not baked into the file — the scan stays untouched, and the cut
/// can be redone at any time.
public struct ArtworkCrop: Codable, Equatable, Hashable, Sendable {
    /// Clockwise rotation applied before framing.
    public var rotationDegrees: Double
    /// Zoom, where 1 fills the frame the way an uncropped image would.
    public var scale: Double
    /// Pan, as a fraction of the frame's size: -0.5 shifts a full half-frame
    /// left/up, +0.5 right/down. Normalized so a cut set on a preview holds at
    /// any render size.
    public var offsetX: Double
    public var offsetY: Double

    public init(
        rotationDegrees: Double = 0,
        scale: Double = 1,
        offsetX: Double = 0,
        offsetY: Double = 0
    ) {
        self.rotationDegrees = rotationDegrees
        self.scale = scale
        self.offsetX = offsetX
        self.offsetY = offsetY
    }

    public static let identity = ArtworkCrop()

    /// True when this crop would change nothing, so callers can skip storing it.
    public var isIdentity: Bool { self == .identity }

    // Bounds exist to keep a mis-drag recoverable: a scan zoomed to 40× or
    // nudged three frames away shows nothing, and the user cannot see what to
    // drag back.
    public static let scaleRange: ClosedRange<Double> = 0.5...4.0
    public static let offsetRange: ClosedRange<Double> = -1.0...1.0

    /// The same crop with every value pulled back inside its bounds and the
    /// rotation folded to 0..<360.
    public var clamped: ArtworkCrop {
        ArtworkCrop(
            rotationDegrees: Self.normalizedRotation(rotationDegrees),
            scale: min(max(scale, Self.scaleRange.lowerBound), Self.scaleRange.upperBound),
            offsetX: min(max(offsetX, Self.offsetRange.lowerBound), Self.offsetRange.upperBound),
            offsetY: min(max(offsetY, Self.offsetRange.lowerBound), Self.offsetRange.upperBound)
        )
    }

    /// Wrap into 0..<360, so ±370° and −350° both read as 10°.
    public static func normalizedRotation(_ degrees: Double) -> Double {
        guard degrees.isFinite else { return 0 }
        let wrapped = degrees.truncatingRemainder(dividingBy: 360)
        return wrapped < 0 ? wrapped + 360 : wrapped
    }

    /// Rotation expressed as the shortest turn from upright, −180...180 — what a
    /// slider should show, since 350° is better read as −10°.
    public var signedRotation: Double {
        let normalized = Self.normalizedRotation(rotationDegrees)
        return normalized > 180 ? normalized - 360 : normalized
    }

    /// Pixel offset for a frame of `size` points, ready for `.offset(x:y:)`.
    public func pixelOffset(in size: Double) -> (x: Double, y: Double) {
        (x: offsetX * size, y: offsetY * size)
    }

    /// Nudge by a drag translation measured in points of a `size`-point frame.
    public func nudged(byX dx: Double, y dy: Double, in size: Double) -> ArtworkCrop {
        guard size > 0 else { return self }
        var moved = self
        moved.offsetX += dx / size
        moved.offsetY += dy / size
        return moved.clamped
    }

    public func zoomed(by factor: Double) -> ArtworkCrop {
        guard factor > 0, factor.isFinite else { return self }
        var zoomed = self
        zoomed.scale *= factor
        return zoomed.clamped
    }

    public func rotated(by degrees: Double) -> ArtworkCrop {
        var turned = self
        turned.rotationDegrees = Self.normalizedRotation(turned.rotationDegrees + degrees)
        return turned
    }
}
