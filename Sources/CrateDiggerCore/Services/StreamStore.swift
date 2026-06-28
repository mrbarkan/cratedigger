import Foundation

/// Persistence for the user's radio/stream sources. Stores the list as a small
/// JSON blob in `PreferencesStore` (app-global config — unlike crates, which are
/// per-folder `.cdlib` files). Corrupt or missing data reads as an empty list.
public final class StreamStore {
    private let prefs: PreferencesStore
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(prefs: PreferencesStore = .shared) {
        self.prefs = prefs
    }

    public func all() -> [StreamSource] {
        guard let data = prefs.streamSourcesData else { return [] }
        return (try? decoder.decode([StreamSource].self, from: data)) ?? []
    }

    public func save(_ streams: [StreamSource]) {
        if streams.isEmpty {
            prefs.streamSourcesData = nil
        } else {
            prefs.streamSourcesData = try? encoder.encode(streams)
        }
    }

    /// Prepends so the newest source shows first (matches the v7 "add to top" behaviour).
    @discardableResult
    public func add(_ stream: StreamSource) -> [StreamSource] {
        var list = all()
        list.removeAll { $0.id == stream.id }
        list.insert(stream, at: 0)
        save(list)
        return list
    }

    @discardableResult
    public func remove(id: String) -> [StreamSource] {
        let list = all().filter { $0.id != id }
        save(list)
        return list
    }

    /// Distinct channel names in first-seen order (for sidebar grouping).
    public func channels() -> [String] {
        var seen = Set<String>()
        return all().map(\.channel).filter { seen.insert($0).inserted }
    }

    /// Channels that have at least one live stream (sidebar shows a LIVE badge).
    public func liveChannels() -> Set<String> {
        Set(all().filter(\.isLive).map(\.channel))
    }
}
