import CryptoKit
import Foundation

/// What the owner has changed in the Artist Pictures sheet and not yet
/// applied, by folded key.
public enum ArtistPictureEdit: Hashable, Sendable {
    /// A picture the owner chose: an offered candidate, or a file of their own.
    /// `prepared` is the exact JPEG to write.
    case picked(prepared: Data, source: ArtistPictureSourceID, candidate: ArtistPictureCandidate?)
    /// "No Picture": remembered, so the finder never offers one again.
    case noPicture
    /// Forget what the store knows, so the finder may look again.
    case clear
}

/// One artist in the Artist Pictures sheet: what the player shows or would
/// get for them, and where that picture came from.
public struct ArtistPictureRow: Identifiable, Hashable, Sendable {
    public enum State: String, Sendable {
        /// The player already shows a picture (the owner's, or one CrateDigger wrote).
        case onDevice
        /// A picture is waiting in the store to be written.
        case ready
        /// Name matches were found but none is sure: the owner picks.
        case check
        /// Nothing known yet.
        case none
        /// The owner said No Picture.
        case rejected
        /// The player cannot match any file name to this name.
        case unnameable
    }

    /// The folded key (`PodBoxArtName.folded`); the name itself when it folds to nothing.
    public let id: String
    public let name: String, trackCount: Int
    public let state: State
    /// "DEVICE", "DISK", "DEEZER", "COMMONS", "PICKED", "CHECK", "NONE", "NO PICTURE".
    public let badge: String
    /// The device-relative file the player shows, for `.onDevice` (nil when
    /// the simulation cannot say which).
    public let devicePath: String?
    /// The candidates to pick from, for `.check`.
    public let candidates: [ArtistPictureCandidate]
    /// Who made the picture and under what licence, when its source says (Commons).
    public let credit: ArtistPictureCredit?

    /// Most tracks first, then by name. `uncertain` holds the candidates a
    /// Find Missing run offered this session, by folded key; `edits` are the
    /// sheet's unapplied changes, which win over the store.
    public static func rows(artists: [ArtistOnDevice], tree: DeviceArtTree, store: ArtistPictureStore,
                            uncertain: [String: [ArtistPictureCandidate]],
                            edits: [String: ArtistPictureEdit] = [:]) -> [ArtistPictureRow] {
        artists
            .sorted { ($0.trackCount, $1.name) > ($1.trackCount, $0.name) }
            .map { row(for: $0, tree: tree, store: store, uncertain: uncertain, edits: edits) }
    }

    /// Apply has something to write: at least one picture ready.
    public static func canApply(_ rows: [ArtistPictureRow]) -> Bool {
        rows.contains { $0.state == .ready }
    }

    /// The record an edit stores for `name`; nil for `.clear`, which removes
    /// the record instead. Picked and rejected records are the owner's word.
    public static func record(for edit: ArtistPictureEdit, name: String, now: Date) -> (ArtistPictureRecord, Data?)? {
        switch edit {
        case let .picked(prepared, source, candidate):
            return (ArtistPictureRecord(foldedKey: "", displayName: name, outcome: .found, source: source,
                                        sourceID: candidate?.sourceID,
                                        preparedHash: SHA256.hash(data: prepared).hexString,
                                        pickedByUser: true, checkedAt: now, credit: candidate?.credit),
                    prepared)
        case .noPicture:
            return (ArtistPictureRecord(foldedKey: "", displayName: name, outcome: .rejected, pickedByUser: true,
                                        checkedAt: now), nil)
        case .clear:
            return nil
        }
    }

    /// The badge for a stored or picked picture's source.
    static func badge(for source: ArtistPictureSourceID?, picked: Bool) -> String {
        if picked { return "PICKED" }
        switch source {
        case .libraryFolder?: return "DISK"
        case .deezer?: return "DEEZER"
        case .commons?: return "COMMONS"
        case .userFile?: return "PICKED"
        case .fanartTV?, .discogs?, .theAudioDB?, nil: return "READY"
        }
    }

    // MARK: - Private

    private static func row(for artist: ArtistOnDevice, tree: DeviceArtTree, store: ArtistPictureStore,
                            uncertain: [String: [ArtistPictureCandidate]],
                            edits: [String: ArtistPictureEdit]) -> ArtistPictureRow {
        let key = artist.foldedKey.isEmpty ? artist.name : artist.foldedKey
        func make(_ state: State, _ badge: String, path: String? = nil, candidates: [ArtistPictureCandidate] = [],
                  credit: ArtistPictureCredit? = nil) -> ArtistPictureRow {
            ArtistPictureRow(id: key, name: artist.name, trackCount: artist.trackCount, state: state, badge: badge,
                             devicePath: path, candidates: candidates, credit: credit)
        }

        guard PodBoxArtName.fileStem(for: artist.name) != nil else { return make(.unnameable, "NONE") }

        // What the player shows now outranks anything waiting: nothing would replace it.
        switch PodBoxArtLookup.artistPicture(for: artist.name, albumFolders: artist.albumFolders, tree: tree) {
        case .found(let path): return make(.onDevice, "DEVICE", path: path)
        case .uncertain: return make(.onDevice, "DEVICE")
        case .none: break
        }

        let edit = edits[key]
        switch edit {
        case let .picked(_, source, candidate)?:
            return make(.ready, badge(for: source, picked: true), credit: candidate?.credit)
        case .noPicture?:
            return make(.rejected, "NO PICTURE")
        case .clear?, nil:
            break
        }
        let record = edit == .clear ? nil : store.record(forName: artist.name)
        if let record {
            switch record.outcome {
            case .rejected:
                return make(.rejected, "NO PICTURE")
            case .found where store.preparedData(for: record) != nil:
                return make(.ready, badge(for: record.source, picked: record.pickedByUser), credit: record.credit)
            case .found, .notFound, .uncertain:
                break
            }
        }
        if let offered = uncertain[key], !offered.isEmpty {
            return make(.check, "CHECK", candidates: offered)
        }
        return make(.none, "NONE")
    }
}
