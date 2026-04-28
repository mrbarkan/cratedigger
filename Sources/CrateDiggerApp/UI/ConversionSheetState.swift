import Foundation

enum TemplateApplyMode: String, CaseIterable {
    case applyAll = "apply_all"
    case reviewPerAlbumPreflight = "review_per_album_preflight"

    var title: String {
        switch self {
        case .applyAll:
            return "Apply to all"
        case .reviewPerAlbumPreflight:
            return "Review album folders"
        }
    }
}

enum AppCapabilityStatus {
    case ready(String)
    case limited(String)
    case unavailable(String)

    var text: String {
        switch self {
        case .ready(let value), .limited(let value), .unavailable(let value):
            return value
        }
    }

    var tone: StatusTone {
        switch self {
        case .ready:
            return .success
        case .limited:
            return .warning
        case .unavailable:
            return .error
        }
    }
}

struct AppReadiness {
    let playback: AppCapabilityStatus
    let metadataProbe: AppCapabilityStatus
    let conversion: AppCapabilityStatus

    var summaryText: String {
        [
            "Playback: \(playback.text)",
            "Metadata: \(metadataProbe.text)",
            "Conversion: \(conversion.text)"
        ].joined(separator: "  •  ")
    }
}

struct ConversionReport {
    let title: String
    let statusLine: String
    let details: String
    let tone: StatusTone
    let showsDetailsButton: Bool
}
