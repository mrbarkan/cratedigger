#if canImport(XCTest)
import Foundation
import XCTest
@testable import CrateDiggerCore

final class AlbumFolderSplitterTests: XCTestCase {
    private func loaded(_ name: String, format: String?) -> LoadedTrack {
        let t = AudioTrack(fileURL: URL(fileURLWithPath: "/tmp/Album/\(name)"),
                           title: name, formatName: format)
        return LoadedTrack(track: t, metadata: ConversionMetadata())
    }

    func testMixedFolderSplitsIntoCodecGroupsLargestFirst() {
        let tracks = [
            loaded("01.flac", format: "flac"), loaded("02.flac", format: "flac"),
            loaded("03.flac", format: "flac"),
            loaded("01.m4a", format: "aac"), loaded("02.m4a", format: "aac"),
        ]
        let groups = AlbumFolderSplitter.codecGroups(for: tracks)
        XCTAssertEqual(groups.map(\.codec), ["FLAC", "AAC"])
        XCTAssertEqual(groups.map { $0.tracks.count }, [3, 2])
    }

    func testSingleCodecFolderIsOneGroup() {
        let groups = AlbumFolderSplitter.codecGroups(for: [
            loaded("01.flac", format: "flac"), loaded("02.flac", format: "FLAC"),
        ])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].codec, "FLAC")
    }

    func testUnknownFormatBucketsUnderQuestionMarkNotDropped() {
        let groups = AlbumFolderSplitter.codecGroups(for: [
            loaded("01.flac", format: "flac"), loaded("02.bin", format: nil),
        ])
        XCTAssertEqual(groups.flatMap(\.tracks).count, 2)
        XCTAssertTrue(groups.contains { $0.codec == "?" })
    }
}
#endif
