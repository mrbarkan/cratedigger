import SwiftUI
import CrateDiggerCore

struct LibraryCleanupView: View {
    @Environment(\.carbon) private var theme
    @EnvironmentObject private var model: LibraryViewModel

    @State private var activeTab = 0

    var body: some View {
        VStack(spacing: 0) {
            header
            tabSwitcher
            
            if activeTab == 0 {
                deadTracksTab
            } else {
                duplicatesTab
            }
        }
        .background(theme.chassis)
        .onAppear {
            model.scanForCleanup()
        }
    }

    private var header: some View {
        HStack {
            Text("Library Maintenance Wells".uppercased())
                .font(CarbonFont.mono(11, weight: .bold))
                .tracking(2)
                .foregroundStyle(theme.ink)
            Spacer()
            Button("Re-Scan") {
                model.scanForCleanup()
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(theme.chassisHi)
        .overlay(Rectangle().fill(Color.black.opacity(0.12)).frame(height: 1), alignment: .bottom)
    }

    private var tabSwitcher: some View {
        HStack(spacing: 0) {
            Button(action: { activeTab = 0 }) {
                Text("Dead Tracks (\(model.deadTracks.count))")
                    .font(CarbonFont.mono(9.5, weight: .bold))
                    .foregroundColor(activeTab == 0 ? theme.orange : theme.ink3)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .background(activeTab == 0 ? theme.chassis : theme.chassisHi)
            }
            .buttonStyle(.plain)

            Button(action: { activeTab = 1 }) {
                Text("Duplicates (\(model.duplicateGroups.count) groups)")
                    .font(CarbonFont.mono(9.5, weight: .bold))
                    .foregroundColor(activeTab == 1 ? theme.orange : theme.ink3)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .background(activeTab == 1 ? theme.chassis : theme.chassisHi)
            }
            .buttonStyle(.plain)
        }
        .overlay(Rectangle().fill(Color.black.opacity(0.12)).frame(height: 1), alignment: .bottom)
    }

    // MARK: - Dead Tracks Tab

    private var deadTracksTab: some View {
        VStack(spacing: 0) {
            if model.deadTracks.isEmpty {
                VStack {
                    Spacer()
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 40))
                        .foregroundColor(.green)
                        .padding(.bottom, 8)
                    Text("No dead tracks found! All file paths exist on disk.")
                        .font(CarbonFont.sans(12))
                        .foregroundColor(.secondary)
                    Spacer()
                }
            } else {
                List {
                    ForEach(model.deadTracks) { loaded in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(loaded.track.title)
                                    .font(CarbonFont.sans(12, weight: .bold))
                                Text(loaded.track.fileURL.path)
                                    .font(CarbonFont.mono(8.5))
                                    .foregroundColor(.red)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 4)
                    }
                }

                HStack {
                    Text("These tracks refer to files that no longer exist. Removing them will clean up your CrateDigger library display.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    KeyButton(style: .selected, action: {
                        model.deleteDeadTracks()
                    }) {
                        Text("REMOVE FROM LIBRARY")
                            .font(CarbonFont.mono(9, weight: .bold))
                            .tracking(1.4)
                    }
                    .frame(width: 170, height: CarbonLayout.keyHeight)
                }
                .padding(14)
                .background(theme.chassisHi)
            }
        }
    }

    // MARK: - Duplicates Tab

    private var duplicatesTab: some View {
        VStack(spacing: 0) {
            if model.duplicateGroups.isEmpty {
                VStack {
                    Spacer()
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 40))
                        .foregroundColor(.green)
                        .padding(.bottom, 8)
                    Text("No duplicate tracks found!")
                        .font(CarbonFont.sans(12))
                        .foregroundColor(.secondary)
                    Spacer()
                }
            } else {
                List {
                    ForEach(model.duplicateGroups) { group in
                        VStack(alignment: .leading, spacing: 6) {
                            Text("\(group.bestTrack.track.artist) - \(group.bestTrack.track.title)")
                                .font(CarbonFont.sans(12.5, weight: .bold))
                                .foregroundColor(theme.ink)
                            
                            // Best version
                            HStack {
                                Image(systemName: "star.fill")
                                    .foregroundColor(.yellow)
                                    .font(.system(size: 9))
                                Text("[BEST]")
                                    .font(CarbonFont.mono(8, weight: .bold))
                                    .foregroundColor(.green)
                                Text(specString(for: group.bestTrack))
                                    .font(CarbonFont.mono(9))
                                Text(group.bestTrack.track.fileURL.lastPathComponent)
                                    .font(CarbonFont.mono(9))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                            .padding(.leading, 8)

                            // Worst versions
                            ForEach(group.worstTracks) { worst in
                                HStack {
                                    Image(systemName: "trash")
                                        .foregroundColor(.red.opacity(0.7))
                                        .font(.system(size: 9))
                                    Text("[DUP]")
                                        .font(CarbonFont.mono(8, weight: .bold))
                                        .foregroundColor(.red)
                                    Text(specString(for: worst))
                                        .font(CarbonFont.mono(9))
                                    Text(worst.track.fileURL.lastPathComponent)
                                        .font(CarbonFont.mono(9))
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }
                                .padding(.leading, 8)
                            }
                        }
                        .padding(.vertical, 8)
                    }
                }

                HStack(spacing: 12) {
                    Button("Export Best versions") {
                        chooseAndExport(best: true)
                    }
                    Button("Export Dup versions") {
                        chooseAndExport(best: false)
                    }
                    Spacer()
                    KeyButton(style: .selected, action: {
                        model.resolveDuplicates()
                    }) {
                        Text("MOVE DUPLICATES TO TRASH")
                            .font(CarbonFont.mono(9, weight: .bold))
                            .tracking(1.2)
                    }
                    .frame(width: 200, height: CarbonLayout.keyHeight)
                }
                .padding(14)
                .background(theme.chassisHi)
            }
        }
    }

    private func specString(for track: LoadedTrack) -> String {
        let fmt = track.track.formatName ?? "Unknown"
        let rate = track.track.bitrateKbps.map { "\($0)kbps" } ?? ""
        let sample = track.track.sampleRateHz.map { "\($0/1000)kHz" } ?? ""
        return "(\([fmt, rate, sample].filter { !$0.isEmpty }.joined(separator: " · ")))"
    }

    private func chooseAndExport(best: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "Choose export destination folder"
        panel.prompt = "Export"
        
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.exportDuplicates(best: best, to: url)
    }
}
