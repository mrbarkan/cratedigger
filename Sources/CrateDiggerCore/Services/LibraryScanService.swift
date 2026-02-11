import AVFoundation
import Foundation

public struct LoadedTrack: Sendable {
    public let track: AudioTrack
    public let metadata: ConversionMetadata

    public init(track: AudioTrack, metadata: ConversionMetadata) {
        self.track = track
        self.metadata = metadata
    }
}

public final class LibraryScanService {
    private let fileManager: FileManager
    private let artworkService: ArtworkService
    private let supportedExtensions: Set<String>

    public init(
        fileManager: FileManager = .default,
        artworkService: ArtworkService = ArtworkService(),
        supportedExtensions: Set<String> = ["mp3", "aac", "m4a", "flac", "wav", "aiff", "ogg", "opus", "caf"]
    ) {
        self.fileManager = fileManager
        self.artworkService = artworkService
        self.supportedExtensions = supportedExtensions
    }

    public func scanFolder(_ folderURL: URL) -> [LoadedTrack] {
        guard let enumerator = fileManager.enumerator(at: folderURL, includingPropertiesForKeys: nil) else {
            return []
        }

        var loadedTracks: [LoadedTrack] = []

        for case let fileURL as URL in enumerator {
            guard supportedExtensions.contains(fileURL.pathExtension.lowercased()) else {
                continue
            }

            if let loadedTrack = loadTrack(at: fileURL) {
                loadedTracks.append(loadedTrack)
            }
        }

        return loadedTracks.sorted { lhs, rhs in
            lhs.track.title.localizedCaseInsensitiveCompare(rhs.track.title) == .orderedAscending
        }
    }

    private func loadTrack(at fileURL: URL) -> LoadedTrack? {
        let asset = AVURLAsset(url: fileURL)

        let title = stringValue(forCommonKey: "title", from: asset) ?? fileURL.deletingPathExtension().lastPathComponent
        let artist = stringValue(forCommonKey: "artist", from: asset) ?? ""
        let album = stringValue(forCommonKey: "albumName", from: asset) ?? ""
        let genre = stringValue(forIdentifierContains: "genre", from: asset)
            ?? stringValue(forCommonKey: "type", from: asset)

        let durationSeconds = duration(from: asset)
        let artwork = artworkService.resolveArtwork(trackURL: fileURL)

        var metadata = ConversionMetadata(
            title: title,
            artist: artist,
            album: album,
            year: intValue(forIdentifierContains: "year", from: asset),
            genre: genre,
            comment: stringValue(forIdentifierContains: "comment", from: asset),
            artwork: artwork
        )

        if metadata.trackNumber == nil {
            metadata.trackNumber = intValue(forIdentifierContains: "trackNumber", from: asset)
        }

        let track = AudioTrack(
            fileURL: fileURL,
            title: title,
            artist: artist,
            album: album,
            durationSeconds: durationSeconds,
            artworkSource: artwork?.source ?? .none,
            artworkHash: artwork?.hash,
            artworkDimensions: artwork?.dimensions
        )

        return LoadedTrack(track: track, metadata: metadata)
    }

    private func stringValue(forCommonKey key: String, from asset: AVAsset) -> String? {
        for item in asset.commonMetadata where item.commonKey?.rawValue == key {
            if let value = item.stringValue, !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private func stringValue(forIdentifierContains key: String, from asset: AVAsset) -> String? {
        let lowercaseKey = key.lowercased()
        for format in asset.availableMetadataFormats {
            for item in asset.metadata(forFormat: format) {
                if let identifier = item.identifier?.rawValue.lowercased(), identifier.contains(lowercaseKey),
                   let value = item.stringValue,
                   !value.isEmpty {
                    return value
                }
            }
        }
        return nil
    }

    private func intValue(forIdentifierContains key: String, from asset: AVAsset) -> Int? {
        guard let value = stringValue(forIdentifierContains: key, from: asset) else {
            return nil
        }

        let filtered = value.filter { $0.isNumber }
        return Int(filtered)
    }

    private func duration(from asset: AVAsset) -> Double {
        let seconds = CMTimeGetSeconds(asset.duration)
        guard seconds.isFinite && seconds > 0 else {
            return 0
        }
        return seconds
    }
}
