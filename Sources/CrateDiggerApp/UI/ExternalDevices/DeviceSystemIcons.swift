import AppKit
import SwiftUI

/// Real Apple device-portrait icons (the classic iPod line), pulled **at
/// runtime** from the loose `.icns` resources of the system's AMPDevices
/// framework — the same artwork Finder shows for a synced device. Nothing is
/// bundled or redistributed with the app.
///
/// If a future macOS moves or renames these files, `image(for:)` returns nil
/// and every caller falls back to the parametric `IPodCatalog` drawings (or
/// the volume's own Finder icon), so this is a progressive enhancement, never
/// a dependency.
enum DeviceSystemIcons {
    private static let resourcesDir =
        "/System/Library/PrivateFrameworks/AMPDevices.framework/Versions/A/Resources"
    /// `iconID` namespace for system icons ("sys.iPod9-Black"), keeping them
    /// disjoint from the drawn catalog's ids ("classic.black").
    static let idPrefix = "sys."

    private static let cache = NSCache<NSString, NSImage>()

    /// Every device-portrait icon available on this machine, as picker entries.
    static let all: [(id: String, name: String)] = {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: resourcesDir) else { return [] }
        return files
            .filter { $0.hasPrefix("iPod") && $0.hasSuffix(".icns") }
            .map { file in
                let base = String(file.dropLast(5))
                return (id: idPrefix + base, name: base.replacingOccurrences(of: "-", with: " · "))
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }()

    /// The framework icon for a "sys." iconID, or nil for foreign/missing ids.
    static func image(for iconID: String?) -> NSImage? {
        guard let iconID, iconID.hasPrefix(idPrefix) else { return nil }
        let base = String(iconID.dropFirst(idPrefix.count))
        // The id round-trips into a filename — never let a crafted profile
        // blob escape the resources directory.
        guard base.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else { return nil }
        if let hit = cache.object(forKey: base as NSString) { return hit }
        guard let image = NSImage(contentsOfFile: "\(resourcesDir)/\(base).icns") else { return nil }
        cache.setObject(image, forKey: base as NSString)
        return image
    }

    /// Display name for a "sys." iconID (picker label / settings readout).
    static func displayName(for iconID: String?) -> String? {
        guard let iconID else { return nil }
        return all.first { $0.id == iconID }?.name
    }

    /// A SwiftUI `Image` rendered at `points` (icons are multi-rep, so this
    /// just picks the right representation; the NSImage is copied because the
    /// cached/workspace instance is shared).
    static func sidebarImage(_ nsImage: NSImage, points: CGFloat) -> Image {
        let copy = nsImage.copy() as! NSImage
        copy.size = NSSize(width: points, height: points)
        return Image(nsImage: copy)
    }
}
