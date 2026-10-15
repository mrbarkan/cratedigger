import Foundation

/// The scan: records flipped through a crate, finds pulled onto a pile, the crates cycling A-F to T-Z (html:530-657).
///
/// A stub until Task 10 ports it: the picture is empty (which the generic
/// `BusySceneTests` read as "not drawn yet" and skip), and the mini is just
/// the shared dashed track.
enum ScanScene {
    static func picture(_ input: BusySceneInput) -> BusyDrawing {
        BusyDrawing(size: BusyDrawing.sceneSize)
    }

    static func mini(_ input: BusySceneInput) -> BusyDrawing {
        var d = BusyDrawing(size: BusyDrawing.miniSize)
        BusyGlyphs.miniTrack(&d, input)
        return d
    }

    /// Stub: chosen with the scene.
    static let keyTime: TimeInterval = 0
}
