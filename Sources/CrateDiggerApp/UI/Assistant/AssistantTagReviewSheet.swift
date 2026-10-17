import CrateDiggerCore
import SwiftUI

/// Where an LLM's tag edits wait for the user. Nothing the assistant proposes
/// is written until it has been looked at here: one row per track, every
/// changed field as before → after, a box per track. APPLY writes the ticked
/// tracks; DISCARD drops the lot. Claude Desktop's "Allow always" can let a
/// model call the tool unattended, and this sheet is what keeps that from
/// becoming unattended edits to the user's files.
struct AssistantTagReviewSheet: View {
    @Environment(\.carbon) private var theme
    @EnvironmentObject private var model: LibraryViewModel

    let proposal: AssistantTagProposal
    /// Tracks to write. Every track starts ticked: the user asked for this,
    /// so the common case is "all of it", but nothing is written until APPLY.
    @State private var selected: Set<UUID>

    init(proposal: AssistantTagProposal) {
        self.proposal = proposal
        _selected = State(initialValue: Set(proposal.items.map(\.trackID)))
    }

    var body: some View {
        VStack(spacing: 0) {
            CarbonPanelHeader("Assistant Tag Review") {
                Text("\(proposal.items.count) TRACK\(proposal.items.count == 1 ? "" : "S")")
                    .font(CarbonFont.mono(8, weight: .bold))
                    .tracking(1.2)
                    .foregroundStyle(theme.ink4)
            }
            request
            Divider()
            rows
            Divider()
            footer
        }
        .frame(minWidth: 0, idealWidth: 760, maxWidth: .infinity,
               minHeight: 0, idealHeight: 600, maxHeight: .infinity)
    }

    // MARK: - Request

    private var request: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("PROPOSED BY YOUR ASSISTANT")
                .font(CarbonFont.mono(8, weight: .bold))
                .tracking(1.4)
                .foregroundStyle(theme.orange)
            Text(proposal.summary)
                .font(CarbonFont.sans(13, weight: .semibold))
                .foregroundStyle(theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text("Ticked tracks are rewritten on APPLY and can be put back with Edit ▸ Undo AI Change. Unticked tracks keep their tags.")
                .font(CarbonFont.sans(10, weight: .regular))
                .foregroundStyle(theme.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    // MARK: - Rows

    private var rows: some View {
        ScrollView {
            // Lazy: a "clean up every genre" proposal can cover the library.
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(proposal.items) { item in
                    row(item)
                }
            }
            .padding(16)
        }
    }

    private func row(_ item: AssistantTagProposal.Item) -> some View {
        let isOn = selected.contains(item.trackID)
        return Toggle(isOn: binding(item.trackID)) {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.displayTitle)
                    .font(CarbonFont.sans(11, weight: .semibold))
                    .foregroundStyle(isOn ? theme.ink : theme.ink3)
                    .lineLimit(1)
                    .truncationMode(.middle)
                ForEach(item.changedFields, id: \.self) { field in
                    HStack(spacing: 6) {
                        Text(Self.label(field))
                            .font(CarbonFont.mono(8, weight: .bold))
                            .foregroundStyle(theme.ink3)
                            .frame(width: 96, alignment: .leading)
                        TagValueDiffView(current: item.current.display(field) ?? "",
                                         proposed: item.proposed.display(field) ?? "",
                                         checked: isOn)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .toggleStyle(.checkbox)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.isDark ? Color.white.opacity(0.04) : Color.black.opacity(0.03))
        .cornerRadius(6)
    }

    static func label(_ field: String) -> String {
        field.replacingOccurrences(of: "_", with: " ").uppercased()
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            KeyButton(style: .normal, action: toggleAll) {
                Text(allSelected ? "CLEAR ALL" : "SELECT ALL")
            }
            .frame(width: 110, height: CarbonLayout.keyHeight)

            Text(scope)
                .font(CarbonFont.mono(8, weight: .regular))
                .foregroundStyle(theme.ink4)
                .padding(.leading, 4)

            Spacer()

            KeyButton(style: .normal, action: { model.discardAssistantTagProposal() }) {
                Text("DISCARD")
            }
            .frame(width: 100, height: CarbonLayout.keyHeight)
            .help("Close without changing any file. The assistant can propose again.")

            KeyButton(style: selected.isEmpty ? .disabled : .selected, action: {
                model.applyAssistantTagProposal(proposal, trackIDs: selected)
            }) {
                Text("APPLY")
            }
            .frame(width: 110, height: CarbonLayout.keyHeight)
            .disabled(selected.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var allSelected: Bool { selected.count == proposal.items.count }

    private var scope: String {
        let tracks = proposal.items.filter { selected.contains($0.trackID) }
        guard !tracks.isEmpty else { return "Nothing selected" }
        let fields = tracks.reduce(0) { $0 + $1.changedFields.count }
        return "Writes \(fields) tag\(fields == 1 ? "" : "s") on \(tracks.count) track\(tracks.count == 1 ? "" : "s")"
    }

    private func toggleAll() {
        selected = allSelected ? [] : Set(proposal.items.map(\.trackID))
    }

    private func binding(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { selected.contains(id) },
            set: { on in
                if on { selected.insert(id) } else { selected.remove(id) }
            }
        )
    }
}
