import AppKit
import CrateDiggerCore
import SwiftUI

/// The Browser pane in radio mode: a vertical list of stream sources, replacing
/// the 3-column Artist/Album/Track browser. Mirrors the v7 `.radio-list`.
struct RadioListView: View {
    @Environment(\.carbon) private var theme
    @EnvironmentObject private var model: LibraryViewModel

    var body: some View {
        VStack(spacing: 0) {
            header
            if model.filteredStreams.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(model.filteredStreams) { stream in
                            RadioRow(stream: stream, selected: model.selectedStreamID == stream.id)
                                .onTapGesture { model.selectStream(id: stream.id) }
                                .contextMenu {
                                    Button("Copy Link") {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(stream.url, forType: .string)
                                    }
                                    Divider()
                                    Button("Remove Stream", role: .destructive) {
                                        model.removeStream(id: stream.id)
                                    }
                                }
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 8)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text((model.radioChannelFilter ?? "All Streams").uppercased())
                .font(CarbonFont.mono(9, weight: .bold))
                .tracking(1.8)
                .foregroundStyle(theme.ink2)
                .lineLimit(1)
            Spacer()
            Text("\(model.filteredStreams.count) SOURCE\(model.filteredStreams.count == 1 ? "" : "S")")
                .font(CarbonFont.mono(8.5))
                .foregroundStyle(theme.ink3)
            Button(action: { model.showingAddStreamSheet = true }) {
                HStack(spacing: 4) {
                    Image(systemName: "plus")
                        .font(.system(size: 8, weight: .bold))
                    Text("ADD URL")
                        .font(CarbonFont.mono(8, weight: .bold))
                        .tracking(1)
                }
                .foregroundStyle(theme.cyan)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(ChromeChassis(theme: theme, cornerRadius: 5))
            }
            .buttonStyle(.plain)
            .help("Add a YouTube stream source")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(theme.ink4)
            Text("No streams yet")
                .font(CarbonFont.sans(13, weight: .medium))
                .foregroundStyle(theme.ink3)
            Text("Paste a YouTube channel, playlist, or video link to start.")
                .font(CarbonFont.mono(9))
                .foregroundStyle(theme.ink4)
                .multilineTextAlignment(.center)
            Button(action: { model.showingAddStreamSheet = true }) {
                Text("ADD URL")
                    .font(CarbonFont.mono(9, weight: .bold))
                    .tracking(1.5)
                    .foregroundStyle(theme.cyan)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(ChromeChassis(theme: theme, cornerRadius: 6))
            }
            .buttonStyle(.plain)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 24)
    }
}

/// A stream's cover: the real fetched thumbnail when available, otherwise the
/// hue-generated poster (matches the v7 mockup). Fills its container.
struct StreamThumbnail: View {
    let stream: StreamSource

    var body: some View {
        if let urlString = stream.thumbnailURL, let url = URL(string: urlString) {
            AsyncImage(url: url) { phase in
                if case .success(let image) = phase {
                    image.resizable().aspectRatio(contentMode: .fill)
                } else {
                    huePoster
                }
            }
        } else {
            huePoster
        }
    }

    private var huePoster: some View {
        LinearGradient(
            colors: [
                Color(hue: Double(stream.hue) / 360, saturation: 0.7, brightness: 0.68),
                Color(hue: Double((stream.hue + 40) % 360) / 360, saturation: 0.6, brightness: 0.42)
            ],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
    }
}

/// A single stream row: thumbnail with play/duration overlay, title + badge +
/// channel, and source/watching metadata.
private struct RadioRow: View {
    @Environment(\.carbon) private var theme
    let stream: StreamSource
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            thumb
            VStack(alignment: .leading, spacing: 4) {
                Text(stream.title)
                    .font(CarbonFont.sans(12.5, weight: .semibold))
                    .foregroundStyle(selected ? theme.selectionInk : theme.ink)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(stream.kind.rawValue.uppercased())
                        .font(CarbonFont.mono(7.5, weight: .bold))
                        .tracking(0.8)
                        .foregroundStyle(badgeColor)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(RoundedRectangle(cornerRadius: 3).fill(badgeColor.opacity(0.16)))
                    Text(stream.channel)
                        .font(CarbonFont.mono(9))
                        .foregroundStyle(selected ? theme.selectionInk.opacity(0.8) : theme.ink3)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 4) {
                    Image(systemName: "play.rectangle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(Color(red: 1, green: 0, blue: 0).opacity(0.85))
                    Text("YouTube")
                        .font(CarbonFont.mono(8.5))
                        .foregroundStyle(selected ? theme.selectionInk.opacity(0.8) : theme.ink3)
                }
                Text(subtext)
                    .font(CarbonFont.mono(8.5))
                    .foregroundStyle(selected ? theme.selectionInk.opacity(0.7) : theme.ink4)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(rowBackground)
        .contentShape(Rectangle())
    }

    private var thumb: some View {
        ZStack {
            StreamThumbnail(stream: stream)
            Image(systemName: selected ? "pause.fill" : "play.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white.opacity(0.92))
                .shadow(color: .black.opacity(0.4), radius: 2)
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Text(durationBadge)
                        .font(CarbonFont.mono(7, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 3)
                        .padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 2).fill(.black.opacity(0.6)))
                        .padding(2)
                }
            }
        }
        .frame(width: 54, height: 40)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(.white.opacity(0.15), lineWidth: 1))
    }

    private var durationBadge: String {
        if stream.isLive { return "LIVE" }
        if let d = stream.durationSeconds, d > 0 {
            return String(format: "%d:%02d", Int(d) / 60, Int(d) % 60)
        }
        switch stream.kind {
        case .playlist: return "LIST"
        case .mix: return "MIX"
        default: return "▶"
        }
    }

    private var subtext: String {
        if stream.isLive { return "● \(stream.viewers ?? "0") watching" }
        return stream.kind.rawValue.capitalized
    }

    private var badgeColor: Color {
        stream.isLive ? Color(red: 1, green: 0.36, blue: 0.29) : theme.cyan
    }

    @ViewBuilder
    private var rowBackground: some View {
        if selected {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            theme.indigo.opacity(theme.isDark ? 0.85 : 0.8),
                            theme.cyan.opacity(theme.isDark ? 0.82 : 0.72)
                        ],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Color.white.opacity(0.24), lineWidth: 1))
        } else {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(theme.ink.opacity(theme.isDark ? 0.04 : 0.03))
        }
    }
}
