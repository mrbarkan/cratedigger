import AppKit
import CrateDiggerCore
import Foundation

/// "Show Artist", and the browser's focus ending it (spec §1). The rule for
/// the focused column is Core's (`ArtistPageFocus`); this is the part that
/// lives with the view model: an explicit artist from a track's menu or the
/// album page's artist link, cleared when the owner clicks a row or moves
/// between columns, so clicking an album or a track brings the album back.
///
/// The artist's name is resolved here when something it depends on changes
/// (focus, selection, the drawn columns, the gallery), and only read by the
/// views, so a body pass never looks anything up.
struct ArtistPageSelection: Equatable {
    /// The artist "Show Artist" asked for, until focus moves.
    private(set) var explicitArtist: String?
    /// The artist the INFO tab is about, or nil for the album page, as of
    /// the last `resolve`.
    private(set) var artistName: String?

    mutating func show(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        explicitArtist = trimmed.isEmpty ? nil : trimmed
    }

    /// A row was clicked (every click sets the focused column) or an arrow
    /// moved between columns.
    mutating func focusMoved() {
        explicitArtist = nil
    }

    /// The owner chose another row in the browser, or a record from outside
    /// the columns (the gallery, Go to Current Song).
    mutating func selectionChanged() {
        explicitArtist = nil
    }

    /// What `browser`'s didSet does, after it has settled the columns: a
    /// changed selection is a row the owner chose, which ends "Show
    /// Artist"; then the name is worked out again.
    mutating func browserChanged(from old: BrowserState, to new: BrowserState, columns: [ColumnContent],
                                 gallery: Bool) {
        if old.selection != new.selection { selectionChanged() }
        resolve(browser: new, columns: columns, gallery: gallery)
    }

    /// Works out `artistName` from the browser as drawn: the name on the
    /// focused artist column's row (`columns` are the browser's own), or the
    /// explicit artist. The gallery replaces the columns, so only "Show
    /// Artist" reaches the page there.
    mutating func resolve(browser: BrowserState, columns: [ColumnContent], gallery: Bool) {
        if gallery, explicitArtist == nil {
            artistName = nil
            return
        }
        artistName = ArtistPageFocus.artistName(view: browser.view, state: browser, columns: columns,
                                                explicitArtist: explicitArtist)
    }
}

/// The artist page in the inspector, wired (spec §1 and §2). Every decision
/// is Core's: which column means the artist (`ArtistPageFocus`), what the
/// library holds (`ArtistLibrarySummary`), the page's words
/// (`ArtistPageText`), the owner settling an identity
/// (`ArtistProfile.confirmIdentity` and kin) and one lookup
/// (`ArtistLookupRun`). This gathers inputs, keeps store I/O, image decoding
/// and the library walk off the main actor, and publishes what the page reads.
///
/// One `ArtistProfileStore` per crates folder and library location, made
/// after the folder resolves and made again when either changes (a library
/// move, the drive going or coming back), only once every writer holding the
/// old one is done (`withArtistProfileStore`), so two stores never overlap
/// on one folder. Every owner action that writes starts with
/// `refuseWhileLibraryDisconnected`; the background worker pauses instead
/// while the library is disconnected, and drops a result that lands after.
@MainActor
extension LibraryViewModel {

    // MARK: - What the page shows

    /// The artist INFO shows a page for, or nil for the album page. Outside
    /// the local library (a device, a playlist) only an artist the library
    /// knows gets a page.
    var inspectedArtistName: String? {
        guard let name = artistPage.artistName else { return nil }
        if currentSource.isLocalLibrary { return name }
        let key = PodBoxArtName.folded(name)
        return artistSummaries[key] != nil || artistProfiles[key] != nil ? name : nil
    }

    func artistProfile(named name: String) -> ArtistProfile? {
        artistProfilesModel.profile(named: name)
    }

    func artistSummary(named name: String) -> ArtistLibrarySummary? {
        artistSummaries[PodBoxArtName.folded(name)]
    }

    /// "Show Artist" and the album page's artist link: the inspector shows
    /// the page until the owner clicks a row or moves between columns.
    func showArtist(_ name: String) {
        updateArtistPage { $0.show(name) }
        inspectorTab = .info
        if inspectorCollapsed { toggleInspectorCollapsed() }
    }

    /// Changes "Show Artist" and, unless `resolving` is false (the caller
    /// is about to change the browser, whose didSet resolves), works out the
    /// inspected artist again. Published only when something changed.
    func updateArtistPage(resolving: Bool = true, _ change: (inout ArtistPageSelection) -> Void = { _ in }) {
        var next = artistPage
        change(&next)
        if resolving { next.resolve(browser: browser, columns: browserColumns, gallery: showArtworkGallery) }
        if next != artistPage { artistPage = next }
    }

    /// The artist a track belongs to, as the library groups it: the album
    /// artist, else the artist.
    nonisolated static func artistName(of loaded: LoadedTrack) -> String {
        ArtistLookupLibrary.artistName(of: loaded)
    }

    /// A photo's thumbnail, decoded off the main actor and kept in the
    /// artwork thumbnail cache. nil when its file cannot be reached (the
    /// library drive unplugged): the page shows the placeholder.
    func artistPhotoThumbnail(hash: String, maxPixel: Int = 900) async -> NSImage? {
        let store = await currentArtistProfileStore()
        return await artworkService.thumbnailAsync(key: "artist-" + hash, maxPixel: maxPixel) {
            store.photoData(hash: hash)
        }
    }

    // MARK: - The store

    /// The one profile store for the crates folder as it resolves now,
    /// made off the main actor (it reads its file) the first time it is
    /// asked for, and again when the folder or the library's location
    /// changes. A new store waits until every writer holding the old one is
    /// done, so it reads what they saved and its own save never sweeps a
    /// photo they just added. The folder is made first (`cratesDirectoryURL`),
    /// except the offline copy's, which is never made here.
    func currentArtistProfileStore() async -> ArtistProfileStore {
        await currentArtistProfileStoreTask().value
    }

    /// The task making (or that made) the current store; a new one when the
    /// folder or the location changed.
    private func currentArtistProfileStoreTask() -> Task<ArtistProfileStore, Never> {
        let folder = cratesDirectoryURL
        let key = currentArtistProfileStoreKey()
        if let task = artistProfileStoreTask, artistProfileStoreKey == key { return task }
        let replacing = artistProfileStoreTask != nil
        let task = Task { () -> ArtistProfileStore in
            if replacing {
                await self.flushArtistLookupSaves()
                await self.artistProfileStoreDrained()
            }
            return await Task.detached(priority: .userInitiated) { ArtistProfileStore(indexDirectory: folder) }.value
        }
        artistProfileStoreTask = task
        artistProfileStoreKey = key
        return task
    }

    /// The folder and library location a profile store is made for, as they
    /// resolve now (`artistProfileStoreKey` is the one the current store was
    /// made for, which can lag behind until someone asks for the store).
    func currentArtistProfileStoreKey() -> String {
        cratesDirectoryURL.standardizedFileURL.path + "\u{0}" + Self.locationCase(libraryLocation)
    }

    /// Runs `work` off the main actor with the current profile store, held
    /// as in use until it returns, so the store is not replaced under it.
    /// Every writer of the store goes through here. While the index is
    /// being moved (`freezeArtistProfileStore`) it waits for the move.
    func withArtistProfileStore<T: Sendable>(_ work: @escaping @Sendable (ArtistProfileStore) async -> T) async -> T {
        await withArtistProfileStore(ifKey: nil, work)!
    }

    /// `withArtistProfileStore`, only when the store it gets is the one for
    /// `key` (the store a lookup started from); nil, with nothing run, when
    /// the folder or location moved on meanwhile (a move, the drive going).
    func withArtistProfileStore<T: Sendable>(ifKey key: String?,
                                             _ work: @escaping @Sendable (ArtistProfileStore) async -> T) async -> T? {
        // Held only once it is still the current store with nothing awaited
        // in between: a swap that began while this waited is never written past.
        var store: ArtistProfileStore
        while true {
            while artistProfileStoreFrozen {
                await withCheckedContinuation { artistProfileStoreThawWaiters.append($0) }
            }
            let task = currentArtistProfileStoreTask()
            store = await task.value
            if artistProfileStoreTask == task, !artistProfileStoreFrozen { break }
        }
        if let key, artistProfileStoreKey != key { return nil }
        artistProfileStoreUsers += 1
        let value = await Task.detached(priority: .userInitiated) { await work(store) }.value
        releaseArtistProfileStore()
        return value
    }

    /// One holder of the store is done; the drain waiters go on when none is left.
    private func releaseArtistProfileStore() {
        artistProfileStoreUsers -= 1
        if artistProfileStoreUsers == 0 {
            let waiters = artistProfileStoreDrainWaiters
            artistProfileStoreDrainWaiters = []
            waiters.forEach { $0.resume() }
        }
    }

    /// Writes the background lookups' results that only the store's memory
    /// holds (`ArtistLookupSaveSchedule`), off the main actor, to the store
    /// they landed in (never another one made since). Called when the
    /// worker pauses or goes idle, and before the store is swapped or the
    /// index moved.
    func flushArtistLookupSaves() async {
        guard let store = artistUnsavedStore else { return }
        artistUnsavedStore = nil
        artistLookupSaves.saved(at: .now)
        artistProfileStoreUsers += 1
        let failure = await Task.detached(priority: .utility) { () -> String? in
            do {
                try store.save()
                return nil
            } catch {
                return Self.logCase(error)
            }
        }.value
        releaseArtistProfileStore()
        if let failure { AppLog.library.notice("Artist lookups not saved (\(failure, privacy: .public))") }
    }

    /// The same, now, on the main actor: at quit and before the library's
    /// drive is ejected, when nothing can wait. One small file write.
    func flushArtistLookupSavesNow() {
        guard let store = artistUnsavedStore else { return }
        artistUnsavedStore = nil
        artistLookupSaves.saved(at: .now)
        do {
            try store.save()
        } catch {
            AppLog.library.notice("Artist lookups not saved (\(Self.logCase(error), privacy: .public))")
        }
    }

    /// The library as the lookups read it, built once per index change (the
    /// track store's tracks copied once, then grouped off the main actor).
    func artistLookupLibrary() async -> ArtistLookupLibrary {
        if let task = artistLookupLibraryTask { return await task.value }
        let tracks = currentTrackStore().allTracks
        let task = Task.detached(priority: .utility) { ArtistLookupLibrary(tracks: tracks) }
        artistLookupLibraryTask = task
        return await task.value
    }

    /// Returns once no writer holds a profile store.
    func artistProfileStoreDrained() async {
        guard artistProfileStoreUsers > 0 else { return }
        await withCheckedContinuation { artistProfileStoreDrainWaiters.append($0) }
    }

    /// For moving the index: no writer starts from now on, and this returns
    /// once those already running are done. `thawArtistProfileStore` ends it.
    func freezeArtistProfileStore() async {
        artistProfileStoreFrozen = true
        await artistProfileStoreDrained()
        await flushArtistLookupSaves()
    }

    /// The move is over and the folder it left in effect is the one the
    /// next store is made for: the writers that waited go on.
    func thawArtistProfileStore() {
        artistProfileStoreFrozen = false
        let waiters = artistProfileStoreThawWaiters
        artistProfileStoreThawWaiters = []
        waiters.forEach { $0.resume() }
    }

    /// Carries the iPod's old artist picture records (`library.cdartists`)
    /// into the profiles once (`ArtistProfileMigration`), then renames the
    /// old file, which nothing reads again. Runs when the crates folder
    /// resolves (at launch, and for a folder chosen later), never while the
    /// library is disconnected. A failure is logged and tried again next time.
    /// Once a folder's pictures are in its profiles, the old prepared-picture
    /// cache (`ArtistPicturePreparedCache.legacyDirectory`), which only the
    /// migration read, is deleted. The background worker waits for this to
    /// settle (`artistMigrationSettled`): it succeeded, or there was nothing
    /// to carry over.
    func migrateArtistPicturesIfNeeded() {
        guard !isLibraryDisconnected else { return }
        // One `stat`: nearly always there is no old file, and nothing to do.
        let folder = cratesDirectoryURL
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent(ArtistPictureStore.fileName).path)
        else {
            artistMigrationSettled = true
            startArtistLookupWorkerIfWanted()
            Task {
                let store = await currentArtistProfileStore()
                await Task.detached(priority: .utility) {
                    if store.picturesMigrated { ArtistPicturePreparedCache.removeLegacyCache() }
                }.value
            }
            return
        }
        artistMigrationSettled = false
        Task {
            let failure = await withArtistProfileStore { store -> String? in
                // The store's own folder: the crates folder may have moved on since.
                let directory = store.indexDirectory
                do {
                    try ArtistProfileMigration.migrate(pictures: ArtistPictureStore(indexDirectory: directory),
                                                       into: store, indexDirectory: directory)
                    ArtistPicturePreparedCache.removeLegacyCache()
                    return nil
                } catch {
                    return Self.logCase(error)
                }
            }
            if let failure {
                AppLog.library.error("Artist pictures not carried into profiles (\(failure, privacy: .public)); the lookup waits for them")
            } else {
                artistMigrationSettled = true
                startArtistLookupWorkerIfWanted()
            }
            reloadArtistProfiles()
        }
    }

    /// The store is made again when the library's location changes case
    /// (chosen, connected, disconnected), not when a detail inside one
    /// changes, which would make a second store for the same folder.
    nonisolated static func locationCase(_ location: LibraryLocation) -> String {
        switch location {
        case .notChosen: return "notChosen"
        case .available: return "available"
        case .disconnected: return "disconnected"
        }
    }

    /// Reads every profile off the main actor and publishes them, only when
    /// they differ from what is shown (compared off the main actor too). A
    /// later reload always wins over an earlier one still reading.
    func reloadArtistProfiles() {
        artistProfilesGeneration += 1
        let generation = artistProfilesGeneration
        let shown = artistProfilesModel.profiles
        Task {
            let store = await currentArtistProfileStore()
            let changed = await Task.detached(priority: .userInitiated) { () -> [String: ArtistProfile]? in
                let profiles = Dictionary(store.allProfiles().map { ($0.foldedKey, $0) },
                                          uniquingKeysWith: { first, _ in first })
                return profiles == shown ? nil : profiles
            }.value
            guard generation == artistProfilesGeneration, let changed else { return }
            artistProfilesModel.publish(changed)
        }
    }

    // MARK: - Library summaries

    /// Rebuilds `artistSummaries` from the browsed local source, off the main
    /// actor: one pass over the index, plus the crate files read for the
    /// crates that hold each artist. A newer request cancels an older one.
    /// Other sources keep the last local summaries, so a device or playlist
    /// view still shows what the library holds of an artist it knows.
    func scheduleArtistSummaries(after delay: Duration = .milliseconds(150)) {
        guard currentSource.isLocalLibrary else { return }
        let previous = artistSummaryTask
        previous?.cancel()
        let index = self.index
        let scope = currentSource
        let listening = currentListeningStore().allStats
        let folder = cratesDirectoryURL
        let crateNames = availableCrates
        artistSummaryTask = Task {
            // One pass at a time: a cancelled one stops at its next check,
            // so an import's run of index rebuilds never stacks full passes.
            await previous?.value
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            let pass = Task.detached(priority: .utility) { () -> ([String: ArtistLibrarySummary], [UUID: LoadedTrack])? in
                var crates: [String: Set<String>] = [:]
                for name in crateNames {
                    if Task.isCancelled { return nil }
                    let url = folder.appendingPathComponent("\(name).cdcrate")
                    guard let data = try? Data(contentsOf: url),
                          let paths = try? JSONDecoder().decode([String].self, from: data) else { continue }
                    crates[name] = Set(paths)
                }
                if Task.isCancelled { return nil }
                let summaries = ArtistLibrarySummary.all(index: index, listening: listening, crates: crates)
                if Task.isCancelled { return nil }
                let wanted = Set(summaries.values.flatMap(\.topTracks))
                var tracks: [UUID: LoadedTrack] = [:]
                if !wanted.isEmpty {
                    for loaded in index.allTracks where wanted.contains(loaded.track.id) {
                        tracks[loaded.track.id] = loaded
                    }
                }
                return (summaries, tracks)
            }
            let result = await withTaskCancellationHandler { await pass.value } onCancel: { pass.cancel() }
            guard let built = result, !Task.isCancelled else { return }
            artistTopTracks = built.1
            artistSummaryScope = scope
            artistSummaries = built.0
        }
    }

    // MARK: - The owner's answers

    /// "Is this them?": the owner picked a candidate, or "None of these"
    /// (`musicBrainzID` nil), which stops lookups for the artist until Look
    /// Up Again. A picked candidate's facts are looked up at once.
    func confirmArtistIdentity(_ name: String, musicBrainzID: String?) {
        guard !refuseWhileLibraryDisconnected() else { return }
        changeArtistProfile(name) { profile in
            if let musicBrainzID {
                profile.confirmIdentity(musicBrainzID: musicBrainzID)
            } else {
                profile.rejectCandidates()
            }
        } then: { [weak self] in
            if musicBrainzID != nil { self?.runArtistLookup(name, resetFirst: false) }
        }
    }

    /// "Not This Artist", on a confirmed artist: that id is never confirmed
    /// again, what came with it goes, and the artist is looked up again so
    /// the page can offer the others.
    func rejectArtistIdentity(_ name: String) {
        guard !refuseWhileLibraryDisconnected() else { return }
        changeArtistProfile(name) { $0.rejectConfirmedIdentity() } then: { [weak self] in
            self?.runArtistLookup(name, resetFirst: false)
        }
    }

    /// No Photo / Show Photo: the app shows the placeholder, and the iPod
    /// gets nothing. An owner choice no lookup changes.
    func setArtistNoPhoto(_ name: String, _ noPhoto: Bool) {
        guard !refuseWhileLibraryDisconnected() else { return }
        changeArtistProfile(name) { $0.noPhoto = noPhoto }
    }

    /// Look Up Again: now, in the foreground lane, whatever the record's
    /// age. A confirmed artist is refreshed by its id, so an identity the
    /// owner picked stays; any other is reset first, so even "None of
    /// these" is asked again.
    func lookUpArtistAgain(_ name: String) {
        guard !refuseWhileLibraryDisconnected() else { return }
        let confirmed: Bool
        if case .confirmed? = artistProfile(named: name)?.identity { confirmed = true } else { confirmed = false }
        runArtistLookup(name, resetFirst: !confirmed)
    }

    // MARK: - Editing (spec §5)

    /// Edit Artist: the sheet, presented from the root (`LibraryPresentations`),
    /// so it opens in the compact player too.
    func editArtist(_ name: String) {
        // A name that folds to nothing has no profile to keep the edits under.
        guard !PodBoxArtName.folded(name).isEmpty, !refuseWhileLibraryDisconnected() else { return }
        artistEditRequest = name
    }

    /// The Edit sheet's Save: the owner's facts and any identity change, as
    /// one store write (`ArtistEditDraft.apply`). A new identity is looked
    /// up at once, as from the page.
    func saveArtistEdit(_ name: String, draft: ArtistEditDraft) {
        guard !refuseWhileLibraryDisconnected() else { return }
        let changesIdentity = draft.changesIdentity(of: artistProfile(named: name)
            ?? ArtistProfile(foldedKey: PodBoxArtName.folded(name), displayName: name))
        changeArtistProfile(name) { draft.apply(to: &$0) } then: { [weak self] in
            if changesIdentity { self?.runArtistLookup(name, resetFirst: false) }
        }
    }

    /// Add Photos…: the file picker, several at once.
    func chooseArtistPhotos(_ name: String) {
        guard !refuseWhileLibraryDisconnected() else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image]
        panel.title = "Add photos of \(name)"
        panel.prompt = "Add"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        addArtistPhotos(name, urls: panel.urls)
    }

    /// The owner's own photos (the picker, or a drop on the portrait), kept
    /// as given up to 32 MB and 50 MP, added after the others; the default
    /// stays where it is unless there is none. Read, checked and stored off
    /// the main actor, saved once; anything refused is said in one alert.
    func addArtistPhotos(_ name: String, urls: [URL]) {
        guard !refuseWhileLibraryDisconnected() else { return }
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return }
        Task {
            let refused = await withArtistProfileStore { store -> [String] in
                var refused: [String] = []
                for url in files {
                    do {
                        try store.addPhoto(name: name, data: try Self.readArtistPhotoFile(url), source: .owner,
                                           sourceID: nil, credit: nil)
                    } catch {
                        refused.append("\(url.lastPathComponent): \(error.localizedDescription)")
                    }
                }
                do {
                    try store.save()
                } catch {
                    refused.append(error.localizedDescription)
                }
                return refused
            }
            reloadArtistProfiles()
            if !refused.isEmpty {
                let title = refused.count == files.count ? "Photos Not Added" : "Some Photos Not Added"
                appAlert = .error(title: title, message: refused.joined(separator: "\n"))
            }
        }
    }

    /// A photo the lookup found but did not download: fetched now (only
    /// from the picture sources' own hosts), stored, and saved.
    func addArtistPhotoCandidate(_ name: String, _ candidate: ArtistPictureRecord.HeldCandidate) {
        guard !refuseWhileLibraryDisconnected() else { return }
        let fetcher = artistPictureFetcher
        Task {
            let failure = await withArtistProfileStore { store -> String? in
                do {
                    let data = try await fetcher.data(from: candidate.imageURL)
                    try store.addCandidatePhoto(name: name, candidate: candidate, data: data)
                    try store.save()
                    return nil
                } catch let error as ArtistProfileStoreError {
                    return error.localizedDescription
                } catch {
                    return "The photo could not be downloaded. Try again in a minute."
                }
            }
            reloadArtistProfiles()
            if let failure { appAlert = .error(title: "Photo Not Added", message: failure) }
        }
    }

    /// Remove: a looked-up photo is remembered, so no lookup brings it back.
    /// Its file goes with the save when no profile uses it any more.
    func removeArtistPhoto(_ name: String, hash: String) {
        guard !refuseWhileLibraryDisconnected() else { return }
        changeArtistProfile(store: { $0.removePhoto(name: name, hash: hash) })
    }

    /// Make Default: the owner's choice, which no lookup changes.
    func setDefaultArtistPhoto(_ name: String, hash: String) {
        guard !refuseWhileLibraryDisconnected() else { return }
        changeArtistProfile(store: { $0.setDefault(name: name, hash: hash) })
    }

    /// The artist photo viewer, presented from the root (`LibraryPresentations`).
    func showArtistPhotos(_ name: String) {
        guard !PodBoxArtName.folded(name).isEmpty else { return }
        artistPhotoViewerRequest = name
    }

    /// A found photo's thumbnail, fetched on demand through the picture
    /// fetcher (its sources' hosts only) and decoded off the main actor.
    /// Kept for the session; nil when it will not download.
    func artistCandidateThumbnail(_ url: URL, side: Int = 240) async -> NSImage? {
        let key = "\(side)|\(url.absoluteString)" as NSString
        if let cached = Self.artistCandidateThumbnails.object(forKey: key) { return cached }
        let fetcher = artistPictureFetcher
        let image = await Task.detached(priority: .utility) { () -> CGImage? in
            guard let data = try? await fetcher.data(from: url) else { return nil }
            return ArtistPicturesSheetModel.thumbnail(data, side: side)
        }.value
        guard let image else { return nil }
        let thumbnail = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        Self.artistCandidateThumbnails.setObject(thumbnail, forKey: key)
        return thumbnail
    }

    private static let artistCandidateThumbnails: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 120
        return cache
    }()

    /// A picture file the owner chose, read whole when it is no larger
    /// than an owner photo may be. An alias by symbolic link is followed to
    /// its picture, which is what is checked. The read itself stops one byte
    /// past the limit, so a file that grew after the check is refused too,
    /// never read whole.
    nonisolated static func readArtistPhotoFile(_ url: URL) throws -> Data {
        let target = url.resolvingSymlinksInPath()
        let values = try target.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw ArtistProfileStoreError.unreadablePhoto }
        let limit = ArtistPictureImage.maximumSourceBytes
        guard (values.fileSize ?? .max) <= limit else { throw ArtistProfileStoreError.photoTooLarge }
        let handle = try FileHandle(forReadingFrom: target)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw ArtistProfileStoreError.photoTooLarge }
        return data
    }

    /// One change to one profile, saved, then the profiles published again.
    /// Store work off the main actor; a failed save is reported.
    private func changeArtistProfile(_ name: String, _ change: @escaping @Sendable (inout ArtistProfile) -> Void,
                                     then: (@MainActor () -> Void)? = nil) {
        changeArtistProfile(store: { $0.update(name: name, change) }, then: then)
    }

    /// The same, for a store call of its own (`removePhoto`, `setDefault`).
    private func changeArtistProfile(store change: @escaping @Sendable (ArtistProfileStore) -> Void,
                                     then: (@MainActor () -> Void)? = nil) {
        Task {
            let failure = await withArtistProfileStore { store -> String? in
                change(store)
                do {
                    try store.save()
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }
            reloadArtistProfiles()
            if let failure {
                appAlert = .error(title: "Artist Not Saved", message: failure)
                return
            }
            then?()
        }
    }

    // MARK: - One lookup

    /// One lookup for `name`, asked for by the owner: the foreground lane,
    /// the library's own album titles and folder picture, the result applied
    /// under the store's owner rules and saved. Various Artists, Unknown
    /// Artist and nameless artists are never looked up. Asked for while a
    /// lookup (the owner's or the background one) is running for the same
    /// artist, it waits for that one to end and runs then, so a refresh after
    /// the owner settled an identity is never lost; the latest ask wins.
    func runArtistLookup(_ name: String, resetFirst: Bool) {
        let key = PodBoxArtName.folded(name)
        guard ArtistLookupScheduler.isLookedUp(name) else {
            showOLEDNotice("NOTHING TO LOOK UP")
            return
        }
        guard !refuseWhileLibraryDisconnected() else { return }
        guard !artistLookupsRunning.contains(key) else {
            artistLookupsQueued[key] = (name, resetFirst)
            return
        }
        artistLookupsRunning.insert(key)
        let run = foregroundArtistLookupRun()
        Task {
            let library = await artistLookupLibrary()
            let outcome = await withArtistProfileStore { store -> Result<Void, Error> in
                let titles = library.albumTitles(for: name)
                let picture = library.picture(for: name)
                do {
                    // A failure puts back the identity the reset replaced.
                    try await store.lookUpAgain(name: name, resetFirst: resetFirst, at: Date()) { existing in
                        try await run.lookUp(name: name, libraryAlbumTitles: titles, libraryPicture: picture,
                                             existing: existing, lane: .foreground, now: Date(),
                                             photoFileExists: { store.hasPhotoFile(hash: $0) })
                    }
                    return .success(())
                } catch {
                    return .failure(error)
                }
            }
            reloadArtistProfiles()
            finishArtistLookup(key)
            if case .failure(let error) = outcome {
                AppLog.library.error("Artist lookup for \(name, privacy: .private) failed: \(Self.logCase(error), privacy: .public)")
                appAlert = .error(title: "Could Not Look Up \(name)", message: Self.lookupFailureMessage(error))
            }
        }
    }

    /// A lookup for `key` ended: the one asked for meanwhile runs now. A
    /// queued Look Up Again on an artist the ended lookup confirmed refreshes
    /// by its id rather than resetting it, as `lookUpArtistAgain` would.
    func finishArtistLookup(_ key: String) {
        artistLookupsRunning.remove(key)
        guard let queued = artistLookupsQueued.removeValue(forKey: key) else { return }
        var resetFirst = queued.resetFirst
        if case .confirmed? = artistProfile(named: queued.name)?.identity { resetFirst = false }
        runArtistLookup(queued.name, resetFirst: resetFirst)
    }

    /// What went wrong, for the log, without anything that can carry a path
    /// or an artist's name: the error's kind and case only.
    nonisolated static func logCase(_ error: Error) -> String {
        switch error {
        case let store as ArtistProfileStoreError:
            switch store {
            case .unreadableStore: return "profiles file unreadable"
            case .unreachableIndexFolder: return "index folder unreachable"
            case .unnamedArtist: return "unnamed artist"
            case .unreadablePhoto: return "unreadable photo"
            case .photoTooLarge: return "photo too large"
            }
        case let lookup as ArtistLookupError:
            switch lookup {
            case .notLookedUp: return "not looked up"
            case .pictureLookupFailed: return "picture lookup failed"
            case .timedOut: return "timed out"
            }
        case let source as ArtistPictureSourceError:
            switch source {
            case .quota: return "quota"
            case .malformed: return "malformed answer"
            case .http(let status): return "HTTP \(status)"
            case .transport: return "transport"
            case .refusedURL: return "refused URL"
            }
        case is CancellationError:
            return "cancelled"
        default:
            let error = error as NSError
            return "\(error.domain) \(error.code)"
        }
    }

    /// Words for the owner: a service not answering is "try later", never
    /// "not found".
    private static func lookupFailureMessage(_ error: Error) -> String {
        if let store = error as? ArtistProfileStoreError, let text = store.errorDescription { return text }
        if let source = error as? ArtistPictureSourceError, source.stopsTheRun || source == .quota {
            return "MusicBrainz, Wikipedia or Deezer did not answer. Nothing was changed; try again in a minute."
        }
        return "The lookup could not finish. Nothing was changed; try again later."
    }

    /// The owner's lookups share one run, so its spacing between Wikidata,
    /// Commons and image requests holds across them.
    private func foregroundArtistLookupRun() -> ArtistLookupRun {
        if let run = artistForegroundLookup { return run }
        let fetcher = artistPictureFetcher
        let deezer = DeezerArtistSource(fetcher: fetcher)
        let run = ArtistLookupRun(
            info: ArtistInfoClient(fetcher: fetcher),
            // No Commons source: the run builds its Commons candidates from
            // the identity search itself.
            pictures: ArtistPictureFinder(sources: [deezer], fetcher: fetcher),
            fetcher: fetcher, deezer: deezer)
        artistForegroundLookup = run
        return run
    }
}

// MARK: - The background lookup (spec §4)

/// One artist the background worker is about to look up, with what the
/// library holds of them for the identity match and the first photo.
struct BackgroundArtistTarget: Sendable {
    let name: String
    /// `PodBoxArtName.folded(name)`.
    let key: String
    let albumTitles: [String]
    let libraryPicture: URL?
    /// False once this artist's photo search ran out of time this session.
    let findsPhoto: Bool
}

/// How one background lookup ended.
enum BackgroundLookupOutcome {
    /// Applied and saved; `photoTimedOut` when it landed without a photo
    /// because the photo search ran out of time.
    case done(photoTimedOut: Bool)
    /// Not kept: the library went away, the switch went off, the store was
    /// replaced or another lookup of the artist was running.
    case discarded
    case failed(Error)
}

@MainActor
extension LibraryViewModel {
    /// Starts the background worker, which waits a minute before its first
    /// lookup, once the old picture records are carried into the profiles
    /// (`artistMigrationSettled`); until then it is only wanted.
    func startArtistLookupWorker() {
        artistLookupWorkerWanted = true
        startArtistLookupWorkerIfWanted()
    }

    func startArtistLookupWorkerIfWanted() {
        guard artistLookupWorkerWanted, artistMigrationSettled, artistLookupWorker == nil else { return }
        #if DEBUG
        // The artist page fixture promises nothing goes on the network.
        if ProcessInfo.processInfo.environment["CRATEDIGGER_ARTIST_PAGE"] != nil { return }
        #endif
        let worker = ArtistLookupWorker(library: self, fetcher: artistPictureFetcher)
        artistLookupWorker = worker
        worker.start()
    }

    /// Why the worker should not run now: the switch, a scan, a conversion
    /// or device transfer, no window on screen, Low Power Mode, no network,
    /// or the library's drive unplugged.
    func artistLookupPauses(offline: Bool) -> ArtistLookupPauses {
        ArtistLookupPauses(disabled: !prefs.artistLookupsEnabled, scanning: scanProgress.isRunning,
                           transferring: isDeviceBusy || isConversionRunning,
                           hidden: !AppVisibility.shared.isVisible,
                           lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled, offline: offline,
                           libraryDisconnected: isLibraryDisconnected)
    }

    /// The artists that go first: the one the inspector shows, then the one
    /// playing from the library.
    func backgroundLookupPriority() -> [String] {
        var names: [String] = []
        if let inspected = inspectedArtistName { names.append(inspected) }
        if let playing = nowPlayingTrack, playingSource?.isLocalLibrary == true {
            names.append(Self.artistName(of: playing))
        }
        return names
    }

    /// The next artist the worker looks up (`ArtistLookupScheduler.due`),
    /// worked out off the main actor from every track the library holds;
    /// nil when nobody is due. Skips the artists this session gave up on,
    /// priority names already looked up this launch, and any artist a lookup
    /// is running for.
    func nextBackgroundArtist(session: ArtistLookupSession) async -> BackgroundArtistTarget? {
        let library = await artistLookupLibrary()
        let running = artistLookupsRunning
        let skipped = session.skipped, priorityDone = session.priorityDone
        let priority = backgroundLookupPriority().filter { name in
            let key = PodBoxArtName.folded(name)
            return !priorityDone.contains(key) && !skipped.contains(key)
        }
        let store = await currentArtistProfileStore()
        return await Task.detached(priority: .utility) { () -> BackgroundArtistTarget? in
            let due = ArtistLookupScheduler().due(artists: library.artists, profiles: { store.profile(forName: $0) },
                                                  priority: priority, now: Date())
            guard let name = due.first(where: { name in
                let key = PodBoxArtName.folded(name)
                return !skipped.contains(key) && !running.contains(key)
            }) else { return nil }
            let key = PodBoxArtName.folded(name)
            return BackgroundArtistTarget(name: name, key: key, albumTitles: library.albumTitles(for: name),
                                          libraryPicture: library.picture(for: name),
                                          findsPhoto: session.findsPhoto(key))
        }.value
    }

    /// One background lookup, in the background lane: the network part off
    /// the main actor and cancelled with the worker, then the result applied
    /// under the store's owner rules (`ArtistLookupResult.apply`) and saved,
    /// unless the library went away, the switch went off or the store was
    /// replaced while it ran. While it runs the artist counts as being looked
    /// up, so an owner's Look Up Again waits for it rather than racing it.
    /// A lookup still running after `limit` is cancelled and fails as
    /// `ArtistLookupError.timedOut`.
    func lookUpInBackground(_ target: BackgroundArtistTarget, run: ArtistLookupRun,
                            limit: Duration) async -> BackgroundLookupOutcome {
        guard !artistLookupsRunning.contains(target.key) else { return .discarded }
        artistLookupsRunning.insert(target.key)
        defer { finishArtistLookup(target.key) }

        let store = await currentArtistProfileStore()
        guard let storeKey = artistProfileStoreKey else { return .discarded }
        let lookup = Task.detached(priority: .utility) { () throws -> ArtistLookupResult in
            try await ArtistLookupRun.bounded(limit) {
                try await run.lookUp(name: target.name, libraryAlbumTitles: target.albumTitles,
                                     libraryPicture: target.libraryPicture,
                                     existing: store.profile(forName: target.name), lane: .background, now: Date(),
                                     findsPhoto: target.findsPhoto,
                                     photoFileExists: { store.hasPhotoFile(hash: $0) })
            }
        }
        let result: ArtistLookupResult
        do {
            result = try await withTaskCancellationHandler { try await lookup.value } onCancel: { lookup.cancel() }
        } catch {
            return .failed(error)
        }
        // Silently, not `refuseWhileLibraryDisconnected`: nobody asked for
        // this, so an unplugged drive is no reason for a notice.
        guard !Task.isCancelled, !isLibraryDisconnected, prefs.artistLookupsEnabled,
              currentArtistProfileStoreKey() == storeKey else { return .discarded }
        // Waits while the index is being moved, and lands nothing if the
        // store it would land in is no longer the one the lookup read. The
        // file is written only now and then (`ArtistLookupSaveSchedule`).
        let saveNow = artistLookupSaves.landed(at: .now)
        guard let landed = await withArtistProfileStore(ifKey: storeKey, { store -> (failure: Error?, store: ArtistProfileStore) in
            do {
                try result.apply(to: store, name: target.name, at: Date())
                if saveNow { try store.save() }
                return (nil, store)
            } catch {
                return (error, store)
            }
        }) else { return .discarded }
        if saveNow {
            artistLookupSaves.saved(at: .now)
            artistUnsavedStore = nil
        } else {
            artistUnsavedStore = landed.store
        }
        reloadArtistProfiles()
        return landed.failure.map { .failed($0) } ?? .done(photoTimedOut: result.photoTimedOut)
    }
}
