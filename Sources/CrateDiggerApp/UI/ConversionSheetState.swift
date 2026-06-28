import Foundation

enum TemplateApplyMode: String, Codable, CaseIterable {
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

struct ConversionReport {
    let title: String
    let statusLine: String
    let details: String
    let tone: StatusTone
    let showsDetailsButton: Bool
}
