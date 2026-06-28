import Foundation

public enum ExternalDeviceKind: String, Codable, CaseIterable, Sendable {
    case genericExternalStorage = "generic_external_storage"
    case sdCard = "sd_card"
    case rockboxIPod = "rockbox_ipod"
    case directFilePlayer = "direct_file_player"

    public var title: String {
        switch self {
        case .genericExternalStorage:
            return "External Storage"
        case .sdCard:
            return "SD Card Player"
        case .rockboxIPod:
            return "Rockbox iPod"
        case .directFilePlayer:
            return "Direct File Player"
        }
    }
}

public enum ExternalDeviceTransferMode: String, Codable, CaseIterable, Sendable {
    case copyOriginals = "copy_originals"
    case convertDuringTransfer = "convert_during_transfer"

    public var title: String {
        switch self {
        case .copyOriginals:
            return "Copy Originals"
        case .convertDuringTransfer:
            return "Convert During Transfer"
        }
    }
}

public struct ExternalDeviceTransferSettings: Codable, Hashable, Sendable {
    public var mode: ExternalDeviceTransferMode
    public var outputFormat: OutputFormat
    public var bitrateKbps: Int?
    public var sampleRateHz: Int?
    public var artworkMaxDimension: Int?
    public var deviceProfile: DeviceProfile
    public var folderStructureMode: FolderStructureMode
    public var templateConfig: FolderTemplateConfig

    public init(
        mode: ExternalDeviceTransferMode = .convertDuringTransfer,
        outputFormat: OutputFormat = .aac,
        bitrateKbps: Int? = 192,
        sampleRateHz: Int? = 44_100,
        artworkMaxDimension: Int? = 1024,
        deviceProfile: DeviceProfile = .generic,
        folderStructureMode: FolderStructureMode = .metadataTemplate,
        templateConfig: FolderTemplateConfig = FolderTemplateConfig(
            preset: .artistYearAlbum,
            tokenOrder: TemplatePreset.artistYearAlbum.defaultTokenOrder
        )
    ) {
        self.mode = mode
        self.outputFormat = outputFormat
        self.bitrateKbps = bitrateKbps
        self.sampleRateHz = sampleRateHz
        self.artworkMaxDimension = artworkMaxDimension
        self.deviceProfile = deviceProfile
        self.folderStructureMode = folderStructureMode
        self.templateConfig = templateConfig
    }

    public var conversionPreset: ConversionPreset? {
        guard mode == .convertDuringTransfer else {
            return nil
        }

        let bitrate = outputFormat.isLossless ? nil : bitrateKbps
        return ConversionPreset(
            id: "external_device_\(outputFormat.rawValue)_\(bitrate ?? 0)",
            name: "External Device \(outputFormat.fileExtension.uppercased())",
            outputFormat: outputFormat,
            bitrateKbps: bitrate,
            sampleRateHz: sampleRateHz,
            channels: nil,
            constantBitrate: outputFormat == .mp3 && deviceProfile == .ipodLegacySafe,
            deviceProfile: deviceProfile,
            tagMode: Self.defaultTagMode(for: outputFormat, deviceProfile: deviceProfile),
            artworkMode: artworkMaxDimension == nil ? .preserve : .compatReembed,
            artworkMaxDimension: artworkMaxDimension
        )
    }

    private static func defaultTagMode(for outputFormat: OutputFormat, deviceProfile: DeviceProfile) -> TagMode {
        if deviceProfile == .ipodLegacySafe {
            switch outputFormat {
            case .mp3:
                return .id3v23
            case .aac, .alac:
                return .mp4Atoms
            case .flac, .wav, .aiff, .ogg, .opus:
                return .auto
            }
        }
        return outputFormat == .mp3 ? .id3v23 : .auto
    }
}

public struct ExternalDeviceProfile: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: ExternalDeviceKind
    public var rootBookmark: Data?
    public var rootDisplayPath: String?
    public var musicDirectorySubpath: String
    public var transferSettings: ExternalDeviceTransferSettings
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        kind: ExternalDeviceKind = .genericExternalStorage,
        rootBookmark: Data? = nil,
        rootDisplayPath: String? = nil,
        musicDirectorySubpath: String = "Music",
        transferSettings: ExternalDeviceTransferSettings = ExternalDeviceTransferSettings(),
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.rootBookmark = rootBookmark
        self.rootDisplayPath = rootDisplayPath
        self.musicDirectorySubpath = Self.normalizedSubpath(musicDirectorySubpath)
        self.transferSettings = transferSettings
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public static func genericStorage(
        name: String = "External Storage",
        rootBookmark: Data? = nil,
        rootDisplayPath: String? = nil
    ) -> ExternalDeviceProfile {
        ExternalDeviceProfile(
            name: name,
            kind: .genericExternalStorage,
            rootBookmark: rootBookmark,
            rootDisplayPath: rootDisplayPath,
            musicDirectorySubpath: "Music",
            transferSettings: ExternalDeviceTransferSettings(
                folderStructureMode: .metadataTemplate,
                templateConfig: FolderTemplateConfig(
                    preset: .artistYearAlbum,
                    tokenOrder: TemplatePreset.artistYearAlbum.defaultTokenOrder
                )
            )
        )
    }

    public static func rockboxIPod(
        name: String = "Rockbox iPod",
        rootBookmark: Data? = nil,
        rootDisplayPath: String? = nil
    ) -> ExternalDeviceProfile {
        ExternalDeviceProfile(
            name: name,
            kind: .rockboxIPod,
            rootBookmark: rootBookmark,
            rootDisplayPath: rootDisplayPath,
            musicDirectorySubpath: "Music",
            transferSettings: ExternalDeviceTransferSettings(
                mode: .convertDuringTransfer,
                outputFormat: .mp3,
                bitrateKbps: 192,
                sampleRateHz: 44_100,
                artworkMaxDimension: 600,
                deviceProfile: .generic,
                folderStructureMode: .metadataTemplate,
                templateConfig: FolderTemplateConfig(
                    preset: .custom,
                    tokenOrder: [.albumArtist, .album, .disabled, .disabled, .disabled]
                )
            )
        )
    }

    public static func directFilePlayer(
        name: String = "Direct File Player",
        rootBookmark: Data? = nil,
        rootDisplayPath: String? = nil
    ) -> ExternalDeviceProfile {
        ExternalDeviceProfile(
            name: name,
            kind: .directFilePlayer,
            rootBookmark: rootBookmark,
            rootDisplayPath: rootDisplayPath,
            musicDirectorySubpath: "",
            transferSettings: ExternalDeviceTransferSettings(
                mode: .convertDuringTransfer,
                outputFormat: .mp3,
                bitrateKbps: 192,
                sampleRateHz: 44_100,
                artworkMaxDimension: 300,
                deviceProfile: .generic,
                folderStructureMode: .flat,
                templateConfig: FolderTemplateConfig(
                    preset: .custom,
                    tokenOrder: [.disabled, .disabled, .disabled, .disabled, .disabled]
                )
            )
        )
    }

    public static func normalizedSubpath(_ rawValue: String) -> String {
        rawValue
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { sanitizePathComponent(String($0)) }
            .filter { !$0.isEmpty }
            .joined(separator: "/")
    }

    private static func sanitizePathComponent(_ rawValue: String) -> String {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        value = value.replacingOccurrences(of: ":", with: "-")
        value = value.replacingOccurrences(of: "\\", with: "-")
        value = value.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if value == "." || value == ".." {
            return ""
        }
        return value
    }
}
