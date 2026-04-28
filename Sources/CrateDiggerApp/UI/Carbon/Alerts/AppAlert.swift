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

    static func info(title: String, message: String) -> AppAlert {
        AppAlert(title: title, message: message, actionTitle: nil, action: nil)
    }

    static func error(title: String, message: String) -> AppAlert {
        AppAlert(title: title, message: message, actionTitle: nil, action: nil)
    }

    static func actionable(
        title: String,
        message: String,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> AppAlert {
        AppAlert(title: title, message: message, actionTitle: actionTitle, action: action)
    }
}
