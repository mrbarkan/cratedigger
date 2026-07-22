import CrateDiggerCore
import SwiftUI

// MARK: - Shared OLED palette

/// The OLED foreground family (#F5F1E6 by default) and helpers. Everything on
/// the glass is drawn from this + the Carbon accents (orange/sun/cyan/indigo/red).
///
/// The values live in `ActiveOLEDPalette`, written by `CarbonThemed.body` from
/// the active theme's `oledForeground`/`oledForegroundMuted`/`onAir` tokens
/// (same idempotent-global pattern as `ActiveThemeFonts`). The ~50 call sites
/// in this file default-parameter off these computed globals; default
/// parameters are evaluated per call and every pane re-renders when the theme
/// environment changes, so theme overrides propagate live without threading
/// `theme` through each call.
enum ActiveOLEDPalette {
    static var foreground = Color(red: 0.961, green: 0.945, blue: 0.902)
    static var muted = Color.white.opacity(0.55)
    static var onAir = Color(red: 1.0, green: 0.357, blue: 0.29)   // #ff5b4a
}
var oledFG: Color { ActiveOLEDPalette.foreground }
func oledFGo(_ opacity: Double) -> Color { oledFG.opacity(opacity) }
private var oledMuted: Color { ActiveOLEDPalette.muted }
private var onAirRed: Color { ActiveOLEDPalette.onAir }

// MARK: - OLED display (one glass, three permanent zones)

/// The OLED reads as ONE physical device screen with fixed geometry, not
/// swappable cards: a persistent annunciator rail (top), a context zone whose
/// panes swap inside a fixed frame (center), and a 5-cell data rail (bottom).
/// Everything on the glass *snaps* between views — no crossfades.
struct OLEDDisplay: View {
    @Environment(\.carbon) private var theme
    @Environment(\.carbonGeometry) private var geometry
    @EnvironmentObject private var model: LibraryViewModel

    var body: some View {
        ZStack {
            background
            VStack(spacing: 0) {
                DisplayRail()
                DisplayContext()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(.top, 8)
            .padding(.horizontal, 18)
            .padding(.bottom, 10)
        }
        .clipShape(RoundedRectangle(cornerRadius: geometry.oledCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: geometry.oledCornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(theme.isDark ? 0.08 : 0.22), lineWidth: 1)
        )
        .compositingGroup()
    }

    private var background: some View {
        RoundedRectangle(cornerRadius: geometry.oledCornerRadius, style: .continuous)
            .fill(theme.oledSurface)
            .overlay(
                RoundedRectangle(cornerRadius: geometry.oledCornerRadius, style: .continuous)
                    .strokeBorder(theme.oledStrokeInner, lineWidth: 2)
            )
            .overlay(
                LinearGradient(
                    colors: [
                        Color.white.opacity(theme.isDark ? 0.04 : 0.08),
                        Color.clear,
                        Color.black.opacity(0.28)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .scanlines(opacity: theme.oledScanlineOpacity)
            .shadow(color: Color.black.opacity(0.5), radius: 6, y: 4)
    }
}

/// The context zone — the six panes swap inside a fixed frame. A plain switch
/// with no animation → the glass snaps like a real FL display.
private struct DisplayContext: View {
    @EnvironmentObject private var model: LibraryViewModel

    var body: some View {
        ZStack {
            switch model.oledView {
            case .nowPlaying:  NowPlayingPane()
            case .conversion:  ConversionPane()
            case .scan:        ScanPane()
            case .remoteSync:  RemoteSyncPane()
            case .cdRip:       CDRipPane()
            case .devices:     DevicesPane()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Annunciator rail + persistent transport strip

private struct DisplayRail: View {
    @Environment(\.carbon) private var theme
    @EnvironmentObject private var model: LibraryViewModel

    private var v: OLEDView { model.oledView }
    private var radioLive: Bool { model.isRadioMode || model.isStreamActive }

    var body: some View {
        HStack(spacing: 0) {
            // Annunciators — every mode permanently printed on the glass, each
            // lit in its own accent (the same color the display-toggle strip
            // glows — see OLEDView.accent).
            HStack(spacing: 12) {
                ann("NOW", lit: v == .nowPlaying, color: OLEDView.nowPlaying.accent(theme))
                ann("CNVRT", lit: v == .conversion, color: OLEDView.conversion.accent(theme))
                ann("SCAN", lit: v == .scan, color: OLEDView.scan.accent(theme))
                ann("SYNC", lit: v == .remoteSync, color: OLEDView.remoteSync.accent(theme))
                ann("CD", lit: v == .cdRip, color: OLEDView.cdRip.accent(theme))
                ann("DEV", lit: v == .devices, color: OLEDView.devices.accent(theme))
                ann("ON AIR", lit: radioLive, color: onAirRed, pulse: onAirPulse)
            }

            Spacer(minLength: 12)

            // Transient system notice (tag saves etc.) — snaps in on the rail
            // instead of interrupting the user with a modal alert.
            if let notice = model.oledNotice {
                Text(notice)
                    .font(CarbonFont.mono(9, weight: .bold))
                    .tracking(1.8)
                    .foregroundStyle(theme.sun)
                    .shadow(color: theme.sun.opacity(0.55), radius: 6)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.trailing, 14)
            }

            RailLive(clock: model.playbackClock)
            RailSettings()
        }
        .padding(.bottom, 7)
        .overlay(
            Rectangle().fill(oledFGo(0.09)).frame(height: 1),
            alignment: .bottom
        )
    }

    /// ON AIR animation: fast flash while a stream is buffering, slow breathe
    /// while it's actually on the air, steady when radio is merely selected.
    private var onAirPulse: AnnPulse {
        guard radioLive else { return .none }
        switch model.playbackState {
        case .loading: return .flash
        case .playing: return .breathe
        default:       return .none
        }
    }

    /// One printed annunciator segment: ghost when inactive, lit (color + glow)
    /// when its view is active. Segments snap — no fade.
    private func ann(_ label: String, lit: Bool, color: Color, pulse: AnnPulse = .none) -> some View {
        HStack(spacing: 5) {
            AnnDot(lit: lit, color: color)
            Text(label)
                .font(CarbonFont.mono(8, weight: .bold))
                .tracking(1.6)
                .foregroundStyle(lit ? color : oledFGo(0.16))
                .shadow(color: lit ? color.opacity(0.55) : .clear, radius: lit ? 7 : 0)
        }
        .fixedSize()
        .modifier(AnnBlink(mode: lit ? pulse : .none))
    }
}

/// How an annunciator animates: `.breathe` is the slow on-air pulse, `.flash`
/// the fast attention blink used while a stream is still connecting.
private enum AnnPulse { case none, breathe, flash }

/// Opacity animation for a whole annunciator (dot + label). Restarts cleanly
/// when the mode changes (loading → playing swaps flash for breathe).
private struct AnnBlink: ViewModifier {
    let mode: AnnPulse
    @State private var dim = false

    func body(content: Content) -> some View {
        content
            .opacity(dim ? (mode == .flash ? 0.2 : 0.4) : 1.0)
            .onAppear(perform: restart)
            .onChange(of: mode) { _ in restart() }
    }

    private func restart() {
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) { dim = false }
        guard mode != .none else { return }
        let period = mode == .flash ? 0.22 : 0.7
        withAnimation(.easeInOut(duration: period).repeatForever(autoreverses: true)) { dim = true }
    }
}

/// The annunciator dot — 5px, ghost or lit. Pulsing happens at the whole-
/// annunciator level (`AnnBlink`), so the dot itself is static.
private struct AnnDot: View {
    let lit: Bool
    let color: Color

    var body: some View {
        Circle()
            .fill(lit ? color : oledFGo(0.09))
            .frame(width: 5, height: 5)
            .shadow(color: lit ? color : .clear, radius: lit ? 5 : 0)
    }
}

/// The persistent transport strip on the right of the rail: mini now-playing +
/// progress (auto-hidden on the nowPlaying view) then the always-visible
/// VOL meter + dB.
private struct RailLive: View {
    @Environment(\.carbon) private var theme
    @EnvironmentObject private var model: LibraryViewModel
    // Playback time lives on the isolated clock; observe it to keep ticking.
    @ObservedObject var clock: PlaybackClock

    private var showMini: Bool { model.oledView != .nowPlaying }

    var body: some View {
        HStack(spacing: 12) {
            if showMini {
                Text(trackTitle)
                    .font(CarbonFont.mono(9, weight: .bold))
                    .tracking(1.08)
                    .foregroundStyle(theme.orange)
                    .shadow(color: theme.orange.opacity(0.4), radius: 6)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 150, alignment: .leading)
                    .fixedSize(horizontal: true, vertical: false)

                HStack(spacing: 6) {
                    Text(model.displayedCurrentTime.asClockPadded)
                        .font(CarbonFont.mono(9, weight: .bold))
                        .foregroundStyle(oledFG)
                    Capsule().fill(oledFGo(0.14))
                        .frame(width: 62, height: 3)
                        .overlay(alignment: .leading) {
                            Capsule().fill(theme.orange)
                                .frame(width: 62 * progress, height: 3)
                                .shadow(color: theme.orange.opacity(0.6), radius: 4)
                        }
                    Text(model.playbackDuration.asClockPadded)
                        .font(CarbonFont.mono(9, weight: .bold))
                        .foregroundStyle(oledFGo(0.4))
                }
                .fixedSize()
            }

            HStack(spacing: 6) {
                Text("VOL")
                    .font(CarbonFont.mono(6.5, weight: .bold))
                    .tracking(1.3)
                    .foregroundStyle(oledFGo(0.3))
                RailVolBars(volume: model.playbackVolume)
                    .frame(width: 52, height: 9)
                Text(oledVolumeDB(model.playbackVolume))
                    .font(CarbonFont.mono(9, weight: .bold))
                    .foregroundStyle(oledFG)
                    .frame(width: 48, alignment: .trailing)   // fixed: fits "−60 dB"
            }
            .fixedSize()
        }
    }

    private var trackTitle: String {
        (model.nowPlayingTrack?.track.title ?? model.selectedTrack?.track.title ?? "—").uppercased()
    }

    private var progress: CGFloat {
        guard model.playbackDuration > 0 else { return 0 }
        return CGFloat(min(max(model.displayedCurrentTime / model.playbackDuration, 0), 1))
    }
}

/// The VIEW / THEME / EQ readouts on the rail — values only, no labels.
private struct RailSettings: View {
    @Environment(\.carbon) private var theme
    @EnvironmentObject private var model: LibraryViewModel
    // Observe the stored appearance *preference* so the THEME readout refreshes on
    // any change — including LIGHT→AUTO, where the resolved appearance (and thus
    // the injected `theme`) is unchanged, so nothing else would trigger a redraw.
    @AppStorage(AppearanceMode.userDefaultsKey) private var appearanceRaw = AppearanceMode.system.rawValue

    var body: some View {
        // Fixed-width slots so the values never shift as their text changes
        // (VIEW ≤ GALLERY, THEME ≤ LIGHT, EQ ≤ TREBLE).
        HStack(spacing: 14) {
            value(viewValue, width: 54)
            value(themeValue, width: 40)
            value(model.eqPreset.label, width: 46)
        }
        .padding(.leading, 14)
        .overlay(
            Rectangle().fill(oledFGo(0.12)).frame(width: 1),
            alignment: .leading
        )
        .fixedSize()
    }

    private func value(_ text: String, width: CGFloat) -> some View {
        Text(text)
            .font(CarbonFont.mono(9.5, weight: .bold))
            .tracking(0.9)
            .foregroundStyle(theme.orange)
            .shadow(color: theme.orange.opacity(0.4), radius: 6)
            .lineLimit(1)
            .frame(width: width, alignment: .leading)
    }

    private var viewValue: String { model.showArtworkGallery ? "GALLERY" : "LIST" }

    private var themeValue: String {
        switch AppearanceMode(rawValue: appearanceRaw) ?? .system {
        case .light:  return "LIGHT"
        case .dark:   return "DARK"
        case .system: return "AUTO"
        }
    }
}

/// A 16-segment cyan→orange VOL meter (revealed through a mask of the lit run),
/// matching the footer POSITION bar's colour ramp.
private struct RailVolBars: View {
    @Environment(\.carbon) private var theme
    let volume: Double

    private let barCount = 16

    var body: some View {
        let lit = Int((volume * Double(barCount)).rounded())
        ZStack {
            segmentRow { _ in oledFGo(0.16) }
            LinearGradient(colors: [theme.cyan, theme.orange], startPoint: .leading, endPoint: .trailing)
                .mask(segmentRow { i in i < lit ? Color.black : Color.clear })
                .shadow(color: theme.orange.opacity(0.5), radius: 2)
        }
    }

    private func segmentRow(_ fill: @escaping (Int) -> Color) -> some View {
        HStack(spacing: 2) {
            ForEach(0..<barCount, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1, style: .continuous).fill(fill(i))
            }
        }
    }
}

/// dB readout for the fader position, per the shared volume law (unity ~92%).
func oledVolumeDB(_ position: Double) -> String {
    VolumeCurve.label(forPosition: position)
}

// MARK: - Pane scaffold + shared parts

/// Every pane shares one composition: a headline row (titles left / numeric
/// readout right), an optional ticker just above the cell rail, and the 5-cell
/// data rail pinned to the bottom.
private struct OLEDPaneScaffold<Headline: View, Readout: View, Ticker: View, Cells: View>: View {
    @ViewBuilder var headline: () -> Headline
    @ViewBuilder var readout: () -> Readout
    @ViewBuilder var ticker: () -> Ticker
    @ViewBuilder var cells: () -> Cells

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .bottom, spacing: 24) {
                headline().frame(maxWidth: .infinity, alignment: .leading)
                readout()
            }
            Spacer(minLength: 8)
            ticker()
            cells()
        }
        .padding(.top, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// The big thin track title + uppercase sub line (np-titles).
private struct NPTitles: View {
    let title: String
    let sub: String
    var titleColor: Color = oledFG
    var titleSize: CGFloat = 44
    /// System messages (the idle nudge) render oblique so they can never be
    /// mistaken for a track title.
    var titleItalic: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(CarbonFont.display(titleSize))
                .fontWeight(.thin)
                .italic(titleItalic)
                .tracking(-0.4)
                .foregroundStyle(titleColor)
                .lineLimit(1)
                .minimumScaleFactor(0.55)
            Text(sub)
                .font(CarbonFont.mono(9.5, weight: .semibold))
                .tracking(1.9)
                .textCase(.uppercase)
                .foregroundStyle(oledMuted)
                .lineLimit(1)
        }
    }
}

/// The large thin clock/number readout (np-clock): big `now` + smaller `tot`.
private struct NPClock: View {
    @Environment(\.carbon) private var theme
    let now: String
    let tot: String
    var nowColor: Color = oledFG
    var totColor: Color = oledFGo(0.4)
    var nowSize: CGFloat = 34

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(now)
                .font(CarbonFont.display(nowSize))
                .fontWeight(.thin)
                .foregroundStyle(nowColor)
                .shadow(color: theme.orange.opacity(nowColor == oledFG ? 0.28 : 0), radius: 7)
            if !tot.isEmpty {
                Text(tot)
                    .font(CarbonFont.mono(12, weight: .semibold))
                    .tracking(1.7)
                    .foregroundStyle(totColor)
            }
        }
    }
}

/// One cell in the bottom data rail.
private struct OLEDCellData: Identifiable {
    let key: String
    let value: String
    let sub: String
    var valueColor: Color = oledFG
    var id: String { key }
}

/// The 5-cell data rail (np-cells) — equal-width cells with hairline separators,
/// pinned to the bottom of every pane; an optional trailing view (the SORT
/// readout) rides at the end behind its own separator.
private struct OLEDCells<Trailing: View>: View {
    let cells: [OLEDCellData]
    @ViewBuilder var trailing: () -> Trailing

    init(_ cells: [OLEDCellData], @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.cells = cells
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.offset) { i, c in
                if i > 0 {
                    Rectangle().fill(oledFGo(0.12)).frame(width: 1).padding(.vertical, 1)
                }
                cell(c, leading: i > 0)
            }
            trailing()
        }
        .padding(.top, 8)
        .overlay(Rectangle().fill(oledFGo(0.12)).frame(height: 1), alignment: .top)
    }

    private func cell(_ c: OLEDCellData, leading: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(c.key.uppercased())
                .font(CarbonFont.mono(7.5, weight: .semibold))
                .tracking(1.65)
                .foregroundStyle(oledFGo(0.45))
            Text(c.value)
                .font(CarbonFont.mono(13, weight: .bold))
                .tracking(0.5)
                .foregroundStyle(c.valueColor)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(c.sub.uppercased())
                .font(CarbonFont.mono(7.5, weight: .semibold))
                .tracking(1.35)
                .foregroundStyle(oledFGo(0.55))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.trailing, 10)
        .padding(.leading, leading ? 10 : 0)
    }
}

/// The scan / sync / cd / devices path ticker (dsp-ticker): a prefix label + a
/// breadcrumb path (leaf lit) + optional trailing meta, above the cell rail.
private struct DSPTicker: View {
    let prefix: String
    let path: AttributedString
    var meta: String? = nil
    var leadingInset: CGFloat = 0

    var body: some View {
        HStack(spacing: 12) {
            Text(prefix)
                .font(CarbonFont.mono(8.5, weight: .bold))
                .tracking(1.9)
                .foregroundStyle(oledFGo(0.5))
                .fixedSize()
            Text(path)
                .font(CarbonFont.mono(10))
                .tracking(0.4)
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let meta {
                Text(meta)
                    .font(CarbonFont.mono(9, weight: .semibold))
                    .tracking(1.7)
                    .foregroundStyle(oledFGo(0.5))
                    .fixedSize()
            }
        }
        .padding(.leading, leadingInset)
        .padding(.bottom, 8)
    }
}

/// A capsule tag (NOW PLAYING / CONVERT · ARMED / etc.).
private struct OLEDTag: View {
    let text: String
    let ink: Color
    let background: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(ink).frame(width: 6, height: 6)
            Text(text)
                .font(CarbonFont.mono(9, weight: .bold))
                .tracking(1.8)
                .foregroundStyle(ink)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(background))
    }
}

/// A thin progress / sweep bar shared by SCAN / SYNC / CD / DEVICES readouts.
private struct ScanBar: View {
    @Environment(\.carbon) private var theme

    enum Style { case rainbow(Double), orange(Double), indigoSweep }
    let style: Style
    @State private var sweep = false

    var body: some View {
        GeometryReader { proxy in
            let w = max(proxy.size.width, 1)
            ZStack(alignment: .leading) {
                Capsule().fill(oledFGo(0.10))
                switch style {
                case .rainbow(let f):
                    Capsule()
                        .fill(LinearGradient(colors: [theme.cyan, theme.indigo, theme.orange], startPoint: .leading, endPoint: .trailing))
                        .frame(width: w * CGFloat(min(max(f, 0), 1)))
                        .shadow(color: theme.cyan.opacity(0.34), radius: 5)
                case .orange(let f):
                    Capsule()
                        .fill(theme.orange)
                        .frame(width: w * CGFloat(min(max(f, 0), 1)))
                        .shadow(color: theme.orange.opacity(0.34), radius: 5)
                case .indigoSweep:
                    Capsule()
                        .fill(LinearGradient(colors: [theme.indigo, theme.cyan], startPoint: .leading, endPoint: .trailing))
                        .frame(width: w * 0.24)
                        .shadow(color: theme.indigo.opacity(0.4), radius: 5)
                        .offset(x: sweep ? w * 0.72 : w * 0.04)
                        .onAppear {
                            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) { sweep = true }
                        }
                }
            }
        }
        .frame(height: 5)
    }
}

// MARK: - NOW PLAYING pane

private struct NowPlayingPane: View {
    @EnvironmentObject private var model: LibraryViewModel

    private var isRadio: Bool {
        (model.isStreamActive || model.isRadioMode) && model.selectedStream != nil
    }

    var body: some View {
        if isRadio { RadioNowPlaying(clock: model.playbackClock) } else { LibraryNowPlaying(clock: model.playbackClock) }
    }
}

/// What the NOW pane shows while nothing is playing — a little crate-digger
/// nudge instead of leaking the browser selection onto the glass.
private enum OLEDIdleMessages {
    static let all: [String] = [
        "Play something you love",
        "Drop the needle",
        "The crates are calling",
        "Silence is just a long intro",
        "Spin something dusty",
        "Your records miss you",
        "Find that B-side",
        "Every dig starts with play",
        "Warm up the tubes",
        "Press play, dig deep",
        "One more spin won't hurt",
        "Dust off a classic",
        "The groove is waiting",
        "Feed the turntable",
        "What's on side B?",
        "Make the speakers proud",
        "Somewhere, a record spins",
        "Rewind. Replay. Repeat.",
        "Today deserves a soundtrack",
        "Good ears deserve good records"
    ]

    static func pick() -> String { all.randomElement() ?? all[0] }
}

private struct LibraryNowPlaying: View {
    @EnvironmentObject private var model: LibraryViewModel
    @Environment(\.carbon) private var theme
    // Playback time lives on the isolated clock; observe it to keep ticking.
    @ObservedObject var clock: PlaybackClock
    @State private var idleMessage = OLEDIdleMessages.pick()

    /// The NOW pane shows only what is actually playing — never the browser
    /// selection. No track loaded = the idle message.
    private var isIdle: Bool { model.nowPlayingTrack == nil }

    var body: some View {
        OLEDPaneScaffold {
            NPTitles(title: displayTrackTitle, sub: subtitle,
                     titleColor: isIdle ? oledFGo(0.6) : oledFG,
                     titleItalic: isIdle)
        } readout: {
            NPClock(now: isIdle ? "--:--" : model.displayedCurrentTime.asClockPadded,
                    tot: isIdle ? "" : "/ " + model.playbackDuration.asClockPadded)
                .fixedSize()
        } ticker: {
            EmptyView()
        } cells: {
            OLEDCells(libraryCells) {
                NPSort(rows: sortRows).padding(.leading, 12)
                    .overlay(Rectangle().fill(oledFGo(0.12)).frame(width: 1), alignment: .leading)
                    .fixedSize()
            }
        }
        // A fresh nudge each time playback winds down.
        .onChange(of: isIdle) { nowIdle in
            if nowIdle { idleMessage = OLEDIdleMessages.pick() }
        }
    }

    private var libraryCells: [OLEDCellData] { LibraryNowPlayingCells.make(model: model) }

    private var sortRows: [NPSortRow] {
        let artist = NPSortRow(key: "ART", field: model.artistSortField.displayName, ascending: model.artistSortAscending)
        let album = NPSortRow(key: "ALB", field: model.albumSortField.displayName, ascending: model.albumSortAscending)
        let track = NPSortRow(key: "TRK", field: model.trackSortField.displayName, ascending: model.trackSortAscending)
        switch model.browserLayout {
        case .full:       return [artist, album, track]
        case .albumTrack: return [album, track]
        case .track:      return [track]
        }
    }

    private var displayTrackTitle: String {
        if isIdle { return idleMessage.uppercased() }
        if let recordTrack = model.currentRecordTrack { return recordTrack.title.uppercased() }
        return (model.nowPlayingTrack?.track.title ?? "—").uppercased()
    }

    private var subtitle: String {
        guard let track = model.nowPlayingTrack else { return "Nothing playing" }
        if let index = model.currentRecordTrackIndex {
            let total = model.nowPlayingRecordMarkers.count
            let album = track.track.album.isEmpty ? track.track.title : track.track.album
            return "TRACK \(index + 1)/\(total) · \(album)"
        }
        let parts = [track.track.artist, track.track.album, track.track.year.map(String.init) ?? ""].filter { !$0.isEmpty }
        return parts.joined(separator: " · ")
    }
}

private struct RadioNowPlaying: View {
    @EnvironmentObject private var model: LibraryViewModel
    @Environment(\.carbon) private var theme
    // Playback time lives on the isolated clock; observe it to keep ticking.
    @ObservedObject var clock: PlaybackClock

    private var stream: StreamSource? { model.selectedStream }
    private var isLive: Bool { stream?.isLive ?? false }
    private var isNative: Bool { model.radioEngineKind == .native }

    var body: some View {
        OLEDPaneScaffold {
            NPTitles(title: headline.uppercased(), sub: subtitle)
        } readout: {
            radioReadout.fixedSize()
        } ticker: {
            EmptyView()
        } cells: {
            OLEDCells(radioCells)
        }
    }

    @ViewBuilder
    private var radioReadout: some View {
        if isLive {
            VStack(alignment: .trailing, spacing: 8) {
                HStack(spacing: 8) {
                    Circle().fill(onAirRed).frame(width: 9, height: 9)
                        .shadow(color: onAirRed.opacity(0.7), radius: 4)
                    Text("ON AIR").font(CarbonFont.display(30)).fontWeight(.thin).foregroundStyle(oledFG)
                }
                Text("UPTIME \(uptimeString)")
                    .font(CarbonFont.mono(10, weight: .semibold)).tracking(1.4)
                    .foregroundStyle(oledFGo(0.5))
            }
        } else {
            NPClock(now: model.displayedCurrentTime.asClockPadded,
                    tot: "/ " + model.playbackDuration.asClockPadded)
        }
    }

    private var radioCells: [OLEDCellData] {
        [
            OLEDCellData(key: "Source", value: "YouTube", sub: isLive ? "Live Stream" : (stream?.kind.rawValue ?? "—")),
            OLEDCellData(key: "Codec", value: codecValue, sub: codecSub),
            OLEDCellData(key: "Bitrate", value: "—", sub: isNative ? "VBR" : "Web Player"),
            OLEDCellData(key: "Buffer", value: "—", sub: isNative ? "Native" : "Browser"),
            OLEDCellData(key: "Tuned In", value: tunedValue, sub: isLive ? "Listening" : "Source")
        ]
    }

    private var headline: String {
        if let chapter = model.currentChapter { return chapter.title }
        return stream?.title ?? "—"
    }

    private var subtitle: String {
        guard let stream else { return "Tune in" }
        if model.currentChapter != nil { return "\(stream.title) · \(stream.channel)" }
        let suffix = isLive ? "YouTube Live Stream" : stream.kind.rawValue.capitalized
        return "\(stream.channel) · \(suffix)"
    }

    private var uptimeString: String {
        let t = max(0, model.radioUptimeSeconds)
        return String(format: "%02d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60)
    }

    private var codecValue: String { isNative ? (isLive ? "HLS" : "AAC") : "—" }
    private var codecSub: String { isNative ? (isLive ? "Stream" : "M4A") : "Embedded" }
    private var tunedValue: String {
        if isLive { return stream?.viewers ?? "—" }
        return (stream?.kind.rawValue ?? "—").uppercased()
    }
}

// MARK: - SORT readout (horizontal, read-only browser sort state)

private struct NPSortRow: Identifiable {
    let key: String
    let field: String
    let ascending: Bool
    var id: String { key }
}

private struct NPSort: View {
    @Environment(\.carbon) private var theme
    let rows: [NPSortRow]

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Text("SORT")
                .font(CarbonFont.mono(6.5, weight: .bold))
                .tracking(1.3)
                .foregroundStyle(oledFGo(0.3))
            ForEach(rows) { row in
                HStack(spacing: 4) {
                    Text(row.key)
                        .font(CarbonFont.mono(7, weight: .semibold))
                        .tracking(1.0)
                        .foregroundStyle(oledFGo(0.4))
                    Text(row.field.uppercased())
                        .font(CarbonFont.mono(9, weight: .bold))
                        .tracking(0.4)
                        .foregroundStyle(theme.orange)
                        .shadow(color: theme.orange.opacity(0.4), radius: 6)
                    Text(row.ascending ? "↑" : "↓")
                        .font(CarbonFont.mono(8, weight: .bold))
                        .foregroundStyle(theme.orange.opacity(0.85))
                }
            }
        }
    }
}

/// Shared builder for the library spec cells (used by NOW PLAYING).
private enum LibraryNowPlayingCells {
    @MainActor
    static func make(model: LibraryViewModel) -> [OLEDCellData] {
        // NOW cells describe the *playing* file only; browser selection
        // stays off the glass (the Inspector is where selection lives).
        let track = model.nowPlayingTrack
        let ext = track?.track.fileURL.pathExtension.uppercased() ?? ""
        let lossless = ["FLAC", "ALAC", "WAV", "AIFF"].contains(ext)

        let trackVal: String
        let trackSub: String
        if let album = model.selectedAlbum, let t = track,
           let idx = album.tracks.firstIndex(where: { $0.track.id == t.track.id }) {
            trackVal = String(format: "%02d / %02d", idx + 1, album.tracks.count)
        } else {
            let count = model.selectedAlbum?.trackCount ?? model.visibleTracks.count
            trackVal = count > 0 ? "\(count) TRK" : "—"
        }
        let total = model.selectedAlbum?.trackCount ?? model.visibleTracks.count
        trackSub = total > 0 ? "\(total) Total" : "—"

        let bitrate = track?.track.bitrateKbps.map { "\($0) kbps" } ?? "—"
        let sample: String = {
            guard let hz = track?.track.sampleRateHz else { return "—" }
            return hz % 1000 == 0 ? "\(hz / 1000) kHz" : String(format: "%.1f kHz", Double(hz) / 1000.0)
        }()
        let size: String = {
            guard let url = track?.track.fileURL,
                  let v = try? url.resourceValues(forKeys: [.fileSizeKey]), let s = v.fileSize else { return "—" }
            return String(format: "%.1f MB", Double(s) / 1_048_576.0)
        }()

        return [
            OLEDCellData(key: "Track", value: trackVal, sub: trackSub),
            OLEDCellData(key: "Format", value: track?.track.formatName?.uppercased() ?? "—", sub: lossless ? "Lossless" : "Lossy"),
            OLEDCellData(key: "Bitrate", value: bitrate, sub: lossless ? "Lossless" : "Constant"),
            OLEDCellData(key: "Sample", value: sample, sub: ["FLAC", "ALAC"].contains(ext) ? "16-bit" : "Audio"),
            OLEDCellData(key: "Size", value: size, sub: "File Size")
        ]
    }
}

// MARK: - CONVERT pane

private struct ConversionPane: View {
    @EnvironmentObject private var model: LibraryViewModel
    @Environment(\.carbon) private var theme

    var body: some View {
        OLEDPaneScaffold {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .bottom, spacing: 14) {
                    formatBlock(sourceFormatPrimary, dim: true)
                    Text("►")
                        .font(CarbonFont.display(26))
                        .foregroundStyle(theme.orange)
                        .shadow(color: theme.orange.opacity(0.6), radius: 4)
                    formatBlock(targetFormatPrimary, dim: false)
                }
                Text(pipelineSub)
                    .font(CarbonFont.mono(9.5, weight: .semibold))
                    .tracking(1.9).textCase(.uppercase)
                    .foregroundStyle(oledMuted)
                    .lineLimit(1)
            }
        } readout: {
            VStack(alignment: .trailing, spacing: 4) {
                NPClock(now: estimateNow, tot: "EST")
                Text("OUTPUT \(outputValue)")
                    .font(CarbonFont.mono(9.5, weight: .semibold))
                    .tracking(1.9).textCase(.uppercase)
                    .foregroundStyle(oledMuted)
            }
            .fixedSize()
        } ticker: {
            DSPTicker(prefix: tickerPrefix, path: tickerPath, meta: tickerMeta)
        } cells: {
            OLEDCells(cells)
        }
    }

    private func formatBlock(_ text: String, dim: Bool) -> some View {
        Text(text)
            .font(CarbonFont.display(40))
            .fontWeight(.thin)
            .foregroundStyle(dim ? oledFGo(0.55) : oledFG)
            .lineLimit(1)
    }

    private var cells: [OLEDCellData] {
        [
            OLEDCellData(key: "Scope", value: scopeValue, sub: scopeSub),
            OLEDCellData(key: "Format", value: formatValue, sub: formatSub),
            OLEDCellData(key: "Bitrate", value: bitrateValue, sub: "kbps · CBR"),
            OLEDCellData(key: "Sample", value: sampleValue + " kHz", sub: "16-bit"),
            OLEDCellData(key: "Output", value: outputValue, sub: outputSub)
        ]
    }

    private var pipelineSub: String {
        let count = model.conversionQueueTracks.count
        let kind = model.isLosslessSelectedFormat ? "Lossless" : "Lossy"
        let container: String
        switch model.conversionSelection.outputFormat {
        case .aac, .alac: container = "M4A"
        default: container = model.conversionSelection.outputFormat.fileExtension.uppercased()
        }
        if count == 0 { return "Queue Idle · \(container) · \(kind)" }
        return "Queue Armed · \(count) Tracks · \(container) · \(kind)"
    }

    private var estimateNow: String {
        let s = model.conversionQueueDurationSeconds
        guard s > 0 else { return "~—" }
        let total = Int(s.rounded()), h = total / 3600, m = (total % 3600) / 60, sec = total % 60
        if h > 0 { return String(format: "~%d:%02d:%02d", h, m, sec) }
        return String(format: "~%d:%02d", m, sec)
    }

    private var sourceFormatPrimary: String {
        let formats = Set(model.conversionQueueTracks.compactMap { $0.track.formatName?.uppercased() })
        if formats.isEmpty { return "—" }
        if formats.count == 1, let only = formats.first { return only }
        return "MIX"
    }

    private var targetFormatPrimary: String { formatValue }

    private var scopeValue: String { "\(model.conversionQueueTracks.count) TRK" }
    private var scopeSub: String {
        switch model.conversionSelection.batchScope {
        case .selectedTracks:  return "Selected"
        case .currentAlbum:    return "Album"
        case .allLoadedTracks: return "All Loaded"
        }
    }

    private var formatValue: String {
        switch model.conversionSelection.outputFormat {
        case .mp3: return "MP3"; case .aac: return "AAC"; case .alac: return "ALAC"
        case .flac: return "FLAC"; case .wav: return "WAV"; case .aiff: return "AIFF"
        case .ogg: return "OGG"; case .opus: return "OPUS"
        }
    }

    private var formatSub: String {
        switch model.conversionSelection.outputFormat {
        case .aac, .alac: return "M4A · " + (model.isLosslessSelectedFormat ? "Lossless" : "Lossy")
        case .mp3, .ogg, .opus: return model.conversionSelection.outputFormat.fileExtension.uppercased() + " · Lossy"
        case .flac: return "FLAC · Lossless"
        case .wav, .aiff: return model.conversionSelection.outputFormat.fileExtension.uppercased() + " · PCM"
        }
    }

    private var bitrateValue: String {
        if model.isLosslessSelectedFormat { return "—" }
        return "\(model.conversionSelection.bitrate ?? 192)"
    }

    private var sampleValue: String {
        let hz = model.conversionSelection.sampleRate ?? 44_100
        if hz % 1000 == 0 { return "\(hz / 1000)" }
        return String(format: "%.1f", Double(hz) / 1000.0)
    }

    private var outputValue: String {
        let bytes = model.conversionEstimatedOutputBytes
        if bytes <= 0 { return "—" }
        let mb = Double(bytes) / 1_048_576.0
        if mb >= 1024 { return String(format: "~%.1f GB", mb / 1024.0) }
        return String(format: "~%.1f MB", mb)
    }

    private var outputSub: String {
        let count = model.conversionQueueTracks.count
        return count == 0 ? "No Queue" : "\(count) Tracks"
    }

    private var tickerPrefix: String {
        let count = model.conversionQueueTracks.count
        return count == 0 ? "PREVIEW · —" : String(format: "PREVIEW · 01 / %02d", count)
    }

    private var tickerPath: AttributedString {
        var out = AttributedString("")
        var head = AttributedString("~/Music/CrateDigger Library/")
        head.foregroundColor = theme.orange
        out.append(head)
        if let preview = model.conversionQueueTracks.first {
            var album = AttributedString("\(preview.track.artist)/\(preview.track.year.map(String.init) ?? "—") \(preview.track.album)/")
            album.foregroundColor = Color(hex: 0xFFD1BD)
            out.append(album)
            let ext = model.conversionSelection.outputFormat.fileExtension
            let num = String(format: "%02d", preview.track.trackNumber ?? 1)
            var title = AttributedString("\(num) \(preview.track.title).\(ext)")
            title.foregroundColor = theme.orange
            out.append(title)
        }
        return out
    }

    private var tickerMeta: String {
        switch model.conversionSelection.folderStructureMode {
        case .sourceRelative:   return "LAYOUT · SOURCE"
        case .flat:             return "LAYOUT · FLAT"
        case .metadataTemplate: return "TEMPLATE · {ARTIST}/{YEAR} {ALBUM}"
        }
    }
}

// MARK: - SCAN pane

private struct ScanPane: View {
    @EnvironmentObject private var model: LibraryViewModel
    @Environment(\.carbon) private var theme

    var body: some View {
        OLEDPaneScaffold {
            NPTitles(title: headline, sub: subtitle)
        } readout: {
            VStack(alignment: .trailing, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(percentValue)
                        .font(CarbonFont.display(34)).fontWeight(.thin).foregroundStyle(oledFG)
                    Text("%")
                        .font(CarbonFont.mono(12, weight: .semibold)).foregroundStyle(oledFGo(0.4))
                }
                ScanBar(style: .rainbow(progressValue)).frame(width: 150)
            }
            .fixedSize()
        } ticker: {
            if let data = pathTickerData {
                DSPTicker(prefix: data.prefix, path: data.path)
            } else {
                EmptyView()
            }
        } cells: {
            OLEDCells(cells)
        }
    }

    private var cells: [OLEDCellData] {
        [
            OLEDCellData(key: "Tracks", value: "\(model.index.allTracks.count)", sub: "Indexed", valueColor: theme.cyan),
            OLEDCellData(key: "Albums", value: "\(model.index.albumCount)", sub: "Releases", valueColor: theme.sun),
            OLEDCellData(key: "Artists", value: "\(model.index.artists.count)", sub: "Performers", valueColor: theme.orange),
            OLEDCellData(key: "Size", value: sizeValue, sub: "On Disk"),
            OLEDCellData(key: "Time", value: timeValue, sub: "Playtime")
        ]
    }

    private var headline: String {
        model.index.allTracks.isEmpty ? "NO LIBRARY" : "\(model.index.allTracks.count) TRACKS"
    }

    private var subtitle: String {
        if model.scanProgress.isRunning {
            if let total = model.scanProgress.totalCandidates {
                return "\(model.scanProgress.filesProbed) / \(total) files probed · Indexing"
            }
            return "\(model.scanProgress.filesProbed) files probed · Indexing"
        }
        if model.index.allTracks.isEmpty { return "Library empty · Press ⌘O to load a folder" }
        return "Indexed across \(model.index.albumCount) albums · \(sourceLine) · Ready"
    }

    private var sourceLine: String {
        if let name = model.scanProgress.folderName, !name.isEmpty { return name }
        return "Library Index"
    }

    private var percentValue: String { "\(Int((progressValue * 100).rounded()))" }

    private var progressValue: Double {
        if model.scanProgress.isRunning, let total = model.scanProgress.totalCandidates, total > 0 {
            return min(max(Double(model.scanProgress.filesProbed) / Double(total), 0), 1)
        }
        // Total not known yet (candidate enumeration) — show an empty bar, not
        // a fake stuck percentage.
        if model.scanProgress.isRunning { return 0 }
        return model.index.allTracks.isEmpty ? 0.08 : 1
    }

    private var sizeValue: String { OLEDByte.string(model.index.totalSizeBytes) }

    private var timeValue: String {
        let total = Int(model.index.allTracks.reduce(0.0) { $0 + $1.track.durationSeconds })
        guard total > 0 else { return "—" }
        let h = total / 3600, m = (total % 3600) / 60
        if h >= 24 { return "\(h / 24)d \(h % 24)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m \(total % 60)s"
    }

    private var pathTickerData: (prefix: String, path: AttributedString)? {
        guard let track = model.selectedTrack else { return nil }
        let folder = track.track.fileURL.deletingLastPathComponent().path
        let prefix: String
        let display: String
        if case .device(let root) = model.currentSource {
            let volume = URL(fileURLWithPath: root).lastPathComponent
            prefix = OLEDByte.freeSpace(forPath: root).map { "\(volume) · \($0) FREE" } ?? volume
            display = folder.hasPrefix(root) ? "/" + volume + String(folder.dropFirst(root.count)) : folder
        } else {
            prefix = "LIBRARY"
            display = folder.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        }
        let leadingSlash = display.hasPrefix("/")
        let parts = display.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        var path = AttributedString()
        for (i, part) in parts.enumerated() {
            let sep = i == 0 ? (leadingSlash ? "/" : "") : "/"
            var seg = AttributedString(sep + part)
            seg.foregroundColor = i == parts.count - 1 ? theme.orange : oledFGo(0.5)
            path.append(seg)
        }
        return (prefix, path)
    }
}

// MARK: - REMOTE SYNC pane

private struct RemoteSyncPane: View {
    @EnvironmentObject private var model: LibraryViewModel
    @Environment(\.carbon) private var theme

    var body: some View {
        OLEDPaneScaffold {
            NPTitles(title: "SYNC", sub: "Navidrome · Syncing metadata from Subsonic server…",
                     titleColor: theme.indigo)
        } readout: {
            VStack(alignment: .trailing, spacing: 6) {
                Text("CONNECTING")
                    .font(CarbonFont.mono(12, weight: .semibold)).tracking(1.7)
                    .foregroundStyle(theme.indigo)
                ScanBar(style: .indigoSweep).frame(width: 150)
            }
            .fixedSize()
        } ticker: {
            DSPTicker(prefix: "SERVER", path: serverPath)
        } cells: {
            OLEDCells([
                OLEDCellData(key: "Artists", value: "\(model.index.artists.count)", sub: "Performers", valueColor: theme.orange),
                OLEDCellData(key: "Albums", value: "\(model.index.albumCount)", sub: "Releases", valueColor: theme.sun),
                OLEDCellData(key: "Tracks", value: "\(model.index.allTracks.count)", sub: "Indexed", valueColor: theme.cyan)
            ])
        }
    }

    private var serverPath: AttributedString {
        var out = AttributedString("https://music.example.net")
        out.foregroundColor = theme.orange
        var tail = AttributedString(" · SUBSONIC API v1.16")
        tail.foregroundColor = oledFGo(0.5)
        out.append(tail)
        return out
    }
}

// MARK: - CD RIP pane

private struct CDRipPane: View {
    @EnvironmentObject private var model: LibraryViewModel
    @Environment(\.carbon) private var theme

    private var done: Int { model.conversionProgress.jobsCompleted }
    private var total: Int { model.conversionProgress.jobsTotal }

    var body: some View {
        OLEDPaneScaffold {
            NPTitles(title: "CD-RIP", sub: "Audio CD · 44.1 kHz · 16-bit PCM · Ripping")
        } readout: {
            VStack(alignment: .trailing, spacing: 6) {
                NPClock(now: String(format: "%02d", min(done + 1, max(total, 1))),
                        tot: "/ \(String(format: "%02d", total))")
                ScanBar(style: .orange(progress)).frame(width: 150)
            }
            .fixedSize()
        } ticker: {
            DSPTicker(prefix: String(format: "RIPPING · %02d / %02d", min(done + 1, max(total, 1)), total),
                      path: AttributedString("~/Music/CrateDigger Library/"))
        } cells: {
            OLEDCells([
                OLEDCellData(key: "Disc", value: "CDDA", sub: "Audio CD"),
                OLEDCellData(key: "Output", value: "FLAC", sub: "Lossless"),
                OLEDCellData(key: "Speed", value: "8.2×", sub: "Average"),
                OLEDCellData(key: "Elapsed", value: "—", sub: "This Disc"),
                OLEDCellData(key: "Remain", value: total > done ? "\(total - done) TRK" : "—", sub: "Remaining")
            ])
        }
    }

    private var progress: Double {
        total > 0 ? Double(done) / Double(total) : 0
    }
}

// MARK: - DEVICES pane

private struct DevicesPane: View {
    @EnvironmentObject private var model: LibraryViewModel
    @Environment(\.carbon) private var theme

    private var profiles: [ExternalDeviceProfile] { PreferencesStore.shared.savedExternalDeviceProfiles }

    var body: some View {
        if let sync = model.deviceSyncProgress {
            syncBody(sync)
        } else if let c = connected {
            deviceBody(profile: c.profile, device: c.device)
        } else {
            emptyBody
        }
    }

    // MARK: Sync readout (SYNC → DEVICE / SYNC COMPLETE)

    private func syncBody(_ sync: DeviceSyncProgressSnapshot) -> some View {
        OLEDPaneScaffold {
            HStack(alignment: .bottom, spacing: 18) {
                DevGlyph()
                NPTitles(
                    title: sync.isRunning
                        ? "SYNC → \(sync.profileName.uppercased())"
                        : "SYNC COMPLETE",
                    sub: sync.isRunning
                        ? "Copying \(min(sync.completed + 1, sync.total)) of \(sync.total)"
                        : "\(sync.completed) track\(sync.completed == 1 ? "" : "s")"
                            + (sync.failed > 0 ? " · \(sync.failed) failed" : "")
                            + " · \(sync.profileName)",
                    titleSize: 40
                )
            }
        } readout: {
            // Bar-beside-the-numbers, 150pt — the same readout shape as SCAN /
            // CD / capacity, so the pane's geometry never shifts mid-sync.
            VStack(alignment: .trailing, spacing: 4) {
                NPClock(now: "\(sync.completed)", tot: "OF \(sync.total)")
                ScanBar(style: .orange(sync.total > 0 ? Double(sync.completed) / Double(sync.total) : 0))
                    .frame(width: 150)
            }
            .fixedSize()
        } ticker: {
            DSPTicker(
                prefix: "SYNC",
                path: AttributedString(sync.currentRelativePath ?? "—"),
                leadingInset: 62
            )
        } cells: {
            // Every pane ends with the OLEDCells rail — it pins the bottom of
            // the glass so panes never resize as state flips (the old OLED
            // size-jump bug). Never put anything else in this slot.
            OLEDCells([
                OLEDCellData(key: "Queue", value: "\(sync.total)", sub: "Tracks", valueColor: theme.cyan),
                OLEDCellData(key: "Synced", value: "\(sync.completed)", sub: sync.isRunning ? "Copying" : "Done",
                             valueColor: theme.orange),
                OLEDCellData(key: "Failed", value: sync.failed > 0 ? "\(sync.failed)" : "—",
                             sub: sync.failed > 0 ? "Kept in queue" : "None"),
                OLEDCellData(key: "Device", value: sync.profileName.uppercased(), sub: "Target")
            ])
        }
    }

    /// A saved device profile whose configured root is *currently mounted* — the
    /// pane only shows a device that is actually connected and set up in Settings.
    /// Prefers the device the user is browsing.
    private var connected: (profile: ExternalDeviceProfile, device: MountedDevice)? {
        let mounted = model.mountedDevices
        guard !mounted.isEmpty, !profiles.isEmpty else { return nil }
        func match(_ dev: MountedDevice) -> ExternalDeviceProfile? {
            profiles.first { p in
                (p.rootDisplayPath.map { $0 == dev.volumeURL.path } ?? false)
                    || p.name.caseInsensitiveCompare(dev.name) == .orderedSame
            }
        }
        if case .device(let path) = model.currentSource,
           let dev = mounted.first(where: { $0.volumeURL.path == path }), let p = match(dev) {
            return (p, dev)
        }
        for dev in mounted { if let p = match(dev) { return (p, dev) } }
        return nil
    }

    // MARK: Connected device

    private func deviceBody(profile: ExternalDeviceProfile, device: MountedDevice) -> some View {
        OLEDPaneScaffold {
            HStack(alignment: .bottom, spacing: 18) {
                DevGlyph()
                NPTitles(title: device.name.uppercased(),
                         sub: "\(profile.kind.title) · Mounted · \(device.volumeURL.path)",
                         titleSize: 40)
            }
        } readout: {
            capacityReadout(for: device).fixedSize()
        } ticker: {
            DSPTicker(prefix: "MUSIC DIR", path: musicDirPath(profile, device), leadingInset: 62)
        } cells: {
            OLEDCells(cells(for: profile))
        }
    }

    // MARK: Empty state (nothing connected / configured)

    private var emptyBody: some View {
        OLEDPaneScaffold {
            HStack(alignment: .bottom, spacing: 18) {
                DevGlyph().opacity(0.4)
                NPTitles(title: "NO DEVICE", sub: emptySub, titleSize: 40)
            }
        } readout: {
            NPClock(now: "—", tot: "GB FREE").fixedSize()
        } ticker: {
            EmptyView()
        } cells: {
            OLEDCells([
                OLEDCellData(key: "Kind", value: "—", sub: "No Device", valueColor: theme.cyan),
                OLEDCellData(key: "Transfer", value: "—", sub: "—"),
                OLEDCellData(key: "Format", value: "—", sub: "—"),
                OLEDCellData(key: "Artwork", value: "—", sub: "—"),
                OLEDCellData(key: "Profiles", value: "\(profiles.count)", sub: "Saved")
            ])
        }
    }

    private var emptySub: String {
        profiles.isEmpty
            ? "Add a device profile in Settings, then connect it"
            : "Connect a saved device — none mounted right now"
    }

    // MARK: Readout (capacity)

    @ViewBuilder
    private func capacityReadout(for device: MountedDevice) -> some View {
        if let cap = capacity(of: device) {
            let freeGB = Double(cap.free) / 1_000_000_000
            let totalGB = Double(cap.total) / 1_000_000_000
            let usedFrac = 1 - Double(cap.free) / Double(cap.total)
            VStack(alignment: .trailing, spacing: 6) {
                NPClock(now: String(format: "%.1f", freeGB), tot: "GB FREE")
                Text("OF \(Int(totalGB.rounded())) GB · \(Int((usedFrac * 100).rounded()))% USED")
                    .font(CarbonFont.mono(9.5, weight: .semibold))
                    .tracking(1.9).textCase(.uppercase)
                    .foregroundStyle(oledMuted)
                ScanBar(style: .orange(usedFrac)).frame(width: 150)
            }
        } else {
            NPClock(now: "—", tot: "GB FREE")
        }
    }

    private func capacity(of device: MountedDevice) -> (free: Int64, total: Int64)? {
        guard let v = try? device.volumeURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]),
              let free = v.volumeAvailableCapacityForImportantUsage,
              let total = v.volumeTotalCapacity, total > 0
        else { return nil }
        return (Int64(free), Int64(total))
    }

    // MARK: Ticker (music dir + template)

    private func musicDirPath(_ profile: ExternalDeviceProfile, _ device: MountedDevice) -> AttributedString {
        let sub = profile.musicDirectorySubpath.isEmpty ? "" : profile.musicDirectorySubpath + "/"
        var out = AttributedString("/\(device.name)/")
        out.foregroundColor = oledFGo(0.5)
        if !sub.isEmpty {
            var leaf = AttributedString(sub)
            leaf.foregroundColor = theme.orange
            out.append(leaf)
        }
        var tmpl = AttributedString(" · \(templateString(profile))")
        tmpl.foregroundColor = oledFGo(0.5)
        out.append(tmpl)
        return out
    }

    private func templateString(_ p: ExternalDeviceProfile) -> String {
        switch p.transferSettings.folderStructureMode {
        case .flat:           return "FLAT"
        case .sourceRelative: return "SOURCE"
        case .metadataTemplate:
            let tokens = p.transferSettings.templateConfig.tokenOrder.filter { !$0.isDisabled }
            guard !tokens.isEmpty else { return "FLAT" }
            return tokens.map { "{\($0.title.uppercased())}" }.joined(separator: "/")
        }
    }

    // MARK: Cells

    private func cells(for profile: ExternalDeviceProfile) -> [OLEDCellData] {
        let s = profile.transferSettings
        let transfer = s.mode == .copyOriginals ? ("COPY", "Originals") : ("CONVERT", "During Copy")
        let fmt = s.outputFormat.fileExtension.uppercased()
        let fmtSub = s.outputFormat.isLossless ? "Lossless" : "\(s.bitrateKbps ?? 192) kbps"
        let artwork: (String, String) = s.artworkMaxDimension.map { ("\($0) px", "Re-embed") } ?? ("KEEP", "Preserve")
        return [
            OLEDCellData(key: "Kind", value: kindCell(profile.kind).0, sub: kindCell(profile.kind).1, valueColor: theme.cyan),
            OLEDCellData(key: "Transfer", value: transfer.0, sub: transfer.1),
            OLEDCellData(key: "Format", value: fmt, sub: fmtSub),
            OLEDCellData(key: "Artwork", value: artwork.0, sub: artwork.1),
            OLEDCellData(key: "Profiles", value: "\(profiles.count)", sub: "Saved")
        ]
    }

    private func kindCell(_ kind: ExternalDeviceKind) -> (String, String) {
        switch kind {
        case .rockboxIPod:            return ("ROCKBOX", "iPod")
        case .sdCard:                 return ("SD CARD", "Player")
        case .directFilePlayer:       return ("PLAYER", "Direct")
        case .genericExternalStorage: return ("STORAGE", "External")
        }
    }
}

/// The connected player drawn as lit display segments (like the cassette/CD
/// glyphs on 90s Sony FL displays) — NOT an image: an outlined body, a
/// cyan-tinted screen, a click-wheel with a glowing orange hub, and a
/// dock-connector bar below.
private struct DevGlyph: View {
    @Environment(\.carbon) private var theme

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                    .fill(theme.cyan.opacity(0.14))
                    .overlay(RoundedRectangle(cornerRadius: 2.5, style: .continuous).stroke(oledFGo(0.65), lineWidth: 1))
                    .frame(width: 30, height: 21)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, 7)

                ZStack {
                    Circle().stroke(oledFGo(0.65), lineWidth: 1).frame(width: 27, height: 27)
                    Circle().fill(theme.orange).frame(width: 8, height: 8)
                        .shadow(color: theme.orange.opacity(0.6), radius: 5)
                }
                .frame(maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 8)
            }
            .frame(width: 44, height: 74)
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(oledFGo(0.8), lineWidth: 1.5)
            )
            .shadow(color: oledFGo(0.16), radius: 9)

            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(oledFGo(0.5))
                .frame(width: 14, height: 3)
        }
        // Scaled down so the DEV headline matches the NPTitles height of every
        // other pane — the glass has fixed geometry and must never grow when
        // panes swap. (The old repeatForever connector pulse is gone too: an
        // infinite CA animation keeps WindowServer compositing at ~12% GPU.)
        .scaleEffect(0.79)
        .frame(width: 35, height: 64)
    }
}

// MARK: - Byte / free-space helpers

enum OLEDByte {
    static func string(_ bytes: Int64) -> String {
        let mb = Double(bytes) / 1_048_576
        if mb >= 1024 { return String(format: "%.1f GB", mb / 1024) }
        if mb >= 1 { return String(format: "%.0f MB", mb) }
        return String(format: "%.0f KB", Double(bytes) / 1024)
    }

    static func freeSpace(forPath path: String) -> String? {
        let url = URL(fileURLWithPath: path)
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let bytes = values.volumeAvailableCapacityForImportantUsage else { return nil }
        return string(Int64(bytes))
    }
}
