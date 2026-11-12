import Foundation

/// Decides who an artist is on MusicBrainz, by the artist picture finder's
/// own match rule (`ArtistPictureMatcher`): a candidate counts only when its
/// name folds equal to ours (`PodBoxArtName.matches`), and it is confident
/// only when its release-group titles share telling titles with the
/// library's album titles, brackets stripped and folded, ignoring
/// self-titled, numbered and generic titles ("Greatest Hits", "Demo", "III"),
/// which many acts of one name share.
///
/// One shared title is enough when only one artist has the name; when more
/// than one does, a candidate needs two, because one title in common between
/// two acts of one name is a coincidence that happens.
///
/// Exactly one confident candidate, not rejected by the owner, is
/// `.confirmed`, unless a candidate the owner rejected is confident on the
/// same evidence: then the evidence has been shown wrong once and the page
/// asks again. No name match left at all is `.notFound`. Anything else (two
/// confident, or name matches with nothing to tell them apart) is
/// `.uncertain`, with the name matches kept for the page to ask about.
public enum ArtistIdentityMatcher {
    /// How many candidates an uncertain record keeps, the finder's limit.
    public static let maximumUncertain = ArtistPictureFinder.maximumUncertain

    /// `rejected` are MusicBrainz ids the owner said are not this artist.
    /// The confirmed identity carries no Wikidata id: the lookup of the
    /// winning candidate brings it.
    public static func decide(name: String, libraryAlbumTitles: [String],
                              candidates: [(ArtistIdentityCandidate, releaseGroupTitles: [String])],
                              rejected: [String]) -> ArtistProfile.Identity {
        let rejected = Set(rejected)
        let named = candidates.filter { PodBoxArtName.matches($0.0.name, name) }
        let required = named.count > 1 ? 2 : 1
        let scored = named.map { pair -> (candidate: ArtistIdentityCandidate, confident: Bool, rejected: Bool) in
            var candidate = pair.0
            candidate.releaseTitles = pair.releaseGroupTitles
            let shared = ArtistPictureMatcher.sharedTellingTitles(pair.releaseGroupTitles, with: libraryAlbumTitles,
                                                                  name: name)
            return (candidate, shared >= required, rejected.contains(candidate.musicBrainzID))
        }
        let kept = scored.filter { !$0.rejected }
        guard !kept.isEmpty else { return .notFound }
        let confident = kept.filter(\.confident).map(\.candidate)
        let rejectedWasConfident = scored.contains { $0.rejected && $0.confident }
        if confident.count == 1, !rejectedWasConfident {
            return .confirmed(musicBrainzID: confident[0].musicBrainzID, wikidataID: nil)
        }
        let held = confident + kept.filter { !$0.confident }.map(\.candidate)
        return .uncertain(Array(held.prefix(maximumUncertain)))
    }
}
