import Foundation

/// The Secure Mode read: a sled crossing the disc over a 60-cell sector map, cells filling per pass and re-reads lighting hot (html:420-447).
///
/// A stub until Task 8 ports it: the picture is empty (which the generic
/// `BusySceneTests` read as "not drawn yet" and skip), and the mini is just
/// the shared dashed track.
enum SecureReadScene {
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
