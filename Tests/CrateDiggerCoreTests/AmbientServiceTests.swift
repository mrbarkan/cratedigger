#if canImport(XCTest)
import Foundation
import XCTest
@testable import CrateDiggerCore

@MainActor
final class AmbientServiceTests: XCTestCase {

    // MARK: - Fakes

    private final class FakeEngine: AmbientEngine {
        let kind: AmbientEngineKind
        var onConfigurationChange: (@MainActor () -> Void)?
        var startError: Error?
        private(set) var startedConfigs: [AmbientEngineConfig] = []
        private(set) var stopCount = 0
        private(set) var gains: [Float] = []
        private(set) var lowCuts: [Bool] = []

        init(kind: AmbientEngineKind) { self.kind = kind }

        func start(_ config: AmbientEngineConfig) throws {
            if let startError { throw startError }
            startedConfigs.append(config)
        }
        func stop() { stopCount += 1 }
        func setGain(_ gain: Float) { gains.append(gain) }
        func setLowCut(_ enabled: Bool) { lowCuts.append(enabled) }
    }

    private final class FakeDevices: AmbientDeviceProviding {
        var inputs: [AudioDeviceSummary] = []
        var defaultInputUID: String?
        var outputs: [AudioDeviceSummary] = []
        var defaultOutputUID: String?

        func input(uid: String?) -> AudioDeviceSummary? {
            let wanted = uid ?? defaultInputUID
            return inputs.first { $0.uid == wanted }
        }
        func output(uid: String?) -> AudioDeviceSummary? {
            let wanted = uid ?? defaultOutputUID
            return outputs.first { $0.uid == wanted }
        }
        func allInputs() -> [AudioDeviceSummary] { inputs }
    }

    private struct DeviceBusy: LocalizedError {
        var errorDescription: String? { "device busy" }
    }

    // MARK: - Fixtures

    private let macMic = AudioDeviceSummary(id: 1, uid: "BuiltInMicrophoneDevice",
                                            name: "MacBook Pro Microphone", transport: .builtIn)
    private let usbMic = AudioDeviceSummary(id: 2, uid: "USB-Yeti", name: "Yeti", transport: .usb)
    private let speakers = AudioDeviceSummary(id: 3, uid: "BuiltInSpeakerDevice", name: "MacBook Pro Speakers",
                                              transport: .builtIn, isBuiltInSpeaker: true)
    private let headsetOut = AudioDeviceSummary(id: 4, uid: "AC-80:output", name: "WH-1000XM5", transport: .bluetooth)
    private let headsetIn = AudioDeviceSummary(id: 5, uid: "AC-80:input", name: "WH-1000XM5", transport: .bluetooth)
    private let usbDAC = AudioDeviceSummary(id: 6, uid: "USB-DAC", name: "FiiO K5", transport: .usb)

    private var devices = FakeDevices()
    private var engines: [FakeEngine] = []
    private var stops: [AmbientService.StopReason] = []
    private var nextStartError: Error?

    private func makeService(settings: AmbientSettings = .defaults, granted: Bool = true) -> AmbientService {
        devices = FakeDevices()
        devices.inputs = [macMic, usbMic, headsetIn]
        devices.defaultInputUID = macMic.uid
        devices.outputs = [speakers, headsetOut, usbDAC]
        devices.defaultOutputUID = headsetOut.uid
        engines = []
        stops = []
        let service = AmbientService(
            settings: settings,
            devices: devices,
            authorize: { granted },
            makeEngine: { [unowned self] kind in
                let engine = FakeEngine(kind: kind)
                engine.startError = self.nextStartError
                self.engines.append(engine)
                return engine
            }
        )
        service.onStop = { [unowned self] reason in self.stops.append(reason) }
        return service
    }

    // MARK: - Turning on

    func testTurningOnStartsTheEngineOnTheMicAndTheMusicsOutput() async throws {
        let service = makeService()
        let result = await service.turnOn(outputUID: headsetOut.uid)

        XCTAssertEqual(result, .started(inputName: macMic.name))
        XCTAssertEqual(service.state, .running(inputName: macMic.name))
        XCTAssertEqual(engines.count, 1)
        XCTAssertEqual(engines[0].kind, .split)
        let config = try XCTUnwrap(engines[0].startedConfigs.first)
        XCTAssertEqual(config.input, macMic)
        XCTAssertEqual(config.output, headsetOut)
        XCTAssertEqual(config.delaySeconds, AmbientDelay.balanced.seconds)
        XCTAssertEqual(config.gain, 1, accuracy: 0.001)
        XCTAssertTrue(config.lowCut)
    }

    func testNilOutputMeansTheSystemDefaultOutput() async throws {
        let service = makeService()
        _ = await service.turnOn(outputUID: nil)
        XCTAssertEqual(try XCTUnwrap(engines.first?.startedConfigs.first).output, headsetOut)
    }

    func testPermissionDeniedLeavesItOffWithNoEngine() async {
        let service = makeService(granted: false)
        let result = await service.turnOn(outputUID: headsetOut.uid)
        XCTAssertEqual(result, .permissionDenied)
        XCTAssertEqual(service.state, .off)
        XCTAssertTrue(engines.isEmpty)
    }

    func testBuiltInSpeakersAreRefused() async {
        let service = makeService()
        let result = await service.turnOn(outputUID: speakers.uid)
        XCTAssertEqual(result, .blockedBySpeakers)
        XCTAssertEqual(service.state, .off)
        XCTAssertTrue(engines.isEmpty)
    }

    func testTheHeadsetsOwnMicWaitsForApproval() async {
        var settings = AmbientSettings.defaults
        settings.inputUID = headsetIn.uid
        let service = makeService(settings: settings)

        let first = await service.turnOn(outputUID: headsetOut.uid)
        XCTAssertEqual(first, .needsCallModeApproval(deviceName: headsetIn.name, deviceUID: headsetIn.uid))
        XCTAssertEqual(service.state, .off)
        XCTAssertTrue(engines.isEmpty)

        settings.callModeApprovedUIDs = [headsetIn.uid]
        service.update(settings)
        let second = await service.turnOn(outputUID: headsetOut.uid)
        XCTAssertEqual(second, .started(inputName: headsetIn.name))
    }

    func testNoInputAtAll() async {
        let service = makeService()
        devices.inputs = []
        let result = await service.turnOn(outputUID: headsetOut.uid)
        XCTAssertEqual(result, .noInput)
        XCTAssertEqual(service.state, .off)
    }

    /// A saved mic that is not plugged in falls back to the system default
    /// rather than refusing, the way the picker shows it.
    func testAMissingSavedMicFallsBackToTheDefault() async {
        var settings = AmbientSettings.defaults
        settings.inputUID = "Unplugged-Mic"
        let service = makeService(settings: settings)
        let result = await service.turnOn(outputUID: headsetOut.uid)
        XCTAssertEqual(result, .started(inputName: macMic.name))
    }

    func testAnEngineThatFailsToStartLeavesItOff() async {
        nextStartError = DeviceBusy()
        defer { nextStartError = nil }
        let service = makeService()
        let result = await service.turnOn(outputUID: headsetOut.uid)
        XCTAssertEqual(result, .failed("device busy"))
        XCTAssertEqual(service.state, .off)
    }

    func testTurningOffStopsTheEngine() async {
        let service = makeService()
        _ = await service.turnOn(outputUID: headsetOut.uid)
        service.turnOff()
        XCTAssertEqual(service.state, .off)
        XCTAssertEqual(engines[0].stopCount, 1)
    }

    // MARK: - Changes while running

    func testLevelAndLowCutApplyLiveWithoutARebuild() async throws {
        let service = makeService()
        _ = await service.turnOn(outputUID: headsetOut.uid)

        var settings = service.settings
        settings.level = 1
        settings.lowCut = false
        service.update(settings)

        XCTAssertEqual(engines.count, 1)
        XCTAssertEqual(engines[0].stopCount, 0)
        XCTAssertEqual(try XCTUnwrap(engines[0].gains.last), Float(AmbientLevelCurve.amplitude(forPosition: 1)),
                       accuracy: 0.001)
        XCTAssertEqual(engines[0].lowCuts.last, false)
    }

    func testSwitchingEnginesRebuildsWithTheOtherEngine() async {
        let service = makeService()
        _ = await service.turnOn(outputUID: headsetOut.uid)

        var settings = service.settings
        settings.engine = .combined
        service.update(settings)

        XCTAssertEqual(engines.count, 2)
        XCTAssertEqual(engines[0].stopCount, 1)
        XCTAssertEqual(engines[1].kind, .combined)
        XCTAssertEqual(engines[1].startedConfigs.count, 1)
        XCTAssertEqual(service.state, .running(inputName: macMic.name))
    }

    func testChangingTheDelayOrMicRebuilds() async throws {
        let service = makeService()
        _ = await service.turnOn(outputUID: headsetOut.uid)

        var settings = service.settings
        settings.delay = .smooth
        settings.inputUID = usbMic.uid
        service.update(settings)

        let config = try XCTUnwrap(engines.last?.startedConfigs.first)
        XCTAssertEqual(config.delaySeconds, AmbientDelay.smooth.seconds)
        XCTAssertEqual(config.input, usbMic)
        XCTAssertEqual(service.state, .running(inputName: usbMic.name))
    }

    func testSettingsChangedWhileOffDoNotStartAnything() {
        let service = makeService()
        var settings = service.settings
        settings.engine = .combined
        service.update(settings)
        XCTAssertEqual(service.settings.engine, .combined)
        XCTAssertTrue(engines.isEmpty)
        XCTAssertEqual(service.state, .off)
    }

    func testAnOutputChangeRebuildsOnTheNewDevice() async throws {
        let service = makeService()
        _ = await service.turnOn(outputUID: headsetOut.uid)

        service.outputDeviceChanged(to: usbDAC.uid)

        XCTAssertEqual(engines[0].stopCount, 1)
        XCTAssertEqual(try XCTUnwrap(engines.last?.startedConfigs.first).output, usbDAC)
        XCTAssertTrue(stops.isEmpty)
    }

    func testSwitchingTheMusicToSpeakersTurnsItOff() async {
        let service = makeService()
        _ = await service.turnOn(outputUID: headsetOut.uid)

        service.outputDeviceChanged(to: speakers.uid)

        XCTAssertEqual(service.state, .off)
        XCTAssertEqual(stops, [.blockedBySpeakers])
        XCTAssertEqual(engines.count, 1, "no engine may start on the speakers")
    }

    func testAnUnpluggedMicTurnsItOff() async {
        var settings = AmbientSettings.defaults
        settings.inputUID = usbMic.uid
        let service = makeService(settings: settings)
        _ = await service.turnOn(outputUID: headsetOut.uid)

        devices.inputs.removeAll { $0.uid == usbMic.uid }
        service.devicesChanged()

        XCTAssertEqual(service.state, .off)
        XCTAssertEqual(stops, [.inputDisconnected])
        XCTAssertEqual(engines[0].stopCount, 1)
    }

    func testDevicesChangingWithTheMicStillPresentLeavesItRunning() async {
        let service = makeService()
        _ = await service.turnOn(outputUID: headsetOut.uid)
        service.devicesChanged()
        XCTAssertEqual(service.state, .running(inputName: macMic.name))
        XCTAssertEqual(engines.count, 1)
    }

    func testAConfigurationChangeRebuilds() async {
        let service = makeService()
        _ = await service.turnOn(outputUID: headsetOut.uid)

        engines[0].onConfigurationChange?()

        XCTAssertEqual(engines[0].stopCount, 1)
        XCTAssertEqual(engines.count, 2)
        XCTAssertEqual(service.state, .running(inputName: macMic.name))
    }

    func testARebuildThatFailsTurnsItOff() async {
        let service = makeService()
        _ = await service.turnOn(outputUID: headsetOut.uid)

        nextStartError = DeviceBusy()
        defer { nextStartError = nil }
        service.outputDeviceChanged(to: usbDAC.uid)

        XCTAssertEqual(service.state, .off)
        XCTAssertEqual(stops, [.failed("device busy")])
    }

    /// Starting an engine makes the hardware report a change of its own (probed
    /// on a UGREEN Bluetooth receiver: every start posted one), and each rebuild
    /// is another start. Past a few rebuilds in quick succession Ambient must turn
    /// off and say why, instead of rebuilding forever with the app frozen.
    func testConfigurationChangesThatKeepComingTurnItOffInsteadOfLooping() async {
        let service = makeService()
        _ = await service.turnOn(outputUID: headsetOut.uid)

        for _ in 0..<10 { engines.last?.onConfigurationChange?() }

        XCTAssertEqual(service.state, .off)
        XCTAssertEqual(stops.count, 1)
        guard case .failed = stops.first else {
            return XCTFail("expected Ambient to stop with a reason, got \(stops)")
        }
        XCTAssertLessThanOrEqual(engines.count, 4, "the first start plus at most three rebuilds")
    }

    // MARK: - Which mic "System Default" means

    /// A Bluetooth receiver is often the system's default input as well as its
    /// output (probed: a UGREEN receiver was both). "System Default" must not
    /// quietly open that mic, which drops the music to call quality; it uses the
    /// Mac's microphone instead, without asking.
    func testSystemDefaultPrefersTheMacMicWhenTheDefaultInputIsTheHeadset() async throws {
        let service = makeService()
        devices.defaultInputUID = headsetIn.uid

        let result = await service.turnOn(outputUID: headsetOut.uid)

        XCTAssertEqual(result, .started(inputName: macMic.name))
        XCTAssertEqual(try XCTUnwrap(engines.first?.startedConfigs.first).input, macMic)
    }

    /// With no built-in mic to fall back on, System Default asks the same
    /// question a named choice of the headset's mic does.
    func testSystemDefaultAsksAboutTheHeadsetMicWhenThereIsNoMacMic() async {
        let service = makeService()
        devices.defaultInputUID = headsetIn.uid
        devices.inputs.removeAll { $0.uid == macMic.uid }

        let result = await service.turnOn(outputUID: headsetOut.uid)

        XCTAssertEqual(result, .needsCallModeApproval(deviceName: headsetIn.name, deviceUID: headsetIn.uid))
    }

    // MARK: - Bit-perfect DSD

    func testBitPerfectDSDPausesAndResumes() async {
        let service = makeService()
        _ = await service.turnOn(outputUID: headsetOut.uid)

        service.setBitPerfectDSDActive(true)
        XCTAssertEqual(service.state, .paused)
        XCTAssertEqual(engines[0].stopCount, 1)

        service.setBitPerfectDSDActive(false)
        XCTAssertEqual(service.state, .running(inputName: macMic.name))
        XCTAssertEqual(engines.count, 2)
    }

    func testTurningOnDuringBitPerfectDSDWaitsPaused() async {
        let service = makeService()
        service.setBitPerfectDSDActive(true)

        let result = await service.turnOn(outputUID: headsetOut.uid)

        XCTAssertEqual(result, .started(inputName: macMic.name))
        XCTAssertEqual(service.state, .paused)
        XCTAssertTrue(engines.isEmpty)
    }

    func testTurningOffWhilePausedStaysOffWhenDSDEnds() async {
        let service = makeService()
        _ = await service.turnOn(outputUID: headsetOut.uid)
        service.setBitPerfectDSDActive(true)
        service.turnOff()
        service.setBitPerfectDSDActive(false)
        XCTAssertEqual(service.state, .off)
        XCTAssertEqual(engines.count, 1)
    }

    func testStateChangesAreReported() async {
        let service = makeService()
        var seen: [AmbientService.State] = []
        service.onStateChange = { seen.append($0) }
        _ = await service.turnOn(outputUID: headsetOut.uid)
        service.turnOff()
        XCTAssertEqual(seen, [.running(inputName: macMic.name), .off])
    }
}
#endif
