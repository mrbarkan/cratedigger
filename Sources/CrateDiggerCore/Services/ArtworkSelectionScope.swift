import Foundation

/// Which candidates in the artwork search grid an action applies to.
///
/// The grid draws scans from three places at once — the Cover Art Archive,
/// Discogs, and files off your own disk — and its source chips narrow that to
/// one. The chips have to narrow what is *acted on* as well as what is drawn,
/// or the selection and the grid disagree: filtering to the archive and
/// pressing SELECT ALL used to tick the hidden Discogs scans too, and STAGE
/// then fetched them, which is how an album ended up with two covers and a set
/// of duplicate booklet pages nobody asked for.
///
/// Hiding is not deselecting. An image the filter hides keeps its selection,
/// so lifting the chip shows it still ticked rather than silently emptied —
/// that is what makes a chip a view of the grid rather than an edit to it.
public enum ArtworkSelectionScope {

    /// What the grid draws under this filter. `nil` is the ALL chip.
    public static func visible(_ images: [RemoteArtworkImage],
                               source: RemoteArtworkSource?) -> [RemoteArtworkImage] {
        guard let source else { return images }
        return images.filter { $0.source == source }
    }

    /// What SELECT ALL, the counter and STAGE act on: selected *and* visible.
    ///
    /// In grid order rather than selection order, because a `Set` has none and
    /// the order is what the staged filenames count (`booklet_01`,
    /// `booklet_02`, …).
    public static func actionable(_ images: [RemoteArtworkImage],
                                  selected: Set<String>,
                                  source: RemoteArtworkSource?) -> [RemoteArtworkImage] {
        visible(images, source: source).filter { selected.contains($0.id) }
    }
}
