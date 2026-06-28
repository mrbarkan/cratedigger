#if canImport(XCTest)
import Foundation
import XCTest
@testable import CrateDiggerCore

final class ExternalToolLocatorTests: XCTestCase {
    func testBundledToolWinsOverExplicitOverride() throws {
        try withTemporaryDirectory(prefix: "CrateDiggerToolLocatorTests") { temporaryDirectory in
            let bundle = try makeBundle(in: temporaryDirectory)
            let bundledTool = try writeExecutableStub(
                named: "ffmpeg",
                contents: "#!/bin/sh\necho bundled\n",
                in: bundle.bundleURL.appendingPathComponent("Contents/Resources", isDirectory: true)
            )
            let explicitTool = try writeExecutableStub(
                named: "ffmpeg-explicit",
                contents: "#!/bin/sh\necho explicit\n",
                in: temporaryDirectory
            )

            let locator = ExternalToolLocator(
                fileManager: .default,
                environment: [:],
                bundle: bundle,
                defaultSystemSearchDirectories: []
            )
            let resolved = try locator.resolveRequired(.ffmpeg, explicitOverride: explicitTool)

            XCTAssertEqual(resolved.url, bundledTool)
        }
    }

    func testExplicitOverrideUsedWhenBundleDoesNotContainTool() throws {
        try withTemporaryDirectory(prefix: "CrateDiggerToolLocatorTests") { temporaryDirectory in
            let bundle = try makeBundle(in: temporaryDirectory)
            let explicitTool = try writeExecutableStub(
                named: "ffprobe-explicit",
                contents: "#!/bin/sh\necho explicit\n",
                in: temporaryDirectory
            )

            let locator = ExternalToolLocator(
                fileManager: .default,
                environment: [:],
                bundle: bundle,
                defaultSystemSearchDirectories: []
            )
            let resolved = try locator.resolveRequired(.ffprobe, explicitOverride: explicitTool)

            XCTAssertEqual(resolved.url, explicitTool)
        }
    }

    func testEnvironmentPathProvidesSystemFallback() throws {
        try withTemporaryDirectory(prefix: "CrateDiggerToolLocatorTests") { temporaryDirectory in
            let bundle = try makeBundle(in: temporaryDirectory)
            let binDirectory = temporaryDirectory.appendingPathComponent("bin", isDirectory: true)
            try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)
            let systemTool = try writeExecutableStub(
                named: "ffmpeg",
                contents: "#!/bin/sh\necho system\n",
                in: binDirectory
            )

            let locator = ExternalToolLocator(
                fileManager: .default,
                environment: ["PATH": binDirectory.path],
                bundle: bundle,
                defaultSystemSearchDirectories: []
            )
            let resolved = try locator.resolveRequired(.ffmpeg)

            XCTAssertEqual(resolved.url, systemTool)
        }
    }

    func testOptionalResolutionReturnsNilWhenToolIsMissing() throws {
        try withTemporaryDirectory(prefix: "CrateDiggerToolLocatorTests") { temporaryDirectory in
            let bundle = try makeBundle(in: temporaryDirectory)
            let locator = ExternalToolLocator(
                fileManager: .default,
                environment: ["PATH": temporaryDirectory.path],
                bundle: bundle,
                defaultSystemSearchDirectories: []
            )

            XCTAssertNil(locator.resolveOptional(.ffprobe))
        }
    }
}

private func makeBundle(in directory: URL) throws -> Bundle {
    let bundleURL = directory.appendingPathComponent("TestBundle.bundle", isDirectory: true)
    let contentsURL = bundleURL.appendingPathComponent("Contents", isDirectory: true)
    let resourcesURL = contentsURL.appendingPathComponent("Resources", isDirectory: true)

    try FileManager.default.createDirectory(at: resourcesURL, withIntermediateDirectories: true)
    let infoPlist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>CFBundleIdentifier</key>
        <string>com.cratedigger.tests.bundle</string>
        <key>CFBundleName</key>
        <string>TestBundle</string>
        <key>CFBundlePackageType</key>
        <string>BNDL</string>
    </dict>
    </plist>
    """
    try Data(infoPlist.utf8).write(to: contentsURL.appendingPathComponent("Info.plist"))

    return try XCTUnwrap(Bundle(path: bundleURL.path))
}
#endif
