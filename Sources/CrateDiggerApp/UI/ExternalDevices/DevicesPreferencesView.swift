import AppKit
import CrateDiggerCore
import SwiftUI

struct DevicesPreferencesView: View {
    /// The running app's view of mounted devices. Read, never observed: the
    /// model publishes far more than this pane needs, so the pane refreshes
    /// on `deviceFirmwareChangedNotification` instead.
    let model: LibraryViewModel?

    @State private var profiles: [ExternalDeviceProfile] = []
    @State private var selectedID: UUID?
    @State private var draft = EditableExternalDeviceProfile()
    @State private var deleteConfirmationShown = false
    @State private var showSavedConfirmation = false
    /// How many albums the review sheet was told to leave alone on the
    /// selected device. Read when a profile is selected; the button clears it.
    @State private var leftAloneCount = 0
    /// What the selected profile's mounted device runs, when it has `.rockbox`.
    @State private var firmware: DeviceFirmware?
    /// The selected profile's device, while it is mounted.
    @State private var mountedDevice: MountedDevice?
    /// It is FAT or exFAT, where macOS leaves `._` files.
    @State private var canCleanUpMacFiles = false
    /// The mounted device runs PodBox (`centralPeopleArtwork`); nil when it
    /// is not mounted, so the On the iPod rows show, disabled where they need it.
    @State private var hasPeopleArtwork: Bool?
    /// What the readiness check says about the mounted device.
    @State private var notes: [PodBoxNote] = []
    @State private var removePicturesConfirmationShown = false
    /// A layout chosen for a profile whose device already has albums,
    /// waiting for the owner to confirm.
    @State private var pendingLayout: RockboxLayoutPreset?

    var body: some View {
        // spacing 0 and no .top alignment: the divider has to run the full
        // height of the pane, and the two columns supply their own insets.
        HStack(spacing: 0) {
            sidebar
                .frame(width: 200)
            Divider()
            editor
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(minWidth: 720, minHeight: 500)
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: LibraryViewModel.deviceFirmwareChangedNotification)) { _ in
            refreshMountedState()
        }
        .alert("Remove device profile?", isPresented: $deleteConfirmationShown) {
            Button("Remove", role: .destructive) { deleteSelectedProfile() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes only the CrateDigger profile. Files on the device are not touched.")
        }
        .alert("Remove artist pictures CrateDigger added?", isPresented: $removePicturesConfirmationShown) {
            Button("Remove", role: .destructive) {
                if let selectedID { model?.removeArtistPicturesCrateDiggerAdded(profileID: selectedID) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Only pictures CrateDigger wrote and nobody has changed since are removed. A copy of each is kept on this Mac. Your own pictures stay.")
        }
        .alert("Change the folder layout?", isPresented: Binding(
            get: { pendingLayout != nil },
            set: { if !$0 { pendingLayout = nil } }
        )) {
            Button("Change") {
                if let pendingLayout { applyLayout(pendingLayout) }
                pendingLayout = nil
            }
            Button("Cancel", role: .cancel) { pendingLayout = nil }
        } message: {
            Text("New albums will use this layout. Albums already on the device stay where they are.")
        }
    }

    /// Title, the list filling everything between, then the add/remove bar
    /// pinned to the bottom — where macOS puts a list's own editing controls.
    private var sidebar: some View {
        VStack(spacing: 0) {
            Text("Devices")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.top, 16)
                .padding(.bottom, 8)

            if profiles.isEmpty {
                Text("No device profiles yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                Spacer(minLength: 0)
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
                .frame(maxHeight: .infinity)
                .onChange(of: selectedID) { newValue in
                    loadDraft(for: newValue)
                }
            }

            Divider()
            HStack(spacing: 2) {
                addDeviceMenu
                Button {
                    deleteConfirmationShown = true
                } label: {
                    Image(systemName: "minus")
                        .frame(width: 18, height: 16)
                }
                .buttonStyle(.borderless)
                .disabled(selectedID == nil)
                .help("Remove selected device profile")
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }

    private var addDeviceMenu: some View {
        Menu {
            // Connected volumes, pre-identified (kind + mount point + music folder
            // + suggested settings) so one click adds a ready-to-use profile.
            let suggestions = DeviceDetectionService().detectDevices()
                .map { seededForPodBox(DeviceProfileSuggester.suggestedProfile(for: $0), device: $0) }
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
                .frame(width: 18, height: 16)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
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
            .padding(24)
        } else {
            // Actions live under the form, not inside it: in the form they
            // scrolled off the bottom of the pane with the last section, so
            // Save was only reachable by scrolling.
            VStack(spacing: 0) {
            Form {
                Section("Device") {
                    TextField("Name", text: $draft.name)
                    Picker("Type", selection: kindBinding) {
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

                    firmwareRows
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

                    if draft.kind == .rockboxIPod {
                        layoutRows
                    }
                }

                artworkSection

                if draft.kind == .rockboxIPod, hasPeopleArtwork != false {
                    onTheIPodSection
                }

            }
            .formStyle(.grouped)

            Divider()
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
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            }
        }
    }

    /// Read-only, and only while the device is mounted and has `.rockbox`:
    /// what the mount-time probe found. Then, while it is mounted, the
    /// cleanup of the Mac's `._` files, which runs only when pressed.
    @ViewBuilder
    private var firmwareRows: some View {
        if let firmware {
            LabeledContent("Firmware") {
                Text(firmware.summaryLine)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .textSelection(.enabled)
            }
            if let notice = firmware.layoutNotice {
                Text(notice + ".")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        if let mountedDevice, let model {
            LabeledContent("Mac files") {
                Button("Clean Up Mac Files…") { model.cleanUpMacFiles(device: mountedDevice, scope: nil) }
                    .disabled(!canCleanUpMacFiles)
            }
            Text(cleanUpCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        Toggle("Clean up after each transfer", isOn: automaticCleanupBinding)
        Text("Removes the ._ files macOS left in the folders a transfer wrote to, keeping a copy on this Mac. Off until you have checked a cleanup on this device; new copies never make them either way.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    // MARK: Folder layout

    /// The profile's folder layout as one of the Rockbox presets, or Custom.
    /// Choosing a preset seeds the template; Custom changes nothing here.
    @ViewBuilder
    private var layoutRows: some View {
        let current = RockboxLayoutPreset.matching(draft.settings.templateConfig)
        Picker("Folder layout", selection: Binding(
            get: { current },
            set: { chosen in
                guard chosen != .custom, chosen != current else { return }
                if let existing = profiles.first(where: { $0.id == selectedID }),
                   model?.hasDeviceCatalog(forProfile: existing) == true {
                    pendingLayout = chosen
                } else {
                    applyLayout(chosen)
                }
            }
        )) {
            ForEach(RockboxLayoutPreset.allCases, id: \.self) { preset in
                Text(preset.title).tag(preset)
            }
        }
        // The caption shows the folders when the title does not already say them.
        if current.caption != current.title {
            Text(current.caption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// The preset's template on the draft (saved with Save), in album folders.
    private func applyLayout(_ preset: RockboxLayoutPreset) {
        guard let template = preset.template else { return }
        draft.settings.templateConfig = template
        draft.settings.folderStructureMode = .metadataTemplate
    }

    // MARK: On the iPod

    /// PodBox's own extras for this iPod: what the readiness check says,
    /// then artist pictures. Every switch is saved with Save; nothing here
    /// writes to the device except Remove (after a confirmation) and Apply
    /// in the Artist Pictures sheet.
    private var onTheIPodSection: some View {
        Section("On the iPod") {
            ForEach(notes) { note in
                VStack(alignment: .leading, spacing: 2) {
                    Text(note.text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let menuPath = note.menuPath {
                        Text("On the iPod: \(menuPath)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            Picker("Artist pictures", selection: podBoxBinding(\.artistPictures)) {
                Text("Off").tag(ArtistPictureDestination.off)
                Text("In /Artwork/People").tag(ArtistPictureDestination.artworkFolder)
                Text("In artist folders").tag(ArtistPictureDestination.artistFolders)
            }
            if !passedM5 {
                Text("Run the M5 check before turning this on.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Toggle("Verified on this iPod (M5)", isOn: Binding(
                get: { passedM5 },
                set: { passed in
                    var preferences = draft.podBox ?? PodBoxPreferences()
                    if passed {
                        preferences.passedChecks.insert(ArtistPictureSession.m5Check)
                    } else {
                        preferences.passedChecks.remove(ArtistPictureSession.m5Check)
                    }
                    draft.podBox = preferences
                }
            ))
            Toggle("Find missing artist pictures automatically", isOn: podBoxBinding(\.findsArtistPicturesAutomatically))
            Text("At the end of each transfer, looks up pictures for artists without one on Deezer, sending only the artist's name. Off until you turn it on.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button("Artist Pictures…") {
                    if let selectedID { model?.showArtistPictures(profileID: selectedID) }
                }
                .disabled(model == nil || selectedID == nil)
                Button("Remove artist pictures CrateDigger added") { removePicturesConfirmationShown = true }
                    .disabled(model == nil || mountedDevice == nil)
            }
            if mountedDevice == nil {
                Text("Connect the iPod to remove pictures from it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var passedM5: Bool {
        draft.podBox?.passedChecks.contains(ArtistPictureSession.m5Check) ?? false
    }

    /// One PodBox preference on the draft, created with its defaults on first change.
    private func podBoxBinding<Value>(_ keyPath: WritableKeyPath<PodBoxPreferences, Value>) -> Binding<Value> {
        Binding(
            get: { (draft.podBox ?? PodBoxPreferences())[keyPath: keyPath] },
            set: { value in
                var preferences = draft.podBox ?? PodBoxPreferences()
                preferences[keyPath: keyPath] = value
                draft.podBox = preferences
            }
        )
    }

    /// The profile's automatic `._` cleanup (off by default; saved with Save).
    private var automaticCleanupBinding: Binding<Bool> {
        Binding(
            get: { draft.podBox?.appleDoubleCleanup ?? false },
            set: { isOn in
                var preferences = draft.podBox ?? PodBoxPreferences()
                preferences.appleDoubleCleanup = isOn
                draft.podBox = preferences
            }
        )
    }

    private var cleanUpCaption: String {
        guard canCleanUpMacFiles else {
            return "Only FAT and exFAT devices collect the hidden ._ files macOS leaves beside each file."
        }
        let hint = DeviceCleanupSummary.mountHint(count: firmware?.unreadableAppleDoubleCount ?? 0)
        return (hint.map { $0 + " " } ?? "")
            + "Removes the hidden ._ files macOS leaves beside each file. A copy is kept on this Mac."
    }

    /// What a transfer does with the art: inside the files (convert mode
    /// only; copy mode writes the files as they are) and as a cover.jpg
    /// beside them. Both are stored on the device, and the review compares
    /// what is already there against them.
    private var artworkSection: some View {
        Section("Artwork") {
            if draft.settings.mode == .convertDuringTransfer {
                Picker("In the files", selection: $draft.settings.artworkMode) {
                    Text("Keep").tag(ArtworkMode.preserve)
                    Text("Re-embed").tag(ArtworkMode.compatReembed)
                    Text("Strip").tag(ArtworkMode.none)
                }
                .pickerStyle(.segmented)

                Picker("Size", selection: $draft.settings.artworkMaxDimension) {
                    ForEach(artworkSizeOptions, id: \.self) { size in
                        // Verbatim: a localized interpolation groups 1024 as "1.024".
                        Text(verbatim: size.map { "\($0) px" } ?? "Original").tag(size)
                    }
                }
                .disabled(draft.settings.artworkMode != .compatReembed)
            }

            Toggle("Folder art (cover.jpg)", isOn: $draft.settings.writesFolderCoverArt)
            Text(folderArtCaption)
                .font(.caption)
                .foregroundStyle(.secondary)

            LabeledContent("Albums left alone") {
                HStack {
                    Text(verbatim: leftAloneCount == 0 ? "None" : "\(leftAloneCount)")
                        .foregroundStyle(.secondary)
                    Button("Forget albums left alone") { forgetLeftAlone() }
                        .disabled(leftAloneCount == 0)
                }
            }
            Text("Albums you chose to leave alone when sending stop being asked about. Forget them to be asked again.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var folderArtCaption: String {
        let size = FolderCoverArtWriter.defaultMaxDimension
        return draft.settings.mode == .convertDuringTransfer
            ? "Writes a \(size) px cover.jpg beside the tracks in each album folder, whatever happens to the art in the files. Rockbox shows it; a large embedded cover comes out grey there."
            : "Writes a \(size) px cover.jpg beside the tracks in each album folder. The copied files keep their own art."
    }

    /// The sizes Re-embed offers, plus whatever the profile already stores
    /// (the factory default is 1024), so a stored size is never shown as
    /// another.
    private var artworkSizeOptions: [Int?] {
        var sizes = Set([300, 500, 600, 800, 1000, 1400])
        if let stored = draft.settings.artworkMaxDimension { sizes.insert(stored) }
        return [nil] + sizes.sorted().map { Optional($0) }
    }

    /// Choosing a kind moves the art defaults with it: to a Rockbox iPod,
    /// Strip and folder art; away from one, no folder art and the mode the
    /// size implies. Only the user's pick goes through here, never a profile
    /// being loaded into the draft.
    private var kindBinding: Binding<ExternalDeviceKind> {
        Binding(
            get: { draft.kind },
            set: { newKind in
                draft.settings = draft.settings.adjustedForKind(from: draft.kind, to: newKind)
                draft.kind = newKind
            }
        )
    }

    private func forgetLeftAlone() {
        guard let selectedID else { return }
        DeviceLeftAloneStore().clear(profileID: selectedID)
        leftAloneCount = 0
    }

    private var iconLabel: String {
        DeviceSystemIcons.displayName(for: draft.iconID)
            ?? IPodCatalog.entry(for: draft.iconID)?.displayName
            ?? "None"
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

        // A confirmation lamp: lights on the state curve, fades like one.
        withAnimation(CarbonMotion.state) { showSavedConfirmation = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation(CarbonMotion.lampOff) { showSavedConfirmation = false }
        }
    }

    private func deleteSelectedProfile() {
        guard let selectedID else { return }
        PreferencesStore.shared.removeExternalDeviceProfile(id: selectedID)
        // A deleted profile's sync queue + staged bakes are trash — drop them now,
        // and the albums it was told to leave alone with them.
        DeviceSyncQueueStore().remove(profileID: selectedID)
        DeviceLeftAloneStore().clear(profileID: selectedID)
        self.selectedID = nil
        reload()
    }

    private func loadDraft(for id: UUID?) {
        guard let id, let profile = profiles.first(where: { $0.id == id }) else {
            draft = EditableExternalDeviceProfile()
            leftAloneCount = 0
            firmware = nil
            mountedDevice = nil
            canCleanUpMacFiles = false
            hasPeopleArtwork = nil
            notes = []
            return
        }
        draft = EditableExternalDeviceProfile(profile: profile)
        leftAloneCount = DeviceLeftAloneStore().load(profileID: id).count
        refreshMountedState()
    }

    /// The selected profile's mounted device, as the app sees it now.
    private func refreshMountedState() {
        guard let model, let selectedID, let device = model.mountedDevice(forProfileID: selectedID) else {
            firmware = nil
            mountedDevice = nil
            canCleanUpMacFiles = false
            hasPeopleArtwork = nil
            notes = []
            return
        }
        firmware = model.firmware(for: device)
        mountedDevice = device
        let capabilities = model.capabilities(for: device)
        canCleanUpMacFiles = capabilities.contains(.appleDoubleSweep)
        hasPeopleArtwork = capabilities.contains(.centralPeopleArtwork)
        notes = model.deviceNotes[device.id] ?? []
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
            // Capture the volume's UUID so this profile binds to *this* physical
            // device — two identically-named iPods at /Volumes/IPOD stay distinct.
            draft.volumeUUID = (try? url.resourceValues(forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString
        } catch {
            AppLog.prefs.warning("Could not bookmark device root: \(String(describing: error), privacy: .public)")
        }
    }

    /// A new Rockbox profile for a device whose probe says PodBox starts on
    /// the PodBox recommended layout. Every other new profile, and every
    /// existing one, keeps the layout it is given.
    private func seededForPodBox(_ profile: ExternalDeviceProfile, device: MountedDevice) -> ExternalDeviceProfile {
        guard profile.kind == .rockboxIPod, model?.firmware(for: device)?.flavour == .podBox,
              let template = RockboxLayoutPreset.podBoxRecommended.template else { return profile }
        var seeded = profile
        seeded.transferSettings.templateConfig = template
        seeded.transferSettings.folderStructureMode = .metadataTemplate
        return seeded
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
    var volumeUUID: String?
    var musicDirectorySubpath: String = "Music"
    var iconID: String?
    /// The whole transfer settings value — device-only fields (mode,
    /// compatibility) and the art are edited inline; the format+folder core is
    /// edited via the Patch Bay (which edits the art too).
    var settings = ExternalDeviceTransferSettings()
    /// Carried through so saving the draft keeps it; the cleanup switch and
    /// the On the iPod rows edit it.
    var podBox: PodBoxPreferences?

    init() {}

    init(profile: ExternalDeviceProfile) {
        name = profile.name
        kind = profile.kind
        rootBookmark = profile.rootBookmark
        rootDisplayPath = profile.rootDisplayPath
        volumeUUID = profile.volumeUUID
        musicDirectorySubpath = profile.musicDirectorySubpath
        iconID = profile.iconID
        settings = profile.transferSettings
        podBox = profile.podBox
    }

    func materialize(id: UUID, createdAt: Date) -> ExternalDeviceProfile {
        ExternalDeviceProfile(
            id: id,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            kind: kind,
            rootBookmark: rootBookmark,
            rootDisplayPath: rootDisplayPath,
            volumeUUID: volumeUUID,
            musicDirectorySubpath: musicDirectorySubpath,
            iconID: iconID,
            transferSettings: settings,
            createdAt: createdAt,
            updatedAt: Date(),
            podBox: podBox
        )
    }
}
