import SwiftUI
import WidgetKit

// No `import NowPlayingFeed`: the Xcode project compiles Sources/NowPlayingFeed
// into this module.

/// What CrateDigger is playing. Show-only: the app writes the feed into the
/// app-group container and reloads this widget; tapping it opens the app.

struct NowPlayingEntry: TimelineEntry {
    let date: Date
    let feed: NowPlayingFeed
    let artwork: NSImage?
}

struct NowPlayingProvider: TimelineProvider {
    func placeholder(in context: Context) -> NowPlayingEntry {
        NowPlayingEntry(date: .now, feed: .idle, artwork: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (NowPlayingEntry) -> Void) {
        completion(currentEntry())
    }

    /// One entry and no schedule: the app reloads the widget whenever the
    /// feed changes, and the progress bar animates from the entry by itself.
    func getTimeline(in context: Context, completion: @escaping (Timeline<NowPlayingEntry>) -> Void) {
        completion(Timeline(entries: [currentEntry()], policy: .never))
    }

    private func currentEntry() -> NowPlayingEntry {
        guard let container = NowPlayingFeed.containerURL() else {
            return NowPlayingEntry(date: .now, feed: .idle, artwork: nil)
        }
        let store = NowPlayingFeedStore(directory: container)
        let feed = store.read()
        let artwork = store.artworkURL(for: feed).flatMap { NSImage(contentsOf: $0) }
        return NowPlayingEntry(date: .now, feed: feed, artwork: artwork)
    }
}

struct NowPlayingWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: NowPlayingEntry

    var body: some View {
        if entry.feed.state == .idle {
            IdleView()
        } else if family == .systemSmall {
            SmallView(feed: entry.feed, artwork: entry.artwork)
        } else {
            MediumView(feed: entry.feed, artwork: entry.artwork)
        }
    }
}

/// Art fills the widget; title and band sit over a gradient at the bottom.
private struct SmallView: View {
    let feed: NowPlayingFeed
    let artwork: NSImage?

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
        .foregroundStyle(artwork == nil ? Color.primary : Color.white)
        .modifier(WidgetBackground(artwork: artwork))
    }
}

/// Art on the left; the mini player's three lines and progress on the right.
private struct MediumView: View {
    let feed: NowPlayingFeed
    let artwork: NSImage?

    var body: some View {
        HStack(spacing: 12) {
            ArtworkTile(image: artwork)
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
        .modifier(WidgetBackground(artwork: nil))
    }
}

private struct IdleView: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "music.note")
                .font(.title)
                .foregroundStyle(.secondary)
            Text("Nothing playing")
                .font(.headline)
                .accentable()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .modifier(WidgetBackground(artwork: nil))
    }
}

private struct ArtworkTile: View {
    let image: NSImage?

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
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

/// `containerBackground` is required on macOS 14+ and absent below it, where
/// the widget pads itself instead.
private struct WidgetBackground: ViewModifier {
    let artwork: NSImage?

    func body(content: Content) -> some View {
        if #available(macOS 14, *) {
            if let artwork {
                content.containerBackground(for: .widget) { ArtBackdrop(image: artwork) }
            } else {
                content.containerBackground(.fill.tertiary, for: .widget)
            }
        } else {
            content
                .padding()
                .background(artwork.map { ArtBackdrop(image: $0) })
        }
    }
}

private struct ArtBackdrop: View {
    let image: NSImage

    var body: some View {
        ZStack {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
            LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .center, endPoint: .bottom)
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
        .description("What CrateDigger is playing.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct CrateDiggerWidgetBundle: WidgetBundle {
    var body: some Widget {
        NowPlayingWidget()
    }
}
