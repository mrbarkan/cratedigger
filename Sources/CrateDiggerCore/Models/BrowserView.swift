import Foundation

/// What a source's browser shows: one to three facets, left to right, each
/// column narrowing the next.
///
/// Three rules, no more: not empty, not wider than three, no facet twice, and
/// Track only last — nothing cascades out of a track. A view can end on an
/// album or an artist; the leaf need not be a track list.
public struct BrowserView: Codable, Equatable, Sendable {
    public var facets: [BrowserFacet]

    public init(_ facets: [BrowserFacet]) {
        self.facets = facets
    }

    /// Artist · Album · Track — the browser as it has always been.
    public static let classic = BrowserView([.artist, .album, .track])
    /// One flat, sortable table. What a playlist opens in.
    public static let table = BrowserView([.track])

    public static let maxColumns = 3

    public enum Problem: Equatable, Sendable {
        case empty
        case tooWide
        case duplicate(BrowserFacet)
        case trackNotLast
    }

    /// Nil when the view is legal, else the first rule it breaks.
    public var problem: Problem? {
        if facets.isEmpty { return .empty }
        if facets.count > Self.maxColumns { return .tooWide }
        var seen: Set<BrowserFacet> = []
        for facet in facets {
            if !seen.insert(facet).inserted { return .duplicate(facet) }
        }
        if let at = facets.firstIndex(of: .track), at != facets.count - 1 { return .trackNotLast }
        return nil
    }

    public var isValid: Bool { problem == nil }

    public var columnCount: Int { facets.count }

    public func column(of facet: BrowserFacet) -> Int? {
        facets.firstIndex(of: facet)
    }

    // MARK: - Legacy layouts

    /// What `BrowserLayout` used to mean, for the two preference keys that
    /// still hold one.
    public init(legacy: BrowserLayout) {
        switch legacy {
        case .full:       self = .classic
        case .albumTrack: self = BrowserView([.album, .track])
        case .track:      self = .table
        }
    }

    // MARK: - Growing, shrinking, swapping

    /// The order a new column's facet is chosen in: the most useful thing the
    /// view does not already show. Track first because a view without a track
    /// list is the unusual one; then the classic tree; then the rest.
    private static let preference: [BrowserFacet] = [
        .track, .album, .artist, .genre, .year, .decade, .format, .albumArtist, .rating
    ]

    /// One column wider, or `self` if already three. Track goes at the end;
    /// anything else goes before a trailing Track column.
    public func adding() -> BrowserView {
        guard facets.count < Self.maxColumns,
              let next = Self.preference.first(where: { !facets.contains($0) })
        else { return self }
        var grown = facets
        if next == .track {
            grown.append(.track)
        } else if grown.last == .track {
            grown.insert(next, at: grown.count - 1)
        } else {
            grown.append(next)
        }
        return BrowserView(grown)
    }

    /// One column narrower, or `self` if already one.
    public func droppingLast() -> BrowserView {
        guard facets.count > 1 else { return self }
        return BrowserView(Array(facets.dropLast()))
    }

    /// The same view with one column showing something else.
    public func replacing(column: Int, with facet: BrowserFacet) -> BrowserView {
        guard facets.indices.contains(column) else { return self }
        var swapped = facets
        swapped[column] = facet
        return BrowserView(swapped)
    }

    /// Whether the header menu should offer `facet` for `column`: false for
    /// a choice that would break a rule. The current facet is always allowed.
    public func canReplace(column: Int, with facet: BrowserFacet) -> Bool {
        guard facets.indices.contains(column) else { return false }
        if facets[column] == facet { return true }
        return replacing(column: column, with: facet).isValid
    }
}
