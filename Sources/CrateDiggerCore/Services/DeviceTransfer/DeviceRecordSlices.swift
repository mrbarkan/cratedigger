import Foundation

/// Record Divider recordings on a device run. The review compares whole
/// tracks and plans one file per source, but a divided recording becomes one
/// file per kept marker, all cut from one source, so its slices are planned
/// apart (`ConversionJob`s with a slice each, at their natural paths) and
/// added to the reviewed plan here.
///
/// A slice whose file is already on the device is left there and counted as
/// already there: never overwritten, never given a ` (2)`. The rest become
/// New copies, each recorded as its own track (marker title, number and
/// length), the way a scan of the written file reads it.
public struct DeviceRecordSlices: Sendable {
    /// Slices to write, as plan copies.
    public let copies: [DeviceTransferFilePlan.Copy]
    /// The job that cuts each copy, by destination path.
    public let jobs: [String: ConversionJob]
    /// Each folder a slice lands in, with the first slice written there.
    public let coverFolders: [URL: LoadedTrack]
    /// Slices whose file the device already holds.
    public let alreadyThere: Int

    /// `jobs` are the slice jobs planned for `tracks` (the divided
    /// recordings). Reads the device, so run it off the main actor.
    public init(jobs sliceJobs: [ConversionJob], of tracks: [LoadedTrack], fileManager: FileManager = .default) {
        let sources = Dictionary(tracks.map { ($0.track.fileURL.path, $0) }, uniquingKeysWith: { first, _ in first })
        let identities = DeviceAlbumIdentity.identities(for: tracks)
        var copies: [DeviceTransferFilePlan.Copy] = []
        var byPath: [String: ConversionJob] = [:]
        var covers: [URL: LoadedTrack] = [:]
        var alreadyThere = 0
        for job in sliceJobs {
            guard let source = sources[job.sourceURL.path] else { continue }
            guard !fileManager.fileExists(atPath: job.destinationURL.path) else {
                alreadyThere += 1
                continue
            }
            var audio = source.track
            let metadata = job.metadata ?? source.metadata
            audio.title = metadata.title ?? audio.title
            audio.trackNumber = metadata.trackNumber
            audio.trackTotal = metadata.trackTotal
            if let start = job.startSeconds, let end = job.endSeconds { audio.durationSeconds = max(0, end - start) }
            let slice = LoadedTrack(track: audio, metadata: metadata)
            copies.append(DeviceTransferFilePlan.Copy(
                source: slice,
                destinationURL: job.destinationURL,
                overwrites: false,
                kind: .new,
                album: identities[source.track.id]
                    ?? DeviceAlbumIdentity(artist: source.track.artist, album: source.track.album)
            ))
            byPath[job.destinationURL.path] = job
            let folder = job.destinationURL.deletingLastPathComponent().standardizedFileURL
            if covers[folder] == nil { covers[folder] = slice }
        }
        self.copies = copies
        self.jobs = byPath
        self.coverFolders = covers
        self.alreadyThere = alreadyThere
    }

    /// `plan` with these slices added: their copies after its own, their
    /// folders among its covers when the device writes folder art, and the
    /// slices already there counted as present.
    public func merged(into plan: DeviceTransferFilePlan, writesFolderCoverArt: Bool) -> DeviceTransferFilePlan {
        DeviceTransferFilePlan(
            copies: plan.copies + copies,
            deletionsByAlbum: plan.deletionsByAlbum,
            coverFolders: writesFolderCoverArt
                ? plan.coverFolders.merging(coverFolders) { planned, _ in planned }
                : plan.coverFolders,
            skippedPresent: plan.skippedPresent + alreadyThere,
            leftAlone: plan.leftAlone,
            replacedAlbums: plan.replacedAlbums,
            keptBothAlbums: plan.keptBothAlbums,
            gapAlbums: plan.gapAlbums,
            unplanned: plan.unplanned
        )
    }
}
