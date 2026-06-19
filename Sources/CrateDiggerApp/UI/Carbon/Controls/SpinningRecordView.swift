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
    @StateObject private var animator = RecordAnimator()
    @State private var discImage: NSImage? = nil
    @State private var isVinyl: Bool = false

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            
            ZStack {
                if isVinyl {
                    vinylRecordLayer
                } else {
                    // CD Layer
                    ZStack {
                        // 1. Rotating CD Face
                        ZStack {
                            // Base Layer
                            ZStack {
                                if let cdImg = discImage {
                                    Image(nsImage: cdImg).resizable().aspectRatio(contentMode: .fill)
                                } else {
                                    blankCDFace
                                }
                                rainbowDiffractionSheen
                            }
                            
                            // Blur Layer (only when spinning)
                            if animator.currentSpeed > 0 {
                                ZStack {
                                    if let cdImg = discImage {
                                        Image(nsImage: cdImg).resizable().aspectRatio(contentMode: .fill)
                                    } else {
                                        blankCDFace
                                    }
                                    rainbowDiffractionSheen
                                }
                                .blur(radius: animator.currentSpeed * 0.08)
                                .mask(
                                    RadialGradient(
                                        gradient: Gradient(colors: [.clear, .white]),
                                        center: .center,
                                        startRadius: size * 0.08,
                                        endRadius: size * 0.45
                                    )
                                )
                            }
                        }
                        .drawingGroup() // GPU-accelerated blur on the rotating face only
                        .rotationEffect(.degrees(-animator.rotationAngle))
                        .animation(nil, value: animator.rotationAngle)
                        
                        // 2. Static Overlays
                        if discImage == nil {
                            cdGroovesOverlay
                        }
                        
                        Circle().stroke(Color.white.opacity(0.25), lineWidth: 1.5)
                        
                        plasticCenterHub
                    }
                }
            }
            .frame(width: size, height: size)
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
            .clipShape(Circle())
            .mask(
                Group {
                    if isVinyl {
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
        .onChange(of: model.nowPlayingTrack) { _ in
            updateDiscData()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("CrateDiggerArtworkImported"))) { _ in
            updateDiscData()
        }
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
                .rotationEffect(.degrees(-animator.rotationAngle))
                .animation(nil, value: animator.rotationAngle)
                
                // Small center hole (static)
                Circle().fill(Color.black).frame(width: holeSize, height: holeSize)
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
        for artist in model.index.artists {
            for album in artist.albums {
                if album.tracks.contains(where: { $0.id == track.id }) {
                    return album
                }
            }
        }
        return nil
    }

    private func updateDiscData() {
        defer {
            animator.isVinyl = self.isVinyl
        }
        guard let track = model.nowPlayingTrack?.track else {
            discImage = nil
            isVinyl = false
            return
        }
        
        let fileManager = FileManager.default
        let folder = track.fileURL.deletingLastPathComponent()
        
        // 1. Check for ArtworkManifest
        let manifest = ArtworkManifest.load(from: folder)
        self.isVinyl = manifest?.mediaFormat == .vinyl
        
        if let manifest = manifest, let discFileName = manifest.roles.first(where: { $0.value == .disc })?.key {
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
                if fileManager.fileExists(atPath: url.path), let image = NSImage(contentsOf: url) {
                    self.discImage = image
                    if candidate.lowercased().contains("vinyl") {
                        self.isVinyl = true
                    }
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
    
    func start(model: LibraryViewModel) {
        self.model = model
        
        stop()
        
        lastUpdateTime = Date()
        
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
        self.timer = t
        RunLoop.main.add(t, forMode: .common)
    }
    
    func stop() {
        timer?.invalidate()
        timer = nil
        lastUpdateTime = nil
    }
    
    private func tick() {
        guard let model = model else { return }
        
        let now = Date()
        let rawDt = lastUpdateTime.map { now.timeIntervalSince($0) } ?? 0.016
        let dt = min(0.1, rawDt)
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
            rotationAngle += currentSpeed * factor
            if rotationAngle >= 360 {
                rotationAngle = rotationAngle.truncatingRemainder(dividingBy: 360)
            }
        }
    }
}
