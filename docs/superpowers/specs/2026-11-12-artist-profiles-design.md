# Artist profiles: portraits and artist info in the app

2026-11-12. Status: draft for approval. Target: the next 2.3.x beta on `v2.3`.

## Why

Artist pictures exist today only as something CrateDigger prepares for a PodBox
iPod (`ArtistPictureStore`, `ArtistPictureFinder`, the Artist Pictures sheet).
The app itself never shows an artist's face or says anything about them. The
owner wants to click an artist in the browser and see who they are: a portrait,
the essentials, a short bio, and what the library holds of them. They want this
filled in without effort (looked up silently in the background), and they want
to be able to correct or add anything themselves, including as many photos as
they like, and choose which photo is each artist's default.

## Goals

1. Selecting an artist in the browser shows an **artist page** in the inspector:
   default portrait, name, one line of facts, short bio, members, genres, what
   the library holds, how it's listened to, links.
2. Info and portraits are **looked up silently in the background** for the
   local library's artists, with the clicked artist jumping the queue.
3. The owner can **edit every field**, **add any number of photos**, and
   **choose the default photo** for each artist.
4. An **artist photo viewer**, built like the album artwork viewer.
5. **One source of truth for the portrait**: the default photo is what the
   inspector shows and what goes to a PodBox iPod.

## Non-goals

- Submitting corrections to MusicBrainz or Wikipedia.
- Sources needing an API key (Last.fm, Discogs bios, fanart.tv), now or as a
  default.
- Artist pages for remote (Subsonic), CD, radio or device sources' artists that
  are not also in the local library. (Device and playlist views show the page
  when the artist exists locally; my call.)
- Portraits in the browser's artist rows or the compact/mini players. A later
  step can add them; the store is built so it can.
- Changing how the iPod decides *whether* to write a picture (the planner's
  none / found / uncertain rule stays exactly as it is).

## Anti-goals (failure even if it "works")

- The wrong person's face or bio shown as if certain. An ambiguous name must
  ask, not guess.
- A background lookup overwriting anything the owner typed or chose.
- Background work making the app feel slow: main-thread work, UI-initiated
  MusicBrainz lookups (FIX TAGS, artwork search, DEEP SCAN) waiting behind a
  2,000-artist background run, or a 14k-track library re-walked per click.
- Personal data leaving the machine. Only artist names (and MusicBrainz / Wikidata
  ids) go out.
- Base64 image bytes inside an index file (the library's existing rule).

## What gets built

### 1. When the inspector shows the artist page (confirmed by the owner)

Clicking an artist already fills the album anchor to its right, so
`selectedAlbum` alone cannot tell "the user is looking at an artist". The INFO
tab shows the **artist page when the focused browser column shows the Artist or
Album Artist facet** (`BrowserState.focusedColumn` / `view.facets`), and the
album page otherwise. Clicking an album or track moves focus and brings the
album back. Arrow keys between columns do the same. In a view with no artist
column the artist page is reachable from the album page (the artist name under
the cover becomes a link) and from a track's context menu ("Show Artist").
This changes today's behaviour in the classic Artist → Album → Track view: a
click on an artist used to show that artist's first album in the inspector.

### 2. The artist page (top to bottom)

- **Portrait**: the default photo, square, as large as the inspector allows
  (same sizing rule as the album poster). Click opens the artist photo viewer.
  Its menu: Choose Default…, Add Photos…, Look Up Again, No Photo.
  Empty state: an unlit placeholder with the artist's initials (the style the
  Artist Pictures sheet already uses).
- **Name**, then **one line of facts**: kind (Person / Band / Orchestra /
  Choir / other MusicBrainz types), origin (area, then country), years
  (life-span; "to now" when no end). Example: *Band · Bristol, England · 1991
  to now*.
- **Bio**: the lead paragraph of the artist's Wikipedia article, clamped to a
  few lines with "More". Under it: "From Wikipedia, CC BY-SA 4.0" with a link
  to the article. A bio the owner wrote shows with no credit.
- **Members** (groups only): name and years, from MusicBrainz member-of-band
  relations; former members dimmed.
- **Genres**: up to five MusicBrainz genre tags.
- **In your library** (nothing fetched): albums, tracks, total time, the
  dominant formats ("mostly FLAC"), first and latest date added, crates that
  hold them.
- **Listening** (nothing fetched, from `ListeningStore`): total plays, last
  played, top five tracks by plays (click to play).
- **Links**: MusicBrainz and Wikipedia, opening in the browser.
- **Edit** button: opens the editor (section 5).
- **"Is this them?"**: when the lookup is unsure, the page shows the
  candidates (name, disambiguation, origin, a few release titles) in place of
  facts and bio; picking one confirms it, "None of these" stops lookups for
  that artist until Look Up Again.

### 3. Data and storage

- **Identity**: an artist profile is keyed by the same folded artist key the
  picture store uses (`PodBoxArtName` folding of the album artist, else
  artist), so the app and the iPod share one record per artist.
- **New store `ArtistProfileStore`** (Core), file `library.cdartistinfo` in the
  Crates Index Folder, registered in `LibraryIndexFiles` (so library moves and
  the offline `LibraryIndexCopy` carry it). One record per artist:
  fetched fields and owner-entered fields kept **separately**
  (`fetched: ArtistFacts?`, `owner: ArtistFacts?`; the page shows owner over
  fetched, field by field); MusicBrainz id and Wikidata id; match state
  (`confirmed`, `uncertain(candidates)`, `notFound`, `rejected`); `checkedAt`;
  photos (ordered list of photo refs: hash, source, credit, width/height, added
  date); `defaultPhoto` (hash) and `defaultPickedByOwner: Bool`; two flags
  (my call): `noPhoto` (the app shows the placeholder, and the iPod gets
  nothing) and `notOnIPod` (the app still shows the photo; the iPod gets
  nothing). Both are owner choices and survive a change of default photo.
- **Photos**: bytes live once, keyed by SHA-256, in an `ArtistPhotos` folder
  beside the index (`<Crates Index Folder>/ArtistPhotos/<hash>.jpg|png`), never
  inside the index file. Fetched photos are stored capped at 1,600 px on the
  long side; photos the owner adds are kept as given up to 32 MB / 50 MP
  (refused beyond, the caps the picture preparer already uses). Thumbnails go
  through the existing thumbnail cache. Removing a photo deletes its file only
  when no profile references the hash.
- **Offline library**: when the library folder is disconnected, profiles load
  from the copy and every writer starts with `refuseWhileLibraryDisconnected`.
  Photo bytes are not copied (too large); the page shows a placeholder for a
  photo whose file is unreachable. My call.
- **Migration from the picture store** (my call): on first load, every
  `ArtistPictureRecord` with prepared bytes becomes a photo on that artist's
  profile and its default: `pickedByUser` records as owner-picked defaults,
  auto-found ones as ordinary defaults. Their 300 px bytes are used at once,
  and the worker re-fetches the original from the recorded source in the
  background to replace them at full size. "No Picture" records become "Don't
  send to the iPod" (section 7). Held candidates carry over. Afterwards
  `library.cdartists` is renamed `library.cdartists.bak` and no longer read;
  the Artist Pictures sheet's Find, including for device-only artists, writes
  into profiles.
- **Library moves**: `LibraryIndexFiles` lists top-level files only, so the
  `ArtistPhotos` folder gets its own handling in `moveIndexFiles` and
  consolidation.

### 4. Background lookups

- **What is fetched per artist**: MusicBrainz artist search by name, then the
  artist (`inc=url-rels+artist-rels+genres+release-groups`); Wikidata entity
  (for the Wikipedia sitelink and Commons image); the Wikipedia REST summary
  (`/api/rest_v1/page/summary/<title>`) in the preferred-language Wikipedia
  that has a sitelink, else English; portrait candidates from the existing
  finder sources (library folder images, Deezer, Commons).
- **Matching**: reuse `ArtistPictureFinder`'s match rule (fold-equal name plus a
  cross-check of release titles against the library's album titles, ignoring
  self-titled and generic titles), applied to the MusicBrainz artist. Exactly
  one confident candidate is confirmed automatically; otherwise the record is
  `uncertain` with the candidates kept, and the page asks.
- **Identity and photos** (my call): a record has two match states, identity
  (MusicBrainz) and photo. When the identity is confirmed, its Wikidata image
  is trusted, and a Deezer candidate is accepted only under the finder's own
  rule *and* when its name folds equal to the confirmed artist's. When the
  identity is uncertain, not found or rejected, the finder's existing rule
  alone may still pick a default photo (that is what the iPod gets today, so
  nothing regresses); facts and bio stay empty. "Is this them?" settles the
  identity only; photo candidates are then re-derived from it. There is one
  picker for identity (the page) and one place for photos (the viewer).
- **Which candidate bytes are kept** (my call): the worker downloads only the
  photo it makes the default. Other candidates are kept as references (source,
  id, URL, credit) and fetched on demand as thumbnails in the viewer and the
  Edit sheet; picking one downloads it into `ArtistPhotos`. A photo the owner
  removes is remembered by source and id (`rejectedPhotoSources`) and never
  re-added by a refresh or Look Up Again.
- **Correcting a match** (my call): a confirmed record offers "Not This
  Artist" (in the portrait menu and the Edit sheet), which rejects that
  MusicBrainz id and shows the candidates again; the Edit sheet also accepts a
  pasted MusicBrainz artist link or id. When the identity changes, fetched
  facts and fetched photos from the old identity are discarded; owner edits,
  owner-added photos and an owner-picked default stay.
- **Scheduling**: one background worker, one artist at a time, artists ordered
  by most tracks first. The clicked artist (and the one now playing) jump to
  the front. Starts a minute after launch, pauses while the library is
  scanning, while a conversion or device transfer runs, while the app is
  hidden or on low power, and when the network is offline. It resumes where it
  stopped across launches (the store's `checkedAt` is the cursor).
- **Rate limits**: every MusicBrainz request goes through the shared
  `MusicBrainzGate`, which gains a **background lane**: a background request
  is only issued when no foreground request is waiting, so FIX TAGS, artwork
  search and DEEP SCAN never queue behind it. Wikipedia/Wikidata/Deezer:
  at most one request per second from the worker.
- **Refresh**: confirmed records are refreshed after 180 days; `notFound`
  after 30 days (the existing rule); `uncertain` and `rejected` never
  automatically. Look Up Again always refreshes now.
- **Failures**: a transport error, 5xx or rate limit is never stored as "not
  found"; the worker backs off (the finder's existing rules) and retries later.
- **Switch**: Settings ▸ Integrations ▸ "Look up artist info and photos", on by
  default, with one line saying only artist names are sent. Off stops the
  worker; manual Look Up Again still works.

### 5. Editing

- **Edit Artist** sheet (AppKit sheet hosting SwiftUI, presented from the
  root): every field of the facts (kind, origin, years, bio, members, genres,
  links). Each field shows the fetched value as a placeholder; typing makes it
  the owner's value; a per-field "Use the looked-up value" clears it. One undo
  step per Save.
- **Photos**: Add Photos… (file picker, multi-select; also drag images onto
  the portrait or into the viewer), pick from the candidates the lookup found,
  remove. Order is the order added; the default is separate.
- **Default photo**: chosen explicitly in three places: the portrait's menu
  ("Choose Default…" shows the photos), the photo viewer ("Make Default" on
  each photo), and the Edit sheet. Until the owner picks, the default is the
  best confident match (library folder image, then the finder's order). Once
  picked (`defaultPickedByOwner`), no lookup changes it. Removing the default
  photo makes the next photo the default, and clears `defaultPickedByOwner`.
- Owner edits are never overwritten by a lookup; a lookup only fills empty
  fetched fields and adds photo candidates.

### 6. The artist photo viewer

Built on the album artwork viewer (`AlbumArtworkViewer.swift`,
`ArtworkViewerPresenter`, `FloatingArtworkPanel`): the same window, glass bar,
zoom and keyboard navigation, showing the artist's photos instead of an
album's images. Bar actions: Make Default, Add Photos…, Remove, Show Credit
(source, licence, author for Commons photos). The default photo carries a
small mark.

### 7. The iPod follows the default photo

- The PodBox picture planner takes its bytes from the profile's default photo
  (prepared to the existing 300 px square baseline JPEG), so the inspector and
  the iPod always agree.
- The Artist Pictures sheet keeps working on the same profiles: Choose File
  there adds a photo and makes it the default; its "No Picture" becomes a
  per-artist **"Don't send to the iPod"** flag, which hides nothing in the app.
- The planner's safety rules are unchanged: it still writes only when the
  player would show nothing, and only through the write door.

## Constraints

- Decidable logic in Core with XCTests: which column means "artist page",
  owner-over-fetched merging, default-photo rules, scheduling order and pauses,
  the gate's background lane, matching, Wikipedia language choice, migration.
  View-model code only wires.
- All network code behind protocols with fakes; tests never touch the
  network. Generic User-Agent (the app's existing one); no personal data.
- Main actor never blocks on image decoding, store I/O or the library walk;
  per-artist library stats are computed once per index change, not per click.
- Sheets and the viewer present from the root (compact player safe).
- Carbon theming and `CarbonMotion`; no em dashes in user-facing copy;
  Wikipedia text keeps its attribution wherever it is shown.
- Release line: 2.3.x beta work on `v2.3`; CHANGELOG under the next beta's
  heading.

## Left to the builder

Type names beyond those above; the exact layout and type sizes of the page
(approved from a real capture, per the owner's practice); how stats are cached;
the viewer's bar layout; the Edit sheet's layout.

## Open questions for the owner

None. Section 1's behaviour change was confirmed on 2026-11-12.
