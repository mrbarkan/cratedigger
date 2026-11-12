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
    /// What happens to the art inside the files a convert-mode transfer writes:
    /// Keep (`.preserve`), Re-embed (`.compatReembed`, resized to
    /// `artworkMaxDimension`) or Strip (`.none`). Copy mode copies files as
    /// they are and ignores it.
    public var artworkMode: ArtworkMode
    /// Write a `cover.jpg` beside the tracks in each album folder the transfer
    /// writes into, whatever `artworkMode` does inside the files. See
    /// `ExternalDeviceProfile.usesFolderCoverArt`.
    public var writesFolderCoverArt: Bool
    public var deviceProfile: DeviceProfile
    public var folderStructureMode: FolderStructureMode
    public var templateConfig: FolderTemplateConfig

    /// `artworkMode` is not optional on purpose: `artworkMode: .none` against
    /// an optional would read as nil, not Strip. Its default, Re-embed, is
    /// what the default 1024 px cap always meant.
    public init(
        mode: ExternalDeviceTransferMode = .convertDuringTransfer,
        outputFormat: OutputFormat = .aac,
        bitrateKbps: Int? = 192,
        sampleRateHz: Int? = 44_100,
        artworkMaxDimension: Int? = 1024,
        artworkMode: ArtworkMode = .compatReembed,
        writesFolderCoverArt: Bool = false,
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
        self.artworkMode = artworkMode
        self.writesFolderCoverArt = writesFolderCoverArt
        self.deviceProfile = deviceProfile
        self.folderStructureMode = folderStructureMode
        self.templateConfig = templateConfig
    }

    enum CodingKeys: String, CodingKey {
        case mode, outputFormat, bitrateKbps, sampleRateHz, artworkMaxDimension
        case artworkMode, writesFolderCoverArt
        case deviceProfile, folderStructureMode, templateConfig
    }

    /// Settings saved before `artworkMode` and `writesFolderCoverArt` existed
    /// decode to what such a device did then, as far as the settings alone
    /// can tell: the mode follows the cap, and no cover is written. The device
    /// kind also mattered (a Rockbox iPod stripped the files and wrote a
    /// cover), and only the profile knows it: `ExternalDeviceProfile.init(from:)`
    /// finishes the job.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = try container.decode(ExternalDeviceTransferMode.self, forKey: .mode)
        outputFormat = try container.decode(OutputFormat.self, forKey: .outputFormat)
        bitrateKbps = try container.decodeIfPresent(Int.self, forKey: .bitrateKbps)
        sampleRateHz = try container.decodeIfPresent(Int.self, forKey: .sampleRateHz)
        artworkMaxDimension = try container.decodeIfPresent(Int.self, forKey: .artworkMaxDimension)
        artworkMode = try container.decodeIfPresent(ArtworkMode.self, forKey: .artworkMode)
            ?? Self.artworkMode(forCap: artworkMaxDimension)
        writesFolderCoverArt = try container.decodeIfPresent(Bool.self, forKey: .writesFolderCoverArt) ?? false
        deviceProfile = try container.decode(DeviceProfile.self, forKey: .deviceProfile)
        folderStructureMode = try container.decode(FolderStructureMode.self, forKey: .folderStructureMode)
        templateConfig = try container.decode(FolderTemplateConfig.self, forKey: .templateConfig)
    }

    /// The embedded-art mode a device had before the mode was stored: the cap
    /// was the switch.
    private static func artworkMode(forCap cap: Int?) -> ArtworkMode {
        cap == nil ? .preserve : .compatReembed
    }

    /// One-line human summary of what a transfer does to the files —
    /// "AAC 192 kbps", "FLAC (lossless)", "Copy originals (no conversion)".
    /// Shown wherever a queue/stage decision is confirmed, so the user sees
    /// which settings got baked in.
    public var summary: String {
        guard mode == .convertDuringTransfer else { return "Copy originals (no conversion)" }
        let name = outputFormat.fileExtension.uppercased()
        if outputFormat.isLossless { return "\(name) (lossless)" }
        guard let kbps = bitrateKbps else { return name }
        return "\(name) \(kbps) kbps"
    }

    /// The preset a convert-mode transfer writes with, nil in copy mode. Art
    /// inside the files follows `artworkMode`; a folder cover is written
    /// beside them separately and never changes the preset.
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
            artworkMode: artworkMode,
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
    /// The mounted volume's filesystem UUID (`URLResourceKey.volumeUUIDStringKey`),
    /// captured when the profile is added. This is what tells two otherwise-identical
    /// devices apart: every Rockbox iPod mounts at `/Volumes/IPOD` named "IPOD", so
    /// path/name matching alone recognizes *any* iPod as this one. Optional so profiles
    /// saved before this existed — and volumes that report no UUID — decode to `nil`
    /// and fall back to path/name matching. See `match(_:in:)`.
    public var volumeUUID: String?
    public var musicDirectorySubpath: String
    /// Chosen device-icon identifier (e.g. "classic.black") from the iPod icon
    /// catalog. Optional so decoding older saved profiles (which have no such
    /// key) yields `nil` rather than throwing — no data-loss migration needed.
    public var iconID: String?
    public var transferSettings: ExternalDeviceTransferSettings
    public var createdAt: Date
    public var updatedAt: Date
    /// PodBox settings for this device. nil (every profile saved before they
    /// existed, and every new one until something is changed) means the defaults.
    public var podBox: PodBoxPreferences?

    /// The PodBox settings in force: the stored ones, else the defaults.
    public var podBoxPreferences: PodBoxPreferences { podBox ?? PodBoxPreferences() }

    enum CodingKeys: String, CodingKey {
        case id, name, kind, rootBookmark, rootDisplayPath, volumeUUID
        case musicDirectorySubpath, iconID, transferSettings, createdAt, updatedAt, podBox
    }

    /// Decodes like the synthesised conformance, plus one migration only the
    /// profile can do: a Rockbox iPod saved before its art settings were
    /// stored stripped the files and wrote a `cover.jpg`, because that was
    /// tied to the kind. Settings that carry the keys keep what they say.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        kind = try container.decode(ExternalDeviceKind.self, forKey: .kind)
        rootBookmark = try container.decodeIfPresent(Data.self, forKey: .rootBookmark)
        rootDisplayPath = try container.decodeIfPresent(String.self, forKey: .rootDisplayPath)
        volumeUUID = try container.decodeIfPresent(String.self, forKey: .volumeUUID)
        musicDirectorySubpath = try container.decode(String.self, forKey: .musicDirectorySubpath)
        iconID = try container.decodeIfPresent(String.self, forKey: .iconID)
        transferSettings = try container.decode(ExternalDeviceTransferSettings.self, forKey: .transferSettings)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        // Lenient: a value this build cannot read (one written by a newer
        // build) leaves the defaults rather than failing the whole profile,
        // which would make every saved profile read as gone.
        podBox = (try? container.decodeIfPresent(PodBoxPreferences.self, forKey: .podBox)) ?? nil

        if kind == .rockboxIPod {
            let stored = try container.nestedContainer(
                keyedBy: ExternalDeviceTransferSettings.CodingKeys.self,
                forKey: .transferSettings
            )
            if !stored.contains(.artworkMode) { transferSettings.artworkMode = .none }
            if !stored.contains(.writesFolderCoverArt) { transferSettings.writesFolderCoverArt = true }
        }
    }

    public init(
        id: UUID = UUID(),
        name: String,
        kind: ExternalDeviceKind = .genericExternalStorage,
        rootBookmark: Data? = nil,
        rootDisplayPath: String? = nil,
        volumeUUID: String? = nil,
        musicDirectorySubpath: String = "Music",
        iconID: String? = nil,
        transferSettings: ExternalDeviceTransferSettings = ExternalDeviceTransferSettings(),
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        podBox: PodBoxPreferences? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.rootBookmark = rootBookmark
        self.rootDisplayPath = rootDisplayPath
        self.volumeUUID = volumeUUID
        self.musicDirectorySubpath = Self.normalizedSubpath(musicDirectorySubpath)
        self.iconID = iconID
        self.transferSettings = transferSettings
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.podBox = podBox
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
                // Rockbox greys out a large embedded cover once it scales it
                // down, so the art travels as a small cover.jpg instead.
                artworkMode: .none,
                writesFolderCoverArt: true,
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

    /// Ship the cover as a `cover.jpg` beside the tracks, in every album folder
    /// a transfer writes into.
    ///
    /// Rockbox reads folder art first and renders a large *embedded* cover in
    /// greyscale once its decoder has to scale the image down to the theme's art
    /// size — a 500 px cover on a 146 px theme comes out grey. A small sidecar
    /// avoids both problems, and every other player that reads folder art picks
    /// it up too. A per-device switch (`writesFolderCoverArt`), independent of
    /// what `artworkMode` does inside the files; Rockbox profiles start with it
    /// on and the files stripped.
    public var usesFolderCoverArt: Bool { transferSettings.writesFolderCoverArt }

    /// The saved profile a mounted `device` belongs to, or nil for an unknown
    /// volume. A stored `volumeUUID` is authoritative when both the profile and the
    /// device report one — so two iPods that both mount at `/Volumes/IPOD` with the
    /// same volume name are told apart, and a profile bound to iPod A never matches
    /// iPod B. Profiles saved before UUIDs were captured (or volumes that report
    /// none) fall back to the mount path, then the volume name.
    public static func match(_ device: MountedDevice, in profiles: [ExternalDeviceProfile]) -> ExternalDeviceProfile? {
        profiles.first { profile in
            if let profileUUID = profile.volumeUUID, let deviceUUID = device.volumeUUID {
                return profileUUID == deviceUUID
            }
            return (profile.rootDisplayPath.map { $0 == device.volumeURL.path } ?? false)
                || profile.name.caseInsensitiveCompare(device.name) == .orderedSame
        }
    }

    /// The music directory a device profile points at, relative to the volume
    /// root. Shares `PathComponentSanitizer`'s rule with the conversion output
    /// path rather than carrying its own copy: two implementations of "clean a
    /// path component" is exactly how the album-folder review sheet ended up
    /// without the traversal guard this one had.
    ///
    /// One behaviour change comes with that: a component starting with "." now
    /// loses the dot instead of keeping it, so a destination can no longer be a
    /// folder invisible in Finder.
    public static func normalizedSubpath(_ rawValue: String) -> String {
        PathComponentSanitizer.sanitizeSubpath(rawValue, fallback: "")
    }
}
