import Foundation
import CrateDiggerCore

/// One track's stored-vs-file tag disagreements, held with the fresh probe so
/// the review sheet can adopt chosen file values without re-probing.
struct MetadataRepairConflictGroup: Identifiable {
    let trackID: UUID
    let trackTitle: String
    let fileURL: URL
    let probed: ConversionMetadata
    let conflicts: [MetadataFieldConflict]
    var id: UUID { trackID }
}

// MARK: - Metadata repair (FIX TAGS)

extension LibraryViewModel {

    /// FIX TAGS only makes sense where tracks are crate-backed local files.
    var canRepairMetadata: Bool {
        if case .prepCrate = currentSource { return true }
        return isLocalSource
    }

    /// One-press repair for the current source: re-probe every track whose
    /// number is missing OR duplicated within its album (an album of all "11"s
    /// is as broken as one with blanks), fill blank tags from the file, and
    /// save the healed crates. Never writes to the audio files.
    func repairMissingMetadata() {
        guard canRepairMetadata, !isRepairingMetadata else { return }

        var duplicatedIDs: Set<UUID> = []
        for artist in index.artists {
            for album in artist.albums {
                duplicatedIDs.formUnion(MetadataRepairPlanner.duplicatedNumberTrackIDs(in: album.tracks))
            }
        }
        let candidates = index.allTracks.filter {
            MetadataRepairPlanner.needsRepair($0.metadata) || duplicatedIDs.contains($0.track.id)
        }
        guard !candidates.isEmpty else {
            appAlert = .info(title: "Tags Check Out",
                             message: "Every track in this source has a track number, with no duplicates inside an album.")
            return
        }

        isRepairingMetadata = true
        showOLEDNotice("CHECKING TAGS…")

        let scanner = self.scanner
        let dupIDs = duplicatedIDs
        let total = candidates.count

        // Detached: the probes must not touch the main actor at all — the first
        // (sequential, main-inherited) version of this loop froze the app for
        // the whole run on a big crate. Strong self is fine: the view model is
        // app-lifetime and @MainActor (Sendable); it's only touched via
        // MainActor.run.
        Task.detached(priority: .userInitiated) {
            typealias ProbeResult = (track: LoadedTrack, outcome: MetadataRepairOutcome, probed: ConversionMetadata)?
            var repaired: [LoadedTrack] = []
            var conflictGroups: [MetadataRepairConflictGroup] = []
            var unreadable = 0
            var completed = 0

            func collect(_ result: ProbeResult) async {
                completed += 1
                if completed % 10 == 0 || completed == total {
                    let done = completed
                    await MainActor.run { self.showOLEDNotice("CHECKING TAGS… \(done)/\(total)") }
                }
                guard let result else {
                    unreadable += 1
                    return
                }
                if result.outcome.didFill {
                    repaired.append(Self.applying(result.outcome.metadata, to: result.track))
                }
                if !result.outcome.conflicts.isEmpty {
                    conflictGroups.append(MetadataRepairConflictGroup(
                        trackID: result.track.track.id,
                        trackTitle: result.track.track.title,
                        fileURL: result.track.track.fileURL,
                        probed: result.probed,
                        conflicts: result.outcome.conflicts
                    ))
                }
            }

            await withTaskGroup(of: ProbeResult.self) { group in
                // ponytail: fixed width 6 — enough to hide ffprobe spawn latency
                // without contending with playback; tune if a huge crate crawls.
                var inFlight = 0
                for track in candidates {
                    if inFlight >= 6, let done = await group.next() {
                        inFlight -= 1
                        await collect(done)
                    }
                    group.addTask {
                        guard let fresh = await scanner.reloadTrack(at: track.track.fileURL) else { return nil }
                        var probed = fresh.metadata
                        // The all-tracks-are-"11" case: the file's tag just
                        // echoes the same duplicated number (the crate was
                        // scanned from these files), so tag-vs-tag comparison
                        // sees nothing. The filename ("03 - Song.flac") is the
                        // remaining honest signal — offer its number as the
                        // conflict's file value.
                        if dupIDs.contains(track.track.id),
                           probed.trackNumber == track.metadata.trackNumber,
                           let inferred = MetadataNormalization.trackNumber(
                               fromFilename: track.track.fileURL.deletingPathExtension().lastPathComponent),
                           inferred != track.metadata.trackNumber {
                            probed.trackNumber = inferred
                        }
                        return (track, MetadataRepairPlanner.repair(stored: track.metadata, probed: probed), probed)
                    }
                    inFlight += 1
                }
                for await done in group {
                    await collect(done)
                }
            }

            let finalRepaired = repaired
            let finalGroups = conflictGroups
            let finalUnreadable = unreadable
            await MainActor.run {
                if !finalRepaired.isEmpty {
                    self.updateTrackURLsInIndex(finalRepaired)
                }
                self.isRepairingMetadata = false
                self.metadataRepairConflicts = finalGroups
                self.showOLEDNotice(finalRepaired.isEmpty ? "TAGS CHECKED" : "TAGS REPAIRED")

                var lines = ["Checked \(total) track\(total == 1 ? "" : "s") with a missing or duplicated track number."]
                lines.append(finalRepaired.isEmpty
                    ? "No fixes found in the files' tags."
                    : "Filled tags on \(finalRepaired.count) track\(finalRepaired.count == 1 ? "" : "s") from the files.")
                if finalUnreadable > 0 { lines.append("\(finalUnreadable) file\(finalUnreadable == 1 ? "" : "s") couldn't be read.") }
                if !finalGroups.isEmpty { lines.append("\(finalGroups.count) track\(finalGroups.count == 1 ? "" : "s") have tags that differ from the files — review them next.") }
                self.appAlert = .info(title: "Tag Check Complete", message: lines.joined(separator: " "))
            }
        }
    }

    /// Apply the review sheet's decisions: for each group, adopt the chosen
    /// conflict fields from the file's tags into the stored metadata.
    func resolveMetadataRepairConflicts(_ chosen: [UUID: [MetadataRepairField]]) {
        let groups = metadataRepairConflicts
        metadataRepairConflicts = []
        var updated: [LoadedTrack] = []

        for group in groups {
            guard let fields = chosen[group.trackID], !fields.isEmpty,
                  let track = index.allTracks.first(where: { $0.track.id == group.trackID })
            else { continue }
            let merged = MetadataRepairPlanner.adopt(fields, from: group.probed, into: track.metadata)
            updated.append(Self.applying(merged, to: track))
        }

        guard !updated.isEmpty else { return }
        updateTrackURLsInIndex(updated)
        showOLEDNotice("TAGS UPDATED")
    }

    /// Rebuild a LoadedTrack around repaired metadata, mirroring the surfaced
    /// fields the scanner derives (title/artist/album/year/track/disc) while
    /// keeping identity, file info, markers, and artwork untouched.
    /// `nonisolated`: pure value work, called from the detached probe task.
    nonisolated private static func applying(_ metadata: ConversionMetadata, to loaded: LoadedTrack) -> LoadedTrack {
        var track = loaded.track
        if let title = metadata.title, !title.isEmpty { track.title = title }
        if let artist = metadata.artist { track.artist = artist }
        if let album = metadata.album { track.album = album }
        track.year = metadata.year
        track.trackNumber = metadata.trackNumber
        track.trackTotal = metadata.trackTotal
        track.discNumber = metadata.discNumber
        track.discTotal = metadata.discTotal
        return LoadedTrack(track: track, metadata: metadata, recordMarkers: loaded.recordMarkers)
    }
}
