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

    /// Posted by Settings ▸ Integrations when the switch changes.
    nonisolated static let settingChanged = Notification.Name("CrateDiggerArtistLookupsChanged")

    private weak var library: LibraryViewModel?
    /// One long-lived run, so its spacing between Wikidata, Commons and image
    /// requests holds from one artist to the next.
    private let run: ArtistLookupRun
    private var task: Task<Void, Never>?
    private var napContinuation: CheckedContinuation<Void, Never>?
    private var napTimer: Task<Void, Never>?
    private let pathMonitor = NWPathMonitor()
    private var settingObserver: NSObjectProtocol?
    private(set) var isOffline = false
    /// Failed lookups in a row; a success sets it back to zero.
    private var failures = 0
    /// Folded keys whose answer could not be used: not asked again this session.
    private var skipped: Set<String> = []
    /// Folded keys of the priority artists already looked up this launch.
    private var priorityDone: Set<String> = []
    /// The store the worker stopped on (it could not be written), until
    /// another store is made.
    private var stoppedAtStore: String?

    init(library: LibraryViewModel, fetcher: ArtistPictureFetching) {
        self.library = library
        let deezer = DeezerArtistSource(fetcher: fetcher)
        // Commons asks MusicBrainz too, and gets the background lane through
        // `find(_:lane:)` like every other source.
        run = ArtistLookupRun(
            info: ArtistInfoClient(fetcher: fetcher),
            pictures: ArtistPictureFinder(sources: [deezer, CommonsArtistSource(fetcher: fetcher)], fetcher: fetcher),
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
    /// or playing artist, the network): a waiting worker looks again now.
    /// A lookup in progress is left to finish.
    func wake() {
        endNap()
    }

    // MARK: - The loop

    private func loop(after delay: Duration) async {
        await nap(delay)
        while !Task.isCancelled, let library {
            if library.artistLookupPauses(offline: isOffline).isPaused
                || (stoppedAtStore != nil && stoppedAtStore == library.artistProfileStoreKey) {
                await nap(Self.pausedRecheck)
                continue
            }
            guard let target = await library.nextBackgroundArtist(skipping: skipped, priorityDone: priorityDone) else {
                await nap(Self.idleRecheck)
                continue
            }
            switch await library.lookUpInBackground(target, run: run) {
            case .done:
                failures = 0
                priorityDone.insert(target.key)
                await nap(Self.between)
            case .discarded:
                // The library, the switch or the store changed under it:
                // nothing was kept, and the pauses are looked at again.
                await nap(Self.between)
            case .failed(let error):
                // Cancelled: the loop ends at its next check (after a breath,
                // so a stray cancellation can never spin it).
                guard let failure = ArtistLookupScheduler.failure(error) else {
                    await nap(Self.between)
                    continue
                }
                failures += 1
                switch failure {
                case .retryLater:
                    break
                case .skipArtist:
                    skipped.insert(target.key)
                    priorityDone.insert(target.key)
                case .stopWorker:
                    stoppedAtStore = library.artistProfileStoreKey
                }
                AppLog.library.notice("Background artist lookup failed (\(String(describing: failure), privacy: .public)); next in \(ArtistLookupScheduler.backoff(afterFailures: self.failures).components.seconds, privacy: .public) s: \(String(describing: error), privacy: .public)")
                await nap(ArtistLookupScheduler.backoff(afterFailures: failures))
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

    /// Sleeps for `duration`, or until `wake` or cancellation.
    private func nap(_ duration: Duration) async {
        guard duration > .zero, !Task.isCancelled else { return }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                endNap()
                guard !Task.isCancelled else { return continuation.resume() }
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
        napTimer?.cancel()
        napTimer = nil
        let continuation = napContinuation
        napContinuation = nil
        continuation?.resume()
    }
}
