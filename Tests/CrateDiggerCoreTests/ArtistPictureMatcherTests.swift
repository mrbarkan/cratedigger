import XCTest
@testable import CrateDiggerCore

/// D2: a picture is taken without asking only when the name keys as ours and
/// one of the candidate's albums is one of the albums on the device.
final class ArtistPictureMatcherTests: XCTestCase {
    private func candidate(_ name: String, albums: [String] = [], id: String = "1") -> ArtistPictureCandidate {
        ArtistPictureCandidate(name: name, source: .deezer, sourceID: id,
                               imageURL: URL(string: "https://img.example/\(id).jpg")!, albumTitles: albums)
    }

    private func verdict(_ candidate: ArtistPictureCandidate, _ name: String, _ albums: [String]) -> ArtistPictureVerdict {
        ArtistPictureMatcher.verdict(candidate, name: name, deviceAlbumTitles: albums)
    }

    func testNameMismatchIsNoMatch() {
        XCTAssertEqual(verdict(candidate("Nirvana UK", albums: ["Nevermind"]), "Nirvana", ["Nevermind"]), .noMatch)
        XCTAssertEqual(verdict(candidate("Bjork Guðmundsdóttir", albums: ["Post"]), "Björk", ["Post"]), .noMatch)
    }

    func testNameMatchWithoutAlbumsIsUncertain() {
        XCTAssertEqual(verdict(candidate("Nirvana"), "Nirvana", ["Nevermind"]), .uncertain)
        XCTAssertEqual(verdict(candidate("Nirvana", albums: ["Nevermind"]), "Nirvana", []), .uncertain)
        XCTAssertEqual(verdict(candidate("Nirvana", albums: ["Bleach"]), "Nirvana", ["Nevermind"]), .uncertain)
    }

    func testAlbumCrossCheckIsConfident() {
        XCTAssertEqual(verdict(candidate("Björk", albums: ["Debut", "Post"]), "Bjork", ["post"]), .confident)
        XCTAssertEqual(verdict(candidate("AC/DC", albums: ["Back In Black"]), "AC-DC", ["Back in Black!"]), .confident)
    }

    func testAlbumSuffixesIgnored() {
        XCTAssertEqual(verdict(candidate("Radiohead", albums: ["OK Computer (Remastered)"]), "Radiohead", ["OK Computer"]),
                       .confident)
        XCTAssertEqual(verdict(candidate("Radiohead", albums: ["OK Computer"]), "Radiohead",
                               ["OK Computer [Collector's Edition] (2009 Remaster)"]), .confident)
        // A title that is nothing but punctuation never matches another one.
        XCTAssertEqual(verdict(candidate("Radiohead", albums: ["(Live)"]), "Radiohead", ["[Live]"]), .uncertain)
        XCTAssertEqual(verdict(candidate("Radiohead", albums: ["!!!"]), "Radiohead", ["???"]), .uncertain)
    }

    /// Review I4: a self-titled album or a generic title says nothing about which act it is.
    func testSelfTitledAndGenericTitlesNeverConfirm() {
        XCTAssertEqual(verdict(candidate("Boston", albums: ["Boston"]), "Boston", ["Boston"]), .uncertain)
        XCTAssertEqual(verdict(candidate("The Beatles", albums: ["Beatles"]), "Beatles", ["The Beatles"]), .uncertain)
        for generic in ["Greatest Hits", "The Best Of", "Best of Boston", "Live", "Live (1985)", "Gold", "Anthology",
                        "The Collection", "Singles", "Remixes", "MTV Unplugged", "Essentials", "The Essential Boston",
                        "Boston's Greatest Hits Vol. 2"] {
            XCTAssertEqual(verdict(candidate("Boston", albums: [generic]), "Boston", [generic]), .uncertain, generic)
        }
        XCTAssertEqual(verdict(candidate("Boston", albums: ["Live (2003)"]), "Boston", ["Live (1985)"]), .uncertain)
        // Titles that only start like a generic word still count.
        XCTAssertEqual(verdict(candidate("Kacey Musgraves", albums: ["Golden Hour"]), "Kacey Musgraves", ["Golden Hour"]),
                       .confident)
        XCTAssertEqual(verdict(candidate("Hole", albums: ["Live Through This"]), "Hole", ["Live Through This"]),
                       .confident)
    }

    func testTwoNirvanasOnlyTheOneWithOurAlbumIsConfident() {
        let grunge = candidate("Nirvana", albums: ["Bleach", "Nevermind", "In Utero"], id: "415")
        let sixties = candidate("Nirvana", albums: ["The Story of Simon Simopath", "All of Us"], id: "9001")
        XCTAssertEqual(verdict(grunge, "Nirvana", ["Nevermind (Deluxe Edition)"]), .confident)
        XCTAssertEqual(verdict(sixties, "Nirvana", ["Nevermind (Deluxe Edition)"]), .uncertain)
    }

    func testNameMatchUsesThePodBoxFold() {
        XCTAssertEqual(verdict(candidate("The Beatles", albums: ["Help!"]), "Beatles, The", ["Help"]), .confident)
        XCTAssertEqual(verdict(candidate("Herbert, Frank", albums: ["Dune"]), "Frank Herbert", ["Dune"]), .confident)
        XCTAssertEqual(verdict(candidate("!!!", albums: ["Thr!!!er"]), "!!!", ["Thr!!!er"]), .noMatch,
                       "a name the player cannot key matches nothing")
    }
}
