import Foundation

/// The stream download: a cassette recording, the take-up pack growing with progress (html:659-727).
///
/// A stub until Task 11 ports it: the picture is empty (which the generic
/// `BusySceneTests` read as "not drawn yet" and skip), and the mini is just
/// the shared dashed track.
enum DownloadScene {
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
