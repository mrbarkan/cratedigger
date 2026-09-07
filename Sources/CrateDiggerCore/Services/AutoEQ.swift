import Foundation

/// Import of AutoEQ "ParametricEQ" text — the de-facto format shared by
/// squig.link's EQ panel, AutoEQ itself, oratory1990's sheets, Wavelet and
/// Poweramp:
///
///     Preamp: -6.1 dB
///     Filter 1: ON PK Fc 105 Hz Gain -2.5 dB Q 0.80
///     Filter 2: ON LSC Fc 105 Hz Gain 5.5 dB Q 0.70
///
/// The point of parsing the *format* rather than talking to any one site is
/// that squig.link is a family of independent static sites with no API — but
/// every one of them exports this.

// MARK: - Model

public struct AutoEQFilter: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case peaking, lowShelf, highShelf }

    public var kind: Kind
    public var frequency: Double
    public var gainDB: Double
    public var q: Double

    public init(kind: Kind, frequency: Double, gainDB: Double, q: Double) {
        self.kind = kind
        self.frequency = frequency
        self.gainDB = gainDB
        self.q = max(q, 0.05)
    }
}

public struct AutoEQProfile: Equatable, Sendable {
    /// AutoEQ's headroom attenuation. Parsed and reported, but never applied:
    /// the graphic EQ has no makeup-gain stage, so folding a constant −6 dB
    /// into 12 band gains would spend the whole range on volume.
    public var preampDB: Double
    public var filters: [AutoEQFilter]
    /// Filter lines that were recognised as filters but whose type this EQ
    /// can't represent (low-pass, high-pass, notch…).
    public var unsupportedCount: Int

    public var isEmpty: Bool { filters.isEmpty }
}

// MARK: - Parsing

public enum AutoEQParser {
    /// Lenient by design: unknown lines, `OFF` filters and stray prose are
    /// skipped rather than failing the paste. An empty `filters` is how the
    /// caller learns nothing usable was found.
    public static func parse(_ text: String) -> AutoEQProfile {
        var preamp = 0.0
        var filters: [AutoEQFilter] = []
        var unsupported = 0

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if line.lowercased().hasPrefix("preamp") {
                if let value = firstNumber(after: ":", in: line) { preamp = value }
                continue
            }
            guard line.lowercased().hasPrefix("filter") else { continue }

            let tokens = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard let onIndex = tokens.firstIndex(where: { $0.caseInsensitiveCompare("ON") == .orderedSame }),
                  onIndex + 1 < tokens.count else { continue }        // OFF or malformed

            guard let kind = kind(for: tokens[onIndex + 1]) else {
                unsupported += 1
                continue
            }
            guard let fc = number(labelled: "Fc", in: tokens),
                  let gain = number(labelled: "Gain", in: tokens) else { continue }
            // A shelf written without a Q gets the RBJ default.
            let q = number(labelled: "Q", in: tokens) ?? 0.707

            filters.append(AutoEQFilter(kind: kind, frequency: fc, gainDB: gain, q: q))
        }

        return AutoEQProfile(preampDB: preamp, filters: filters, unsupportedCount: unsupported)
    }

    private static func kind(for token: String) -> AutoEQFilter.Kind? {
        switch token.uppercased() {
        case "PK", "PEQ", "MODAL":  return .peaking
        case "LS", "LSC", "LSQ":    return .lowShelf
        case "HS", "HSC", "HSQ":    return .highShelf
        default:                    return nil
        }
    }

    /// The number following `label` — `Fc 105 Hz` → 105.
    private static func number(labelled label: String, in tokens: [String]) -> Double? {
        guard let index = tokens.firstIndex(where: { $0.caseInsensitiveCompare(label) == .orderedSame }),
              index + 1 < tokens.count else { return nil }
        return Double(tokens[index + 1].replacingOccurrences(of: ",", with: "."))
    }

    private static func firstNumber(after separator: String, in line: String) -> Double? {
        let tail = line.components(separatedBy: separator).dropFirst().joined(separator: separator)
        for token in tail.split(whereSeparator: \.isWhitespace) {
            if let value = Double(token.replacingOccurrences(of: ",", with: ".")) { return value }
        }
        return nil
    }
}

// MARK: - Mapping onto the graphic EQ

public enum AutoEQMapper {
    public struct Result: Equatable, Sendable {
        /// One gain per graphic-EQ band, already clamped to the fader range.
        public var gains: [Double]
        /// Bands that wanted more than the faders can give.
        public var clampedBands: Int
        /// RMS error (dB) between the parametric curve and the fitted one over
        /// 20 Hz – 20 kHz. Small numbers mean the 12 bands caught the shape.
        public var fitErrorDB: Double
    }

    /// The parametric curve sampled onto the graphic EQ.
    ///
    /// Reading the target off at each band centre would overshoot badly: the
    /// bands are ⅔-octave peaks less than an octave apart, so each one's
    /// skirts land on its neighbours' centres. Instead this solves for the
    /// gain set whose *combined* response best matches the target across the
    /// spectrum — the same thing a hardware EQ's user does by ear, done once.
    public static func map(_ profile: AutoEQProfile,
                           centers: [Double] = EqualizerProcessor.centerFrequencies,
                           bandQ: Double = EqualizerProcessor.bandQ,
                           limit: Double = 12) -> Result {
        let grid = logGrid(from: 20, to: 20_000, count: 240)
        let target = grid.map { f in
            profile.filters.reduce(0) { $0 + response(of: $1, at: f) }
        }

        // Unit-gain shape of each band across the grid. Peaking response in dB
        // is near-linear in gain over ±12 dB, so one basis row scales.
        let basis: [[Double]] = centers.map { fc in
            let unit = AutoEQFilter(kind: .peaking, frequency: fc, gainDB: 1, q: bandQ)
            return grid.map { response(of: unit, at: $0) }
        }

        let n = centers.count
        // Normal equations AᵀA g = Aᵀt, ridged so a band with nothing to do
        // settles at 0 instead of chasing its neighbours.
        var matrix = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
        var rhs = [Double](repeating: 0, count: n)
        for i in 0..<n {
            for j in i..<n {
                let dot = zip(basis[i], basis[j]).reduce(0) { $0 + $1.0 * $1.1 }
                matrix[i][j] = dot
                matrix[j][i] = dot
            }
            matrix[i][i] += 1e-3
            rhs[i] = zip(basis[i], target).reduce(0) { $0 + $1.0 * $1.1 }
        }

        let solved = solve(matrix, rhs) ?? [Double](repeating: 0, count: n)
        var clamped = 0
        let gains = solved.map { value -> Double in
            let snapped = (value * 2).rounded() / 2          // the faders' 0.5 dB step
            if abs(snapped) > limit { clamped += 1 }
            return min(max(snapped, -limit), limit)
        }

        // How well the fitted bands actually reproduce the curve.
        var sumSquares = 0.0
        for (index, t) in target.enumerated() {
            let fitted = (0..<n).reduce(0.0) { $0 + gains[$1] * basis[$1][index] }
            sumSquares += (fitted - t) * (fitted - t)
        }
        let rms = target.isEmpty ? 0 : (sumSquares / Double(target.count)).squareRoot()

        return Result(gains: gains, clampedBands: clamped, fitErrorDB: rms)
    }

    /// The parametric curve itself, for drawing a preview.
    public static func curve(_ profile: AutoEQProfile, at frequencies: [Double]) -> [Double] {
        frequencies.map { f in profile.filters.reduce(0) { $0 + response(of: $1, at: f) } }
    }

    /// The graphic EQ's combined response for a gain set, for drawing a preview.
    public static func curve(forGains gains: [Double],
                             at frequencies: [Double],
                             centers: [Double] = EqualizerProcessor.centerFrequencies,
                             bandQ: Double = EqualizerProcessor.bandQ) -> [Double] {
        frequencies.map { f in
            zip(centers, gains).reduce(0) { sum, pair in
                sum + response(of: AutoEQFilter(kind: .peaking, frequency: pair.0,
                                                gainDB: pair.1, q: bandQ), at: f)
            }
        }
    }

    public static func logGrid(from low: Double, to high: Double, count: Int) -> [Double] {
        (0..<count).map { low * pow(high / low, Double($0) / Double(count - 1)) }
    }

    // MARK: - Biquad response (RBJ cookbook, matching EqualizerProcessor)

    /// Magnitude response in dB of one filter at `frequency`, evaluated on the
    /// same 44.1 kHz digital design the audio path uses — so what the preview
    /// draws is what the cascade will do.
    static func response(of filter: AutoEQFilter, at frequency: Double) -> Double {
        let fs = 44_100.0
        let a = pow(10, filter.gainDB / 40)
        let w0 = 2 * Double.pi * min(filter.frequency, fs / 2 - 1) / fs
        let cosw = cos(w0)
        let alpha = sin(w0) / (2 * filter.q)
        let sqrtA = a.squareRoot()

        let b0, b1, b2, a0, a1, a2: Double
        switch filter.kind {
        case .peaking:
            b0 = 1 + alpha * a;  b1 = -2 * cosw;  b2 = 1 - alpha * a
            a0 = 1 + alpha / a;  a1 = -2 * cosw;  a2 = 1 - alpha / a
        case .lowShelf:
            let twoSqrtAlpha = 2 * sqrtA * alpha
            b0 =     a * ((a + 1) - (a - 1) * cosw + twoSqrtAlpha)
            b1 = 2 * a * ((a - 1) - (a + 1) * cosw)
            b2 =     a * ((a + 1) - (a - 1) * cosw - twoSqrtAlpha)
            a0 =         (a + 1) + (a - 1) * cosw + twoSqrtAlpha
            a1 =    -2 * ((a - 1) + (a + 1) * cosw)
            a2 =         (a + 1) + (a - 1) * cosw - twoSqrtAlpha
        case .highShelf:
            let twoSqrtAlpha = 2 * sqrtA * alpha
            b0 =      a * ((a + 1) + (a - 1) * cosw + twoSqrtAlpha)
            b1 = -2 * a * ((a - 1) + (a + 1) * cosw)
            b2 =      a * ((a + 1) + (a - 1) * cosw - twoSqrtAlpha)
            a0 =          (a + 1) - (a - 1) * cosw + twoSqrtAlpha
            a1 =      2 * ((a - 1) - (a + 1) * cosw)
            a2 =          (a + 1) - (a - 1) * cosw - twoSqrtAlpha
        }

        let w = 2 * Double.pi * min(frequency, fs / 2 - 1) / fs
        let numerator = magnitude(b0, b1, b2, at: w)
        let denominator = magnitude(a0, a1, a2, at: w)
        guard denominator > 0 else { return 0 }
        return 20 * log10(numerator / denominator)
    }

    private static func magnitude(_ c0: Double, _ c1: Double, _ c2: Double, at w: Double) -> Double {
        let real = c0 + c1 * cos(w) + c2 * cos(2 * w)
        let imag = -(c1 * sin(w) + c2 * sin(2 * w))
        return (real * real + imag * imag).squareRoot()
    }

    /// Gaussian elimination with partial pivoting. 12×12 once per import —
    /// no reason to reach for LAPACK.
    private static func solve(_ a: [[Double]], _ b: [Double]) -> [Double]? {
        var m = a, v = b
        let n = v.count
        for col in 0..<n {
            guard let pivot = (col..<n).max(by: { abs(m[$0][col]) < abs(m[$1][col]) }),
                  abs(m[pivot][col]) > 1e-12 else { return nil }
            m.swapAt(col, pivot); v.swapAt(col, pivot)

            for row in (col + 1)..<n {
                let factor = m[row][col] / m[col][col]
                guard factor != 0 else { continue }
                for k in col..<n { m[row][k] -= factor * m[col][k] }
                v[row] -= factor * v[col]
            }
        }
        var x = [Double](repeating: 0, count: n)
        for row in stride(from: n - 1, through: 0, by: -1) {
            let sum = ((row + 1)..<n).reduce(0.0) { $0 + m[row][$1] * x[$1] }
            x[row] = (v[row] - sum) / m[row][row]
        }
        return x
    }
}
