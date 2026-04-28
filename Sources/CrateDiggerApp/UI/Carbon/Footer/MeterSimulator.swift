import Combine
import Foundation

@MainActor
final class MeterSimulator: ObservableObject {
    @Published private(set) var leftLevel: Double = 0
    @Published private(set) var rightLevel: Double = 0

    private var timer: Timer?
    private var lastUpdate: Date = Date()

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        leftLevel = 0
        rightLevel = 0
    }

    private func tick() {
        let elapsed = Date().timeIntervalSince(lastUpdate)
        lastUpdate = Date()

        let ll = pseudoEnvelope(seed: 0.7, t: Date().timeIntervalSinceReferenceDate)
        let rl = pseudoEnvelope(seed: 0.31, t: Date().timeIntervalSinceReferenceDate + 0.2)

        leftLevel  = decay(current: leftLevel, target: ll, dt: elapsed)
        rightLevel = decay(current: rightLevel, target: rl, dt: elapsed)
    }

    private func pseudoEnvelope(seed: Double, t: TimeInterval) -> Double {
        let a = sin(t * 4.7  + seed * 1.3)
        let b = sin(t * 9.3  + seed * 2.7) * 0.6
        let c = sin(t * 13.1 + seed * 0.4) * 0.3
        let raw = (a + b + c) * 0.4 + 0.5
        return min(max(raw, 0.05), 0.98)
    }

    private func decay(current: Double, target: Double, dt: TimeInterval) -> Double {
        if target > current { return min(target, current + dt * 5.0) }
        return max(target, current - dt * 1.5)
    }
}
