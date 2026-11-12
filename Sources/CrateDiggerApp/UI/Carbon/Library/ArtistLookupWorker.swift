import CrateDiggerCore
import Foundation
import Network

/// The background artist lookup (spec §4): one artist at a time, in the
/// MusicBrainz gate's background lane, so FIX TAGS, artwork search and DEEP
/// SCAN never wait behind it. What to look up next is Core's
/// (`ArtistLookupScheduler`: the inspected and now-playing artists first,
/// then most tracks first), as are the pauses (`ArtistLookupPauses`), the
/// back-off (`ArtistLookupScheduler.backoff`) and what a failure means
/// (`ArtistLookupScheduler.failure`). This owns the loop, the waiting and
/// the network monitor; `LibraryViewModel+ArtistProfiles` gathers the
/// inputs and applies each result off the main actor.
///
/// It starts a minute after launch and resumes where it stopped across
/// launches, since the store's `checkedAt` is the cursor. Nothing it does
/// waits on the main actor beyond reading a few flags.
@MainActor
final class ArtistLookupWorker {
    nonisolated static let startDelay: Duration = .seconds(60)
    /// How soon a paused worker looks at its pauses again (a wake is sooner).
    nonisolated static let pausedRecheck: Duration = .seconds(30)
    /// How soon a worker with nobody due looks again (a wake is sooner).
    nonisolated static let idleRecheck: Duration = .seconds(30 * 60)
    /// A breath between two lookups that went well.
    nonisolated static let between: Duration = .seconds(1)
    /// The background's Deezer requests, at most one a second.
    nonisolated static let deezerSpacing: Duration = .seconds(1)
    /// How long the photo search of one artist may take in the background.
    /// Longer than the 8 s the owner waits for: nobody is watching, and a
    /// common name's search takes a while at a request a second.
    nonisolated static let photoBudget: Duration = .seconds(30)
    /// How long one artist's whole lookup may take before it counts as
    /// timed out (`ArtistLookupError.timedOut`); three of those in a row and
    /// the artist is skipped for the session (`ArtistLookupSession`).
    nonisolated static let lookupLimit: Duration = .seconds(180)

    /// Posted by Settings ▸ Integrations when the switch changes.
    nonisolated static let settingChanged = Notification.Name("CrateDiggerArtistLookupsChanged")

    private weak var library: LibraryViewModel?
    /// One long-lived run, so its spacing between Wikidata, Commons and image
    /// requests holds from one artist to the next.
    private let run: ArtistLookupRun
    private var task: Task<Void, Never>?
    private var napContinuation: CheckedContinuation<Void, Never>?
    private var napTimer: Task<Void, Never>?
    /// What the current nap is waiting out; only idle and paused naps wake.
    private var napKind: NapKind?

    private enum NapKind {
        /// The minute after launch, and the breath between two lookups.
        case start, between
        /// Nobody due, or paused: a wake looks again now.
        case idle, paused
        /// A failure's back-off: never cut short by a wake.
        case backoff
    }
    private let pathMonitor = NWPathMonitor()
    private var settingObserver: NSObjectProtocol?
    private(set) var isOffline = false
    /// Failures in a row, the artists given up on, the priority artists
    /// done and the photos left alone, for this launch (Core's rules).
    private var session = ArtistLookupSession()
    /// The store the worker stopped on (it could not be written), until
    /// another store is made.
    private var stoppedAtStore: String?

    init(library: LibraryViewModel, fetcher: ArtistPictureFetching) {
        self.library = library
        // At most one Deezer request a second from the background.
        let deezer = DeezerArtistSource(fetcher: fetcher, spacing: Self.deezerSpacing)
        // No Commons source: the run builds its Commons candidates from the
        // identity search itself (`ArtistLookupRun`).
        run = ArtistLookupRun(
            info: ArtistInfoClient(fetcher: fetcher),
            pictures: ArtistPictureFinder(sources: [deezer], fetcher: fetcher, perArtist: Self.photoBudget),
            fetcher: fetcher, deezer: deezer)
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let offline = path.status != .satisfied
            Task { @MainActor [weak self] in self?.setOffline(offline) }
        }
        pathMonitor.start(queue: DispatchQueue(label: "cratedigger.artist-lookups.network", qos: .utility))
        settingObserver = NotificationCenter.default.addObserver(
            forName: Self.settingChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.settingDidChange() }
        }
    }

    deinit {
        pathMonitor.cancel()
        if let settingObserver { NotificationCenter.default.removeObserver(settingObserver) }
    }

    func start(after delay: Duration = ArtistLookupWorker.startDelay) {
        guard task == nil else { return }
        task = Task { await self.loop(after: delay) }
    }

    /// Something the order or the pauses depend on changed (the inspected
    /// or playing artist, the network): a worker that is idle or paused
    /// looks again now. A lookup in progress is left to finish, and a
    /// failure's back-off is waited out: waking it would hammer a service
    /// that has just said no.
    func wake() {
        guard napKind == .idle || napKind == .paused else { return }
        endNap()
    }

    // MARK: - The loop

    private func loop(after delay: Duration) async {
        await nap(delay, .start)
        while !Task.isCancelled, let library {
            if library.artistLookupPauses(offline: isOffline).isPaused || !library.artistMigrationSettled
                || (stoppedAtStore != nil && stoppedAtStore == library.artistProfileStoreKey) {
                // What landed since the last save is written before the wait.
                await library.flushArtistLookupSaves()
                await nap(Self.pausedRecheck, .paused)
                continue
            }
            guard let target = await library.nextBackgroundArtist(session: session) else {
                await library.flushArtistLookupSaves()
                await nap(Self.idleRecheck, .idle)
                continue
            }
            switch await library.lookUpInBackground(target, run: run, limit: Self.lookupLimit) {
            case .done(let photoTimedOut):
                session.succeeded(target.key, photoTimedOut: photoTimedOut)
                await nap(Self.between, .between)
            case .discarded:
                // The library, the switch or the store changed under it:
                // nothing was kept, and the pauses are looked at again.
                await nap(Self.between, .between)
            case .failed(let error):
                // Cancelled: the loop ends at its next check (after a breath,
                // so a stray cancellation can never spin it).
                guard let failure = session.failed(target.key, error) else {
                    await nap(Self.between, .between)
                    continue
                }
                if failure == .stopWorker { stoppedAtStore = library.artistProfileStoreKey }
                // The error's case only: its text can carry a path or a name.
                AppLog.library.notice("Background artist lookup failed (\(String(describing: failure), privacy: .public)); next in \(self.session.backoff.components.seconds, privacy: .public) s: \(LibraryViewModel.logCase(error), privacy: .public)")
                await nap(session.backoff, .backoff)
            }
        }
    }

    /// The switch turned off stops the lookup in progress (nothing of it is
    /// kept); turned on, the worker starts looking now.
    private func settingDidChange() {
        task?.cancel()
        task = nil
        endNap()
        start(after: .zero)
    }

    private func setOffline(_ offline: Bool) {
        guard offline != isOffline else { return }
        isOffline = offline
        if !offline { wake() }
    }

    // MARK: - Waiting

    /// Sleeps for `duration`, or until cancellation, or a `wake` when the
    /// nap is idle or paused.
    private func nap(_ duration: Duration, _ kind: NapKind) async {
        guard duration > .zero, !Task.isCancelled else { return }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                endNap()
                guard !Task.isCancelled else { return continuation.resume() }
                napKind = kind
                napContinuation = continuation
                napTimer = Task { [weak self] in
                    // A timer cancelled by `endNap` must not end the next nap.
                    do { try await Task.sleep(for: duration) } catch { return }
                    self?.endNap()
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.endNap() }
        }
    }

    private func endNap() {
        napKind = nil
        napTimer?.cancel()
        napTimer = nil
        let continuation = napContinuation
        napContinuation = nil
        continuation?.resume()
    }
}
