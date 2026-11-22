import Foundation

/// What the DEVICES screen's Artwork cell says about a device's art: the
/// value is what goes inside the files (or the cover's size when nothing
/// does), the sub line says where it goes. With folder art on and art inside
/// the files too, the sub line adds the cover ("+ cover.jpg"), so both read.
public enum DeviceArtworkReadout {
    /// (value, sub) for the DEVICES Artwork cell.
    /// Strip + folder → ("400 px", "cover.jpg"); Keep → ("KEEP", "Embedded");
    /// Re-embed 600 → ("600 px", "Embedded"); Keep + folder → ("KEEP", "+ cover.jpg");
    /// Re-embed 600 + folder → ("600 px", "+ cover.jpg"); Strip, no folder → ("NONE", "Stripped").
    /// Re-embed with no cap has no size to show and reads "RE-EMBED". Keep
    /// copies the art as it is, so it never shows the cap.
    public static func cell(mode: ArtworkMode, maxDimension: Int?, folderArt: Bool) -> (value: String, sub: String) {
        let embedded: String
        switch mode {
        case .none:
            return folderArt
                ? ("\(FolderCoverArtWriter.defaultMaxDimension) px", "cover.jpg")
                : ("NONE", "Stripped")
        case .preserve:
            embedded = "KEEP"
        case .compatReembed:
            embedded = maxDimension.map { "\($0) px" } ?? "RE-EMBED"
        }
        return (embedded, folderArt ? "+ cover.jpg" : "Embedded")
    }
}
