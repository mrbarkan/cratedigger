import CrateDiggerCore
import SwiftUI

/// Shared helpers for the folder-token-order pickers used by both the conversion
/// options sheet and the external-device profile editor. Both keep a
/// fixed-length token list, drop duplicate non-disabled tokens (substituting the
/// next unused token from the pool), and pad the tail with `.disabled`.
enum FolderTokenOrder {
    static let tokenCount = 5

    static func normalize(_ order: [FolderToken]) -> [FolderToken] {
        var normalized: [FolderToken] = []
        var used: Set<FolderToken> = []
        let pool: [FolderToken] = [.year, .albumArtist, .album, .compilation]

        for token in order.prefix(tokenCount) {
            if token == .disabled {
                normalized.append(.disabled)
            } else if used.insert(token).inserted {
                normalized.append(token)
            } else if let fallback = pool.first(where: { !used.contains($0) }) {
                normalized.append(fallback)
                used.insert(fallback)
            } else {
                normalized.append(.disabled)
            }
        }

        while normalized.count < tokenCount {
            normalized.append(.disabled)
        }
        return normalized
    }

    /// A binding for the token at `index` within `order`, normalizing the whole
    /// list on every edit so duplicates and length stay consistent.
    static func tokenBinding(in order: Binding<[FolderToken]>, at index: Int) -> Binding<FolderToken> {
        Binding(
            get: {
                guard order.wrappedValue.indices.contains(index) else { return .disabled }
                return order.wrappedValue[index]
            },
            set: { newValue in
                var next = order.wrappedValue
                if next.count < tokenCount {
                    next.append(contentsOf: Array(repeating: .disabled, count: tokenCount - next.count))
                }
                guard next.indices.contains(index) else { return }
                next[index] = newValue
                order.wrappedValue = normalize(next)
            }
        )
    }
}
