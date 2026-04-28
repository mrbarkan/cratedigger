import SwiftUI

struct MainShell: View {
    @Environment(\.carbon) private var theme
    @EnvironmentObject private var model: LibraryViewModel

    var body: some View {
        HStack(spacing: CarbonLayout.mainGap) {
            sidebarWell
                .frame(width: CarbonLayout.sidebarWidth)
            browserWell
                .frame(maxWidth: .infinity)
            inspectorWell
                .frame(width: CarbonLayout.inspectorWidth)
        }
    }

    private var sidebarWell: some View {
        wellShell(title: "Sources", trailing: sourcesTrailing) {
            SourcesSidebar()
        }
    }

    private var browserWell: some View {
        wellShell(title: "Browser · \(browserSubtitle)", trailing: browserTrailing) {
            BrowserPane()
        }
    }

    private var inspectorWell: some View {
        wellShell(title: "Inspector", trailing: "Rec. Metadata") {
            // Phase 6 will replace this with InspectorPane.
            VStack {
                Spacer()
                Text(model.selectedAlbum?.title ?? "—")
                    .font(CarbonFont.sans(18, weight: .bold))
                    .foregroundStyle(theme.ink)
                Text(model.selectedAlbum?.artistName ?? "")
                    .font(CarbonFont.mono(10, weight: .semibold))
                    .tracking(2)
                    .foregroundStyle(theme.ink3)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var sourcesTrailing: String {
        let n = model.index.artists.count
        return n == 0 ? "—" : String(format: "%02d", n)
    }

    private var browserSubtitle: String {
        if model.scanProgress.isRunning { return "Scanning" }
        if model.index.allTracks.isEmpty { return "Empty" }
        return "Library"
    }

    private var browserTrailing: String {
        let n = model.index.allTracks.count
        return n == 0 ? "—" : "\(n) RECORDS"
    }

    private func wellShell<Inner: View>(title: String, trailing: String, @ViewBuilder content: @escaping () -> Inner) -> some View {
        RecessedWell {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(title.uppercased())
                        .font(CarbonFont.mono(9, weight: .bold))
                        .tracking(2.2)
                        .foregroundStyle(theme.ink2)
                    Spacer()
                    Text(trailing)
                        .font(CarbonFont.mono(9))
                        .foregroundStyle(theme.ink3)
                }
                .padding(.horizontal, 4)

                PaperPanel {
                    content()
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}
