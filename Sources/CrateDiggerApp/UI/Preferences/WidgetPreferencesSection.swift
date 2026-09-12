import CrateDiggerCore
import NowPlayingFeed
import SwiftUI

/// Settings ▸ Interface ▸ Now Playing Widget. The modes travel to the widget
/// inside the feed, so changing one republishes it straight away.
struct WidgetPreferencesSection: View {
    @State private var idleMode = PreferencesStore.shared.widgetIdleMode
    @State private var playingMode = PreferencesStore.shared.widgetPlayingMode

    var body: some View {
        Section("Now Playing Widget") {
            Picker("When nothing is playing", selection: $idleMode) {
                Text("Slideshow of your library").tag(NowPlayingFeed.IdleMode.librarySlideshow)
                Text("Cover of the last album played").tag(NowPlayingFeed.IdleMode.lastAlbumCover)
                Text("A phrase").tag(NowPlayingFeed.IdleMode.phrase)
            }
            .onChange(of: idleMode) { newValue in
                PreferencesStore.shared.widgetIdleMode = newValue
                Self.announceChange()
            }

            Picker("While playing", selection: $playingMode) {
                Text("Album cover").tag(NowPlayingFeed.PlayingMode.albumCover)
                Text("Cover and booklet").tag(NowPlayingFeed.PlayingMode.coverAndBooklet)
            }
            .onChange(of: playingMode) { newValue in
                PreferencesStore.shared.widgetPlayingMode = newValue
                Self.announceChange()
            }

            Text("Slideshows move on every minute. Cover and booklet turns the album's scans or PDF booklet after its cover, when it has one. To add the widget, right-click the desktop and choose Edit Widgets.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onAppear {
            // The window controller is cached across opens; re-read in case a
            // Reset Preferences cleared these.
            idleMode = PreferencesStore.shared.widgetIdleMode
            playingMode = PreferencesStore.shared.widgetPlayingMode
        }
    }

    private static func announceChange() {
        NotificationCenter.default.post(name: NSNotification.Name("CrateDiggerWidgetModesChanged"), object: nil)
    }
}
