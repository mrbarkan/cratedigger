import Foundation

/// The owner settling who an artist is, from the artist page (spec §2 and
/// §4, Correcting a match). Each is a change to one profile, made through
/// `ArtistProfileStore.update`; none touches the owner's facts, the owner's
/// photos, an owner-picked default, `noPhoto` or `notOnIPod`.
extension ArtistProfile {
    /// "Is this them?", or an id pasted in the Edit sheet: the owner named
    /// who this is. The identity is confirmed with no Wikidata id and no
    /// check date, so the next lookup (run at once) fetches its facts by the
    /// id. An id the owner once said is "Not This Artist" is taken back.
    /// Whatever the identity was before (confirmed, uncertain, not found,
    /// rejected), what was found for the name goes (`discardIdentityData`):
    /// a Deezer or Commons photo found by the name alone may be of the very
    /// act the owner is correcting. Picking the identity already confirmed
    /// changes nothing.
    public mutating func confirmIdentity(musicBrainzID: String) {
        if case .confirmed(let current, _) = identity, current == musicBrainzID { return }
        discardIdentityData()
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

    /// Drops the fetched facts, the held candidates and the Deezer and
    /// Commons photos, found for the old identity or for the name alone. The
    /// owner's photos, the library folder's picture, migrated photos and an
    /// owner-picked default stay; when the default goes, the first photo
    /// left takes over, as a default the owner has not picked.
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
