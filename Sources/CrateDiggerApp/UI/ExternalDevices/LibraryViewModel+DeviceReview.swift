import AppKit
import CrateDiggerCore
import Foundation

/// The review every device transfer goes through before it writes anything:
/// compare what is being sent with what the device holds, ask about the
/// albums that differ (once, in one sheet), and turn the answers into a file
/// plan. The decisions are Core's (`DeviceTransferResolver`,
/// `DeviceLeftAloneStore`); this only wires them to the sheet and the stores.
extension LibraryViewModel {
    /// Review → sheet (only when an album needs an answer) → plan.
    ///
    /// - `reviewedAlbumFolders`: the per-album folder names the user reviewed
    ///   for a template layout (a convert run's album-folder review).
    /// - `alreadyDecided`: answers made before, such as ones stored on a sync
    ///   queue entry. Those albums are not asked about again; an answer given
    ///   in the sheet wins over one passed here.
    ///
    /// Remembers the sheet's Leave it answers for this device and forgets an
    /// album left alone before that the user now answered otherwise.
    ///
    /// Returns nil when the user cancels the sheet, or when the plan is
    /// refused (an alert says why). Nothing has been written either way.
    @MainActor
    func reviewedDevicePlan(
        tracks: [LoadedTrack],
        profile: ExternalDeviceProfile,
        mountedRoot: URL,
        catalog: [LoadedTrack],
        presentingFrom host: NSViewController,
        reviewedAlbumFolders: [AlbumFolderKey: String] = [:],
        alreadyDecided: [DeviceAlbumIdentity: DeviceAlbumDecision] = [:]
    ) async -> (plan: DeviceTransferFilePlan, review: DeviceTransferReview)? {
        let leftAloneStore = DeviceLeftAloneStore()
        let leftAlone = leftAloneStore.load(profileID: profile.id)

        // The review checks every planned destination on the device: a
        // file-system walk over USB, so off the main actor.
        let review = await Task.detached(priority: .userInitiated) {
            DeviceTransferResolver().review(
                sending: tracks,
                catalog: catalog,
                profile: profile,
                mountedAt: mountedRoot,
                leftAlone: leftAlone,
                reviewedAlbumFolders: reviewedAlbumFolders
            )
        }.value

        var answers: [DeviceAlbumIdentity: DeviceAlbumDecision] = [:]
        let asked = review.needingDecision.filter { alreadyDecided[$0.identity] == nil }
        if !asked.isEmpty {
            // Albums already answered stay off the sheet. The sheet only
            // shows a review, so a copy of it without them is enough there;
            // the plan below is resolved from the real one.
            let shown = alreadyDecided.isEmpty
                ? review
                : DeviceTransferReview(albums: review.albums.filter { alreadyDecided[$0.identity] == nil })
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

        let decisions = alreadyDecided.merging(answers) { _, answered in answered }
        let plan: DeviceTransferFilePlan
        do {
            plan = try await Task.detached(priority: .userInitiated) {
                try DeviceTransferResolver().resolve(
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

        // Only once the plan stands: a refused transfer changes nothing.
        leftAloneStore.record(answers, profileID: profile.id)
        return (plan, review)
    }
}
