import Foundation

/// The art a transfer leaves on the device, as a scan of the device reads it
/// back. Shared by the matcher (what would be sent) and the catalog patch
/// (what was just written), so the two can never disagree about the same
/// write and make an album read as differing right after it was sent.
///
/// `artworkDimensions` on a library track describes the art the library
/// resolved (embedded, else a folder image, else cached remote art), not what
/// is inside the file, so what lands depends on the write:
/// - A copy (`artworkMode` nil) moves the file's bytes, so only embedded art lands.
/// - Keep (`.preserve`) maps the source's own picture stream (`0:v?`) as it
///   is: only embedded art, never resized.
/// - Re-embed (`.compatReembed`) writes `ConversionMetadata.artwork`, the
///   resolved art whatever its source, resized like
///   `ArtworkService.prepareCompatibleArtwork`.
/// - Strip (`.none`) writes none.
/// - A folder cover (`FolderCoverArtWriter`) takes the resolved art of any
///   source, at most `FolderCoverArtWriter.defaultMaxDimension`.
///
/// A device scan reads embedded art before a `cover.jpg`
/// (`ArtworkService.resolveArtwork`), so embedded art is what the catalog
/// records whenever the write put any in the file, even beside a larger cover
/// (whatever the player itself prefers to draw).
enum DeviceWrittenArt {
    /// Longest side and source of the art a scan reads back after writing
    /// `tracks`, or nil for none. Each track is read back on its own, the way
    /// the catalog patch records it, and the first that yields art decides:
    /// an album whose art is embedded in only some files then reads the same
    /// here as its patched catalog records do, where the matcher takes the
    /// first track carrying art.
    static func readBack(
        of tracks: [LoadedTrack],
        artworkMode: ArtworkMode?,
        cap: Int?,
        deviceProfile: DeviceProfile,
        writesFolderCoverArt: Bool
    ) -> (side: Int, source: ArtworkSource)? {
        tracks.lazy.compactMap {
            readBack(of: $0, artworkMode: artworkMode, cap: cap,
                     deviceProfile: deviceProfile, writesFolderCoverArt: writesFolderCoverArt)
        }.first
    }

    /// One track's art as a scan reads it back after the write.
    private static func readBack(
        of track: LoadedTrack,
        artworkMode: ArtworkMode?,
        cap: Int?,
        deviceProfile: DeviceProfile,
        writesFolderCoverArt: Bool
    ) -> (side: Int, source: ArtworkSource)? {
        let tracks = [track]
        let embedded: Int?
        switch artworkMode {
        case nil, .preserve?:
            embedded = longestSide(of: tracks, from: [.embedded])
        case .compatReembed?:
            embedded = longestSide(of: tracks, from: nil).map {
                reembeddedSide($0, cap: cap, deviceProfile: deviceProfile)
            }
        case .none?:
            embedded = nil
        }
        if let embedded { return (embedded, .embedded) }

        guard writesFolderCoverArt, let resolved = longestSide(of: tracks, from: nil) else { return nil }
        return (min(resolved, FolderCoverArtWriter.defaultMaxDimension), .folderImage)
    }

    /// `ArtworkService.prepareCompatibleArtwork`: a cap (never under 120)
    /// shrinks, never enlarges; without one the picture is left alone, except
    /// on the legacy-safe profile, which always goes to 600.
    static func reembeddedSide(_ side: Int, cap: Int?, deviceProfile: DeviceProfile) -> Int {
        if let cap { return min(side, max(120, cap)) }
        return deviceProfile == .ipodLegacySafe ? min(side, 600) : side
    }

    /// Longest side of the first track in the list that carries art
    /// dimensions from one of `sources` (nil: any source).
    static func longestSide(of tracks: [LoadedTrack], from sources: Set<ArtworkSource>?) -> Int? {
        tracks.lazy
            .filter { sources?.contains($0.track.artworkSource) ?? true }
            .compactMap(\.track.artworkDimensions)
            .first
            .map { max($0.width, $0.height) }
    }
}
