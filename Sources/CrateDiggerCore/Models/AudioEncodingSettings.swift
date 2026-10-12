import Foundation

/// The audio half of a conversion: which encoder runs and the knobs that
/// encoder actually has.
///
/// The knobs differ by format, and offering the wrong ones is how a FLAC
/// conversion ended up showing a bitrate (lossless encoders have none; the
/// rate falls out of how well the audio compresses) and how Opus defaulted to
/// 44.1 kHz, a rate libopus refuses outright. `normalized()` is the one place
/// that maps whatever a selection remembers onto what the format honours, so
/// the Patch Bay, the preset matcher and the ffmpeg preset all agree.
///
/// `nil` sample rate and bit depth mean "keep the source's", which is what an
/// archive of a hi-res capture needs: forcing 44.1 kHz on a 24/96 needle drop
/// throws resolution away.
public struct AudioEncodingSettings: Hashable, Codable, Sendable {
    public var format: OutputFormat
    public var bitrateKbps: Int?
    public var sampleRateHz: Int?
    public var bitDepth: Int?
    public var flacCompressionLevel: Int?

    public init(
        format: OutputFormat,
        bitrateKbps: Int? = nil,
        sampleRateHz: Int? = nil,
        bitDepth: Int? = nil,
        flacCompressionLevel: Int? = nil
    ) {
        self.format = format
        self.bitrateKbps = bitrateKbps
        self.sampleRateHz = sampleRateHz
        self.bitDepth = bitDepth
        self.flacCompressionLevel = flacCompressionLevel
    }

    /// What the format honours, with anything it ignores cleared and anything
    /// out of range replaced by the format's default.
    ///
    /// The stored selection is deliberately left raw: switching FLAC → AAC →
    /// FLAC should come back to the bit depth you picked, not a reset one.
    public func normalized() -> AudioEncodingSettings {
        var out = self
        let format = self.format

        if format.usesBitrate {
            if let rate = bitrateKbps, OutputFormat.bitrateOptions.contains(rate) {
                out.bitrateKbps = rate
            } else {
                out.bitrateKbps = OutputFormat.defaultBitrateKbps
            }
        } else {
            out.bitrateKbps = nil
        }

        if !format.sampleRateOptions.contains(sampleRateHz) {
            out.sampleRateHz = nil
        }

        let depths = format.bitDepthOptions
        if depths.isEmpty {
            out.bitDepth = nil
        } else if !depths.contains(bitDepth) {
            out.bitDepth = format.defaultBitDepth
        }

        let levels = format.compressionLevelOptions
        if levels.isEmpty {
            out.flacCompressionLevel = nil
        } else if let level = flacCompressionLevel, levels.contains(level) {
            out.flacCompressionLevel = level
        } else {
            out.flacCompressionLevel = OutputFormat.defaultFLACCompressionLevel
        }

        return out
    }

    /// One line for a menu or a readout, e.g. "FLAC · 16-bit · 44.1 kHz".
    public var summary: String {
        let s = normalized()
        var parts = [s.format.displayName]
        if let kbps = s.bitrateKbps {
            parts.append("\(kbps) kbps")
        }
        if s.format.isLossless {
            switch (s.bitDepth, s.sampleRateHz) {
            case (nil, nil):
                parts.append("Source resolution")
            case let (depth, rate):
                parts.append(depth.map { "\($0)-bit" } ?? "Source depth")
                parts.append(rate.map(Self.kilohertz) ?? "Source rate")
            }
        } else if let rate = s.sampleRateHz {
            parts.append(Self.kilohertz(rate))
        } else if let fixed = s.format.fixedSampleRateHz {
            parts.append(Self.kilohertz(fixed))
        }
        return parts.joined(separator: " · ")
    }

    /// Rough output rate for the size estimate, per track. Lossless sizes
    /// depend on the source, so this needs the track's own sample rate when
    /// the settings keep it.
    public func estimatedKbps(sourceSampleRateHz: Int?) -> Double {
        let s = normalized()
        if let kbps = s.bitrateKbps { return Double(kbps) }
        let rate = s.sampleRateHz ?? sourceSampleRateHz ?? 44_100
        // Hi-res captures are nearly always 24-bit; CD-rate sources 16-bit.
        let depth = s.bitDepth ?? (rate > 48_000 ? 24 : 16)
        let pcmKbps = Double(rate * depth * 2) / 1000.0
        switch s.format {
        case .flac, .alac:
            // Typical lossless compression on music lands near 60%.
            return pcmKbps * 0.6
        default:
            return pcmKbps
        }
    }

    static func kilohertz(_ hz: Int) -> String {
        hz % 1000 == 0
            ? "\(hz / 1000) kHz"
            : String(format: "%.1f kHz", Double(hz) / 1000.0)
    }
}

public extension OutputFormat {
    /// Lossy encoders are steered by a bitrate. Lossless ones have nothing to
    /// steer: the size is whatever the audio compresses to.
    var usesBitrate: Bool { !isLossless }

    static let bitrateOptions: [Int] = [96, 128, 160, 192, 256, 320]
    static let defaultBitrateKbps = 192

    /// Rates the encoder accepts, `nil` = keep the source's.
    ///
    /// Opus only runs at 48 kHz (libopus rejects 44.1 kHz and ffmpeg fails the
    /// job), so it offers the source option alone and lets ffmpeg pick 48 kHz.
    /// MP3, AAC and Vorbis stop at 48 kHz: a hi-res rate buys nothing in a
    /// lossy file.
    var sampleRateOptions: [Int?] {
        switch self {
        case .opus:
            return [nil]
        case .mp3, .aac, .ogg:
            return [nil, 44_100, 48_000]
        case .alac, .flac, .wav, .aiff:
            return [nil, 44_100, 48_000, 88_200, 96_000]
        }
    }

    /// The rate the encoder always runs at, when it has only one.
    var fixedSampleRateHz: Int? {
        self == .opus ? 48_000 : nil
    }

    /// Bit depths on offer, `nil` = keep the source's.
    ///
    /// FLAC and ALAC can follow the source because their encoders take
    /// whatever sample format the decoder hands them. WAV and AIFF are fixed
    /// PCM codecs, so they need a depth named, and 16 is what they wrote
    /// before the choice existed.
    var bitDepthOptions: [Int?] {
        switch self {
        case .flac, .alac:
            return [nil, 16, 24]
        case .wav, .aiff:
            return [16, 24]
        case .mp3, .aac, .ogg, .opus:
            return []
        }
    }

    var defaultBitDepth: Int? {
        switch self {
        case .wav, .aiff: return 16
        default:          return nil
        }
    }

    /// FLAC's speed/size dial. Every level is lossless; higher only spends
    /// more encode time for a smaller file. ffmpeg's default is 5.
    var compressionLevelOptions: [Int] {
        self == .flac ? [0, 5, 8] : []
    }

    static let defaultFLACCompressionLevel = 5

    var displayName: String {
        switch self {
        case .mp3:  return "MP3"
        case .aac:  return "AAC"
        case .alac: return "ALAC"
        case .flac: return "FLAC"
        case .wav:  return "WAV"
        case .aiff: return "AIFF"
        case .ogg:  return "Ogg Vorbis"
        case .opus: return "Opus"
        }
    }
}
