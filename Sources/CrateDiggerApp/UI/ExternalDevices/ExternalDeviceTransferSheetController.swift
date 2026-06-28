import AppKit
import CrateDiggerCore
import SwiftUI

struct ExternalDeviceTransferSelection {
    let profileID: UUID
    let batchScope: ConversionBatchScope
}

final class ExternalDeviceTransferSheetController: ThemedSheetHostingController {
    var onDecision: ((ExternalDeviceTransferSelection?) -> Void)?

    private let profiles: [ExternalDeviceProfile]
    private let initialScope: ConversionBatchScope

    init(
        profiles: [ExternalDeviceProfile],
        initialScope: ConversionBatchScope = .currentAlbum
    ) {
        self.profiles = profiles
        self.initialScope = initialScope
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let rootView = ExternalDeviceTransferSheetView(
            profiles: profiles,
            initialScope: initialScope
        ) { [weak self] selection in
            self?.onDecision?(selection)
        }

        setThemedRoot(rootView)
    }
}

private struct ExternalDeviceTransferSheetView: View {
    @Environment(\.carbon) private var theme

    let profiles: [ExternalDeviceProfile]
    let onDecision: (ExternalDeviceTransferSelection?) -> Void

    @State private var selectedProfileID: UUID?
    @State private var batchScope: ConversionBatchScope

    init(
        profiles: [ExternalDeviceProfile],
        initialScope: ConversionBatchScope,
        onDecision: @escaping (ExternalDeviceTransferSelection?) -> Void
    ) {
        self.profiles = profiles
        self.onDecision = onDecision
        _selectedProfileID = State(initialValue: profiles.first?.id)
        _batchScope = State(initialValue: initialScope)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            if profiles.isEmpty {
                emptyState
            } else {
                controls
                profileSummary
            }

            actionBar
        }
        .padding(18)
        .frame(minWidth: 680, minHeight: profiles.isEmpty ? 260 : 420)
        .background(theme.chassis)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Transfer to Device")
                .font(CarbonFont.sans(26, weight: .bold))
                .foregroundStyle(theme.ink)
            Text("Send loaded tracks to a mounted device using its saved format and folder layout.")
                .font(CarbonFont.mono(12, weight: .medium))
                .foregroundStyle(theme.ink2)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No device profiles saved.")
                .font(CarbonFont.sans(15, weight: .semibold))
                .foregroundStyle(theme.ink)
            Text("Open CrateDigger > Preferences > Devices to add an SD card player, Rockbox iPod, or direct-file player first.")
                .font(CarbonFont.mono(12))
                .foregroundStyle(theme.ink2)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(theme.paper)
        )
    }

    private var controls: some View {
        Form {
            Picker("Device", selection: $selectedProfileID) {
                ForEach(profiles) { profile in
                    Text(profile.name).tag(Optional(profile.id))
                }
            }

            Picker("Tracks", selection: $batchScope) {
                ForEach(ConversionBatchScope.allCases, id: \.self) { scope in
                    Text(scope.title).tag(scope)
                }
            }
        }
        .formStyle(.grouped)
        .frame(maxHeight: 130)
    }

    @ViewBuilder
    private var profileSummary: some View {
        if let profile = selectedProfile {
            VStack(alignment: .leading, spacing: 10) {
                summaryRow("Type", profile.kind.title)
                summaryRow("Mounted root", profile.rootDisplayPath ?? "Will ask before transfer")
                summaryRow("Device folder", profile.musicDirectorySubpath.isEmpty ? "Device root" : profile.musicDirectorySubpath)
                summaryRow("Mode", transferModeLabel(profile))
                summaryRow("Layout", layoutLabel(profile))
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(theme.paper)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(theme.hair.opacity(0.5), lineWidth: 1)
            )
        }
    }

    private func summaryRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label.uppercased())
                .font(CarbonFont.mono(9, weight: .bold))
                .tracking(1.8)
                .foregroundStyle(theme.ink3)
                .frame(width: 110, alignment: .trailing)
            Text(value)
                .font(CarbonFont.mono(12, weight: .medium))
                .foregroundStyle(theme.ink)
                .lineLimit(2)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
    }

    private var actionBar: some View {
        HStack(spacing: 12) {
            Spacer()
            Button("Cancel") {
                onDecision(nil)
            }
            .keyboardShortcut(.cancelAction)

            Button("Transfer") {
                guard let selectedProfileID else {
                    onDecision(nil)
                    return
                }
                onDecision(ExternalDeviceTransferSelection(
                    profileID: selectedProfileID,
                    batchScope: batchScope
                ))
            }
            .disabled(profiles.isEmpty)
            .keyboardShortcut(.defaultAction)
            .tint(theme.orange)
        }
    }

    private var selectedProfile: ExternalDeviceProfile? {
        guard let selectedProfileID else { return nil }
        return profiles.first { $0.id == selectedProfileID }
    }

    private func transferModeLabel(_ profile: ExternalDeviceProfile) -> String {
        switch profile.transferSettings.mode {
        case .copyOriginals:
            return "Copy originals"
        case .convertDuringTransfer:
            let settings = profile.transferSettings
            let bitrate = settings.bitrateKbps.map { "\($0) kbps" } ?? "auto"
            return "\(settings.outputFormat.appDisplayName), \(bitrate), \(settings.sampleRateHz.appSampleRateLabel)"
        }
    }

    private func layoutLabel(_ profile: ExternalDeviceProfile) -> String {
        switch profile.transferSettings.folderStructureMode {
        case .flat:
            return "Flat files"
        case .sourceRelative:
            return "Source-relative folders"
        case .metadataTemplate:
            return profile.transferSettings.templateConfig.preset.title
        }
    }
}
