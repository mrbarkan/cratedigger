import CrateDiggerCore
import SwiftUI

/// The inspector's controls, mounted on the chassis *outside* the paper panel:
/// the tab row above it and the library tools below it. They sit here rather
/// than inside `InspectorPane` so the panel itself only ever shows content.

// MARK: - Tabs (above the panel)

struct InspectorTabBar: View {
    @Environment(\.carbonGeometry) private var geometry
    @EnvironmentObject private var model: LibraryViewModel

    /// The DISC tab (spinning record) only makes sense for local files — it's
    /// disabled while browsing Radio / Streams.
    private func isDisabled(_ tab: InspectorTab) -> Bool {
        tab == .disc && model.isRadioMode
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                ForEach(InspectorTab.allCases, id: \.self) { tab in
                    KeyButton(
                        style: model.inspectorTab == tab ? .selected : .normal,
                        action: { model.inspectorTab = tab }
                    ) {
                        HStack(spacing: 3) {
                            // The loupe marks the tab that can go looking for art.
                            if tab == .art {
                                Image(systemName: "magnifyingglass")
                                    .font(.system(size: 8, weight: .bold))
                            }
                            Text(tab.rawValue)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 22)
                    .disabled(isDisabled(tab))
                    .opacity(isDisabled(tab) ? 0.4 : 1)
                    .carbonTip(isDisabled(tab) ? "Not available for Radio / Streams" : "")
                }
            }

            // Opens the album's booklet if it has one, otherwise the cover.
            // Full width on its own row: it's an action, not a fifth tab.
            let album = model.selectedAlbum
            KeyButton(style: album == nil ? .disabled : .normal, action: {
                if let album { model.showArtwork(for: album) }
            }) {
                HStack(spacing: 6) {
                    Image(systemName: album?.booklet != nil ? "book.fill" : "photo.fill")
                        .font(.system(size: 10))
                    Text("ARTWORK")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity)
            .frame(height: geometry.keyHeight)
            .carbonTip(album?.booklet != nil ? "Open this album's digital booklet" : "View the album cover")
        }
        // Entering Radio / Streams while on the DISC tab falls back to INFO.
        .onChange(of: model.isRadioMode) { isRadio in
            if isRadio && model.inspectorTab == .disc { model.inspectorTab = .info }
        }
    }
}

// MARK: - Library tools (below the panel)

struct InspectorToolsBar: View {
    @Environment(\.carbonGeometry) private var geometry
    @EnvironmentObject private var model: LibraryViewModel

    @State private var showingCleanup = false

    var body: some View {
        HStack(spacing: 6) {
            KeyButton(style: model.selectedTrack != nil ? .normal : .disabled, action: {
                model.editTags(for: model.resolvedSelectionTracks())
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "tag.fill").font(.system(size: 9))
                    Text("TAGS")
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: geometry.keyHeight)
            .carbonTip("View and edit the selected tracks' tags")

            // On a mounted device this slot becomes FIX ART: CLEANUP
            // reorganizes the *library*, which is meaningless while you're
            // looking at what's on a player, and repairing that player's
            // covers is the thing you actually reach for there.
            if model.browsedMountedDevice != nil {
                KeyButton(style: model.canFixDeviceAlbumArt ? .normal : .disabled, action: {
                    model.fixDeviceAlbumArt()
                }) {
                    HStack(spacing: 4) {
                        if model.isFixingDeviceArt {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "photo.on.rectangle.angled").font(.system(size: 9))
                        }
                        Text(model.isFixingDeviceArt ? "FIXING…" : "FIX ART")
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: geometry.keyHeight)
                .disabled(!model.canFixDeviceAlbumArt)
                .carbonTip("Write a cover.jpg beside every album on this device, taken from the tracks already on it. Players that read folder art (Rockbox) pick it up; the audio files aren't touched.")
            } else {
                KeyButton(style: .normal, action: { showingCleanup = true }) {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkles").font(.system(size: 9))
                        Text("CLEANUP")
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: geometry.keyHeight)
            }

            // Select tracks → re-probe them, then look the release up online
            // and offer the differences for review. With nothing selected it
            // falls back to a local-only sweep of the source (see
            // LibraryViewModel+MetadataRepair).
            // While a run is in flight the key becomes its own stop button —
            // a whole-library selection is thousands of file reads, and the
            // press that started it is where you look to end it.
            KeyButton(style: model.canRepairMetadata ? .normal : .disabled, action: {
                if model.isRepairingMetadata {
                    model.cancelMetadataRepair()
                } else {
                    model.repairMissingMetadata()
                }
            }) {
                HStack(spacing: 4) {
                    if model.isRepairingMetadata {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "bandage.fill").font(.system(size: 9))
                    }
                    Text(model.isRepairingMetadata ? "STOP" : "FIX TAGS")
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: geometry.keyHeight)
            .disabled(!model.canRepairMetadata)
            .carbonTip("Look up the selected tracks online (MusicBrainz · iTunes) and choose which tags to correct. If the names don't match anything, Deep Scan identifies them by their audio instead. With nothing selected, checks the whole source against the files without going online.")
        }
        // A tool you work *in*, so it gets a movable, resizable panel.
        .carbonPanel(
            isPresented: $showingCleanup,
            title: "Library Cleanup",
            minSize: NSSize(width: 560, height: 420),
            initialSize: NSSize(width: 720, height: 560),
            maxSize: NSSize(width: 1200, height: 900),
            autosaveName: "cratedigger.panel.cleanup"
        ) {
            LibraryCleanupView().environmentObject(model)
        }
    }
}
