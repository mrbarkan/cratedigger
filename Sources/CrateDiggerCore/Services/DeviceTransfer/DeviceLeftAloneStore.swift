import Foundation

/// The albums the user chose to leave alone on each device, so they stop
/// coming back to the review sheet. One JSON file per device profile:
/// `<AppSupport>/CrateDigger/DeviceLeftAlone/<profileID>.json`. It belongs to
/// the device, not the library, so it lives beside the device's other state
/// rather than in the crates folder.
public struct DeviceLeftAloneStore {
    private let directory: URL
    private let fileManager: FileManager

    /// `directory` is the folder holding the per-device files; nil uses the
    /// one under Application Support.
    public init(directory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        if let directory {
            self.directory = directory
        } else {
            let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            self.directory = base.appendingPathComponent("CrateDigger/DeviceLeftAlone", isDirectory: true)
        }
    }

    /// Empty when nothing was left alone, or the file can't be read: a lost
    /// answer only means the album is asked about again.
    public func load(profileID: UUID) -> Set<DeviceAlbumIdentity> {
        guard let data = try? Data(contentsOf: url(for: profileID)) else { return [] }
        do {
            return Set(try JSONDecoder().decode([DeviceAlbumIdentity].self, from: data))
        } catch {
            AppLog.library.warning(
                "Could not read the albums left alone on \(profileID, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return []
        }
    }

    public func insert(_ ids: Set<DeviceAlbumIdentity>, profileID: UUID) {
        guard !ids.isEmpty else { return }
        save(load(profileID: profileID).union(ids), profileID: profileID)
    }

    public func remove(_ ids: Set<DeviceAlbumIdentity>, profileID: UUID) {
        guard !ids.isEmpty else { return }
        save(load(profileID: profileID).subtracting(ids), profileID: profileID)
    }

    /// Applies the review sheet's answers: a Leave it is remembered, any other
    /// answer forgets the album (the user changed their mind about one left
    /// alone before). Albums not answered keep whatever was remembered.
    ///
    /// `kinds` are the review's (`DeviceTransferReview.differenceKinds`). A
    /// Leave it for an album whose only difference is a taken name is not
    /// remembered: it says nothing about the album, and remembering it would
    /// silently leave alone a later real upgrade of it. Such an answer
    /// changes nothing stored.
    public func record(
        _ answers: [DeviceAlbumIdentity: DeviceAlbumDecision],
        kinds: [DeviceAlbumIdentity: DeviceDifferenceKind],
        profileID: UUID
    ) {
        let leave = Set(answers.filter { $0.value == .leave && kinds[$0.key] != .pathTaken }.keys)
        let other = Set(answers.filter { $0.value != .leave }.keys)
        guard !leave.isEmpty || !other.isEmpty else { return }
        let current = load(profileID: profileID)
        let updated = current.union(leave).subtracting(other)
        if updated != current { save(updated, profileID: profileID) }
    }

    /// Forget every album left alone on this device.
    public func clear(profileID: UUID) {
        try? fileManager.removeItem(at: url(for: profileID))
    }

    /// An empty set removes the file rather than writing `[]`. Failures are
    /// logged, not thrown: nothing a caller could do mid-transfer.
    private func save(_ ids: Set<DeviceAlbumIdentity>, profileID: UUID) {
        guard !ids.isEmpty else {
            clear(profileID: profileID)
            return
        }
        // Sorted so the file is stable between saves of the same set.
        let sorted = ids.sorted { ($0.artist, $0.album) < ($1.artist, $1.album) }
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(sorted).write(to: url(for: profileID), options: .atomic)
        } catch {
            AppLog.library.warning(
                "Could not save the albums left alone on \(profileID, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func url(for profileID: UUID) -> URL {
        directory.appendingPathComponent(profileID.uuidString).appendingPathExtension("json")
    }
}
