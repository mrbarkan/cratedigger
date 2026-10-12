import SwiftUI
import CrateDiggerCore

/// One MusicBrainz release in Artwork Search's result list: what it is, what
/// art it carries, and the key that opens it.
///
/// Its own view with plain-value inputs, compared by `Equatable`, so a count
/// or a cover size landing for one release redraws that row and not the whole
/// list. As a method on the sheet, every probe that landed re-ran every row's
/// body.
struct ArtworkReleaseRow: View, Equatable {
    @Environment(\.carbon) private var theme

    let release: MBReleaseCandidate
    let count: CoverArtCount
    let frontSize: ArtworkDimensions?
    let isBest: Bool
    let isRemembered: Bool
    /// Asks for the front cover's size once this row is on screen and
    /// MusicBrainz has said there is a front to measure.
    let probeFront: @MainActor () async -> Void
    let open: () -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.release == rhs.release && lhs.count == rhs.count && lhs.frontSize == rhs.frontSize
            && lhs.isBest == rhs.isBest && lhs.isRemembered == rhs.isRemembered
    }

    private var hasFront: Bool {
        guard let summary = count.summary else { return false }
        return summary.hasFront && !summary.darkened
    }

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                titleLine
                detailLine
                if let disambiguation = release.disambiguation {
                    Text(disambiguation)
                        .font(CarbonFont.sans(9.5, weight: .regular))
                        .foregroundStyle(theme.ink3)
                        .italic()
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            // The art column: never squeezed. A long title truncates instead,
            // because these badges are the reason the list exists.
            HStack(spacing: 6) {
                if isRemembered {
                    pill("USED", fill: theme.cyan, ink: .white)
                        .carbonTip("This album's artwork already came from this release.")
                }
                frontSizeBadge
                imageCountBadge
                KeyButton(style: .normal, action: open) {
                    Text("GET ARTWORK")
                }
                .frame(width: 96, height: 22)
            }
            .fixedSize()
            .layoutPriority(1)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(isBest ? theme.orange.opacity(0.06) : Color.clear)
        // Re-runs when the count lands and says there is a front. Cancelled
        // when the row scrolls away, which the service does not mistake for
        // a failure.
        .task(id: hasFront && frontSize == nil) {
            guard hasFront, frontSize == nil else { return }
            await probeFront()
        }
    }

    private var titleLine: some View {
        HStack(spacing: 8) {
            if isBest {
                pill("★ BEST", fill: theme.orange, ink: .white)
                    .carbonTip("Closest match to this album's title, format and year")
            }
            Text(release.title)
                .font(CarbonFont.sans(12, weight: .bold))
                .foregroundStyle(theme.ink)
                .lineLimit(1)
                .truncationMode(.tail)
            if let media = release.mediaSummary {
                tag(media.uppercased(), fill: theme.orange.opacity(0.15), ink: theme.orange)
            }
            if let status = release.status, status != "Official" {
                tag(status.uppercased(), fill: theme.ink4.opacity(0.15), ink: theme.ink3)
            }
        }
    }

    /// Artist, year, country, tracks, barcode: one line, separated by dots,
    /// so a pressing can be told apart at a glance.
    private var detailLine: some View {
        let parts = [
            release.artist,
            release.date,
            release.country,
            release.trackCount.map { "\($0) track\($0 == 1 ? "" : "s")" }
        ].compactMap { $0 }
        return HStack(spacing: 8) {
            Text(parts.joined(separator: " · "))
                .font(CarbonFont.mono(9, weight: .medium))
                .foregroundStyle(theme.ink3)
                .lineLimit(1)
                .truncationMode(.tail)
            if let barcode = release.barcode {
                Text(barcode)
                    .font(CarbonFont.mono(9, weight: .medium))
                    .foregroundStyle(theme.ink4)
                    .lineLimit(1)
                    .carbonTip("Barcode")
            }
        }
    }

    /// The front cover's size, once measured. "HD" reads faster than the
    /// numbers when you're scanning a list for the one worth opening.
    @ViewBuilder
    private var frontSizeBadge: some View {
        if let size = frontSize {
            let isHiRes = size.isHighResolution
            pill(isHiRes ? "HD" : "\(size.longEdge)PX", fill: isHiRes ? theme.cyan : theme.ink3, ink: .white)
                .carbonTip("The front cover is \(size.width) × \(size.height) pixels")
        }
    }

    /// How many images the Cover Art Archive holds for this release. Three
    /// honest states: still counting, counted, and couldn't count.
    @ViewBuilder
    private var imageCountBadge: some View {
        switch count {
        case .pending:
            tag("…", fill: theme.ink4.opacity(0.08), ink: theme.ink4)
                .carbonTip("Counting images")
        case .unknown:
            tag("? IMAGES", fill: theme.ink4.opacity(0.12), ink: theme.ink3)
                .carbonTip("Couldn't count the images for this release. GET ARTWORK still asks the archive.")
        case .known(let summary):
            let n = summary.available
            tag(n == 0 ? "NO IMAGES" : "\(n) IMAGE\(n == 1 ? "" : "S")",
                fill: n == 0 ? theme.ink4.opacity(0.12) : theme.cyan.opacity(0.15),
                ink: n == 0 ? theme.ink4 : theme.cyan)
                .carbonTip(Self.countTip(summary))
        }
    }

    static func countTip(_ summary: CoverArtSummary) -> String {
        if summary.darkened {
            return "The Cover Art Archive holds images for this release but has withdrawn them."
        }
        guard summary.count > 0 else {
            return "The Cover Art Archive has no images for this release. Discogs may still have some."
        }
        let covers: String
        switch (summary.hasFront, summary.hasBack) {
        case (true, true): covers = ", front and back covers included"
        case (true, false): covers = ", front cover included"
        case (false, true): covers = ", back cover included, no front"
        case (false, false): covers = ", no front cover marked"
        }
        return "\(summary.count) image\(summary.count == 1 ? "" : "s") on the Cover Art Archive\(covers). Discogs may add more."
    }

    private func tag(_ text: String, fill: Color, ink: Color) -> some View {
        Text(text)
            .font(CarbonFont.mono(8, weight: .bold))
            .tracking(0.5)
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(fill)
            .foregroundColor(ink)
            .cornerRadius(3)
    }

    private func pill(_ text: String, fill: Color, ink: Color) -> some View {
        Text(text)
            .font(CarbonFont.mono(7.5, weight: .bold))
            .tracking(0.5)
            .lineLimit(1)
            .foregroundColor(ink)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(fill))
    }
}
