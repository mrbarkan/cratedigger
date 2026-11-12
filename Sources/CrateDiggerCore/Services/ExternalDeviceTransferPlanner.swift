import Foundation

public enum ExternalDeviceTransferAction: String, Sendable {
    case copyOriginal
    case convert
}

public struct PlannedExternalDeviceTransfer: Hashable, Sendable {
    public let sourceURL: URL
    public let destinationURL: URL
    public let relativeSubpath: String?
    public let action: ExternalDeviceTransferAction
    public let conversionPreset: ConversionPreset?
    public let metadata: ConversionMetadata?

    public init(
        sourceURL: URL,
        destinationURL: URL,
        relativeSubpath: String?,
        action: ExternalDeviceTransferAction,
        conversionPreset: ConversionPreset?,
        metadata: ConversionMetadata?
    ) {
        self.sourceURL = sourceURL
        self.destinationURL = destinationURL
        self.relativeSubpath = relativeSubpath
        self.action = action
        self.conversionPreset = conversionPreset
        self.metadata = metadata
    }

    public var conversionJob: ConversionJob? {
        guard action == .convert else {
            return nil
        }
        return ConversionJob(
            sourceURL: sourceURL,
            destinationURL: destinationURL,
            metadata: metadata
        )
    }
}

public struct ExternalDeviceTransferPlanner {
    private let pathPlanner: OutputPathPlanner
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.pathPlanner = OutputPathPlanner(fileManager: fileManager)
        self.fileManager = fileManager
    }

    public func destinationRoot(for profile: ExternalDeviceProfile, mountedAt mountedRoot: URL) -> URL {
        var destination = mountedRoot
        let subpath = ExternalDeviceProfile.normalizedSubpath(profile.musicDirectorySubpath)
        for component in subpath.split(separator: "/").map(String.init) where !component.isEmpty {
            destination.appendPathComponent(component, isDirectory: true)
        }
        return destination
    }

    /// `naturalNames`: every track gets its natural path, even when a file on
    /// disk or another track of the batch already has it, and
    /// `reservedDestinationPaths` is ignored. The device review
    /// (`DeviceTransferResolver`) plans this way so it can see those clashes and
    /// ask about them, never step past them with a silent ` (2)`.
    public func planTransfers(
        tracks: [LoadedTrack],
        profile: ExternalDeviceProfile,
        mountedAt mountedRoot: URL,
        reviewedAlbumFolders: [AlbumFolderKey: String] = [:],
        reservedDestinationPaths: Set<String> = [],
        naturalNames: Bool = false
    ) -> [PlannedExternalDeviceTransfer] {
        let destinationRoot = destinationRoot(for: profile, mountedAt: mountedRoot)
        let preset = profile.transferSettings.conversionPreset
        let planningPreset = preset ?? ConversionPreset.genericAAC
        let action: ExternalDeviceTransferAction = preset == nil ? .copyOriginal : .convert
        let sourceRoot = commonAncestorDirectory(for: tracks.map { $0.track.fileURL })

        // One album, one folder on the device: reconciled across the batch so a
        // soundtrack doesn't arrive as a folder per performer.
        let albumKeys = pathPlanner.albumFolderKeys(for: tracks)

        var reserved = reservedDestinationPaths
        var plannedTransfers: [PlannedExternalDeviceTransfer] = []
        plannedTransfers.reserveCapacity(tracks.count)
        /// Device-safe path key -> the raw planned path that produced it.
        var producedBy: [String: String] = [:]
        func key(_ url: URL) -> String {
            url.standardizedFileURL.path.precomposedStringWithCanonicalMapping.lowercased()
        }

        for track in tracks {
            let destinationExtension = preset?.outputExtension ?? track.track.fileURL.pathExtension
            // Natural names first; collisions are avoided below, after the
            // names are made device-safe, so two names that become the same
            // ("What?" and "What") still end up apart.
            let plannedPath = pathPlanner.planDestination(
                for: track,
                preset: planningPreset,
                destinationRoot: destinationRoot,
                sourceRoot: sourceRoot,
                folderMode: profile.transferSettings.folderStructureMode,
                templateConfig: profile.transferSettings.templateConfig,
                reviewedAlbumFolders: reviewedAlbumFolders,
                reservedDestinationPaths: [],
                destinationFileExtension: destinationExtension,
                avoidExistingFiles: false,
                albumKey: albumKeys[track.track.id]
            )
            // Names a device can hold and the write policy passes, before
            // anything compares or reserves them.
            let raw = key(plannedPath.destinationURL)
            let safe = Self.deviceSafeURL(plannedPath.destinationURL, under: destinationRoot)
            var destinationURL = safe
            var attempt = 1
            while true {
                let candidate = key(destinationURL)
                let clashesInBatch = producedBy[candidate].map { naturalNames ? $0 != raw : true } ?? false
                let takenOnDisk = !naturalNames
                    && (reserved.contains(destinationURL.standardizedFileURL.resolvingSymlinksInPath().path)
                        || fileManager.fileExists(atPath: destinationURL.path))
                // Natural names keep a genuine clash (the same name twice) for
                // the review to ask about; only a clash the sanitising made is
                // stepped past here.
                guard clashesInBatch || takenOnDisk else { break }
                attempt += 1
                destinationURL = Self.suffixed(safe, attempt: attempt)
            }
            producedBy[key(destinationURL)] = raw
            if !naturalNames {
                reserved.insert(destinationURL.standardizedFileURL.resolvingSymlinksInPath().path)
            }

            plannedTransfers.append(
                PlannedExternalDeviceTransfer(
                    sourceURL: track.track.fileURL,
                    destinationURL: destinationURL,
                    relativeSubpath: plannedPath.relativeSubpath.map { _ in
                        Self.relativeSubpath(of: destinationURL, under: destinationRoot)
                    },
                    action: action,
                    conversionPreset: preset,
                    metadata: track.metadata
                )
            )
        }

        return plannedTransfers
    }

    // MARK: - Device-safe names

    /// `url` with every component below `root` made a name a FAT device can
    /// hold and the device write policy passes (`FATName.component`): no
    /// trailing dot or space (FAT drops them, so `R.E.M.` would name another
    /// folder than the one planned), no leading dot, no `? * " < > | : \`,
    /// no reserved stem, and no `~<digit>`, which reads as a FAT short name.
    /// Applied to every planned device destination, before the review
    /// compares paths, so a second send plans the same names as the first.
    /// The album's identity comes from its tags, so a renamed folder is still
    /// the same album. Nothing already on a device is renamed.
    public static func deviceSafeURL(_ url: URL, under root: URL) -> URL {
        let rootComponents = root.standardizedFileURL.pathComponents
        let components = url.standardizedFileURL.pathComponents
        guard components.count > rootComponents.count,
              Array(components.prefix(rootComponents.count)) == rootComponents
        else { return url }
        let below = Array(components.dropFirst(rootComponents.count))
        var result = root
        for (index, component) in below.enumerated() {
            let isFile = index == below.count - 1
            let ext = isFile ? (component as NSString).pathExtension : ""
            let stem = isFile && !ext.isEmpty ? (component as NSString).deletingPathExtension : component
            let safe = FATName.component(stem, extension: ext.isEmpty ? nil : ext).map(withoutShortNameMarker)
                ?? (ext.isEmpty ? "_" : "_." + ext)
            result.appendPathComponent(safe, isDirectory: !isFile)
        }
        return result
    }

    /// Device-safe destinations for jobs planned at their natural names (a
    /// Record Divider's slices): each made safe first (`deviceSafeURL`), and
    /// only then stepped past ` (n)` where it lands on a path in `reserved`
    /// or on an earlier one in the list, compared as FAT does (case and
    /// Unicode form folded). Sanitising after avoiding collisions would let
    /// two names that become one ("What?" and "What") collide again.
    public static func deviceSafeUnique(_ urls: [URL], under root: URL, reserved: Set<String>) -> [URL] {
        func key(_ url: URL) -> String {
            url.standardizedFileURL.resolvingSymlinksInPath().path.precomposedStringWithCanonicalMapping.lowercased()
        }
        var taken = Set(reserved.map { key(URL(fileURLWithPath: $0)) })
        return urls.map { url in
            let safe = deviceSafeURL(url, under: root)
            var candidate = safe
            var attempt = 1
            while taken.contains(key(candidate)) {
                attempt += 1
                candidate = suffixed(safe, attempt: attempt)
            }
            taken.insert(key(candidate))
            return candidate
        }
    }

    /// `url` with " (n)" before its extension.
    static func suffixed(_ url: URL, attempt: Int) -> URL {
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        let named = url.deletingLastPathComponent().appendingPathComponent("\(base) (\(attempt))")
        return ext.isEmpty ? named : named.appendingPathExtension(ext)
    }

    /// `~` followed by a digit becomes `-`: such a name can be taken for a
    /// FAT 8.3 short name (`ROCKBO~1`) and the policy refuses it.
    private static func withoutShortNameMarker(_ name: String) -> String {
        var scalars = Array(name.unicodeScalars)
        for index in scalars.indices.dropLast() where scalars[index] == "~" && ("0"..."9").contains(scalars[index + 1]) {
            scalars[index] = "-"
        }
        var out = String.UnicodeScalarView()
        out.append(contentsOf: scalars)
        return String(out)
    }

    private static func relativeSubpath(of url: URL, under root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let folder = url.deletingLastPathComponent().standardizedFileURL.path
        guard folder.hasPrefix(rootPath) else { return "" }
        return String(folder.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func commonAncestorDirectory(for urls: [URL]) -> URL? {
        guard let first = urls.first else { return nil }
        var commonComponents = first.deletingLastPathComponent().standardizedFileURL.pathComponents
        for url in urls.dropFirst() {
            let parts = url.deletingLastPathComponent().standardizedFileURL.pathComponents
            var count = 0
            while count < commonComponents.count, count < parts.count, commonComponents[count] == parts[count] {
                count += 1
            }
            commonComponents = Array(commonComponents.prefix(count))
            if commonComponents.isEmpty {
                return nil
            }
        }

        guard !commonComponents.isEmpty else { return nil }
        if commonComponents == ["/"] {
            return URL(fileURLWithPath: "/", isDirectory: true)
        }
        return URL(fileURLWithPath: "/" + commonComponents.dropFirst().joined(separator: "/"), isDirectory: true)
    }
}
