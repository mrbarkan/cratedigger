import AppKit
import CrateDiggerCore
import UniformTypeIdentifiers

/// SACD ISO → per-track DSF import ("rip as physical album"). Mirrors the CD
/// rip flow: the OLED shows rip progress, results land via loadFolders (Prep
/// Crate). sacd_extract is bring-your-own (GPL + SACD-DRM circumvention keep
/// it out of an MIT repo) — resolved like yt-dlp, never bundled.
@MainActor
extension LibraryViewModel {

    func beginSACDImport() {
        guard let tool = ExternalToolLocator().resolveOptional(.sacdExtract)?.url else {
            presentSACDExtractMissing()
            return
        }
        let panel = NSOpenPanel()
        panel.title = "Choose an SACD ISO"
        panel.allowedContentTypes = [UTType(filenameExtension: "iso") ?? .data]
        panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in
            guard response == .OK, let iso = panel.url else { return }
            Task { @MainActor in self?.importSACDISO(at: iso, toolURL: tool) }
        }
    }

    private func importSACDISO(at iso: URL, toolURL: URL) {
        guard SACDISOInspector.isSACDISO(iso) else {
            appAlert = .error(title: "Not an SACD ISO",
                              message: "“\(iso.lastPathComponent)” has no SACD table of contents. Only SACD images can be imported this way.")
            return
        }
        guard let destRoot = currentConversionDestinationURL ?? managedLibraryFolderURL else {
            appAlert = .error(title: "No Destination Set",
                              message: "Configure a default output folder in Preferences first.")
            return
        }
        let service = SACDExtractService(toolURL: toolURL)
        oledView = .cdRip
        conversionProgress = ConversionProgressSnapshot(jobsCompleted: 0, jobsTotal: 1,
                                                        currentFilename: iso.lastPathComponent,
                                                        isRunning: true)
        service.readDiscInfo(iso: iso) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .failure(let error):
                    self.finishSACDImport(alert: .error(title: "SACD Read Failed",
                                                        message: error.localizedDescription))
                case .success(let disc):
                    self.confirmAndExtract(disc: disc, iso: iso, service: service, destRoot: destRoot)
                }
            }
        }
    }

    private func confirmAndExtract(disc: SACDDiscInfo, iso: URL,
                                   service: SACDExtractService, destRoot: URL) {
        let artist = PathComponentSanitizer.sanitize(disc.albumArtist, fallback: "Unknown Artist")
        let albumPart = PathComponentSanitizer.sanitize(disc.albumTitle, fallback: "Unknown Album")
        let albumFolder = disc.year.map { "[\($0)] - \(albumPart)" } ?? albumPart
        let destination = destRoot.appendingPathComponent(artist, isDirectory: true)
            .appendingPathComponent(albumFolder, isDirectory: true)

        let alert = NSAlert()
        alert.messageText = "Rip “\(disc.albumTitle)”?"
        alert.informativeText = """
        \(disc.albumArtist) — \(disc.stereoTracks.count) stereo tracks.
        DSF files will be written to:
        \(destination.path)
        """
        alert.addButton(withTitle: "Rip")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else {
            finishSACDImport(alert: nil)
            return
        }

        conversionProgress = ConversionProgressSnapshot(jobsCompleted: 0,
                                                        jobsTotal: disc.stereoTracks.count,
                                                        currentFilename: disc.albumTitle,
                                                        isRunning: true)
        service.extractStereoTracks(
            iso: iso,
            trackNumbers: disc.stereoTracks.map(\.number),
            to: destination,
            onTrackDone: { [weak self] done, total in
                Task { @MainActor in
                    self?.conversionProgress = ConversionProgressSnapshot(
                        jobsCompleted: done, jobsTotal: total,
                        currentFilename: disc.stereoTracks.indices.contains(done)
                            ? disc.stereoTracks[done].title : nil,
                        isRunning: true)
                }
            },
            completion: { [weak self] result in
                Task { @MainActor in
                    guard let self else { return }
                    switch result {
                    case .success(let files):
                        // Scan the album folder in — lands in the Prep Crate
                        // like any dig, then files into a crate as usual.
                        self.loadFolders([destination])
                        self.finishSACDImport(alert: .info(
                            title: "SACD Ripped!",
                            message: "\(files.count) DSF tracks imported from “\(disc.albumTitle)”."))
                    case .failure(let error):
                        self.finishSACDImport(alert: .error(title: "SACD Rip Failed",
                                                            message: error.localizedDescription))
                    }
                }
            })
    }

    private func finishSACDImport(alert: AppAlert?) {
        conversionProgress = .idle
        if oledView == .cdRip { oledView = .nowPlaying }
        if let alert { appAlert = alert }
    }

    /// Bring-your-own binary, like yt-dlp — but there is no brew formula, so
    /// offer the verified source-build recipe instead.
    private func presentSACDExtractMissing() {
        let recipe = """
        git clone https://github.com/sacd-ripper/sacd-ripper.git
        cd sacd-ripper/tools/sacd_extract
        cmake -DCMAKE_POLICY_VERSION_MINIMUM=3.5 . && cmake --build .
        sudo cp sacd_extract /usr/local/bin/
        """
        let alert = NSAlert()
        alert.messageText = "sacd_extract Not Found"
        alert.informativeText = """
        Importing SACD ISOs needs the open-source sacd_extract tool, which CrateDigger can't bundle for licensing reasons.

        Build it once with the commands below (needs Xcode command-line tools + cmake), or point CRATEDIGGER_SACD_EXTRACT_PATH at an existing binary.
        """
        alert.addButton(withTitle: "Copy Build Commands")
        alert.addButton(withTitle: "OK")
        if alert.runModal() == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(recipe, forType: .string)
        }
    }
}
