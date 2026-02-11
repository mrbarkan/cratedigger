import Foundation

public enum DeviceProfile: String, Codable, CaseIterable, Sendable {
    case generic
    case ipodLegacySafe = "ipod_legacy_safe"
}

public enum TagMode: String, Codable, CaseIterable, Sendable {
    case auto
    case id3v23
    case mp4Atoms = "mp4_atoms"
}

public enum ArtworkMode: String, Codable, CaseIterable, Sendable {
    case preserve
    case compatReembed = "compat_reembed"
    case none
}

public enum OutputFormat: String, Codable, CaseIterable, Sendable {
    case mp3
    case aac
    case alac
    case flac
    case wav
    case aiff
    case ogg
    case opus

    public var fileExtension: String {
        switch self {
        case .aac:
            return "m4a"
        default:
            return rawValue
        }
    }
}

public struct ConversionPreset: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let outputFormat: OutputFormat
    public let bitrateKbps: Int?
    public let sampleRateHz: Int?
    public let channels: Int?
    public let constantBitrate: Bool
    public let deviceProfile: DeviceProfile
    public let tagMode: TagMode
    public let artworkMode: ArtworkMode

    public init(
        id: String,
        name: String,
        outputFormat: OutputFormat,
        bitrateKbps: Int?,
        sampleRateHz: Int?,
        channels: Int?,
        constantBitrate: Bool = false,
        deviceProfile: DeviceProfile = .generic,
        tagMode: TagMode = .auto,
        artworkMode: ArtworkMode = .compatReembed
    ) {
        self.id = id
        self.name = name
        self.outputFormat = outputFormat
        self.bitrateKbps = bitrateKbps
        self.sampleRateHz = sampleRateHz
        self.channels = channels
        self.constantBitrate = constantBitrate
        self.deviceProfile = deviceProfile
        self.tagMode = tagMode
        self.artworkMode = artworkMode
    }

    public var outputExtension: String {
        outputFormat.fileExtension
    }

    public static let genericAAC = ConversionPreset(
        id: "generic_aac_256",
        name: "AAC 256",
        outputFormat: .aac,
        bitrateKbps: 256,
        sampleRateHz: nil,
        channels: nil,
        deviceProfile: .generic,
        tagMode: .auto,
        artworkMode: .compatReembed
    )

    public static let genericFLAC = ConversionPreset(
        id: "generic_flac",
        name: "FLAC",
        outputFormat: .flac,
        bitrateKbps: nil,
        sampleRateHz: nil,
        channels: nil,
        deviceProfile: .generic,
        tagMode: .auto,
        artworkMode: .compatReembed
    )

    public static func ipodAAC(bitrate: Int = 192) -> ConversionPreset {
        ConversionPreset(
            id: "ipod_aac_\(bitrate)",
            name: "iPod AAC \(bitrate)",
            outputFormat: .aac,
            bitrateKbps: bitrate,
            sampleRateHz: 44_100,
            channels: 2,
            constantBitrate: false,
            deviceProfile: .ipodLegacySafe,
            tagMode: .mp4Atoms,
            artworkMode: .compatReembed
        )
    }

    public static func ipodMP3(bitrate: Int = 192) -> ConversionPreset {
        ConversionPreset(
            id: "ipod_mp3_\(bitrate)",
            name: "iPod MP3 \(bitrate) CBR",
            outputFormat: .mp3,
            bitrateKbps: bitrate,
            sampleRateHz: 44_100,
            channels: 2,
            constantBitrate: true,
            deviceProfile: .ipodLegacySafe,
            tagMode: .id3v23,
            artworkMode: .compatReembed
        )
    }

    public static let defaultPresets: [ConversionPreset] = {
        var presets: [ConversionPreset] = [genericAAC, genericFLAC]
        for rate in [128, 160, 192, 256, 320] {
            presets.append(ipodAAC(bitrate: rate))
            presets.append(ipodMP3(bitrate: rate))
        }
        return presets
    }()

    public static func preset(withID id: String, overrideDeviceProfile: DeviceProfile? = nil) -> ConversionPreset? {
        guard var preset = defaultPresets.first(where: { $0.id == id }) else {
            return nil
        }

        if let overrideDeviceProfile {
            preset = ConversionPreset(
                id: preset.id,
                name: preset.name,
                outputFormat: preset.outputFormat,
                bitrateKbps: preset.bitrateKbps,
                sampleRateHz: preset.sampleRateHz,
                channels: preset.channels,
                constantBitrate: preset.constantBitrate,
                deviceProfile: overrideDeviceProfile,
                tagMode: preset.tagMode,
                artworkMode: preset.artworkMode
            )
        }

        return preset
    }
}

public struct ConversionMetadata: Hashable, Sendable {
    public var title: String?
    public var artist: String?
    public var album: String?
    public var trackNumber: Int?
    public var discNumber: Int?
    public var year: Int?
    public var genre: String?
    public var comment: String?
    public var artwork: ArtworkAsset?

    public init(
        title: String? = nil,
        artist: String? = nil,
        album: String? = nil,
        trackNumber: Int? = nil,
        discNumber: Int? = nil,
        year: Int? = nil,
        genre: String? = nil,
        comment: String? = nil,
        artwork: ArtworkAsset? = nil
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.year = year
        self.genre = genre
        self.comment = comment
        self.artwork = artwork
    }
}

public struct ConversionJob: Hashable, Sendable {
    public let sourceURL: URL
    public let destinationURL: URL
    public let metadata: ConversionMetadata?

    public init(sourceURL: URL, destinationURL: URL, metadata: ConversionMetadata? = nil) {
        self.sourceURL = sourceURL
        self.destinationURL = destinationURL
        self.metadata = metadata
    }
}

public enum QueueStatus: String, Sendable {
    case queued
    case running
    case completed
    case failed
}

public struct QueuedConversion: Identifiable, Sendable {
    public let id: UUID
    public let job: ConversionJob
    public let preset: ConversionPreset
    public var status: QueueStatus

    public init(id: UUID = UUID(), job: ConversionJob, preset: ConversionPreset, status: QueueStatus = .queued) {
        self.id = id
        self.job = job
        self.preset = preset
        self.status = status
    }
}

public struct ConversionExecutionResult: Sendable {
    public let queuedID: UUID
    public let status: QueueStatus
    public let warning: String?
    public let log: String

    public init(queuedID: UUID, status: QueueStatus, warning: String?, log: String) {
        self.queuedID = queuedID
        self.status = status
        self.warning = warning
        self.log = log
    }
}
