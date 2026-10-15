import CoreGraphics

/// What a stroke or fill is drawn in.
///
/// Semantic rather than a colour, so a scene never knows which glass it is
/// drawn on: the renderer maps each ink onto the active theme's tokens, and
/// monochrome glass (which must never show `meterHot` red) falls out of that
/// one map instead of a check in every scene.
public enum BusyInk: String, CaseIterable, Sendable {
    /// The OLED phosphor.
    case foreground
    /// `theme.cyan`.
    case cool
    /// `theme.meterHot`.
    case hot
    /// The phosphor at 0.26.
    case dim
    /// `theme.oledSurface`. Only ever an occluding fill, never a stroke.
    case background
}

/// Horizontal anchoring of a text run around its `at` point, as canvas
/// `textAlign` does.
public enum BusyTextAlign: Sendable {
    case left, center, right
}

/// One recorded drawing primitive. Geometry is in the drawing's own y-down
/// unit space (240 × 100 for a picture, 96 × 12 for a mini).
public enum BusyShape: Equatable, Sendable {
    /// `weight` multiplies the renderer's line width (the note beam's × 2.2).
    case line(from: CGPoint, to: CGPoint, ink: BusyInk, weight: CGFloat)
    case path(points: [CGPoint], closed: Bool, stroke: BusyInk?, fill: BusyInk?)
    case circle(center: CGPoint, radius: CGFloat, stroke: BusyInk?, fill: BusyInk?)
    /// Radians, canvas convention (y-down, increasing angle turns clockwise).
    /// The sweep runs from `start` towards increasing angles until `end`, as
    /// canvas `arc(…, anticlockwise: false)` does.
    case arc(center: CGPoint, radius: CGFloat, start: Double, end: Double, ink: BusyInk)
    case ellipse(center: CGPoint, radii: CGSize, rotation: Double, fill: BusyInk)
    case quadCurve(from: CGPoint, control: CGPoint, to: CGPoint, ink: BusyInk)
    case rect(CGRect, stroke: BusyInk?, fill: BusyInk?)
    case roundedRect(CGRect, radius: CGFloat, stroke: BusyInk?, fill: BusyInk?)
    /// `at` is the alphabetic baseline point, as in the sketch's fillText.
    case text(String, at: CGPoint, size: CGFloat, align: BusyTextAlign, ink: BusyInk)
    /// Every shape up to the matching `clipEnd` is cut to this rect.
    case clipBegin(CGRect, radius: CGFloat)
    case clipEnd
}

/// The list of primitives a Busy Signals scene draws, in order.
///
/// Scenes are stateless functions that return one of these; the App's
/// `BusyCanvas` replays it into a SwiftUI `Canvas`. Keeping the scene's
/// output a plain value is what lets every frame be unit-tested (its bounds,
/// its inks, equality between two calls) without rendering a pixel.
///
/// Two deliberate omissions:
/// - **No colours.** Shapes carry a `BusyInk`, and theming, glow and
///   monochrome are the renderer's job. See `BusyInk`.
/// - **No transform primitive.** The sketch's `translate` + `scale`
///   (html:238, the note glyph) is applied by the glyph helper to the
///   coordinates before it emits them. A drawing that carried transforms
///   would need a matrix stack in both the renderer and `bounds`, for the
///   sake of one glyph.
///
/// The pen methods are named and ordered like the sketch's `pen()`
/// (html:185) so a port reads line for line, and default to `.foreground`
/// as the sketch defaults to `pal.fg`. Every `CGFloat` and angle that comes
/// in is sanitised (non-finite becomes 0), so a NaN out of a progress
/// computation can never reach the renderer.
public struct BusyDrawing: Equatable, Sendable {
    /// The OLED picture's unit space.
    public static let sceneSize = CGSize(width: 240, height: 100)
    /// A rail mini's unit space.
    public static let miniSize = CGSize(width: 96, height: 12)

    /// Text width is estimated at this fraction of an em per character: the
    /// OLED face is monospaced, and 0.6 em is its advance.
    static let textAdvance: CGFloat = 0.6
    /// How far a text box reaches below its baseline, in ems (descenders).
    static let textDescent: CGFloat = 0.25

    public let size: CGSize
    public private(set) var shapes: [BusyShape]

    public init(size: CGSize) {
        self.size = size
        self.shapes = []
    }

    // MARK: - The pen

    public mutating func line(_ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat,
                              _ ink: BusyInk = .foreground, weight: CGFloat = 1) {
        shapes.append(.line(from: Self.point(x1, y1), to: Self.point(x2, y2),
                            ink: ink, weight: Self.finite(weight)))
    }

    public mutating func poly(_ points: [CGPoint], _ ink: BusyInk? = .foreground,
                              closed: Bool = false, fill: BusyInk? = nil) {
        shapes.append(.path(points: points.map { Self.point($0.x, $0.y) },
                            closed: closed, stroke: ink, fill: fill))
    }

    public mutating func circle(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat,
                                _ ink: BusyInk? = .foreground, fill: BusyInk? = nil) {
        shapes.append(.circle(center: Self.point(x, y), radius: Self.finite(r), stroke: ink, fill: fill))
    }

    /// A filled circle with no stroke. Glows, as the sketch's `dot` does.
    public mutating func dot(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat, _ ink: BusyInk = .foreground) {
        shapes.append(.circle(center: Self.point(x, y), radius: Self.finite(r), stroke: nil, fill: ink))
    }

    public mutating func arc(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat,
                             _ a0: Double, _ a1: Double, _ ink: BusyInk = .foreground) {
        shapes.append(.arc(center: Self.point(x, y), radius: Self.finite(r),
                           start: Self.finite(a0), end: Self.finite(a1), ink: ink))
    }

    public mutating func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat,
                              _ ink: BusyInk? = .foreground, fill: BusyInk? = nil) {
        shapes.append(.rect(Self.rect(x, y, w, h), stroke: ink, fill: fill))
    }

    /// A filled rect with no stroke. Glows, as the sketch's `block` does.
    public mutating func block(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat,
                               _ ink: BusyInk = .foreground) {
        shapes.append(.rect(Self.rect(x, y, w, h), stroke: nil, fill: ink))
    }

    public mutating func roundedRect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat,
                                     _ r: CGFloat, _ ink: BusyInk? = .foreground, fill: BusyInk? = nil) {
        shapes.append(.roundedRect(Self.rect(x, y, w, h), radius: Self.finite(r), stroke: ink, fill: fill))
    }

    /// A filled, rotated ellipse (a note head).
    public mutating func ellipse(_ x: CGFloat, _ y: CGFloat, rx: CGFloat, ry: CGFloat,
                                 rotation: Double, _ ink: BusyInk) {
        shapes.append(.ellipse(center: Self.point(x, y),
                               radii: CGSize(width: Self.finite(rx), height: Self.finite(ry)),
                               rotation: Self.finite(rotation), fill: ink))
    }

    public mutating func quadCurve(from: CGPoint, control: CGPoint, to: CGPoint, _ ink: BusyInk) {
        shapes.append(.quadCurve(from: Self.point(from.x, from.y),
                                 control: Self.point(control.x, control.y),
                                 to: Self.point(to.x, to.y), ink: ink))
    }

    /// `y` is the alphabetic baseline.
    public mutating func text(_ s: String, _ x: CGFloat, _ y: CGFloat, _ ink: BusyInk = .foreground,
                              size: CGFloat = 6, align: BusyTextAlign = .left) {
        shapes.append(.text(s, at: Self.point(x, y), size: Self.finite(size), align: align, ink: ink))
    }

    /// Runs `body` on this drawing with everything it records cut to `rect`
    /// (rounded by `radius`): appends `.clipBegin`, the body's shapes, then
    /// `.clipEnd`. Clips nest; an inner clip is cut by the outer one.
    public mutating func clipped(to rect: CGRect, radius: CGFloat, _ body: (inout BusyDrawing) -> Void) {
        shapes.append(.clipBegin(Self.rect(rect.origin.x, rect.origin.y, rect.width, rect.height),
                                 radius: Self.finite(radius)))
        body(&self)
        shapes.append(.clipEnd)
    }

    // MARK: - Reading it back

    /// Union of every shape's geometric box (text estimated at 0.6 em a
    /// character). Arcs are bounded by their swept range (both endpoints
    /// plus any axis extreme inside the sweep), not the full circle. Shapes
    /// between a clipBegin and its clipEnd are intersected with the clip
    /// rect. What the in-bounds tests check.
    ///
    /// Stroke width and glow are ignored: they are the renderer's, and the
    /// tests allow for them with a tolerance. An empty drawing (or one whose
    /// every shape is clipped away) has `.zero` bounds rather than `.null`,
    /// so a caller can compare edges without first checking for infinity.
    public var bounds: CGRect {
        var union: CGRect?
        var clips: [CGRect] = []
        for shape in shapes {
            switch shape {
            case let .clipBegin(rect, _):
                let rect = rect.standardized
                let cut = clips.last.map { $0.intersection(rect) } ?? rect
                clips.append(cut)
                continue
            case .clipEnd:
                _ = clips.popLast()
                continue
            default:
                break
            }
            guard var box = Self.box(of: shape) else { continue }
            if let clip = clips.last {
                box = box.intersection(clip)
                if box.isNull { continue }
            }
            union = union.map { $0.union(box) } ?? box
        }
        return union ?? .zero
    }

    /// Every ink used by a stroke or a fill.
    public var inks: Set<BusyInk> {
        var used = Set<BusyInk>()
        for shape in shapes {
            switch shape {
            case let .line(_, _, ink, _), let .arc(_, _, _, _, ink),
                 let .ellipse(_, _, _, ink), let .quadCurve(_, _, _, ink),
                 let .text(_, _, _, _, ink):
                used.insert(ink)
            case let .path(_, _, stroke, fill), let .circle(_, _, stroke, fill),
                 let .rect(_, stroke, fill), let .roundedRect(_, _, stroke, fill):
                if let stroke { used.insert(stroke) }
                if let fill { used.insert(fill) }
            case .clipBegin, .clipEnd:
                break
            }
        }
        return used
    }

    // MARK: - Geometry

    /// One shape's geometric box, or nil for a clip marker or a path with no
    /// points.
    static func box(of shape: BusyShape) -> CGRect? {
        switch shape {
        case let .line(from, to, _, _):
            return enclosing([from, to])
        case let .path(points, _, _, _):
            return points.isEmpty ? nil : enclosing(points)
        case let .circle(center, radius, _, _):
            return square(around: center, radius: radius)
        case let .arc(center, radius, start, end, _):
            return enclosing(arcExtremes(center: center, radius: radius, start: start, end: end))
        case let .ellipse(center, radii, _, _):
            // Rotation can swing either radius onto either axis, so the
            // larger one bounds both. Compare magnitudes: with two negative
            // radii a plain max would pick the smaller one.
            return square(around: center, radius: max(abs(radii.width), abs(radii.height)))
        case let .quadCurve(from, control, to, _):
            return enclosing([from, control, to])
        case let .rect(rect, _, _), let .roundedRect(rect, _, _, _):
            return rect.standardized
        case let .text(string, at, size, align, _):
            let width = CGFloat(string.count) * size * textAdvance
            let minX: CGFloat
            switch align {
            case .left: minX = at.x
            case .center: minX = at.x - width / 2
            case .right: minX = at.x - width
            }
            return CGRect(x: minX, y: at.y - size, width: width, height: size * (1 + textDescent))
        case .clipBegin, .clipEnd:
            return nil
        }
    }

    /// The points that bound an arc: its two endpoints plus every axis
    /// extreme (0, π/2, π, 3π/2) its sweep passes through. The sweep follows
    /// canvas rules: clockwise from `start`, a whole circle once it spans
    /// 2π or more, and an `end` below `start` wrapped forward by 2π.
    static func arcExtremes(center: CGPoint, radius: CGFloat, start: Double, end: Double) -> [CGPoint] {
        let twoPi = 2 * Double.pi
        var sweep = end - start
        if sweep >= twoPi {
            sweep = twoPi
        } else {
            sweep = sweep.truncatingRemainder(dividingBy: twoPi)
            if sweep < 0 { sweep += twoPi }
        }
        func point(_ angle: Double) -> CGPoint {
            CGPoint(x: center.x + CGFloat(cos(angle)) * radius,
                    y: center.y + CGFloat(sin(angle)) * radius)
        }
        // Walk from `start` reduced into [0, 2π): at a huge but finite angle
        // the gap between adjacent Doubles exceeds π/2, so stepping the raw
        // angle would round every step away and never leave the loop.
        var from = start.truncatingRemainder(dividingBy: twoPi)
        if from < 0 { from += twoPi }
        var points = [point(from), point(from + sweep)]
        // The first quarter-turn at or after `from`, then every one after it
        // still inside the sweep: at most five, counted by integer index.
        let quarter = Double.pi / 2
        var index = (from / quarter).rounded(.up)
        while index * quarter <= from + sweep {
            points.append(point(index * quarter))
            index += 1
        }
        return points
    }

    private static func enclosing(_ points: [CGPoint]) -> CGRect {
        let xs = points.map(\.x), ys = points.map(\.y)
        let minX = xs.min() ?? 0, minY = ys.min() ?? 0
        return CGRect(x: minX, y: minY, width: (xs.max() ?? 0) - minX, height: (ys.max() ?? 0) - minY)
    }

    private static func square(around center: CGPoint, radius: CGFloat) -> CGRect {
        let r = abs(radius)
        return CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r)
    }

    // MARK: - Sanitising

    static func finite(_ value: CGFloat) -> CGFloat { value.isFinite ? value : 0 }
    static func finite(_ value: Double) -> Double { value.isFinite ? value : 0 }

    private static func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: finite(x), y: finite(y))
    }

    private static func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: finite(x), y: finite(y), width: finite(w), height: finite(h))
    }
}
