import Foundation

/// Where the audio came from, so a rip can be encoded at what that medium
/// actually holds: 16-bit/44.1 kHz for a CD, the capture's own resolution for
/// a needle drop, DSD rendered as 24/88.2 PCM for an SACD.
///
/// Paired with a `RipTier` (1:1, Lossless, Lossy), which picks the codec
/// class. The medium decides the resolution; the tier decides the encoding;
/// the FORMAT and BITRATE rows still pick the flavour within a tier (FLAC or
/// ALAC, AAC 256 or MP3 320).
public enum PhysicalMedium: String, CaseIterable, Codable, Sendable {
    case cd
    case miniDisc
    case sacd
    case dvdAudio
    case bluRay
    case bluRayAudio
    case vinyl
    case tape
    /// Not a medium: library files of mixed origin, each kept at its own
    /// resolution. The default, so an ordinary conversion is never pinned
    /// to a disc's spec by a tier key pressed for a rip.
    case anySource

    public enum Group: String, CaseIterable, Sendable {
        case disc, analog, other

        public var title: String {
            switch self {
            case .disc:   return "Disc"
            case .analog: return "Analog"
            case .other:  return "Other"
            }
        }
    }

    public var group: Group {
        switch self {
        case .cd, .miniDisc, .sacd, .dvdAudio, .bluRay, .bluRayAudio: return .disc
        case .vinyl, .tape:                                            return .analog
        case .anySource:                                               return .other
        }
    }

    public static var grouped: [(group: Group, media: [PhysicalMedium])] {
        Group.allCases.map { group in (group, allCases.filter { $0.group == group }) }
    }

    public var title: String {
        switch self {
        case .cd:          return "CD"
        case .miniDisc:    return "MiniDisc"
        case .sacd:        return "SACD"
        case .dvdAudio:    return "DVD-Audio"
        case .bluRay:      return "Blu-ray"
        case .bluRayAudio: return "Blu-ray Audio"
        case .vinyl:       return "Vinyl"
        case .tape:        return "Tape"
        case .anySource:   return "Any Source"
        }
    }

    /// What the medium carries, in a line.
    public var nativeSpec: String {
        switch self {
        case .cd:          return "16-bit · 44.1 kHz"
        case .miniDisc:    return "ATRAC, played out as 16-bit · 44.1 kHz"
        case .sacd:        return "DSD64, as 24-bit · 88.2 kHz PCM"
        case .dvdAudio:    return "24-bit · up to 192 kHz"
        case .bluRay:      return "24-bit · 48 kHz, sometimes 96"
        case .bluRayAudio: return "24-bit · 96 or 192 kHz"
        case .vinyl:       return "Analog capture, kept as recorded"
        case .tape:        return "Analog capture, kept as recorded"
        case .anySource:   return "Each file's own resolution"
        }
    }

    /// A caveat worth reading before choosing a tier, if there is one.
    public var note: String? {
        switch self {
        case .miniDisc:
            return "ATRAC is already lossy: 1:1 and Lossless keep what the disc has, they can't restore what it dropped."
        case .sacd:
            return "DSD has no lossless PCM equivalent; 88.2 kHz is the standard conversion of DSD64."
        case .bluRay, .bluRayAudio, .dvdAudio:
            return "Rip the disc to files first; these settings shape the conversion. Multichannel layouts are kept."
        default:
            return nil
        }
    }

    /// Bit depth for 1:1 and Lossless. `nil` keeps the source's, which only
    /// FLAC and ALAC can do; 1:1 writes 24 in that case (see `RipTier`).
    /// Analog captures are pinned to 24 so a 1:1 WAV never truncates one.
    public var pcmDepth: Int? {
        switch self {
        case .cd, .miniDisc: return 16
        case .anySource:     return nil
        default:             return 24
        }
    }

    /// Sample rate for 1:1 and Lossless; `nil` keeps the source's.
    public var pcmRateHz: Int? {
        switch self {
        case .cd, .miniDisc: return 44_100
        // ffmpeg decodes DSD64 to 352.8 kHz; 88.2 kHz is the conventional
        // PCM rendering and a quarter of the size.
        case .sacd:          return 88_200
        default:             return nil
        }
    }

    /// The rate a lossy encode runs at: the medium's own family, never a
    /// hi-res rate a lossy file can't use.
    public var lossyRateHz: Int {
        switch self {
        case .dvdAudio, .bluRay, .bluRayAudio: return 48_000
        default:                               return 44_100
        }
    }
}

/// How much of the medium to keep. Three keys, one lit, none when the rows
/// below have been edited into something no tier describes.
public enum RipTier: String, CaseIterable, Codable, Sendable {
    /// Uncompressed PCM at the medium's resolution: a sample-for-sample copy.
    case exact
    /// The same audio compressed without loss, about 40% smaller.
    case lossless
    /// Trades fidelity for size.
    case lossy

    public var title: String {
        switch self {
        case .exact:    return "1:1"
        case .lossless: return "Lossless"
        case .lossy:    return "Lossy"
        }
    }

    public var explanation: String {
        switch self {
        case .exact:    return "Uncompressed PCM at the medium's resolution: a sample-for-sample copy."
        case .lossless: return "The same audio compressed without loss, about 40% smaller than 1:1."
        case .lossy:    return "Small files that play anywhere; some fidelity is traded for size."
        }
    }

    /// The settings this tier means for `medium`.
    ///
    /// `current` supplies the flavour, so pressing a tier doesn't undo a
    /// choice the FORMAT and BITRATE rows already made: Lossless stays ALAC if
    /// you picked ALAC, Lossy stays MP3 320 if you picked that. Anything else
    /// gets the tier's default (WAV, FLAC at level 8, AAC 256).
    public func settings(for medium: PhysicalMedium, keeping current: AudioEncodingSettings) -> AudioEncodingSettings {
        let current = current.normalized()
        switch self {
        case .exact:
            let format: OutputFormat = [.wav, .aiff].contains(current.format) ? current.format : .wav
            // WAV and AIFF can't follow the source's depth; 24 never truncates.
            return AudioEncodingSettings(format: format, sampleRateHz: medium.pcmRateHz, bitDepth: medium.pcmDepth ?? 24)
        case .lossless:
            let format: OutputFormat = [.flac, .alac].contains(current.format) ? current.format : .flac
            let level = format == .flac ? (current.format == .flac ? current.flacCompressionLevel : 8) : nil
            return AudioEncodingSettings(format: format, sampleRateHz: medium.pcmRateHz, bitDepth: medium.pcmDepth,
                                         flacCompressionLevel: level).normalized()
        case .lossy:
            let keepsFlavour = current.format.usesBitrate
            return AudioEncodingSettings(
                format: keepsFlavour ? current.format : .aac,
                bitrateKbps: keepsFlavour ? current.bitrateKbps : 256,
                sampleRateHz: medium.lossyRateHz
            ).normalized()
        }
    }

    /// The tier these settings are for `medium`, or nil when the rows have
    /// been edited away from all three.
    public static func matching(_ settings: AudioEncodingSettings, medium: PhysicalMedium) -> RipTier? {
        let target = settings.normalized()
        return allCases.first { $0.settings(for: medium, keeping: target) == target }
    }
}
