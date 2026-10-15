import Foundation

/// The conversion: a file passing under a press, squashed flat when lossy and re-boxed whole when lossless (html:451-528).
///
/// A stub until Task 9 ports it: the picture is empty (which the generic
/// `BusySceneTests` read as "not drawn yet" and skip), and the mini is just
/// the shared dashed track.
enum ConvertScene {
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
