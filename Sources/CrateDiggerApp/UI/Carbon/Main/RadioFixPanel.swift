import CrateDiggerCore
import SwiftUI

/// The banner shown when a stream fails: what went wrong, in the user's terms,
/// and the buttons that actually address *that* cause.
///
/// This replaced a bare "Stream Problem" alert. An alert can only be dismissed,
/// so the most common real failure — a yt-dlp that YouTube has outrun — left
/// people with nothing to do. Remedies come from `StreamFailureAdvisor`, which
/// is careful not to blame the install when the video is simply private or gone.
struct RadioFixPanel: View {
    @Environment(\.carbon) private var theme
    @EnvironmentObject private var model: LibraryViewModel
    let diagnosis: StreamFailureAdvisor.Diagnosis

    @State private var showingDetail = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(theme.orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text("STREAM PROBLEM")
                        .font(CarbonFont.mono(8.5, weight: .bold))
                        .tracking(1.8)
                        .foregroundStyle(theme.orange)
                    Text(diagnosis.summary)
                        .font(CarbonFont.sans(11.5))
                        .foregroundStyle(theme.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                Button(action: { model.dismissStreamFailure() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(theme.ink4)
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.carbonHover)
                .carbonTip("Dismiss")
            }

            // Primary remedy first; the rest stay available but quieter.
            HStack(spacing: 6) {
                ForEach(Array(diagnosis.remedies.enumerated()), id: \.offset) { index, remedy in
                    KeyButton(style: index == 0 ? .selected : .normal,
                              action: { model.applyStreamRemedy(remedy) }) {
                        Text(remedy.actionTitle.uppercased())
                            .font(CarbonFont.mono(8.5, weight: .bold))
                            .tracking(0.8)
                            .lineLimit(1)
                            .padding(.horizontal, 8)
                    }
                    .frame(height: 22)
                }
                Spacer(minLength: 0)
                if diagnosis.detail != nil {
                    Button(action: { showingDetail.toggle() }) {
                        Text(showingDetail ? "HIDE LOG" : "LOG")
                            .font(CarbonFont.mono(8.5, weight: .bold))
                            .tracking(0.8)
                            .foregroundStyle(theme.ink4)
                    }
                    .buttonStyle(.carbonHover)
                }
            }

            if showingDetail, let detail = diagnosis.detail {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(detail)
                        .font(CarbonFont.mono(9))
                        .foregroundStyle(theme.ink4)
                        .textSelection(.enabled)
                        .padding(6)
                }
                .frame(maxHeight: 64)
                .background(RoundedRectangle(cornerRadius: 5).fill(theme.wellDeep))
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(theme.chassis)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(theme.orange.opacity(0.45), lineWidth: 1)
                )
        )
        .padding(.horizontal, 6)
        .padding(.top, 8)
    }
}

/// One-tap stations, so Radio isn't an empty box with a URL field. Filtered to
/// the category being browsed, and anything already saved is hidden.
struct StreamSuggestionsView: View {
    @Environment(\.carbon) private var theme
    @EnvironmentObject private var model: LibraryViewModel

    var body: some View {
        let suggestions = model.availableSuggestions(for: model.radioCategoryFilter)
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("SUGGESTED STATIONS")
                    .font(CarbonFont.mono(8.5, weight: .semibold))
                    .tracking(2.2)
                    .foregroundStyle(theme.ink3)
                Spacer()
                Button(action: { model.showingStreamSuggestions = false }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(theme.ink4)
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.carbonHover)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            if suggestions.isEmpty {
                Text("You've already added every station we suggest here.")
                    .font(CarbonFont.sans(11.5))
                    .foregroundStyle(theme.ink4)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(suggestions) { suggestion in
                            SuggestionRow(suggestion: suggestion) {
                                model.addSuggestedStream(suggestion)
                            }
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 8)
                }
            }
        }
        .background(theme.isDark ? Color.black.opacity(0.25) : Color.black.opacity(0.03))
    }
}

private struct SuggestionRow: View {
    @Environment(\.carbon) private var theme
    let suggestion: StreamSuggestion
    let onAdd: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onAdd) {
            HStack(spacing: 8) {
                Image(systemName: suggestion.kind == .live ? "dot.radiowaves.left.and.right" : "play.rectangle")
                    .font(.system(size: 11))
                    .foregroundStyle(suggestion.kind == .live ? theme.orange : theme.ink3)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(suggestion.title)
                        .font(CarbonFont.sans(11.5, weight: .medium))
                        .foregroundStyle(theme.ink)
                        .lineLimit(1)
                    Text(suggestion.blurb)
                        .font(CarbonFont.mono(8.5))
                        .foregroundStyle(theme.ink4)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: "plus.circle")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(hovering ? theme.orange : theme.ink4)
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
        .carbonTip(suggestion.channel)
    }
}
