import XCTest

/// Spec invariant I1: every byte written to a device and every file deleted
/// from one goes through `DeviceFileIO`. This reads the sources that touch
/// devices and fails, naming file and line, on any direct file-system
/// mutator. Crude on purpose: it is what stops the next writer walking round
/// the door. A line that really writes on the Mac (never the device) goes in
/// `allowedLines` with its reason; an entry that no longer matches anything
/// fails too, so the list cannot rot.
final class DeviceWriteDoorLintTests: XCTestCase {
    /// Folders (or single files) whose Swift sources are checked, relative to
    /// the repo root, minus the file names in `excluding`. Task 9 adds
    /// `Services/DeviceTransfer`, `FolderCoverArtWriter.swift` and
    /// `UI/ExternalDevices` once they go through the door.
    static let guardedPaths: [(path: String, excluding: Set<String>)] = [
        // DeviceFileIO.swift is the door itself.
        ("Sources/CrateDiggerCore/Services/DeviceFiles", excluding: ["DeviceFileIO.swift"]),
        ("Sources/CrateDiggerCore/Services/PodBox", excluding: []),
    ]

    /// Exemptions: a line in a file ending `fileSuffix` that contains
    /// `substring` may call a mutator, for `reason`.
    static let allowedLines: [(fileSuffix: String, substring: String, reason: String)] = [
        ("DeviceFiles/DeviceWriteJournal.swift", "fileManager.createDirectory(at: folder",
         "makes the journal's own folder in Application Support, on the Mac"),
        ("DeviceFiles/DeviceWriteJournal.swift", "fileManager.createFile(atPath: url.path",
         "creates journal.jsonl in the journal folder, on the Mac"),
        ("DeviceFiles/DeviceWriteJournal.swift", "FileHandle(forUpdating: url)",
         "appends to journal.jsonl on the Mac; opened for update to read its last byte"),
        ("DeviceFiles/DeviceWriteJournal.swift", "try data.write(to: url)",
         "writes a backup into the journal folder on the Mac"),
        ("DeviceFiles/DeviceWriteJournal.swift", "fileManager.createDirectory(at: directory",
         "makes a backup's folder inside the journal folder, on the Mac"),
        ("DeviceFiles/DeviceWriteJournal.swift", "fileManager.copyItem(at: url, to: destination)",
         "backs a device file up to the Mac: reads the device, writes only the Mac"),
    ]

    /// The plan's list, then the lower-level and older spellings of the same
    /// mutations, so swapping one call for its cousin is caught as well.
    static let forbiddenCalls = [
        "copyItem(", "moveItem(", "removeItem(", "trashItem(", "createFile(", ".write(to:",
        "FileHandle(forWritingTo", "FileHandle(forUpdating", "replaceItem",
        // Cousins.
        "write(toFile:", "FileHandle(forWritingAtPath", "FileHandle(forUpdatingAtPath",
        ".createDirectory(at:", ".createDirectory(atPath:", "createSymbolicLink", "linkItem(", "setAttributes(",
        "copyfile(", "unlink(", "rename(", "removexattr(", "setxattr(", "O_WRONLY", "O_RDWR", "O_CREAT", "O_TRUNC",
    ]

    struct Violation: Equatable, CustomStringConvertible {
        let file: String
        let line: Int
        let call: String
        let text: String
        var description: String { "\(file):\(line): \(call) in `\(text)`" }
    }

    /// Scans one file's source. Lines inside `//` and `/* */` comments are
    /// skipped; a code line is flagged even when the call sits in a trailing
    /// comment (the safe way to be wrong). Returns the violations and the
    /// indexes of the `allowed` entries that excused something.
    static func scan(_ source: String, file: String,
                     allowed: [(fileSuffix: String, substring: String, reason: String)] = allowedLines)
        -> (violations: [Violation], usedExemptions: Set<Int>) {
        var violations: [Violation] = []
        var used = Set<Int>()
        var inBlockComment = false
        for (index, rawLine) in source.components(separatedBy: "\n").enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if inBlockComment {
                if line.contains("*/") { inBlockComment = false }
                continue
            }
            if line.hasPrefix("//") { continue }
            if line.hasPrefix("/*") {
                inBlockComment = !line.contains("*/")
                continue
            }
            // The earliest call on the line, the longest at that spot ("removeItem(" over "moveItem(").
            let matches = forbiddenCalls.compactMap { call in line.range(of: call).map { (call, $0.lowerBound) } }
            guard let call = matches.min(by: { $0.1 != $1.1 ? $0.1 < $1.1 : $0.0.count > $1.0.count })?.0
            else { continue }
            if let exemption = allowed.indices.first(where: {
                file.hasSuffix(allowed[$0].fileSuffix) && line.contains(allowed[$0].substring)
            }) {
                used.insert(exemption)
                continue
            }
            violations.append(Violation(file: file, line: index + 1, call: call, text: line))
        }
        return (violations, used)
    }

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // CrateDiggerCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent()
    }

    /// The Swift files under one guarded path, sorted. nil when it is missing.
    private static func sources(_ guarded: (path: String, excluding: Set<String>)) -> [URL]? {
        let url = repoRoot.appendingPathComponent(guarded.path)
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) else { return nil }
        guard isFolder.boolValue else { return [url] }
        let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil)
        return (walker?.allObjects as? [URL] ?? [])
            .filter { $0.pathExtension == "swift" && !guarded.excluding.contains($0.lastPathComponent) }
            .sorted { $0.path < $1.path }
    }

    // MARK: Tests

    func testNoDirectFileMutationOutsideTheDoor() throws {
        var violations: [Violation] = []
        var used = Set<Int>()
        var scanned = 0
        for guarded in Self.guardedPaths {
            guard let files = Self.sources(guarded) else {
                XCTFail("\(guarded.path) is guarded but does not exist; was it moved?")
                continue
            }
            for file in files {
                let relative = String(file.path.dropFirst(Self.repoRoot.path.count + 1))
                let result = Self.scan(try String(contentsOf: file, encoding: .utf8), file: relative)
                violations += result.violations
                used.formUnion(result.usedExemptions)
                scanned += 1
            }
        }
        XCTAssertGreaterThan(scanned, 5, "the lint read almost nothing; is the repo root right?")
        for violation in violations {
            XCTFail("Device file mutation outside DeviceFileIO: \(violation). Go through DeviceFileExecutor, or add an allowedLines entry with a reason if this writes only on the Mac.")
        }
        for index in Self.allowedLines.indices where !used.contains(index) {
            let entry = Self.allowedLines[index]
            XCTFail("allowedLines entry matches nothing any more, remove it: \(entry.fileSuffix) / \(entry.substring)")
        }
    }

    func testLintCatchesAPlantedViolation() {
        let source = """
        import Foundation
        func tidy(_ fm: FileManager, _ x: URL) throws {
            try fm.removeItem(at: x)
        }
        """
        let result = Self.scan(source, file: "Sources/CrateDiggerCore/Services/PodBox/Planted.swift")
        XCTAssertEqual(result.violations,
                       [Violation(file: "Sources/CrateDiggerCore/Services/PodBox/Planted.swift", line: 3,
                                  call: "removeItem(", text: "try fm.removeItem(at: x)")])
    }

    func testEveryForbiddenCallIsCaught() {
        for call in Self.forbiddenCalls {
            let result = Self.scan("let x = y.\(call)z)", file: "Planted.swift")
            XCTAssertEqual(result.violations.count, 1, call)
        }
    }

    func testCommentsAreIgnored() {
        let source = """
        // try fm.removeItem(at: x)
            /// Never call copyItem( on a device.
        /* moveItem(
           createFile(
        */
        /* data.write(to: url) */
        let ok = true
        """
        XCTAssertEqual(Self.scan(source, file: "Planted.swift").violations, [])
    }

    func testAllowedLineNeedsBothFileAndSubstring() {
        let line = "try data.write(to: url)"
        XCTAssertEqual(Self.scan(line, file: "Sources/x/DeviceFiles/DeviceWriteJournal.swift").violations, [])
        XCTAssertEqual(Self.scan(line, file: "Sources/x/DeviceFiles/DeviceFileExecutor.swift").violations.count, 1)
        XCTAssertEqual(Self.scan("try other.write(to: url)",
                                 file: "Sources/x/DeviceFiles/DeviceWriteJournal.swift").violations.count, 1)
    }
}
