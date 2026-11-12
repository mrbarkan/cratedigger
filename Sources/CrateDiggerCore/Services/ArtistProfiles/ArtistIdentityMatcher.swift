import Foundation

/// Decides who an artist is on MusicBrainz, by the artist picture finder's
/// own match rule (`ArtistPictureMatcher`): a candidate counts only when its
/// name folds equal to ours (`PodBoxArtName.matches`), and it is confident
/// only when one of its release-group titles equals one of the library's
/// album titles, brackets stripped and folded, ignoring self-titled and
/// generic titles ("Greatest Hits", "Live"), which many acts of one name share.
///
/// Exactly one confident candidate, not rejected by the owner, is
/// `.confirmed`. No name match at all is `.notFound`. Anything else (two
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
        let named = candidates.filter { !rejected.contains($0.0.musicBrainzID) && PodBoxArtName.matches($0.0.name, name) }
            .map { pair -> (candidate: ArtistIdentityCandidate, confident: Bool) in
                var candidate = pair.0
                candidate.releaseTitles = pair.releaseGroupTitles
                let confident = ArtistPictureMatcher.sharesTellingTitle(pair.releaseGroupTitles,
                                                                        with: libraryAlbumTitles, name: name)
                return (candidate, confident)
            }
        guard !named.isEmpty else { return .notFound }
        let confident = named.filter(\.confident).map(\.candidate)
        if confident.count == 1 {
            return .confirmed(musicBrainzID: confident[0].musicBrainzID, wikidataID: nil)
        }
        let held = confident + named.filter { !$0.confident }.map(\.candidate)
        return .uncertain(Array(held.prefix(maximumUncertain)))
    }
}
