import Combine
import SwiftUI
import CrateDiggerCore

struct CDMaskShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addEllipse(in: rect)
        
        let holeSize = rect.width * 0.125
        let holeRect = CGRect(
            x: rect.midX - holeSize / 2,
            y: rect.midY - holeSize / 2,
            width: holeSize,
            height: holeSize
        )
        path.addEllipse(in: holeRect)
        return path
    }
}

struct SpinningRecordView: View {
    @ObservedObject var model: LibraryViewModel
    /// Tray semantics: this view is the deck's transport, so it always shows
    /// the *loaded* disc (the now-playing queue's album — which persists
    /// through pause/stop, like a real tray) and never the browsed selection.
    /// Previewing a browsed album's disc art belongs to the ART tab / artwork
    /// viewer. An earlier follows-selection mode spun the browsed album's art
    /// while something else was playing, which read as the wrong album playing.
    @StateObject private var animator = RecordAnimator()
    @State private var discImage: NSImage? = nil
    @State private var isVinyl: Bool = false
    /// No track loaded in the queue at all — render the empty tray instead of
    /// a blank disc, so "nothing playing" doesn't look like a blank CD-R.
    @State private var trayEmpty = true
    /// Vinyl side (A, B, …) of the current track, shown statically on the record.
    @State private var currentSide: String? = nil

    // Pre-rendered CD faces. The 60fps animation only rotates/crossfades these
    // cached bitmaps; the expensive gradients + motion smear are rasterized
    // once (here), not rebuilt every frame. Rebuilt only when the disc art
    // changes (tracked via `faceToken`), at a fixed canvas size so window
    // resizes never trigger a re-render.
    @State private var sharpFace: NSImage? = nil
    @State private var blurredFace: NSImage? = nil
    @State private var faceToken: Int = 0
    private let faceRenderSize: CGFloat = 480

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            
            ZStack {
                if trayEmpty {
                    emptyTrayLayer
                } else if isVinyl {
                    vinylRecordLayer
                } else {
                    // CD Layer
                    ZStack {
                        // 1. Rotating CD Face — cached bitmaps. Per frame this is
                        // just a textured quad being rotated + an opacity
                        // crossfade, so it can hold 60fps without pegging the CPU.
                        ZStack {
                            cdFaceImage(sharpFace, size: size)

                            // Motion blur: a pre-smeared copy faded in by speed.
                            // No per-frame blur or offscreen rasterization.
                            if animator.currentSpeed > 0 {
                                cdFaceImage(blurredFace, size: size)
                                    .opacity(blurOpacity(for: animator.currentSpeed))
                            }
                        }
                        .rotationEffect(.degrees(animator.rotationAngle))
                        .animation(nil, value: animator.rotationAngle)

                        // 2. Static Overlays
                        if discImage == nil {
                            cdGroovesOverlay
                        }

                        Circle().stroke(Color.white.opacity(0.25), lineWidth: 1.5)

                        plasticCenterHub
                    }
                    .onAppear { renderCDFaces() }
                    .onChange(of: faceToken) { _ in renderCDFaces() }
                }
            }
            .frame(width: size, height: size)
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
            .clipShape(Circle())
            .mask(
                Group {
                    if isVinyl || trayEmpty {
                        Circle()
                    } else {
                        CDMaskShape().fill(style: FillStyle(eoFill: true))
                    }
                }
            )
        }
        .aspectRatio(1, contentMode: .fit)
        .onAppear {
            updateDiscData()
            animator.start(model: model)
        }
        .onDisappear {
            animator.stop()
        }
        // Tray semantics: only a queue change swaps the disc — browsing
        // (selection changes) never touches the tray, which also stops the
        // per-selection manifest re-reads this view used to do.
        .onChange(of: model.nowPlayingTrack) { _ in
            updateDiscData()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("CrateDiggerArtworkImported"))) { _ in
            updateDiscData()
        }
    }

    /// Nothing loaded in the queue yet — a dark, open tray instead of a disc.
    private var emptyTrayLayer: some View {
        ZStack {
            Circle()
                .fill(Color.primary.opacity(0.04))
            Circle()
                .stroke(Color.primary.opacity(0.12), lineWidth: 1.5)
            Circle()
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
                .scaleEffect(0.72)
            Text("NO DISC")
                .font(CarbonFont.mono(10, weight: .bold))
                .tracking(2.5)
                .foregroundStyle(Color.primary.opacity(0.35))
        }
    }

    // MARK: - Cached CD face rendering

    /// Display a cached face bitmap, falling back to a live (sharp, unblurred)
    /// render for the brief moment before the cache is populated so the disc
    /// never flashes blank.
    @ViewBuilder
    private func cdFaceImage(_ image: NSImage?, size: CGFloat) -> some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .frame(width: size, height: size)
        } else {
            cdFaceContent(size: size)
        }
    }

    /// The sharp CD face: artwork + diffraction sheen.
    private func cdFaceContent(size: CGFloat) -> some View {
        ZStack {
            if let cdImg = discImage {
                Image(nsImage: cdImg).resizable().aspectRatio(contentMode: .fill)
            } else {
                blankCDFace
            }
            rainbowDiffractionSheen
        }
        .frame(width: size, height: size)
        .clipped()
    }

    /// Rasterize the sharp + smeared faces once into bitmaps. Cheap to do on a
    /// track/art change; rotating the results every frame is then nearly free.
    ///
    /// The "blurred" face is a *rotational* motion smear, not a Gaussian blur:
    /// the sharp face averaged across `smearArcDegrees` of rotation (the
    /// standard onion-skin trick — copy i drawn at alpha 1/(i+1) accumulates a
    /// uniform average). Streaks follow the spin direction, the hub stays
    /// naturally sharp, and the rim smears hardest — like a long-exposure
    /// photo of a spinning disc, not an out-of-focus one.
    @MainActor
    private func renderCDFaces() {
        let scale = NSScreen.main?.backingScaleFactor ?? 2

        let sharp = ImageRenderer(content: cdFaceContent(size: faceRenderSize))
        sharp.scale = scale
        sharpFace = sharp.nsImage

        guard let sharpFace else {
            blurredFace = nil
            return
        }

        // ponytail: fixed arc tuned for the "fast" preset; per-speed smear
        // faces if the medium/slow presets ever look over-smeared.
        let copies = 24
        let smearArcDegrees = 18.0
        let smear = ImageRenderer(content:
            ZStack {
                ForEach(0..<copies, id: \.self) { i in
                    Image(nsImage: sharpFace)
                        .resizable()
                        .frame(width: faceRenderSize, height: faceRenderSize)
                        .rotationEffect(.degrees(smearArcDegrees * (Double(i) / Double(copies - 1) - 0.5)))
                        .opacity(1.0 / Double(i + 1))
                }
            }
            .frame(width: faceRenderSize, height: faceRenderSize)
            // Just enough to melt the discrete copies into a continuous streak.
            .blur(radius: 1.2)
            .clipped()
        )
        smear.scale = scale
        blurredFace = smear.nsImage
    }

    /// How present the pre-blurred face is, as a function of spin speed. Fully
    /// faded in by roughly medium speed; absent at rest.
    private func blurOpacity(for speed: Double) -> Double {
        min(1.0, max(0.0, speed / 30.0))
    }

    @ViewBuilder
    private var vinylRecordLayer: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let labelSize = w * 0.38 // 38% for the label
            let holeSize = w * 0.025 // Small spindle hole

            ZStack {
                // Black vinyl base with grooves (static)
                Circle().fill(Color(white: 0.08))
                
                // Grooves (static)
                ForEach(0..<18) { i in
                    Circle()
                        .stroke(Color.white.opacity(0.03), lineWidth: 0.5)
                        .frame(width: w * (0.42 + Double(i) * 0.032), height: w * (0.42 + Double(i) * 0.032))
                }
                
                // Highlight sheen (static - reflections are fixed relative to light source)
                AngularGradient(
                    colors: [
                        Color.white.opacity(0.0), Color.white.opacity(0.12),
                        Color.white.opacity(0.0), Color.white.opacity(0.12),
                        Color.white.opacity(0.0)
                    ],
                    center: .center
                )
                .clipShape(Circle())
                
                // Center Label (rotating)
                ZStack {
                    if let img = discImage {
                        Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Circle().fill(Color.orange)
                    }
                }
                .frame(width: labelSize, height: labelSize)
                .clipShape(Circle())
                .rotationEffect(.degrees(animator.rotationAngle))
                .animation(nil, value: animator.rotationAngle)
                
                // Small center hole (static)
                Circle().fill(Color.black).frame(width: holeSize, height: holeSize)

                // Vinyl side badge (static, near the top edge) — follows the
                // current track's `side` tag.
                if let side = currentSide, !side.isEmpty {
                    Text("SIDE \(side)")
                        .font(CarbonFont.mono(9, weight: .bold))
                        .tracking(1.5)
                        .foregroundStyle(Color.white.opacity(0.85))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.black.opacity(0.55)))
                        .overlay(Capsule().stroke(Color.white.opacity(0.2), lineWidth: 0.5))
                        .offset(y: -w * 0.34)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var blankCDFace: some View {
        AngularGradient(
            colors: [
                Color(hex: 0xE5E5E5), Color(hex: 0xC0C0C0), Color(hex: 0xF0F0F0),
                Color(hex: 0xD8D8D8), Color(hex: 0xB8B8B8), Color(hex: 0xE5E5E5)
            ],
            center: .center
        )
    }

    private var cdGroovesOverlay: some View {
        ForEach(0..<10) { i in
            Circle().stroke(Color.black.opacity(0.02), lineWidth: 1)
                .scaleEffect(CGFloat(0.35 + Double(i) * 0.06))
        }
    }

    private var rainbowDiffractionSheen: some View {
        AngularGradient(
            colors: [
                Color.clear, Color.blue.opacity(0.15), Color.green.opacity(0.15),
                Color.yellow.opacity(0.15), Color.red.opacity(0.15), Color.clear,
                Color.clear, Color.blue.opacity(0.15), Color.green.opacity(0.15),
                Color.yellow.opacity(0.15), Color.red.opacity(0.15), Color.clear
            ],
            center: .center
        )
        .blendMode(.screen)
    }

    private var plasticCenterHub: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let hubSize = w * 0.28
            let holeSize = w * 0.125
            
            ZStack {
                Circle().fill(Color.white.opacity(0.12))
                    .frame(width: hubSize, height: hubSize)
                    .overlay(Circle().stroke(Color.white.opacity(0.2), lineWidth: 1.5))
                Circle().stroke(Color.white.opacity(0.25), lineWidth: 1).frame(width: w * 0.22, height: w * 0.22)
                Circle().stroke(Color.white.opacity(0.3), lineWidth: 0.8).frame(width: w * 0.16, height: w * 0.16)
                Circle().stroke(Color.white.opacity(0.4), lineWidth: 1.5).frame(width: holeSize, height: holeSize)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }

    private var nowPlayingAlbum: Album? {
        guard let track = model.nowPlayingTrack else { return nil }
        return model.album(containing: track.track.id)
    }

    /// The disc-label image to show, in priority order: the one tagged with the
    /// current track's CD number (multi-disc sets, via `discNumbers`), then its
    /// vinyl side (via `discSides`), else any disc-roled image.
    private func discImageFilename(in manifest: ArtworkManifest, forSide side: String?, forDisc disc: Int?) -> String? {
        let discFiles = manifest.roles.compactMap { $0.value == .disc ? $0.key : nil }
        if let disc, let match = discFiles.first(where: { manifest.discNumbers?[$0] == disc }) {
            return match
        }
        if let side = side?.uppercased(), !side.isEmpty,
           let match = discFiles.first(where: { manifest.discSides?[$0]?.uppercased() == side }) {
            return match
        }
        return discFiles.first
    }

    private func updateDiscData() {
        defer {
            animator.isVinyl = self.isVinyl
            // Invalidate the cached CD faces so they re-render for the new art.
            faceToken &+= 1
        }
        // Tray semantics: only the loaded (now-playing queue) disc, never the
        // browsed selection. The queue survives pause/stop, like a real tray.
        let loaded = model.nowPlayingTrack
        trayEmpty = loaded == nil
        currentSide = loaded?.metadata.side
        guard let track = loaded?.track else {
            discImage = nil
            isVinyl = false
            return
        }
        
        let fileManager = FileManager.default
        let folder = track.fileURL.deletingLastPathComponent()
        
        // 1. Check for ArtworkManifest
        let manifest = ArtworkManifest.load(from: folder)
        self.isVinyl = manifest?.mediaFormat == .vinyl
        
        if let manifest = manifest, let discFileName = discImageFilename(in: manifest, forSide: currentSide, forDisc: track.discNumber) {
            let candidateSubfolders = ["", "artwork", "Artwork", "scans", "Scans", "covers", "Covers"]
            for sub in candidateSubfolders {
                let base = sub.isEmpty ? folder : folder.appendingPathComponent(sub)
                let url = base.appendingPathComponent(discFileName)
                if let image = NSImage(contentsOf: url) {
                    self.discImage = image
                    return
                }
            }
        }
        
        // 2. Fallback to disc/vinyl filenames
        let candidates = [
            "cd.jpg", "cd.jpeg", "cd.png", "CD.jpg", "CD.jpeg", "CD.png", "CD.PNG",
            "vinyl.jpg", "vinyl.jpeg", "vinyl.png", "VINYL.jpg", "disc.jpg", "disc.png"
        ]
        
        let subfolders = ["", "Artwork", "artwork", "Art", "art", "Covers", "covers"]
        
        for subfolder in subfolders {
            let baseFolder = subfolder.isEmpty ? folder : folder.appendingPathComponent(subfolder)
            for candidate in candidates {
                let url = baseFolder.appendingPathComponent(candidate)
                // Note: a "vinyl.jpg" here is only a *label image* — the medium
                // itself is decided solely by the manifest's media format
                // (Art tab dropdown). Auto/unset always reads as CD.
                if fileManager.fileExists(atPath: url.path), let image = NSImage(contentsOf: url) {
                    self.discImage = image
                    return
                }
            }
        }
        
        // 3. Fallback to cover art URL if available
        if let album = nowPlayingAlbum, let coverURL = album.booklet?.frontCoverURL {
            if let image = NSImage(contentsOf: coverURL) {
                self.discImage = image
                return
            }
        }

        // 4. Fallback to embedded cover art
        if let hash = track.artworkHash,
           let image = model.artworkService.generateThumbnail(artworkHash: hash, size: CGSize(width: 480, height: 480)) {
            self.discImage = image
            return
        }
        
        self.discImage = nil
    }
}

// MARK: - RecordAnimator

@MainActor
final class RecordAnimator: ObservableObject {
    @Published var rotationAngle: Double = 0.0
    @Published var currentSpeed: Double = 0.0
    
    var isVinyl: Bool = false
    
    private weak var model: LibraryViewModel?
    private var timer: Timer?
    private var lastUpdateTime: Date?
    private var playbackStateSub: AnyCancellable?

    func start(model: LibraryViewModel) {
        self.model = model

        stop()
        ensureTimer()
        // The tick self-halts once the disc settles at rest (no point waking
        // the run loop 60×/s to compute a zero delta while paused) — this
        // restarts it when playback resumes. Same pattern as MeterDriver.
        playbackStateSub = model.$playbackState.sink { [weak self] state in
            MainActor.assumeIsolated {
                if state == .playing { self?.ensureTimer() }
            }
        }
    }

    func stop() {
        playbackStateSub = nil
        haltTimer()
    }

    private func ensureTimer() {
        guard timer == nil else { return }
        lastUpdateTime = Date()
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
        self.timer = t
        RunLoop.main.add(t, forMode: .common)
    }

    private func haltTimer() {
        timer?.invalidate()
        timer = nil
        lastUpdateTime = nil
    }

    private func tick() {
        guard let model = model else { return }
        
        let now = Date()
        let rawDt = lastUpdateTime.map { now.timeIntervalSince($0) } ?? 0.016
        // Cap catch-up to ~3 frames. A larger clamp lets a single hitch advance
        // the disc far enough to alias into apparent reverse spin.
        let dt = min(0.05, rawDt)
        lastUpdateTime = now
        
        let targetSpeed: Double
        if model.playbackState == .playing {
            if isVinyl {
                targetSpeed = 1.2
            } else {
                targetSpeed = model.cdAnimationSpeed.angleIncrement
            }
        } else {
            targetSpeed = 0.0
        }
        
        let factor = dt / 0.016
        
        if currentSpeed < targetSpeed {
            currentSpeed += (targetSpeed - currentSpeed) * min(1.0, factor * 0.25)
            if abs(targetSpeed - currentSpeed) < 0.05 { currentSpeed = targetSpeed }
        } else if currentSpeed > targetSpeed {
            currentSpeed += (targetSpeed - currentSpeed) * min(1.0, factor * 0.035)
            if abs(currentSpeed - targetSpeed) < 0.05 { currentSpeed = targetSpeed }
        }
        
        if currentSpeed > 0 {
            // Hard-cap the per-rendered-frame advance well under 180° so a
            // dropped frame can never read as backwards rotation (wagon-wheel
            // effect). Better to briefly spin a touch slow than to reverse.
            let delta = min(currentSpeed * factor, 120.0)
            rotationAngle += delta
            if rotationAngle >= 360 {
                rotationAngle = rotationAngle.truncatingRemainder(dividingBy: 360)
            }
        } else if targetSpeed == 0 {
            // Fully settled at rest — stop ticking. The playback-state
            // subscription in start() restarts the timer on the next play.
            haltTimer()
        }
    }
}
