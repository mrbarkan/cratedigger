import Foundation

/// Persists a scanned device's track catalog to disk so re-selecting a device —
/// even across app launches — doesn't re-walk it. One JSON file per device under
/// Application Support. RESCAN refreshes it whole; a transfer `patch`es in what
/// it wrote and removed, so the catalog stays a last-known picture of the
/// device even while it is unplugged. Artwork bytes are omitted by
/// `ArtworkAsset`'s Codable, so these stay small.
public struct DeviceCatalogStore {
    private let directory: URL
    private let fileManager: FileManager

    public init(directory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        if let directory {
            self.directory = directory
        } else {
            let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            self.directory = base.appendingPathComponent("CrateDigger/DeviceCatalogs", isDirectory: true)
        }
    }

    public func load(key: String) -> [LoadedTrack]? {
        guard let data = try? Data(contentsOf: url(for: key)) else { return nil }
        return try? JSONDecoder().decode([LoadedTrack].self, from: data)
    }

    public func save(_ tracks: [LoadedTrack], key: String) {
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(tracks) else { return }
        try? data.write(to: url(for: key), options: .atomic)
    }

    public func remove(key: String) {
        try? fileManager.removeItem(at: url(for: key))
    }

    /// Bring a saved catalog up to date after a write: drop the records at
    /// `removingPaths`, then add `adding`, each replacing any record already
    /// at its path (an overwrite in place). Paths compare case-insensitively,
    /// as a FAT or exFAT device does. Without a saved catalog this does
    /// nothing: there is no picture to correct, and the next browse scans the
    /// whole device.
    public func patch(key: String, adding: [LoadedTrack], removingPaths: Set<String>) {
        guard let catalog = load(key: key) else { return }
        save(Self.patched(catalog, adding: adding, removingPaths: removingPaths), key: key)
    }

    /// `patch` on a catalog in memory, for a caller that also keeps the
    /// patched result (the browser's index of the device).
    public static func patched(
        _ catalog: [LoadedTrack],
        adding: [LoadedTrack],
        removingPaths: Set<String>
    ) -> [LoadedTrack] {
        let gone = Set(removingPaths.map { pathKey(URL(fileURLWithPath: $0)) })
            .union(adding.map { pathKey($0.track.fileURL) })
        let kept = catalog.filter { !gone.contains(pathKey($0.track.fileURL)) }
        return kept + adding
    }

    /// A catalog record for a file this app just wrote: the source's tags, the
    /// destination URL, and the output format/bitrate/sample rate when
    /// converted (`preset` non-nil), named the way a scan of the file names
    /// them. The art is what a scan would read back (`DeviceWrittenArt`):
    /// embedded art as the preset leaves it, else the folder cover when
    /// `writesFolderCoverArt`. Gets a fresh id: a device record is not the
    /// library track it came from.
    public static func writtenTrack(
        source: LoadedTrack,
        destination: URL,
        preset: ConversionPreset?,
        writesFolderCoverArt: Bool = false
    ) -> LoadedTrack {
        let original = source.track
        let art = DeviceWrittenArt.readBack(
            of: [source],
            artworkMode: preset?.artworkMode,
            cap: preset?.artworkMaxDimension,
            deviceProfile: preset?.deviceProfile ?? .generic,
            writesFolderCoverArt: writesFolderCoverArt
        )

        var formatName = original.formatName
        var bitrateKbps = original.bitrateKbps
        var sampleRateHz = original.sampleRateHz
        if let preset {
            let format = preset.outputFormat
            formatName = scannedFormatName(format, bitDepth: preset.bitDepth)
            bitrateKbps = format.isLossless ? nil : preset.bitrateKbps
            // libopus only writes 48 kHz, and the encoder is never asked for another rate.
            sampleRateHz = format == .opus ? 48_000 : (preset.sampleRateHz ?? original.sampleRateHz)
        }

        let audio = AudioTrack(
            fileURL: destination,
            title: original.title,
            artist: original.artist,
            album: original.album,
            durationSeconds: original.durationSeconds,
            formatName: formatName,
            bitrateKbps: bitrateKbps,
            sampleRateHz: sampleRateHz,
            year: original.year,
            trackNumber: original.trackNumber,
            trackTotal: original.trackTotal,
            discNumber: original.discNumber,
            discTotal: original.discTotal,
            artworkSource: art?.source ?? .none,
            artworkHash: art == nil ? nil : original.artworkHash,
            artworkDimensions: art.flatMap { scaled(original.artworkDimensions, toLongestSide: $0.side) }
        )
        var metadata = source.metadata
        if art == nil { metadata.artwork = nil }
        return LoadedTrack(track: audio, metadata: metadata)
    }

    /// What a device scan calls a file of this format: ffprobe's codec name,
    /// uppercased (`LibraryScanService`).
    private static func scannedFormatName(_ format: OutputFormat, bitDepth: Int?) -> String {
        switch format {
        case .mp3: return "MP3"
        case .aac: return "AAC"
        case .alac: return "ALAC"
        case .flac: return "FLAC"
        case .wav: return bitDepth == 24 ? "PCM_S24LE" : "PCM_S16LE"
        case .aiff: return bitDepth == 24 ? "PCM_S24BE" : "PCM_S16BE"
        case .ogg: return "VORBIS"
        case .opus: return "OPUS"
        }
    }

    /// `dimensions` shrunk, keeping its shape, so the longest side is `side`.
    private static func scaled(_ dimensions: ArtworkDimensions?, toLongestSide side: Int) -> ArtworkDimensions? {
        guard let dimensions else { return nil }
        let longest = max(dimensions.width, dimensions.height)
        guard longest > side, longest > 0 else { return dimensions }
        let scale = Double(side) / Double(longest)
        return ArtworkDimensions(
            width: max(1, Int((Double(dimensions.width) * scale).rounded())),
            height: max(1, Int((Double(dimensions.height) * scale).rounded()))
        )
    }

    private static func pathKey(_ url: URL) -> String {
        url.standardizedFileURL.path.lowercased()
    }

    private func url(for key: String) -> URL {
        directory.appendingPathComponent(sanitized(key)).appendingPathExtension("cdtracks")
    }

    private func sanitized(_ key: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let cleaned = String(key.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        return cleaned.isEmpty ? "device" : cleaned
    }
}
