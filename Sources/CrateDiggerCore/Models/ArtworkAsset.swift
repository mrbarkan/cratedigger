import Foundation

public struct ArtworkAsset: Hashable, Codable, Sendable {
    public let source: ArtworkSource
    public let hash: String
    public let dimensions: ArtworkDimensions
    /// In-memory only. The raw bytes live in the on-disk `ArtworkStore` keyed by
    /// `hash`; they are deliberately NOT persisted in `.cdlib`/`.cdtracks` (that
    /// duplicated every cover per track and bloated the library to gigabytes).
    public let data: Data

    public init(source: ArtworkSource, hash: String, dimensions: ArtworkDimensions, data: Data) {
        self.source = source
        self.hash = hash
        self.dimensions = dimensions
        self.data = data
    }

    private enum CodingKeys: String, CodingKey { case source, hash, dimensions, data }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        source = try container.decode(ArtworkSource.self, forKey: .source)
        hash = try container.decode(String.self, forKey: .hash)
        dimensions = try container.decode(ArtworkDimensions.self, forKey: .dimensions)
        // Backward-compat: older crates embedded the bytes here. Read them when
        // present so a migration can move them into the ArtworkStore; new files
        // omit the key and decode to empty.
        data = (try? container.decodeIfPresent(Data.self, forKey: .data)) ?? Data()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(source, forKey: .source)
        try container.encode(hash, forKey: .hash)
        try container.encode(dimensions, forKey: .dimensions)
        // `data` intentionally omitted — it lives in the ArtworkStore by hash.
    }
}
