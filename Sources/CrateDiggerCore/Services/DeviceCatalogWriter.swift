import Foundation

/// Every write to the saved device catalogs, in one place, so a whole-volume
/// scan that finishes late can never put back a catalog a transfer has
/// patched since (or one a RESCAN or FIX ART dropped).
///
/// A scan takes a token when it starts. A patch or a removal moves the key's
/// token on, and a scan's save is refused when its token is no longer the
/// current one: the scan may have walked the device before the write. The
/// check and the write share one lock, so nothing can slip in between.
/// Thread-safe; the file work is meant to run off the main actor.
public final class DeviceCatalogWriter: @unchecked Sendable {
    private let store: DeviceCatalogStore
    private let tokenLock = NSLock()
    private var tokens: [String: Int] = [:]
    /// Held for every write, with the token check inside it.
    private let writeLock = NSLock()

    public init(store: DeviceCatalogStore = DeviceCatalogStore()) {
        self.store = store
    }

    public func load(key: String) -> [LoadedTrack]? {
        store.load(key: key)
    }

    public func exists(key: String) -> Bool {
        store.exists(key: key)
    }

    /// Taken when a scan starts; hand it back to `saveScan`.
    public func scanToken(key: String) -> Int {
        tokenLock.withLock { tokens[key, default: 0] }
    }

    /// Whether a scan that started with `token` may still save.
    public func isCurrent(_ token: Int, key: String) -> Bool {
        scanToken(key: key) == token
    }

    /// Saves a scan's catalog unless the key was patched or removed after the
    /// scan started. Returns whether it saved.
    @discardableResult
    public func saveScan(_ tracks: [LoadedTrack], key: String, token: Int) -> Bool {
        writeLock.withLock {
            guard isCurrent(token, key: key) else { return false }
            store.save(tracks, key: key)
            return true
        }
    }

    /// `DeviceCatalogStore.patch`, returning the patched catalog (nil when
    /// none was saved). Refuses any scan already under way.
    public func patch(key: String, adding: [LoadedTrack], removingPaths: Set<String>) -> [LoadedTrack]? {
        writeLock.withLock {
            advance(key)
            guard let catalog = store.load(key: key) else { return nil }
            let patched = DeviceCatalogStore.patched(catalog, adding: adding, removingPaths: removingPaths)
            store.save(patched, key: key)
            return patched
        }
    }

    /// Drops the saved catalog, and refuses any scan already under way.
    public func remove(key: String) {
        writeLock.withLock {
            advance(key)
            store.remove(key: key)
        }
    }

    /// `DeviceCatalogStore.discardOlderFormats`, under the write lock. Run
    /// once at launch, before any catalog is read.
    @discardableResult
    public func discardOlderFormats() -> Int {
        writeLock.withLock { store.discardOlderFormats() }
    }

    private func advance(_ key: String) {
        tokenLock.withLock { tokens[key, default: 0] += 1 }
    }
}
