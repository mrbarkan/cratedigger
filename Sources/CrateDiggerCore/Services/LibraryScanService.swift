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

    public func scanFolder(_ folderURL: URL) async -> [LoadedTrack] {
        guard let enumerator = fileManager.enumerator(at: folderURL, includingPropertiesForKeys: nil) else {
            return []
        }

        var candidateURLs: [URL] = []
        while let object = enumerator.nextObject() {
            guard let fileURL = object as? URL,
                  supportedExtensions.contains(fileURL.pathExtension.lowercased()) else {
                continue
            }
            candidateURLs.append(fileURL)
        }

        var loadedTracks: [LoadedTrack] = []
        loadedTracks.reserveCapacity(candidateURLs.count)
        for fileURL in candidateURLs {
            if let loadedTrack = await loadTrack(at: fileURL) {
                loadedTracks.append(loadedTrack)
            }
        }

        return loadedTracks.sorted { lhs, rhs in
            lhs.track.title.localizedCaseInsensitiveCompare(rhs.track.title) == .orderedAscending
        }
    }

    private func loadTrack(at fileURL: URL) async -> LoadedTrack? {
        let asset = AVURLAsset(url: fileURL)
        let commonMetadata = (try? await asset.load(.commonMetadata)) ?? []

        let title = await stringValue(forCommonKey: "title", in: commonMetadata) ?? fileURL.deletingPathExtension().lastPathComponent
        let artist = await stringValue(forCommonKey: "artist", in: commonMetadata) ?? ""
        let album = await stringValue(forCommonKey: "albumName", in: commonMetadata) ?? ""
        let genreFromIdentifier = await stringValue(forIdentifierContains: "genre", from: asset)
        let genreFromCommon = await stringValue(forCommonKey: "type", in: commonMetadata)
        let genre = genreFromIdentifier ?? genreFromCommon

        let durationSeconds = await duration(from: asset)
        let artwork = await artworkService.resolveArtwork(trackURL: fileURL)

        var metadata = ConversionMetadata(
            title: title,
            artist: artist,
            album: album,
            year: await intValue(forIdentifierContains: "year", from: asset),
            genre: genre,
            comment: await stringValue(forIdentifierContains: "comment", from: asset),
            artwork: artwork
        )

        if metadata.trackNumber == nil {
            metadata.trackNumber = await intValue(forIdentifierContains: "trackNumber", from: asset)
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

    private func stringValue(forCommonKey key: String, in metadataItems: [AVMetadataItem]) async -> String? {
        for item in metadataItems where item.commonKey?.rawValue == key {
            if let value = try? await item.load(.stringValue),
               !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private func stringValue(forIdentifierContains key: String, from asset: AVAsset) async -> String? {
        let lowercaseKey = key.lowercased()
        let metadataFormats = (try? await asset.load(.availableMetadataFormats)) ?? []
        for format in metadataFormats {
            guard let metadataItems = try? await asset.loadMetadata(for: format) else {
                continue
            }

            for item in metadataItems {
                if let identifier = item.identifier?.rawValue.lowercased(),
                   identifier.contains(lowercaseKey),
                   let value = try? await item.load(.stringValue),
                   !value.isEmpty {
                    return value
                }
            }
        }
        return nil
    }

    private func intValue(forIdentifierContains key: String, from asset: AVAsset) async -> Int? {
        guard let value = await stringValue(forIdentifierContains: key, from: asset) else {
            return nil
        }

        let filtered = value.filter { $0.isNumber }
        return Int(filtered)
    }

    private func duration(from asset: AVAsset) async -> Double {
        guard let duration = try? await asset.load(.duration) else {
            return 0
        }

        let seconds = CMTimeGetSeconds(duration)
        guard seconds.isFinite && seconds > 0 else {
            return 0
        }
        return seconds
    }
}
