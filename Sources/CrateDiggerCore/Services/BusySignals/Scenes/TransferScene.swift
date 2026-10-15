import Foundation

/// The device transfer: a laptop feeding an iPod whose screen shows the no-entry sign until it is done (html:729-771).
///
/// A stub until Task 12 ports it: the picture is empty (which the generic
/// `BusySceneTests` read as "not drawn yet" and skip), and the mini is just
/// the shared dashed track.
enum TransferScene {
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
