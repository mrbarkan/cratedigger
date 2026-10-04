import XCTest
@testable import CrateDiggerCore

/// The spectrum used to read as a staircase growing out of the bottom-left
/// corner whatever was playing: music's energy falls with frequency, and an
/// unweighted FFT shows that slope rather than the music. These tests pin the
/// tilt that compensates for it and the floor/ceiling tuned against it.
final class SpectrumTiltTests: XCTestCase {

    // MARK: - The tilt itself

    func testTiltIsZeroAtOneKilohertz() {
        XCTAssertEqual(SpectrumProcessor.tiltDB(centreHz: 1_000), 0, accuracy: 0.0001)
    }

    func testTiltRisesFourAndAHalfDecibelsPerOctave() {
        XCTAssertEqual(SpectrumProcessor.tiltDB(centreHz: 2_000), 4.5, accuracy: 0.0001)
        XCTAssertEqual(SpectrumProcessor.tiltDB(centreHz: 4_000), 9.0, accuracy: 0.0001)
        XCTAssertEqual(SpectrumProcessor.tiltDB(centreHz: 500), -4.5, accuracy: 0.0001)
        XCTAssertEqual(SpectrumProcessor.tiltDB(centreHz: 125), -13.5, accuracy: 0.0001)
    }

    /// The band centres are the geometric means of the 20 Hz – 20 kHz edges,
    /// so the outermost gains land where the spec says: about −24 dB for the
    /// lowest band (≈ 27 Hz) and about +18 dB for the highest (≈ 15 kHz).
    func testBandGainsSpanTheExpectedRange() {
        let gains = SpectrumProcessor.bandGainsDB
        XCTAssertEqual(gains.count, SpectrumProcessor.bandCount)
        XCTAssertEqual(gains.first ?? 0, -23.5, accuracy: 0.5)
        XCTAssertEqual(gains.last ?? 0, 17.6, accuracy: 0.5)
        // 20 Hz – 20 kHz is log2(1000) ≈ 9.97 octaves; one band is a twelfth
        // of that, so neighbours differ by about 3.74 dB.
        for i in 1..<gains.count {
            XCTAssertEqual(gains[i] - gains[i - 1], Float(4.5 * log2(1_000.0) / 12), accuracy: 0.001)
        }
    }

    // MARK: - Pink noise calibration

    /// Pink noise at −18 dBFS RMS is the calibration target: equal energy per
    /// octave, at a level typical of mastered music, should light every band to
    /// about half the column. Levels are averaged over many windows because a
    /// single FFT of noise scatters by several dB per bin, and the meter the
    /// user sees has ballistics doing the same averaging.
    func testPinkNoiseAtMinus18DBFSLightsEveryBandToThreeSegments() {
        let segments = Self.measuredPinkNoiseSegments()
        XCTAssertEqual(segments.count, SpectrumProcessor.bandCount)
        for (band, lit) in segments.enumerated() {
            XCTAssertTrue((2...4).contains(lit), "band \(band) lit \(lit) segments, expected 3 ± 1 (all: \(segments))")
        }
    }

    /// The other side of the window: the ceiling must be low enough that loud
    /// music reaches the top row. Pink noise 6 dB over the calibration level,
    /// about where a loud master's chorus sits, has to bring its hottest band
    /// within a segment and a quarter of the top, so the transients riding
    /// over that level light the peak. At the old −14 dB ceiling it stopped
    /// 1.7 segments short (4.34) and the peak row stayed dark on real tracks;
    /// at −20 it reads 4.86. Any ceiling above about −18.8 dB fails here, as
    /// any below about −24 fails the −18 dBFS calibration above.
    func testPinkNoiseSixDecibelsHotterBringsTheTopBandNearThePeakRow() {
        let levels = Self.measuredPinkNoiseLevels(rmsDBFS: -12)
        let hottest = (levels.max() ?? 0) * 6
        XCTAssertGreaterThanOrEqual(hottest, 4.75, "hottest band at \(hottest) segments of 6 (all: \(levels.map { $0 * 6 }))")
    }

    /// Silence must read as silence: the tilt adds up to +18 dB, and the floor
    /// must still sit above what digital zero produces.
    func testSilenceLightsNothing() {
        let processor = SpectrumProcessor()
        let zeros = [Float](repeating: 0, count: 512)
        var levels: [Float] = []
        for _ in 0..<8 {
            levels = zeros.withUnsafeBufferPointer { processor.compute(samples: $0.baseAddress!, stride: 1, count: 512) }
        }
        XCTAssertTrue(levels.allSatisfy { $0 == 0 }, "\(levels)")
    }

    // MARK: - Helpers

    /// Feeds deterministic pink noise through `compute` in 512-frame chunks,
    /// the size a tap callback typically delivers, and returns the segment
    /// count (out of 6) each band settles at.
    static func measuredPinkNoiseSegments(rmsDBFS: Double = -18) -> [Int] {
        let means = measuredPinkNoiseLevels(rmsDBFS: rmsDBFS)
        return means.map { Int(($0 * 6).rounded()) }
    }

    static func measuredPinkNoiseLevels(rmsDBFS: Double = -18) -> [Double] {
        let chunk = 512
        let warmChunks = SpectrumProcessor.size / chunk   // fills the ring
        let measuredChunks = 400                          // ~4.6 s of audio
        let samples = pinkNoise(count: (warmChunks + measuredChunks) * chunk, rmsDBFS: rmsDBFS)

        let processor = SpectrumProcessor()
        var sums = [Double](repeating: 0, count: SpectrumProcessor.bandCount)
        samples.withUnsafeBufferPointer { buffer in
            for c in 0..<(warmChunks + measuredChunks) {
                let levels = processor.compute(samples: buffer.baseAddress! + c * chunk, stride: 1, count: chunk)
                guard c >= warmChunks else { continue }
                for i in levels.indices { sums[i] += Double(levels[i]) }
            }
        }
        return sums.map { $0 / Double(measuredChunks) }
    }

    /// Paul Kellet's refined pink filter (accurate to ±0.05 dB above 9.2 Hz at
    /// 44.1 kHz) over white noise from a seeded LCG, so every run hears exactly
    /// the same noise. The first second is thrown away while the slowest pole
    /// settles, then the whole buffer is scaled to the requested RMS.
    static func pinkNoise(count: Int, rmsDBFS: Double) -> [Float] {
        var seed: UInt64 = 0x5EED_CAFE_F00D_0001
        func white() -> Double {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(seed >> 11) / Double(1 << 53) * 2 - 1
        }
        var b0 = 0.0, b1 = 0.0, b2 = 0.0, b3 = 0.0, b4 = 0.0, b5 = 0.0, b6 = 0.0
        func pink() -> Double {
            let w = white()
            b0 = 0.99886 * b0 + w * 0.0555179
            b1 = 0.99332 * b1 + w * 0.0750759
            b2 = 0.96900 * b2 + w * 0.1538520
            b3 = 0.86650 * b3 + w * 0.3104856
            b4 = 0.55000 * b4 + w * 0.5329522
            b5 = -0.7616 * b5 - w * 0.0168980
            let out = b0 + b1 + b2 + b3 + b4 + b5 + b6 + w * 0.5362
            b6 = w * 0.115926
            return out
        }
        for _ in 0..<44_100 { _ = pink() }

        var raw = [Double](repeating: 0, count: count)
        var mean = 0.0
        for i in 0..<count { raw[i] = pink(); mean += raw[i] }
        mean /= Double(count)
        var power = 0.0
        for i in 0..<count { raw[i] -= mean; power += raw[i] * raw[i] }
        let rms = (power / Double(count)).squareRoot()
        let gain = pow(10, rmsDBFS / 20) / rms
        return raw.map { Float($0 * gain) }
    }
}
