import CoreAudio
import Foundation

/// What an Ambient engine needs to carry one mic into one output.
public struct AmbientEngineConfig: Equatable, Sendable {
    public let input: AudioDeviceSummary
    public let output: AudioDeviceSummary
    public let delaySeconds: Double
    /// Linear, from `AmbientLevelCurve`. May exceed 1.
    public let gain: Float
    public let lowCut: Bool

    public init(input: AudioDeviceSummary, output: AudioDeviceSummary, delaySeconds: Double,
                gain: Float, lowCut: Bool) {
        self.input = input
        self.output = output
        self.delaySeconds = delaySeconds
        self.gain = gain
        self.lowCut = lowCut
    }
}

/// One way of getting the microphone to the output. `AmbientService` owns the
/// lifecycle; an engine only starts, stops and takes live adjustments.
@MainActor
public protocol AmbientEngine: AnyObject {
    /// Called on the main actor when the hardware reconfigures under a running
    /// engine (a format change, a Bluetooth reconnect). The service rebuilds.
    var onConfigurationChange: (@MainActor () -> Void)? { get set }
    func start(_ config: AmbientEngineConfig) throws
    func stop()
    func setGain(_ gain: Float)
    func setLowCut(_ enabled: Bool)
}

/// Resolves device UIDs to summaries. A nil UID means the system default for
/// that direction; an unknown one returns nil.
public protocol AmbientDeviceProviding: AnyObject {
    func input(uid: String?) -> AudioDeviceSummary?
    func output(uid: String?) -> AudioDeviceSummary?
    /// Every input connected right now, for finding the Mac's own mic.
    func allInputs() -> [AudioDeviceSummary]
}

/// Ambient's state machine: which mic, which output, whether it may run, and
/// what to do when any of that changes underneath it.
///
/// Everything a listener can hear go wrong is decided here rather than in the
/// view model, so it is covered by `AmbientServiceTests` with a fake engine.
@MainActor
public final class AmbientService {

    public enum State: Equatable, Sendable {
        case off
        case running(inputName: String)
        /// On, but held back while bit-perfect DSD owns the output.
        case paused
    }

    public enum StartResult: Equatable, Sendable {
        case started(inputName: String)
        case permissionDenied
        case noInput
        case blockedBySpeakers
        case needsCallModeApproval(deviceName: String, deviceUID: String)
        case failed(String)
    }

    /// Why Ambient turned itself off, for the notice on the screen.
    public enum StopReason: Equatable, Sendable {
        case inputDisconnected
        case blockedBySpeakers
        case needsCallModeApproval(deviceName: String, deviceUID: String)
        case failed(String)
    }

    public private(set) var state: State = .off {
        didSet { if state != oldValue { onStateChange?(state) } }
    }
    public private(set) var settings: AmbientSettings
    public var onStateChange: ((State) -> Void)?
    public var onStop: ((StopReason) -> Void)?

    private let devices: AmbientDeviceProviding
    private let authorize: () async -> Bool
    private let makeEngine: (AmbientEngineKind) -> AmbientEngine
    private var engine: AmbientEngine?
    /// The output the music plays through. nil is the system default.
    private var outputUID: String?
    /// The mic the engine was last started on, so an unplug is noticed even
    /// when the saved setting is "system default".
    private var runningInputUID: String?
    private var bitPerfectDSDActive = false
    /// When each recent rebuild caused by the hardware reporting a change
    /// happened. Starting an engine can make the hardware report one of its own
    /// (probed on a Bluetooth receiver: every start did), so without a limit
    /// each rebuild set off the next and the app froze.
    private var hardwareRebuilds: [Date] = []
    private let now: () -> Date

    static let hardwareRebuildLimit = 3
    static let hardwareRebuildWindow: TimeInterval = 10
    static let keptReconfiguringMessage =
        "Your audio devices kept reconfiguring, so Ambient turned off to keep CrateDigger responsive. "
        + "A Bluetooth headset's own microphone is the usual cause; the Mac's microphone avoids it."

    public init(settings: AmbientSettings,
                devices: AmbientDeviceProviding,
                authorize: @escaping () async -> Bool,
                makeEngine: @escaping (AmbientEngineKind) -> AmbientEngine,
                now: @escaping () -> Date = Date.init) {
        self.settings = settings
        self.devices = devices
        self.authorize = authorize
        self.makeEngine = makeEngine
        self.now = now
    }

    // MARK: - Switching

    public func turnOn(outputUID: String?) async -> StartResult {
        self.outputUID = outputUID
        guard await authorize() else { return .permissionDenied }

        switch resolve() {
        case .failure(let refusal):
            return refusal.startResult
        case .success(let config):
            if bitPerfectDSDActive {
                runningInputUID = config.input.uid
                state = .paused
                return .started(inputName: config.input.name)
            }
            do {
                try launch(config)
                return .started(inputName: config.input.name)
            } catch {
                return .failed(error.localizedDescription)
            }
        }
    }

    public func turnOff() {
        teardown()
        runningInputUID = nil
        state = .off
    }

    // MARK: - Changes

    /// Level and low cut apply to the running engine; a new mic, delay or
    /// engine rebuilds it. While off, the settings are only remembered.
    public func update(_ newSettings: AmbientSettings) {
        let old = settings
        settings = newSettings
        guard case .running = state, let engine else { return }

        if old.inputUID != newSettings.inputUID || old.delay != newSettings.delay
            || old.engine != newSettings.engine {
            rebuild()
            return
        }
        if old.level != newSettings.level {
            engine.setGain(Self.gain(forLevel: newSettings.level))
        }
        if old.lowCut != newSettings.lowCut {
            engine.setLowCut(newSettings.lowCut)
        }
    }

    /// The music moved to another output. Follow it, or stop if it moved to
    /// the speakers.
    public func outputDeviceChanged(to uid: String?) {
        outputUID = uid
        rebuild()
    }

    /// Devices were added or removed. Only the loss of the mic in use matters.
    public func devicesChanged() {
        guard state != .off, let runningInputUID else { return }
        if devices.input(uid: runningInputUID) == nil {
            stop(because: .inputDisconnected)
        }
    }

    /// Bit-perfect DSD must be the only thing on its output: mixing the mic in
    /// would corrupt the DoP markers and the DAC would play static.
    public func setBitPerfectDSDActive(_ active: Bool) {
        guard active != bitPerfectDSDActive else { return }
        bitPerfectDSDActive = active
        if active {
            guard case .running = state else { return }
            teardown()
            state = .paused
        } else if state == .paused {
            restart()
        }
    }

    // MARK: - Plumbing

    private enum Refusal: Error {
        case noInput
        case noOutput
        case speakers
        case callMode(name: String, uid: String)

        var startResult: StartResult {
            switch self {
            case .noInput: return .noInput
            case .noOutput: return .failed(Self.noOutputMessage)
            case .speakers: return .blockedBySpeakers
            case .callMode(let name, let uid): return .needsCallModeApproval(deviceName: name, deviceUID: uid)
            }
        }

        var stopReason: StopReason {
            switch self {
            case .noInput: return .inputDisconnected
            case .noOutput: return .failed(Self.noOutputMessage)
            case .speakers: return .blockedBySpeakers
            case .callMode(let name, let uid): return .needsCallModeApproval(deviceName: name, deviceUID: uid)
            }
        }

        private static let noOutputMessage = "No audio output is available."
    }

    private static func gain(forLevel level: Double) -> Float {
        Float(AmbientLevelCurve.amplitude(forPosition: level))
    }

    /// The devices and settings as they are right now, or why they can't run.
    private func resolve() -> Result<AmbientEngineConfig, Refusal> {
        guard let output = devices.output(uid: outputUID) ?? devices.output(uid: nil) else {
            return .failure(.noOutput)
        }
        guard let input = chooseInput(for: output) else {
            return .failure(.noInput)
        }
        switch AmbientPolicy.verdict(input: input, output: output,
                                     approvedCallModeUIDs: settings.callModeApprovedUIDs) {
        case .blockedBySpeakers: return .failure(.speakers)
        case .needsCallModeApproval: return .failure(.callMode(name: input.name, uid: input.uid))
        case .ok: break
        }
        return .success(AmbientEngineConfig(input: input, output: output,
                                            delaySeconds: settings.delay.seconds,
                                            gain: Self.gain(forLevel: settings.level),
                                            lowCut: settings.lowCut))
    }

    /// The saved mic while it is plugged in. Otherwise the system default,
    /// except that the default may not be the headset the music plays through
    /// when the Mac has a mic of its own: a Bluetooth receiver is often both the
    /// default input and the output (probed on a UGREEN), and opening its mic
    /// drops the music to call quality without anyone having chosen that.
    /// Picking the headset's mic by name still gets the question.
    private func chooseInput(for output: AudioDeviceSummary) -> AudioDeviceSummary? {
        if let uid = settings.inputUID, let saved = devices.input(uid: uid) {
            return saved
        }
        guard let systemDefault = devices.input(uid: nil) else { return nil }
        let defaultIsTheHeadset = AmbientPolicy.verdict(input: systemDefault, output: output,
                                                        approvedCallModeUIDs: []) == .needsCallModeApproval
        guard defaultIsTheHeadset,
              let builtIn = devices.allInputs().first(where: { $0.transport == .builtIn }) else {
            return systemDefault
        }
        return builtIn
    }

    private func launch(_ config: AmbientEngineConfig) throws {
        // A session starting from off gets a fresh rebuild allowance.
        if state == .off { hardwareRebuilds.removeAll() }
        teardown()
        let engine = makeEngine(settings.engine)
        engine.onConfigurationChange = { [weak self] in self?.hardwareReconfigured() }
        do {
            try engine.start(config)
        } catch {
            engine.stop()
            state = .off
            throw error
        }
        self.engine = engine
        runningInputUID = config.input.uid
        state = .running(inputName: config.input.name)
    }

    private func rebuild() {
        guard case .running = state else { return }
        restart()
    }

    /// The hardware reported a change under a running engine. Rebuild, unless
    /// that has already happened `hardwareRebuildLimit` times inside
    /// `hardwareRebuildWindow`: by then the rebuilds are feeding themselves,
    /// and turning off with a reason beats freezing the app.
    private func hardwareReconfigured() {
        guard case .running = state else { return }
        let current = now()
        hardwareRebuilds.removeAll { current.timeIntervalSince($0) > Self.hardwareRebuildWindow }
        guard hardwareRebuilds.count < Self.hardwareRebuildLimit else {
            stop(because: .failed(Self.keptReconfiguringMessage))
            return
        }
        hardwareRebuilds.append(current)
        restart()
    }

    /// Start again on the current devices and settings, or turn off saying why.
    private func restart() {
        switch resolve() {
        case .failure(let refusal):
            stop(because: refusal.stopReason)
        case .success(let config):
            do {
                try launch(config)
            } catch {
                stop(because: .failed(error.localizedDescription))
            }
        }
    }

    private func stop(because reason: StopReason) {
        teardown()
        runningInputUID = nil
        state = .off
        onStop?(reason)
    }

    private func teardown() {
        engine?.onConfigurationChange = nil
        engine?.stop()
        engine = nil
    }
}
