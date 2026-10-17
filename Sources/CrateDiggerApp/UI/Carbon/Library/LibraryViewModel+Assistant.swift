import AppKit
import AssistantKit
import CrateDiggerCore
import Foundation

/// A change the view model refused. The message reaches the LLM, which passes
/// it on, so it is written for the user.
struct AssistantHostError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

/// The library assistant's host: what `LibraryAssistant` reads and the writes
/// it asks for, done through the same funnels as the UI (`saveCrateTracks`,
/// the playlist service, the stream store, `updateTracksMetadata`), so the
/// disconnected-library guard, the crate caches and every repoint behave as
/// they would for a click. Only ever wired up when the hidden assistant
/// preference is on (`AssistantController`).
extension LibraryViewModel: LibraryAssistantHost {

    func startAssistantIfEnabled() {
        AssistantController.shared.start(host: self)
    }

    // MARK: - Reading

    func assistantLibraryInput() -> AssistantLibraryInput {
        AssistantLibraryInput(
            crates: availableCrates.map { ($0, loadCrateTracks(name: $0)) },
            prepCrate: prepCrateTracks,
            stats: currentListeningStore().allStats,
            playlists: playlists,
            streams: streams)
    }

    func assistantWriteRefusal() -> String? {
        guard case .disconnected(let volume, _) = libraryLocation else { return nil }
        let drive = volume.map { "the drive \"\($0)\"" } ?? "its folder"
        return "The library is on \(drive), which isn't connected, so CrateDigger can only read it right now. Ask the user to connect it and try again."
    }

    func assistantLibraryFolder() -> String {
        cratesDirectoryURL.standardizedFileURL.path
    }

    // MARK: - Crates and playlists

    func assistantWriteCrates(_ memberships: [(name: String, paths: [String])]) throws {
        guard !refuseWhileLibraryDisconnected() else {
            throw AssistantHostError(assistantWriteRefusal() ?? "The library can't be written right now.")
        }
        // The paths came from the library, so every track is already in the
        // store: no store write, just each crate's membership.
        let store = currentTrackStore()
        for (name, paths) in memberships {
            guard saveCrateTracks(store.tracks(paths: paths), name: name, persistStore: false) else {
                throw AssistantHostError("CrateDigger couldn't save the crate \"\(name)\".")
            }
        }
        refreshAvailableCrates()
        selectSource(currentSource)
    }

    func assistantTrashCrates(_ names: [String]) throws {
        guard !refuseWhileLibraryDisconnected() else {
            throw AssistantHostError(assistantWriteRefusal() ?? "The library can't be written right now.")
        }
        // `deleteCrate` without its confirmation: an undo was asked for, and
        // the Trash keeps the file either way.
        for name in names {
            let url = cratesDirectoryURL.appendingPathComponent("\(name).cdcrate")
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            } catch {
                throw AssistantHostError("CrateDigger couldn't move the crate \"\(name)\" to the Trash: \(error.localizedDescription)")
            }
        }
        refreshAvailableCrates()
        if case .localCrate(let current) = currentSource, names.contains(current) {
            selectSource(.localAll)
        } else {
            selectSource(currentSource)
        }
    }

    func assistantWritePlaylist(name: String, paths: [String]) throws {
        try playlistService.savePlaylist(Playlist(name: name, trackURLs: paths.map { URL(fileURLWithPath: $0) }))
        playlists = playlistService.listPlaylists()
        if case .playlist(let current) = currentSource, current == name {
            selectSource(currentSource)
        }
    }

    func assistantTrashPlaylist(name: String) throws {
        try playlistService.deletePlaylist(name: name, useTrash: true)
        playlists = playlistService.listPlaylists()
        if case .playlist(let current) = currentSource, current == name {
            selectSource(.localAll)
        }
    }

    // MARK: - Streams

    func assistantAddStreams(_ new: [StreamSource]) {
        for stream in new {
            streams = streamStore.add(stream)
            fetchMetadata(for: stream.id)
        }
    }

    func assistantRemoveStreams(ids: [String]) {
        for id in ids { streams = streamStore.remove(id: id) }
    }

    // MARK: - Tags

    func assistantPresentTagReview(_ proposal: AssistantTagProposal) -> String? {
        guard assistantTagProposal == nil else {
            return "A tag review from the assistant is already open in CrateDigger. Ask the user to apply or discard it first."
        }
        guard metadataMatches.isEmpty, metadataRepairConflicts.isEmpty else {
            return "CrateDigger is in the middle of a FIX TAGS review. Ask the user to finish it first."
        }
        assistantTagProposal = proposal
        showOLEDNotice("TAGS TO REVIEW")
        // The user is in Claude, not here: bounce the Dock icon once.
        NSApp.requestUserAttention(.informationalRequest)
        return nil
    }

    func assistantRestoreTags(_ writes: [UUID: AssistantTagWrite]) throws {
        guard !refuseWhileLibraryDisconnected() else {
            throw AssistantHostError(assistantWriteRefusal() ?? "The library can't be written right now.")
        }
        let tracks = assistantTracksByID()
        let updates = writes.compactMap { id, write in
            tracks[id].map { (track: $0, metadata: write.values.applied(to: $0.metadata, fields: write.fields)) }
        }
        updateTracksMetadata(updates)
    }

    func assistantJournalDidChange() {
        AssistantController.shared.journalDidChange()
    }

    /// The review sheet's Apply: writes the ticked tracks' proposed fields over
    /// what each track carries now, and records the change for undo.
    func applyAssistantTagProposal(_ proposal: AssistantTagProposal, trackIDs: Set<UUID>) {
        assistantTagProposal = nil
        guard !trackIDs.isEmpty, !refuseWhileLibraryDisconnected() else { return }
        let tracks = assistantTracksByID()
        var updates: [(track: LoadedTrack, metadata: ConversionMetadata)] = []
        var edits: [AssistantChange.TagEdit] = []
        for item in proposal.items where trackIDs.contains(item.trackID) {
            guard let track = tracks[item.trackID] else { continue }
            let before = AssistantTagValues(track)
            var after = before
            for field in item.changedFields { after.copy(field, from: item.proposed) }
            guard after != before else { continue }
            updates.append((track, after.applied(to: track.metadata, fields: after.changedFields(from: before))))
            edits.append(AssistantChange.TagEdit(trackID: item.trackID, before: before, after: after))
        }
        guard !updates.isEmpty else { return }
        // Journalled before the write lands. A track whose write fails still
        // reads its old tags, and undo only restores fields that read what
        // this change wrote, so it leaves that track alone.
        AssistantController.shared.assistant?.recordAppliedTags(summary: proposal.summary, edits: edits)
        updateTracksMetadata(updates)
    }

    func discardAssistantTagProposal() {
        assistantTagProposal = nil
    }

    /// Edit ▸ Undo AI Change.
    func undoAssistantChange() {
        let result = AssistantController.shared.undoLast()
        if result.isError {
            appAlert = .error(title: "Can’t Undo", message: result.text)
        } else {
            showOLEDNotice("UNDONE")
        }
    }

    private func assistantTracksByID() -> [UUID: LoadedTrack] {
        var tracks: [UUID: LoadedTrack] = [:]
        for track in currentTrackStore().allTracks + prepCrateTracks where tracks[track.track.id] == nil {
            tracks[track.track.id] = track
        }
        return tracks
    }
}
