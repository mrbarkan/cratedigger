import AppKit
import CrateDiggerCore
import SwiftUI

/// Presents the artist photo viewer (spec §6): the album artwork viewer's
/// full-screen window, glass bar, zoom and keys, showing an artist's photos in
/// the order they were added. Opened from the artist page's portrait.
@MainActor
enum ArtistPhotoViewerPresenter {
    private static var window: BorderlessBookletWindow?

    static func show(name: String, theme: CarbonTheme, model: LibraryViewModel) {
        close()
        let view = ArtistPhotoNavigator(name: name, onClose: { close() })
            .environmentObject(model)
            .environment(\.carbon, theme)
        let w = BorderlessBookletWindow(contentView: AnyView(view))
        // A dark room whatever the app's Appearance says, as the album viewer
        // is, so the glass bar reads one way across the row.
        w.appearance = NSAppearance(named: .darkAqua)
        w.presentFading()
        window = w
    }

    static func close() {
        window?.dismissFading()
        window = nil
    }
}

/// The artist's photos, as large as the screen allows, with the controls in a
/// strip below: BACK / FWD and the count, zoom and the backdrop dim, then
/// Make Default, Add Photos…, Remove and Show Credit, then CLOSE. The default
/// carries a mark. ← and → page; Esc closes. The photos are the profile as it
/// now stands, so a photo added, removed or made the default shows at once.
struct ArtistPhotoNavigator: View {
    @Environment(\.carbon) private var theme
    @EnvironmentObject private var model: LibraryViewModel
    let name: String
    let onClose: () -> Void

    @State private var index = 0
    @State private var images: [String: NSImage] = [:]
    @State private var zoom: ArtZoom = .fit
    @State private var pan = ArtworkPan()
    @State private var eventMonitor: Any?
    @State private var showingCredit = false
    @State private var confirmingRemove = false
    @State private var dropTargeted = false
    /// Photos whose file could not be read (the library drive unplugged).
    /// Cleared when the library is available again.
    @State private var unreachable: Set<String> = []
    /// Bumped to load the pictures again (the drive came back).
    @State private var reloadToken = 0
    /// Open while the viewer's own file picker runs, so its keys stay its own.
    @State private var modal = ModalGate()
    /// What went wrong with an add or a download, shown here: the main
    /// window's alert would sit under this floating viewer.
    @State private var notice: String?
    /// The album viewer's own dim, so the two rooms are as dark as each other.
    @AppStorage("artworkBackdropDim") private var backdropDim = 0.55

    private static let barHeight = ArtworkBar.barHeight

    private var profile: ArtistProfile? { model.artistProfile(named: name) }
    private var photos: [ArtistPhoto] { profile?.photos ?? [] }
    private var current: ArtistPhoto? { photos.indices.contains(index) ? photos[index] : nil }
    private var isDefault: Bool { current.map { $0.hash == profile?.defaultPhoto } ?? false }

    var body: some View {
        ZStack {
            Color.black.opacity(backdropDim)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { onClose() }

            VStack(spacing: 0) {
                viewport
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, 40)
                    .padding(.top, 32)

                controlCluster
                    .padding(.top, 14)
                    .padding(.bottom, 30)
            }
        }
        // Pictures dropped anywhere on the viewer become the owner's photos.
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            ArtistPhotoDrop.load(providers) { urls in
                guard libraryIsWritable() else { return }
                model.addArtistPhotos(name, urls: urls)
            }
        }
        .onAppear {
            if let start = photos.firstIndex(where: { $0.hash == profile?.defaultPhoto }) { index = start }
            // The Remove confirmation and the file picker own the keyboard
            // while they are up: Esc and the arrows are theirs, not the viewer's.
            let gate = modal
            eventMonitor = ArtworkKeys.install(blocked: { confirmingRemove || gate.isOpen }, close: onClose,
                                               step: step)
        }
        .onDisappear {
            if let monitor = eventMonitor { NSEvent.removeMonitor(monitor) }
            eventMonitor = nil
        }
        .task(id: "\(current?.hash ?? "")|\(photos.count)|\(reloadToken)") { await loadAround() }
        // The drive came back: what could not be reached may be there now.
        .onChange(of: model.libraryLocation) { location in
            guard case .available = location, !unreachable.isEmpty else { return }
            unreachable = []
            reloadToken += 1
        }
        // An artist photo add or download that failed while this is open.
        .onChange(of: model.appAlert?.id) { _ in
            guard let alert = model.appAlert, Self.photoAlertTitles.contains(alert.title) else { return }
            notice = "\(alert.title). \(alert.message)"
            model.appAlert = nil
        }
        .onChange(of: current?.hash) { _ in pan = ArtworkPan() }
        // A photo removed (here or in the Edit sheet): stay on the one that
        // took its place, or the last.
        .onChange(of: photos.count) { count in index = min(index, max(0, count - 1)) }
    }

    // MARK: - The picture

    private var viewport: some View {
        GeometryReader { geo in
            ZStack {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { onClose() }
                picture(viewport: geo.size)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(theme.orange, style: StrokeStyle(lineWidth: 2, dash: [6, 5]))
                    .opacity(dropTargeted ? 1 : 0)
                    .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder
    private func picture(viewport: CGSize) -> some View {
        if let photo = current {
            if let image = images[photo.hash] {
                ZoomableArtwork(image: image, zoom: zoom, pan: $pan, viewport: viewport)
            } else if unreachable.contains(photo.hash) {
                emptyState("This photo's file cannot be reached. Is the library's drive connected?")
            } else {
                ProgressView().controlSize(.large)
            }
        } else {
            emptyState("No photos of \(name) yet. Add your own, or drop pictures here.")
        }
    }

    private func emptyState(_ text: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "person.crop.square")
                .font(.system(size: 64, weight: .ultraLight))
                .foregroundStyle(.white.opacity(0.4))
            Text(text)
                .font(CarbonFont.mono(11, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
        }
        .onTapGesture {}
    }

    // MARK: - Control cluster

    private var controlCluster: some View {
        VStack(spacing: 8) {
            Text(name)
                .font(CarbonFont.sans(21, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1)

            HStack(spacing: 8) {
                Text(caption)
                    .foregroundStyle(.white.opacity(0.7))
                if isDefault {
                    Text("·").foregroundStyle(.white.opacity(0.4))
                    Text("DEFAULT").foregroundStyle(theme.orange)
                }
            }
            .font(CarbonFont.mono(11, weight: .bold))
            .tracking(1.4)
            .lineLimit(1)

            if let notice {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(notice)
                        .font(CarbonFont.mono(10.5, weight: .semibold))
                        .foregroundStyle(theme.orange)
                        .lineLimit(4)
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                    Button { self.notice = nil } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.white.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                    .help("Dismiss")
                }
                .frame(maxWidth: 640)
            }

            if showingCredit, let line = creditLine {
                Text(line)
                    .font(CarbonFont.mono(10.5))
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 640)
                    .textSelection(.enabled)
            }

            if let found = profile?.photoCandidates, !found.isEmpty {
                HStack(spacing: 8) {
                    Text("FOUND")
                        .font(CarbonFont.mono(9, weight: .bold))
                        .tracking(1.6)
                        .foregroundStyle(.white.opacity(0.5))
                    ForEach(found.prefix(8), id: \.self) { candidate in
                        ArtistCandidateTile(name: name, candidate: candidate, model: model)
                    }
                }
                .padding(.top, 2)
            }

            HStack(spacing: 6) {
                ArtworkBar.pill(label: "BACK", icon: "chevron.left") { step(-1) }
                    .disabled(photos.count <= 1)
                    .opacity(photos.count <= 1 ? 0.35 : 1)
                Text(photos.isEmpty ? "0 / 0" : "\(index + 1) / \(photos.count)")
                    .font(CarbonFont.mono(9.5, weight: .bold))
                    .tracking(1.2)
                    .foregroundStyle(.white.opacity(0.55))
                    .frame(minWidth: 52)
                    .frame(height: Self.barHeight)
                    .modifier(BarSurface(cornerRadius: Self.barHeight / 2))
                ArtworkBar.pill(label: "FWD", icon: "chevron.right") { step(1) }
                    .disabled(photos.count <= 1)
                    .opacity(photos.count <= 1 ? 0.35 : 1)

                ArtworkBar.divider

                ArtworkBar.zoomMenu(zoom) { zoom = $0; pan = ArtworkPan() }
                ArtworkBar.dimControl($backdropDim)

                ArtworkBar.divider

                // What to do with this photo
                // On the default itself this is a readout, not a dead key.
                if isDefault {
                    Text("DEFAULT")
                        .font(CarbonFont.mono(9.5, weight: .bold))
                        .tracking(1.5)
                        .foregroundStyle(theme.orange)
                        .padding(.horizontal, 18)
                        .frame(height: Self.barHeight)
                        .modifier(BarSurface(cornerRadius: Self.barHeight / 2))
                        .help("The photo the artist page shows and the iPod gets")
                } else {
                    ArtworkBar.pill(label: "MAKE DEFAULT") {
                        if let photo = current { model.setDefaultArtistPhoto(name, hash: photo.hash) }
                    }
                    .disabled(current == nil)
                    .opacity(current == nil ? 0.35 : 1)
                    .help("Make this the photo the artist page shows and the iPod gets")
                }
                ArtworkBar.icon("plus", size: Self.barHeight) { choosePhotos() }
                    .help("Add photos of \(name)")
                ArtworkBar.icon("trash", size: Self.barHeight) { confirmingRemove = true }
                    .disabled(current == nil)
                    .opacity(current == nil ? 0.35 : 1)
                    .help("Remove this photo")
                ArtworkBar.icon(showingCredit ? "info.circle.fill" : "info.circle", size: Self.barHeight) {
                    showingCredit.toggle()
                }
                .disabled(current == nil)
                .opacity(current == nil ? 0.35 : 1)
                .help(showingCredit ? "Hide where this photo came from" : "Show where this photo came from")

                ArtworkBar.divider

                ArtworkBar.pill(label: "CLOSE") { onClose() }
            }
            .padding(.top, 4)
        }
        .confirmationDialog("Remove this photo of \(name)?", isPresented: $confirmingRemove,
                            titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                if let photo = current { model.removeArtistPhoto(name, hash: photo.hash) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(current?.source == .owner
                 ? "Your file is left where it was; only CrateDigger's copy goes."
                 : "A looked-up photo you remove is never added back by a lookup.")
        }
    }

    /// "FROM DEEZER · 1600 × 1600".
    private var caption: String {
        guard let photo = current else { return "NO PHOTOS" }
        return "FROM \(ArtistPhotoCredit.sourceName(photo.source).uppercased()) · \(photo.pixelWidth) × \(photo.pixelHeight)"
    }

    /// Show Credit: the source, and for a Commons photo its file, licence and
    /// author.
    private var creditLine: String? {
        guard let photo = current else { return nil }
        let added = "added " + photo.added.formatted(date: .abbreviated, time: .omitted)
        if let credit = photo.credit {
            return "\(ArtistPhotoCredit.sourceName(photo.source)): \(ArtistPhotoCredit.line(credit)), \(added)"
        }
        return "\(ArtistPhotoCredit.sourceName(photo.source).prefix(1).uppercased())"
            + "\(ArtistPhotoCredit.sourceName(photo.source).dropFirst()), \(added)"
    }

    // MARK: - Behaviour

    /// The alerts the artist photo actions raise, caught while the viewer is
    /// up and shown in it instead.
    private static let photoAlertTitles: Set<String> = [
        "Photos Not Added", "Some Photos Not Added", "Photo Not Added", "Artist Not Saved",
    ]

    /// Add Photos…: the picker runs modal, so the gate is open exactly as
    /// long as it is on screen.
    private func choosePhotos() {
        guard libraryIsWritable() else { return }
        notice = nil
        modal.isOpen = true
        model.chooseArtistPhotos(name)
        modal.isOpen = false
    }

    /// Says so here, where it can be seen, when the library's drive is
    /// out; the view model refuses as well.
    private func libraryIsWritable() -> Bool {
        if case .disconnected(let volume, _) = model.libraryLocation {
            notice = "\(volume ?? "The library's drive") is disconnected, so photos cannot be added. "
                + "Connect it and try again."
            return false
        }
        notice = nil
        return true
    }

    private func step(_ delta: Int) {
        guard !photos.isEmpty else { return }
        index = (index + delta + photos.count) % photos.count
    }

    /// The current photo and its neighbours, and nothing else, decoded off
    /// the main actor to at most twice the screen's backing size: enough for
    /// 200%, never a 50 MP original held for the session.
    private func loadAround() async {
        guard !photos.isEmpty else {
            images = [:]
            return
        }
        let order = [index, index + 1, index - 1]
            .map { (($0 % photos.count) + photos.count) % photos.count }
        var wanted: [String] = []
        for position in order where !wanted.contains(photos[position].hash) { wanted.append(photos[position].hash) }
        images = images.filter { wanted.contains($0.key) }
        let side = ArtistPhotoDecode.side(for: NSScreen.main)
        let store = await model.currentArtistProfileStore()
        for hash in wanted where images[hash] == nil && !unreachable.contains(hash) {
            let decoded = await Task.detached(priority: .userInitiated) {
                UncheckedSendableBox(ArtistPhotoDecode.image(store.photoData(hash: hash), maxPixel: side))
            }.value.value
            guard !Task.isCancelled else { return }
            if let decoded { images[hash] = decoded } else { unreachable.insert(hash) }
        }
    }
}

/// Open while a modal the viewer started is on screen. A class, so the key
/// monitor's closure reads the live value while `runModal` blocks.
private final class ModalGate {
    var isOpen = false
}

/// The viewer's decode: ImageIO's downscaled decode with orientation, done
/// once, off the main actor.
enum ArtistPhotoDecode {
    /// About twice the screen's longest side in pixels.
    static func side(for screen: NSScreen?) -> Int {
        let frame = screen?.frame.size ?? CGSize(width: 1_920, height: 1_080)
        let scale = screen?.backingScaleFactor ?? 2
        return Int(max(frame.width, frame.height) * scale * 2)
    }

    static func image(_ data: Data?, maxPixel: Int) -> NSImage? {
        guard let data, let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        // A bitmap rep, as `NSImage(contentsOf:)` gives the album viewer, so
        // its pixel count is the decoded one and 100% means what it says.
        let rep = NSBitmapImageRep(cgImage: cg)
        let image = NSImage(size: NSSize(width: cg.width, height: cg.height))
        image.addRepresentation(rep)
        return image
    }
}
