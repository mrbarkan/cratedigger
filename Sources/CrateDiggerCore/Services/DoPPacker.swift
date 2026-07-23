import Foundation

/// DoP (DSD over PCM, spec 1.1): each 24-bit PCM frame carries a marker byte
/// (0x05/0xFA alternating per frame) in bits 23–16 and 16 DSD bits — two bytes,
/// chronologically older in bits 15–8 — below it. A DAC that sees the marker
/// sequence unpacks the DSD stream bit-perfectly; anything that modifies the
/// samples (volume, EQ, SRC) destroys the markers, so the DoP path must stay
/// untouched end to end.
public enum DoPPacker {
    public static let markers: [UInt8] = [0x05, 0xFA]

    /// Bit-reversal LUT: DSF stores each byte LSB-first (earliest bit = LSB);
    /// DoP wants the earliest bit in the MSB.
    static let reversed: [UInt8] = (0...255).map { value in
        var v = UInt8(value), r: UInt8 = 0
        for _ in 0..<8 { r = (r << 1) | (v & 1); v >>= 1 }
        return r
    }

    public static func word(marker: UInt8, older: UInt8, newer: UInt8, lsbFirst: Bool) -> Int32 {
        let hi = lsbFirst ? reversed[Int(older)] : older
        let lo = lsbFirst ? reversed[Int(newer)] : newer
        let raw = UInt32(marker) << 16 | UInt32(hi) << 8 | UInt32(lo)
        // Sign-extend 24-bit → 32-bit.
        return Int32(bitPattern: raw << 8) >> 8
    }

    /// 24-bit ints are exactly representable in Float32 (24-bit mantissa), so
    /// a unity-gain float path delivers the words to the HAL bit-perfectly.
    public static func float(fromWord word: Int32) -> Float {
        Float(word) / 8_388_608
    }
}

/// A DSD stream's 1-bit duty cycle tracks instantaneous amplitude: 50% ones is
/// silence, all-ones/all-zeros is full scale. Mean |duty − ½| × 2 over a window
/// gives an honest, decode-free VU level for the bit-perfect path.
public enum DSDLevelMeter {
    static let onesCount: [Double] = (0...255).map { Double($0.nonzeroBitCount) }

    public static func amplitude(of bytes: some Sequence<UInt8>) -> Double {
        var sum = 0.0
        var count = 0
        for byte in bytes {
            sum += abs(onesCount[Int(byte)] / 4.0 - 1.0)
            count += 1
        }
        return count == 0 ? 0 : sum / Double(count)
    }
}
