import SwiftUI

/// First-run setup sheet: pick the three independent library folders (or accept
/// defaults) and get going. Presented from `model.showingOnboarding`.
struct OnboardingView: View {
    @Environment(\.carbon) private var theme
    @EnvironmentObject private var model: LibraryViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            VStack(spacing: 10) {
                folderRow(
                    icon: "internaldrive", title: "LOCAL LIBRARY",
                    desc: "Where your albums & tracks live — can be an external drive.",
                    path: model.localLibraryDisplayPath, isDefault: !model.localLibraryIsSet,
                    choose: { model.chooseLocalLibraryFolder() })
                folderRow(
                    icon: "tray.2", title: "LIBRARY FILE LOCATION",
                    desc: "Where crate index (.cdlib) files are saved.",
                    path: model.libraryFileDisplayPath, isDefault: !model.libraryFileIsSet,
                    choose: { model.chooseLibraryFileFolder() })
                folderRow(
                    icon: "arrow.down.doc", title: "DEFAULT OUTPUT",
                    desc: "Where converted files go by default.",
                    path: model.outputDisplayPath, isDefault: !model.outputIsSet,
                    choose: { model.chooseOutputFolder() })
            }

            Button(action: { model.openExistingLibrary() }) {
                HStack(spacing: 6) {
                    Image(systemName: "folder.badge.gearshape").font(.system(size: 10, weight: .semibold))
                    Text("I already have a library — open it…")
                        .font(CarbonFont.mono(10, weight: .semibold))
                }
                .foregroundStyle(theme.cyan)
            }
            .buttonStyle(.plain)

            footer
        }
        .padding(24)
        .frame(width: 520)
    }

    private var header: some View {
        HStack(spacing: 14) {
            BrandMark(size: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text("Welcome to CrateDigger")
                    .font(CarbonFont.sans(20, weight: .bold))
                    .foregroundStyle(theme.ink)
                Text("Pick where your library lives. Each is independent — you can change them later in Preferences.")
                    .font(CarbonFont.sans(12))
                    .foregroundStyle(theme.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func folderRow(icon: String, title: String, desc: String, path: String,
                           isDefault: Bool, choose: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(theme.ink3)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(CarbonFont.mono(9.5, weight: .bold)).tracking(1.4)
                        .foregroundStyle(theme.ink2)
                    if isDefault {
                        Text("DEFAULT")
                            .font(CarbonFont.mono(7.5, weight: .bold))
                            .foregroundStyle(theme.ink4)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 3).fill(theme.ink4.opacity(0.16)))
                    }
                }
                Text(desc).font(CarbonFont.sans(11)).foregroundStyle(theme.ink3)
                Text(path)
                    .font(CarbonFont.mono(9)).foregroundStyle(theme.ink4)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Button("Choose…") { choose() }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(theme.ink.opacity(theme.isDark ? 0.05 : 0.03)))
    }

    private var footer: some View {
        HStack {
            Text("Unchosen folders default to ~/Music/CrateDigger.")
                .font(CarbonFont.mono(8.5)).foregroundStyle(theme.ink4)
            Spacer()
            Button("Get Started") { model.completeFirstRunSetup() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
        }
    }
}
