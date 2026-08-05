import Foundation

/// How playback should wind down on its own.
///
/// Two shapes of timer live here: `after(minutes:)` is wall-clock and resolves
/// to a deadline, while `endOfTrack` / `endOfQueue` are event-driven and have no
/// deadline at all — they wait for playback itself to reach a boundary. Keeping
/// both in one type is what lets the UI show a single "SLEEP" state.
public enum SleepMode: Equatable, Hashable, Sendable, Codable {
    case off
    /// Stop once this many minutes of wall-clock time have passed.
    case after(minutes: Int)
    /// Stop when the playing track finishes.
    case endOfTrack
    /// Stop when the queue runs out — "after this album / playlist".
    case endOfQueue

    public var isArmed: Bool { self != .off }

    /// Nil for the event-driven modes: they can't be predicted from the clock.
    public func deadline(from start: Date) -> Date? {
        guard case .after(let minutes) = self, minutes > 0 else { return nil }
        return start.addingTimeInterval(TimeInterval(minutes) * 60)
    }

    /// Whole seconds left, floored at zero. Nil when there is no deadline to
    /// count down — the caller shows the mode's label instead of a clock.
    public func remainingSeconds(now: Date, start: Date) -> Int? {
        guard let deadline = deadline(from: start) else { return nil }
        return max(0, Int(deadline.timeIntervalSince(now).rounded(.up)))
    }

    public func hasElapsed(now: Date, start: Date) -> Bool {
        guard let deadline = deadline(from: start) else { return false }
        return now >= deadline
    }

    /// Short label for the OLED / menu — a countdown for timed modes, the
    /// boundary's name for the event-driven ones.
    public func statusLabel(now: Date, start: Date) -> String? {
        switch self {
        case .off:
            return nil
        case .after:
            guard let remaining = remainingSeconds(now: now, start: start) else { return nil }
            return Self.clockLabel(remaining)
        case .endOfTrack:
            return "END OF TRACK"
        case .endOfQueue:
            return "END OF QUEUE"
        }
    }

    /// `m:ss` under an hour, `h:mm:ss` above it.
    public static func clockLabel(_ seconds: Int) -> String {
        let safe = max(0, seconds)
        let minutes = safe / 60
        return minutes >= 60
            ? String(format: "%d:%02d:%02d", minutes / 60, minutes % 60, safe % 60)
            : String(format: "%d:%02d", minutes, safe % 60)
    }

    /// The menu's fixed offerings, in order.
    public static let presetMinutes = [15, 30, 45, 60, 90]

    public var menuTitle: String {
        switch self {
        case .off:                  return "Off"
        case .after(let minutes):   return "\(minutes) Minutes"
        case .endOfTrack:           return "After This Track"
        case .endOfQueue:           return "After This Album / Playlist"
        }
    }
}
