import CrateDiggerCore
import SwiftUI

/// What CrateDigger thinks the disc in the drive is, shown above the CD's track
/// list — the confirmation you want *before* pressing RIP, since the answer
/// decides every filename and folder the rip writes.
struct DiscIdentityBar: View {
    @Environment(\.carbon) private var theme
    @EnvironmentObject private var model: LibraryViewModel
    let info: AudioCDInfo

    var body: some View {
        VStack(spacing: 0) {
            summary
            if model.cdDetectionState == .choosing, !model.cdDiscMatches.isEmpty {
                picker
            }
        }
        .background(theme.isDark ? Color.black.opacity(0.28) : Color.black.opacity(0.035))
        .overlay(
            Rectangle()
                .fill(theme.isDark ? Color.white.opacity(0.05) : Color.black.opacity(0.08))
                .frame(height: 1),
            alignment: .bottom
        )
    }

    // MARK: - Summary line

    private var summary: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(iconColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(headline)
                    .font(CarbonFont.sans(12, weight: .semibold))
                    .foregroundStyle(theme.ink)
                    .lineLimit(1)
                Text(detail)
                    .font(CarbonFont.mono(8.5))
                    .foregroundStyle(theme.ink4)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)
            actions
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var actions: some View {
        switch model.cdDetectionState {
        case .identified:
            KeyButton(style: .normal, action: { model.detectAudioCD(info, force: true) }) {
                Text("RE-IDENTIFY")
                    .padding(.horizontal, 8)
            }
            .frame(height: 22)
            .carbonTip("Look the disc up again")
            KeyButton(style: .normal, action: { model.clearDiscMatch(for: info) }) {
                Text("CLEAR")
                    .padding(.horizontal, 8)
            }
            .frame(height: 22)
            .carbonTip("Forget this match and use the disc's own names")

        case .notFound(let toc):
            // A miss should still leave somewhere to go — this disc can be added.
            KeyButton(style: .normal, action: { model.submitDiscToMusicBrainz(toc) }) {
                Text("ADD TO MUSICBRAINZ")
                    .padding(.horizontal, 8)
            }
            .frame(height: 22)
            .carbonTip("Open MusicBrainz to attach this disc to a release")

        case .failed, .idle:
            KeyButton(style: .selected, action: { model.detectAudioCD(info, force: true) }) {
                Text("IDENTIFY DISC")
                    .padding(.horizontal, 8)
            }
            .frame(height: 22)

        case .looking, .choosing, .unavailable:
            EmptyView()
        }
    }

    // MARK: - Match picker

    /// One disc ID can be a standalone album *and* a disc inside several box
    /// sets. That changes the album tag, so it's the user's call, not ours.
    private var picker: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("SAME DISC, DIFFERENT RELEASES — PICK ONE")
                .font(CarbonFont.mono(8, weight: .bold))
                .tracking(1.4)
                .foregroundStyle(theme.orange)
                .padding(.horizontal, 12)
                .padding(.bottom, 4)

            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(model.cdDiscMatches) { candidate in
                        MatchRow(candidate: candidate) {
                            model.applyDiscMatch(candidate, to: info)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
            .frame(maxHeight: 190)
        }
    }

    // MARK: - Copy

    private var icon: String {
        switch model.cdDetectionState {
        case .identified:               return "checkmark.seal.fill"
        case .looking:                  return "arrow.triangle.2.circlepath"
        case .choosing:                 return "questionmark.circle.fill"
        case .notFound, .failed:        return "exclamationmark.triangle.fill"
        case .idle, .unavailable:       return "opticaldisc"
        }
    }

    private var iconColor: Color {
        switch model.cdDetectionState {
        case .identified:        return theme.cyan
        case .notFound, .failed: return theme.orange
        default:                 return theme.ink3
        }
    }

    private var headline: String {
        switch model.cdDetectionState {
        case .identified(let release):
            return "\(release.artist) — \(release.title)"
        case .looking:
            return "Identifying disc…"
        case .choosing:
            return "\(model.cdDiscMatches.count) releases share this disc"
        case .notFound:
            return "Disc not in the MusicBrainz database"
        case .failed:
            return "Couldn’t identify this disc"
        case .idle, .unavailable:
            return info.hasUsableNames ? info.name : "Unidentified disc"
        }
    }

    private var detail: String {
        let trackCount = "\(info.tracks.count) track\(info.tracks.count == 1 ? "" : "s")"
        switch model.cdDetectionState {
        case .identified(let release):
            var parts: [String] = []
            if let year = release.year { parts.append(String(year)) }
            parts.append(trackCount)
            if (release.totalDiscs ?? 1) > 1 {
                parts.append("disc \(model.cdMatchedDiscNumber) of \(release.totalDiscs ?? 1)")
            }
            parts.append(runtime)
            return parts.joined(separator: " · ")
        case .notFound:
            return "\(trackCount) · \(runtime) · tags will fall back to the disc's own names"
        case .failed(let message):
            return message
        default:
            return "\(trackCount) · \(runtime)"
        }
    }

    /// Total runtime straight from the TOC — no need to read the audio.
    private var runtime: String {
        guard let toc = info.toc else { return "—" }
        let seconds = Int(toc.trackDurationsInSeconds.reduce(0, +).rounded())
        return SleepMode.clockLabel(seconds)
    }
}

private struct MatchRow: View {
    @Environment(\.carbon) private var theme
    let candidate: ReleaseCandidate
    let onPick: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onPick) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(candidate.title)
                        .font(CarbonFont.sans(11.5, weight: .medium))
                        .foregroundStyle(theme.ink)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(CarbonFont.mono(8.5))
                        .foregroundStyle(theme.ink4)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: "arrow.right.circle")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(hovering ? theme.cyan : theme.ink4)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(hovering ? theme.ink.opacity(0.06) : Color.clear)
            )
        }
        .buttonStyle(.carbonHover)
        .onHover { hovering = $0 }
    }

    private var subtitle: String {
        var parts = [candidate.artist]
        if let year = candidate.year { parts.append(String(year)) }
        let discs = candidate.totalDiscs ?? 1
        parts.append(discs > 1 ? "box set · \(discs) discs" : "single disc")
        return parts.filter { !$0.isEmpty }.joined(separator: " · ").uppercased()
    }
}
