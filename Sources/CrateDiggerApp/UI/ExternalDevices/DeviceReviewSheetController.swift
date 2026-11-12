import AppKit
import CrateDiggerCore
import SwiftUI

/// "Already on <device>": one row per album whose copy on the device differs
/// from the one being sent, each answered Replace, Keep both or Leave it.
/// Nothing is pre-selected, and Continue stays off until every row shown has
/// an answer. The row text and the answer state are Core's
/// (`DeviceReviewRow`, `DeviceReviewState`); this only draws them.
final class DeviceReviewSheetController: ThemedSheetHostingController {
    /// The answers for the rows shown, or nil for Cancel (nothing is written).
    var onDecision: (([DeviceAlbumIdentity: DeviceAlbumDecision]?) -> Void)?
    /// The sheet left the screen, answered or not. Separate from `onDecision`
    /// so it can never dismiss the sheet again from inside a dismissal.
    var onDisappear: (() -> Void)?

    private let review: DeviceTransferReview
    private let deviceName: String
    private let settings: ExternalDeviceTransferSettings
    private let maxListHeight: CGFloat
    private let initialState: DeviceReviewState
    private let initiallyShowsLeftAlone: Bool

    /// `initialState` and `showsLeftAlone` exist for the DEBUG capture of an
    /// answered sheet; a transfer always opens it unanswered.
    init(
        review: DeviceTransferReview,
        deviceName: String,
        settings: ExternalDeviceTransferSettings,
        maxListHeight: CGFloat,
        initialState: DeviceReviewState = DeviceReviewState(),
        showsLeftAlone: Bool = false
    ) {
        self.review = review
        self.deviceName = deviceName
        self.settings = settings
        self.maxListHeight = maxListHeight
        self.initialState = initialState
        self.initiallyShowsLeftAlone = showsLeftAlone
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let rootView = DeviceReviewSheetView(
            review: review,
            deviceName: deviceName,
            settings: settings,
            maxListHeight: maxListHeight,
            initialState: initialState,
            showsLeftAlone: initiallyShowsLeftAlone
        ) { [weak self] decisions in
            self?.onDecision?(decisions)
        }
        setThemedRoot(rootView)
    }

    /// The sheet went away without an answer (closed with its window,
    /// dismissed from outside): the caller treats that as a Cancel. After
    /// Continue or Cancel the answer was already delivered, and this is ignored.
    override func viewDidDisappear() {
        super.viewDidDisappear()
        onDisappear?()
    }

    /// The list scrolls rather than growing the sheet past its window: room
    /// for the header and buttons is taken off the window's height (or the
    /// screen's, whichever is smaller), never below a few rows' worth, so a
    /// compact-player window still gets a usable list.
    static func maxListHeight(for window: NSWindow?) -> CGFloat {
        let chrome: CGFloat = 270
        let floor: CGFloat = 240
        let screen = (window?.screen ?? NSScreen.main)?.visibleFrame.height ?? 800
        let windowHeight = window?.frame.height ?? screen
        return max(floor, min(windowHeight, screen) - chrome)
    }
}

extension LibraryViewModel {
    /// Asks about the albums of `review` that differ from the device's copy.
    /// Returns the answer for each album shown, or nil when the user cancels
    /// the transfer. Presented from `host`, which callers take from
    /// `presentationHostViewController`, so it works in the compact player.
    ///
    /// No album to ask about returns no answers at once, without a sheet.
    /// It always returns: a host without a window is a Cancel, and so is a
    /// sheet that goes away unanswered, or whose window closes before it
    /// shows (a sheet presented while another is attached waits its turn).
    func presentDeviceReview(
        _ review: DeviceTransferReview,
        deviceName: String,
        settings: ExternalDeviceTransferSettings,
        presentingFrom host: NSViewController
    ) async -> [DeviceAlbumIdentity: DeviceAlbumDecision]? {
        await presentDeviceReview(review, deviceName: deviceName, settings: settings,
                                  presentingFrom: host, initialState: DeviceReviewState(), showsLeftAlone: false)
    }

    func presentDeviceReview(
        _ review: DeviceTransferReview,
        deviceName: String,
        settings: ExternalDeviceTransferSettings,
        presentingFrom host: NSViewController,
        initialState: DeviceReviewState,
        showsLeftAlone: Bool
    ) async -> [DeviceAlbumIdentity: DeviceAlbumDecision]? {
        guard DeviceReviewRow.needsReview(review) else { return [:] }
        guard let window = host.view.window else {
            AppLog.library.error("Device review for \(deviceName, privacy: .public) has no window to present from; cancelling the transfer")
            return nil
        }
        return await withCheckedContinuation { continuation in
            let controller = DeviceReviewSheetController(
                review: review,
                deviceName: deviceName,
                settings: settings,
                maxListHeight: DeviceReviewSheetController.maxListHeight(for: window),
                initialState: initialState,
                showsLeftAlone: showsLeftAlone
            )
            var resumed = false
            var windowClose: NSObjectProtocol?
            // Resumes exactly once: the first answer wins, and the later
            // calls (the disappear after a dismiss, a window closing) find
            // `resumed` set.
            func finish(_ decisions: [DeviceAlbumIdentity: DeviceAlbumDecision]?) {
                guard !resumed else { return }
                resumed = true
                if let windowClose { NotificationCenter.default.removeObserver(windowClose) }
                windowClose = nil
                continuation.resume(returning: decisions)
            }
            controller.onDecision = { [weak controller] decisions in
                guard !resumed else { return }
                // Deliver first: dismissing runs viewDidDisappear, whose
                // Cancel must not become the answer.
                finish(decisions)
                controller?.dismiss(nil)
            }
            controller.onDisappear = { finish(nil) }
            windowClose = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
            ) { _ in
                MainActor.assumeIsolated { finish(nil) }
            }
            host.presentAsSheet(controller)
        }
    }
}

// MARK: - SwiftUI body

private struct DeviceReviewSheetView: View {
    @Environment(\.carbon) private var theme

    let review: DeviceTransferReview
    let deviceName: String
    let settings: ExternalDeviceTransferSettings
    let maxListHeight: CGFloat
    let onDecision: ([DeviceAlbumIdentity: DeviceAlbumDecision]?) -> Void

    @State private var state: DeviceReviewState
    @State private var showsLeftAlone: Bool
    @State private var listHeight: CGFloat = 0

    init(
        review: DeviceTransferReview,
        deviceName: String,
        settings: ExternalDeviceTransferSettings,
        maxListHeight: CGFloat,
        initialState: DeviceReviewState,
        showsLeftAlone: Bool,
        onDecision: @escaping ([DeviceAlbumIdentity: DeviceAlbumDecision]?) -> Void
    ) {
        self.review = review
        self.deviceName = deviceName
        self.settings = settings
        self.maxListHeight = maxListHeight
        self.onDecision = onDecision
        _state = State(initialValue: initialState)
        _showsLeftAlone = State(initialValue: showsLeftAlone)
    }

    private static let sheetWidth: CGFloat = 760
    private static let choiceWidth: CGFloat = 264
    private static let labelWidth: CGFloat = 74
    private static let fadeHeight: CGFloat = 36

    private var rows: [DeviceReviewRow] {
        DeviceReviewRow.rows(for: review, settings: settings, includingLeftAlone: showsLeftAlone)
    }

    private var leftAloneCount: Int { DeviceReviewRow.leftAloneCount(in: review) }

    var body: some View {
        let rows = rows
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.bottom, 14)
            controls(rows)
                .padding(.bottom, 10)
            list(rows)
                .padding(.bottom, 12)
            Divider()
                .padding(.bottom, 14)
            actionBar(rows)
        }
        .padding(20)
        .frame(width: Self.sheetWidth)
        .background(theme.chassis)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Already on \(deviceName)")
                .font(CarbonFont.sans(22, weight: .bold))
                .foregroundStyle(theme.ink)
                .lineLimit(1)
                .truncationMode(.middle)
            Text("These albums are on the device in another form. Choose what to do with each one.")
                .font(CarbonFont.sans(13))
                .foregroundStyle(theme.ink2)
                .fixedSize(horizontal: false, vertical: true)
            // The rest of the batch, which goes ahead without asking.
            HStack(spacing: 8) {
                Text("NO ANSWER NEEDED")
                    .font(CarbonFont.mono(8.5, weight: .bold))
                    .tracking(1.4)
                    .foregroundStyle(theme.ink3)
                Text(DeviceReviewRow.summary(of: review))
                    .font(CarbonFont.mono(11))
                    .foregroundStyle(theme.ink2)
            }
            .padding(.top, 2)
        }
    }

    // MARK: Set all, left alone

    private func controls(_ rows: [DeviceReviewRow]) -> some View {
        HStack(spacing: 14) {
            Menu("Set all to…") {
                Button("Replace") { state.setAll(.replace, rows: rows) }
                Button("Keep both") { state.setAll(.keepBoth, rows: rows) }
                Button("Leave it") { state.setAll(.leave, rows: rows) }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityHint("Gives every album below the same answer.")

            Spacer()

            if leftAloneCount > 0 {
                Toggle(isOn: Binding(
                    get: { showsLeftAlone },
                    set: { show in
                        showsLeftAlone = show
                        if show {
                            state.presetLeftAlone(rows: DeviceReviewRow.rows(
                                for: review, settings: settings, includingLeftAlone: true
                            ))
                        }
                    }
                )) {
                    Text("Show \(leftAloneCount) \(leftAloneCount == 1 ? "album" : "albums") left alone")
                        .font(CarbonFont.mono(11, weight: .medium))
                        .foregroundStyle(theme.ink2)
                }
                .toggleStyle(.checkbox)
                .accessibilityHint("Lists the albums you chose to leave alone before, so you can change your answer.")
            }
        }
    }

    // MARK: Rows

    /// Sized to its rows up to `maxListHeight`, then scrolls.
    /// When it scrolls, the bottom edge fades into the chassis: a list whose
    /// cut lands on a row boundary otherwise gives no hint that more albums
    /// wait below (overlay scrollers stay hidden until a scroll).
    private func list(_ rows: [DeviceReviewRow]) -> some View {
        let overflows = listHeight > maxListHeight
        return ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(rows) { row in
                    rowView(row)
                }
            }
            .padding(.trailing, 2)
            .background(GeometryReader { proxy in
                Color.clear.preference(key: ListHeightKey.self, value: proxy.size.height)
            })
            // Outside the measurement: room for the last row to clear the fade.
            .padding(.bottom, overflows ? Self.fadeHeight : 0)
        }
        .scrollIndicators(overflows ? .visible : .automatic)
        .frame(height: min(max(listHeight, 1), maxListHeight))
        .overlay(alignment: .bottom) {
            if overflows {
                LinearGradient(colors: [theme.chassis.opacity(0), theme.chassis],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: Self.fadeHeight)
                    .allowsHitTesting(false)
            }
        }
        .onPreferenceChange(ListHeightKey.self) { listHeight = $0 }
    }

    private func rowView(_ row: DeviceReviewRow) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(row.title)
                    .font(CarbonFont.sans(13, weight: .semibold))
                    .foregroundStyle(theme.ink)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(row.title)
                Text(row.artist)
                    .font(CarbonFont.sans(11.5))
                    .foregroundStyle(theme.ink2)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 3) {
                    comparisonLine("ON DEVICE", row.onDevice)
                    comparisonLine("SENDING", row.sending)
                }
                .padding(.top, 5)

                if let note = row.note {
                    Label(note, systemImage: "exclamationmark.circle")
                        .font(CarbonFont.mono(10.5, weight: .medium))
                        .foregroundStyle(theme.orange)
                        .padding(.top, 3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 6) {
                Picker("Answer for \(row.title)", selection: decision(for: row.id)) {
                    Text("Replace").tag(DeviceAlbumDecision?.some(.replace))
                    Text("Keep both").tag(DeviceAlbumDecision?.some(.keepBoth))
                    Text("Leave it").tag(DeviceAlbumDecision?.some(.leave))
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: Self.choiceWidth)
                .accessibilityHint(row.replaceEffect)

                Text(row.replaceEffect)
                    .font(CarbonFont.mono(10))
                    .foregroundStyle(theme.ink3)
                    .multilineTextAlignment(.trailing)
                    .frame(width: Self.choiceWidth, alignment: .trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(theme.paper)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(theme.hair.opacity(0.5), lineWidth: 1)
        )
    }

    private func comparisonLine(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .font(CarbonFont.mono(8.5, weight: .bold))
                .tracking(1.4)
                .foregroundStyle(theme.ink3)
                .frame(width: Self.labelWidth, alignment: .leading)
            Text(value)
                .font(CarbonFont.mono(11))
                .foregroundStyle(theme.ink)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private func decision(for id: DeviceAlbumIdentity) -> Binding<DeviceAlbumDecision?> {
        Binding(
            get: { state.decisions[id] },
            set: { state.decisions[id] = $0 }
        )
    }

    // MARK: Buttons

    private func actionBar(_ rows: [DeviceReviewRow]) -> some View {
        let answered = rows.filter { state.decisions[$0.id] != nil }.count
        let canConfirm = state.canConfirm(rows: rows)
        return HStack(spacing: 12) {
            Text(canConfirm
                 ? "Every album has an answer."
                 : "\(answered) of \(rows.count) answered. Choose for every album to continue.")
                .font(CarbonFont.mono(10.5))
                .foregroundStyle(theme.ink3)
            Spacer()
            Button("Cancel") {
                onDecision(nil)
            }
            .keyboardShortcut(.cancelAction)
            .accessibilityHint("Stops the whole transfer. Nothing is written to the device.")

            Button("Continue") {
                guard canConfirm else { return }
                onDecision(state.result(rows: rows))
            }
            .keyboardShortcut(.defaultAction)
            .tint(theme.orange)
            .disabled(!canConfirm)
            .accessibilityHint("Sends the transfer with these answers.")
        }
    }
}

private struct ListHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - DEBUG sample

#if DEBUG
extension DeviceReviewSheetController {
    /// `CRATEDIGGER_DEVICE_REVIEW=1`: a review with a row for each kind of
    /// difference (audio form, art size, other release, a name taken, two
    /// copies on the device, a very long title) plus one album left alone
    /// before, so the sheet can be captured without a device plugged in.
    static func debugSample() -> (review: DeviceTransferReview, settings: ExternalDeviceTransferSettings) {
        let settings = ExternalDeviceTransferSettings(mode: .copyOriginals)

        func tracks(_ count: Int, artist: String, album: String, format: String, kbps: Int?, rate: Int, root: String) -> [LoadedTrack] {
            guard count > 0 else { return [] }
            return (1...count).map { number in
                let url = URL(fileURLWithPath: root)
                    .appendingPathComponent(artist)
                    .appendingPathComponent(album)
                    .appendingPathComponent(String(format: "%02d Track %d.%@", number, number, format.lowercased()))
                let audio = AudioTrack(fileURL: url, title: "Track \(number)", artist: artist, album: album,
                                       formatName: format, bitrateKbps: kbps, sampleRateHz: rate, trackNumber: number)
                return LoadedTrack(track: audio, metadata: ConversionMetadata(
                    title: "Track \(number)", artist: artist, album: album, trackNumber: number))
            }
        }

        func album(
            _ artist: String, _ title: String,
            status: DeviceAlbumStatus = .differs,
            differences: Set<DeviceAlbumDifference> = [],
            sent: (count: Int, format: String, kbps: Int?, rate: Int),
            device: (count: Int, format: String, kbps: Int?, rate: Int)?,
            changed: Int = 0,
            copies: Int = 1,
            art: (sent: Int?, device: Int?) = (nil, nil),
            leftAlone: Bool = false
        ) -> DeviceAlbumComparison {
            let sentTracks = tracks(sent.count, artist: artist, album: title, format: sent.format,
                                    kbps: sent.kbps, rate: sent.rate, root: "/Users/Shared/Library")
            let deviceTracks = device.map {
                tracks($0.count, artist: artist, album: title, format: $0.format, kbps: $0.kbps, rate: $0.rate,
                       root: "/Volumes/IPOD/Music")
            } ?? []
            let pairs = Array(zip(sentTracks.prefix(changed), deviceTracks)).map { (sent: $0, device: $1) }
            let matched = status == .differs ? changed : min(sentTracks.count, deviceTracks.count)
            return DeviceAlbumComparison(
                identity: DeviceAlbumIdentity(artist: artist, album: title),
                displayArtist: artist,
                displayAlbum: title,
                status: status,
                differences: differences,
                sent: sentTracks,
                missing: Array(sentTracks.dropFirst(matched)),
                same: status == .differs ? [] : Array(sentTracks.prefix(matched)),
                changed: pairs,
                deviceTracks: deviceTracks,
                deviceFolder: deviceTracks.first?.track.fileURL.deletingLastPathComponent(),
                deviceCopyCount: device == nil ? 0 : copies,
                sentArtPixels: art.sent,
                deviceArtPixels: art.device,
                isLeftAlone: leftAlone
            )
        }

        let albums: [DeviceAlbumComparison] = [
            album("Miles Davis", "Kind of Blue", differences: [.audioForm, .artSize],
                  sent: (11, "flac", nil, 44_100), device: (5, "MP3", 128, 44_100),
                  changed: 5, art: (1400, 600)),
            album("Talk Talk", "Spirit of Eden", differences: [.artSize],
                  sent: (6, "MP3", 320, 44_100), device: (6, "MP3", 320, 44_100),
                  changed: 6, art: (1200, 500)),
            album("David Bowie",
                  "The Rise and Fall of Ziggy Stardust and the Spiders from Mars (50th Anniversary Half-Speed Remaster)",
                  differences: [.differentRelease],
                  sent: (13, "flac", nil, 96_000), device: (11, "AAC", 256, 44_100),
                  art: (1000, 1000)),
            album("Boards of Canada", "Music Has the Right to Children", differences: [.pathTaken],
                  sent: (17, "flac", nil, 44_100), device: nil,
                  art: (1400, nil)),
            album("Nina Simone", "Little Girl Blue", differences: [.audioForm],
                  sent: (11, "PCM_S24LE", 4608, 96_000), device: (11, "flac", nil, 44_100),
                  changed: 11, copies: 2, art: (800, 800)),
            album("Godspeed You! Black Emperor", "Lift Your Skinny Fists Like Antennas to Heaven",
                  differences: [.audioForm],
                  sent: (4, "flac", nil, 44_100), device: (4, "MP3", 192, 44_100),
                  changed: 4, art: (nil, nil)),
            album("Aphex Twin", "Selected Ambient Works 85-92", differences: [.audioForm],
                  sent: (13, "flac", nil, 44_100), device: (13, "MP3", 160, 44_100),
                  changed: 13, art: (1200, 300), leftAlone: true),
            // The rest of the batch, for the summary line.
            album("Can", "Tago Mago", status: .new, sent: (7, "flac", nil, 44_100), device: nil),
            album("Stereolab", "Dots and Loops", status: .present,
                  sent: (10, "MP3", 320, 44_100), device: (10, "MP3", 320, 44_100)),
            album("Slowdive", "Souvlaki", status: .gaps,
                  sent: (10, "MP3", 320, 44_100), device: (4, "MP3", 320, 44_100))
        ]
        return (DeviceTransferReview(albums: albums), settings)
    }
}
#endif
