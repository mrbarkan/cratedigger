import Foundation

/// Persistence for the user's album version groups. Stores the list as a small
/// JSON blob in `PreferencesStore` (app-global config, like `StreamStore` — not a
/// per-folder `.cdlib`). Corrupt or missing data reads as an empty list. The user's
/// audio files are never touched; a group is purely an overlay.
public final class AlbumGroupStore {
    private let prefs: PreferencesStore
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(prefs: PreferencesStore = .shared) {
        self.prefs = prefs
    }

    public func all() -> [AlbumGroup] {
        guard let data = prefs.albumGroupsData else { return [] }
        return (try? decoder.decode([AlbumGroup].self, from: data)) ?? []
    }

    public func save(_ groups: [AlbumGroup]) {
        if groups.isEmpty {
            prefs.albumGroupsData = nil
        } else {
            prefs.albumGroupsData = try? encoder.encode(groups)
        }
    }

    /// Insert or replace a group by id; returns the new list.
    @discardableResult
    public func upsert(_ group: AlbumGroup) -> [AlbumGroup] {
        var list = all()
        if let i = list.firstIndex(where: { $0.id == group.id }) {
            list[i] = group
        } else {
            list.append(group)
        }
        save(list)
        return list
    }

    @discardableResult
    public func remove(id: String) -> [AlbumGroup] {
        let list = all().filter { $0.id != id }
        save(list)
        return list
    }
}
