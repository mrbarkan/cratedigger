import CrateDiggerCore
import SwiftUI

/// Everything lined up to be written, in two kinds.
///
/// **Crate queue** — what the settings above will convert right now, resolved
/// through the same `OutputPathPlanner` the conversion uses, so the listed
/// filename is the one that gets written. CONVERT (below) runs it.
///
/// **Device queues** — what's waiting for each external device. Those are
/// *pre*-conversions: they bake into a staging tree so the eventual SYNC is a
/// plain copy, and they use the device's own format, not the settings above.
/// Keeping both lists here is the point — before this, the only place a device
/// queue existed was a bar on that device's screen, so "what am I about to
/// convert" had two answers in two places.
struct ConversionQueueView: View {
    @Environment(\.carbon) private var theme
    @EnvironmentObject private var model: LibraryViewModel

    /// Loaded on appear rather than held on the view model: the rows are only
    /// wanted while this tab is up, and a resident copy of every queue is a
    /// second library in memory.
    @State private var deviceEntries: [UUID: [DeviceSyncQueueEntry]] = [:]

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(model.queuedDeviceProfiles) { profile in
                    deviceSection(profile)
                    sectionRule
                }
                crateSection
            }
        }
        .onAppear(perform: loadDeviceEntries)
        // Queueing, clearing or pre-converting elsewhere changes these lists.
        .onChange(of: model.syncQueueCounts) { _ in loadDeviceEntries() }
        .onChange(of: model.syncQueueSummaries) { _ in loadDeviceEntries() }
    }

    private func loadDeviceEntries() {
        deviceEntries = Dictionary(
            uniqueKeysWithValues: model.queuedDeviceProfiles.map {
                ($0.id, model.syncQueueEntries(profileID: $0.id))
            }
        )
    }

    private var sectionRule: some View {
        Rectangle()
            .fill(theme.isDark ? Color.white.opacity(0.07) : Color.black.opacity(0.09))
            .frame(height: 1)
            .padding(.vertical, 4)
    }

    // MARK: - Device queues (pre-conversion)

    @ViewBuilder
    private func deviceSection(_ profile: ExternalDeviceProfile) -> some View {
        let summary = model.syncQueueSummary(profileID: profile.id)
        sectionHeader(
            title: "DEVICE QUEUE · \(profile.name.uppercased())",
            detail: summary.headline.uppercased(),
            stacked: true
        ) {
            // Copy-mode devices have nothing to bake, so the key would be a
            // permanently dead control.
            if summary.pendingConversionCount > 0 {
                KeyButton(style: .normal, action: { model.convertQueuedTransfers(profileID: profile.id) }) {
                    Text("PRE-CONVERT")
                }
                .frame(width: 96, height: 18)
                .disabled(model.isConversionRunning)
                .carbonTip("Convert the \(summary.pendingConversionCount) unconverted track"
                           + (summary.pendingConversionCount == 1 ? "" : "s")
                           + " to \(profile.transferSettings.summary) now, so SYNC is just a copy")
            }
        }

        ForEach(Array((deviceEntries[profile.id] ?? []).enumerated()), id: \.element.id) { index, entry in
            ConversionQueueRow(
                loaded: entry.track,
                position: index + 1,
                destination: entry.destinationRelativePath,
                badge: entry.isStaged ? "READY" : profile.transferSettings.outputFormat.fileExtension.uppercased(),
                badgeIsDone: entry.isStaged
            )
        }
    }

    // MARK: - Crate queue (convert now, with the settings above)

    @ViewBuilder
    private var crateSection: some View {
        // The scope is named in the header because all three are lists you
        // point at, and which one is live decides what CONVERT touches.
        sectionHeader(
            title: "CRATE QUEUE",
            detail: "\(model.conversionSelection.batchScope.shortTitle.uppercased()) · \(summary)",
            stacked: true
        ) {
            // Only the convert queue is ours to empty: Prep and Selection are
            // owned elsewhere, and a CLEAR that quietly emptied the Prep Crate
            // would be a very expensive surprise.
            if model.conversionSelection.batchScope == .queue, !model.convertQueue.isEmpty {
                KeyButton(style: .normal, action: { model.clearConvertQueue() }) {
                    Text("CLEAR")
                }
                .frame(width: 66, height: 18)
                .carbonTip("Empty the convert queue")
            }
        }
        if model.conversionQueueTracks.isEmpty {
            empty
        } else {
            ForEach(Array(model.conversionQueueTracks.enumerated()), id: \.element.track.id) { index, loaded in
                ConversionQueueRow(
                    loaded: loaded,
                    position: index + 1,
                    destination: model.plannedOutputName(for: loaded),
                    badge: loaded.track.formatName ?? "—",
                    badgeIsDone: false
                )
            }
        }
    }

    // MARK: - Header

    /// One line when the title and detail are short (the crate queue); stacked
    /// when a device name and a size have to share the row with a key, which in
    /// this column truncates both down to "DEVICE Q…".
    private func sectionHeader<Accessory: View>(
        title: String,
        detail: String,
        stacked: Bool = false,
        @ViewBuilder accessory: () -> Accessory
    ) -> some View {
        HStack(spacing: 8) {
            if stacked {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(CarbonFont.mono(8.5, weight: .semibold))
                        .tracking(2.2)
                        .foregroundStyle(theme.ink3)
                        .lineLimit(1)
                    Text(detail)
                        .font(CarbonFont.mono(8.5, weight: .semibold))
                        .tracking(1.2)
                        .foregroundStyle(theme.ink4)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
            } else {
                Text(title)
                    .font(CarbonFont.mono(8.5, weight: .semibold))
                    .tracking(2.2)
                    .foregroundStyle(theme.ink3)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(detail)
                    .font(CarbonFont.mono(8.5, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(theme.ink4)
                    .lineLimit(1)
            }
            accessory()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .overlay(
            Rectangle()
                .fill(theme.isDark ? Color.white.opacity(0.05) : Color.black.opacity(0.07))
                .frame(height: 1),
            alignment: .bottom
        )
    }

    private var summary: String {
        let tracks = model.conversionQueueTracks
        guard !tracks.isEmpty else { return "—" }
        let noun = tracks.count == 1 ? "TRACK" : "TRACKS"
        let seconds = model.conversionQueueDurationSeconds
        return seconds > 0
            ? "\(tracks.count) \(noun) · \(SleepMode.clockLabel(Int(seconds)))"
            : "\(tracks.count) \(noun)"
    }

    private var emptyTitle: String {
        switch model.conversionSelection.batchScope {
        case .queue:     return "Convert queue is empty"
        case .prep:      return "Prep Crate is empty"
        case .selection: return "Nothing selected"
        }
    }

    private var emptyDetail: String {
        switch model.conversionSelection.batchScope {
        case .queue:     return "Right-click anything in the browser and choose Add to Convert Queue."
        case .prep:      return "Scanned folders land in the Prep Crate before you file them."
        case .selection: return "Select an artist, album or tracks in the browser."
        }
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Text(emptyTitle)
                .font(CarbonFont.sans(12, weight: .semibold))
                .foregroundStyle(theme.ink3)
            Text(emptyDetail)
                .font(CarbonFont.sans(11))
                .multilineTextAlignment(.center)
                .foregroundStyle(theme.ink4)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }
}

private struct ConversionQueueRow: View {
    @Environment(\.carbon) private var theme
    let loaded: LoadedTrack
    let position: Int
    /// Filename the planner will write, or nil if it can't be resolved yet.
    let destination: String?
    /// Trailing chip: source format for a crate row, target format (or READY)
    /// for a device row.
    var badge: String = "—"
    /// Already converted and waiting — drawn as done rather than pending.
    var badgeIsDone: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            Text(String(format: "%02d", position))
                .font(CarbonFont.mono(9))
                .foregroundStyle(theme.ink4)
                .frame(width: 20, alignment: .trailing)

            VStack(alignment: .leading, spacing: 1) {
                Text(loaded.track.title)
                    .font(CarbonFont.sans(11.5, weight: .medium))
                    .foregroundStyle(theme.ink)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.system(size: 7))
                        .foregroundStyle(theme.ink4)
                    Text(destination ?? loaded.track.fileURL.lastPathComponent)
                        .font(CarbonFont.mono(8.5))
                        .foregroundStyle(destination == nil ? theme.ink4.opacity(0.6) : theme.cyan)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(badge)
                .font(CarbonFont.mono(8, weight: badgeIsDone ? .bold : .regular))
                .tracking(0.8)
                .foregroundStyle(badgeIsDone ? theme.orange : theme.ink4)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .overlay(
            Rectangle()
                .fill(theme.isDark ? Color.white.opacity(0.035) : Color.black.opacity(0.045))
                .frame(height: 1),
            alignment: .bottom
        )
    }
}
