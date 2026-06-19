import SwiftUI
import CrateDiggerCore

struct MetadataEditorView: View {
    @Environment(\.carbon) private var theme
    @EnvironmentObject private var model: LibraryViewModel
    @Environment(\.dismiss) private var dismiss

    let track: LoadedTrack

    @State private var title: String
    @State private var artist: String
    @State private var albumArtist: String
    @State private var album: String
    @State private var genre: String
    @State private var yearString: String
    @State private var trackNumString: String
    @State private var trackTotalString: String
    @State private var discNumString: String
    @State private var discTotalString: String
    @State private var comment: String

    init(track: LoadedTrack) {
        self.track = track
        _title = State(initialValue: track.track.title)
        _artist = State(initialValue: track.track.artist)
        _albumArtist = State(initialValue: track.metadata.albumArtist ?? "")
        _album = State(initialValue: track.track.album)
        _genre = State(initialValue: track.metadata.genre ?? "")
        _yearString = State(initialValue: track.track.year.map(String.init) ?? "")
        _trackNumString = State(initialValue: track.track.trackNumber.map(String.init) ?? "")
        _trackTotalString = State(initialValue: track.metadata.trackTotal.map(String.init) ?? "")
        _discNumString = State(initialValue: track.track.discNumber.map(String.init) ?? "")
        _discTotalString = State(initialValue: track.metadata.discTotal.map(String.init) ?? "")
        _comment = State(initialValue: track.metadata.comment ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 14) {
                    groupField("Title", text: $title)
                    groupField("Artist", text: $artist)
                    groupField("Album Artist", text: $albumArtist)
                    groupField("Album", text: $album)
                    groupField("Genre", text: $genre)
                    
                    HStack(spacing: 14) {
                        groupField("Year", text: $yearString)
                        groupField("Track No", text: $trackNumString)
                        groupField("Track Total", text: $trackTotalString)
                    }

                    HStack(spacing: 14) {
                        groupField("Disc No", text: $discNumString)
                        groupField("Disc Total", text: $discTotalString)
                        Spacer()
                    }

                    groupField("Comment", text: $comment)
                }
                .padding(18)
            }

            footer
        }
        .frame(width: 480, height: 500)
        .background(theme.chassis)
    }

    private var header: some View {
        HStack {
            Text("Edit Track Tags".uppercased())
                .font(CarbonFont.mono(11, weight: .bold))
                .tracking(2)
                .foregroundStyle(theme.ink)
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(theme.chassisHi)
        .overlay(Rectangle().fill(Color.black.opacity(0.12)).frame(height: 1), alignment: .bottom)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel") {
                dismiss()
            }
            .buttonStyle(.bordered)
            
            KeyButton(style: .selected, action: saveMetadata) {
                Text("SAVE CHANGES")
                    .font(CarbonFont.mono(9.5, weight: .bold))
                    .tracking(1.5)
            }
            .frame(width: 120, height: CarbonLayout.keyHeight)
        }
        .padding(14)
        .background(theme.chassisHi)
        .overlay(Rectangle().fill(Color.black.opacity(0.12)).frame(height: 1), alignment: .top)
    }

    private func groupField(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(CarbonFont.mono(8, weight: .bold))
                .tracking(1.4)
                .foregroundStyle(theme.ink3)
            TextField("", text: text)
                .textFieldStyle(.plain)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(theme.isDark ? Color.white.opacity(0.04) : Color.black.opacity(0.03))
                .cornerRadius(4)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(theme.ink4.opacity(0.25), lineWidth: 0.8))
        }
    }

    private func saveMetadata() {
        var updated = track.metadata
        updated.title = title.isEmpty ? nil : title
        updated.artist = artist.isEmpty ? nil : artist
        updated.albumArtist = albumArtist.isEmpty ? nil : albumArtist
        updated.album = album.isEmpty ? nil : album
        updated.genre = genre.isEmpty ? nil : genre
        updated.year = Int(yearString)
        updated.trackNumber = Int(trackNumString)
        updated.trackTotal = Int(trackTotalString)
        updated.discNumber = Int(discNumString)
        updated.discTotal = Int(discTotalString)
        updated.comment = comment.isEmpty ? nil : comment

        model.updateTrackMetadata(track, newMetadata: updated)
        dismiss()
    }
}
