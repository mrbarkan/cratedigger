import CrateDiggerCore
import Foundation

/// Playback state for a radio stream, normalized across both engines
/// (WebView embed and native yt-dlp).
enum RadioEngineState: Equatable {
    case idle
    case loading        // resolving / buffering ("TUNING IN…")
    case playing
    case paused
    case failed(String)
}

/// Abstracts how a `StreamSource` is actually played. Two implementations:
/// `YouTubeEmbedStreamEngine` (hidden WKWebView + IFrame, zero-config default) and
/// `YtDlpStreamEngine` (resolves a playable URL via yt-dlp, plays through AVPlayer).
/// The UI is engine-agnostic; `LibraryViewModel` picks the active engine.
@MainActor
protocol RadioPlaybackEngine: AnyObject {
    var onStateChange: ((RadioEngineState) -> Void)? { get set }
    /// (currentSeconds, durationSeconds). duration is 0 for live streams.
    var onTimeChange: ((Double, Double) -> Void)? { get set }

    func play(_ stream: StreamSource)
    func pause()
    func resume()
    func stop()
    func setVolume(_ volume: Double)   // 0...1
    func seek(toSeconds seconds: Double)  // ignored for live
    /// Route audio to a CoreAudio output device. Honored by the native engine;
    /// no-op for the WebView engine (it can't control routing).
    func setOutputDeviceUID(_ uid: String?)
}

extension RadioPlaybackEngine {
    func setOutputDeviceUID(_ uid: String?) {}
}
