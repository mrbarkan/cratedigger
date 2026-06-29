import Accelerate
import Foundation

/// A real 12-band graphic EQ applied in the audio path: a cascade of peaking
/// biquad filters (one per band) run in-place on the tap's samples, so playback
/// actually changes. Bands are log-spaced 20 Hz – 20 kHz to match the meters.
///
/// Coefficients are recomputed on the audio thread only when the gains change
/// (cheap, RBJ cookbook). Per-channel delay state persists across callbacks.
/// `ponytail:` assumes 44.1 kHz for coefficient math — a 48 kHz file shifts the
/// band centers ~9%, inaudible for a tone-shaping EQ.
public final class EqualizerProcessor {
    public static let bandCount = 12

    private static let sampleRate = 44_100.0
    private static let q = 1.41                  // ~⅔-octave peaking bands
    private static let maxChannels = 8
    private static let delayLen = 2 * bandCount + 2

    /// Geometric band-center frequencies (Hz), low → high.
    public static let centerFrequencies: [Double] = {
        let minHz = 20.0, maxHz = 20_000.0
        return (0..<bandCount).map { b in
            minHz * pow(maxHz / minHz, (Double(b) + 0.5) / Double(bandCount))
        }
    }()

    private var setup: vDSP_biquad_Setup
    private var coeffs = [Double](repeating: 0, count: 5 * bandCount)
    private var delays: [[Float]]

    private let lock = NSLock()
    private var gains = [Double](repeating: 0, count: bandCount)   // dB
    private var enabled = false
    private var version = 0
    private var appliedVersion = -1

    public init() {
        delays = (0..<Self.maxChannels).map { _ in [Float](repeating: 0, count: Self.delayLen) }
        Self.fillCoeffs(&coeffs, gainsDB: gains)
        setup = coeffs.withUnsafeBufferPointer {
            vDSP_biquad_CreateSetup($0.baseAddress!, vDSP_Length(Self.bandCount))!
        }
    }

    deinit { vDSP_biquad_DestroySetup(setup) }

    // MARK: - Control (main thread)

    public func update(enabled: Bool, gainsDB: [Double]) {
        lock.lock()
        self.enabled = enabled
        for i in 0..<gains.count { gains[i] = i < gainsDB.count ? gainsDB[i] : 0 }
        version += 1
        lock.unlock()
    }

    public var isEnabled: Bool {
        lock.lock(); defer { lock.unlock() }
        return enabled
    }

    // MARK: - Processing (audio thread)

    /// Filter one channel's samples in place. `channel` indexes the per-channel
    /// delay state (stereo → 0 and 1).
    public func processInPlace(_ samples: UnsafeMutablePointer<Float>, stride: Int, frames: Int, channel: Int) {
        guard channel < Self.maxChannels, frames > 0 else { return }
        refreshCoeffsIfNeeded()
        delays[channel].withUnsafeMutableBufferPointer { dp in
            vDSP_biquad(setup, dp.baseAddress!,
                        samples, vDSP_Stride(stride),
                        samples, vDSP_Stride(stride),
                        vDSP_Length(frames))
        }
    }

    private func refreshCoeffsIfNeeded() {
        lock.lock()
        let v = version
        guard v != appliedVersion else { lock.unlock(); return }
        let snapshot = gains
        lock.unlock()

        Self.fillCoeffs(&coeffs, gainsDB: snapshot)
        coeffs.withUnsafeBufferPointer {
            vDSP_biquad_SetCoefficientsDouble(setup, $0.baseAddress!, 0, vDSP_Length(Self.bandCount))
        }
        appliedVersion = v
    }

    /// RBJ peaking-EQ coefficients per band, normalized so a0 = 1 → [b0,b1,b2,a1,a2].
    private static func fillCoeffs(_ out: inout [Double], gainsDB: [Double]) {
        for b in 0..<bandCount {
            let g = b < gainsDB.count ? gainsDB[b] : 0
            let A = pow(10.0, g / 40.0)
            let w0 = 2 * Double.pi * centerFrequencies[b] / sampleRate
            let cw = cos(w0)
            let alpha = sin(w0) / (2 * q)
            let a0 = 1 + alpha / A
            let base = b * 5
            out[base + 0] = (1 + alpha * A) / a0   // b0
            out[base + 1] = (-2 * cw) / a0          // b1
            out[base + 2] = (1 - alpha * A) / a0    // b2
            out[base + 3] = (-2 * cw) / a0          // a1
            out[base + 4] = (1 - alpha / A) / a0    // a2
        }
    }
}
