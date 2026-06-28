import Foundation

public struct Artist: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let albums: [Album]

    public init(id: String, name: String, albums: [Album]) {
        self.id = id
        self.name = name
        self.albums = albums
    }

    public var albumCount: Int { albums.count }

    public static func == (lhs: Artist, rhs: Artist) -> Bool {
        lhs.id == rhs.id
    }
}

extension Artist: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
