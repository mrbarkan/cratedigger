import Foundation

public struct ArtworkAsset: Hashable, Sendable {
    public let source: ArtworkSource
    public let hash: String
    public let dimensions: ArtworkDimensions
    public let data: Data

    public init(source: ArtworkSource, hash: String, dimensions: ArtworkDimensions, data: Data) {
        self.source = source
        self.hash = hash
        self.dimensions = dimensions
        self.data = data
    }
}
