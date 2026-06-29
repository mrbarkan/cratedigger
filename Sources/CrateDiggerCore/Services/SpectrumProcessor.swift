import Accelerate

/// Turns a stream of PCM samples into 12 log-spaced frequency-band magnitudes
/// (0…1) spanning ~20 Hz – 20 kHz, for the vertical spectrum meter.
///
/// Samples are accumulated into a sliding ring buffer so the FFT window is
/// always full (4096 pts ⇒ ~10 Hz bins) regardless of how many frames each tap
/// callback delivers — that's what lets the low bands actually resolve 20 Hz.
/// Built once and reused on the audio thread; scratch is preallocated.
///
/// The dB window (`floorDB`/`ceilDB`) is the knob to tune if the bars read too
/// hot or too dead. Visual smoothing happens later in `MeterDriver`.
final class SpectrumProcessor {
    static let log2n: vDSP_Length = 12
    static let size = 1 << 12            // 4096-point FFT
    static let half = size / 2
    static let bandCount = 12

    // Assume 44.1 kHz for Hz→bin mapping. ponytail: capture the real rate from
    // the tap's prepare callback if a 48 kHz mislabel ever matters; visually it
    // doesn't.
    private static let sampleRate = 44_100.0
    private let floorDB: Float = -62
    private let ceilDB: Float = -6

    private let setup: FFTSetup
    private var window = [Float](repeating: 0, count: SpectrumProcessor.size)
    private var ring = [Float](repeating: 0, count: SpectrumProcessor.size)
    private var writeIndex = 0
    private var windowed = [Float](repeating: 0, count: SpectrumProcessor.size)
    private var realp = [Float](repeating: 0, count: SpectrumProcessor.half)
    private var imagp = [Float](repeating: 0, count: SpectrumProcessor.half)
    private var mags = [Float](repeating: 0, count: SpectrumProcessor.half)
    private var result = [Float](repeating: 0, count: SpectrumProcessor.bandCount)
    private let bandRanges: [(lo: Int, hi: Int)]

    init() {
        setup = vDSP_create_fftsetup(Self.log2n, FFTRadix(kFFTRadix2))!
        vDSP_hann_window(&window, vDSP_Length(Self.size), Int32(vDSP_HANN_NORM))

        // Log-spaced band edges across 20 Hz … 20 kHz, mapped to FFT bins.
        let minHz = 20.0, maxHz = 20_000.0
        func bin(_ hz: Double) -> Int {
            max(1, min(Self.half - 1, Int((hz * Double(Self.size) / Self.sampleRate).rounded())))
        }
        var ranges: [(lo: Int, hi: Int)] = []
        for b in 0..<Self.bandCount {
            let loHz = minHz * pow(maxHz / minHz, Double(b) / Double(Self.bandCount))
            let hiHz = minHz * pow(maxHz / minHz, Double(b + 1) / Double(Self.bandCount))
            let lo = bin(loHz)
            ranges.append((lo, max(lo + 1, bin(hiHz))))
        }
        bandRanges = ranges
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    /// Append a mono view of `samples` (interleaved channel 0 → `stride = channels`)
    /// to the ring, then compute the 12 band levels (0…1). Returns the internal
    /// buffer — copy it if you need to keep it.
    func compute(samples: UnsafePointer<Float>, stride: Int, count: Int) -> [Float] {
        let n = Self.size

        // Append the newest samples (keep only the last n if a giant buffer lands).
        var srcCount = count
        var srcStart = 0
        if srcCount > n { srcStart = srcCount - n; srcCount = n }
        for i in 0..<srcCount {
            ring[writeIndex] = samples[(srcStart + i) * stride]
            writeIndex = (writeIndex + 1) % n
        }

        // Reorder ring (oldest → newest) into `windowed`, then apply the window.
        let firstPart = n - writeIndex
        ring.withUnsafeBufferPointer { rp in
            windowed.withUnsafeMutableBufferPointer { wp in
                cblas_scopy(Int32(firstPart), rp.baseAddress! + writeIndex, 1, wp.baseAddress!, 1)
                if writeIndex > 0 {
                    cblas_scopy(Int32(writeIndex), rp.baseAddress!, 1, wp.baseAddress! + firstPart, 1)
                }
            }
        }
        vDSP_vmul(windowed, 1, window, 1, &windowed, 1, vDSP_Length(n))

        // Real FFT via the even/odd split-complex packing trick.
        realp.withUnsafeMutableBufferPointer { rp in
            imagp.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBufferPointer { wp in
                    wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { cp in
                        vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(n / 2))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, Self.log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &mags, 1, vDSP_Length(Self.half))
            }
        }

        // Per band: mean power → amplitude → dB → 0…1.
        let nf = Float(n)
        for (i, range) in bandRanges.enumerated() {
            let hi = min(range.hi, Self.half)
            var level: Float = 0
            if hi > range.lo {
                var sum: Float = 0
                mags.withUnsafeBufferPointer { mp in
                    vDSP_sve(mp.baseAddress! + range.lo, 1, &sum, vDSP_Length(hi - range.lo))
                }
                let amp = sqrt(sum / Float(hi - range.lo)) / nf
                let db = 20 * log10(amp + 1e-7)
                level = min(max((db - floorDB) / (ceilDB - floorDB), 0), 1)
            }
            result[i] = level
        }
        return result
    }
}
