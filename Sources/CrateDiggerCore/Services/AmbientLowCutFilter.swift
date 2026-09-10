import Foundation

/// Ambient's low cut: a 2nd-order Butterworth high-pass at 120 Hz, so mains
/// hum, fridge drone and footsteps drop away while voices and doorbells come
/// through. A plain biquad (the RBJ cookbook high-pass) rather than an
/// `AVAudioUnitEQ`, because the engines no longer run inside `AVAudioEngine`.
///
/// Mono, processed in place, one IO buffer at a time. The filter's memory
/// carries across calls, so buffer boundaries don't click.
public struct AmbientLowCutFilter {
    public var isEnabled = true {
        // Coming back on with memory from before would start on a jump.
        didSet { if isEnabled != oldValue { reset() } }
    }

    private let b0: Double, b1: Double, b2: Double, a1: Double, a2: Double
    private var z1 = 0.0, z2 = 0.0

    public init(sampleRate: Double, cutoff: Double = 120) {
        let w0 = 2 * Double.pi * cutoff / sampleRate
        let cosW0 = cos(w0)
        let alpha = sin(w0) / (2 * (1 / 2.0.squareRoot()))   // Butterworth: Q = 1/√2
        let a0 = 1 + alpha
        b0 = (1 + cosW0) / 2 / a0
        b1 = -(1 + cosW0) / a0
        b2 = (1 + cosW0) / 2 / a0
        a1 = -2 * cosW0 / a0
        a2 = (1 - alpha) / a0
    }

    public mutating func process(_ samples: UnsafeMutablePointer<Float>, frameCount: Int) {
        guard isEnabled else { return }
        for index in 0..<frameCount {
            // Transposed direct form II.
            let x = Double(samples[index])
            let y = b0 * x + z1
            z1 = b1 * x - a1 * y + z2
            z2 = b2 * x - a2 * y
            samples[index] = Float(y)
        }
    }

    private mutating func reset() {
        z1 = 0
        z2 = 0
    }
}
