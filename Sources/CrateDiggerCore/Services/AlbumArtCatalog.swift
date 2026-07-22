import Foundation

/// One page in the album artwork navigator. A page is usually one image file, but
/// a `.tray` page composites a disc image over an inlay/tray-card image (the
/// "CD in its case" look), and a synthetic `.cover` page can have no file at all
/// (the viewer then renders the album's embedded artwork).
public struct ArtworkPage: Hashable, Sendable {
    public enum Kind: String, Sendable, Codable {
        case cover, bookletPage, inlay, tray, disc, back
        /// Any of the extended package roles (spine, sleeve, sticker, matrix,
        /// obi, poster, wrapped cover) — rendered as a plain zoomable page.
        case other
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
        var byRole: [ArtworkRole: [URL]] = [:]
        for url in imageURLs {
            let role = classify(url, manifest: manifest)
            guard role != .ignore else { continue }
            byRole[role, default: []].append(url)
        }

        let byName: (URL, URL) -> Bool = {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
        for role in byRole.keys { byRole[role]?.sort(by: byName) }

        // Alt covers are front pages too, but always AFTER the main cover —
        // "cover_alt.jpg" would otherwise filename-sort ahead of "cover.jpg".
        let covers = (byRole[.cover] ?? []) + (byRole[.altCover] ?? [])
        let bookletPages = byRole[.bookletPage] ?? []
        let inlays = byRole[.inlay] ?? []
        let discs = byRole[.disc] ?? []
        let backs = byRole[.back] ?? []

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
        // The extended package roles close the sequence, in ART-grid order:
        // spine, sleeve, matrix/runout, sticker, obi, poster, wrapped cover.
        let extendedRoles: [ArtworkRole] = [.spine, .sleeve, .matrixRunout, .sticker, .obi, .poster, .wrapped]
        for role in extendedRoles {
            let urls = byRole[role] ?? []
            for (i, url) in urls.enumerated() {
                pages.append(ArtworkPage(kind: .other, label: label(role.displayName, i, urls.count), imageURL: url))
            }
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

    /// Manifest role wins; otherwise fall back to the same filename heuristics the
    /// booklet sorter uses. Order matters: the specific package parts (inlay,
    /// matrix, obi, spine…) are checked before the generic "cover"/"disc"
    /// keywords so "back cover", "matrix disc 1", and "inside cover" land
    /// correctly; "sleeve" is checked *after* front/back so "sleeve front.jpg"
    /// reads as a cover scan while a bare "inner sleeve.jpg" stays a sleeve.
    static func classify(_ url: URL, manifest: ArtworkManifest?) -> ArtworkRole {
        let name = url.lastPathComponent
        if let role = manifest?.roles[name], role != .auto {
            return role
        }

        let n = name.lowercased()
        if n.contains("inlay") || n.contains("inlet") || n.contains("tray") || n.contains("insert") || n.contains("inside") {
            return .inlay
        }
        if n.contains("matrix") || n.contains("runout") { return .matrixRunout }
        if n.contains("obi") { return .obi }
        if n.contains("spine") { return .spine }
        if n.contains("sticker") || n.contains("hype") { return .sticker }
        if n.contains("poster") { return .poster }
        if n.contains("wrap") || n.contains("shrink") || n.contains("seal") { return .wrapped }
        if n.contains("back") || n.contains("rear") { return .back }
        if n.contains("cd") || n.contains("disc") || n.contains("disk") || n.contains("label") || n.contains("media") || n.contains("vinyl") || n.contains("dvd") {
            return .disc
        }
        if n.contains("front") || n.contains("cover") || n == "folder" || n == "external" { return .cover }
        if n.contains("sleeve") { return .sleeve }
        return .bookletPage
    }
}
