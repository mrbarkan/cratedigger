import Foundation

public enum AlbumBookletSource: Codable, Hashable, Sendable {
    case pdf(URL)
    case images([URL])
}

public struct AlbumBooklet: Codable, Hashable, Sendable {
    public let source: AlbumBookletSource

    public init(source: AlbumBookletSource) {
        self.source = source
    }

    public var frontCoverURL: URL? {
        switch source {
        case .pdf:
            return nil
        case .images(let urls):
            return urls.first
        }
    }

    /// Scans the given album folder for any booklet PDF files or folders containing booklet images.
    public static func scan(in albumFolder: URL, fileManager: FileManager = .default, manifest: ArtworkManifest? = nil) -> AlbumBooklet? {
        // 1. Look for PDF files directly in the album folder
        if let contents = try? fileManager.contentsOfDirectory(at: albumFolder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            let pdfs = contents.filter { $0.pathExtension.lowercased() == "pdf" }
            // Sort to prefer names containing 'booklet', 'liner', 'notes', etc.
            let sortedPdfs = pdfs.sorted { lhs, rhs in
                let lName = lhs.lastPathComponent.lowercased()
                let rName = rhs.lastPathComponent.lowercased()
                let lHasKeywords = lName.contains("booklet") || lName.contains("liner") || lName.contains("notes")
                let rHasKeywords = rName.contains("booklet") || rName.contains("liner") || rName.contains("notes")
                if lHasKeywords != rHasKeywords {
                    return lHasKeywords && !rHasKeywords
                }
                return lName.localizedStandardCompare(rName) == .orderedAscending
            }
            if let firstPdf = sortedPdfs.first {
                return AlbumBooklet(source: .pdf(firstPdf))
            }
        }

        // 2. Look for images in candidate directories and the root directory
        let candidateDirNames = [
            "", "artwork", "Artwork", "scans", "Scans", "booklet", "Booklet",
            "covers", "Covers", "liner notes", "Liner Notes", "LinerNotes"
        ]

        var collectedImages: [URL] = []

        for dirName in candidateDirNames {
            let subfolderURL = dirName.isEmpty ? albumFolder : albumFolder.appendingPathComponent(dirName)
            var isDir: ObjCBool = false
            if fileManager.fileExists(atPath: subfolderURL.path, isDirectory: &isDir), isDir.boolValue {
                if let contents = try? fileManager.contentsOfDirectory(at: subfolderURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                    // Check for PDF inside the subfolder first
                    if !dirName.isEmpty {
                        let pdfs = contents.filter { $0.pathExtension.lowercased() == "pdf" }
                        if let firstPdf = pdfs.first {
                            return AlbumBooklet(source: .pdf(firstPdf))
                        }
                    }

                    // Look for image pages
                    let imageExtensions = ["jpg", "jpeg", "png", "tiff", "webp", "gif"]
                    let images = contents.filter { imageExtensions.contains($0.pathExtension.lowercased()) }
                    
                    // If we are in the root directory, ONLY collect images if they are explicitly in the manifest
                    // OR if they look like a booklet page and we have no subfolder. 
                    if dirName.isEmpty {
                        if let manifest = manifest {
                            let mapped = images.filter { manifest.roles[$0.lastPathComponent] != nil && manifest.roles[$0.lastPathComponent] != .ignore && manifest.roles[$0.lastPathComponent] != .disc }
                            collectedImages.append(contentsOf: mapped)
                        }
                    } else {
                        collectedImages.append(contentsOf: images)
                    }
                }
            }
        }

        if !collectedImages.isEmpty {
            // Deduplicate
            let uniqueImages = Array(Set(collectedImages))
            let sortedImages = sortAndCategorizeBookletImages(uniqueImages, manifest: manifest)
            if !sortedImages.isEmpty {
                return AlbumBooklet(source: .images(sortedImages))
            }
        }

        return nil
    }

    /// Categorizes and sorts booklet image URLs based on their filenames to align with standard physical packaging order:
    /// Front Cover -> Booklet Pages -> Generic -> Inlay/Inlet -> Back Cover
    /// Note: Excludes CD/disc label artwork scans.
    public static func sortAndCategorizeBookletImages(_ urls: [URL], manifest: ArtworkManifest? = nil) -> [URL] {
        var front: [URL] = []
        var booklet: [URL] = []
        var inlay: [URL] = []
        var back: [URL] = []
        var generic: [URL] = []

        for url in urls {
            let name = url.lastPathComponent
            let nameLower = name.lowercased()

            if let manifest = manifest, let role = manifest.roles[name], role != .auto {
                switch role {
                case .cover, .altCover: front.append(url)
                case .bookletPage: booklet.append(url)
                case .inlay: inlay.append(url)
                case .back: back.append(url)
                case .disc, .ignore: continue
                case .auto: break
                }
                continue
            }

            // Filter out CD / Disc label scans entirely from the booklet view
            if nameLower.contains("cd") || nameLower.contains("disc") || nameLower.contains("disk") || nameLower.contains("label") || nameLower.contains("media") || nameLower.contains("vinyl") || nameLower.contains("dvd") {
                continue
            }

            if nameLower.contains("front") || nameLower.contains("cover") || nameLower == "folder" || nameLower == "external" {
                front.append(url)
            } else if nameLower.contains("back") || nameLower.contains("rear") || nameLower == "backcover" {
                back.append(url)
            } else if nameLower.contains("inlay") || nameLower.contains("inlet") || nameLower.contains("tray") || nameLower.contains("insert") || nameLower.contains("inside") {
                inlay.append(url)
            } else if nameLower.contains("booklet") || nameLower.contains("book") || nameLower.contains("page") || nameLower.contains("liner") || nameLower.contains("notes") || nameLower.contains("brochure") || nameLower.contains("scan") {
                booklet.append(url)
            } else {
                generic.append(url)
            }
        }

        let sortByFilename: (URL, URL) -> Bool = { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        front.sort(by: sortByFilename)
        booklet.sort(by: sortByFilename)
        inlay.sort(by: sortByFilename)
        back.sort(by: sortByFilename)
        generic.sort(by: sortByFilename)

        return front + booklet + generic + inlay + back
    }
}
