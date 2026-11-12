import AppKit
import CrateDiggerCore
import Foundation

/// The review every device transfer goes through before it writes anything:
/// compare what is being sent with what the device holds, ask about the
/// albums that differ (once, in one sheet), and turn the answers into a file
/// plan. The decisions are Core's (`DeviceTransferResolver`,
/// `DeviceLeftAloneStore`); this only wires them to the sheet and the stores.
extension LibraryViewModel {
    /// The mounted device a send to `profile` at `root` writes to: the volume
    /// that holds `root`, when it is this profile's device. Otherwise shows
    /// why not and returns nil, before anything is read or written: the
    /// catalog reviewed and patched must be the volume the files land on.
    @MainActor
    func mountedDevice(for profile: ExternalDeviceProfile, at root: URL) -> MountedDevice? {
        let holder = MountedDevice.containing(root, in: mountedDevices)
        if let holder, deviceProfile(for: holder)?.id == profile.id {
            return holder
        }
        if holder == nil, !mountedDevices.contains(where: { deviceProfile(for: $0)?.id == profile.id }) {
            appAlert = .error(
                title: "\(profile.name) isn't connected",
                message: "Nothing was sent. Connect the device and send again."
            )
        } else {
            AppLog.conversion.error("\(profile.name, privacy: .public) points at \(root.path, privacy: .public), which is not its mounted volume")
            appAlert = .error(
                title: "Nothing was sent to \(profile.name)",
                message: "\(holder?.name ?? root.path) isn't the volume this profile points at. Open Preferences > Devices and choose its folder again."
            )
        }
        return nil
    }

    /// Review → sheet (only when an album needs an answer) → plan.
    ///
    /// - `reviewedAlbumFolders`: the per-album folder names the user reviewed
    ///   for a template layout (a convert run's album-folder review).
    /// - `alreadyDecided`: answers made before, such as ones stored on a sync
    ///   queue entry. Those albums are not asked about again; an answer given
    ///   in the sheet wins over one passed here.
    /// - `fileManager`: what the review and plan see on disk. Queuing passes
    ///   one blind to the staging tree (`DeviceSyncQueuePlanner`); every
    ///   write to a mounted device uses the default.
    ///
    /// `answers` are the sheet's own answers. The caller hands them to
    /// `rememberDeviceAnswers` once the transfer is sure to go ahead (its
    /// preflights passed), so a send that never ran remembers nothing.
    ///
    /// Returns nil when the user cancels the sheet, the sheet can't be shown,
    /// or the plan is refused (an alert says why in the last two cases).
    /// Nothing has been written either way.
    @MainActor
    func reviewedDevicePlan(
        tracks: [LoadedTrack],
        profile: ExternalDeviceProfile,
        mountedRoot: URL,
        catalog: [LoadedTrack],
        presentingFrom host: NSViewController,
        reviewedAlbumFolders: [AlbumFolderKey: String] = [:],
        alreadyDecided: [DeviceAlbumIdentity: DeviceStoredDecision] = [:],
        fileManager: FileManager = .default
    ) async -> (plan: DeviceTransferFilePlan, review: DeviceTransferReview,
                answers: [DeviceAlbumIdentity: DeviceAlbumDecision])? {
        let leftAlone = DeviceLeftAloneStore().load(profileID: profile.id)

        // The review checks every planned destination on the device: a
        // file-system walk over USB, so off the main actor.
        let review = await Task.detached(priority: .userInitiated) {
            DeviceTransferResolver(fileManager: fileManager).review(
                sending: tracks,
                catalog: catalog,
                profile: profile,
                mountedAt: mountedRoot,
                leftAlone: leftAlone,
                reviewedAlbumFolders: reviewedAlbumFolders
            )
        }.value

        // An earlier answer counts only for an album that still differs, and
        // in the same kind of way: one the device now lacks or already holds
        // needs none, and one that changed kind is asked again.
        let decided = DeviceTransferResolver.applicableDecisions(stored: alreadyDecided, review: review)
        var answers: [DeviceAlbumIdentity: DeviceAlbumDecision] = [:]
        let asked = review.needingDecision.filter { decided[$0.identity] == nil }
        if !asked.isEmpty {
            guard host.view.window != nil else {
                AppLog.conversion.error("No window to show the device review for \(profile.name, privacy: .public)")
                appAlert = .error(
                    title: "Nothing was sent to \(profile.name)",
                    message: "Some albums are already on the device in another form, and CrateDigger could not show where to choose what happens to them. Bring the CrateDigger window forward and send again."
                )
                return nil
            }
            // Albums already answered stay off the sheet. The sheet only
            // shows a review, so a copy of it without them is enough there;
            // the plan below is resolved from the real one.
            let shown = decided.isEmpty
                ? review
                : DeviceTransferReview(albums: review.albums.filter { decided[$0.identity] == nil })
            guard let chosen = await presentDeviceReview(
                shown,
                deviceName: profile.name,
                settings: profile.transferSettings,
                presentingFrom: host
            ) else {
                AppLog.conversion.notice("Device review cancelled for \(profile.name, privacy: .public)")
                return nil
            }
            answers = chosen
        }

        let decisions = decided.merging(answers) { _, answered in answered }
        let plan: DeviceTransferFilePlan
        do {
            plan = try await Task.detached(priority: .userInitiated) {
                try DeviceTransferResolver(fileManager: fileManager).resolve(
                    review,
                    decisions: decisions,
                    profile: profile,
                    mountedAt: mountedRoot
                )
            }.value
        } catch {
            AppLog.conversion.error("Device plan refused for \(profile.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            appAlert = .error(title: "Nothing was sent to \(profile.name)", message: error.localizedDescription)
            return nil
        }
        return (plan, review, answers)
    }

    /// Remembers the sheet's Leave it answers for this device and forgets an
    /// album left alone before that the user now answered otherwise. Called
    /// once a send is going ahead (or turned out to need nothing).
    func rememberDeviceAnswers(_ answers: [DeviceAlbumIdentity: DeviceAlbumDecision], profileID: UUID) {
        DeviceLeftAloneStore().record(answers, profileID: profileID)
    }
}
