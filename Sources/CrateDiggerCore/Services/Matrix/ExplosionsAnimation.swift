import Foundation

/// Light bursting from the centre. How loud the music is against its own
/// recent level (a `LoudnessFollower`'s drive) sets the radius of a lit core,
/// and each bass hit launches a ring that travels outward and fades.
///
/// Rings outlive the frame that spawned them, which is why `isAtRest` waits
/// for the last one to fade rather than for the music to stop.
public struct ExplosionsAnimation: MatrixAnimation {
    /// A ring launched by one bass hit.
    public struct Ring: Equatable, Sendable {
        /// Seconds since the hit.
        public var age: TimeInterval
        /// In the elliptical distance units of `distance(column:row:)`.
        public var radius: Double { age * ExplosionsAnimation.ringSpeed }
        /// Fades linearly from 1 at the hit to 0 at the end of its life.
        public var brightness: Double { max(0, 1 - age / ExplosionsAnimation.ringLifetime) }
    }

    /// Radius units per second: 2.0 carries a ring past the grid's edge (1)
    /// in half a second, just as it fades out.
    static let ringSpeed = 2.0
    static let ringLifetime: TimeInterval = 0.5
    /// A cell this close to a ring's radius is part of the ring.
    static let ringHalfWidth = 0.18
    static let maxRings = 4
    /// How far the bass must jump above its own running average to count as a hit.
    /// Measured on real tracks and steady pink noise: 0.15 fires 27–107 rings
    /// a minute on music (dense masters at the low end) and one to four on
    /// noise; 0.12 adds about 20 a minute on dense material but makes noise
    /// fire 4–8, which reads as flicker. The 6 dB hotter spectrum ceiling
    /// already widened the bass's swings enough to lift the dense masters.
    static let hitThreshold = 0.15
    /// The core's radius at full drive. Below 1 so that even the loudest
    /// moment leaves the corners for the rings to cross: at a typical drive of
    /// 0.5 the core is a small centre, and a chorus roughly doubles it.
    static let coreReach = 0.75
    static let averageTimeConstant: TimeInterval = 0.3
    /// The core's brightness, the same step below peak as a VU meter's body.
    static let coreIntensity = VerticalVUAnimation.bodyIntensity

    public private(set) var rings: [Ring] = []
    private var bassAverage = 0.0
    /// A hit fires once on the way up; the bass has to drop back within the
    /// threshold before it can fire again. Otherwise a held note re-triggers
    /// every tick until the average catches up, and the four-ring cap fills
    /// with rings all stuck at the centre.
    private var armed = true
    private var loudness = 0.0
    private var follower = LoudnessFollower()
    /// The lit core's radius this frame, in the units of `distance(column:row:)`.
    public private(set) var coreRadius = 0.0

    public init() {}

    public var isAtRest: Bool { rings.isEmpty && loudness == 0 }

    /// Cool at the centre, hot toward the edge: the core glows cyan and a
    /// ring turns to the meter's hot colour as it reaches the border, the way
    /// a VU's top segments do.
    public static func restingHeat(column: Int, row: Int) -> Double {
        distance(column: column, row: row)
    }

    /// Distance of a cell from the grid's centre (5.5, 2.5), elliptical so a
    /// ring fills the wide grid evenly, clamped to 0…1.
    public static func distance(column: Int, row: Int) -> Double {
        distances[row * MatrixFrame.columns + column]
    }

    private static let distances: [Double] = (0..<(MatrixFrame.columns * MatrixFrame.rows)).map { index in
        let column = index % MatrixFrame.columns
        let row = index / MatrixFrame.columns
        let dx = (Double(column) - Double(MatrixFrame.columns - 1) / 2) / 6
        let dy = (Double(row) - Double(MatrixFrame.rows - 1) / 2) / 3
        return min((dx * dx + dy * dy).squareRoot(), 1)
    }

    public mutating func frame(for input: MatrixInput) -> MatrixFrame {
        loudness = input.loudness

        // Age what is already travelling before anything new is launched, so
        // a ring spawned this tick starts at radius 0.
        for i in rings.indices { rings[i].age += input.dt }
        rings.removeAll { $0.age >= Self.ringLifetime }

        let bass = (input.bands[0] + input.bands[1] + input.bands[2]) / 3
        let excess = bass - bassAverage
        if excess > Self.hitThreshold {
            if armed {
                rings.append(Ring(age: 0))
                if rings.count > Self.maxRings { rings.removeFirst(rings.count - Self.maxRings) }
                armed = false
            }
        } else {
            armed = true
        }
        bassAverage += (bass - bassAverage) * (1 - exp(-input.dt / Self.averageTimeConstant))

        // At rest the driver stops ticking, and the next tick may come much
        // later. Over that gap of silence the average would have decayed to
        // zero, so it is set there now rather than left holding the last beat,
        // which would swallow the first hit after a pause.
        if isAtRest { bassAverage = 0 }

        // Sized off the raw loudness, the core barely changed size within a
        // song; the follower measures it against the song's own level. It
        // forgets that level by itself once playback has stopped (the settled
        // 0 that also puts this animation at rest) or after a quiet spell
        // longer than `LoudnessFollower.silenceHold`, so the next sound is
        // measured afresh rather than against the last song.
        coreRadius = follower.drive(loudness: loudness, dt: input.dt) * Self.coreReach

        var frame = MatrixFrame.dark
        for row in 0..<MatrixFrame.rows {
            for column in 0..<MatrixFrame.columns {
                let d = Self.distance(column: column, row: row)
                var intensity = coreRadius > 0 && d <= coreRadius ? Self.coreIntensity : 0
                for ring in rings where abs(d - ring.radius) <= Self.ringHalfWidth {
                    intensity = max(intensity, ring.brightness)
                }
                guard intensity > 0 else { continue }
                frame[column: column, row: row] = MatrixCell(intensity: intensity, heat: Self.restingHeat(column: column, row: row))
            }
        }
        return frame
    }
}
