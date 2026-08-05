import CrateDiggerCore
import Foundation

/// Sleep timer. Timed modes run off a 1s ticker so the countdown can be shown;
/// the event-driven modes (`endOfTrack` / `endOfQueue`) carry no deadline and are
/// resolved by playback reaching a boundary — see `noteSleepTrackChanged()` and
/// `noteSleepQueueEnded()`, called from the playback bindings.
@MainActor
extension LibraryViewModel {

    // MARK: - Arming

    func setSleepMode(_ mode: SleepMode) {
        sleepMode = mode
        sleepStartedAt = Date()
        // The track playing when an end-of-track timer is armed is the one it
        // waits for; without this, arming mid-track would stop at the *next*
        // boundary only by luck of which callback fires first.
        sleepAnchorTrackID = mode == .endOfTrack ? nowPlayingTrack?.track.id : nil

        guard mode.isArmed else {
            stopSleepTicker()
            sleepRemainingLabel = nil
            showOLEDNotice("SLEEP OFF")
            return
        }

        refreshSleepLabel()
        if mode.deadline(from: sleepStartedAt) != nil {
            startSleepTicker()
        } else {
            stopSleepTicker()   // nothing to count down
        }
        showOLEDNotice("SLEEP · \(sleepRemainingLabel ?? "ON")")
    }

    func cancelSleep() { setSleepMode(.off) }

    var isSleepArmed: Bool { sleepMode.isArmed }

    // MARK: - Ticking

    private func startSleepTicker() {
        stopSleepTicker()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.sleepTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        sleepTimer = timer
    }

    private func stopSleepTicker() {
        sleepTimer?.invalidate()
        sleepTimer = nil
    }

    private func sleepTick() {
        guard sleepMode.isArmed else { stopSleepTicker(); return }
        refreshSleepLabel()
        if sleepMode.hasElapsed(now: Date(), start: sleepStartedAt) {
            fireSleep()
        }
    }

    private func refreshSleepLabel() {
        sleepRemainingLabel = sleepMode.statusLabel(now: Date(), start: sleepStartedAt)
    }

    // MARK: - Event-driven boundaries

    /// The playing track changed. Ends an `endOfTrack` timer, but only once the
    /// track it was armed against is actually gone.
    func noteSleepTrackChanged() {
        guard sleepMode == .endOfTrack else { return }
        guard let anchor = sleepAnchorTrackID else { fireSleep(); return }
        if nowPlayingTrack?.track.id != anchor { fireSleep() }
    }

    /// The queue ran out — the boundary `endOfQueue` waits for. `endOfTrack`
    /// also ends here: the queue ending means that track ended too.
    func noteSleepQueueEnded() {
        guard sleepMode == .endOfQueue || sleepMode == .endOfTrack else { return }
        fireSleep()
    }

    // MARK: - Firing

    private func fireSleep() {
        stopSleepTicker()
        sleepMode = .off
        sleepRemainingLabel = nil
        sleepAnchorTrackID = nil

        // Stop whichever path is actually producing sound.
        if isStreamActive {
            stopRadio()
        } else {
            playback.pause()
        }
        showOLEDNotice("SLEEP")
        appAlert = .info(title: "Sleep Timer",
                         message: "Playback stopped — the sleep timer ran out.")
    }
}
