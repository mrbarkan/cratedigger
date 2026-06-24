import CrateDiggerCore
import Foundation

/// Native playback engine: resolves a YouTube stream to a playable URL with
/// yt-dlp (off the main actor), then plays it through a `PlaybackService`
/// (AVPlayer). Full hardware integration — real transport, output-device
/// routing, and accurate codec/buffer because the audio flows through AVPlayer.
@MainActor
final class YtDlpStreamEngine: RadioPlaybackEngine {

    var onStateChange: ((RadioEngineState) -> Void)?
    var onTimeChange: ((Double, Double) -> Void)?

    private let resolver: StreamResolver
    private let player: PlaybackServiceProtocol
    private var resolveTask: Task<Void, Never>?
    private var volume: Double = 0.8

    init(resolver: StreamResolver, player: PlaybackServiceProtocol = PlaybackService()) {
        self.resolver = resolver
        self.player = player
        wirePlayer()
    }

    private func wirePlayer() {
        player.onStateChange = { [weak self] state in
            Task { @MainActor in self?.map(state) }
        }
        player.onTimeChange = { [weak self] current, duration in
            Task { @MainActor in self?.onTimeChange?(current, duration) }
        }
        player.onError = { [weak self] message in
            Task { @MainActor in self?.onStateChange?(.failed(message)) }
        }
    }

    func play(_ stream: StreamSource) {
        onStateChange?(.loading)
        resolveTask?.cancel()
        let resolver = self.resolver
        resolveTask = Task { [weak self] in
            do {
                let resolved = try await Task.detached { try resolver.resolve(stream) }.value
                if Task.isCancelled { return }
                await MainActor.run {
                    guard let self else { return }
                    let item = PlaybackQueueItem(
                        url: resolved.playbackURL,
                        title: stream.title,
                        artist: stream.channel,
                        album: "YouTube",
                        durationSeconds: resolved.durationSeconds ?? 0
                    )
                    self.player.load(queue: [item], startIndex: 0, autoPlay: true)
                    self.player.setVolume(self.volume)
                }
            } catch {
                if Task.isCancelled { return }
                await MainActor.run { self?.onStateChange?(.failed(Self.describe(error))) }
            }
        }
    }

    func pause()  { player.pause() }
    func resume() { player.play() }

    func stop() {
        resolveTask?.cancel()
        resolveTask = nil
        player.load(queue: [], startIndex: 0, autoPlay: false)
        onStateChange?(.idle)
    }

    func setVolume(_ volume: Double) {
        self.volume = max(0, min(volume, 1))
        player.setVolume(self.volume)
    }

    func seek(toSeconds seconds: Double) { player.seek(toSeconds: seconds) }
    func setOutputDeviceUID(_ uid: String?) { player.setOutputDeviceUID(uid) }

    private func map(_ state: PlaybackState) {
        switch state {
        case .idle:    onStateChange?(.idle)
        case .loading: onStateChange?(.loading)
        case .playing: onStateChange?(.playing)
        case .paused:  onStateChange?(.paused)
        case .ended:   onStateChange?(.idle)
        case .failed(let message): onStateChange?(.failed(message))
        }
    }

    private static func describe(_ error: Error) -> String {
        guard let e = error as? StreamResolverError else { return error.localizedDescription }
        switch e {
        case .emptyOutput:               return "yt-dlp returned no playable stream."
        case .badURL:                    return "yt-dlp returned an unreadable URL."
        case .commandFailed(_, let err):
            let firstLine = err.split(separator: "\n").first.map(String.init) ?? "yt-dlp failed."
            return firstLine
        }
    }
}
