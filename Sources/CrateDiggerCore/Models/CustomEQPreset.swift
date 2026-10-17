import Foundation

/// One user EQ slot: a name and the 12 band gains it stores. An empty `gains`
/// means the slot has never been saved into, which is what the editor shows as
/// a dashed "empty" key.
public struct CustomEQPreset: Codable, Sendable, Equatable {
    /// How many slots the editor offers. Fixed — one full row of keys under
    /// the six built-ins reads as hardware, an unbounded list reads as a file
    /// browser. Raising it is safe: `PreferencesStore.customEQPresets` pads a
    /// shorter stored list with empty slots, and an older build reads only the
    /// slots it knows.
    public static let slotCount = 6

    public var name: String
    public var gains: [Double]

    public init(name: String, gains: [Double] = []) {
        self.name = name
        self.gains = gains
    }

    public var isEmpty: Bool { gains.isEmpty }

    /// The default, never-saved slots.
    public static var emptySlots: [CustomEQPreset] {
        (1...slotCount).map { CustomEQPreset(name: "USER \($0)") }
    }
}
