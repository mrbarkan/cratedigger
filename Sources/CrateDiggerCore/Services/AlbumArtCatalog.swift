import Foundation

/// One page in the album artwork navigator. A page is usually one image file, but
/// a `.tray` page composites a disc image over an inlay/tray-card image (the
/// "CD in its case" look), and a synthetic `.cover` page can have no file at all
/// (the viewer then renders the album's embedded artwork).
public struct ArtworkPage: Hashable, Sendable {
    public enum Kind: String, Sendable, Codable {
        case cover, bookletPage, inlay, tray, disc, back
    }

    public let kind: Kind
    public let label: String
    /// Primary image file. `nil` for a synthetic cover backed by embedded artwork.
    public let imageURL: URL?
    /// For `.tray`: the disc image composited over `imageURL` (the inlay/tray card).
    public let overlayURL: URL?

    public init(kind: Kind, label: String, imageURL: URL?, overlayURL: URL? = nil) {
        self.kind = kind
        self.label = label
        self.imageURL = imageURL
        self.overlayURL = overlayURL
    }
}

/// Turns an album folder's loose image files (+ its `ArtworkManifest` roles) into
/// an ordered list of navigator pages: Cover → Booklet 1..n → Inlay → Tray → Disc
/// → Back. The `pages(imageURLs:manifest:)` classification is pure so it's
/// unit-tested; the filesystem scan is a thin convenience over it.
public enum AlbumArtCatalog {
    private static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "tiff", "webp", "gif", "bmp"]

    public static func pages(imageURLs: [URL], manifest: ArtworkManifest?) -> [ArtworkPage] {
        var covers: [URL] = [], altCovers: [URL] = [], bookletPages: [URL] = [], inlays: [URL] = [], discs: [URL] = [], backs: [URL] = []

        for url in imageURLs {
            switch classify(url, manifest: manifest) {
            case .cover: covers.append(url)
            case .altCover: altCovers.append(url)
            case .bookletPage: bookletPages.append(url)
            case .inlay: inlays.append(url)
            case .disc: discs.append(url)
            case .back: backs.append(url)
            case .ignore: continue
            }
        }

        let byName: (URL, URL) -> Bool = {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
        covers.sort(by: byName); altCovers.sort(by: byName); bookletPages.sort(by: byName)
        inlays.sort(by: byName); discs.sort(by: byName); backs.sort(by: byName)
        // Alt covers are front pages too, but always AFTER the main cover —
        // "cover_alt.jpg" would otherwise filename-sort ahead of "cover.jpg".
        covers += altCovers

        var pages: [ArtworkPage] = []

        for (i, url) in covers.enumerated() {
            pages.append(ArtworkPage(kind: .cover, label: label("Cover", i, covers.count), imageURL: url))
        }
        for (i, url) in bookletPages.enumerated() {
            pages.append(ArtworkPage(kind: .bookletPage, label: "Booklet \(i + 1)", imageURL: url))
        }
        for (i, url) in inlays.enumerated() {
            pages.append(ArtworkPage(kind: .inlay, label: label("Inlay", i, inlays.count), imageURL: url))
        }
        // "CD box" tray page: the disc seated on the inlay/tray card. Only when
        // both parts exist.
        if let inlay = inlays.first, let disc = discs.first {
            pages.append(ArtworkPage(kind: .tray, label: "Tray", imageURL: inlay, overlayURL: disc))
        }
        for (i, url) in discs.enumerated() {
            let side = manifest?.discSides?[url.lastPathComponent]
            let label = side.map { "Disc (\($0))" } ?? label("Disc", i, discs.count)
            pages.append(ArtworkPage(kind: .disc, label: label, imageURL: url))
        }
        for (i, url) in backs.enumerated() {
            pages.append(ArtworkPage(kind: .back, label: label("Back", i, backs.count), imageURL: url))
        }
        return pages
    }

    /// Scan an album folder and build its pages (loads the folder's manifest too).
    public static func pages(in albumFolder: URL, fileManager: FileManager = .default) -> [ArtworkPage] {
        pages(
            imageURLs: gatherImageURLs(in: albumFolder, fileManager: fileManager),
            manifest: ArtworkManifest.load(from: albumFolder)
        )
    }

    public static func gatherImageURLs(in albumFolder: URL, fileManager: FileManager = .default) -> [URL] {
        let candidateDirNames = [
            "", "artwork", "Artwork", "Art", "art", "scans", "Scans",
            "booklet", "Booklet", "covers", "Covers", "liner notes", "Liner Notes", "LinerNotes"
        ]
        var found: Set<URL> = []
        for dirName in candidateDirNames {
            let dir = dirName.isEmpty ? albumFolder : albumFolder.appendingPathComponent(dirName)
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue,
                  let contents = try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            else { continue }
            for file in contents where imageExtensions.contains(file.pathExtension.lowercased()) {
                found.insert(file)
            }
        }
        return Array(found)
    }

    private static func label(_ base: String, _ index: Int, _ count: Int) -> String {
        count > 1 ? "\(base) \(index + 1)" : base
    }

    private enum Bucket { case cover, altCover, bookletPage, inlay, disc, back, ignore }

    /// Manifest role wins; otherwise fall back to the same filename heuristics the
    /// booklet sorter uses. Order matters: inlay/back are checked before the more
    /// generic "cover"/"disc" keywords so "back cover" and "inside cover" land
    /// correctly.
    private static func classify(_ url: URL, manifest: ArtworkManifest?) -> Bucket {
        let name = url.lastPathComponent
        if let role = manifest?.roles[name], role != .auto {
            switch role {
            case .cover: return .cover
            case .altCover: return .altCover
            case .back: return .back
            case .disc: return .disc
            case .inlay: return .inlay
            case .bookletPage: return .bookletPage
            case .ignore: return .ignore
            case .auto: break
            }
        }

        let n = name.lowercased()
        if n.contains("inlay") || n.contains("inlet") || n.contains("tray") || n.contains("insert") || n.contains("inside") {
            return .inlay
        }
        if n.contains("back") || n.contains("rear") { return .back }
        if n.contains("cd") || n.contains("disc") || n.contains("disk") || n.contains("label") || n.contains("media") || n.contains("vinyl") || n.contains("dvd") {
            return .disc
        }
        if n.contains("front") || n.contains("cover") || n == "folder" || n == "external" { return .cover }
        return .bookletPage
    }
}
