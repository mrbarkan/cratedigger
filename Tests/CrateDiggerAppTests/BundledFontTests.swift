#if canImport(XCTest)
import CoreText
import XCTest
@testable import CrateDiggerApp

/// The faces `CarbonFont` names as the app's defaults have to be files the app
/// ships. `Font.custom` never fails — a missing PostScript name draws Helvetica
/// and says nothing — so for two release lines Inter and JetBrains Mono
/// resolved from the author's `~/Library/Fonts` and from nowhere else, and
/// every other Mac ran the whole interface in the system font.
final class BundledFontTests: XCTestCase {

    private var shippedFaces: Set<String> = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        let fonts = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // CrateDiggerAppTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Sources/CrateDiggerApp/Resources/Fonts", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(at: fonts, includingPropertiesForKeys: nil)
            .filter { ["ttf", "otf"].contains($0.pathExtension.lowercased()) }
        shippedFaces = Set(files.flatMap { url in
            ((CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor]) ?? [])
                .compactMap { CTFontDescriptorCopyAttribute($0, kCTFontNameAttribute) as? String }
        })
        XCTAssertFalse(shippedFaces.isEmpty, "no fonts under Resources/Fonts")
    }

    /// Checked by PostScript name read out of the file, not by filename: the
    /// name is what `Font.custom` asks CoreText for.
    func testEveryDefaultFaceCarbonFontNamesIsShipped() {
        let defaults = [
            CarbonFont.sansFamily, CarbonFont.sansMedium, CarbonFont.sansSemibold,
            CarbonFont.sansBold, CarbonFont.sansExtraBold,
            CarbonFont.monoFamily, CarbonFont.monoMedium, CarbonFont.monoSemibold, CarbonFont.monoBold,
            CarbonFont.displayFamily,
        ]
        for face in defaults {
            XCTAssertTrue(shippedFaces.contains(face),
                          "\(face) is a CarbonFont default but no file in Resources/Fonts declares it")
        }
    }

    /// Static faces, deliberately. A variable font registers only under its
    /// default instance's name, which is how `JetBrainsMono-Bold` drew as
    /// Helvetica on the one machine that had the family at all.
    func testShippedFontsAreStaticFaces() throws {
        let fonts = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/CrateDiggerApp/Resources/Fonts", isDirectory: true)
        for url in try FileManager.default.contentsOfDirectory(at: fonts, includingPropertiesForKeys: nil)
        where ["ttf", "otf"].contains(url.pathExtension.lowercased()) {
            let descriptors = (CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor]) ?? []
            let font = CTFontCreateWithFontDescriptor(try XCTUnwrap(descriptors.first), 12, nil)
            XCTAssertNil(CTFontCopyVariationAxes(font), "\(url.lastPathComponent) is a variable font")
        }
    }
}
#endif
