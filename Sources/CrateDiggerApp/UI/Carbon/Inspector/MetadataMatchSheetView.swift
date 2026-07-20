import CrateDiggerCore
import SwiftUI

/// Review sheet for FIX TAGS' online lookup: the matched release up top, then
/// one checkbox per field that would change. Checked fields are written to the
/// files on APPLY; unchecked are left exactly as they are.
///
/// Fields default to checked — the user asked for a fix, so the common case is
/// "yes, all of it" — but nothing is written until they say so, and the release
/// that's proposing the change is named right there with its runners-up one
/// click away.
struct MetadataMatchSheetView: View {
    @Environment(\.carbon) private var theme
    @EnvironmentObject private var model: LibraryViewModel

    /// Which of the release's candidates is being reviewed.
    @State private var candidateIndex = 0
    /// Fields to write. Seeded from the match; edits persist per candidate.
    @State private var checked: Set<MetadataRepairField> = []
    @State private var expandedFields: Set<MetadataRepairField> = []

    private var matches: [ReleaseMatch] { model.metadataMatches }
    private var match: ReleaseMatch? {
        guard matches.indices.contains(candidateIndex) else { return matches.first }
        return matches[candidateIndex]
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            if let match {
                releaseCard(match)
                Divider()
                fieldList(match)
                Divider()
                footer(match)
            }
        }
        .frame(width: 660, height: 520)
        .onAppear { seedChecks() }
        .onChange(of: candidateIndex) { _ in seedChecks() }
        .onChange(of: model.currentMatchAlbumLabel) { _ in
            candidateIndex = 0
            seedChecks()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("MATCHING TAGS")
                .font(CarbonFont.mono(10, weight: .bold))
                .tracking(1.6)
                .foregroundStyle(theme.ink2)
            Spacer()
            if let progress = model.matchQueueProgress {
                Text("ALBUM \(progress.current) OF \(progress.total)\(model.currentMatchAlbumLabel.map { " · \($0.uppercased())" } ?? "")")
                    .font(CarbonFont.mono(8, weight: .bold))
                    .tracking(1.2)
                    .foregroundStyle(theme.orange)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            if matches.count > 1 {
                Text("\(candidateIndex + 1) OF \(matches.count) MATCHES")
                    .font(CarbonFont.mono(8, weight: .bold))
                    .tracking(1.2)
                    .foregroundStyle(theme.ink4)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Release card

    private func releaseCard(_ match: ReleaseMatch) -> some View {
        HStack(spacing: 12) {
            artwork(match.candidate)

            VStack(alignment: .leading, spacing: 3) {
                Text(match.candidate.title)
                    .font(CarbonFont.mono(12, weight: .bold))
                    .foregroundStyle(theme.ink)
                    .lineLimit(1)
                Text(subtitle(match.candidate))
                    .font(CarbonFont.mono(9, weight: .regular))
                    .foregroundStyle(theme.ink3)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    sourceBadge(match.candidate.source)
                    Text("\(Int((match.score * 100).rounded()))% MATCH")
                        .font(CarbonFont.mono(8, weight: .bold))
                        .tracking(0.8)
                        .foregroundStyle(theme.ink4)
                }
                .padding(.top, 2)
            }

            Spacer(minLength: 8)

            if matches.count > 1 {
                candidateStepper
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private func artwork(_ candidate: ReleaseCandidate) -> some View {
        // The release's own cover, straight from the source — a fast visual
        // check that this is the right pressing. Local art isn't substituted:
        // showing the file's current cover here would defeat the point.
        AsyncImage(url: candidate.artworkURL) { image in
            image.resizable().aspectRatio(contentMode: .fill)
        } placeholder: {
            ZStack {
                Rectangle().fill(theme.well)
                Image(systemName: "opticaldisc")
                    .font(.system(size: 16))
                    .foregroundStyle(theme.ink4)
            }
        }
        .frame(width: 52, height: 52)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(Color.black.opacity(0.25), lineWidth: 0.5)
        )
    }

    private func subtitle(_ candidate: ReleaseCandidate) -> String {
        var parts = [candidate.artist]
        if let year = candidate.year { parts.append(String(year)) }
        if let total = candidate.totalTracks { parts.append("\(total) tracks") }
        if let genre = candidate.genre { parts.append(genre) }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func sourceBadge(_ source: ReleaseSource) -> some View {
        Text(source.label.uppercased())
            .font(CarbonFont.mono(7, weight: .bold))
            .tracking(0.9)
            .foregroundStyle(theme.orange)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(theme.orange.opacity(0.14))
            )
    }

    private var candidateStepper: some View {
        HStack(spacing: 6) {
            KeyButton(style: candidateIndex > 0 ? .normal : .disabled, action: {
                candidateIndex = max(0, candidateIndex - 1)
            }) {
                Image(systemName: "chevron.left").font(.system(size: 9, weight: .bold))
            }
            .frame(width: 30, height: 24)

            KeyButton(style: candidateIndex < matches.count - 1 ? .normal : .disabled, action: {
                candidateIndex = min(matches.count - 1, candidateIndex + 1)
            }) {
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
            }
            .frame(width: 30, height: 24)
        }
        .carbonTip("Not the right release? Step through the other matches.")
    }

    // MARK: - Fields

    private func fieldList(_ match: ReleaseMatch) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Checked fields are written to the \(match.trackProposals.count == 1 ? "file" : "files"). Unchecked fields keep their current value.")
                    .font(CarbonFont.sans(10, weight: .regular))
                    .foregroundStyle(theme.ink3)

                ForEach(match.changedFields, id: \.self) { field in
                    fieldCard(field, in: match)
                }
            }
            .padding(16)
        }
    }

    private func fieldCard(_ field: MetadataRepairField, in match: ReleaseMatch) -> some View {
        let changes = self.changes(for: field, in: match)
        let uniform = uniformChange(changes)

        return VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: binding(field)) {
                HStack(spacing: 6) {
                    Text(field.rawValue)
                        .font(CarbonFont.mono(9, weight: .bold))
                        .foregroundStyle(theme.ink2)
                        .frame(width: 84, alignment: .leading)

                    if let uniform {
                        valueDiff(from: uniform.current, to: uniform.proposed, checked: checked.contains(field))
                    } else {
                        Text("\(changes.count) tracks change")
                            .font(CarbonFont.mono(9, weight: .regular))
                            .foregroundStyle(theme.ink3)
                        Button(expandedFields.contains(field) ? "hide" : "show") {
                            if expandedFields.contains(field) {
                                expandedFields.remove(field)
                            } else {
                                expandedFields.insert(field)
                            }
                        }
                        .buttonStyle(.link)
                        .font(CarbonFont.mono(8, weight: .regular))
                    }
                    Spacer(minLength: 0)
                }
            }
            .toggleStyle(.checkbox)

            if uniform == nil, expandedFields.contains(field) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(changes, id: \.trackID) { change in
                        HStack(spacing: 6) {
                            Text(change.trackTitle)
                                .font(CarbonFont.mono(8, weight: .regular))
                                .foregroundStyle(theme.ink4)
                                .frame(width: 150, alignment: .leading)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            valueDiff(from: change.current, to: change.proposed, checked: checked.contains(field))
                            Spacer(minLength: 0)
                        }
                    }
                }
                .padding(.leading, 104)
                .padding(.top, 2)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.isDark ? Color.white.opacity(0.04) : Color.black.opacity(0.03))
        .cornerRadius(6)
    }

    private func valueDiff(from current: String, to proposed: String, checked: Bool) -> some View {
        HStack(spacing: 6) {
            Text(current.isEmpty ? "—" : current)
                .font(CarbonFont.mono(9, weight: .regular))
                .foregroundStyle(theme.ink3)
                .strikethrough(checked)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(-1)
            Image(systemName: "arrow.right")
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(theme.ink4)
            Text(proposed.isEmpty ? "—" : proposed)
                .font(CarbonFont.mono(9, weight: .semibold))
                .foregroundStyle(checked ? theme.ink : theme.ink3)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    // MARK: - Footer

    private func footer(_ match: ReleaseMatch) -> some View {
        HStack(spacing: 8) {
            KeyButton(style: .normal, action: { toggleSelectAll(match) }) {
                Text(allChecked(match) ? "CLEAR ALL" : "SELECT ALL")
                    .font(CarbonFont.mono(9, weight: .bold))
            }
            .frame(width: 110, height: CarbonLayout.keyHeight)

            Text(applyScope(match))
                .font(CarbonFont.mono(8, weight: .regular))
                .foregroundStyle(theme.ink4)
                .padding(.leading, 4)

            Spacer()

            KeyButton(style: .normal, action: { model.cancelMatchQueue() }) {
                Text("CANCEL")
                    .font(CarbonFont.mono(9, weight: .bold))
            }
            .frame(width: 90, height: CarbonLayout.keyHeight)

            if model.matchQueueProgress != nil {
                KeyButton(style: .normal, action: { model.advanceMatchQueue() }) {
                    Text("SKIP")
                        .font(CarbonFont.mono(9, weight: .bold))
                }
                .frame(width: 80, height: CarbonLayout.keyHeight)
                .help("Leave this album unchanged and review the next one")
            }

            KeyButton(style: checked.isEmpty ? .disabled : .selected, action: {
                model.applyReleaseMatch(match, fields: checked)
            }) {
                Text("APPLY")
                    .font(CarbonFont.mono(9, weight: .bold))
            }
            .frame(width: 110, height: CarbonLayout.keyHeight)
            .disabled(checked.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func applyScope(_ match: ReleaseMatch) -> String {
        let tracks = match.trackProposals.filter { proposal in
            proposal.changedFields.contains { checked.contains($0) }
        }.count
        guard tracks > 0 else { return "Nothing selected" }
        return "Writes \(checked.count) field\(checked.count == 1 ? "" : "s") on \(tracks) track\(tracks == 1 ? "" : "s")"
    }

    // MARK: - Helpers

    private struct FieldChange {
        let trackID: UUID
        let trackTitle: String
        let current: String
        let proposed: String
    }

    private func changes(for field: MetadataRepairField, in match: ReleaseMatch) -> [FieldChange] {
        match.trackProposals.compactMap { proposal in
            guard proposal.changedFields.contains(field) else { return nil }
            return FieldChange(
                trackID: proposal.trackID,
                trackTitle: proposal.trackTitle,
                current: MetadataRepairPlanner.value(of: field, in: proposal.current) ?? "",
                proposed: MetadataRepairPlanner.value(of: field, in: proposal.proposed) ?? ""
            )
        }
    }

    /// One line instead of N when every track's change is the same — which it is
    /// for album-wide fields (album, year, genre), i.e. most of the sheet.
    private func uniformChange(_ changes: [FieldChange]) -> (current: String, proposed: String)? {
        guard let first = changes.first else { return nil }
        guard changes.count == 1 || changes.allSatisfy({
            $0.current == first.current && $0.proposed == first.proposed
        }) else { return nil }
        return (first.current, first.proposed)
    }

    private func binding(_ field: MetadataRepairField) -> Binding<Bool> {
        Binding(
            get: { checked.contains(field) },
            set: { on in
                if on { checked.insert(field) } else { checked.remove(field) }
            }
        )
    }

    private func allChecked(_ match: ReleaseMatch) -> Bool {
        !match.changedFields.isEmpty && Set(match.changedFields).isSubset(of: checked)
    }

    private func toggleSelectAll(_ match: ReleaseMatch) {
        checked = allChecked(match) ? [] : Set(match.changedFields)
    }

    private func seedChecks() {
        checked = Set(match?.changedFields ?? [])
        expandedFields = []
    }
}
