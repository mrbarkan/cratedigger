import CrateDiggerCore
import Foundation

extension OutputFormat {
    var appDisplayName: String {
        switch self {
        case .mp3:  return "MP3"
        case .aac:  return "AAC (.m4a)"
        case .alac: return "ALAC (.m4a)"
        case .flac: return "FLAC"
        case .wav:  return "WAV"
        case .aiff: return "AIFF"
        case .ogg:  return "OGG"
        case .opus: return "Opus"
        }
    }
}

extension Optional where Wrapped == Int {
    var appSampleRateLabel: String {
        guard let value = self else { return "Source" }
        if value % 1000 == 0 {
            return "\(value / 1000) kHz"
        }
        return String(format: "%.1f kHz", Double(value) / 1000.0)
    }
}
