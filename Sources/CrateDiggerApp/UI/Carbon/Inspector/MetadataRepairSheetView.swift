import SwiftUI
import CrateDiggerCore

/// Review sheet for FIX TAGS conflicts: tracks whose stored tags differ from
/// what's in the files. Each row can adopt the file's value; unchecked rows
/// keep the crate's current value.
struct MetadataRepairSheetView: View {
    @Environment(\.carbon) private var theme
    @EnvironmentObject private var model: LibraryViewModel

    /// Checked rows, keyed per track.
    @State private var chosen: [UUID: Set<MetadataRepairField>] = [:]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("TAGS THAT DIFFER FROM THE FILES")
                    .font(CarbonFont.mono(10, weight: .bold))
                    .tracking(1.6)
                    .foregroundStyle(theme.ink2)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Checked fields take the file's value; unchecked keep what's in your crate. Nothing is written to the audio files either way.")
                        .font(CarbonFont.sans(10, weight: .regular))
                        .foregroundStyle(theme.ink3)

                    ForEach(model.metadataRepairConflicts) { group in
                        groupCard(group)
                    }
                }
                .padding(16)
            }

            Divider()

            HStack(spacing: 8) {
                KeyButton(style: .normal, action: toggleSelectAll) {
                    Text(allSelected ? "CLEAR ALL" : "SELECT ALL")
                        .font(CarbonFont.mono(9, weight: .bold))
                }
                .frame(width: 110, height: CarbonLayout.keyHeight)

                Spacer()

                KeyButton(style: .normal, action: { model.metadataRepairConflicts = [] }) {
                    Text("CANCEL")
                        .font(CarbonFont.mono(9, weight: .bold))
                }
                .frame(width: 90, height: CarbonLayout.keyHeight)

                KeyButton(style: .selected, action: apply) {
                    Text("APPLY SELECTED")
                        .font(CarbonFont.mono(9, weight: .bold))
                }
                .frame(width: 140, height: CarbonLayout.keyHeight)
                .disabled(chosen.values.allSatisfy(\.isEmpty))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(width: 640, height: 480)
    }

    private func groupCard(_ group: MetadataRepairConflictGroup) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(group.trackTitle)
                .font(CarbonFont.mono(10, weight: .bold))
                .foregroundStyle(theme.ink)
            Text(group.fileURL.lastPathComponent)
                .font(CarbonFont.mono(8, weight: .regular))
                .foregroundStyle(theme.ink4)
                .lineLimit(1)
                .truncationMode(.middle)

            ForEach(group.conflicts) { conflict in
                Toggle(isOn: binding(group.trackID, conflict.field)) {
                    conflictRow(group.trackID, conflict)
                }
                .toggleStyle(.checkbox)
            }
        }
        .padding(10)
        // Fill the sheet's width — content-hugging cards left a ragged column
        // of different widths with dead space to the right.
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.isDark ? Color.white.opacity(0.04) : Color.black.opacity(0.03))
        .cornerRadius(6)
    }

    private func conflictRow(_ trackID: UUID, _ conflict: MetadataFieldConflict) -> some View {
        HStack(spacing: 6) {
            Text(conflict.field.rawValue)
                .font(CarbonFont.mono(9, weight: .bold))
                .foregroundStyle(theme.ink2)
                .frame(width: 80, alignment: .leading)
            Text(conflict.storedValue)
                .font(CarbonFont.mono(9, weight: .regular))
                .foregroundStyle(theme.ink3)
                .strikethrough(isChosen(trackID, conflict.field))
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(-1)
            Image(systemName: "arrow.right")
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(theme.ink4)
            Text(conflict.probedValue)
                .font(CarbonFont.mono(9, weight: .semibold))
                .foregroundStyle(theme.ink)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
    }

    /// Every conflict row currently checked?
    private var allSelected: Bool {
        model.metadataRepairConflicts.allSatisfy { group in
            group.conflicts.allSatisfy { isChosen(group.trackID, $0.field) }
        }
    }

    private func toggleSelectAll() {
        if allSelected {
            chosen = [:]
        } else {
            chosen = Dictionary(uniqueKeysWithValues: model.metadataRepairConflicts.map { group in
                (group.trackID, Set(group.conflicts.map(\.field)))
            })
        }
    }

    private func isChosen(_ trackID: UUID, _ field: MetadataRepairField) -> Bool {
        chosen[trackID]?.contains(field) ?? false
    }

    private func binding(_ trackID: UUID, _ field: MetadataRepairField) -> Binding<Bool> {
        Binding(
            get: { isChosen(trackID, field) },
            set: { on in
                var fields = chosen[trackID] ?? []
                if on { fields.insert(field) } else { fields.remove(field) }
                chosen[trackID] = fields
            }
        )
    }

    private func apply() {
        model.resolveMetadataRepairConflicts(chosen.mapValues(Array.init))
    }
}
