import CoreGraphics

/// Where a job pane puts its Busy Signals picture inside its top band, the
/// part of the pane above the 48 pt cell rail.
///
/// The picture is a guest: it is dropped, not squeezed, whenever it would
/// cost the pane something it already shows. Too short a band (a theme with
/// a short header) and the scene stops reading; too narrow (a drag-shrunk
/// window) and the readout to its right loses its room. Either way the pane
/// falls back to its idle body, and the rail minis still show.
///
/// Only the height gives: the width is always the full 220 pt. The spec's
/// `min(220, …)` never bites, because a band too narrow for 220 already
/// fails the readout clearance and is dropped before it could shrink.
public enum BusyPictureLayout {
    /// The sketch's own canvas (html:943); the scene letterboxes into it.
    static let maxSize = CGSize(width: 220, height: 84)
    /// Below this the scene is unreadable.
    static let minimumHeight: CGFloat = 40
    /// What must stay right of the picture: a 150 pt readout plus the 24 pt
    /// row gap.
    static let readoutClearance: CGFloat = 174

    /// The picture's frame inside a pane's top band, or nil when it doesn't
    /// fit. `leading` is `OLEDCells.textLeading(ofColumn: 2, in: width)`, so
    /// the picture shares the cell rail's verticals; `topInset` is the
    /// title's cap-top inset, like the NOW matrix. At the default 170 pt
    /// header that is 220 × 76.
    public static func frame(bandSize: CGSize, leading: CGFloat, topInset: CGFloat) -> CGRect? {
        let height = min(maxSize.height, bandSize.height - topInset)
        guard height >= minimumHeight else { return nil }
        let width = maxSize.width
        guard bandSize.width - (leading + width) >= readoutClearance else { return nil }
        return CGRect(x: leading, y: topInset, width: width, height: height)
    }
}
