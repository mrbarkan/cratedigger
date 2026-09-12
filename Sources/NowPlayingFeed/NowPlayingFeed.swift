import Foundation

/// What CrateDigger is playing, as the Now Playing widget sees it, and what the
/// widget shows around it.
///
/// The app writes one of these into the app-group container whenever the
/// system's now-playing info changes, with the pictures it names; the widget
/// reads it back and draws. Nothing ever travels the other way.
public struct NowPlayingFeed: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case idle, playing, paused }

    /// What the widget shows with nothing playing.
    public enum IdleMode: String, Codable, CaseIterable, Sendable {
        /// Random covers from the whole library, one a minute.
        case librarySlideshow
        /// The cover of the last album that played.
        case lastAlbumCover
        /// A clear widget with one of `idlePhrases`.
        case phrase
    }

    /// What the widget shows while a track is playing or paused.
    public enum PlayingMode: String, Codable, CaseIterable, Sendable {
        /// The album's cover.
        case albumCover
        /// The cover, then the album's booklet pages, one a minute.
        case coverAndBooklet
    }

    /// A cover shown with nothing playing, and the words the wide widget puts
    /// beside it.
    public struct Cover: Codable, Equatable, Sendable {
        /// The picture file.
        public var file: String
        public var album: String
        public var artist: String
        public var year: Int?
        /// A crate the record lives in, for a library cover.
        public var crate: String?
        /// When the record last played, for the last album's cover.
        public var playedAt: Date?

        public init(file: String, album: String, artist: String, year: Int? = nil,
                    crate: String? = nil, playedAt: Date? = nil) {
            self.file = file
            self.album = album
            self.artist = artist
            self.year = year
            self.crate = crate
            self.playedAt = playedAt
        }
    }

    public var state: State
    public var title: String
    public var artist: String
    public var album: String
    /// A radio stream: no duration, no progress bar.
    public var isLive: Bool
    public var duration: Double
    /// Seconds into the track as of `playheadAt`. The widget extrapolates
    /// from the pair while `state == .playing`, so the app never has to
    /// write on a tick.
    public var playhead: Double
    public var playheadAt: Date
    /// The playing cover's picture file, nil for no art.
    public var artworkFile: String?
    public var idleMode: IdleMode
    public var playingMode: PlayingMode
    /// The playing album's pictures, cover first, in `coverAndBooklet` mode.
    public var slides: [String]
    /// Random library covers, in `librarySlideshow` mode.
    public var idleSlides: [Cover]
    /// The cover of the last album that played, kept after playback stops.
    public var lastCover: Cover?

    public init(state: State = .idle, title: String = "", artist: String = "", album: String = "",
                isLive: Bool = false, duration: Double = 0, playhead: Double = 0,
                playheadAt: Date = .distantPast, artworkFile: String? = nil,
                idleMode: IdleMode = .librarySlideshow, playingMode: PlayingMode = .albumCover,
                slides: [String] = [], idleSlides: [Cover] = [], lastCover: Cover? = nil) {
        self.state = state
        self.title = title
        self.artist = artist
        self.album = album
        self.isLive = isLive
        self.duration = duration
        self.playhead = playhead
        self.playheadAt = playheadAt
        self.artworkFile = artworkFile
        self.idleMode = idleMode
        self.playingMode = playingMode
        self.slides = slides
        self.idleSlides = idleSlides
        self.lastCover = lastCover
    }

    public static let idle = NowPlayingFeed()

    /// The app group both the app and the widget are entitled to. macOS
    /// group identifiers are team-prefixed (`TEAMID.name`), unlike iOS's
    /// `group.` form.
    public static let groupIdentifier = "L26TPPMPF3.com.cratedigger.shared"

    /// The widget's kind, for `WidgetCenter.reloadTimelines(ofKind:)`.
    public static let widgetKind = "NowPlaying"

    /// The shared container, or nil when the process is not entitled to it.
    public static func containerURL() -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupIdentifier)
    }

    // MARK: - What the widget shows

    /// Every picture file this feed names.
    public var pictureNames: [String] {
        [artworkFile, lastCover?.file].compactMap { $0 } + slides + idleSlides.map(\.file)
    }

    /// The pictures to cycle through now: the album's slides while playing in
    /// `coverAndBooklet`, the library covers while idle in `librarySlideshow`,
    /// otherwise none.
    public var slideshow: [String] {
        switch state {
        case .idle: return idleMode == .librarySlideshow ? idleSlides.map(\.file) : []
        case .playing, .paused: return playingMode == .coverAndBooklet ? slides : []
        }
    }

    /// The one picture to show when there is no slideshow to show instead.
    public var stillPicture: String? {
        switch state {
        case .idle: return idleMode == .lastAlbumCover ? lastCover?.file : nil
        case .playing, .paused: return artworkFile
        }
    }

    /// The idle cover a picture belongs to, for the words beside it.
    public func cover(forPicture file: String) -> Cover? {
        idleSlides.first { $0.file == file } ?? (lastCover?.file == file ? lastCover : nil)
    }

    /// Slides change on the minute: the fastest pace the system reliably
    /// honours for a widget's timeline.
    public static let slideInterval: TimeInterval = 60

    /// Which of `count` slides shows at `date`. Keyed on the wall clock rather
    /// than on when the widget last reloaded, so a reload in the middle of a
    /// slideshow carries on instead of jumping back to the first picture.
    public static func slideIndex(at date: Date, count: Int) -> Int {
        guard count > 0 else { return 0 }
        let step = Int((date.timeIntervalSinceReferenceDate / slideInterval).rounded(.down))
        return ((step % count) + count) % count
    }

    /// When the next `count` slides go up: `date` itself, then each following
    /// minute boundary.
    public static func slideDates(from date: Date, count: Int) -> [Date] {
        let minute = (date.timeIntervalSinceReferenceDate / slideInterval).rounded(.down) * slideInterval
        return (0..<count).map { offset in
            offset == 0 ? date : Date(timeIntervalSinceReferenceDate: minute + Double(offset) * slideInterval)
        }
    }

    /// A nudge for when nothing is playing, shared by the OLED's NOW pane and
    /// the widget's phrase mode so both speak with one voice.
    public static let idlePhrases: [String] = [
        "Play something you love",
        "Drop the needle",
        "The crates are calling",
        "Silence is just a long intro",
        "Spin something dusty",
        "Your records miss you",
        "Find that B-side",
        "Every dig starts with play",
        "Warm up the tubes",
        "Press play, dig deep",
        "One more spin won't hurt",
        "Dust off a classic",
        "The groove is waiting",
        "Feed the turntable",
        "What's on side B?",
        "Make the speakers proud",
        "Somewhere, a record spins",
        "Rewind. Replay. Repeat.",
        "Today deserves a soundtrack",
        "Good ears deserve good records"
    ]
}

/// The feed on disk: one JSON file, and a folder of the pictures it names.
public struct NowPlayingFeedStore: Sendable {
    public static let feedFileName = "now-playing.json"

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// Holds the pictures a feed names and nothing else, so anything in it the
    /// feed no longer names can go.
    public var picturesDirectory: URL {
        directory.appendingPathComponent("pictures", isDirectory: true)
    }

    /// Write `feed` unless the file already holds exactly these bytes, and
    /// say whether anything changed, so the caller reloads the widget only
    /// then.
    ///
    /// Pictures the feed does not name are removed first. `picture` is then
    /// asked for the bytes of each named picture not on disk yet; one it cannot
    /// supply is left out of what is written, so the widget never names a file
    /// that is not there. A picture rendered later with `writePicture` joins
    /// the feed on the next write that still names it.
    @discardableResult
    public func write(_ feed: NowPlayingFeed, picture: (String) -> Data?) throws -> Bool {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: picturesDirectory, withIntermediateDirectories: true)

        let named = Set(feed.pictureNames)
        let onDisk = (try? fileManager.contentsOfDirectory(atPath: picturesDirectory.path)) ?? []
        for name in onDisk where !named.contains(name) {
            try? fileManager.removeItem(at: picturesDirectory.appendingPathComponent(name))
        }
        for name in named where !hasPicture(named: name) {
            if let data = picture(name) {
                try writePicture(data, named: name)
            }
        }

        var written = feed
        written.artworkFile = feed.artworkFile.flatMap { hasPicture(named: $0) ? $0 : nil }
        written.lastCover = feed.lastCover.flatMap { hasPicture(named: $0.file) ? $0 : nil }
        written.slides = feed.slides.filter(hasPicture(named:))
        written.idleSlides = feed.idleSlides.filter { hasPicture(named: $0.file) }

        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(written)
        let url = directory.appendingPathComponent(Self.feedFileName)
        if (try? Data(contentsOf: url)) == data { return false }
        try data.write(to: url, options: .atomic)
        return true
    }

    /// Put one picture in place, for a render that finishes after the write
    /// that named it.
    public func writePicture(_ data: Data, named name: String) throws {
        try FileManager.default.createDirectory(at: picturesDirectory, withIntermediateDirectories: true)
        try data.write(to: picturesDirectory.appendingPathComponent(name), options: .atomic)
    }

    public func hasPicture(named name: String) -> Bool {
        FileManager.default.fileExists(atPath: picturesDirectory.appendingPathComponent(name).path)
    }

    /// The picture's file, when it is on disk.
    public func pictureURL(named name: String) -> URL? {
        hasPicture(named: name) ? picturesDirectory.appendingPathComponent(name) : nil
    }

    /// The last feed written, or idle when there is none or it cannot be read.
    public func read() -> NowPlayingFeed {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(Self.feedFileName)),
              let feed = try? JSONDecoder().decode(NowPlayingFeed.self, from: data)
        else { return .idle }
        return feed
    }
}
