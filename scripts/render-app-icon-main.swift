//
// Writes every app-icon asset from `AppIconArtwork`. Run it through
// `scripts/render-app-icon.sh`, which compiles this together with the artwork
// so there is only ever one drawing of the icon.
//

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

@main
struct AppIconRenderer {
    static let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

    static func main() {
        // The classic track, macOS 13 to 26. Apple's grid: the artwork sits in an
        // 824-of-1024 box so the icon matches its neighbours in the Dock.
        let iconset = "Branding/Icon/CrateDigger.iconset"
        for (name, side) in [
            ("icon_16x16", 16), ("icon_16x16@2x", 32),
            ("icon_32x32", 32), ("icon_32x32@2x", 64),
            ("icon_128x128", 128), ("icon_128x128@2x", 256),
            ("icon_256x256", 256), ("icon_256x256@2x", 512),
            ("icon_512x512", 512), ("icon_512x512@2x", 1024)
        ] {
            write("\(iconset)/\(name).png", side: side, inset: true)
        }

        // The same art for an Xcode asset catalogue; Contents.json is already there.
        for side in [16, 32, 64, 128, 256, 512, 1024] {
            write("Branding/Icon/AppIcon.appiconset/icon_\(side).png", side: side, inset: true)
        }

        // Tahoe / Icon Composer: full bleed, and the system supplies the mask. The
        // layers are what gives Liquid Glass its depth, so they ship separately.
        write("Branding/Icon/Tahoe/CrateDigger-1024-fullbleed.png", side: 1024, rounded: false)
        write("Branding/Icon/Tahoe/CrateDigger-1024-master.png", side: 1024)
        for layer in AppIconArtwork.Layer.allCases {
            let name = ["", "1-plate", "2-disc", "3-label"][layer.rawValue]
            write("Branding/Icon/Tahoe/Layers/\(name).png", side: 1024, rounded: false, layers: [layer])
        }

        // The preview the branding README links to.
        write("Branding/Generated/CrateDiggerIcon-1024.png", side: 1024)
    }


    static func write(
        _ relativePath: String,
        side: Int,
        inset: Bool = false,
        rounded: Bool = true,
        layers: Set<AppIconArtwork.Layer> = Set(AppIconArtwork.Layer.allCases)
    ) {
        let url = root.appendingPathComponent(relativePath)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )

        guard let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { fatalError("could not make a \(side)px context") }

        context.setAllowsAntialiasing(true)
        context.interpolationQuality = .high
        AppIconArtwork.draw(in: context, canvas: CGFloat(side), inset: inset, rounded: rounded, layers: layers)

        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(
                  url as CFURL, UTType.png.identifier as CFString, 1, nil
              )
        else { fatalError("could not encode \(relativePath)") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { fatalError("could not write \(relativePath)") }

        print("wrote \(relativePath) (\(side)px)")
    }
}
