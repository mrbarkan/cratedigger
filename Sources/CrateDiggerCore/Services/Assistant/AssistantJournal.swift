import Foundation

/// One change the assistant made, kept so it can be undone. It records what
/// the change did rather than a copy of what was there before, so an undo
/// takes back the assistant's own work and leaves alone anything the user
/// changed afterwards by hand.
public struct AssistantChange: Codable, Sendable, Equatable, Identifiable {
    public struct CrateEdit: Codable, Sendable, Equatable {
        public var name: String
        /// The crate did not exist before this change.
        public var created: Bool
        public var added: [String]
        public var removed: [String]

        public init(name: String, created: Bool, added: [String], removed: [String]) {
            self.name = name
            self.created = created
            self.added = added
            self.removed = removed
        }
    }

    public struct PlaylistEdit: Codable, Sendable, Equatable {
        public var name: String
        /// The playlist's paths before, or nil when this change created it.
        public var before: [String]?
        public var after: [String]

        public init(name: String, before: [String]?, after: [String]) {
            self.name = name
            self.before = before
            self.after = after
        }
    }

    public struct TagEdit: Codable, Sendable, Equatable {
        public var trackID: UUID
        public var before: AssistantTagValues
        public var after: AssistantTagValues

        public init(trackID: UUID, before: AssistantTagValues, after: AssistantTagValues) {
            self.trackID = trackID
            self.before = before
            self.after = after
        }
    }

    public var id: UUID
    public var date: Date
    public var summary: String
    /// The crates folder the change was made in. An undo in another library
    /// would write into the wrong crates, so it is refused.
    public var libraryFolder: String
    public var crates: [CrateEdit]
    public var playlist: PlaylistEdit?
    public var addedStreamIDs: [String]
    public var tags: [TagEdit]

    public init(id: UUID = UUID(), date: Date = Date(), summary: String, libraryFolder: String,
                crates: [CrateEdit] = [], playlist: PlaylistEdit? = nil,
                addedStreamIDs: [String] = [], tags: [TagEdit] = []) {
        self.id = id
        self.date = date
        self.summary = summary
        self.libraryFolder = libraryFolder
        self.crates = crates
        self.playlist = playlist
        self.addedStreamIDs = addedStreamIDs
        self.tags = tags
    }
}

/// The assistant's undo history: newest last, at most `capacity` entries,
/// saved to disk on every change so an undo survives a relaunch.
public final class AssistantJournal {
    public static let capacity = 20

    public static var defaultURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("CrateDigger/assistant-journal.json")
    }

    public let fileURL: URL
    public private(set) var entries: [AssistantChange]

    /// An unreadable journal starts empty rather than failing the feature; the
    /// bad file is kept beside it, so nothing is lost by starting over.
    public init(fileURL: URL = AssistantJournal.defaultURL) {
        self.fileURL = fileURL
        guard let data = try? Data(contentsOf: fileURL) else {
            entries = []
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let decoded = try? decoder.decode([AssistantChange].self, from: data) {
            entries = decoded
        } else {
            try? FileManager.default.moveItem(at: fileURL, to: fileURL.appendingPathExtension("unreadable"))
            entries = []
        }
    }

    public var last: AssistantChange? { entries.last }

    public func append(_ change: AssistantChange) throws {
        entries.append(change)
        if entries.count > Self.capacity { entries.removeFirst(entries.count - Self.capacity) }
        try save()
    }

    /// Takes the newest entry off the journal.
    @discardableResult
    public func removeLast() throws -> AssistantChange? {
        guard let last = entries.popLast() else { return nil }
        try save()
        return last
    }

    public func removeAll() throws {
        entries.removeAll()
        try save()
    }

    private func save() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try encoder.encode(entries).write(to: fileURL, options: .atomic)
    }
}

/// Tags to write to one track: the values, and which of them to write.
public struct AssistantTagWrite: Equatable, Sendable {
    public var values: AssistantTagValues
    public var fields: [String]

    public init(values: AssistantTagValues, fields: [String]) {
        self.values = values
        self.fields = fields
    }
}

/// What undoing one change means against the library as it is now.
public struct AssistantUndoPlan: Equatable, Sendable {
    /// Crates to rewrite, with their whole new membership.
    public var crateMemberships: [(name: String, paths: [String])]
    /// Crates the change created that hold nothing but what it put there.
    public var cratesToTrash: [String]
    public var playlistToWrite: (name: String, paths: [String])?
    public var playlistToTrash: String?
    public var streamIDsToRemove: [String]
    /// Per track, the tags to write back and which fields to write.
    public var tagRestores: [UUID: AssistantTagWrite]
    /// Things the undo left alone, for the reply.
    public var notes: [String]

    public static func == (lhs: AssistantUndoPlan, rhs: AssistantUndoPlan) -> Bool {
        lhs.crateMemberships.map(\.name) == rhs.crateMemberships.map(\.name)
            && lhs.crateMemberships.map(\.paths) == rhs.crateMemberships.map(\.paths)
            && lhs.cratesToTrash == rhs.cratesToTrash
            && lhs.playlistToWrite?.name == rhs.playlistToWrite?.name
            && lhs.playlistToWrite?.paths == rhs.playlistToWrite?.paths
            && lhs.playlistToTrash == rhs.playlistToTrash
            && lhs.streamIDsToRemove == rhs.streamIDsToRemove
            && lhs.tagRestores == rhs.tagRestores
            && lhs.notes == rhs.notes
    }

    /// Plans the undo of `change` against `library`.
    ///
    /// - A crate gives back what the change added and takes back what it
    ///   removed. A crate the change created goes to the Trash only when it
    ///   still holds nothing else; one the user has since added to is kept.
    /// - A playlist goes back to what it was, or to the Trash if the change
    ///   made it, unless the user has edited it since, in which case it is
    ///   left alone and the reply says so.
    /// - A tag goes back only where it still reads what the change wrote.
    public static func plan(undoing change: AssistantChange, in library: AssistantLibrary) -> AssistantUndoPlan {
        var plan = AssistantUndoPlan(crateMemberships: [], cratesToTrash: [], playlistToWrite: nil,
                                     playlistToTrash: nil, streamIDsToRemove: [], tagRestores: [:], notes: [])

        for edit in change.crates {
            guard let name = library.crateName(matching: edit.name), let current = library.crates[name] else {
                plan.notes.append("The crate \"\(edit.name)\" is gone, so there was nothing to undo there.")
                continue
            }
            let added = Set(edit.added)
            var paths = current.filter { !added.contains($0) }
            for path in edit.removed where !paths.contains(path) { paths.append(path) }
            if edit.created && paths.isEmpty {
                plan.cratesToTrash.append(name)
            } else {
                if edit.created {
                    plan.notes.append("Kept \"\(name)\": it has tracks the assistant didn't put there.")
                }
                if paths != current { plan.crateMemberships.append((name, paths)) }
            }
        }

        if let edit = change.playlist {
            let current = library.playlist(matching: edit.name)
            let currentPaths = current?.trackURLs.map { TrackStore.key(for: $0) }
            if current == nil {
                plan.notes.append("The playlist \"\(edit.name)\" is gone, so there was nothing to undo there.")
            } else if currentPaths != edit.after {
                plan.notes.append("Left the playlist \"\(edit.name)\" alone: it was changed after the assistant made it.")
            } else if let before = edit.before {
                plan.playlistToWrite = (current!.name, before)
            } else {
                plan.playlistToTrash = current!.name
            }
        }

        let existingStreams = Set(library.streams.map(\.id))
        plan.streamIDsToRemove = change.addedStreamIDs.filter(existingStreams.contains)

        var skippedTags = 0
        var unremovable = 0
        for edit in change.tags {
            guard let track = library.track(id: edit.trackID) else { skippedTags += 1; continue }
            var restored = track.tags
            var fields: [String] = []
            for field in edit.after.changedFields(from: edit.before) {
                guard track.tags.display(field) == edit.after.display(field) else {
                    skippedTags += 1
                    continue
                }
                // The change added a number where there was none, and the tag
                // writer can't take one away.
                if edit.before.display(field) == nil, !AssistantTagValues.removableFields.contains(field) {
                    unremovable += 1
                    continue
                }
                restored.copy(field, from: edit.before)
                fields.append(field)
            }
            if !fields.isEmpty { plan.tagRestores[edit.trackID] = AssistantTagWrite(values: restored, fields: fields) }
        }
        if skippedTags > 0 {
            plan.notes.append("Left \(skippedTags) tag\(skippedTags == 1 ? "" : "s") alone: changed again since, or the track is gone.")
        }
        if unremovable > 0 {
            plan.notes.append("Couldn't remove \(unremovable) number\(unremovable == 1 ? "" : "s") (year, track or disc) that the change added: CrateDigger can change those tags but not delete them.")
        }
        return plan
    }
}
