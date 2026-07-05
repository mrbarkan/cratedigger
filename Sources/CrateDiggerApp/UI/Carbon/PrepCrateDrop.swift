import CrateDiggerCore
import SwiftUI
import UniformTypeIdentifiers

/// Feedback for the whole-window Finder drop: while a drag hovers the window a
/// Carbon HUD names where the payload will land (the Prep Crate) — or calls
/// out payloads that contain no records at all.
enum PrepCrateDropHint: Equatable {
    case record
    case notARecord
}

struct PrepCrateDropDelegate: DropDelegate {
    @Binding var hint: PrepCrateDropHint?
    let model: LibraryViewModel

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.fileURL])
    }

    func dropEntered(info: DropInfo) {
        // Optimistic: show the Prep-Crate hint immediately, refine once the
        // pasteboard URLs have loaded (async, usually within a frame).
        setHint(.record)
        Self.loadURLs(info) { urls in
            guard !urls.isEmpty else { return }
            setHint(urls.contains(where: Self.isRecordLike) ? .record : .notARecord)
        }
    }

    func dropExited(info: DropInfo) {
        setHint(nil)
    }

    func performDrop(info: DropInfo) -> Bool {
        setHint(nil)
        Self.loadURLs(info) { urls in
            guard !urls.isEmpty else { return }
            // The scan does the real filtering (and alerts when a payload
            // yields no audio) — folders always pass through to it.
            Task { @MainActor in model.importDroppedURLs(urls) }
        }
        return true
    }

    /// Bindings may be poked from item-provider completion queues.
    private func setHint(_ value: PrepCrateDropHint?) {
        DispatchQueue.main.async { hint = value }
    }

    /// A folder can always hide records; a file counts only if the scanner
    /// would pick it up.
    static func isRecordLike(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            return true
        }
        return LibraryScanService.defaultSupportedExtensions.contains(url.pathExtension.lowercased())
    }

    private static func loadURLs(_ info: DropInfo, completion: @escaping ([URL]) -> Void) {
        let providers = info.itemProviders(for: [.fileURL])
        guard !providers.isEmpty else { return completion([]) }
        var urls: [URL] = []
        let lock = NSLock()
        let group = DispatchGroup()
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url {
                    lock.lock()
                    urls.append(url)
                    lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) { completion(urls) }
    }
}

/// The HUD itself — dimmed chassis + a dashed drop card, cyan for records
/// bound for the Prep Crate, red for payloads with nothing diggable in them.
struct PrepCrateDropOverlay: View {
    @Environment(\.carbon) private var theme
    let hint: PrepCrateDropHint?

    var body: some View {
        ZStack {
            if let hint {
                Color.black.opacity(theme.isDark ? 0.38 : 0.20)
                card(hint)
            }
        }
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.15), value: hint)
        .ignoresSafeArea()
    }

    private func card(_ hint: PrepCrateDropHint) -> some View {
        let accent = hint == .record ? theme.cyan : theme.red
        return VStack(spacing: 10) {
            Image(systemName: hint == .record ? "tray.and.arrow.down.fill" : "nosign")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(accent)
                .shadow(color: accent.opacity(0.6), radius: 10)
            Text(hint == .record ? "DROP TO ADD TO PREP CRATE" : "NOT A RECORD")
                .font(CarbonFont.mono(13, weight: .bold))
                .tracking(2.4)
                .foregroundStyle(theme.ink)
            Text(hint == .record
                 ? "Folders and audio files land in the staging crate"
                 : "Drop folders or audio files — this payload can't be dug")
                .font(CarbonFont.sans(11))
                .foregroundStyle(theme.ink3)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 22)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(theme.chassis)
                .opacity(0.96)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [7, 5]))
                .foregroundStyle(accent.opacity(0.8))
        )
        .shadow(color: .black.opacity(0.5), radius: 24, y: 10)
    }
}
