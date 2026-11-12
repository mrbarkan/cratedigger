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
/// move, the drive going or coming back). Every writer starts with
/// `refuseWhileLibraryDisconnected`.
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
        artistProfiles[PodBoxArtName.folded(name)]
    }

    func artistSummary(named name: String) -> ArtistLibrarySummary? {
        artistSummaries[PodBoxArtName.folded(name)]
    }

    func isLookingUpArtist(_ name: String) -> Bool {
        artistLookupsRunning.contains(PodBoxArtName.folded(name))
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
        let albumArtist = loaded.metadata.albumArtist?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !albumArtist.isEmpty { return albumArtist }
        return loaded.metadata.artist ?? loaded.track.artist
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
    /// changes. The folder is made first (`cratesDirectoryURL`), except the
    /// offline copy's, which is never made here.
    func currentArtistProfileStore() async -> ArtistProfileStore {
        let folder = cratesDirectoryURL
        let key = folder.standardizedFileURL.path + "\u{0}" + Self.locationCase(libraryLocation)
        if let task = artistProfileStoreTask, artistProfileStoreKey == key { return await task.value }
        let task = Task.detached(priority: .userInitiated) { ArtistProfileStore(indexDirectory: folder) }
        artistProfileStoreTask = task
        artistProfileStoreKey = key
        return await task.value
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

    /// Reads every profile off the main actor and publishes them. A later
    /// reload always wins over an earlier one still reading.
    func reloadArtistProfiles() {
        artistProfilesGeneration += 1
        let generation = artistProfilesGeneration
        Task {
            let store = await currentArtistProfileStore()
            let profiles = await Task.detached(priority: .userInitiated) { store.allProfiles() }.value
            guard generation == artistProfilesGeneration else { return }
            artistProfiles = Dictionary(profiles.map { ($0.foldedKey, $0) }, uniquingKeysWith: { first, _ in first })
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
            let store = await currentArtistProfileStore()
            let refused = await Task.detached(priority: .userInitiated) { () -> [String] in
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
            }.value
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
        let fetcher = URLSessionPictureFetcher()
        Task {
            let store = await currentArtistProfileStore()
            let failure = await Task.detached(priority: .userInitiated) { () -> String? in
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
            }.value
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

    /// A found photo's thumbnail, fetched on demand through the picture
    /// fetcher (its sources' hosts only) and decoded off the main actor.
    /// Kept for the session; nil when it will not download.
    func artistCandidateThumbnail(_ url: URL, side: Int = 240) async -> NSImage? {
        let key = "\(side)|\(url.absoluteString)" as NSString
        if let cached = Self.artistCandidateThumbnails.object(forKey: key) { return cached }
        let fetcher = URLSessionPictureFetcher()
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

    /// A plain file no larger than an owner photo may be, read whole.
    nonisolated static func readArtistPhotoFile(_ url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw ArtistProfileStoreError.unreadablePhoto }
        guard (values.fileSize ?? .max) <= ArtistPictureImage.maximumSourceBytes else {
            throw ArtistProfileStoreError.photoTooLarge
        }
        return try Data(contentsOf: url)
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
            let store = await currentArtistProfileStore()
            let failure = await Task.detached(priority: .userInitiated) { () -> String? in
                change(store)
                do {
                    try store.save()
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }.value
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
    /// Artist and nameless artists are never looked up.
    func runArtistLookup(_ name: String, resetFirst: Bool) {
        let key = PodBoxArtName.folded(name)
        guard ArtistLookupScheduler.isLookedUp(name) else {
            showOLEDNotice("NOTHING TO LOOK UP")
            return
        }
        guard !artistLookupsRunning.contains(key), !refuseWhileLibraryDisconnected() else { return }
        artistLookupsRunning.insert(key)
        let run = foregroundArtistLookupRun()
        let index = self.index
        Task {
            let store = await currentArtistProfileStore()
            let outcome = await Task.detached(priority: .userInitiated) { () -> Result<Void, Error> in
                let titles = index.artists.filter { PodBoxArtName.folded($0.name) == key }
                    .flatMap(\.albums).map(\.title)
                let picture = ArtistPictureSession.LibraryFolders(tracks: index.allTracks).picture(for: name)
                do {
                    // A failure puts back the identity the reset replaced.
                    try await store.lookUpAgain(name: name, resetFirst: resetFirst, at: Date()) { existing in
                        try await run.lookUp(name: name, libraryAlbumTitles: titles, libraryPicture: picture,
                                             existing: existing, lane: .foreground, now: Date())
                    }
                    return .success(())
                } catch {
                    return .failure(error)
                }
            }.value
            artistLookupsRunning.remove(key)
            reloadArtistProfiles()
            if case .failure(let error) = outcome {
                AppLog.library.error("Artist lookup for \(name, privacy: .private) failed: \(String(describing: error), privacy: .public)")
                appAlert = .error(title: "Could Not Look Up \(name)", message: Self.lookupFailureMessage(error))
            }
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
        let fetcher = URLSessionPictureFetcher()
        let deezer = DeezerArtistSource(fetcher: fetcher)
        let run = ArtistLookupRun(
            info: ArtistInfoClient(fetcher: fetcher),
            pictures: ArtistPictureFinder(sources: [deezer, CommonsArtistSource(fetcher: fetcher)], fetcher: fetcher),
            fetcher: fetcher, deezer: deezer)
        artistForegroundLookup = run
        return run
    }
}
