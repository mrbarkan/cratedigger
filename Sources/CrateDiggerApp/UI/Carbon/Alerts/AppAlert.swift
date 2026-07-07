import Foundation

/// User-facing alert state surfaced by the view model. Distinct from
/// inline status fields so we can centralize alert presentation in
/// CarbonRootView. SwiftUI's .alert(item:) consumes Identifiable, so
/// the id is what makes the same message re-presentable after dismiss.
struct AppAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    /// Optional secondary action button. If nil, the alert only has OK.
    var actionTitle: String?
    var action: (() -> Void)?
    /// Optional plain hyperlink shown in the footer, left of the buttons — e.g.
    /// the update alerts' link to the GitHub releases page.
    var linkTitle: String?
    var linkURL: URL?

    static func info(
        title: String,
        message: String,
        linkTitle: String? = nil,
        linkURL: URL? = nil
    ) -> AppAlert {
        AppAlert(title: title, message: message, actionTitle: nil, action: nil,
                 linkTitle: linkTitle, linkURL: linkURL)
    }

    static func error(title: String, message: String) -> AppAlert {
        AppAlert(title: title, message: message, actionTitle: nil, action: nil)
    }

    static func actionable(
        title: String,
        message: String,
        actionTitle: String,
        linkTitle: String? = nil,
        linkURL: URL? = nil,
        action: @escaping () -> Void
    ) -> AppAlert {
        AppAlert(title: title, message: message, actionTitle: actionTitle, action: action,
                 linkTitle: linkTitle, linkURL: linkURL)
    }
}
