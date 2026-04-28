import SwiftUI

struct MainShell: View {
    @Environment(\.carbon) private var theme

    var body: some View {
        HStack(spacing: CarbonLayout.mainGap) {
            wellPlaceholder(title: "Sources", count: "—")
                .frame(width: CarbonLayout.sidebarWidth)
            wellPlaceholder(title: "Browser", count: "—")
                .frame(maxWidth: .infinity)
            wellPlaceholder(title: "Inspector", count: "—")
                .frame(width: CarbonLayout.inspectorWidth)
        }
    }

    private func wellPlaceholder(title: String, count: String) -> some View {
        RecessedWell {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(title.uppercased())
                        .font(CarbonFont.mono(9, weight: .bold))
                        .tracking(2.2)
                        .foregroundStyle(theme.ink2)
                    Spacer()
                    Text(count)
                        .font(CarbonFont.mono(9))
                        .foregroundStyle(theme.ink3)
                }
                .padding(.horizontal, 4)
                PaperPanel {
                    Color.clear
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}
