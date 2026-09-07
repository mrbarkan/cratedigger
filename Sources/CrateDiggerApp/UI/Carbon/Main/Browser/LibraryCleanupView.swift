import SwiftUI
import CrateDiggerCore

struct LibraryCleanupView: View {
    @Environment(\.carbon) private var theme
    @Environment(\.carbonGeometry) private var geometry
    @EnvironmentObject private var model: LibraryViewModel

    @State private var activeTab = 0

    /// Checked = will be trashed. Keyed by standardized file path; reseeded
    /// (worst versions pre-checked) whenever scan results change.
    @State private var checkedPaths: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            header
            tabSwitcher

            switch activeTab {
            case 0:  deadTracksTab
            case 1:  duplicatesTab
            default: artworkTab
            }
        }
        .frame(minWidth: 0, idealWidth: 720, maxWidth: .infinity,
               minHeight: 0, idealHeight: 560, maxHeight: .infinity)
        .background(theme.chassis)
        .onAppear {
            model.scanForCleanup()
        }
    }

    private var header: some View {
        // The close affordance is gone: this is a window now, so the traffic
        // lights already do it, and a second ✕ inside the panel read as clutter.
        CarbonPanelHeader("Library Maintenance Wells") {
            CarbonPanelButton(title: "Re-Scan", width: 92) { model.scanForCleanup() }
        }
    }

    private var tabSwitcher: some View {
        HStack(spacing: 0) {
            Button(action: { activeTab = 0 }) {
                Text("Missing Tracks (\(model.deadTracks.count))")
                    .font(CarbonFont.mono(9.5, weight: .bold))
                    .foregroundColor(activeTab == 0 ? theme.orange : theme.ink3)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .background(activeTab == 0 ? theme.chassis : theme.chassisHi)
            }
            .buttonStyle(.carbonHover)

            Button(action: { activeTab = 1 }) {
                Text("Duplicates (\(model.duplicateGroups.count) groups)")
                    .font(CarbonFont.mono(9.5, weight: .bold))
                    .foregroundColor(activeTab == 1 ? theme.orange : theme.ink3)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .background(activeTab == 1 ? theme.chassis : theme.chassisHi)
            }
            .buttonStyle(.carbonHover)

            Button(action: { activeTab = 2 }) {
                Text(model.artworkAudit.isEmpty ? "Artwork" : "Artwork (\(model.artworkAudit.count))")
                    .font(CarbonFont.mono(9.5, weight: .bold))
                    .foregroundColor(activeTab == 2 ? theme.orange : theme.ink3)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .background(activeTab == 2 ? theme.chassis : theme.chassisHi)
            }
            .buttonStyle(.carbonHover)
        }
        .overlay(Rectangle().fill(Color.black.opacity(0.12)).frame(height: 1), alignment: .bottom)
    }

    // MARK: - Artwork Tab
    //
    // The counterpart to the ART tab's per-album search: one sweep for every
    // album whose cover is missing or too small to look at, and one key that
    // goes and fetches better ones.

    private var artworkTab: some View {
        VStack(spacing: 0) {
            if model.isAuditingArtwork {
                centeredMessage(icon: "hourglass", title: "Measuring covers",
                                detail: "Reading image headers across the library.")
            } else if model.artworkAudit.isEmpty {
                centeredMessage(
                    icon: "checkmark.circle",
                    title: "Nothing flagged",
                    detail: "Scan to find albums with no cover, or a cover under \(ArtworkQuality.minimumLongEdge) px."
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.artworkAudit) { row in
                            artworkAuditRow(row)
                            Divider().background(theme.hair.opacity(0.5))
                        }
                    }
                }
            }

            HStack(spacing: 10) {
                Text(auditSummary)
                    .font(CarbonFont.mono(9))
                    .foregroundStyle(theme.ink3)
                Spacer()
                KeyButton(style: model.isAuditingArtwork ? .disabled : .normal,
                          action: { model.auditLibraryArtwork() }) {
                    Text("SCAN ARTWORK")
                }
                .frame(width: 130, height: geometry.keyHeight)

                KeyButton(style: model.artworkAudit.isEmpty ? .disabled : .selected,
                          action: { model.fixAuditedArtwork() }) {
                    Text("FIX ALL (\(model.artworkAudit.count))")
                }
                .frame(width: 130, height: geometry.keyHeight)
                .carbonTip("Look each flagged album up online and write the best cover found into its folder. Never replaces a cover with a smaller one.")
            }
            .padding(12)
            .background(theme.chassisHi)
            .overlay(Rectangle().fill(Color.black.opacity(0.12)).frame(height: 1), alignment: .top)
        }
    }

    private var auditSummary: String {
        guard !model.artworkAudit.isEmpty else { return "" }
        let missing = model.artworkAudit.filter { $0.verdict == .missing }.count
        let low = model.artworkAudit.count - missing
        return "\(missing) with no cover · \(low) under \(ArtworkQuality.minimumLongEdge) px"
    }

    private func artworkAuditRow(_ row: ArtworkAuditRow) -> some View {
        HStack(spacing: 10) {
            Text(row.verdict == .missing ? "NONE" : "LOW")
                .font(CarbonFont.mono(7.5, weight: .bold))
                .tracking(0.8)
                .foregroundColor(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Capsule().fill(row.verdict == .missing ? theme.orange : theme.ink3))
                .frame(width: 46)

            VStack(alignment: .leading, spacing: 1) {
                Text(row.title)
                    .font(CarbonFont.sans(11, weight: .semibold))
                    .foregroundStyle(theme.ink)
                    .lineLimit(1)
                Text(row.artist)
                    .font(CarbonFont.mono(9))
                    .foregroundStyle(theme.ink3)
                    .lineLimit(1)
            }
            Spacer()
            Text(row.sizeLabel)
                .font(CarbonFont.mono(9, weight: .semibold))
                .foregroundStyle(theme.ink4)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }

    private func centeredMessage(icon: String, title: String, detail: String) -> some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(theme.ink4)
            Text(title.uppercased())
                .font(CarbonFont.mono(10, weight: .bold))
                .tracking(1.8)
                .foregroundStyle(theme.ink2)
            Text(detail)
                .font(CarbonFont.sans(11))
                .foregroundStyle(theme.ink3)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                    Text("No missing tracks! Every file path exists on disk.")
                        .font(CarbonFont.sans(12))
                        .foregroundColor(.secondary)
                    Spacer()
                }
            } else {
                List {
                    ForEach(model.deadTracks) { loaded in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(loaded.track.title.isEmpty ? loaded.track.fileURL.lastPathComponent : loaded.track.title)
                                    .font(CarbonFont.sans(12, weight: .bold))
                                Text(loaded.track.fileURL.path)
                                    .font(CarbonFont.mono(8.5))
                                    .foregroundColor(.red)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer(minLength: 8)
                            Button("Locate…") { model.relinkMissingTrack(loaded) }
                                .font(CarbonFont.mono(9, weight: .bold))
                            Button("Remove") { model.removeMissingTrack(loaded) }
                                .font(CarbonFont.mono(9))
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .frame(maxHeight: .infinity)

                HStack(spacing: 12) {
                    Text("These files moved, were renamed, or were deleted. Point CrateDigger at the folder they moved to and it re-links every match at once.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Locate Folder…") {
                        model.relinkMissingTracksFromFolder(model.deadTracks)
                    }
                    .font(CarbonFont.mono(9, weight: .bold))
                    KeyButton(style: .selected, action: {
                        model.deleteDeadTracks()
                    }) {
                        Text("REMOVE ALL")
                    }
                    .frame(width: 120, height: geometry.keyHeight)
                }
                .padding(14)
                .background(theme.chassisHi)
            }
        }
    }

    // MARK: - Duplicates Tab

    private var duplicatesTab: some View {
        VStack(spacing: 0) {
            modeBar

            if model.isCleanupScanning {
                VStack {
                    Spacer()
                    ProgressView().controlSize(.large)
                    Text("Scanning…")
                        .font(CarbonFont.sans(12))
                        .foregroundColor(.secondary)
                        .padding(.top, 8)
                    Spacer()
                }
            } else if model.duplicateGroups.isEmpty {
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
                        duplicateGroupRow(group)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .frame(maxHeight: .infinity)

                HStack(spacing: 12) {
                    Button("Export Best versions") { chooseAndExport(best: true) }
                    Button("Export Dup versions") { chooseAndExport(best: false) }
                    Spacer()
                    KeyButton(style: checkedPaths.isEmpty ? .disabled : .selected, action: trashSelected) {
                        Text("TRASH SELECTED (\(checkedPaths.count))")
                    }
                    .frame(width: 200, height: geometry.keyHeight)
                    .disabled(checkedPaths.isEmpty)
                }
                .padding(14)
                .background(theme.chassisHi)
            }
        }
        .onChange(of: model.isCleanupScanning) { scanning in
            // Reseed only when a scan lands — NOT on every duplicateGroups
            // mutation, or ignoring one group would revert explicit
            // keep/trash choices in every other group.
            if !scanning {
                checkedPaths = Set(model.duplicateGroups.flatMap { g in
                    g.worstTracks.map { $0.track.fileURL.standardizedFileURL.path }
                })
            }
        }
        .onAppear {
            checkedPaths = Set(model.duplicateGroups.flatMap { g in
                g.worstTracks.map { $0.track.fileURL.standardizedFileURL.path }
            })
        }
    }

    /// STRICT / BROAD selector — strict = re-encodes of the same release only,
    /// broad = the same recording anywhere.
    private var modeBar: some View {
        HStack(spacing: 8) {
            Text("MATCH")
                .font(CarbonFont.mono(8, weight: .bold))
                .tracking(1.4)
                .foregroundStyle(theme.ink3)
            ForEach([DuplicateScanMode.strict, .broad], id: \.self) { mode in
                Button(action: { model.duplicateScanMode = mode }) {
                    Text(mode == .strict ? "STRICT · SAME ALBUM" : "BROAD · ANY RELEASE")
                        .font(CarbonFont.mono(8.5, weight: .bold))
                        .foregroundColor(model.duplicateScanMode == mode ? theme.orange : theme.ink3)
                        .padding(.vertical, 5)
                        .padding(.horizontal, 10)
                        .background(model.duplicateScanMode == mode ? theme.chassis : theme.chassisHi)
                        .cornerRadius(3)
                }
                .buttonStyle(.carbonHover)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(theme.chassisHi)
        .overlay(Rectangle().fill(Color.black.opacity(0.12)).frame(height: 1), alignment: .bottom)
    }

    private func duplicateGroupRow(_ group: DuplicateGroup) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(group.bestTrack.track.artist) - \(group.bestTrack.track.title)")
                    .font(CarbonFont.sans(12.5, weight: .bold))
                    .foregroundColor(theme.ink)
                Spacer()
                Button("NOT A DUPLICATE") {
                    let memberPaths = ([group.bestTrack] + group.worstTracks)
                        .map { $0.track.fileURL.standardizedFileURL.path }
                    checkedPaths.subtract(memberPaths)
                    model.ignoreDuplicateGroup(group)
                }
                    .font(CarbonFont.mono(8, weight: .bold))
                    .foregroundColor(.secondary)
                    .help("Never flag this exact set of files again")
            }

            memberRow(group.bestTrack, isBest: true)
            ForEach(group.worstTracks) { worst in
                memberRow(worst, isBest: false)
            }
        }
        .padding(.vertical, 8)
    }

    private func memberRow(_ loaded: LoadedTrack, isBest: Bool) -> some View {
        let path = loaded.track.fileURL.standardizedFileURL.path
        let checked = checkedPaths.contains(path)
        return HStack {
            Button(action: {
                if checked { checkedPaths.remove(path) } else { checkedPaths.insert(path) }
            }) {
                Image(systemName: checked ? "checkmark.square.fill" : "square")
                    .foregroundColor(checked ? .red : theme.ink3)
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .help(checked ? "Will be moved to Trash" : "Will be kept")

            if isBest {
                Image(systemName: "star.fill")
                    .foregroundColor(.yellow)
                    .font(.system(size: 9))
                Text("[BEST]")
                    .font(CarbonFont.mono(8, weight: .bold))
                    .foregroundColor(.green)
            } else {
                Text("[DUP]")
                    .font(CarbonFont.mono(8, weight: .bold))
                    .foregroundColor(.red)
            }
            Text(specString(for: loaded))
                .font(CarbonFont.mono(9))
            Text(loaded.track.fileURL.lastPathComponent)
                .font(CarbonFont.mono(9))
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
        .padding(.leading, 8)
    }

    private func trashSelected() {
        let selected = model.duplicateGroups.flatMap { group in
            ([group.bestTrack] + group.worstTracks).filter {
                checkedPaths.contains($0.track.fileURL.standardizedFileURL.path)
            }
        }
        model.resolveDuplicates(selected: selected)
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
