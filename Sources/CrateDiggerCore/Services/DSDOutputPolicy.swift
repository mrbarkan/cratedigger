import Foundation

public enum DSDOutputMode: String, CaseIterable, Sendable {
    case auto, pcm, native
}

public enum DSDPlaybackRoute: Equatable, Sendable {
    case native(dopFrameRateHz: Double)
    case pcmDecode
}

/// Decides how a DSD track reaches the DAC: bit-perfect DoP when the mode
/// allows it and the output device exposes the required PCM frame rate,
/// otherwise the existing ffmpeg decode-to-PCM path. DoP v1 is stereo-only.
public enum DSDOutputPolicy {
    public static func route(mode: DSDOutputMode,
                             dsdRateHz: Int,
                             channelCount: Int,
                             deviceSampleRates: [Double]) -> DSDPlaybackRoute {
        guard mode != .pcm, channelCount == 2 else { return .pcmDecode }
        let frameRate = Double(dsdRateHz) / 16.0
        guard deviceSampleRates.contains(where: { abs($0 - frameRate) < 0.5 }) else {
            return .pcmDecode
        }
        return .native(dopFrameRateHz: frameRate)
    }
}
