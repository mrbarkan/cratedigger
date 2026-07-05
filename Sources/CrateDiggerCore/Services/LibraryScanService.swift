import AVFoundation
import Foundation

public struct LoadedTrack: Hashable, Equatable, Codable, Sendable {
    public let track: AudioTrack
    public let metadata: ConversionMetadata
    /// Record Divider track markers (vinyl-side splitting). `nil`/empty = an
    /// ordinary, undivided track. Optional so pre-feature `.cdlib` crates decode.
    public var recordMarkers: [RecordMarker]?

    public init(track: AudioTrack, metadata: ConversionMetadata, recordMarkers: [RecordMarker]? = nil) {
        self.track = track
        self.metadata = metadata
        self.recordMarkers = recordMarkers
    }

    /// The index of the Record Divider track playing at `seconds` (the last marker
    /// whose start is at or before `seconds`), or `nil` if the track is undivided.
    public func recordTrackIndex(at seconds: Double) -> Int? {
        guard let recordMarkers, !recordMarkers.isEmpty else { return nil }
        var result: Int?
        for (i, marker) in recordMarkers.enumerated() where marker.startSeconds <= seconds + 0.001 {
            result = i
        }
        return result ?? 0
    }
}

public final class LibraryScanService {
    private let fileManager: FileManager
    private let artworkService: ArtworkService
    private let remoteArtworkService: RemoteArtworkService?
    private let metadataProbe: MetadataProbing?
    private let supportedExtensions: Set<String>

    public init(
        fileManager: FileManager = .default,
        artworkService: ArtworkService = ArtworkService(),
        remoteArtworkService: RemoteArtworkService? = nil,
        metadataProbe: MetadataProbing? = nil,
        supportedExtensions: Set<String> = ["mp3", "aac", "m4a", "flac", "wav", "aiff", "ogg", "opus", "caf"]
    ) {
        let resolvedProbe: MetadataProbing?
        if let metadataProbe {
            resolvedProbe = metadataProbe
        } else {
            do {
                resolvedProbe = try MetadataProbeService(fileManager: fileManager)
            } catch {
                AppLog.scan.warning("Falling back to AVFoundation-only metadata; ffprobe unavailable: \(String(describing: error), privacy: .public)")
                resolvedProbe = nil
            }
        }
        self.fileManager = fileManager
        self.artworkService = artworkService
        self.remoteArtworkService = remoteArtworkService
        self.metadataProbe = resolvedProbe
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

        // Fresh scan: folder covers may have changed on disk since the last one.
        artworkService.clearFolderArtworkMemo()

        // Load tracks concurrently — each loadTrack blocks on a synchronous
        // ffprobe spawn plus AVAsset metadata loads, so the old serial loop left
        // every other core idle (15-30 min for a 14k-track library). Sliding
        // window: seed one task per core, refill as each finishes. Completion
        // order doesn't matter; results are sorted below.
        let maxConcurrent = max(1, ProcessInfo.processInfo.activeProcessorCount)
        var loadedTracks: [LoadedTrack] = []
        loadedTracks.reserveCapacity(candidateURLs.count)

        await withTaskGroup(of: LoadedTrack?.self) { group in
            var nextIndex = 0
            while nextIndex < min(maxConcurrent, candidateURLs.count) {
                let fileURL = candidateURLs[nextIndex]
                group.addTask { await self.loadTrack(at: fileURL) }
                nextIndex += 1
            }
            for await loadedTrack in group {
                if let loadedTrack {
                    loadedTracks.append(loadedTrack)
                }
                // Stop dispatching new work when the surrounding task is
                // cancelled; the view model discards partial results anyway.
                if nextIndex < candidateURLs.count, !Task.isCancelled {
                    let fileURL = candidateURLs[nextIndex]
                    group.addTask { await self.loadTrack(at: fileURL) }
                    nextIndex += 1
                }
            }
        }

        return loadedTracks.sorted { lhs, rhs in
            lhs.track.title.localizedCaseInsensitiveCompare(rhs.track.title) == .orderedAscending
        }
    }

    /// Re-read a single file's tags into a fresh `LoadedTrack` (e.g. the
    /// context-menu "Refresh Tags"). The caller is responsible for re-attaching
    /// any app-side state (track id, record markers).
    public func reloadTrack(at fileURL: URL) async -> LoadedTrack? {
        // "Refresh Tags" must re-read the folder cover from disk, not serve a
        // possibly-stale entry from the last scan's memo.
        artworkService.clearFolderArtworkMemo()
        return await loadTrack(at: fileURL)
    }

    private func loadTrack(at fileURL: URL) async -> LoadedTrack? {
        let asset = AVURLAsset(url: fileURL)
        let commonMetadata = (try? await asset.load(.commonMetadata)) ?? []
        let extendedMetadata = await loadExtendedMetadata(from: asset)
        let allMetadata = commonMetadata + extendedMetadata
        let probedMetadata = probeMetadata(for: fileURL)

        let avTitle = coalesce(
            await stringValue(forCommonKeys: ["title"], in: commonMetadata),
            await stringValue(forIdentifierContains: ["title", "tit2"], in: allMetadata)
        ) ?? fileURL.deletingPathExtension().lastPathComponent
        let avArtist = coalesce(
            await stringValue(forCommonKeys: ["artist"], in: commonMetadata),
            await stringValue(
                forIdentifierContains: ["artist", "tpe1"],
                excluding: ["albumartist", "album_artist", "album artist", "tpe2", "aart"],
                in: allMetadata
            )
        ) ?? ""
        let avAlbum = coalesce(
            await stringValue(forCommonKeys: ["albumName"], in: commonMetadata),
            await stringValue(
                forIdentifierContains: ["album", "talb"],
                excluding: ["albumartist", "album_artist", "album artist", "tpe2", "aart"],
                in: allMetadata
            )
        ) ?? ""
        let avAlbumArtist = coalesce(
            await stringValue(forIdentifierContains: ["album_artist", "albumartist", "aart", "tpe2"], in: allMetadata),
            await stringValue(forIdentifierContains: ["album artist"], in: allMetadata)
        )
        let avGenre = coalesce(
            await stringValue(forCommonKeys: ["genre", "type"], in: commonMetadata),
            await stringValue(forIdentifierContains: ["genre", "tcon"], in: allMetadata)
        )
        let avYear = coalesce(
            await yearValue(forIdentifierContains: ["year", "date", "tdrc", "day"], in: allMetadata),
            await yearValue(forCommonKeys: ["creationDate"], in: commonMetadata)
        )

        let parsedTrack = parseIndexAndTotal(from: await stringValue(forIdentifierContains: ["tracknumber", "track_number", "track", "trkn"], in: allMetadata))
        let avTrackNumber = parsedTrack.number
        let avTrackTotal = coalesce(
            parsedTrack.total,
            await intValue(forIdentifierContains: ["tracktotal", "totaltracks"], in: allMetadata)
        )

        let parsedDisc = parseIndexAndTotal(from: await stringValue(forIdentifierContains: ["discnumber", "disc_number", "disk", "disc", "tpos"], in: allMetadata))
        let avDiscNumber = parsedDisc.number
        let avDiscTotal = coalesce(
            parsedDisc.total,
            await intValue(forIdentifierContains: ["disctotal", "totaldiscs"], in: allMetadata)
        )

        let avComment = coalesce(
            await stringValue(forIdentifierContains: ["comment", "comm"], in: allMetadata),
            await stringValue(forCommonKeys: ["description"], in: commonMetadata)
        )
        let avCompilation = await boolValue(forIdentifierContains: ["compilation", "cpil", "tcmp"], in: allMetadata)

        let durationSeconds = await duration(from: asset)
        // Pass the metadata this function already loaded so ArtworkService
        // doesn't build and re-load a second AVURLAsset for the same file.
        var artwork = await artworkService.resolveArtwork(trackURL: fileURL, preloadedMetadata: allMetadata)
        if artwork == nil, let remoteArtworkService {
            if let cached = await remoteArtworkService.cachedArtwork(artist: avArtist, album: avAlbum) {
                artworkService.ingest(cached)
                artwork = cached
            }
        }

        let avMetadata = ConversionMetadata(
            title: avTitle,
            artist: avArtist,
            albumArtist: avAlbumArtist,
            album: avAlbum,
            compilation: avCompilation,
            trackNumber: avTrackNumber,
            trackTotal: avTrackTotal,
            discNumber: avDiscNumber,
            discTotal: avDiscTotal,
            year: avYear,
            genre: avGenre,
            comment: avComment,
            artwork: artwork
        )

        // Prefer ffprobe's tags (with AVFoundation as fallback) whenever the
        // probe is available. ffprobe runs for every file regardless, so this
        // costs nothing extra, and it is the only path that reads FLAC/OGG
        // Vorbis comments — AVFoundation can't, which is why track/disc numbers
        // came back nil for those files.
        let metadata: ConversionMetadata
        if let probedMetadata {
            metadata = MetadataNormalization.normalize(
                formatTags: probedMetadata.formatTags,
                fallback: avMetadata,
                artwork: artwork
            )
        } else {
            metadata = avMetadata
        }

        let trackTitle = normalizedString(metadata.title) ?? fileURL.deletingPathExtension().lastPathComponent
        let trackArtist = normalizedString(metadata.artist) ?? ""
        let trackAlbum = normalizedString(metadata.album) ?? ""
        let inferredFormatName = normalizedString(probedMetadata?.primaryAudioStream?.codecName)?.uppercased()
            ?? normalizedString(probedMetadata?.formatName)?
                .split(separator: ",")
                .first
                .map(String.init)?
                .uppercased()
            ?? fileURL.pathExtension.uppercased()
        let inferredBitRateKbps = preferredBitRateKbps(from: probedMetadata)
        let inferredSampleRateHz = preferredSampleRate(from: probedMetadata)

        let track = AudioTrack(
            fileURL: fileURL,
            title: trackTitle,
            artist: trackArtist,
            album: trackAlbum,
            durationSeconds: durationSeconds,
            formatName: inferredFormatName,
            bitrateKbps: inferredBitRateKbps,
            sampleRateHz: inferredSampleRateHz,
            year: metadata.year,
            trackNumber: metadata.trackNumber,
            trackTotal: metadata.trackTotal,
            discNumber: metadata.discNumber,
            discTotal: metadata.discTotal,
            artworkSource: artwork?.source ?? .none,
            artworkHash: artwork?.hash,
            artworkDimensions: artwork?.dimensions
        )

        return LoadedTrack(track: track, metadata: metadata)
    }

    private func probeMetadata(for fileURL: URL) -> ProbedMetadata? {
        guard let metadataProbe else {
            return nil
        }
        return try? metadataProbe.probe(url: fileURL)
    }

    private func loadExtendedMetadata(from asset: AVAsset) async -> [AVMetadataItem] {
        var metadataItems: [AVMetadataItem] = []
        let metadataFormats = (try? await asset.load(.availableMetadataFormats)) ?? []

        for format in metadataFormats {
            guard let loadedMetadata = try? await asset.loadMetadata(for: format) else {
                continue
            }
            metadataItems.append(contentsOf: loadedMetadata)
        }

        return metadataItems
    }

    private func stringValue(forCommonKeys keys: [String], in metadataItems: [AVMetadataItem]) async -> String? {
        let normalizedKeys = Set(keys.map { $0.lowercased() })
        for item in metadataItems {
            guard let commonKey = item.commonKey?.rawValue.lowercased(),
                  normalizedKeys.contains(commonKey),
                  let value = await metadataStringValue(for: item),
                  !value.isEmpty
            else {
                continue
            }
            return value
        }

        return nil
    }

    private func stringValue(
        forIdentifierContains keys: [String],
        excluding excludedKeys: [String] = [],
        in metadataItems: [AVMetadataItem]
    ) async -> String? {
        let normalizedKeys = keys.map { $0.lowercased() }
        let normalizedExcludedKeys = excludedKeys.map { $0.lowercased() }
        for item in metadataItems {
            guard let identifier = item.identifier?.rawValue.lowercased(),
                  normalizedKeys.contains(where: { identifier.contains($0) }),
                  !normalizedExcludedKeys.contains(where: { identifier.contains($0) }),
                  let value = await metadataStringValue(for: item),
                  !value.isEmpty
            else {
                continue
            }
            return value
        }

        return nil
    }

    private func metadataStringValue(for item: AVMetadataItem) async -> String? {
        if let value = try? await item.load(.stringValue) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }

        do {
            let loadedValue = try await item.load(.value)
            switch loadedValue {
            case let string as String:
                let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            case let number as NSNumber:
                return number.stringValue
            case let data as Data:
                if let decoded = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                   !decoded.isEmpty {
                    return decoded
                }
            default:
                return nil
            }

            return nil
        } catch {
            return nil
        }
    }

    private func intValue(forIdentifierContains keys: [String], in metadataItems: [AVMetadataItem]) async -> Int? {
        guard let value = await stringValue(forIdentifierContains: keys, in: metadataItems) else {
            return nil
        }

        return intValue(from: value)
    }

    private func yearValue(forIdentifierContains keys: [String], in metadataItems: [AVMetadataItem]) async -> Int? {
        guard let value = await stringValue(forIdentifierContains: keys, in: metadataItems) else {
            return nil
        }

        return yearValue(from: value)
    }

    private func yearValue(forCommonKeys keys: [String], in metadataItems: [AVMetadataItem]) async -> Int? {
        guard let value = await stringValue(forCommonKeys: keys, in: metadataItems) else {
            return nil
        }

        return yearValue(from: value)
    }

    private func intValue(from rawValue: String) -> Int? {
        let firstNumericRun = rawValue.split(whereSeparator: { !$0.isNumber }).first
        return firstNumericRun.flatMap { Int($0) }
    }

    private func yearValue(from rawValue: String) -> Int? {
        for numericRun in rawValue.split(whereSeparator: { !$0.isNumber }) {
            guard numericRun.count == 4, let year = Int(numericRun), (1000...2999).contains(year) else {
                continue
            }
            return year
        }

        if let numeric = intValue(from: rawValue), (1000...2999).contains(numeric) {
            return numeric
        }
        return nil
    }

    private func boolValue(forIdentifierContains keys: [String], in metadataItems: [AVMetadataItem]) async -> Bool? {
        guard let value = await stringValue(forIdentifierContains: keys, in: metadataItems)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              !value.isEmpty
        else {
            return nil
        }

        switch value {
        case "1", "true", "yes", "y":
            return true
        case "0", "false", "no", "n":
            return false
        default:
            if let numeric = Int(value) {
                return numeric != 0
            }
            return nil
        }
    }

    private func coalesce(_ values: String?...) -> String? {
        for value in values {
            guard let value else { continue }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }

    // ponytail: keeps both async values eagerly evaluated; `a ?? (await b)` won't
    // compile because `??`'s RHS autoclosure can't be async.
    private func coalesce(_ values: Int?...) -> Int? {
        for value in values {
            if let value {
                return value
            }
        }
        return nil
    }

    private func parseIndexAndTotal(from rawValue: String?) -> (number: Int?, total: Int?) {
        guard let rawValue else {
            return (nil, nil)
        }

        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return (nil, nil)
        }

        if trimmed.contains("/") {
            let components = trimmed.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
            let number = components.first.flatMap { intValue(from: String($0)) }
            let total = components.count > 1 ? intValue(from: String(components[1])) : nil
            return (number, total)
        }

        return (intValue(from: trimmed), nil)
    }

    private func preferredBitRateKbps(from metadata: ProbedMetadata?) -> Int? {
        guard let metadata else {
            return nil
        }

        let sourceBitRate = metadata.primaryAudioStream?.bitRateBps ?? metadata.formatBitRateBps
        guard let bitRateBps = sourceBitRate, bitRateBps > 0 else {
            return nil
        }
        return max(1, Int((Double(bitRateBps) / 1000).rounded()))
    }

    private func preferredSampleRate(from metadata: ProbedMetadata?) -> Int? {
        guard let sample = metadata?.primaryAudioStream?.sampleRateHz, sample > 0 else {
            return nil
        }
        return sample
    }

    private func normalizedString(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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
