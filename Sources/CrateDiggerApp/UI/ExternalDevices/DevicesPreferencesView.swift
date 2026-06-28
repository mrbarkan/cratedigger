import AppKit
import CrateDiggerCore
import SwiftUI

struct DevicesPreferencesView: View {
    @State private var profiles: [ExternalDeviceProfile] = []
    @State private var selectedID: UUID?
    @State private var draft = EditableExternalDeviceProfile()
    @State private var deleteConfirmationShown = false

    private let bitrateOptions = [-1, 128, 160, 192, 256, 320]
    private let sampleRateOptions = [-1, 44_100, 48_000, 88_200, 96_000]
    private let artworkOptions = [-1, 300, 600, 1000, 1400]

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            sidebar
                .frame(width: 190)
            Divider()
            editor
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(minWidth: 720, minHeight: 500)
        .onAppear(perform: reload)
        .alert("Remove device profile?", isPresented: $deleteConfirmationShown) {
            Button("Remove", role: .destructive) { deleteSelectedProfile() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes only the CrateDigger profile. Files on the device are not touched.")
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Devices")
                    .font(.headline)
                Spacer()
                addDeviceMenu
            }

            if profiles.isEmpty {
                Text("No device profiles yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                List(profiles, id: \.id, selection: $selectedID) { profile in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(profile.name)
                            .lineLimit(1)
                        Text(profile.kind.title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .tag(profile.id)
                }
                .onChange(of: selectedID) { newValue in
                    loadDraft(for: newValue)
                }
            }
        }
    }

    private var addDeviceMenu: some View {
        Menu {
            Button("External Storage") { addProfile(.genericStorage(name: "External Storage")) }
            Button("SD Card Player") { addProfile(makeSDCardProfile()) }
            Button("Rockbox iPod") { addProfile(.rockboxIPod()) }
            Button("Direct File Player") { addProfile(.directFilePlayer()) }
        } label: {
            Image(systemName: "plus")
        }
        .menuStyle(.button)
        .help("Add device profile")
    }

    @ViewBuilder
    private var editor: some View {
        if selectedID == nil {
            VStack(alignment: .leading, spacing: 8) {
                Text("Add or select a device profile.")
                    .font(.headline)
                Text("Profiles remember where a mounted device lives, how music should be organized there, and whether tracks should be copied or converted during transfer.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Form {
                Section("Device") {
                    TextField("Name", text: $draft.name)
                    Picker("Type", selection: $draft.kind) {
                        ForEach(ExternalDeviceKind.allCases, id: \.self) { kind in
                            Text(kind.title).tag(kind)
                        }
                    }

                    LabeledContent("Mounted root") {
                        HStack {
                            Text(draft.rootDisplayPath ?? "Not set")
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(draft.rootDisplayPath == nil ? .secondary : .primary)
                            Button("Choose...") { chooseMountedRoot() }
                        }
                    }

                    TextField("Music folder on device", text: $draft.musicDirectorySubpath)
                    Text("Leave blank for direct-file players that expect tracks at the device root.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Transfer") {
                    Picker("Mode", selection: $draft.transferMode) {
                        ForEach(ExternalDeviceTransferMode.allCases, id: \.self) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }

                    if draft.transferMode == .convertDuringTransfer {
                        Picker("Format", selection: $draft.outputFormat) {
                            ForEach(OutputFormat.allCases, id: \.self) { format in
                                Text(format.appDisplayName).tag(format)
                            }
                        }

                        Picker("Bitrate", selection: $draft.bitrateTag) {
                            ForEach(bitrateOptions, id: \.self) { option in
                                Text(option < 0 ? "Auto" : "\(option) kbps").tag(option)
                            }
                        }
                        .disabled(draft.outputFormat.isLossless)

                        Picker("Sample rate", selection: $draft.sampleRateTag) {
                            ForEach(sampleRateOptions, id: \.self) { option in
                                Text(option < 0 ? "Source" : Optional(option).appSampleRateLabel).tag(option)
                            }
                        }

                        Picker("Artwork", selection: $draft.artworkTag) {
                            ForEach(artworkOptions, id: \.self) { option in
                                Text(option < 0 ? "Original" : "\(option) px").tag(option)
                            }
                        }

                        Picker("Compatibility", selection: $draft.deviceProfile) {
                            Text("Generic").tag(DeviceProfile.generic)
                            Text("iPod legacy safe").tag(DeviceProfile.ipodLegacySafe)
                        }
                    }
                }

                Section("Folder layout") {
                    Picker("Structure", selection: $draft.folderStructureMode) {
                        ForEach(FolderStructureMode.allCases, id: \.self) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }

                    if draft.folderStructureMode == .metadataTemplate {
                        Picker("Preset", selection: $draft.templatePreset) {
                            ForEach(TemplatePreset.allCases, id: \.self) { preset in
                                Text(preset.title).tag(preset)
                            }
                        }
                        .onChange(of: draft.templatePreset) { newValue in
                            if newValue != .custom {
                                draft.tokenOrder = FolderTokenOrder.normalize(newValue.defaultTokenOrder)
                            }
                        }

                        if draft.templatePreset == .custom {
                            HStack(spacing: 8) {
                                ForEach(0..<FolderTokenOrder.tokenCount, id: \.self) { index in
                                    Picker("Token \(index + 1)", selection: FolderTokenOrder.tokenBinding(in: $draft.tokenOrder, at: index)) {
                                        ForEach(FolderToken.allCases, id: \.self) { token in
                                            Text(token.title).tag(token)
                                        }
                                    }
                                    .labelsHidden()
                                }
                            }
                        }
                    }
                }

                HStack {
                    Button("Remove", role: .destructive) {
                        deleteConfirmationShown = true
                    }
                    Spacer()
                    Button("Save") {
                        saveDraft()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .formStyle(.grouped)
        }
    }

    private func reload() {
        profiles = PreferencesStore.shared.savedExternalDeviceProfiles
        if selectedID == nil || !profiles.contains(where: { $0.id == selectedID }) {
            selectedID = profiles.first?.id
        }
        loadDraft(for: selectedID)
    }

    private func addProfile(_ profile: ExternalDeviceProfile) {
        PreferencesStore.shared.upsertExternalDeviceProfile(profile)
        selectedID = profile.id
        reload()
    }

    private func saveDraft() {
        guard let id = selectedID else { return }
        let existing = profiles.first { $0.id == id }
        let saved = draft.materialize(
            id: id,
            createdAt: existing?.createdAt ?? Date()
        )
        PreferencesStore.shared.upsertExternalDeviceProfile(saved)
        reload()
        selectedID = saved.id
        loadDraft(for: saved.id)
    }

    private func deleteSelectedProfile() {
        guard let selectedID else { return }
        PreferencesStore.shared.removeExternalDeviceProfile(id: selectedID)
        self.selectedID = nil
        reload()
    }

    private func loadDraft(for id: UUID?) {
        guard let id, let profile = profiles.first(where: { $0.id == id }) else {
            draft = EditableExternalDeviceProfile()
            return
        }
        draft = EditableExternalDeviceProfile(profile: profile)
    }

    private func chooseMountedRoot() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = "Choose mounted device root"
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            draft.rootBookmark = try PreferencesStore.makeBookmark(for: url)
            draft.rootDisplayPath = url.path
        } catch {
            AppLog.prefs.warning("Could not bookmark device root: \(String(describing: error), privacy: .public)")
        }
    }

    private func makeSDCardProfile() -> ExternalDeviceProfile {
        ExternalDeviceProfile(
            name: "SD Card Player",
            kind: .sdCard,
            musicDirectorySubpath: "Music",
            transferSettings: ExternalDeviceTransferSettings(
                mode: .convertDuringTransfer,
                outputFormat: .aac,
                bitrateKbps: 192,
                sampleRateHz: 44_100,
                artworkMaxDimension: 600,
                folderStructureMode: .metadataTemplate,
                templateConfig: FolderTemplateConfig(
                    preset: .artistYearAlbum,
                    tokenOrder: TemplatePreset.artistYearAlbum.defaultTokenOrder
                )
            )
        )
    }
}

private struct EditableExternalDeviceProfile {
    var name: String = ""
    var kind: ExternalDeviceKind = .genericExternalStorage
    var rootBookmark: Data?
    var rootDisplayPath: String?
    var musicDirectorySubpath: String = "Music"
    var transferMode: ExternalDeviceTransferMode = .convertDuringTransfer
    var outputFormat: OutputFormat = .aac
    var bitrateTag: Int = 192
    var sampleRateTag: Int = 44_100
    var artworkTag: Int = 1024
    var deviceProfile: DeviceProfile = .generic
    var folderStructureMode: FolderStructureMode = .metadataTemplate
    var templatePreset: TemplatePreset = .artistYearAlbum
    var tokenOrder: [FolderToken] = TemplatePreset.artistYearAlbum.defaultTokenOrder

    init() {}

    init(profile: ExternalDeviceProfile) {
        name = profile.name
        kind = profile.kind
        rootBookmark = profile.rootBookmark
        rootDisplayPath = profile.rootDisplayPath
        musicDirectorySubpath = profile.musicDirectorySubpath
        transferMode = profile.transferSettings.mode
        outputFormat = profile.transferSettings.outputFormat
        bitrateTag = profile.transferSettings.bitrateKbps ?? -1
        sampleRateTag = profile.transferSettings.sampleRateHz ?? -1
        artworkTag = profile.transferSettings.artworkMaxDimension ?? -1
        deviceProfile = profile.transferSettings.deviceProfile
        folderStructureMode = profile.transferSettings.folderStructureMode
        templatePreset = profile.transferSettings.templateConfig.preset
        tokenOrder = FolderTokenOrder.normalize(profile.transferSettings.templateConfig.tokenOrder)
    }

    func materialize(id: UUID, createdAt: Date) -> ExternalDeviceProfile {
        ExternalDeviceProfile(
            id: id,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            kind: kind,
            rootBookmark: rootBookmark,
            rootDisplayPath: rootDisplayPath,
            musicDirectorySubpath: musicDirectorySubpath,
            transferSettings: ExternalDeviceTransferSettings(
                mode: transferMode,
                outputFormat: outputFormat,
                bitrateKbps: bitrateTag > 0 ? bitrateTag : nil,
                sampleRateHz: sampleRateTag > 0 ? sampleRateTag : nil,
                artworkMaxDimension: artworkTag > 0 ? artworkTag : nil,
                deviceProfile: deviceProfile,
                folderStructureMode: folderStructureMode,
                templateConfig: FolderTemplateConfig(
                    preset: templatePreset,
                    tokenOrder: FolderTokenOrder.normalize(tokenOrder)
                )
            ),
            createdAt: createdAt,
            updatedAt: Date()
        )
    }
}
