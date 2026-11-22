import AppKit
import CrateDiggerCore
import SwiftUI

/// The Simple editor's palette: 2 to 6 swatches side by side, each with its
/// hex, a pin menu, a remove key and, under it, the jobs it paints now.
///
/// Hovering a swatch lights its jobs in the preview; hovering one job name
/// lights just that job. Clicking a swatch opens the system colour panel on it.
/// A drag in the colour panel shows on the swatch at once and becomes one
/// history step when the pointer rests, so ← steps back over the whole drag
/// rather than through each pixel of it.
struct PaletteSwatchRow: View {
    @Environment(\.carbon) private var theme
    @ObservedObject var editor: SimpleThemeEditor
    @ObservedObject var session: ThemeEditorSession

    @StateObject private var colorPanel = SwatchColorPanel()
    /// Colours dragged in the colour panel that are not a history step yet.
    @State private var live: [Int: String] = [:]
    @State private var pendingCommit: DispatchWorkItem?
    @State private var hoveredSwatch: Int?
    @State private var hoveredJob: ThemeJob?

    static let cellWidth: CGFloat = 52
    private static let chipHeight: CGFloat = 34
    /// Quiet time after the last colour-panel change before it is committed.
    private static let commitDelay: TimeInterval = 0.3

    private var state: SimpleThemeState { editor.history.current }
    private var palette: [String] { state.palette }

    var body: some View {
        HStack(alignment: .top, spacing: 5) {
            ForEach(Array(palette.enumerated()), id: \.offset) { index, hex in
                cell(index: index, hex: live[index] ?? hex)
            }
            if palette.count < SimpleThemeRecipe.maxPaletteCount {
                addCell
            }
            Spacer(minLength: 0)
        }
        .onChange(of: palette) { _ in
            // A history step (or ←/→) moved the palette under a drag in progress.
            live = [:]
            pendingCommit?.cancel()
        }
        .onDisappear {
            pendingCommit?.cancel()
            colorPanel.release()
            editor.highlightedJobs = []
        }
    }

    // MARK: - Cell

    private func cell(index: Int, hex: String) -> some View {
        let jobs = editor.jobs(forSwatch: index)
        let pinned = Set(state.pins.filter { $0.value == index }.map(\.key))
        let active = colorPanel.activeIndex == index

        return VStack(alignment: .leading, spacing: 4) {
            chip(hex: hex, active: active)
                .onTapGesture { openColorPanel(index: index, hex: hex) }
                .carbonTip("Click to pick this colour. Hover to see what it paints.")

            HexField(
                value: Binding(get: { hex }, set: { commit(Self.rgb($0), at: index) }),
                fontSize: 9,
                horizontalPadding: 4
            )
            .frame(width: Self.cellWidth)

            HStack(spacing: 0) {
                pinMenu(index: index, pinned: pinned)
                Spacer(minLength: 0)
                removeKey(index: index)
            }

            VStack(alignment: .leading, spacing: 2) {
                if jobs.isEmpty {
                    Text("UNUSED")
                        .font(CarbonFont.mono(7, weight: .bold))
                        .tracking(0.6)
                        .foregroundStyle(theme.ink4)
                }
                ForEach(jobs, id: \.self) { job in
                    jobLabel(job, pinned: pinned.contains(job))
                }
            }
            .frame(width: Self.cellWidth, alignment: .leading)
        }
        .frame(width: Self.cellWidth, alignment: .topLeading)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { hoveredSwatch = index } else if hoveredSwatch == index { hoveredSwatch = nil }
            updateHighlight()
        }
    }

    private func chip(hex: String, active: Bool) -> some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(Color(hexString: hex) ?? .black)
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(active ? theme.orange : theme.hair, lineWidth: active ? 2 : 1)
            )
            .frame(width: Self.cellWidth, height: Self.chipHeight)
            .animation(CarbonMotion.state, value: active)
    }

    private func jobLabel(_ job: ThemeJob, pinned: Bool) -> some View {
        let lit = hoveredJob == job
        return HStack(spacing: 2) {
            if pinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 6, weight: .bold))
            }
            Text(job.label.uppercased())
                .font(CarbonFont.mono(7, weight: .bold))
                .tracking(0.5)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .foregroundStyle(lit ? theme.orange : theme.ink3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { hoveredJob = job } else if hoveredJob == job { hoveredJob = nil }
            updateHighlight()
        }
        .help(pinned ? "\(job.label), pinned to this colour: Shuffle leaves it here." : job.label)
    }

    /// The pin icon, then the job: a pinned job stays on this swatch through
    /// every Shuffle. Picking a job pinned here again unpins it.
    private func pinMenu(index: Int, pinned: Set<ThemeJob>) -> some View {
        Menu {
            ForEach(ThemeJob.allCases, id: \.self) { job in
                Button {
                    session.gated(.pin) {
                        editor.edit { state in
                            if pinned.contains(job) { state.unpin(job) } else { state.pin(job, to: index) }
                        }
                    }
                } label: {
                    if pinned.contains(job) {
                        Label(job.label, systemImage: "checkmark")
                    } else {
                        Text(job.label)
                    }
                }
            }
        } label: {
            Image(systemName: pinned.isEmpty ? "pin" : "pin.fill")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(pinned.isEmpty ? theme.ink3 : theme.orange)
                .frame(width: 18, height: 16)
                .contentShape(Rectangle())
        }
        // `.button` + `.plain`, as elsewhere in the app: a borderless menu
        // draws its label as a black template and drops the colour.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .carbonTip("Pin this colour to a job. Shuffle never moves a pinned job.")
    }

    private func removeKey(index: Int) -> some View {
        let canRemove = palette.count > SimpleThemeRecipe.minPaletteCount
        return Button {
            session.gated(.palette) {
                if colorPanel.activeIndex != nil { colorPanel.release() }
                editor.edit { $0.removeColor(at: index) }
            }
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(canRemove ? theme.ink3 : theme.ink4.opacity(0.4))
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.carbonHover)
        .disabled(!canRemove)
        .carbonTip(canRemove ? "Remove this colour." : "A palette keeps at least two colours.")
    }

    private var addCell: some View {
        Button {
            session.gated(.palette) {
                let hex = Self.companion(to: palette)
                editor.edit { $0.addColor(hex) }
                openColorPanel(index: editor.history.current.palette.count - 1, hex: hex)
            }
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(theme.ink4, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.ink3)
            }
            .frame(width: Self.cellWidth, height: Self.chipHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.carbonHover)
        .carbonTip("Add a colour (up to six). With more colours, more jobs get one of their own.")
    }

    // MARK: - Committing

    private func updateHighlight() {
        if let hoveredJob {
            editor.highlightedJobs = [hoveredJob]
        } else if let hoveredSwatch {
            editor.highlightedJobs = Set(editor.jobs(forSwatch: hoveredSwatch))
        } else {
            editor.highlightedJobs = []
        }
    }

    /// A finished edit (hex committed, or a colour-panel drag at rest): one
    /// history step, asked about first on a reopened theme.
    private func commit(_ hex: String, at index: Int) {
        guard palette.indices.contains(index), hex != palette[index] else {
            live[index] = nil
            return
        }
        session.gated(.palette, onCancel: { live[index] = nil }) {
            // The latest dragged colour, if the drag went on while asking.
            let latest = live[index] ?? hex
            live[index] = nil
            editor.edit { $0.setColor(latest, at: index) }
        }
    }

    private func openColorPanel(index: Int, hex: String) {
        colorPanel.open(index: index, hex: hex) { picked in
            live[index] = picked
            pendingCommit?.cancel()
            // While a question is up, the drag just keeps the swatch current;
            // the answer commits whatever it reached.
            guard session.prompt == nil else { return }
            let work = DispatchWorkItem { commit(picked, at: index) }
            pendingCommit = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.commitDelay, execute: work)
        }
    }

    /// Palette swatches are opaque: an `#RRGGBBAA` typed or pasted keeps its colour.
    private static func rgb(_ hex: String) -> String {
        let upper = hex.uppercased()
        return upper.count == 9 ? String(upper.prefix(7)) : upper
    }

    /// A starting colour for a new swatch: the last one's hue turned halfway
    /// round, so it reads as new rather than as a near-copy.
    private static func companion(to palette: [String]) -> String {
        guard let last = palette.last.flatMap({ Color(hexString: $0) }),
              let rgb = NSColor(last).usingColorSpace(.sRGB)
        else { return "#8A8F98" }
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        rgb.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        let turned = NSColor(
            hue: (hue + 0.5).truncatingRemainder(dividingBy: 1),
            saturation: max(saturation, 0.45),
            brightness: min(max(brightness, 0.55), 0.9),
            alpha: 1
        )
        return SwatchColorPanel.hex(of: turned) ?? "#8A8F98"
    }
}

// MARK: - Colour panel

/// Points the shared system colour panel at one swatch. The panel is
/// app-global, so the bridge takes it over only while a swatch is being
/// picked and lets go when the row goes away or the panel closes.
@MainActor
final class SwatchColorPanel: NSObject, ObservableObject {
    /// The swatch the colour panel is editing, outlined while it is.
    @Published private(set) var activeIndex: Int?
    private var onChange: ((String) -> Void)?
    private var closeObserver: NSObjectProtocol?

    func open(index: Int, hex: String, onChange: @escaping (String) -> Void) {
        let panel = NSColorPanel.shared
        // Detach first, so setting the colour below is not reported to whoever
        // held the panel before.
        panel.setTarget(nil)
        panel.setAction(nil)
        panel.showsAlpha = false
        panel.isContinuous = true
        if let color = Color(hexString: hex) { panel.color = NSColor(color) }
        self.onChange = onChange
        activeIndex = index
        panel.setTarget(self)
        panel.setAction(#selector(colorChanged(_:)))
        panel.orderFront(nil)

        if closeObserver == nil {
            closeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: panel, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.release() }
            }
        }
    }

    /// Stops listening to the panel; leaves it open for anyone else.
    func release() {
        if onChange != nil {
            NSColorPanel.shared.setTarget(nil)
            NSColorPanel.shared.setAction(nil)
        }
        onChange = nil
        activeIndex = nil
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
    }

    @objc private func colorChanged(_ sender: NSColorPanel) {
        guard let hex = Self.hex(of: sender.color) else { return }
        onChange?(hex)
    }

    /// `#RRGGBB` in sRGB, the form palette swatches are stored in.
    static func hex(of color: NSColor) -> String? {
        guard let srgb = color.usingColorSpace(.sRGB) else { return nil }
        let channel = { (value: CGFloat) in Int((min(max(value, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X",
                      channel(srgb.redComponent), channel(srgb.greenComponent), channel(srgb.blueComponent))
    }
}
