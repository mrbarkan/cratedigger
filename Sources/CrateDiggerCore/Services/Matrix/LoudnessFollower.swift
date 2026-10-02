import Foundation

/// Turns `MatrixInput.loudness` into a drive that swings with the music.
///
/// Loudness itself barely moves within a song: measured on ordinary mastered
/// tracks it sits around 0.3–0.55 with a standard deviation of only 0.04–0.08,
/// so anything sized straight off it (Frame's depth, the Explosions core)
/// froze at one size whatever was playing. A master's absolute level says
/// nothing about where its loud moments are, so the follower measures the
/// song against itself instead: it keeps a running mean and a running mean
/// absolute deviation of the loudness, and reports where the current reading
/// sits between two spreads below the mean (0) and two spreads above it (1).
/// A typical moment reads about 0.5; a hit or a chorus pushes toward 1, a
/// breakdown toward 0.
///
/// The spread has a floor, so a near-constant signal (a steady tone, pink
/// noise) reads as a calm 0.5 rather than having its jitter blown up to fill
/// the whole range.
///
/// Silence comes in two kinds. A reading of exactly 0 is the meter settled
/// after playback stopped (`MeterDriver` snaps a faded-out signal to 0, and
/// only then), and forgets the song at once. A reading that is merely under
/// `silenceGate` is a quiet moment inside the music, a stop-time break or
/// the tail of a fade: the drive is 0, but the statistics are held for
/// `silenceHold`, so the hit that ends a break reads as loud against the
/// song rather than as the calm seed of a new one, and a fade dithering
/// across the gate doesn't re-seed (and jump to 0.5) on every crossing.
public struct LoudnessFollower: Sendable {
    /// Seconds for the mean and spread to follow a change. Long enough that
    /// a beat or a fill stands out against them, short enough that a quiet
    /// verse after a loud chorus becomes the new normal within a few bars.
    /// A step longer than this (the window was hidden, the main thread
    /// stalled) re-seeds rather than weighting one reading by nearly all of
    /// it, which would leave the spread at that reading's deviation and
    /// mute the drive for seconds.
    static let timeConstant: TimeInterval = 2
    /// How many spreads the 0…1 range spans, centred on the mean: 4 puts the
    /// ends at ±2 spreads.
    static let spreadsAcrossRange = 4.0
    /// The smallest spread the mapping divides by. Pink noise through the
    /// meter's ballistics wobbles by a mean deviation of about 0.008, music's
    /// short-term spread is several times that, so 0.025 keeps noise near 0.5
    /// (±0.1) while leaving even a compressed master its full swing.
    static let spreadFloor = 0.025
    /// Loudness below this is silence: the drive is 0 and the statistics stop
    /// following.
    static let silenceGate = 0.02
    /// How long the loudness has to stay under the gate before the song's
    /// statistics are forgotten: longer than a stop-time break, shorter than
    /// the gap between most tracks.
    static let silenceHold: TimeInterval = 0.75

    private var mean = 0.0
    private var spread = 0.0
    /// Readings folded into the statistics since they were last seeded; zero
    /// means there is nothing to measure against and the next sound seeds
    /// afresh.
    private var heard = 0
    /// Whether the last reading was at or above the gate.
    private var gateOpen = false
    /// Seconds the loudness has stayed under the gate.
    private var quietFor: TimeInterval = 0

    public init() {}

    /// True while the gate is closed: the last reading was under the silence
    /// gate, or nothing has been heard yet. The statistics may still be held
    /// (see `silenceHold`); this only says the drive is 0 for silence.
    public var isSilent: Bool { !gateOpen }

    /// Forget everything heard: the next sound seeds the statistics afresh.
    public mutating func reset() {
        mean = 0
        spread = 0
        heard = 0
        gateOpen = false
        quietFor = 0
    }

    /// Hear one reading, `dt` seconds after the last, and answer the drive in
    /// 0…1.
    public mutating func drive(loudness: Double, dt: TimeInterval) -> Double {
        let loudness = loudness.isNaN ? 0 : loudness
        let dt = dt.isNaN ? 0 : max(dt, 0)
        guard loudness != 0 else {
            reset()
            return 0
        }
        guard loudness >= Self.silenceGate else {
            gateOpen = false
            quietFor += dt
            if quietFor >= Self.silenceHold { reset() }
            return 0
        }
        gateOpen = true
        quietFor = 0
        guard heard > 0, dt <= Self.timeConstant else {
            // The first sound after silence (or after a gap the statistics
            // can't speak for) becomes the mean, so resuming playback reads
            // as a calm 0.5 rather than climbing from zero and pinning the
            // drive at 1 for the length of the time constant.
            mean = loudness
            spread = 0
            heard = 1
            return 0.5
        }

        let deviation = loudness - mean
        let drive = 0.5 + deviation / (Self.spreadsAcrossRange * max(spread, Self.spreadFloor))

        // Exponential smoothing at `timeConstant`, except while it has heard
        // fewer readings than that: then a plain average of everything since
        // the seed, so a first reading caught mid-attack can't skew the mean
        // for seconds after.
        let weight = max(1 - exp(-dt / Self.timeConstant), 1 / Double(heard + 1))
        mean += deviation * weight
        spread += (abs(deviation) - spread) * weight
        heard += 1

        return min(max(drive, 0), 1)
    }
}
