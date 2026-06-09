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

    public init(fileManager: FileManager = .default) {
        self.pathPlanner = OutputPathPlanner(fileManager: fileManager)
    }

    public func destinationRoot(for profile: ExternalDeviceProfile, mountedAt mountedRoot: URL) -> URL {
        var destination = mountedRoot
        let subpath = ExternalDeviceProfile.normalizedSubpath(profile.musicDirectorySubpath)
        for component in subpath.split(separator: "/").map(String.init) where !component.isEmpty {
            destination.appendPathComponent(component, isDirectory: true)
        }
        return destination
    }

    public func planTransfers(
        tracks: [LoadedTrack],
        profile: ExternalDeviceProfile,
        mountedAt mountedRoot: URL,
        reviewedAlbumFolders: [AlbumFolderKey: String] = [:],
        reservedDestinationPaths: Set<String> = []
    ) -> [PlannedExternalDeviceTransfer] {
        let destinationRoot = destinationRoot(for: profile, mountedAt: mountedRoot)
        let preset = profile.transferSettings.conversionPreset
        let planningPreset = preset ?? ConversionPreset.genericAAC
        let action: ExternalDeviceTransferAction = preset == nil ? .copyOriginal : .convert
        let sourceRoot = commonAncestorDirectory(for: tracks.map { $0.track.fileURL })

        var reserved = reservedDestinationPaths
        var plannedTransfers: [PlannedExternalDeviceTransfer] = []
        plannedTransfers.reserveCapacity(tracks.count)

        for track in tracks {
            let destinationExtension = preset?.outputExtension ?? track.track.fileURL.pathExtension
            let plannedPath = pathPlanner.planDestination(
                for: track,
                preset: planningPreset,
                destinationRoot: destinationRoot,
                sourceRoot: sourceRoot,
                folderMode: profile.transferSettings.folderStructureMode,
                templateConfig: profile.transferSettings.templateConfig,
                reviewedAlbumFolders: reviewedAlbumFolders,
                reservedDestinationPaths: reserved,
                destinationFileExtension: destinationExtension
            )
            reserved.insert(plannedPath.destinationURL.standardizedFileURL.resolvingSymlinksInPath().path)

            plannedTransfers.append(
                PlannedExternalDeviceTransfer(
                    sourceURL: track.track.fileURL,
                    destinationURL: plannedPath.destinationURL,
                    relativeSubpath: plannedPath.relativeSubpath,
                    action: action,
                    conversionPreset: preset,
                    metadata: track.metadata
                )
            )
        }

        return plannedTransfers
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
