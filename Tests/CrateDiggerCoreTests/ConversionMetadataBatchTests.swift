import XCTest
@testable import CrateDiggerCore

final class ConversionMetadataBatchTests: XCTestCase {

    private func meta(album: String? = nil, albumArtist: String? = nil,
                      genre: String? = nil, year: Int? = nil,
                      title: String? = nil, trackNumber: Int? = nil) -> ConversionMetadata {
        ConversionMetadata(title: title, albumArtist: albumArtist, album: album,
                           trackNumber: trackNumber, year: year, genre: genre)
    }

    // MARK: commonValue — shared vs mixed

    func testCommonValueSharedAcrossAll() {
        let items = [meta(album: "Discovery"), meta(album: "Discovery"), meta(album: "Discovery")]
        XCTAssertEqual(ConversionMetadata.commonValue(.album, in: items), "Discovery")
    }

    func testCommonValueMixedIsNil() {
        let items = [meta(album: "Discovery"), meta(album: "Homework")]
        XCTAssertNil(ConversionMetadata.commonValue(.album, in: items))
    }

    func testCommonValueAbsentTagIsEmptyString() {
        // All three lack a genre → they "agree" on empty, which is a shared value.
        let items = [meta(), meta(), meta()]
        XCTAssertEqual(ConversionMetadata.commonValue(.genre, in: items), "")
    }

    func testCommonValueYearFormatting() {
        let items = [meta(year: 2001), meta(year: 2001)]
        XCTAssertEqual(ConversionMetadata.commonValue(.year, in: items), "2001")
    }

    // MARK: applyingBatchEdits — only changed fields touched

    func testApplyOnlyEditedFields() {
        let original = meta(album: "Old", albumArtist: "Daft Punk", title: "Aerodynamic", trackNumber: 3)
        let edited = original.applyingBatchEdits([.album: "New"])
        XCTAssertEqual(edited.album, "New")
        // Untouched fields survive — crucially the per-track ones.
        XCTAssertEqual(edited.albumArtist, "Daft Punk")
        XCTAssertEqual(edited.title, "Aerodynamic")
        XCTAssertEqual(edited.trackNumber, 3)
    }

    func testApplyEmptyStringClearsTag() {
        let original = meta(genre: "House")
        let edited = original.applyingBatchEdits([.genre: ""])
        XCTAssertNil(edited.genre)
    }

    func testApplyYearParsesInt() {
        let edited = meta().applyingBatchEdits([.year: "2013"])
        XCTAssertEqual(edited.year, 2013)
    }

    // MARK: end-to-end merge mirroring the editor's save logic

    func testBatchMergeLeavesMixedUntouchedAndAppliesChange() {
        // Two tracks: same album-artist, different titles (per-track), mixed genre.
        let a = meta(album: "Discovery", albumArtist: "Daft Punk", genre: "House", title: "One More Time")
        let b = meta(album: "Discovery", albumArtist: "Daft Punk", genre: "Disco", title: "Aerodynamic")
        let items = [a, b]

        // User opened the batch editor (genre shows "Multiple values"), typed a
        // new album, left genre blank. Compute edits the way saveBatch does:
        var edits: [ConversionMetadata.BatchField: String] = [:]
        func consider(_ field: ConversionMetadata.BatchField, _ current: String) {
            let original = ConversionMetadata.commonValue(field, in: items) ?? ""
            if current != original { edits[field] = current }
        }
        consider(.album, "Discovery (Remastered)")  // changed
        consider(.albumArtist, "Daft Punk")         // unchanged → skipped
        consider(.genre, "")                         // mixed, left blank → skipped

        XCTAssertEqual(edits, [.album: "Discovery (Remastered)"])

        let outA = a.applyingBatchEdits(edits)
        let outB = b.applyingBatchEdits(edits)
        XCTAssertEqual(outA.album, "Discovery (Remastered)")
        XCTAssertEqual(outB.album, "Discovery (Remastered)")
        // Mixed genre untouched on both; titles preserved.
        XCTAssertEqual(outA.genre, "House")
        XCTAssertEqual(outB.genre, "Disco")
        XCTAssertEqual(outA.title, "One More Time")
        XCTAssertEqual(outB.title, "Aerodynamic")
    }

    // MARK: Compilation (Bool? carried as "1"/"0"/"")

    func testCompilationCommonValueShared() {
        let items = [ConversionMetadata(compilation: true), ConversionMetadata(compilation: true)]
        XCTAssertEqual(ConversionMetadata.commonValue(.compilation, in: items), "1")
    }

    func testCompilationCommonValueMixedIsNil() {
        let items = [ConversionMetadata(compilation: true), ConversionMetadata(compilation: false)]
        XCTAssertNil(ConversionMetadata.commonValue(.compilation, in: items))
    }

    func testCompilationAbsentIsEmptyString() {
        let items = [ConversionMetadata(), ConversionMetadata()]
        XCTAssertEqual(ConversionMetadata.commonValue(.compilation, in: items), "")
    }

    func testApplyCompilationSetsTrueFalseNil() {
        XCTAssertEqual(ConversionMetadata().applyingBatchEdits([.compilation: "1"]).compilation, true)
        XCTAssertEqual(ConversionMetadata(compilation: true).applyingBatchEdits([.compilation: "0"]).compilation, false)
        XCTAssertNil(ConversionMetadata(compilation: true).applyingBatchEdits([.compilation: ""]).compilation)
    }

    func testApplyCompilationLeavesOtherFields() {
        let edited = meta(album: "X", albumArtist: "Y").applyingBatchEdits([.compilation: "1"])
        XCTAssertEqual(edited.compilation, true)
        XCTAssertEqual(edited.album, "X")
        XCTAssertEqual(edited.albumArtist, "Y")
    }
}
