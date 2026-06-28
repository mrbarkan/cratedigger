import CrateDiggerCore
import SwiftUI

/// Review sheet for Record Divider: shows the tracks detected inside a vinyl-side
/// rip and lets the user keep/skip, rename, and fix boundaries (nudge / merge /
/// split) before saving them as `recordMarkers`. Presented from
/// `model.showingRecordDividerSheet` (track context menu → "Record Divider…").
struct RecordDividerSheet: View {
    @Environment(\.carbon) private var theme
    @EnvironmentObject private var model: LibraryViewModel

    private var keptCount: Int { model.recordDividerRows.filter(\.keep).count }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            sensitivityRow
            if let hint = model.recordDividerHint {
                Text(hint)
                    .font(CarbonFont.mono(9.5))
                    .foregroundStyle(theme.orange)
            }
            rowsArea
            footer
        }
        .padding(20)
        .frame(width: 580, height: 560)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Circle().fill(theme.orange).frame(width: 7, height: 7)
            Text("RECORD DIVIDER")
                .font(CarbonFont.mono(11, weight: .bold))
                .tracking(2)
                .foregroundStyle(theme.ink)
            Spacer()
            if let name = model.recordDividerTrack?.track.fileURL.lastPathComponent {
                Text(name)
                    .font(CarbonFont.mono(9))
                    .foregroundStyle(theme.ink3)
                    .lineLimit(1)
            }
        }
    }

    // MARK: - Sensitivity + re-scan

    private var sensitivityRow: some View {
        HStack(spacing: 12) {
            Text("SENSITIVITY")
                .font(CarbonFont.mono(8.5, weight: .bold))
                .tracking(1.4)
                .foregroundStyle(theme.ink3)
            Slider(value: $model.recordDividerSensitivity, in: 0...1)
                .frame(maxWidth: 200)
                .disabled(model.recordDividerIsScanning)
            Text(sensitivityLabel)
                .font(CarbonFont.mono(8.5))
                .foregroundStyle(theme.ink4)
            Spacer()
            Button(action: { model.rescanRecordDivider() }) {
                HStack(spacing: 5) {
                    if model.recordDividerIsScanning {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise").font(.system(size: 9, weight: .bold))
                    }
                    Text(model.recordDividerIsScanning ? "SCANNING…" : "RE-SCAN")
                        .font(CarbonFont.mono(8.5, weight: .bold))
                        .tracking(1)
                }
                .foregroundStyle(theme.cyan)
            }
            .buttonStyle(.plain)
            .disabled(model.recordDividerIsScanning)
        }
    }

    private var sensitivityLabel: String {
        let v = model.recordDividerSensitivity
        if v < 0.34 { return "Few / long gaps" }
        if v < 0.67 { return "Balanced" }
        return "Many / short gaps"
    }

    // MARK: - Rows

    @ViewBuilder
    private var rowsArea: some View {
        if model.recordDividerIsScanning && model.recordDividerRows.isEmpty {
            VStack(spacing: 8) {
                Spacer()
                ProgressView()
                Text("Scanning for tracks…")
                    .font(CarbonFont.mono(9.5))
                    .foregroundStyle(theme.ink3)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.recordDividerRows.isEmpty {
            VStack(spacing: 6) {
                Spacer()
                Text("No tracks")
                    .font(CarbonFont.sans(13, weight: .medium))
                    .foregroundStyle(theme.ink3)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(Array(model.recordDividerRows.enumerated()), id: \.element.id) { index, row in
                        rowView(index: index, row: row)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 8).fill(theme.ink.opacity(theme.isDark ? 0.04 : 0.03)))
        }
    }

    private func rowView(index: Int, row: RecordDividerDraftRow) -> some View {
        let isLast = index == model.recordDividerRows.count - 1
        return HStack(spacing: 8) {
            Toggle("", isOn: Binding(get: { row.keep }, set: { _ in model.recordDividerToggleKeep(row.id) }))
                .labelsHidden()
                .toggleStyle(.checkbox)
                .carbonTip(row.keep ? "This track will be exported" : "Skipped — won't be exported")

            Text(String(format: "%02d", index + 1))
                .font(CarbonFont.mono(9, weight: .semibold))
                .foregroundStyle(theme.ink4)
                .frame(width: 20, alignment: .leading)

            TextField("Title", text: Binding(get: { row.title },
                                             set: { model.recordDividerRename(row.id, to: $0) }))
                .textFieldStyle(.roundedBorder)
                .font(CarbonFont.sans(12))
                .frame(minWidth: 120)
                .opacity(row.keep ? 1 : 0.45)

            edgeStepper(label: row.startSeconds.asClockHMS, id: row.id, isStart: true)
            edgeStepper(label: row.endSeconds.asClockHMS, id: row.id, isStart: false)

            Text(row.durationSeconds.asClock)
                .font(CarbonFont.mono(8.5))
                .foregroundStyle(theme.ink4)
                .frame(width: 48, alignment: .trailing)

            Button(action: { model.recordDividerSplit(row.id) }) {
                Image(systemName: "scissors").font(.system(size: 9))
            }
            .buttonStyle(.plain).foregroundStyle(theme.ink3).carbonTip("Split at midpoint")

            Button(action: { model.recordDividerMergeWithNext(row.id) }) {
                Image(systemName: "arrow.triangle.merge").font(.system(size: 9))
            }
            .buttonStyle(.plain).foregroundStyle(isLast ? theme.ink4.opacity(0.4) : theme.ink3)
            .disabled(isLast).carbonTip("Merge with next")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    /// A boundary value with −/+ nudge buttons (±1 s).
    private func edgeStepper(label: String, id: UUID, isStart: Bool) -> some View {
        HStack(spacing: 2) {
            Button(action: { model.recordDividerNudge(id, isStart: isStart, by: -1) }) {
                Image(systemName: "minus").font(.system(size: 7, weight: .bold))
            }
            .buttonStyle(.plain).foregroundStyle(theme.ink3)
            Text(label)
                .font(CarbonFont.mono(8.5))
                .foregroundStyle(theme.ink2)
                .frame(width: 46)
            Button(action: { model.recordDividerNudge(id, isStart: isStart, by: 1) }) {
                Image(systemName: "plus").font(.system(size: 7, weight: .bold))
            }
            .buttonStyle(.plain).foregroundStyle(theme.ink3)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 4).fill(theme.ink.opacity(0.05)))
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Text("\(keptCount) of \(model.recordDividerRows.count) kept")
                .font(CarbonFont.mono(9))
                .foregroundStyle(theme.ink3)
            Spacer()
            Button("Cancel") { model.cancelRecordDivider() }
                .keyboardShortcut(.cancelAction)
            Button("Save Markers") { model.applyRecordDivider() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(model.recordDividerIsScanning)
        }
    }

}
