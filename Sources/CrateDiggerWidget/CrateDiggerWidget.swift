import SwiftUI
import WidgetKit

// No `import NowPlayingFeed`: the Xcode project compiles Sources/NowPlayingFeed
// into this module.

/// What CrateDigger is playing, or a picture while it plays nothing. Show-only:
/// the app writes the feed and its pictures into the app-group container and
/// reloads this widget; tapping it opens the app.

struct NowPlayingEntry: TimelineEntry {
    let date: Date
    let feed: NowPlayingFeed
    /// The cover or slide on screen at `date`, nil when there is none.
    let picture: NSImage?
    /// With nothing playing, the words for the cover on screen.
    let cover: NowPlayingFeed.Cover?
    /// Shown with nothing playing when there is no picture to show instead.
    let phrase: String
}

struct NowPlayingProvider: TimelineProvider {
    /// A slideshow schedules this many one-minute entries, then asks again.
    /// ponytail: half an hour, not more: every entry is rendered up front and a
    /// widget extension gets little memory. Raise it if reloads show up in the
    /// energy report.
    private static let slideEntryCount = 30

    func placeholder(in context: Context) -> NowPlayingEntry {
        NowPlayingEntry(date: .now, feed: .idle, picture: nil, cover: nil, phrase: NowPlayingFeed.idlePhrases[0])
    }

    func getSnapshot(in context: Context, completion: @escaping (NowPlayingEntry) -> Void) {
        completion(timeline(from: .now).entries[0])
    }

    /// The app reloads the widget whenever the feed changes. Between reloads a
    /// slideshow runs from its schedule, a phrase changes on the hour, and
    /// anything else holds still; the progress bar animates on its own.
    func getTimeline(in context: Context, completion: @escaping (Timeline<NowPlayingEntry>) -> Void) {
        completion(timeline(from: .now))
    }

    private func timeline(from now: Date) -> Timeline<NowPlayingEntry> {
        let store = NowPlayingFeed.containerURL().map { NowPlayingFeedStore(directory: $0) }
        let feed = store?.read() ?? .idle
        let phrase = NowPlayingFeed.idlePhrases.randomElement() ?? ""
        var loaded: [String: NSImage] = [:]
        func picture(_ name: String?) -> NSImage? {
            guard let name else { return nil }
            if let image = loaded[name] { return image }
            let image = store?.pictureURL(named: name).flatMap { NSImage(contentsOf: $0) }
            loaded[name] = image
            return image
        }

        func entry(_ date: Date, showing name: String?) -> NowPlayingEntry {
            let cover = feed.state == .idle ? name.flatMap(feed.cover(forPicture:)) : nil
            return NowPlayingEntry(date: date, feed: feed, picture: picture(name), cover: cover, phrase: phrase)
        }

        let slides = feed.slideshow
        if slides.count > 1 {
            let entries = NowPlayingFeed.slideDates(from: now, count: Self.slideEntryCount).map { date in
                entry(date, showing: slides[NowPlayingFeed.slideIndex(at: date, count: slides.count)])
            }
            return Timeline(entries: entries, policy: .atEnd)
        }

        let still = entry(now, showing: slides.first ?? feed.stillPicture)
        let showsPhrase = feed.state == .idle && still.picture == nil
        return Timeline(entries: [still], policy: showsPhrase ? .after(now.addingTimeInterval(3600)) : .never)
    }
}

struct NowPlayingWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: NowPlayingEntry

    var body: some View {
        if entry.feed.state == .idle {
            if let picture = entry.picture, family == .systemSmall {
                IdlePictureView(picture: picture, caption: entry.feed.idleMode == .lastAlbumCover ? "Nothing playing" : nil)
            } else if let picture = entry.picture {
                IdleMediumView(mode: entry.feed.idleMode, picture: picture, cover: entry.cover)
            } else {
                PhraseView(phrase: entry.phrase)
            }
        } else if family == .systemSmall {
            SmallView(feed: entry.feed, picture: entry.picture)
        } else {
            MediumView(feed: entry.feed, picture: entry.picture)
        }
    }
}

/// The picture fills the widget; title and band sit over a gradient.
private struct SmallView: View {
    let feed: NowPlayingFeed
    let picture: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Spacer(minLength: 0)
            Text(feed.title)
                .font(.headline)
                .lineLimit(2)
                .accentable()
            Text(feed.artist)
                .font(.subheadline)
                .lineLimit(1)
                .opacity(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(picture == nil ? Color.primary : Color.white)
        .modifier(WidgetBackdrop(picture.map { .picture($0, shaded: true) } ?? .plain))
    }
}

/// The picture on the left; the mini player's three lines and progress on the right.
private struct MediumView: View {
    let feed: NowPlayingFeed
    let picture: NSImage?

    var body: some View {
        HStack(spacing: 12) {
            PictureTile(image: picture)
            VStack(alignment: .leading, spacing: 2) {
                Text(feed.title)
                    .font(.headline)
                    .lineLimit(2)
                    .accentable()
                Text(feed.artist)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if !feed.album.isEmpty {
                    Text(feed.album)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                ProgressLine(feed: feed)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .modifier(WidgetBackdrop(.plain))
    }
}

/// The wide widget with nothing playing, laid out like `MediumView`: the cover
/// on the left, and beside it what the record is and why it is on screen.
private struct IdleMediumView: View {
    let mode: NowPlayingFeed.IdleMode
    let picture: NSImage
    let cover: NowPlayingFeed.Cover?

    var body: some View {
        HStack(spacing: 12) {
            PictureTile(image: picture)
            VStack(alignment: .leading, spacing: 2) {
                Text(mode == .lastAlbumCover ? "LAST PLAYED" : "FROM YOUR CRATES")
                    .font(.caption2.weight(.semibold))
                    .tracking(1.2)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 2)
                if let cover {
                    Text(cover.album)
                        .font(.headline)
                        .lineLimit(2)
                        .accentable()
                    Text(cover.year.map { "\(cover.artist) · \(String($0))" } ?? cover.artist)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    footer(cover)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .modifier(WidgetBackdrop(.plain))
    }

    /// Where a library cover lives, or how long ago the last album played. The
    /// relative time counts on by itself, with no reload.
    @ViewBuilder
    private func footer(_ cover: NowPlayingFeed.Cover) -> some View {
        if mode == .lastAlbumCover, let playedAt = cover.playedAt {
            Text(playedAt, style: .relative) + Text(" ago")
        } else if let crate = cover.crate {
            Text("in \(crate)")
        }
    }
}

/// A library cover, or the last album's cover under a caption.
private struct IdlePictureView: View {
    let picture: NSImage
    let caption: String?

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            if let caption {
                Text(caption)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .accentable()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .modifier(WidgetBackdrop(.picture(picture, shaded: caption != nil)))
    }
}

/// A line from the OLED's idle phrases on a clear widget.
private struct PhraseView: View {
    let phrase: String

    var body: some View {
        Text(phrase)
            .font(.title3.weight(.semibold))
            .multilineTextAlignment(.center)
            .minimumScaleFactor(0.7)
            .accentable()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .modifier(WidgetBackdrop(.clear))
    }
}

private struct PictureTile: View {
    let image: NSImage?

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    FittedPicture(image: image)
                } else {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.2))
                        .overlay {
                            Image(systemName: "music.note")
                                .font(.largeTitle)
                                .foregroundStyle(.secondary)
                        }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// The whole picture, over a blurred fill of itself. A square cover fills
/// its square on its own; a portrait booklet page or a cover in the wide
/// medium widget keeps every edge instead of being cropped.
private struct FittedPicture: View {
    let image: NSImage

    var body: some View {
        ZStack {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .blur(radius: 18)
                .opacity(0.6)
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
        }
        .clipped()
    }
}

/// Moves by itself while playing, stands still while paused, and gives way
/// to a LIVE label for a stream.
private struct ProgressLine: View {
    let feed: NowPlayingFeed

    var body: some View {
        if feed.isLive {
            Label("Live", systemImage: "dot.radiowaves.left.and.right")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if feed.duration > 0 {
            HStack(spacing: 6) {
                if feed.state == .playing {
                    let start = feed.playheadAt.addingTimeInterval(-feed.playhead)
                    ProgressView(timerInterval: start...start.addingTimeInterval(feed.duration), countsDown: false) {
                        EmptyView()
                    } currentValueLabel: {
                        EmptyView()
                    }
                } else {
                    Image(systemName: "pause.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    ProgressView(value: min(max(feed.playhead, 0), feed.duration), total: feed.duration)
                }
            }
        }
    }
}

private enum Backdrop {
    /// A picture filling the widget, with a gradient under any text.
    case picture(NSImage, shaded: Bool)
    /// The system's plain widget fill.
    case plain
    /// No fill at all.
    case clear
}

/// `containerBackground` is required on macOS 14+ and absent below it, where
/// the widget pads itself and has no clear mode to offer.
private struct WidgetBackdrop: ViewModifier {
    let backdrop: Backdrop

    init(_ backdrop: Backdrop) {
        self.backdrop = backdrop
    }

    func body(content: Content) -> some View {
        if #available(macOS 14, *) {
            switch backdrop {
            case .picture(let image, let shaded):
                content.containerBackground(for: .widget) { PictureBackdrop(image: image, shaded: shaded) }
            case .plain:
                content.containerBackground(.fill.tertiary, for: .widget)
            case .clear:
                content.containerBackground(Color.clear, for: .widget)
            }
        } else {
            content
                .padding()
                .background(legacyBackground)
        }
    }

    @ViewBuilder
    private var legacyBackground: some View {
        if case .picture(let image, let shaded) = backdrop {
            PictureBackdrop(image: image, shaded: shaded)
        }
    }
}

private struct PictureBackdrop: View {
    let image: NSImage
    let shaded: Bool

    var body: some View {
        ZStack {
            FittedPicture(image: image)
            if shaded {
                LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .center, endPoint: .bottom)
            }
        }
    }
}

private extension View {
    /// Tinted with the system accent in accented and clear rendering modes.
    @ViewBuilder
    func accentable() -> some View {
        if #available(macOS 14, *) {
            widgetAccentable()
        } else {
            self
        }
    }
}

struct NowPlayingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: NowPlayingFeed.widgetKind, provider: NowPlayingProvider()) { entry in
            NowPlayingWidgetView(entry: entry)
        }
        .configurationDisplayName("Now Playing")
        .description("What CrateDigger is playing, with its cover and booklet.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct CrateDiggerWidgetBundle: WidgetBundle {
    var body: some Widget {
        NowPlayingWidget()
    }
}
