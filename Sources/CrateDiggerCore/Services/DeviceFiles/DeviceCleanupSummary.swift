import Foundation

/// What CrateDigger says around a cleanup of macOS `._` files on a device:
/// the question before it, the line after it, and the hint that there is
/// something to clean. Counts are grouped as in "1,731".
public enum DeviceCleanupSummary {
    /// Said when a plan finds nothing to remove.
    public static let nothingFound = "No Mac metadata files found."

    /// The line under `nothingFound`: what was looked at and kept, if anything.
    public static func nothingFoundDetail(deviceName: String, leftAlone: [String: Int]) -> String {
        leftAloneLine(leftAlone).map { "Nothing on \(deviceName) needs removing. " + $0 }
            ?? "Nothing on \(deviceName) needs removing."
    }

    /// The confirmation before anything is removed.
    /// `folders`: the folders a scoped cleanup covers, as the owner reads
    /// them; listed when there is more than one, so a selection spanning
    /// albums says exactly where it will look.
    public static func confirmation(_ plan: AppleDoubleSweepPlan, deviceName: String,
                                    folders: [String] = []) -> (title: String, message: String) {
        let count = plan.candidates.count
        var message = count == 1
            ? "1 Mac metadata file found. It is not music. A copy is kept on this Mac."
            : "\(number(count)) Mac metadata files found. They are not music. A copy is kept on this Mac."
        if folders.count > 1 { message += " In: " + folders.joined(separator: ", ") + "." }
        if let left = leftAloneLine(plan.leftAlone) { message += " " + left }
        return ("Remove Mac files from \(deviceName)?", message)
    }

    /// The line after a cleanup: what went, what was refused at the moment of
    /// deletion (it no longer passed the proof), and what was never a candidate.
    public static func result(removed: Int, refused: Int, leftAlone: [String: Int]) -> String {
        var parts = [removed == 1 ? "Removed 1 Mac metadata file." : "Removed \(number(removed)) Mac metadata files."]
        if refused > 0 {
            parts.append(refused == 1
                ? "1 could not be verified and was left."
                : "\(number(refused)) could not be verified and were left.")
        }
        if let left = leftAloneLine(leftAlone) { parts.append(left) }
        return parts.joined(separator: " ")
    }

    /// The caption beside Clean Up Mac Files: how many `._` files PodBox's
    /// own unreadable-files list names. nil when it names none.
    public static func mountHint(count: Int) -> String? {
        guard count > 0 else { return nil }
        return count == 1 ? "PodBox is reading 1 Mac file as music." : "PodBox is reading \(number(count)) Mac files as music."
    }

    // MARK: - Private

    private static func leftAloneLine(_ leftAlone: [String: Int]) -> String? {
        let total = leftAlone.values.reduce(0, +)
        guard total > 0 else { return nil }
        return total == 1 ? "1 other file is left alone." : "\(number(total)) other files are left alone."
    }

    private static func number(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.groupingSeparator = ","
        formatter.groupingSize = 3
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
}

/// The end of every user-started write session on a device (spec 1b,
/// `finishDeviceSession`): on FAT and exFAT, the proven macOS `._` twins in
/// the folders the session wrote or deleted in are removed through the
/// executor (re-proven at the moment of deletion, a copy kept on the Mac
/// first), and the next steps on the device are worked out. It never fails
/// the session it ends: a problem becomes one line.
public enum DeviceSessionFinish {
    public struct Result: Sendable, Equatable {
        /// The summary's closing lines: a cleanup line when it removed or
        /// refused anything, then the next steps.
        public let lines: [String]
        public let removed: Int
        /// `changes`, plus `.cleanup` when anything was removed.
        public let changes: DeviceWriteChanges
    }

    /// Whether a session's finish sweeps at all: only on a FAT or exFAT
    /// volume, and only once the owner has turned the device's automatic
    /// cleanup on (off by default, behind checks M3 and M4).
    public static func sweepsAfterTransfer(capabilities: DeviceCapabilities, preferences: PodBoxPreferences) -> Bool {
        capabilities.contains(.appleDoubleSweep) && preferences.appleDoubleCleanup
    }

    /// `sweeps`: `sweepsAfterTransfer` said yes. The scope
    /// is exactly the parent folders of `written` and `deleted`, listed
    /// non-recursively.
    public static func finish(
        written: [URL],
        deleted: [URL],
        changes: DeviceWriteChanges,
        firmware: DeviceFirmware?,
        sweeps: Bool,
        volumeRoot: URL,
        sweeper: AppleDoubleSweeper = AppleDoubleSweeper(),
        executor: DeviceFileExecutor,
        sessionID: UUID = UUID()
    ) -> Result {
        var changes = changes
        var lines: [String] = []
        var removed = 0
        let scope = folders(of: written + deleted)
        if sweeps, !scope.isEmpty {
            let plan = sweeper.plan(volumeRoot: volumeRoot, scope: scope)
            if plan.refusal == nil, !plan.candidates.isEmpty {
                let outcomes = executor.apply(plan.operations, sessionID: sessionID)
                removed = outcomes.filter { $0 == .deleted }.count
                let refused = outcomes.count - removed - outcomes.filter { $0 == .alreadyGone }.count
                if removed > 0 || refused > 0 {
                    lines.append(DeviceCleanupSummary.result(removed: removed, refused: refused, leftAlone: [:]))
                }
            }
            if removed > 0 { changes.insert(.cleanup) }
        }
        lines += PodBoxNextSteps.after(changes, firmware: firmware)
        return Result(lines: lines, removed: removed, changes: changes)
    }

    /// Each distinct parent folder, in first-seen order.
    static func folders(of files: [URL]) -> [URL] {
        var seen = Set<String>()
        return files.map { $0.deletingLastPathComponent() }.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }
}
