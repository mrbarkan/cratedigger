import Foundation

/// How long the room's sound waits before it plays: the trade between feeling
/// live and never crackling. Bluetooth output usually wants more slack.
public enum AmbientDelay: String, Codable, CaseIterable, Sendable {
    case live, balanced, smooth

    public var seconds: Double {
        switch self {
        case .live: return 0.010
        case .balanced: return 0.030
        case .smooth: return 0.080
        }
    }

    public var title: String {
        switch self {
        case .live: return "Live"
        case .balanced: return "Balanced"
        case .smooth: return "Smooth"
        }
    }
}

/// Which audio path carries the microphone to the output. Both are offered so
/// a listener can pick whichever sounds better on their hardware.
public enum AmbientEngineKind: String, Codable, CaseIterable, Sendable {
    /// Two engines, one per device, joined by `AmbientRingBuffer`.
    case split
    /// One engine on a private aggregate of the two devices; macOS handles drift.
    case combined

    public var title: String {
        switch self {
        case .split: return "Split"
        case .combined: return "Combined"
        }
    }
}

/// Everything about Ambient that survives a relaunch. Whether it is on does
/// not: it always starts off, so the mic indicator never lights by surprise.
public struct AmbientSettings: Codable, Equatable, Sendable {
    /// nil follows the system default input.
    public var inputUID: String?
    /// AMBIENT fader position, 0…1 (see `AmbientLevelCurve`).
    public var level: Double
    public var delay: AmbientDelay
    public var lowCut: Bool
    public var engine: AmbientEngineKind
    /// Bluetooth mics the listener chose to use anyway, knowing the headset
    /// drops to call quality while Ambient is on.
    public var callModeApprovedUIDs: Set<String>

    public static let defaults = AmbientSettings(
        inputUID: nil,
        level: AmbientLevelCurve.unityPosition,
        delay: .balanced,
        lowCut: true,
        engine: .split,
        callModeApprovedUIDs: []
    )

    private enum CodingKeys: String, CodingKey {
        case inputUID, level, delay, lowCut, engine, callModeApprovedUIDs
    }
}

extension AmbientSettings {
    /// Missing fields take their default, so a blob saved by a build that knew
    /// fewer settings keeps the ones it has.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = AmbientSettings.defaults
        self.init(
            inputUID: try container.decodeIfPresent(String.self, forKey: .inputUID),
            level: try container.decodeIfPresent(Double.self, forKey: .level) ?? fallback.level,
            delay: try container.decodeIfPresent(AmbientDelay.self, forKey: .delay) ?? fallback.delay,
            lowCut: try container.decodeIfPresent(Bool.self, forKey: .lowCut) ?? fallback.lowCut,
            engine: try container.decodeIfPresent(AmbientEngineKind.self, forKey: .engine) ?? fallback.engine,
            callModeApprovedUIDs: try container.decodeIfPresent(Set<String>.self, forKey: .callModeApprovedUIDs)
                ?? fallback.callModeApprovedUIDs
        )
    }
}
