import CrateDiggerCore
import SwiftUI

/// Says why every row is dimmed and nothing can be changed: the library's
/// drive is out, and what is on screen is the copy kept on this Mac.
/// Styled like `DiscIdentityBar`, the other bar that sits over the browser.
struct LibraryDisconnectedBar: View {
    @Environment(\.carbon) private var theme
    @EnvironmentObject private var model: LibraryViewModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "externaldrive.badge.xmark")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.orange)

            VStack(alignment: .leading, spacing: 2) {
                Text(headline)
                    .font(CarbonFont.sans(12, weight: .semibold))
                    .foregroundStyle(theme.ink)
                    .lineLimit(1)
                Text(detail)
                    .font(CarbonFont.mono(8.5))
                    .foregroundStyle(theme.ink4)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(theme.isDark ? Color.black.opacity(0.28) : Color.black.opacity(0.035))
        .overlay(
            Rectangle()
                .fill(theme.isDark ? Color.white.opacity(0.05) : Color.black.opacity(0.08))
                .frame(height: 1),
            alignment: .bottom
        )
        .accessibilityElement(children: .combine)
    }

    private var headline: String {
        if let name = model.disconnectedLibraryVolumeName {
            return "\u{201C}\(name)\u{201D} is disconnected"
        }
        return "Your library folder can\u{2019}t be found"
    }

    private var detail: String {
        let asOf = model.libraryCopyDate.map {
            "Showing your library as of \($0.formatted(date: .abbreviated, time: .shortened)). "
        } ?? "Showing your last saved library. "
        return asOf + "Changes are paused until it\u{2019}s back."
    }
}
