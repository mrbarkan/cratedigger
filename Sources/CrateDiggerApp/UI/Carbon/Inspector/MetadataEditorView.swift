import SwiftUI
import CrateDiggerCore

/// Identifies the track(s) a tag-editor sheet should edit. One track → the full
/// per-track editor; many → a batch editor of the shared album/artist fields.
struct TagEditTarget: Identifiable {
    let id = UUID()
    let tracks: [LoadedTrack]
}

struct MetadataEditorView: View {
    @Environment(\.carbon) private var theme
    @EnvironmentObject private var model: LibraryViewModel
    @Environment(\.dismiss) private var dismiss

    let tracks: [LoadedTrack]

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

    private var isBatch: Bool { tracks.count > 1 }

    init(track: LoadedTrack) {
        self.init(tracks: [track])
    }

    init(tracks: [LoadedTrack]) {
        self.tracks = tracks
        let primary = tracks.first
        if tracks.count > 1 {
            // Batch: prefill the shared fields; blank where tracks disagree.
            let metas = tracks.map(\.metadata)
            func common(_ f: ConversionMetadata.BatchField) -> String {
                ConversionMetadata.commonValue(f, in: metas) ?? ""
            }
            _title = State(initialValue: "")
            _artist = State(initialValue: common(.artist))
            _albumArtist = State(initialValue: common(.albumArtist))
            _album = State(initialValue: common(.album))
            _genre = State(initialValue: common(.genre))
            _yearString = State(initialValue: common(.year))
            _trackNumString = State(initialValue: "")
            _trackTotalString = State(initialValue: common(.trackTotal))
            _discNumString = State(initialValue: "")
            _discTotalString = State(initialValue: common(.discTotal))
            _comment = State(initialValue: common(.comment))
        } else {
            _title = State(initialValue: primary?.track.title ?? "")
            _artist = State(initialValue: primary?.track.artist ?? "")
            _albumArtist = State(initialValue: primary?.metadata.albumArtist ?? "")
            _album = State(initialValue: primary?.track.album ?? "")
            _genre = State(initialValue: primary?.metadata.genre ?? "")
            _yearString = State(initialValue: primary?.track.year.map(String.init) ?? "")
            _trackNumString = State(initialValue: primary?.track.trackNumber.map(String.init) ?? "")
            _trackTotalString = State(initialValue: primary?.metadata.trackTotal.map(String.init) ?? "")
            _discNumString = State(initialValue: primary?.track.discNumber.map(String.init) ?? "")
            _discTotalString = State(initialValue: primary?.metadata.discTotal.map(String.init) ?? "")
            _comment = State(initialValue: primary?.metadata.comment ?? "")
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 14) {
                    if isBatch {
                        Text("Editing \(tracks.count) tracks · blank fields are left unchanged")
                            .font(CarbonFont.mono(8.5, weight: .medium))
                            .foregroundStyle(theme.ink3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        groupField("Title", text: $title)
                    }

                    groupField("Artist", text: $artist, field: .artist)
                    groupField("Album Artist", text: $albumArtist, field: .albumArtist)
                    groupField("Album", text: $album, field: .album)
                    groupField("Genre", text: $genre, field: .genre)

                    HStack(spacing: 14) {
                        groupField("Year", text: $yearString, field: .year)
                        if !isBatch {
                            groupField("Track No", text: $trackNumString)
                        }
                        groupField("Track Total", text: $trackTotalString, field: .trackTotal)
                    }

                    HStack(spacing: 14) {
                        if !isBatch {
                            groupField("Disc No", text: $discNumString)
                        }
                        groupField("Disc Total", text: $discTotalString, field: .discTotal)
                        Spacer()
                    }

                    groupField("Comment", text: $comment, field: .comment)
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
            Text((isBatch ? "Edit \(tracks.count) Tracks" : "Edit Track Tags").uppercased())
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

            KeyButton(style: .selected, action: save) {
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

    /// A labelled text field. In batch mode, fields whose tracks disagree show a
    /// "Multiple values" placeholder so an empty box reads as "mixed", not blank.
    private func groupField(_ label: String, text: Binding<String>,
                            field: ConversionMetadata.BatchField? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(CarbonFont.mono(8, weight: .bold))
                .tracking(1.4)
                .foregroundStyle(theme.ink3)
            TextField(placeholder(for: field), text: text)
                .textFieldStyle(.plain)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(theme.isDark ? Color.white.opacity(0.04) : Color.black.opacity(0.03))
                .cornerRadius(4)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(theme.ink4.opacity(0.25), lineWidth: 0.8))
        }
    }

    private func placeholder(for field: ConversionMetadata.BatchField?) -> String {
        guard isBatch, let field else { return "" }
        return ConversionMetadata.commonValue(field, in: tracks.map(\.metadata)) == nil
            ? "Multiple values" : ""
    }

    private func save() {
        isBatch ? saveBatch() : saveSingle()
        dismiss()
    }

    private func saveSingle() {
        guard let track = tracks.first else { return }
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
    }

    private func saveBatch() {
        let metas = tracks.map(\.metadata)
        var edits: [ConversionMetadata.BatchField: String] = [:]
        // A field counts as "edited" only when its box differs from the shared
        // value it was prefilled with — so untouched (incl. mixed) fields are
        // left exactly as they were on every track.
        func consider(_ field: ConversionMetadata.BatchField, _ current: String) {
            let original = ConversionMetadata.commonValue(field, in: metas) ?? ""
            if current != original { edits[field] = current }
        }
        consider(.artist, artist)
        consider(.albumArtist, albumArtist)
        consider(.album, album)
        consider(.genre, genre)
        consider(.year, yearString)
        consider(.trackTotal, trackTotalString)
        consider(.discTotal, discTotalString)
        consider(.comment, comment)

        guard !edits.isEmpty else { return }
        for track in tracks {
            model.updateTrackMetadata(track, newMetadata: track.metadata.applyingBatchEdits(edits))
        }
    }
}
