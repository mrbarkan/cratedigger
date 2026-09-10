import AppKit
import AVFoundation
import Combine
import CrateDiggerCore
import Foundation

/// Ambient: the room through the headphones, under the music.
///
/// `AmbientService` (Core) decides everything a listener could hear go wrong,
/// and is tested there. This file is only the glue: persistence, the mic
/// permission prompt, the two alerts, the screen notices, and the three signals
/// the service needs from the rest of the app (the output device, the device
/// list, and bit-perfect DSD).
extension LibraryViewModel {

    func makeAmbientService() -> AmbientService {
        let service = AmbientService(
            settings: ambientSettings,
            devices: ambientDevices,
            authorize: { await Self.requestMicrophoneAccess() },
            makeEngine: { kind in
                switch kind {
                case .split: return SplitAmbientEngine()
                case .combined: return CombinedAmbientEngine()
                }
            }
        )
        service.onStateChange = { [weak self] state in
            guard let self else { return }
            let previous = self.ambientState
            self.ambientState = state
            if state == .paused, case .running = previous {
                self.showOLEDNotice("AMBIENT PAUSED · DSD PLAYING")
            } else if case .running = state, previous == .paused {
                self.showOLEDNotice("AMBIENT BACK ON")
            }
        }
        service.onStop = { [weak self] reason in self?.handleAmbientStop(reason) }
        return service
    }

    /// Called once from init. Loads the settings before anything touches the
    /// service, which is built lazily from them.
    func setupAmbient() {
        ambientSettings = prefs.ambientSettings
        _ = ambientService

        ambientDevices.observeDeviceChanges { [weak self] in
            MainActor.assumeIsolated { self?.ambientService.devicesChanged() }
        }

        let center = NotificationCenter.default
        ambientSubscriptions.append(center.addObserver(
            forName: NSNotification.Name("CrateDiggerAudioDeviceChanged"), object: nil, queue: .main
        ) { [weak self] notification in
            // Preferences posts "" for System Default.
            let uid = (notification.object as? String).flatMap { $0.isEmpty ? nil : $0 }
            MainActor.assumeIsolated { self?.ambientService.outputDeviceChanged(to: uid) }
        })
        ambientSubscriptions.append(center.addObserver(
            forName: NSNotification.Name("CrateDiggerAmbientChanged"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.applyAmbientSettings(self.prefs.ambientSettings, persist: false)
            }
        })
        // DoP engages when a DSD track loads, and every load moves the playback
        // state, so the state stream is where to look. `isNativeDSDActive` is
        // already current by the time the new state is published.
        ambientSubscriptions.append($playbackState.sink { [weak self] _ in
            guard let self else { return }
            self.ambientService.setBitPerfectDSDActive(self.playback.isNativeDSDActive)
        })
    }

    // MARK: - Reading

    /// Every input Core Audio knows about right now.
    func ambientInputDevices() -> [AudioDeviceSummary] {
        ambientDevices.inputs()
    }

    /// The mic the pickers should tick: the saved one while it is plugged in,
    /// otherwise "" for System Default, which is what Ambient will really use.
    var ambientEffectiveInputUID: String {
        guard let uid = ambientSettings.inputUID, ambientDevices.input(uid: uid) != nil else { return "" }
        return uid
    }

    // MARK: - Switching

    func toggleAmbient() {
        if ambientState == .off {
            startAmbient()
        } else {
            ambientService.turnOff()
            showOLEDNotice("AMBIENT OFF")
        }
    }

    private func startAmbient() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await self.ambientService.turnOn(outputUID: self.prefs.selectedOutputDeviceUID)
            self.handleAmbientStart(result)
        }
    }

    // MARK: - Settings

    func setAmbientLevel(_ position: Double) {
        var settings = ambientSettings
        settings.level = min(max(position, 0), 1)
        applyAmbientSettings(settings, persist: true)
    }

    func setAmbientInput(uid: String?) {
        var settings = ambientSettings
        settings.inputUID = uid
        applyAmbientSettings(settings, persist: true)
    }

    func setAmbientDelay(_ delay: AmbientDelay) {
        var settings = ambientSettings
        settings.delay = delay
        applyAmbientSettings(settings, persist: true)
        showOLEDNotice("DELAY · \(delay.title.uppercased())")
    }

    func setAmbientLowCut(_ enabled: Bool) {
        var settings = ambientSettings
        settings.lowCut = enabled
        applyAmbientSettings(settings, persist: true)
        showOLEDNotice(enabled ? "LOW CUT · ON" : "LOW CUT · OFF")
    }

    func setAmbientEngine(_ kind: AmbientEngineKind) {
        var settings = ambientSettings
        settings.engine = kind
        applyAmbientSettings(settings, persist: true)
        showOLEDNotice("ENGINE · \(kind.title.uppercased())")
    }

    /// The one door every settings change goes through: mirror it for the UI,
    /// persist it unless it came from the store, and hand it to the service,
    /// which applies it live or rebuilds.
    private func applyAmbientSettings(_ settings: AmbientSettings, persist: Bool) {
        guard settings != ambientSettings else { return }
        ambientSettings = settings
        if persist { prefs.ambientSettings = settings }
        ambientService.update(settings)
    }

    // MARK: - Outcomes

    private func handleAmbientStart(_ result: AmbientService.StartResult) {
        switch result {
        case .started(let inputName):
            showOLEDNotice(ambientState == .paused
                           ? "AMBIENT WAITS · DSD PLAYING"
                           : "AMBIENT ON · \(inputName.uppercased())")
        case .permissionDenied:
            appAlert = .actionable(
                title: "Microphone Access Is Off",
                message: "Ambient needs the microphone to hear the room. Allow CrateDigger in System Settings under Privacy & Security, Microphone, then press AMB again.",
                actionTitle: "Open Privacy Settings"
            ) {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                    NSWorkspace.shared.open(url)
                }
            }
        case .noInput:
            appAlert = .error(
                title: "No Microphone",
                message: "Ambient needs a microphone and none is available. A MacBook's built-in microphone is off while its lid is closed."
            )
        case .blockedBySpeakers:
            showOLEDNotice("AMBIENT NEEDS HEADPHONES", blinking: true, seconds: 3.5)
        case .needsCallModeApproval(let deviceName, let deviceUID):
            confirmCallMode(deviceName: deviceName, deviceUID: deviceUID)
        case .failed(let message):
            appAlert = .error(title: "Ambient Could Not Start", message: message)
        }
    }

    private func handleAmbientStop(_ reason: AmbientService.StopReason) {
        switch reason {
        case .inputDisconnected:
            showOLEDNotice("AMBIENT OFF · MIC DISCONNECTED", blinking: true, seconds: 3.5)
        case .blockedBySpeakers:
            showOLEDNotice("AMBIENT OFF · NEEDS HEADPHONES", blinking: true, seconds: 3.5)
        case .needsCallModeApproval(let deviceName, let deviceUID):
            confirmCallMode(deviceName: deviceName, deviceUID: deviceUID)
        case .failed(let message):
            appAlert = .error(title: "Ambient Stopped", message: message)
        }
    }

    /// The headset's own mic flips it into call mode. Offer the Mac's mic when
    /// there is one, remember "Use Anyway" for this device, and start again
    /// either way.
    private func confirmCallMode(deviceName: String, deviceUID: String) {
        let builtIn = ambientDevices.inputs().first { $0.transport == .builtIn }

        let alert = NSAlert()
        alert.messageText = "Use the microphone on \(deviceName)?"
        alert.informativeText = "Opening its microphone switches \(deviceName) to call mode, so your music will sound flat and mono while Ambient is on."
            + (builtIn == nil ? "" : " The Mac's built-in microphone avoids that.")
        if builtIn != nil { alert.addButton(withTitle: "Use Built-in Mic") }
        alert.addButton(withTitle: "Use Anyway")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal().rawValue
        let first = NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        var settings = ambientSettings

        if let builtIn, response == first {
            settings.inputUID = builtIn.uid
        } else if response == first + (builtIn == nil ? 0 : 1) {
            settings.callModeApprovedUIDs.insert(deviceUID)
        } else {
            return
        }
        applyAmbientSettings(settings, persist: true)
        startAmbient()
    }

    private static func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }
}
