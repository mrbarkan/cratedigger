import AppKit
import CrateDiggerCore
import Foundation

/// Update checking: "Check for Updates…" in the app menu, plus a silent
/// once-a-day check at launch. Compares the running version against the
/// GitHub Releases feed (`UpdateCheckService`); the alert's Download button
/// opens the release page — no auto-install.
extension LibraryViewModel {
    func checkForUpdates(userInitiated: Bool) {
        if !userInitiated {
            if let last = prefs.lastUpdateCheckDate,
               Date().timeIntervalSince(last) < 24 * 60 * 60 {
                return
            }
        }
        guard let current = SemanticVersion(tag: AppVersion.currentSemverString) else {
            AppLog.library.warning("Update check skipped: unparseable current version \(AppVersion.currentSemverString, privacy: .public)")
            return
        }
        let includePrereleases = !AppVersion.channel.isEmpty

        Task { [weak self] in
            let result: UpdateCheckResult
            do {
                result = try await UpdateCheckService().checkForUpdate(
                    currentVersion: current,
                    includePrereleases: includePrereleases
                )
            } catch {
                AppLog.library.warning("Update check failed: \(String(describing: error), privacy: .public)")
                if userInitiated {
                    await MainActor.run {
                        self?.appAlert = .error(
                            title: "Couldn't Check for Updates",
                            message: "The releases feed couldn't be reached. Check your connection and try again."
                        )
                    }
                }
                return
            }
            await MainActor.run {
                self?.presentUpdateResult(result, userInitiated: userInitiated)
            }
        }
    }

    private func presentUpdateResult(_ result: UpdateCheckResult, userInitiated: Bool) {
        prefs.lastUpdateCheckDate = Date()

        switch result {
        case .upToDate:
            if userInitiated {
                appAlert = .info(
                    title: "You're Up to Date",
                    message: "\(AppVersion.currentDisplayString) is the newest version."
                )
            }
        case .updateAvailable(let release):
            // The background check announces each new version once; a manual
            // check always shows it.
            if !userInitiated, prefs.lastNotifiedUpdateTag == release.tagName {
                return
            }
            prefs.lastNotifiedUpdateTag = release.tagName
            appAlert = .actionable(
                title: "Update Available",
                message: "\(release.name) is out — you're on \(AppVersion.currentDisplayString). The download page has the release notes and the DMG.",
                actionTitle: "Download"
            ) {
                NSWorkspace.shared.open(release.htmlURL)
            }
        }
    }
}
