#if canImport(XCTest)
import CoreAudio
import Foundation
import XCTest
@testable import CrateDiggerCore

final class AmbientPolicyTests: XCTestCase {

    private let macMic = AudioDeviceSummary(id: 1, uid: "BuiltInMicrophoneDevice",
                                            name: "MacBook Pro Microphone", transport: .builtIn)
    private let speakers = AudioDeviceSummary(id: 2, uid: "BuiltInSpeakerDevice",
                                              name: "MacBook Pro Speakers", transport: .builtIn,
                                              isBuiltInSpeaker: true)
    private let headphoneJack = AudioDeviceSummary(id: 3, uid: "BuiltInHeadphoneOutputDevice",
                                                   name: "External Headphones", transport: .builtIn)
    private let headsetOut = AudioDeviceSummary(id: 4, uid: "AC-80-0A-11-22-33:output",
                                                name: "WH-1000XM5", transport: .bluetooth)
    private let headsetIn = AudioDeviceSummary(id: 5, uid: "AC-80-0A-11-22-33:input",
                                               name: "WH-1000XM5", transport: .bluetooth)
    private let otherBluetoothMic = AudioDeviceSummary(id: 6, uid: "F0-99-B6-44-55-66:input",
                                                       name: "AirPods", transport: .bluetooth)

    private func fourCC(_ code: String) -> UInt32 {
        code.utf8.reduce(0) { $0 << 8 | UInt32($1) }
    }

    // MARK: - Device classification

    func testCoreAudioTransportTypesMapToWhatThePolicyCaresAbout() {
        XCTAssertEqual(AudioTransport(coreAudioTransportType: kAudioDeviceTransportTypeBuiltIn), .builtIn)
        XCTAssertEqual(AudioTransport(coreAudioTransportType: kAudioDeviceTransportTypeBluetooth), .bluetooth)
        XCTAssertEqual(AudioTransport(coreAudioTransportType: kAudioDeviceTransportTypeBluetoothLE), .bluetooth)
        XCTAssertEqual(AudioTransport(coreAudioTransportType: kAudioDeviceTransportTypeUSB), .usb)
        XCTAssertEqual(AudioTransport(coreAudioTransportType: kAudioDeviceTransportTypeAirPlay), .other)
    }

    /// Only an explicit internal-speaker data source counts. A MacBook Pro's
    /// speakers report `ispk` (probed on a Mac16,8). A built-in output that
    /// reports nothing is let through: blocking it would risk refusing the
    /// headphone jack, which is half of what this feature is for.
    func testBuiltInOutputIsASpeakerOnlyWhenItSaysSo() {
        XCTAssertTrue(AudioDeviceSummary.isBuiltInSpeaker(transport: .builtIn, outputDataSource: fourCC("ispk")))
        XCTAssertFalse(AudioDeviceSummary.isBuiltInSpeaker(transport: .builtIn, outputDataSource: fourCC("hdpn")))
        XCTAssertFalse(AudioDeviceSummary.isBuiltInSpeaker(transport: .builtIn, outputDataSource: nil))
    }

    /// External outputs can't be told apart from headphones, so they are never
    /// called speakers whatever they report.
    func testExternalOutputsAreNeverSpeakers() {
        XCTAssertFalse(AudioDeviceSummary.isBuiltInSpeaker(transport: .usb, outputDataSource: nil))
        XCTAssertFalse(AudioDeviceSummary.isBuiltInSpeaker(transport: .bluetooth, outputDataSource: fourCC("ispk")))
    }

    // MARK: - Verdicts

    func testBuiltInSpeakersAreRefused() {
        XCTAssertEqual(AmbientPolicy.verdict(input: macMic, output: speakers, approvedCallModeUIDs: []),
                       .blockedBySpeakers)
    }

    /// Howling beats call quality: speakers are refused even for a mic that
    /// would otherwise need approval.
    func testSpeakersAreRefusedBeforeCallModeIsConsidered() {
        XCTAssertEqual(AmbientPolicy.verdict(input: headsetIn, output: speakers, approvedCallModeUIDs: []),
                       .blockedBySpeakers)
    }

    func testMacMicIntoTheHeadphoneJackIsFine() {
        XCTAssertEqual(AmbientPolicy.verdict(input: macMic, output: headphoneJack, approvedCallModeUIDs: []), .ok)
    }

    func testMacMicIntoBluetoothHeadphonesIsFine() {
        XCTAssertEqual(AmbientPolicy.verdict(input: macMic, output: headsetOut, approvedCallModeUIDs: []), .ok)
    }

    /// The headset's own mic flips it into call mode, which is what the music
    /// is playing through.
    func testTheHeadsetsOwnMicNeedsApproval() {
        XCTAssertEqual(AmbientPolicy.verdict(input: headsetIn, output: headsetOut, approvedCallModeUIDs: []),
                       .needsCallModeApproval)
    }

    func testApprovalIsRememberedForThatMicOnly() {
        XCTAssertEqual(AmbientPolicy.verdict(input: headsetIn, output: headsetOut,
                                             approvedCallModeUIDs: [headsetIn.uid]), .ok)
        XCTAssertEqual(AmbientPolicy.verdict(input: headsetIn, output: headsetOut,
                                             approvedCallModeUIDs: [otherBluetoothMic.uid]),
                       .needsCallModeApproval)
    }

    func testSomeOtherBluetoothMicIsNotTheHeadset() {
        XCTAssertEqual(AmbientPolicy.verdict(input: otherBluetoothMic, output: headsetOut,
                                             approvedCallModeUIDs: []), .ok)
    }

    /// Some Bluetooth devices expose one audio object for both directions, with
    /// no `:input` / `:output` suffix to strip.
    func testOneBluetoothObjectForBothDirectionsIsTheSameDevice() {
        let combined = AudioDeviceSummary(id: 7, uid: "04-52-C7-77-88-99", name: "Bose QC45", transport: .bluetooth)
        XCTAssertEqual(AmbientPolicy.verdict(input: combined, output: combined, approvedCallModeUIDs: []),
                       .needsCallModeApproval)
    }
}
#endif
