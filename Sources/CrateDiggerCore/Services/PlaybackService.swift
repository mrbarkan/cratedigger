import AVFoundation
import Foundation

public struct PlaybackQueueItem: Hashable, Sendable {
    public let url: URL
    public let title: String
    public let artist: String
    public let album: String
    public let durationSeconds: Double

    public init(url: URL, title: String, artist: String, album: String, durationSeconds: Double) {
        self.url = url
        self.title = title
        self.artist = artist
        self.album = album
        self.durationSeconds = durationSeconds
    }
}

public enum PlaybackState: Equatable, Sendable {
    case idle
    case loading
    case playing
    case paused
    case failed(message: String)
    case ended
}

public protocol PlaybackServiceProtocol: AnyObject {
    var state: PlaybackState { get }
    var currentIndex: Int? { get }
    var currentTimeSeconds: Double { get }
    var durationSeconds: Double { get }
    var errorMessage: String? { get }
    var queue: [PlaybackQueueItem] { get }

    var onStateChange: ((PlaybackState) -> Void)? { get set }
    var onCurrentIndexChange: ((Int?) -> Void)? { get set }
    var onTimeChange: ((Double, Double) -> Void)? { get set }
    var onError: ((String) -> Void)? { get set }

    func load(queue: [PlaybackQueueItem], startIndex: Int, autoPlay: Bool)
    func play()
    func pause()
    func togglePlayPause()
    func seek(toSeconds: Double)
    func next()
    func previous()
    func setVolume(_ volume: Double)
    func setOutputDeviceUID(_ uid: String?)
    /// Latest 0...1 VU meter positions per channel, from the real audio signal.
    func currentLevels() -> (left: Double, right: Double)
    /// Latest 0...1 log-spaced frequency-band magnitudes, for the spectrum meter.
    func currentSpectrum() -> [Double]
    /// Enable/disable the in-path EQ and set its 12 per-band gains (dB).
    func setEqualizer(enabled: Bool, gains: [Double])
    /// Linear makeup gain (≥1) so the volume fader can push above unity (0 dB).
    func setMasterGain(_ gain: Double)
}

protocol PlaybackEngineProtocol: AnyObject {
    var onItemReady: (() -> Void)? { get set }
    var onItemFailed: ((String) -> Void)? { get set }
    var onItemEnded: (() -> Void)? { get set }
    var onPeriodicTime: ((Double, Double) -> Void)? { get set }

    var currentTimeSeconds: Double { get }
    var durationSeconds: Double { get }

    func replaceCurrentItem(url: URL)
    func play()
    func pause()
    func seek(toSeconds: Double)
    func setVolume(_ volume: Double)
    func setOutputDeviceUID(_ uid: String?)
    var currentLevels: (left: Double, right: Double) { get }
    var currentSpectrum: [Double] { get }
    func setEqualizer(enabled: Bool, gains: [Double])
    func setMasterGain(_ gain: Double)
}

extension PlaybackEngineProtocol {
    var currentLevels: (left: Double, right: Double) { (0, 0) }
    var currentSpectrum: [Double] { [] }
    func setEqualizer(enabled: Bool, gains: [Double]) {}
    func setMasterGain(_ gain: Double) {}
}

final class AVPlayerEngine: PlaybackEngineProtocol {
    var onItemReady: (() -> Void)?
    var onItemFailed: ((String) -> Void)?
    var onItemEnded: (() -> Void)?
    var onPeriodicTime: ((Double, Double) -> Void)?

    var currentTimeSeconds: Double {
        seconds(for: player.currentTime())
    }

    var durationSeconds: Double {
        guard let item = player.currentItem else {
            return 0
        }
        return seconds(for: item.duration)
    }

    private let player = AVPlayer()
    private let levelTap = AudioLevelTap()
    private var timeObserverToken: Any?
    private var statusObservation: NSKeyValueObservation?
    private var itemEndObserver: NSObjectProtocol?

    init() {
        player.automaticallyWaitsToMinimizeStalling = true
        addPeriodicTimeObserver()
    }

    deinit {
        if let timeObserverToken {
            player.removeTimeObserver(timeObserverToken)
        }
        statusObservation = nil
        if let itemEndObserver {
            NotificationCenter.default.removeObserver(itemEndObserver)
        }
    }

    func replaceCurrentItem(url: URL) {
        statusObservation = nil
        if let itemEndObserver {
            NotificationCenter.default.removeObserver(itemEndObserver)
            self.itemEndObserver = nil
        }

        let item = AVPlayerItem(url: url)
        attachLevelMetering(to: item)
        player.replaceCurrentItem(with: item)

        statusObservation = item.observe(\.status, options: [.new, .initial]) { [weak self] item, _ in
            guard let self else { return }
            switch item.status {
            case .readyToPlay:
                self.onItemReady?()
            case .failed:
                self.onItemFailed?(item.error?.localizedDescription ?? "Unable to play this file.")
            case .unknown:
                break
            @unknown default:
                break
            }
        }

        itemEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            self?.onItemEnded?()
        }
    }

    func play() {
        player.play()
    }

    func pause() {
        player.pause()
    }

    func seek(toSeconds seconds: Double) {
        let safe = max(0, seconds)
        let target = CMTime(seconds: safe, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func setVolume(_ volume: Double) {
        player.volume = Float(max(0, min(volume, 1)))
    }

    func setOutputDeviceUID(_ uid: String?) {
        player.audioOutputDeviceUniqueID = uid
    }

    var currentLevels: (left: Double, right: Double) {
        let peaks = levelTap.currentPeaks()
        // Fold in the player volume so the meter tracks what you actually hear.
        let v = Double(player.volume)
        return (meterPosition(peaks.left * v), meterPosition(peaks.right * v))
    }

    var currentSpectrum: [Double] {
        // Already 0...1 from the FFT's dB mapping; scale by volume so the bars
        // fall when you turn it down, matching the level meter.
        let v = Double(player.volume)
        return levelTap.currentBands().map { $0 * v }
    }

    func setEqualizer(enabled: Bool, gains: [Double]) {
        levelTap.setEQ(enabled: enabled, gains: gains)
    }

    func setMasterGain(_ gain: Double) {
        levelTap.setMasterGain(gain)
    }

    /// Map a linear peak (0...1) to a meter fill position: -48 dBFS → 0 and
    /// 0 dBFS → 0.80 so full scale lands on the meter's "0" tick.
    private func meterPosition(_ linear: Double) -> Double {
        guard linear > 0.000_001 else { return 0 }
        let db = 20 * log10(linear)
        return min(max((db + 48) / 48 * 0.80, 0), 1)
    }

    /// Attach an audio tap so `currentLevels` reflects the real signal. The
    /// asset's audio track loads asynchronously, so wire the mix once it's ready.
    private func attachLevelMetering(to item: AVPlayerItem) {
        levelTap.reset()
        let tap = levelTap
        Task { [weak item] in
            guard let item,
                  let track = try? await item.asset.loadTracks(withMediaType: .audio).first
            else { return }
            let mix = tap.makeAudioMix(forTrack: track)
            await MainActor.run { item.audioMix = mix }
        }
    }

    private func addPeriodicTimeObserver() {
        let interval = CMTime(seconds: 0.2, preferredTimescale: 600)
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.onPeriodicTime?(self.currentTimeSeconds, self.durationSeconds)
        }
    }

    private func seconds(for time: CMTime) -> Double {
        guard time.isNumeric, !time.isIndefinite else {
            return 0
        }
        let value = CMTimeGetSeconds(time)
        guard value.isFinite, value >= 0 else {
            return 0
        }
        return value
    }
}

public final class PlaybackService: PlaybackServiceProtocol {
    public private(set) var state: PlaybackState = .idle {
        didSet {
            notify {
                self.onStateChange?(self.state)
            }
        }
    }
    public private(set) var currentIndex: Int? {
        didSet {
            notify {
                self.onCurrentIndexChange?(self.currentIndex)
            }
        }
    }
    public private(set) var currentTimeSeconds: Double = 0 {
        didSet {
            notifyTimeChange()
        }
    }
    public private(set) var durationSeconds: Double = 0 {
        didSet {
            notifyTimeChange()
        }
    }
    public private(set) var errorMessage: String?
    public private(set) var queue: [PlaybackQueueItem] = []

    public var onStateChange: ((PlaybackState) -> Void)?
    public var onCurrentIndexChange: ((Int?) -> Void)?
    public var onTimeChange: ((Double, Double) -> Void)?
    public var onError: ((String) -> Void)?

    private let engine: PlaybackEngineProtocol
    private var pendingAutoPlay = false

    public convenience init() {
        self.init(engine: AVPlayerEngine())
    }

    init(engine: PlaybackEngineProtocol) {
        self.engine = engine
        bindEngineCallbacks()
    }

    public func load(queue: [PlaybackQueueItem], startIndex: Int, autoPlay: Bool) {
        self.queue = queue
        pendingAutoPlay = autoPlay
        errorMessage = nil

        guard !queue.isEmpty else {
            engine.pause()
            currentIndex = nil
            currentTimeSeconds = 0
            durationSeconds = 0
            state = .idle
            return
        }

        let clampedIndex = max(0, min(startIndex, queue.count - 1))
        currentIndex = clampedIndex
        currentTimeSeconds = 0
        durationSeconds = 0
        state = .loading
        engine.replaceCurrentItem(url: queue[clampedIndex].url)
    }

    public func play() {
        guard !queue.isEmpty else { return }

        if state == .ended, let currentIndex {
            load(queue: queue, startIndex: currentIndex, autoPlay: true)
            return
        }

        if currentIndex == nil {
            load(queue: queue, startIndex: 0, autoPlay: true)
            return
        }

        pendingAutoPlay = true
        engine.play()
        state = .playing
    }

    public func pause() {
        engine.pause()
        if case .failed = state {
            return
        }
        if state != .idle {
            state = .paused
        }
    }

    public func togglePlayPause() {
        switch state {
        case .playing:
            pause()
        default:
            play()
        }
    }

    public func seek(toSeconds: Double) {
        let upperBound = durationSeconds > 0 ? durationSeconds : toSeconds
        let clamped = max(0, min(toSeconds, upperBound))
        engine.seek(toSeconds: clamped)
        currentTimeSeconds = clamped
    }

    public func next() {
        guard !queue.isEmpty else { return }
        guard let currentIndex else {
            load(queue: queue, startIndex: 0, autoPlay: true)
            return
        }

        let shouldPlay = state == .playing || state == .loading
        let nextIndex = currentIndex + 1
        guard queue.indices.contains(nextIndex) else {
            engine.pause()
            currentTimeSeconds = durationSeconds
            state = .ended
            return
        }

        load(queue: queue, startIndex: nextIndex, autoPlay: shouldPlay)
    }

    public func previous() {
        guard !queue.isEmpty else { return }
        guard let currentIndex else {
            load(queue: queue, startIndex: 0, autoPlay: true)
            return
        }

        if currentTimeSeconds > 3 {
            seek(toSeconds: 0)
            return
        }

        let shouldPlay = state == .playing || state == .loading
        let previousIndex = currentIndex - 1
        if queue.indices.contains(previousIndex) {
            load(queue: queue, startIndex: previousIndex, autoPlay: shouldPlay)
        } else {
            seek(toSeconds: 0)
        }
    }

    public func setVolume(_ volume: Double) {
        engine.setVolume(volume)
    }

    public func setMasterGain(_ gain: Double) {
        engine.setMasterGain(gain)
    }

    public func setOutputDeviceUID(_ uid: String?) {
        engine.setOutputDeviceUID(uid)
    }

    public func currentSpectrum() -> [Double] {
        engine.currentSpectrum
    }

    public func setEqualizer(enabled: Bool, gains: [Double]) {
        engine.setEqualizer(enabled: enabled, gains: gains)
    }

    public func currentLevels() -> (left: Double, right: Double) {
        engine.currentLevels
    }

    private func bindEngineCallbacks() {
        engine.onItemReady = { [weak self] in
            guard let self else { return }
            self.durationSeconds = self.engine.durationSeconds
            self.currentTimeSeconds = self.engine.currentTimeSeconds

            if self.pendingAutoPlay {
                self.engine.play()
                self.state = .playing
            } else {
                self.state = .paused
            }
        }

        engine.onItemFailed = { [weak self] message in
            guard let self else { return }
            self.errorMessage = message
            self.notify {
                self.onError?(message)
            }

            if let currentIndex, self.queue.indices.contains(currentIndex + 1) {
                self.load(queue: self.queue, startIndex: currentIndex + 1, autoPlay: true)
                return
            }

            self.state = .failed(message: message)
        }

        engine.onItemEnded = { [weak self] in
            guard let self else { return }
            if let currentIndex, self.queue.indices.contains(currentIndex + 1) {
                self.load(queue: self.queue, startIndex: currentIndex + 1, autoPlay: true)
                return
            }

            self.currentTimeSeconds = self.durationSeconds
            self.state = .ended
        }

        engine.onPeriodicTime = { [weak self] current, duration in
            guard let self else { return }
            self.currentTimeSeconds = max(0, current)
            if duration > 0 {
                self.durationSeconds = duration
            }
        }
    }

    private func notify(_ block: @escaping () -> Void) {
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.async(execute: block)
        }
    }

    private func notifyTimeChange() {
        notify {
            self.onTimeChange?(self.currentTimeSeconds, self.durationSeconds)
        }
    }
}
