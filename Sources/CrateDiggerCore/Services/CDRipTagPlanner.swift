import CryptoKit
import Foundation

/// What an audio CD's tracks rip with, and what a finished rip imports.
///
/// A CD arrives with no tags: macOS mounts it as "1 Audio Track.aiff" on a
/// read-only volume called "Audio CD". So the tags a rip writes are assembled
/// here, in layers: what macOS gave us, then the release the user picked, then
/// any edit the user made while the disc was in the drive. Those edits can't be
/// written to the disc, so they are staged and ride along with the rip.
public enum CDRipTagPlanner {

    /// The disc's tracks as the browser shows them and the rip tags them.
    ///
    /// - Parameter stagedEdits: the user's edits, keyed by the track's file
    ///   path on the disc. An edit replaces the track's tags whole (the editor
    ///   hands back a complete tag set); only a cover it lacks is filled in,
    ///   because the release's cover can arrive after the edit was made.
    public static func tracks(
        for info: AudioCDInfo,
        release: ReleaseCandidate?,
        cover: ArtworkAsset?,
        stagedEdits: [String: ConversionMetadata] = [:]
    ) -> [LoadedTrack] {
        let trackCount = info.tracks.count
        let disc = release.map { discNumber(in: $0, trackCount: trackCount) }
        let discTotal = release.flatMap { discTotal(of: $0) }
        // Disc numbers only mean something on a multi-disc release; stamping
        // "disc 1 of 1" on an ordinary album is noise (ReleaseScorer agrees).
        let isMultiDisc = (discTotal ?? 1) > 1

        return info.tracks.map { track in
            let matched = release.flatMap { release in
                release.tracks.first { $0.position == track.trackNumber && $0.discNumber == disc }
            }
            var metadata = ConversionMetadata(
                title: matched?.title ?? track.title,
                artist: matched?.artist ?? release?.artist ?? "Audio CD",
                albumArtist: release?.artist,
                album: release?.title ?? info.name,
                trackNumber: track.trackNumber,
                trackTotal: trackCount,
                discNumber: isMultiDisc ? disc : nil,
                discTotal: isMultiDisc ? discTotal : nil,
                year: release?.year,
                genre: release?.genre,
                artwork: cover
            )
            if var edited = stagedEdits[track.fileURL.path] {
                if edited.artwork == nil { edited.artwork = cover }
                metadata = edited
            }

            let audioTrack = AudioTrack(
                id: stableID(for: track.fileURL),
                fileURL: track.fileURL,
                title: metadata.title ?? track.title,
                artist: metadata.artist ?? "",
                album: metadata.album ?? "",
                durationSeconds: matched?.durationSeconds ?? 0,
                formatName: "AIFF",
                year: metadata.year,
                trackNumber: metadata.trackNumber,
                trackTotal: metadata.trackTotal,
                discNumber: metadata.discNumber,
                discTotal: metadata.discTotal
            )
            return LoadedTrack(track: audioTrack, metadata: metadata)
        }
    }

    /// Which disc of a release this CD is.
    ///
    /// A box set's disc ID resolves to the whole set, so the track list holds
    /// every disc. The one in the drive is whichever disc has exactly this many
    /// tracks; matching by position alone would take disc 1's titles for disc 3.
    public static func discNumber(in release: ReleaseCandidate, trackCount: Int) -> Int {
        let byDisc = Dictionary(grouping: release.tracks, by: \.discNumber)
        let exact = byDisc.filter { $0.value.count == trackCount }.keys.sorted()
        return exact.first ?? byDisc.keys.sorted().first ?? 1
    }

    /// The same file on the disc keeps the same ID across rebuilds (the cover
    /// arriving, an edit being staged), so the browser keeps the user's place
    /// instead of falling back to the first track.
    static func stableID(for fileURL: URL) -> UUID {
        let digest = Array(SHA256.hash(data: Data(fileURL.path.utf8)))
        return UUID(uuid: (digest[0], digest[1], digest[2], digest[3], digest[4], digest[5],
                           digest[6], digest[7], digest[8], digest[9], digest[10], digest[11],
                           digest[12], digest[13], digest[14], digest[15]))
    }

    private static func discTotal(of release: ReleaseCandidate) -> Int? {
        release.totalDiscs ?? release.tracks.map(\.discNumber).max()
    }

    /// The folders a finished rip should import: the album folders it wrote
    /// into, in the order it wrote them. Never the destination root, which
    /// holds every album ever converted there.
    public static func importFolders(forWritten files: [URL]) -> [URL] {
        var seen = Set<String>()
        return files.map { $0.deletingLastPathComponent() }.filter { seen.insert($0.path).inserted }
    }
}
