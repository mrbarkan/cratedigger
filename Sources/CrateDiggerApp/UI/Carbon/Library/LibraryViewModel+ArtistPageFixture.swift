#if DEBUG
import AppKit
import CrateDiggerCore
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// `CRATEDIGGER_ARTIST_PAGE=<name>`: a made-up library of three artists and
/// their profiles, seeded into the scratch crates folder, then the browser
/// put on `<name>` so the inspector shows its page. "Massive Attack" is a
/// band with a photo, members and a long bio; "Björk" a person with no photo
/// (the initials tile); "Air" a name MusicBrainz cannot tell apart, so the
/// page asks "Is this them?". The facts and bios are written for the
/// fixture, not taken from Wikipedia. Nothing goes on the network.
///
/// Refused unless `CRATEDIGGER_CRATES_DIR` points the library at a scratch
/// folder outside `/Volumes` and `CFFIXED_USER_HOME` at a scratch home: it
/// writes crates, the track store, plays and profiles there.
@MainActor
extension LibraryViewModel {
    func debugSeedArtistPage(_ name: String) async {
        guard let folder = Self.debugCratesDirectory else {
            NSLog("[artist-page] refusing: CRATEDIGGER_CRATES_DIR is not set, so the fixture would go into the real library")
            return
        }
        // Never onto a drive (a real iPod may be mounted), and never with the
        // real preferences, which the fixture's crates folder would be saved in.
        let path = folder.resolvingSymlinksInPath().path
        guard path != "/Volumes", !path.hasPrefix("/Volumes/"),
              ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] != nil else {
            NSLog("[artist-page] refusing: CRATEDIGGER_CRATES_DIR must be outside /Volumes and CFFIXED_USER_HOME must be set")
            return
        }
        let fixture = ArtistPageFixture(root: folder.appendingPathComponent("FixtureMusic", isDirectory: true))
        // A cover and a back in each album folder (inside the scratch folder),
        // so the album artwork viewer has pages to show.
        for album in Set(fixture.tracks.map { $0.track.fileURL.deletingLastPathComponent() }) {
            try? FileManager.default.createDirectory(at: album, withIntermediateDirectories: true)
            for (file, warmth) in [("cover.jpg", 0.05), ("back.jpg", 0.12)] {
                try? ArtistPageFixture.portraitJPEG(warmth: warmth)?.write(to: album.appendingPathComponent(file))
            }
        }

        saveCrateTracks(fixture.tracks, name: Self.personalCrateName)
        saveCrateTracks(fixture.vinyl, name: "Vinyl")
        let listening = currentListeningStore()
        for (loaded, entry) in fixture.listening {
            let path = ListeningStore.key(for: loaded.track.fileURL)
            listening.backfill(paths: [path], dateAdded: entry.added)
            for play in 0..<entry.plays {
                listening.recordPlay(path: path, at: entry.lastPlayed.addingTimeInterval(Double(-play) * 86_400))
            }
        }
        persistListeningStore()
        refreshAvailableCrates()
        selectSource(.localAll)

        let store = await currentArtistProfileStore()
        let photo = ArtistPageFixture.portraitJPEG()
        let secondPhoto = ArtistPageFixture.portraitJPEG(warmth: 0.1)
        let profiles = fixture.profiles
        let failure = await Task.detached { () -> String? in
            do {
                for profile in profiles {
                    store.update(name: profile.displayName) { $0 = profile }
                }
                if let photo {
                    let added = try store.addPhoto(name: "Massive Attack", data: photo, source: .owner, sourceID: nil,
                                                   credit: nil)
                    store.setDefault(name: "Massive Attack", hash: added.hash)
                }
                if let secondPhoto {
                    try store.addPhoto(name: "Massive Attack", data: secondPhoto, source: .owner, sourceID: nil,
                                       credit: nil)
                }
                try store.save()
                return nil
            } catch {
                return error.localizedDescription
            }
        }.value
        if let failure { NSLog("[artist-page] fixture profiles not saved: %@", failure) }
        reloadArtistProfiles()

        inspectorTab = .info
        if let artist = index.artists.first(where: { PodBoxArtName.folded($0.name) == PodBoxArtName.folded(name) }) {
            browser.view = .classic
            focusedColumn = 0
            selectedArtistID = artist.id
        } else {
            showArtist(name)
        }
        // `CRATEDIGGER_ARTIST_EDIT=1`: the Edit sheet over the page.
        if ProcessInfo.processInfo.environment["CRATEDIGGER_ARTIST_EDIT"] == "1" {
            try? await Task.sleep(for: .seconds(1))
            editArtist(name)
        }
        // `CRATEDIGGER_ARTIST_VIEWER=1`: the artist photo viewer.
        if ProcessInfo.processInfo.environment["CRATEDIGGER_ARTIST_VIEWER"] == "1" {
            try? await Task.sleep(for: .seconds(1))
            showArtistPhotos(name)
        }
    }
}

/// The fixture's music, plays and profiles.
private struct ArtistPageFixture {
    struct Listening {
        var plays: Int
        var lastPlayed: Date
        var added: Date
    }

    let tracks: [LoadedTrack]
    let vinyl: [LoadedTrack]
    let listening: [(LoadedTrack, Listening)]

    init(root: URL) {
        let albums: [(artist: String, album: String, year: Int, format: String, titles: [String])] = [
            ("Massive Attack", "Blue Lines", 1991, "FLAC",
             ["Safe from Harm", "One Love", "Blue Lines", "Be Thankful for What You've Got", "Five Man Army",
              "Unfinished Sympathy", "Daydreaming", "Lately", "Hymn of the Big Wheel"]),
            ("Massive Attack", "Protection", 1994, "FLAC",
             ["Protection", "Karmacoma", "Three", "Weather Storm", "Spying Glass", "Better Things", "Euro Zero Zero",
              "Sly", "Heat Miser", "Light My Fire"]),
            ("Massive Attack", "Mezzanine", 1998, "FLAC",
             ["Angel", "Risingson", "Teardrop", "Inertia Creeps", "Exchange", "Dissolved Girl", "Man Next Door",
              "Black Milk", "Mezzanine", "Group Four", "(Exchange)"]),
            ("Massive Attack", "Heligoland", 2010, "MP3",
             ["Pray for Rain", "Babel", "Splitting the Atom", "Girl I Love You", "Psyche", "Flat of the Blade",
              "Paradise Circus", "Rush Minute", "Saturday Come Slow", "Atlas Air"]),
            ("Björk", "Debut", 1993, "AAC",
             ["Human Behaviour", "Crying", "Venus as a Boy", "There's More to Life Than This", "Like Someone in Love",
              "Big Time Sensuality", "One Day", "Aeroplane", "Come to Me", "Violently Happy", "The Anchor Song"]),
            ("Björk", "Homogenic", 1997, "FLAC",
             ["Hunter", "Jóga", "Unravel", "Bachelorette", "All Neon Like", "5 Years", "Immature", "Alarm Call",
              "Pluto", "All Is Full of Love"]),
            ("Air", "Moon Safari", 1998, "FLAC",
             ["La Femme d'Argent", "Sexy Boy", "All I Need", "Kelly Watch the Stars", "Talisman", "Remember",
              "You Make It Easy", "Ce matin-là", "New Star in the Sky", "Le Voyage de Pénélope"]),
        ]
        let now = Date()
        var tracks: [LoadedTrack] = []
        var vinyl: [LoadedTrack] = []
        var listening: [(LoadedTrack, Listening)] = []
        for (albumIndex, album) in albums.enumerated() {
            let folder = root.appendingPathComponent(album.artist).appendingPathComponent("\(album.year) \(album.album)")
            for (offset, title) in album.titles.enumerated() {
                let number = offset + 1
                let url = folder.appendingPathComponent(String(format: "%02d %@.%@", number, title,
                                                               album.format == "MP3" ? "mp3" : "flac"))
                let seconds = Double(200 + (number * 37 + albumIndex * 53) % 230)
                let loaded = LoadedTrack(
                    track: AudioTrack(fileURL: url, title: title, artist: album.artist, album: album.album,
                                      durationSeconds: seconds, formatName: album.format, year: album.year,
                                      trackNumber: number),
                    metadata: ConversionMetadata(title: title, artist: album.artist, albumArtist: album.artist,
                                                 album: album.album, trackNumber: number, year: album.year))
                tracks.append(loaded)
                if album.album == "Mezzanine" || album.album == "Homogenic" { vinyl.append(loaded) }
                let plays = album.artist == "Air" ? 0 : (number * 7 + albumIndex * 3) % 19
                let added = Calendar.current.date(byAdding: .month, value: -(60 - albumIndex * 8), to: now) ?? now
                listening.append((loaded, Listening(plays: plays, lastPlayed: now.addingTimeInterval(Double(-number) * 3_600),
                                                    added: added)))
            }
        }
        self.tracks = tracks
        self.vinyl = vinyl
        self.listening = listening
    }

    var profiles: [ArtistProfile] {
        let checked = Date()
        let band = ArtistProfile(
            foldedKey: "", displayName: "Massive Attack",
            identity: .confirmed(musicBrainzID: "10adbe5e-a2c0-4bf3-8249-2b4cbf6e6ca8", wikidataID: "Q11895"),
            fetched: ArtistFacts(
                kind: "Group", origin: "Bristol, England", begin: "1988",
                bio: "Massive Attack are a band from Bristol, formed in 1988 out of a sound-system collective "
                    + "that played warehouse parties across the city. Their first album set slow, heavy beats "
                    + "under soul, reggae and hip hop, with a rotating cast of singers, and gave a name to a "
                    + "sound that much of the decade's electronic music would borrow. Later records grew darker "
                    + "and more guitar-driven, and the band became known as much for their live shows and their "
                    + "artwork as for their singles. This paragraph is fixture text written for the artist page "
                    + "capture, standing in for the lead of a Wikipedia article.",
                bioSourceURL: URL(string: "https://en.wikipedia.org/wiki/Massive_Attack"),
                members: [
                    ArtistMember(name: "Robert Del Naja", begin: "1988", isCurrent: true),
                    ArtistMember(name: "Grant Marshall", begin: "1988", isCurrent: true),
                    ArtistMember(name: "Andrew Vowles", begin: "1988", end: "1999", isCurrent: false),
                    ArtistMember(name: "Adrian Thaws", begin: "1988", end: "1995", isCurrent: false),
                ],
                genres: ["trip hop", "electronic", "downtempo", "alternative dance", "dub"],
                links: [
                    ArtistLink(kind: .musicBrainz,
                               url: URL(string: "https://musicbrainz.org/artist/10adbe5e-a2c0-4bf3-8249-2b4cbf6e6ca8")!),
                    ArtistLink(kind: .wikipedia, url: URL(string: "https://en.wikipedia.org/wiki/Massive_Attack")!),
                ]),
            owner: ArtistFacts(origin: "Bristol, England, UK"),
            // On a host the picture fetcher refuses, so no request is made.
            photoCandidates: [
                ArtistPictureRecord.HeldCandidate(source: .deezer, sourceID: "fixture-1",
                                                  imageURL: URL(string: "https://fixture.invalid/1.jpg")!),
                ArtistPictureRecord.HeldCandidate(source: .commons, sourceID: "fixture-2",
                                                  imageURL: URL(string: "https://fixture.invalid/2.jpg")!),
            ],
            checkedAt: checked)
        let person = ArtistProfile(
            foldedKey: "", displayName: "Björk",
            identity: .confirmed(musicBrainzID: "87c5dedd-371d-4a53-9f7f-80522fb7f3cb", wikidataID: "Q42455"),
            fetched: ArtistFacts(
                kind: "Person", origin: "Reykjavík, Iceland", begin: "1965",
                bio: "Björk is a singer, songwriter and producer from Reykjavík. Fixture text for the capture: "
                    + "short enough to show whole, with no More.",
                bioSourceURL: URL(string: "https://en.wikipedia.org/wiki/Bj%C3%B6rk"),
                genres: ["art pop", "electronic", "experimental"],
                links: [ArtistLink(kind: .musicBrainz,
                                   url: URL(string: "https://musicbrainz.org/artist/87c5dedd-371d-4a53-9f7f-80522fb7f3cb")!)]),
            checkedAt: checked)
        let uncertain = ArtistProfile(
            foldedKey: "", displayName: "Air",
            identity: .uncertain([
                ArtistIdentityCandidate(musicBrainzID: "cb67438a-7f50-4f2b-a6f1-2bb2729fd538", name: "Air",
                                        disambiguation: "French electronic duo", origin: "Versailles, France",
                                        releaseTitles: ["Moon Safari", "Talkie Walkie", "The Virgin Suicides"]),
                ArtistIdentityCandidate(musicBrainzID: "00000000-0000-4000-8000-000000000002", name: "Air",
                                        disambiguation: "Japanese rock band", origin: "Japan",
                                        releaseTitles: ["Usual Tones of Voice", "My Life"]),
                ArtistIdentityCandidate(musicBrainzID: "00000000-0000-4000-8000-000000000003", name: "AIR",
                                        disambiguation: "1970s jazz trio", origin: "United States",
                                        releaseTitles: ["Air Song", "Air Raid", "Open Air Suit"]),
            ]),
            checkedAt: checked)
        return [band, person, uncertain]
    }

    /// A made-up portrait: a lit backdrop and a silhouette, as a JPEG.
    static func portraitJPEG(warmth: Double = 0) -> Data? {
        let side = 1_200
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let full = CGRect(x: 0, y: 0, width: side, height: side)
        let colors = [CGColor(srgbRed: 0.10 + warmth, green: 0.12, blue: 0.20 - warmth, alpha: 1),
                      CGColor(srgbRed: 0.55 - warmth * 3, green: 0.18 + warmth * 2, blue: 0.16 + warmth * 3,
                              alpha: 1)] as CFArray
        if let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: side, y: side), options: [])
        }
        context.setFillColor(CGColor(srgbRed: 0.04, green: 0.04, blue: 0.06, alpha: 0.92))
        for (x, scale) in [(0.30, 0.9), (0.52, 1.05), (0.74, 0.85)] {
            let cx = Double(side) * x, head = 110.0 * scale
            context.fillEllipse(in: CGRect(x: cx - head, y: 560 * scale, width: head * 2, height: head * 2.3))
            context.fill(CGRect(x: cx - head * 1.9, y: 0, width: head * 3.8, height: 560 * scale))
        }
        context.setFillColor(CGColor(srgbRed: 1, green: 0.85, blue: 0.6, alpha: 0.10))
        context.fillEllipse(in: full.insetBy(dx: 300, dy: 300).offsetBy(dx: 0, dy: 260))
        guard let image = context.makeImage() else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }
}
#endif
