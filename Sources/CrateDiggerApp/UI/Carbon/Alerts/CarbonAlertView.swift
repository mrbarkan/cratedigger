import SwiftUI

/// Carbon-styled replacement for the native macOS alert. Presented as a sheet
/// from `CarbonRootView` whenever `model.appAlert` is set, so every in-app
/// message (success, error, confirm) shares the same look as the Add Stream and
/// Record Divider sheets instead of a stock system dialog.
///
/// The header dot is the brand accent rather than a tone colour: many call sites
/// surface success/info through the `.error(...)` factory (see CLAUDE.md), so a
/// red dot keyed off the factory would mislabel those. Honest tone colouring is
/// a separate pass over the ~30 call sites.
struct CarbonAlertView: View {
    @Environment(\.carbon) private var theme
    @Environment(\.dismiss) private var dismiss
    let alert: AppAlert

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Circle().fill(theme.orange).frame(width: 7, height: 7)
                Text(alert.title.uppercased())
                    .font(CarbonFont.mono(11, weight: .bold))
                    .tracking(2)
                    .foregroundStyle(theme.ink)
                    .lineLimit(2)
                Spacer(minLength: 0)
            }

            Text(alert.message)
                .font(CarbonFont.sans(12))
                .foregroundStyle(theme.ink2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 10) {
                Spacer()
                if let actionTitle = alert.actionTitle, let action = alert.action {
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button(actionTitle) {
                        action()
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                } else {
                    Button("OK") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}
