import AppKit
import CrateDiggerCore
import SwiftUI

struct DevicesPreferencesView: View {
    @State private var profiles: [ExternalDeviceProfile] = []
    @State private var selectedID: UUID?
    @State private var draft = EditableExternalDeviceProfile()
    @State private var deleteConfirmationShown = false
    @State private var showSavedConfirmation = false

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
            // Connected volumes, pre-identified (kind + mount point + music folder
            // + suggested settings) so one click adds a ready-to-use profile.
            let suggestions = DeviceDetectionService().detectDevices()
                .map { DeviceProfileSuggester.suggestedProfile(for: $0) }
            if !suggestions.isEmpty {
                Section("Detected") {
                    ForEach(suggestions) { profile in
                        Button("\(profile.name) — \(profile.kind.title)") { addProfile(profile) }
                    }
                }
            }

            Section("Add manually") {
                Button("External Storage") { addProfile(.genericStorage(name: "External Storage")) }
                Button("SD Card Player") { addProfile(makeSDCardProfile()) }
                Button("Rockbox iPod") { addProfile(.rockboxIPod()) }
                Button("Direct File Player") { addProfile(.directFilePlayer()) }
            }
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

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Icon")
                            Spacer()
                            Text(iconLabel)
                                .font(.caption)
                                .foregroundStyle(draft.iconID == nil ? .secondary : Color(hex: 0xFF6D3F))
                        }
                        DeviceIconPicker(selection: $draft.iconID)
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
                    Toggle("Convert before transferring", isOn: Binding(
                        get: { draft.settings.mode == .convertDuringTransfer },
                        set: { draft.settings.mode = $0 ? .convertDuringTransfer : .copyOriginals }
                    ))

                    if draft.settings.mode == .convertDuringTransfer {
                        Picker("Compatibility", selection: $draft.settings.deviceProfile) {
                            Text("Generic").tag(DeviceProfile.generic)
                            Text("iPod legacy safe").tag(DeviceProfile.ipodLegacySafe)
                        }
                        Text("You'll choose the format and folder layout in the transfer panel each time you send tracks to this device.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack {
                    Button("Remove", role: .destructive) {
                        deleteConfirmationShown = true
                    }
                    Spacer()
                    if showSavedConfirmation {
                        Label("Settings Saved", systemImage: "checkmark.circle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.green)
                            .transition(.opacity)
                    }
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

    private var iconLabel: String {
        IPodCatalog.entry(for: draft.iconID)?.displayName ?? "None"
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

        withAnimation { showSavedConfirmation = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation { showSavedConfirmation = false }
        }
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
    var iconID: String?
    /// The whole transfer settings value — device-only fields (mode, compatibility)
    /// are edited inline; the format+folder core is edited via the Patch Bay.
    var settings = ExternalDeviceTransferSettings()

    init() {}

    init(profile: ExternalDeviceProfile) {
        name = profile.name
        kind = profile.kind
        rootBookmark = profile.rootBookmark
        rootDisplayPath = profile.rootDisplayPath
        musicDirectorySubpath = profile.musicDirectorySubpath
        iconID = profile.iconID
        settings = profile.transferSettings
    }

    func materialize(id: UUID, createdAt: Date) -> ExternalDeviceProfile {
        ExternalDeviceProfile(
            id: id,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            kind: kind,
            rootBookmark: rootBookmark,
            rootDisplayPath: rootDisplayPath,
            musicDirectorySubpath: musicDirectorySubpath,
            iconID: iconID,
            transferSettings: settings,
            createdAt: createdAt,
            updatedAt: Date()
        )
    }
}
