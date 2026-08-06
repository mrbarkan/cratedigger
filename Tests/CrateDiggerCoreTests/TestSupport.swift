import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

@testable import CrateDiggerCore

func withTemporaryDirectory<Result>(
    prefix: String,
    _ body: (URL) throws -> Result
) throws -> Result {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer {
        if FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    return try body(directory)
}

func withTemporaryDirectory<Result>(
    prefix: String,
    _ body: (URL) async throws -> Result
) async throws -> Result {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer {
        if FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    return try await body(directory)
}

func writeExecutableStub(named executableName: String, contents: String, in directory: URL) throws -> URL {
    let url = directory.appendingPathComponent(executableName)
    try Data(contents.utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
}

func makeImageData(
    size: NSSize = NSSize(width: 500, height: 500),
    fileType: NSBitmapImageRep.FileType = .jpeg
) throws -> Data {
    let image = NSImage(size: size)
    image.lockFocus()

    NSColor(calibratedRed: 0.08, green: 0.35, blue: 0.72, alpha: 1).setFill()
    NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()

    NSColor.white.setStroke()
    let path = NSBezierPath()
    path.lineWidth = 12
    path.move(to: NSPoint(x: 0, y: 0))
    path.line(to: NSPoint(x: size.width, y: size.height))
    path.stroke()

    image.unlockFocus()

    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let data = bitmap.representation(using: fileType, properties: [.compressionFactor: 0.9])
    else {
        throw NSError(domain: "CrateDiggerCoreTests", code: 1)
    }

    return data
}

/// A square JPEG of `pixels` x `pixels` tagged at `dpi`. At a non-72 DPI the
/// decoded `NSImage.size` (points) diverges from the pixel dimensions, which is
/// what artwork downscaling has to measure against.
func makeJPEGData(pixels: Int, dpi: Int) throws -> Data {
    guard let context = CGContext(
        data: nil,
        width: pixels,
        height: pixels,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ) else {
        throw NSError(domain: "CrateDiggerCoreTests", code: 3)
    }

    context.setFillColor(CGColor(red: 0.08, green: 0.35, blue: 0.72, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: pixels, height: pixels))

    let output = NSMutableData()
    guard let cgImage = context.makeImage(),
          let destination = CGImageDestinationCreateWithData(
              output, UTType.jpeg.identifier as CFString, 1, nil
          )
    else {
        throw NSError(domain: "CrateDiggerCoreTests", code: 4)
    }

    CGImageDestinationAddImage(destination, cgImage, [
        kCGImageDestinationLossyCompressionQuality: 0.9,
        kCGImagePropertyDPIWidth: dpi,
        kCGImagePropertyDPIHeight: dpi
    ] as CFDictionary)

    guard CGImageDestinationFinalize(destination) else {
        throw NSError(domain: "CrateDiggerCoreTests", code: 5)
    }
    return output as Data
}

func pumpMainQueue() async {
    await withCheckedContinuation { continuation in
        DispatchQueue.main.async {
            continuation.resume()
        }
    }
}
