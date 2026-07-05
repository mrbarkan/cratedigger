import CrateDiggerCore
import SwiftUI

struct SourcesSidebar: View {
    @Environment(\.carbon) private var theme
    @EnvironmentObject private var model: LibraryViewModel

    @State private var showingPlaylistSheet = false
    @State private var newPlaylistName = ""
    @State private var showingCrateSheet = false
    @State private var newCrateName = ""
    @State private var targetedCrate: String? = nil
    @State private var targetedPlaylist: String? = nil
    @State private var editTarget: SidebarEditTarget? = nil
    @State private var editText: String = ""
    @FocusState private var editFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    sectionHeader("Prep Crate", trailing: "")
                    sidebarItem(
                        icon: Image(systemName: "tray.and.arrow.down"),
                        title: "Prep Crate",
                        count: "\(model.prepCrateTracks.count)",
                        selected: model.currentSource == .prepCrate,
                        action: { model.selectSource(.prepCrate) }
                    )
                    .contextMenu {
                        if !model.selectedTracksForCrateAdd().isEmpty {
                            Button("Add \(model.selectedTracksForCrateAdd().count) selected to \(model.targetCrateName)") {
                                model.addSelectionToCrate(crateName: model.targetCrateName)
                            }
                            Divider()
                        }
                        if !model.prepCrateTracks.isEmpty {
                            ForEach(model.availableCrates, id: \.self) { crateName in
                                Button("Add all to \(crateName)") {
                                    model.addItemsToCrate(model.prepCrateTracks.map { "track::" + $0.track.id.uuidString }, crateName: crateName)
                                }
                            }
                        }
                    }

                    HStack {
                        sectionHeader("Local Library", trailing: "")
                        Spacer()
                        Button(action: { showingCrateSheet = true }) {
                            Image(systemName: "plus")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(theme.ink2)
                        }
                        .buttonStyle(.carbonHover)
                        .padding(.trailing, 12)
                        .padding(.top, 10)
                    }
                    
                    sidebarItem(
                        icon: Image(systemName: "square.stack"),
                        title: "All Records",
                        count: "\(model.allRecordsCount)",
                        selected: model.currentSource == .localAll,
                        action: { model.selectSource(.localAll) }
                    )

                    ForEach(model.availableCrates, id: \.self) { crateName in
                        HStack {
                            crateLabel(crateName)
                            if crateName != LibraryViewModel.personalCrateName {
                                Button(action: { model.deleteCrate(name: crateName) }) {
                                    Image(systemName: "trash")
                                        .font(.system(size: 9))
                                        .foregroundColor(theme.ink3)
                                }
                                .buttonStyle(.carbonHover)
                                .padding(.trailing, 14)
                            }
                        }
                        .contextMenu {
                            Button("Set as Target Crate") {
                                model.targetCrateName = crateName
                            }
                            if crateName != LibraryViewModel.personalCrateName {
                                Button("Rename") {
                                    beginRename(.crate(crateName), current: crateName)
                                }
                                Button("Delete Crate") {
                                    model.deleteCrate(name: crateName)
                                }
                            }
                        }
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(targetedCrate == crateName ? theme.cyan : Color.clear, lineWidth: 1.5)
                        )
                        .draggable("crate::" + crateName)
                        .dropDestination(for: String.self) { items, _ in
                            // A crate dragged onto another reorders the list; any other
                            // payload (track/artist/album) adds those tracks to this crate.
                            if let dragged = items.first(where: { $0.hasPrefix("crate::") }) {
                                model.moveCrate(String(dragged.dropFirst("crate::".count)), before: crateName)
                            } else {
                                model.addItemsToCrate(items, crateName: crateName)
                            }
                            return true
                        } isTargeted: { targeted in
                            if targeted {
                                targetedCrate = crateName
                            } else if targetedCrate == crateName {
                                targetedCrate = nil
                            }
                        }
                        .dropDestination(for: URL.self) { urls, _ in
                            model.addURLsToCrate(urls, crateName: crateName)
                            return true
                        } isTargeted: { targeted in
                            if targeted {
                                targetedCrate = crateName
                            } else if targetedCrate == crateName {
                                targetedCrate = nil
                            }
                        }
                    }
                    
                    sectionHeader("Remote Library", trailing: "")
                    sidebarItem(
                        icon: Image(systemName: "cloud"),
                        title: "Subsonic / Navidrome",
                        count: "\(model.currentSource == .remote ? model.index.allTracks.count : 0)",
                        selected: model.currentSource == .remote,
                        action: { model.selectSource(.remote) }
                    )
                    
                    HStack {
                        sectionHeader("Radio / Streams", trailing: "")
                        Spacer()
                        Button(action: { model.showingAddStreamSheet = true }) {
                            Image(systemName: "plus")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(theme.ink2)
                        }
                        .buttonStyle(.carbonHover)
                        .padding(.trailing, 12)
                        .padding(.top, 10)
                        .carbonTip("Add a YouTube stream source")
                    }

                    sidebarItem(
                        icon: Image(systemName: "dot.radiowaves.left.and.right"),
                        title: "All Streams",
                        count: "\(model.streams.count)",
                        selected: isSelectedRadio(nil),
                        action: { model.enterRadio(category: nil) }
                    )

                    ForEach(model.streamCategories, id: \.self) { category in
                        sidebarItem(
                            icon: Image(systemName: category.iconName),
                            title: category.title,
                            count: category == .youtubeLive
                                ? "LIVE" : "\(model.streamCount(in: category))",
                            selected: isSelectedRadio(category),
                            action: { model.enterRadio(category: category) }
                        )
                    }

                    if !model.mountedCDs.isEmpty {
                        sectionHeader("CD Drives", trailing: "")
                        ForEach(model.mountedCDs) { cd in
                            VStack(alignment: .leading, spacing: 4) {
                                sidebarItem(
                                    icon: Image(systemName: "opticaldisc"),
                                    title: cd.name,
                                    count: "\(cd.tracks.count)",
                                    selected: isSelectedCD(cd.volumeURL.path),
                                    action: { model.selectSource(.cd(volumePath: cd.volumeURL.path)) }
                                )
                                Button(action: { model.ripCD(info: cd) }) {
                                    Text("RIP CD")
                                        .font(CarbonFont.mono(8, weight: .bold))
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(theme.orange)
                                        .cornerRadius(4)
                                }
                                .buttonStyle(.carbonHover)
                                .padding(.leading, 36)
                                .padding(.bottom, 6)
                            }
                        }
                    }

                    if !model.mountedDevices.isEmpty {
                        sectionHeader("Devices", trailing: "")
                        ForEach(model.mountedDevices) { device in
                            sidebarItem(
                                icon: deviceIcon(for: device),
                                title: device.name,
                                count: isSelectedDevice(device.volumeURL.path) ? "\(model.index.allTracks.count)" : "—",
                                selected: isSelectedDevice(device.volumeURL.path),
                                action: { model.selectSource(.device(volumePath: device.volumeURL.path)) }
                            )
                        }
                    }

                    HStack {
                        sectionHeader("Playlists", trailing: "")
                        Spacer()
                        Button(action: { showingPlaylistSheet = true }) {
                            Image(systemName: "plus")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(theme.ink2)
                        }
                        .buttonStyle(.carbonHover)
                        .padding(.trailing, 12)
                        .padding(.top, 10)
                    }
                    
                    ForEach(model.playlists) { pl in
                        HStack {
                            playlistLabel(pl)
                            Button(action: { model.deletePlaylist(name: pl.name) }) {
                                Image(systemName: "trash")
                                    .font(.system(size: 9))
                                    .foregroundColor(theme.ink3)
                            }
                            .buttonStyle(.carbonHover)
                            .padding(.trailing, 14)
                        }
                        .contextMenu {
                            Button("Rename") {
                                beginRename(.playlist(pl.name), current: pl.name)
                            }
                            Button("Delete Playlist") {
                                model.deletePlaylist(name: pl.name)
                            }
                        }
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(targetedPlaylist == pl.name ? theme.cyan : Color.clear, lineWidth: 1.5)
                        )
                        .dropDestination(for: String.self) { items, _ in
                            model.addItemsToPlaylist(items, playlistName: pl.name)
                            return true
                        } isTargeted: { targeted in
                            if targeted {
                                targetedPlaylist = pl.name
                            } else if targetedPlaylist == pl.name {
                                targetedPlaylist = nil
                            }
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showingPlaylistSheet) {
            playlistCreationSheet
        }
        .sheet(isPresented: $showingCrateSheet) {
            crateCreationSheet
        }
        .onAppear {
            model.refreshCDs()
            model.refreshDevices()
        }
    }

    private func isSelectedPlaylist(_ name: String) -> Bool {
        if case .playlist(let currentName) = model.currentSource {
            return currentName == name
        }
        return false
    }

    private func isSelectedCrate(_ name: String) -> Bool {
        if case .localCrate(let currentName) = model.currentSource {
            return currentName == name
        }
        return false
    }

    private func isSelectedCD(_ path: String) -> Bool {
        if case .cd(let currentPath) = model.currentSource {
            return currentPath == path
        }
        return false
    }

    private func isSelectedDevice(_ path: String) -> Bool {
        if case .device(let currentPath) = model.currentSource {
            return currentPath == path
        }
        return false
    }

    private func isSelectedRadio(_ category: RadioCategory?) -> Bool {
        if case .radio(let current) = model.currentSource {
            return current == category
        }
        return false
    }

    private var playlistCreationSheet: some View {
        VStack(spacing: 20) {
            Text("Create Playlist".uppercased())
                .font(CarbonFont.mono(11, weight: .bold))
                .tracking(2)
            TextField("Playlist Name", text: $newPlaylistName)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("Cancel") {
                    showingPlaylistSheet = false
                    newPlaylistName = ""
                }
                Spacer()
                Button("Create") {
                    if !newPlaylistName.isEmpty {
                        model.createPlaylist(name: newPlaylistName)
                        showingPlaylistSheet = false
                        newPlaylistName = ""
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 300)
    }

    private var crateCreationSheet: some View {
        VStack(spacing: 20) {
            Text("Create Crate".uppercased())
                .font(CarbonFont.mono(11, weight: .bold))
                .tracking(2)
            TextField("Crate Name", text: $newCrateName)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("Cancel") {
                    showingCrateSheet = false
                    newCrateName = ""
                }
                Spacer()
                Button("Create") {
                    if !newCrateName.isEmpty {
                        model.createCrate(name: newCrateName)
                        showingCrateSheet = false
                        newCrateName = ""
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 300)
    }

    private func sectionHeader(_ title: String, trailing: String) -> some View {
        HStack {
            Text(title.uppercased())
            Spacer()
            Text(trailing)
        }
        .font(CarbonFont.mono(8.5, weight: .semibold))
        .tracking(2.2)
        .foregroundStyle(theme.ink4)
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 3)
    }

    /// Device rows show the real thing: the profile's chosen device portrait
    /// (e.g. an iPod) when one is set, else the volume's own Finder icon.
    private func deviceIcon(for device: MountedDevice) -> Image {
        if let nsImage = DeviceSystemIcons.image(for: model.deviceProfile(for: device)?.iconID) {
            return DeviceSystemIcons.sidebarImage(nsImage, points: 16)
        }
        return DeviceSystemIcons.sidebarImage(
            NSWorkspace.shared.icon(forFile: device.volumeURL.path), points: 16
        )
    }

    private func sidebarItem(
        icon: Image,
        title: String,
        count: String,
        selected: Bool,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: { if !disabled { action() } }) {
            HStack(spacing: 8) {
                icon
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(iconColor(selected: selected, disabled: disabled))
                    .frame(width: 16, height: 16)
                Text(title)
                    .font(CarbonFont.sans(12.5, weight: .medium))
                    .foregroundStyle(textColor(selected: selected, disabled: disabled))
                Spacer()
                Text(count)
                    .font(CarbonFont.mono(9.5))
                    .foregroundStyle(countColor(selected: selected, disabled: disabled))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(rowBackground(selected: selected))
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.carbonHover)
        .opacity(disabled ? 0.5 : 1)
        .allowsHitTesting(!disabled)
    }

    private func textColor(selected: Bool, disabled: Bool) -> Color {
        if disabled { return theme.ink3 }
        if selected { return theme.selectionInk }
        return theme.ink
    }

    private func iconColor(selected: Bool, disabled: Bool) -> Color {
        if disabled { return theme.ink4 }
        if selected { return theme.selectionInk }
        return theme.ink3
    }

    private func countColor(selected: Bool, disabled: Bool) -> Color {
        if selected {
            return theme.selectionInk.opacity(0.72)
        }
        return theme.ink3
    }

    @ViewBuilder
    private func rowBackground(selected: Bool) -> some View {
        if selected {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            theme.indigo.opacity(theme.isDark ? 0.88 : 0.82),
                            theme.cyan.opacity(theme.isDark ? 0.86 : 0.76)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.white.opacity(0.26), lineWidth: 1)
                )
                .shadow(color: theme.cyan.opacity(theme.isDark ? 0.24 : 0.18), radius: 10)
        } else {
            Color.clear
        }
    }

    // MARK: - Renamable crate / playlist rows

    @ViewBuilder
    private func crateLabel(_ crateName: String) -> some View {
        if editTarget == .crate(crateName) {
            renameField { commitRename(.crate(crateName)) }
        } else {
            sidebarItem(
                icon: Image(systemName: crateName == model.targetCrateName ? "shippingbox.fill" : "shippingbox"),
                title: crateName,
                count: "\(model.crateTrackCounts[crateName] ?? 0)",
                selected: isSelectedCrate(crateName),
                action: {
                    model.selectSource(.localCrate(name: crateName))
                    model.targetCrateName = crateName
                }
            )
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                guard crateName != LibraryViewModel.personalCrateName else { return }
                beginRename(.crate(crateName), current: crateName)
            })
        }
    }

    @ViewBuilder
    private func playlistLabel(_ pl: Playlist) -> some View {
        if editTarget == .playlist(pl.name) {
            renameField { commitRename(.playlist(pl.name)) }
        } else {
            sidebarItem(
                icon: Image(systemName: "music.note.list"),
                title: pl.name,
                count: "\(pl.trackURLs.count)",
                selected: isSelectedPlaylist(pl.name),
                action: { model.selectSource(.playlist(name: pl.name)) }
            )
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                beginRename(.playlist(pl.name), current: pl.name)
            })
        }
    }

    /// Inline rename field, padded to line up with `sidebarItem`.
    private func renameField(commit: @escaping () -> Void) -> some View {
        TextField("", text: $editText)
            .textFieldStyle(.plain)
            .font(CarbonFont.sans(12.5, weight: .medium))
            .foregroundStyle(theme.ink)
            .focused($editFieldFocused)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(theme.well.opacity(theme.isDark ? 0.7 : 0.5))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(theme.cyan.opacity(0.7), lineWidth: 1)
                    )
            )
            .padding(.horizontal, 4)
            .onSubmit(commit)
            .onExitCommand { cancelRename() }
            .onAppear { editFieldFocused = true }
            .onChange(of: editFieldFocused) { focused in
                if !focused { cancelRename() }
            }
    }

    private func beginRename(_ target: SidebarEditTarget, current: String) {
        editText = current
        editTarget = target
        editFieldFocused = true
    }

    private func commitRename(_ target: SidebarEditTarget) {
        let proposed = editText
        editTarget = nil
        switch target {
        case .crate(let old): _ = model.renameCrate(old, to: proposed)
        case .playlist(let old): _ = model.renamePlaylist(old, to: proposed)
        }
    }

    private func cancelRename() {
        editTarget = nil
    }
}

/// Which sidebar item is being renamed inline.
private enum SidebarEditTarget: Equatable {
    case crate(String)
    case playlist(String)
}
