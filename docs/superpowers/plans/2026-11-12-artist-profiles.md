# Artist Profiles Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Selecting an artist shows an artist page in the inspector (default portrait, facts, Wikipedia bio, members, genres, library and listening stats), filled in by a silent background lookup, editable by the owner, with any number of photos, an owner-chosen default, and an artist photo viewer; the default photo is also what goes to a PodBox iPod.

**Architecture:** Core gains an `ArtistProfiles/` folder: the profile model and store (`library.cdartistinfo` + an `ArtistPhotos` folder in the Crates Index Folder), parsers and a fetch client for MusicBrainz / Wikidata / Wikipedia, an identity matcher, a background lookup scheduler, per-artist library stats, and the rule for when the inspector shows the artist page. The app wires a `LibraryViewModel+ArtistProfiles` extension, an inspector artist page, an Edit Artist sheet, an artist photo viewer built on the album artwork viewer, and points the existing PodBox picture planner and Artist Pictures sheet at profiles.

**Tech Stack:** Swift 5.9 SwiftPM, SwiftUI + AppKit, XCTest via `scripts/test.sh`.

**Spec:** `docs/superpowers/specs/2026-11-12-artist-profiles-design.md` (read it before any task; it is the authority where this plan is silent).

## Global Constraints

- Work only in `/Volumes/EX_3/Code/CrateDigger/.claude/worktrees/artist-profiles` (branch `feat/artist-profiles`, cut from `v2.3`). Never push, tag or bump versions.
- A real iPod is mounted at `/Volumes/IPOD`. Never write, rename or delete anything under `/Volumes` outside this repo. Device writes go only through `DeviceFileExecutor`; the door lint (`DeviceWriteDoorLintTests`) must stay green.
- App launch rule: never launch `.build/debug/CrateDiggerApp` itself. Only a renamed copy of the binary (so its defaults go to a scratch domain) with `CFFIXED_USER_HOME` and `CRATEDIGGER_CRATES_DIR` both set to scratch folders on the same command line; kill it and delete the scratch domain afterwards. If that isolation cannot be guaranteed, do not launch.
- Build `swift build`; test `scripts/test.sh --filter <Class>`; full `scripts/test.sh` green before each commit. Commit messages end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Decidable logic in Core with XCTests; the view model only wires.
- All network code behind protocols with fakes; tests never touch the network. Requests use the app's existing User-Agent and send only artist names and MusicBrainz / Wikidata ids.
- Every MusicBrainz request goes through `MusicBrainzGate`; background requests use its background lane (Task 4).
- No image decoding, store I/O or library walk on the main actor.
- Image bytes never inside an index file. Fetched photos capped at 1,600 px long side; owner photos refused over `ArtistPictureImage.maximumSourceBytes` (32 MB) or `maximumSourceArea` (50 MP).
- Every writer of the profile store or `ArtistPhotos` starts with `guard !refuseWhileLibraryDisconnected()`.
- Owner-entered fields, owner photos, `defaultPickedByOwner`, `noPhoto`, `notOnIPod` and `rejectedPhotoSources` are never changed by a lookup.
- Wikipedia text always shows "From Wikipedia, CC BY-SA 4.0" with a link to the article.
- Sheets and the viewer present from the root (`presentationHostViewController` / `LibraryPresentations`), compact-player safe. Carbon theming, `CarbonMotion`, no em dashes in user-facing copy.
- CHANGELOG lines go under the heading the PodBox lines are under (moved at press time).

## Review Focus

1. Artists with the same name as another act ("Boston", "Air") or a generic name: never confirmed automatically, page asks. Test in Task 3 (`testTwoSameNamedArtistsStayUncertain`).
2. "Various Artists", "Unknown Artist", empty names and names that fold to an empty key: no lookup, no page beyond library stats. Test in Task 5 (`testVariousAndUnknownAreNeverLookedUp`).
3. A 2,000-artist library while the owner runs FIX TAGS: foreground MusicBrainz requests never wait behind background ones. Test in Task 4 (`testForegroundOvertakesQueuedBackground`).
4. Owner edits, then a 180-day refresh or Look Up Again: nothing the owner set changes. Test in Task 1 (`testFetchedUpdateNeverTouchesOwnerFields`) and Task 5 (`testRefreshKeepsOwnerChoices`).
5. Library drive unplugged with the inspector on an artist: page shows from the copy, photos show the placeholder, every edit is refused with the existing disconnected message. Test in Task 1 (`testMissingPhotoFileReadsAsUnavailable`) and by the guard in Task 8.

---

### Task 1: Profile model and store

**Files:**
- Create: `Sources/CrateDiggerCore/Services/ArtistProfiles/ArtistProfile.swift`, `Sources/CrateDiggerCore/Services/ArtistProfiles/ArtistProfileStore.swift`
- Modify: `Sources/CrateDiggerCore/Services/LibraryIndexCopy.swift` (`LibraryIndexFiles.extensions` adds `"cdartistinfo"`)
- Test: `Tests/CrateDiggerCoreTests/ArtistProfileStoreTests.swift`

**Interfaces — Produces:**

```swift
public struct ArtistFacts: Codable, Hashable, Sendable {
    public var kind: String?            // "Person", "Group", "Orchestra", "Choir", other MB types
    public var origin: String?          // "Bristol, England"
    public var begin: String?, end: String?   // "1991", nil = to now
    public var bio: String?
    public var bioSourceURL: URL?       // set only for fetched Wikipedia text
    public var members: [ArtistMember]?
    public var genres: [String]?
    public var links: [ArtistLink]?
}
public struct ArtistMember: Codable, Hashable, Sendable { public var name: String; public var begin: String?; public var end: String?; public var isCurrent: Bool }
public struct ArtistLink: Codable, Hashable, Sendable { public enum Kind: String, Codable, Sendable { case musicBrainz, wikipedia, other }; public var kind: Kind; public var url: URL }

public struct ArtistPhoto: Codable, Hashable, Sendable {
    public enum Source: String, Codable, Sendable { case owner, library, deezer, commons, migrated }
    public var hash: String; public var source: Source; public var sourceID: String?
    public var credit: ArtistPictureCredit?; public var pixelWidth: Int; public var pixelHeight: Int; public var added: Date
    public var replaceFromURL: URL?     // migrated 300 px photo awaiting its original
}

public struct ArtistProfile: Codable, Hashable, Sendable {
    public enum Identity: Codable, Hashable, Sendable {
        case unknown, confirmed(musicBrainzID: String, wikidataID: String?), uncertain([ArtistIdentityCandidate]),
             notFound, rejected
    }
    public var foldedKey: String; public var displayName: String
    public var identity: Identity; public var rejectedMusicBrainzIDs: [String]
    public var fetched: ArtistFacts?; public var owner: ArtistFacts?
    public var photos: [ArtistPhoto]; public var photoCandidates: [ArtistPictureRecord.HeldCandidate]
    public var rejectedPhotoSources: [String]          // "<source>:<sourceID>"
    public var defaultPhoto: String?; public var defaultPickedByOwner: Bool
    public var noPhoto: Bool; public var notOnIPod: Bool
    public var checkedAt: Date?
    public var facts: ArtistFacts { get }   // owner over fetched, field by field
    public var defaultPhotoRef: ArtistPhoto? { get }   // nil when noPhoto
}
public struct ArtistIdentityCandidate: Codable, Hashable, Sendable {
    public var musicBrainzID: String; public var name: String; public var disambiguation: String?
    public var origin: String?; public var releaseTitles: [String]
}

public final class ArtistProfileStore: @unchecked Sendable {   // NSLock inside, like ArtistPictureStore
    public static let fileName = "library.cdartistinfo", photosFolder = "ArtistPhotos"
    public init(indexDirectory: URL, fileManager: FileManager = .default)
    public func profile(forName name: String) -> ArtistProfile?
    public func allProfiles() -> [ArtistProfile]
    public func update(name: String, _ change: (inout ArtistProfile) -> Void)     // creates when missing
    public func applyFetched(name: String, facts: ArtistFacts?, identity: ArtistProfile.Identity, at: Date)
    public func addPhoto(name: String, data: Data, source: ArtistPhoto.Source, sourceID: String?, credit: ArtistPictureCredit?) throws -> ArtistPhoto
    public func removePhoto(name: String, hash: String)
    public func setDefault(name: String, hash: String)           // owner action
    public func photoData(hash: String) -> Data?
    public func photoURL(hash: String) -> URL
    public func save() throws
}
```

Rules pinned here: `facts` merges per field (owner non-nil wins; an owner empty string means "cleared by owner" and shows nothing); `applyFetched` replaces only `fetched`, `identity`, `checkedAt`; `addPhoto` stores bytes at `<index>/ArtistPhotos/<sha256>.<jpg|png>` (fetched sources resized to 1,600 px long side, re-encoded JPEG 0.85; owner kept as given within the caps, else throws), dedups by hash, appends; when `defaultPhoto` is nil the first photo becomes default without setting `defaultPickedByOwner`; `removePhoto` adds `source:sourceID` to `rejectedPhotoSources` for non-owner photos, deletes the file only when no profile references the hash, and when the removed photo was the default picks the next photo and clears `defaultPickedByOwner`; `setDefault` sets `defaultPickedByOwner = true`; key is `PodBoxArtName.folded(name)`; empty key → `update` is a no-op. File decoding is lenient (unknown fields ignored, one bad record does not lose the others); only file-not-found reads as empty, any other read error makes `save()` throw rather than overwrite.

- [ ] **Step 1: Failing tests:** `testOwnerFieldsWinFieldByField`, `testOwnerEmptyStringClearsField`, `testFetchedUpdateNeverTouchesOwnerFields`, `testAddPhotoStoresOncePerHash`, `testFetchedPhotoIsCappedAt1600`, `testOwnerPhotoOverCapsIsRefused`, `testFirstPhotoBecomesDefaultNotPicked`, `testSetDefaultMarksPickedByOwner`, `testRemovingDefaultPicksNextAndClearsPicked`, `testRemovedFetchedPhotoIsRemembered`, `testPhotoFileKeptWhileAnotherProfileUsesIt`, `testNoPhotoHidesDefaultRef`, `testRoundTripAndLenientDecode`, `testUnreadableFileBlocksSave`, `testEmptyKeyIsIgnored`, `testMissingPhotoFileReadsAsUnavailable` (`photoData` nil, profile intact), `testIndexFilesIncludeArtistInfo`.
- [ ] **Step 2:** `scripts/test.sh --filter ArtistProfileStoreTests` fails (types missing).
- [ ] **Step 3:** Implement the two files and the extension entry.
- [ ] **Step 4:** Filter passes; full suite passes.
- [ ] **Step 5:** Commit `feat(artists): artist profiles and their photos, stored with the library`.

### Task 2: Migration from the picture store

**Files:**
- Create: `Sources/CrateDiggerCore/Services/ArtistProfiles/ArtistProfileMigration.swift`
- Test: `Tests/CrateDiggerCoreTests/ArtistProfileMigrationTests.swift`

**Interfaces — Consumes:** Task 1; `ArtistPictureStore` (`allRecords`, `preparedData(for:)`). **Produces:**

```swift
public enum ArtistProfileMigration {
    /// Runs once: returns false when there was nothing to migrate or it already ran.
    @discardableResult
    public static func migrate(pictures: ArtistPictureStore, into profiles: ArtistProfileStore,
                               indexDirectory: URL, fileManager: FileManager = .default) throws -> Bool
}
```

Rules (spec §3): every record with prepared bytes → a photo of source `.migrated` and the default; `pickedByUser` → `defaultPickedByOwner = true`; `replaceFromURL` set from the record's held/source URL when the source is `.deezer` or `.commons` (resolve the candidate URL the record kept; nil otherwise); `.rejected` records → `notOnIPod = true`; `candidates` → `photoCandidates`; `credit` kept. After a successful `profiles.save()`, rename `library.cdartists` → `library.cdartists.bak` (never delete). A second call returns false and changes nothing. A failure leaves `library.cdartists` in place.

- [ ] **Step 1: Failing tests:** `testPickedRecordBecomesOwnerDefault`, `testFoundRecordBecomesPlainDefault`, `testRejectedBecomesNotOnIPod`, `testCandidatesAndCreditCarryOver`, `testDeezerAndCommonsGetReplaceURL`, `testOldFileRenamedToBak`, `testSecondRunDoesNothing`, `testSaveFailureKeepsOldFile`.
- [ ] **Step 2–4:** red, implement, green (filter, then full suite).
- [ ] **Step 5:** Commit `feat(artists): carry the iPod's artist pictures into profiles`.

### Task 3: Fetching facts and matching the identity

**Files:**
- Create: `Sources/CrateDiggerCore/Services/ArtistProfiles/ArtistInfoParsers.swift`, `ArtistInfoClient.swift`, `ArtistIdentityMatcher.swift`
- Test: `Tests/CrateDiggerCoreTests/ArtistInfoParsersTests.swift`, `ArtistIdentityMatcherTests.swift`, `ArtistInfoClientTests.swift` (JSON fixtures as literal strings in the tests)

**Interfaces — Consumes:** `ArtistPictureFetching` (the existing fetcher protocol with its HTTPS host allowlist; extend the allowlist with `*.wikipedia.org`), `MusicBrainzGate`, `CommonsArtistParser`. **Produces:**

```swift
public enum ArtistInfoParsers {
    public static func searchCandidates(_ data: Data) throws -> [ArtistIdentityCandidate]   // /ws/2/artist?query=
    public static func artistDetail(_ data: Data) throws -> (facts: ArtistFacts, wikidataID: String?, releaseGroupTitles: [String])
        // /ws/2/artist/<id>?inc=url-rels+artist-rels+genres+release-groups&fmt=json
    public static func wikipediaTitles(fromEntity data: Data, id: String) throws -> [String: String]  // "enwiki": "Massive Attack"
    public static func summary(_ data: Data) throws -> (extract: String, pageURL: URL)?            // REST page/summary
    public static func wikipediaChoice(sitelinks: [String: String], preferredLanguages: [String]) -> (language: String, title: String)?
}
public protocol ArtistInfoFetching: Sendable {
    func candidates(for name: String, lane: MusicBrainzGate.Lane) async throws -> [ArtistIdentityCandidate]
    func detail(musicBrainzID: String, lane: MusicBrainzGate.Lane) async throws -> (facts: ArtistFacts, wikidataID: String?, releaseGroupTitles: [String])
    func bio(wikidataID: String, preferredLanguages: [String]) async throws -> (extract: String, pageURL: URL)?
}
public struct ArtistInfoClient: ArtistInfoFetching { public init(fetcher: ArtistPictureFetching, gate: MusicBrainzGate = .shared) }
public enum ArtistIdentityMatcher {
    public static func decide(name: String, libraryAlbumTitles: [String],
                              candidates: [(ArtistIdentityCandidate, releaseGroupTitles: [String])],
                              rejected: [String]) -> ArtistProfile.Identity
}
```

Rules: kind from MB `type`; origin = `area.name` then `begin-area` country name, joined ", "; begin/end = year part of `life-span`; members from `artist-rels` of type "member of band" (backward direction), `isCurrent` = no `end`, sorted current first; genres = top five `genres` by count; links: MusicBrainz page always, Wikipedia page when a bio was found. Wikipedia language: first of the preferred languages (from `Locale.preferredLanguages`, language code only) that has a sitelink, else `enwiki`, else nil; summary extract trimmed to the lead paragraph; missing page → nil, not an error. Matching reuses `ArtistPictureMatcher`'s rule: fold-equal name (`PodBoxArtName.matches`) plus at least one release-group title equal (folded, brackets stripped) to a library album title, ignoring self-titled and the generic titles list the finder already has; exactly one confident non-rejected candidate → `.confirmed`; none name-equal → `.notFound`; otherwise `.uncertain` with up to five name-equal candidates. Errors: transport, 5xx and 429 propagate as the finder's existing run-stopping error type, never mapped to notFound.

- [ ] **Step 1: Failing tests:** parsers: `testDetailParsesKindOriginYearsMembersGenresLinks`, `testPersonWithoutEndReadsToNow`, `testGenresTopFive`, `testSitelinksAndLanguageChoice` (preferred `["pt","en"]` with ptwiki → pt; only enwiki → en; none → nil), `testSummaryLeadParagraph`, `testMissingSummaryIsNil`; matcher: `testOneConfidentIsConfirmed`, `testTwoSameNamedArtistsStayUncertain`, `testSelfTitledAloneIsNotEnough`, `testNoNameMatchIsNotFound`, `testRejectedIDIsSkipped`; client: `testEveryMusicBrainzCallWaitsOnTheGateInItsLane`, `testOnlyNamesAndIDsLeaveTheMachine` (inspect fake fetcher URLs), `testServerErrorIsNotNotFound`.
- [ ] **Step 2–4:** red, implement, green.
- [ ] **Step 5:** Commit `feat(artists): look up who an artist is, and their bio`.

### Task 4: MusicBrainz gate background lane

**Files:**
- Modify: `Sources/CrateDiggerCore/Services/MusicBrainzGate.swift`
- Test: `Tests/CrateDiggerCoreTests/MusicBrainzGateTests.swift` (create if absent)

**Produces:** `public enum Lane: Sendable { case foreground, background }`; `public func wait(lane: Lane = .foreground) async throws`. Existing `wait()` callers stay foreground unchanged. A background waiter is released only when no foreground waiter is queued at its slot time; a foreground waiter arriving while background waiters queue goes first; the 1-per-interval spacing and `holdOff` apply to both lanes; cancellation of a background waiter frees its place.

- [ ] **Step 1: Failing tests** (60 ms gate): `testForegroundOvertakesQueuedBackground`, `testBackgroundRunsWhenNoForegroundWaits`, `testSpacingHoldsAcrossLanes`, `testCancelledBackgroundWaiterFreesItsPlace`, `testExistingWaitIsForeground`.
- [ ] **Step 2–4:** red, implement, green; check no existing caller's test slowed.
- [ ] **Step 5:** Commit `feat(musicbrainz): a background lane that never makes a lookup you started wait`.

### Task 5: The background lookup scheduler

**Files:**
- Create: `Sources/CrateDiggerCore/Services/ArtistProfiles/ArtistLookupScheduler.swift`, `ArtistLookupRun.swift`
- Test: `Tests/CrateDiggerCoreTests/ArtistLookupSchedulerTests.swift`, `ArtistLookupRunTests.swift`

**Interfaces — Consumes:** Tasks 1, 3, 4; `ArtistPictureFinder` (sources library/Deezer/Commons). **Produces:**

```swift
public struct ArtistLookupScheduler: Sendable {
    public static let confirmedRefresh: TimeInterval = 180 * 86_400
    public static let notFoundRetry: TimeInterval = ArtistPictureRecord.notFoundLifetime   // 30 days
    public init()
    /// Artists due for a lookup, most tracks first, with `priority` names first.
    public func due(artists: [(name: String, trackCount: Int)], profiles: (String) -> ArtistProfile?,
                    priority: [String], now: Date) -> [String]
    public static func isLookedUp(_ name: String) -> Bool    // false for Various Artists, Unknown Artist, empty, empty key
}
public struct ArtistLookupPauses: Equatable, Sendable {
    public var disabled, scanning, transferring, hidden, lowPower, offline, libraryDisconnected: Bool
    public var isPaused: Bool { get }
}
public struct ArtistLookupRun: Sendable {
    public init(info: ArtistInfoFetching, pictures: ArtistPictureFinder, fetcher: ArtistPictureFetching)
    /// One artist: identity, facts, bio, and a default photo when the profile has none it may keep.
    public func lookUp(name: String, libraryAlbumTitles: [String], libraryPicture: URL?,
                       existing: ArtistProfile?, lane: MusicBrainzGate.Lane, now: Date) async throws -> ArtistLookupResult
}
public struct ArtistLookupResult: Sendable {
    public var identity: ArtistProfile.Identity; public var facts: ArtistFacts?
    public var defaultPhoto: (data: Data, source: ArtistPhoto.Source, sourceID: String?, credit: ArtistPictureCredit?)?
    public var photoCandidates: [ArtistPictureRecord.HeldCandidate]
    public var replacementForMigrated: (hash: String, data: Data)?
}
```

Rules (spec §4): due = never checked; confirmed older than 180 days; notFound older than 30 days; never `uncertain`/`rejected` automatically; `priority` overrides order and staleness (always due once per launch). Identity confirmed → facts + bio fetched; Wikidata image trusted as a candidate; a Deezer candidate accepted only under the finder's rule and when its name folds equal to the confirmed artist's. Identity not confirmed → no facts, but the finder's existing rule may still pick a default photo. A photo is fetched only when the profile has no default it may keep (none, or not owner-picked and still `.migrated` with `replaceFromURL`), skipping `rejectedPhotoSources` and anything when `noPhoto`. Candidates beyond the chosen one are returned as references only. Errors propagate (the app backs off); nothing is stored for a failed artist.

- [ ] **Step 1: Failing tests:** scheduler: `testMostTracksFirst`, `testPriorityGoesFirst`, `testConfirmedRefreshAfter180Days`, `testNotFoundRetryAfter30Days`, `testUncertainAndRejectedNeverAutomatic`, `testVariousAndUnknownAreNeverLookedUp`, `testAnyPauseStops`; run (fakes): `testConfirmedFetchesFactsBioAndPhoto`, `testUncertainGetsNoFactsButMayGetPhoto`, `testOwnerDefaultIsNeverReplaced`, `testRejectedPhotoSourceIsSkipped`, `testNoPhotoFetchesNoPhoto`, `testMigratedPhotoGetsItsOriginal`, `testFailureStoresNothing`, `testRefreshKeepsOwnerChoices` (store round trip through `applyFetched`).
- [ ] **Step 2–4:** red, implement, green.
- [ ] **Step 5:** Commit `feat(artists): a background lookup that never overrides the owner`.

### Task 6: Library stats and when the artist page shows

**Files:**
- Create: `Sources/CrateDiggerCore/Services/ArtistProfiles/ArtistLibrarySummary.swift`, `ArtistPageFocus.swift`
- Test: `Tests/CrateDiggerCoreTests/ArtistLibrarySummaryTests.swift`, `ArtistPageFocusTests.swift`

**Produces:**

```swift
public struct ArtistLibrarySummary: Equatable, Sendable {
    public var albumCount, trackCount: Int; public var totalSeconds: Double
    public var dominantFormat: String?           // "FLAC" when ≥ 60% of tracks, else nil (page then lists the top two)
    public var formatCounts: [(String, Int)]
    public var firstAdded, latestAdded: Date?
    public var crateNames: [String]
    public var totalPlays: Int; public var lastPlayed: Date?
    public var topTracks: [UUID]                 // up to 5 by plays, ties by last played
    /// Built once per index change for every artist; keyed like profiles.
    public static func all(index: LibraryIndex, listening: [String: ListeningStats],
                           crates: [String: Set<String>]) -> [String: ArtistLibrarySummary]
}
public enum ArtistPageFocus {
    /// True when INFO should show the artist page.
    public static func showsArtist(view: BrowserView, focusedColumn: Int, explicitArtist: String?) -> Bool
    public static func artistName(view: BrowserView, state: BrowserState, index: LibraryIndex, explicitArtist: String?) -> String?
}
```

Rules: grouping uses the album artist (else artist), like the index's artist bucket; `dateAdded` from `ListeningStats`; `showsArtist` is true when the focused column's facet is `.artist` or `.albumArtist`, or when `explicitArtist` is set (from "Show Artist"); the explicit artist is cleared by the view model when focus moves to another column (documented here, wired in Task 7).

- [ ] **Step 1: Failing tests:** `testCountsAndTotalTime`, `testDominantFormatThreshold`, `testDatesAddedFromListening`, `testCratesListed`, `testTopTracksByPlays`, `testCompilationGroupsByAlbumArtist`, `testArtistColumnFocusShowsArtist`, `testAlbumArtistColumnFocusShowsArtist`, `testAlbumColumnFocusShowsAlbum`, `testExplicitArtistInViewWithoutArtistColumn`, `testSummaryForFourteenThousandTracksUnder100ms` (synthetic index; measure).
- [ ] **Step 2–4:** red, implement, green.
- [ ] **Step 5:** Commit `feat(artists): what the library holds of an artist, and when to show them`.

### Task 7: The artist page in the inspector

**Files:**
- Create: `Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel+ArtistProfiles.swift`, `Sources/CrateDiggerApp/UI/Carbon/Inspector/ArtistPageView.swift`
- Modify: `Sources/CrateDiggerApp/UI/Carbon/Inspector/InspectorPane.swift` (INFO branch), the album caption block (artist name becomes a link), the track context menu ("Show Artist")

**Interfaces — Consumes:** Tasks 1, 6. **Produces (view model):** `@Published var artistProfiles: [String: ArtistProfile]` (folded key → profile, refreshed from the store off the main actor), `@Published var artistSummaries: [String: ArtistLibrarySummary]` (rebuilt off the main actor in `index`'s `didSet` path), `var inspectedArtistName: String?` (from `ArtistPageFocus`), `func showArtist(_ name: String)`, `func artistPhotoThumbnail(hash:) async -> NSImage?` (through the existing thumbnail cache), `func confirmArtistIdentity(_ name: String, musicBrainzID: String?)` (nil = None of these → `.rejected`), `func lookUpArtistAgain(_ name: String)`.

Page content and order exactly as spec §2, including "Is this them?" for `.uncertain`, the Wikipedia credit line, members with former dimmed, top tracks clickable to play. Portrait: same sizing rule as the album poster; click opens the photo viewer (Task 9; until then, no-op with `// Task 9`); menu: Choose Default…, Add Photos…, Look Up Again, Not This Artist (confirmed only), No Photo / Show Photo. Empty portrait: initials placeholder in the style of `ArtistPictureRow`. Capture the page (isolated launch rule) with a scratch library and fixture profiles via a DEBUG hook `CRATEDIGGER_ARTIST_PAGE=<name>` that seeds a fixture profile; save `.build/artist-review/page-dark.png` and `page-light.png`.

- [ ] **Step 1:** App test `ArtistPageWiringTests`: `testFocusOnArtistColumnSetsInspectedArtist`, `testShowArtistThenFocusAlbumClearsIt`.
- [ ] **Step 2:** Implement view model and view.
- [ ] **Step 3:** `swift build`, full suite.
- [ ] **Step 4:** Capture, look, fix, re-capture.
- [ ] **Step 5:** Commit `feat(artists): the artist page in the inspector`.

### Task 8: Editing an artist and their photos

**Files:**
- Create: `Sources/CrateDiggerApp/UI/Carbon/Sheets/EditArtistSheetController.swift`, `Sources/CrateDiggerCore/Services/ArtistProfiles/ArtistEditDraft.swift`
- Modify: `LibraryViewModel+ArtistProfiles.swift`
- Test: `Tests/CrateDiggerCoreTests/ArtistEditDraftTests.swift`

**Produces:**

```swift
public struct ArtistEditDraft: Equatable, Sendable {
    public init(profile: ArtistProfile)
    public var owner: ArtistFacts                      // what the sheet edits; placeholders come from profile.fetched
    public mutating func useLookedUp(_ field: PartialKeyPath<ArtistFacts>)
    public var pastedMusicBrainz: String?             // link or bare id
    public static func musicBrainzID(from text: String) -> String?   // accepts https://musicbrainz.org/artist/<uuid> or <uuid>
    public func apply(to profile: inout ArtistProfile)  // identity change discards fetched facts and non-owner photos, keeps owner data
}
```

View model: `editArtist(_ name:)` (sheet from the root), `addArtistPhotos(_ name:, urls: [URL])` (and drop onto the portrait), `removeArtistPhoto`, `setDefaultArtistPhoto`, `setArtistNoPhoto`, `rejectArtistIdentity` ("Not This Artist"). Every writer starts with `guard !refuseWhileLibraryDisconnected()`. One Save = one store write.

- [ ] **Step 1: Failing tests:** `testEditsGoToOwnerOnly`, `testUseLookedUpClearsOwnerField`, `testMusicBrainzLinkAndBareIDParse`, `testGarbageIsNotAnID`, `testIdentityChangeKeepsOwnerDataDropsFetched`.
- [ ] **Step 2–4:** red, implement (Core then sheet), green.
- [ ] **Step 5:** Capture the sheet (`.build/artist-review/edit-sheet.png`), fix, commit `feat(artists): edit an artist, add photos, choose the default`.

### Task 9: The artist photo viewer

**Files:**
- Create: `Sources/CrateDiggerApp/UI/Carbon/Main/Browser/ArtistPhotoViewer.swift`
- Modify: `AlbumArtworkViewer.swift` only to extract what both viewers share (window, glass bar, zoom, keyboard navigation) into reusable pieces without changing the album viewer's behaviour.

Shows the artist's photos in order; bar: Make Default, Add Photos…, Remove, Show Credit; the default carries a small mark; arrow keys move between photos; opened from the portrait (replace the Task 7 `// Task 9` no-op). Capture `.build/artist-review/viewer.png`.

- [ ] **Step 1:** `swift build`; full suite (the album viewer's existing tests, if any, unchanged).
- [ ] **Step 2:** Capture both viewers to confirm the album viewer is unchanged; fix.
- [ ] **Step 3:** Commit `feat(artists): an artist photo viewer`.

### Task 10: Running it, the switch, and the iPod

**Files:**
- Modify: `LibraryViewModel+ArtistProfiles.swift`, `Sources/CrateDiggerApp/UI/Preferences/PreferencesWindowController.swift` (Integrations), `Sources/CrateDiggerCore/Services/PreferencesStore.swift` (`artistLookupsEnabled`, default true), `LibraryViewModel+ArtistPictures.swift`, `LibraryViewModel.swift` (`moveIndexFiles`, consolidation, launch migration), `ArtistPicturesSheetController.swift`

Wiring: start the worker a minute after launch with `ArtistLookupScheduler` + `ArtistLookupRun`, one artist at a time on the background lane, pausing per `ArtistLookupPauses` (scanning = `scanProgress.isRunning`, transferring = `isDeviceBusy || isConversionRunning`, hidden = `AppVisibility`, low power = `ProcessInfo.isLowPowerModeEnabled`, offline = `NWPathMonitor`, disabled = the preference); the inspected artist and the now-playing artist are passed as `priority`; failures back off (double the pause from 30 s, capped at 30 min, reset after a success). Settings ▸ Integrations: "Look up artist info and photos" toggle with the caption "Only artist names are sent, to MusicBrainz, Wikipedia, Wikidata and Deezer." Migration (Task 2) runs once at launch after the crates folder resolves. Library moves and consolidation carry the `ArtistPhotos` folder. The PodBox picture planner's `prepared:` map is built from each artist's `defaultPhotoRef` (prepared with `ArtistPictureImage.prepare`), skipping `noPhoto` and `notOnIPod`. The Artist Pictures sheet reads and writes profiles: Choose File → `addPhoto` + `setDefault`; No Picture → `notOnIPod = true`; its Find writes found photos into profiles (owner rules apply). `library.cdartists` is no longer read after migration.

- [ ] **Step 1: Failing tests (Core):** `ArtistPicturePreparedMapTests`: `testPreparedComesFromDefaultPhoto`, `testNoPhotoAndNotOnIPodAreSkipped`; `LookupBackoffTests`: `testBackoffDoublesAndResets` (pure function in `ArtistLookupScheduler`).
- [ ] **Step 2:** Implement Core pieces, then wiring.
- [ ] **Step 3:** Full suite (the existing Artist Pictures tests adapted, assertions kept).
- [ ] **Step 4:** Commit `feat(artists): look artists up in the background; the iPod uses the default photo`.

### Task 11: Docs

**Files:** `CLAUDE.md` (an "Artist profiles" subsection next to "PodBox and the device write door": store, owner-over-fetched rule, identity states, the lookup worker and its pauses, the gate's background lane, the default photo feeding the iPod, the focus rule, DEBUG hook, and the rules a change must not break), `CHANGELOG.md` (user-facing lines), `docs/PODBOX_CHECKS.md` (the picture now comes from the artist's default photo).

- [ ] **Step 1:** Write. **Step 2:** Commit `docs: artist profiles`.
