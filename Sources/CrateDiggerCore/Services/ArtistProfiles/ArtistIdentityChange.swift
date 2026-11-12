import Foundation

/// The owner settling who an artist is, from the artist page (spec §2 and
/// §4, Correcting a match). Each is a change to one profile, made through
/// `ArtistProfileStore.update`; none touches the owner's facts, the owner's
/// photos, an owner-picked default, `noPhoto` or `notOnIPod`.
extension ArtistProfile {
    /// "Is this them?": the owner picked this candidate. The identity is
    /// confirmed with no Wikidata id and no check date, so the next lookup
    /// (run at once by the page) fetches its facts by the id. An id the owner
    /// once said is "Not This Artist" is taken back. The photos stay: an
    /// unsettled artist's default came from the picture finder's own rule,
    /// not from an identity; the held candidates are dropped, to be found
    /// again for the confirmed artist. Picking the identity already
    /// confirmed changes nothing.
    public mutating func confirmIdentity(musicBrainzID: String) {
        if case .confirmed(let current, _) = identity, current == musicBrainzID { return }
        if case .confirmed = identity { discardIdentityData() }
        identity = .confirmed(musicBrainzID: musicBrainzID, wikidataID: nil)
        rejectedMusicBrainzIDs.removeAll { $0 == musicBrainzID }
        photoCandidates = []
        checkedAt = nil
    }

    /// "None of these": no lookups for this artist until Look Up Again. The
    /// candidates are not remembered as rejected ids, so Look Up Again may
    /// offer them again.
    public mutating func rejectCandidates() {
        identity = .rejected
        fetched = nil
    }

    /// "Not This Artist", on a confirmed artist only: its id is never
    /// confirmed again, the identity goes back to unknown (looked up again,
    /// so the page shows the other candidates), and what came with the old
    /// identity goes: its fetched facts and its Commons and Deezer photos.
    /// The owner's photos, their library folder's picture, a migrated photo
    /// and an owner-picked default stay; when the default goes, the first
    /// photo left takes over, as a default the owner has not picked.
    public mutating func rejectConfirmedIdentity() {
        guard case .confirmed(let id, _) = identity else { return }
        if !rejectedMusicBrainzIDs.contains(id) { rejectedMusicBrainzIDs.append(id) }
        identity = .unknown
        discardIdentityData()
        checkedAt = nil
    }

    /// Drops the fetched facts and the photos a confirmed identity brought.
    private mutating func discardIdentityData() {
        fetched = nil
        photoCandidates = []
        let ownerDefault = defaultPickedByOwner ? defaultPhoto : nil
        photos.removeAll { photo in
            (photo.source == .commons || photo.source == .deezer) && photo.hash != ownerDefault
        }
        if !photos.contains(where: { $0.hash == defaultPhoto }) {
            defaultPhoto = photos.first?.hash
            defaultPickedByOwner = false
        }
    }
}
