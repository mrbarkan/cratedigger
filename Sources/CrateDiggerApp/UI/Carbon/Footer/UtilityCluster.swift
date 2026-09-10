import CrateDiggerCore
import SwiftUI

/// Footer right cluster (CrateDigger v6 `.f-util`): volume, ambient, EQ LCD.
/// The mini-player launch button now lives in the header next to RESCAN
/// (see `BrandBlock`).
struct UtilityCluster: View {
    @EnvironmentObject private var model: LibraryViewModel

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VolumeKnob(value: $model.playbackVolume)
            AmbientPod()
            EQScreen()
        }
    }
}

/// The AMBIENT pod: how loud the room plays, on a fader, with the AMB key that
/// turns it on printed into the label row so it costs no footer width.
/// Right-click holds the same settings as Playback ▸ Ambient, so they can be
/// compared by ear without opening a window.
private struct AmbientPod: View {
    @EnvironmentObject private var model: LibraryViewModel

    var body: some View {
        VolumeKnob(
            value: Binding(get: { model.ambientSettings.level },
                           set: { model.setAmbientLevel($0) }),
            label: "AMBIENT",
            unityFraction: AmbientLevelCurve.unityPosition,
            accessibilityName: "Ambient level",
            width: 150
        ) {
            AmbientKey(state: model.ambientState) {
                ClickPlayer.shared.play(.tick)
                model.toggleAmbient()
            }
        }
        .contextMenu { AmbientMenuItems() }
    }
}

/// A small silicone key lit from behind while Ambient runs. Half-lit while it
/// is paused for bit-perfect DSD: on, but not passing sound.
private struct AmbientKey: View {
    let state: AmbientService.State
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            SiliconeCap(shape: Capsule(), lit: state != .off) {
                Text("AMB")
                    .font(CarbonFont.mono(6.5, weight: .bold))
                    .tracking(0.8)
            }
            .opacity(state == .paused ? 0.55 : 1)
            .frame(width: 34, height: 13)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Ambient")
        .accessibilityValue(state == .off ? "Off" : state == .paused ? "Paused" : "On")
        .help("Hear the room through your headphones (⌥⌘A)")
    }
}

/// Ambient's settings as menu content, for the pod's right-click menu.
private struct AmbientMenuItems: View {
    @EnvironmentObject private var model: LibraryViewModel

    var body: some View {
        Button(model.ambientState == .off ? "Turn Ambient On" : "Turn Ambient Off") {
            model.toggleAmbient()
        }
        Divider()
        Picker("Microphone", selection: Binding(get: { model.ambientEffectiveInputUID },
                                                set: { model.setAmbientInput(uid: $0.isEmpty ? nil : $0) })) {
            Text("System Default").tag("")
            ForEach(model.ambientInputDevices(), id: \.uid) { device in
                Text(device.name).tag(device.uid)
            }
        }
        Picker("Delay", selection: Binding(get: { model.ambientSettings.delay },
                                           set: { model.setAmbientDelay($0) })) {
            ForEach(AmbientDelay.allCases, id: \.self) { delay in
                Text(delay.title).tag(delay)
            }
        }
        Toggle("Low Cut", isOn: Binding(get: { model.ambientSettings.lowCut },
                                        set: { model.setAmbientLowCut($0) }))
        Picker("Engine", selection: Binding(get: { model.ambientSettings.engine },
                                            set: { model.setAmbientEngine($0) })) {
            ForEach(AmbientEngineKind.allCases, id: \.self) { kind in
                Text(kind.title).tag(kind)
            }
        }
    }
}
