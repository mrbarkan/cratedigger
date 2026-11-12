import Foundation
import XCTest

/// Spec invariant I1: every byte written to a device and every file deleted
/// from one goes through `DeviceFileIO`, and only `DeviceFileExecutor` calls
/// `DeviceFileIO`'s mutators. Two checks, both by reading the sources:
///
/// 1. **Guarded code** (the device folders in Core and the App) may not call
///    any file-system mutator directly: Foundation, POSIX, streams, or a
///    shell tool launched with `Process`.
/// 2. **All of `Sources`** may not call the door's own mutators
///    (`copyDataOnly`, `writeAtomically`, `DeviceFileIO.remove`, ...)
///    anywhere but `DeviceFileExecutor.swift`, so nothing can skip the
///    volume, policy and journal checks by calling the primitives itself.
///
/// Lines are normalised before matching (backticks dropped, `x . y` and
/// `f (` closed up, `.init(` read as `(`), names match on word boundaries,
/// a method named without a call (`fm.removeItem` as a value) still counts,
/// and code after a `*/` on the same line is scanned. Crude on purpose, and
/// it fails toward flagging: a code line is flagged even when the call sits
/// in a trailing `//` comment.
///
/// A line that really writes on the Mac goes in `allowedLines` with its
/// reason. Each entry must excuse exactly one line: one that matches nothing
/// fails, so the list cannot rot, and one that matches two fails, so an
/// entry cannot quietly cover a second write added beside the first.
final class DeviceWriteDoorLintTests: XCTestCase {
    typealias Exemption = (fileSuffix: String, substring: String, reason: String)

    /// Folders (or single files) checked by rule 1, relative to the repo
    /// root, minus the file names in `excluding`.
    static let guardedPaths: [(path: String, excluding: Set<String>)] = [
        // DeviceFileIO.swift is the door itself.
        ("Sources/CrateDiggerCore/Services/DeviceFiles", excluding: ["DeviceFileIO.swift"]),
        ("Sources/CrateDiggerCore/Services/PodBox", excluding: []),
        ("Sources/CrateDiggerCore/Services/DeviceTransfer", excluding: []),
        ("Sources/CrateDiggerCore/Services/FolderCoverArtWriter.swift", excluding: []),
        ("Sources/CrateDiggerApp/UI/ExternalDevices", excluding: []),
    ]

    /// Rule 2: where the door's mutators may be called (and are defined).
    static let doorFiles = [
        "Sources/CrateDiggerCore/Services/DeviceFiles/DeviceFileIO.swift",
        "Sources/CrateDiggerCore/Services/DeviceFiles/DeviceFileExecutor.swift",
    ]

    /// Exemptions: a line in a file ending `fileSuffix` whose text contains
    /// `substring` may call a mutator, for `reason`.
    static let allowedLines: [Exemption] = [
        // The journal: everything it writes is on the Mac.
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
        // The prepared-picture cache.
        ("PodBox/ArtistPictureStore.swift", "fileManager.createDirectory(at: imageDirectory",
         "makes the prepared-picture cache in Application Support, on the Mac"),
        ("PodBox/ArtistPictureStore.swift", "try prepared.write(to: url, options: .atomic)",
         "writes a prepared picture into that cache, on the Mac"),
        ("PodBox/ArtistPictureStore.swift", "try data.write(to: fileURL, options: .atomic)",
         "saves library.cdartists in the library's index folder, on the Mac"),
        // Left-alone albums: a per-profile file in Application Support.
        ("DeviceTransfer/DeviceLeftAloneStore.swift", "try? fileManager.removeItem(at: url(for: profileID))",
         "forgets the left-alone list, a file in Application Support on the Mac"),
        ("DeviceTransfer/DeviceLeftAloneStore.swift", "try fileManager.createDirectory(at: directory",
         "makes the left-alone folder in Application Support, on the Mac"),
        ("DeviceTransfer/DeviceLeftAloneStore.swift", "try JSONEncoder().encode(sorted).write(to: url(for: profileID)",
         "saves the left-alone list in Application Support, on the Mac"),
        // Device sync: the staging folder is on the Mac.
        ("ExternalDevices/LibraryViewModel+DeviceSync.swift",
         "try? FileManager.default.createDirectory(at: stagingRoot",
         "makes the sync staging folder, which is on the Mac"),
        // Covers: a device run passes DeviceTransferDoor.writeCover; only an
        // ordinary conversion's cover takes this default.
        ("Services/FolderCoverArtWriter.swift", "try data.write(to: destination, options: .atomic)",
         "an ordinary (non-device) conversion's cover, in the destination folder the user chose"),
    ]

    // MARK: Rules

    struct Rule {
        let label: String
        let regex: NSRegularExpression

        init(_ label: String, _ pattern: String) {
            self.label = label
            // A bad pattern is a bug in this file: fail loudly at first use.
            regex = try! NSRegularExpression(pattern: pattern)
        }

        func firstMatch(in line: String) -> Int? {
            regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line))?.range.location
        }
    }

    private static let notIdent = "(?<![A-Za-z0-9_])"
    private static let endIdent = "(?![A-Za-z0-9_])"

    /// Method names that mutate, matched as a whole word whether called or
    /// passed as a value.
    static let mutatingMethods = [
        "copyItem", "moveItem", "removeItem", "trashItem", "createFile", "replaceItem", "replaceItemAt",
        "linkItem", "createSymbolicLink", "setAttributes", "createDirectory", "changeFileAttributes",
        // NSWorkspace.recycle moves to a Trash (on a device, `.Trashes`);
        // URL.setResourceValues renames with `.name` and sets other metadata.
        "recycle", "setResourceValues",
    ]
    /// C and POSIX calls distinctive enough to match as a whole word, called or not.
    static let distinctiveFunctions = [
        "unlink", "unlinkat", "renameat", "renamex_np", "renameatx_np", "rmdir", "mkdir", "mkdirat", "creat",
        "fopen", "freopen", "ftruncate", "clonefile", "clonefileat", "fclonefileat", "copyfile", "fcopyfile",
        "removexattr", "fremovexattr", "setxattr", "fsetxattr", "exchangedata", "symlinkat", "linkat",
        "lchmod", "fchmod", "fchown", "lchown", "utimes", "lutimes", "futimes", "setattrlist", "fsetattrlist",
        // Writers that create their output file themselves.
        "CGImageDestinationCreateWithURL", "AVAssetWriter", "AudioFileCreateWithURL", "ExtAudioFileCreateWithURL",
    ]
    /// Calls whose names are ordinary words: only when called.
    static let wordFunctions = ["rename", "truncate", "link", "symlink", "chmod", "chown", "OutputStream", "NSOutputStream"]

    static let forbidden: [Rule] = {
        var rules: [Rule] = []
        for name in mutatingMethods { rules.append(Rule(name, notIdent + name + endIdent)) }
        for name in distinctiveFunctions { rules.append(Rule(name, notIdent + name + endIdent)) }
        // A declaration ("func rename(") is not a call.
        for name in wordFunctions { rules.append(Rule(name + "(", "(?<!func )" + notIdent + name + "\\(")) }
        rules += [
            // C remove(): with its module, or bare (not a method like array.remove(at:)).
            Rule("remove(", "\(notIdent)(?:Darwin|Glibc|Foundation)\\.remove\(endIdent)|(?<!func )(?<![A-Za-z0-9_.])remove\\("),
            // Data/NSData/String writes, with or without a receiver.
            Rule("write(to:", "\(notIdent)write\\((?:to|toFile|toURL):"),
            Rule("FileHandle for writing", "\(notIdent)(?:NS)?FileHandle\\((?:forWriting|forUpdating)"),
            Rule("open for writing", "\(notIdent)O_(?:WRONLY|RDWR|CREAT|TRUNC|APPEND)\(endIdent)"),
            // A shell or a file tool launched with Process.
            Rule("file tool via Process",
                 "\"(?:/usr)?(?:/s?bin/)?(?:rm|mv|cp|ditto|rsync|unlink|rmdir|mkdir|touch|dd|ln|chmod|chown|install|srm|xattr|sh|bash|zsh)\""),
        ]
        return rules
    }()

    /// The door's mutators (rule 2).
    static let doorRules: [Rule] = [
        Rule("copyDataOnly", notIdent + "copyDataOnly" + endIdent),
        Rule("writeAtomically", notIdent + "writeAtomically" + endIdent),
        Rule("removeProvenAppleDouble", notIdent + "removeProvenAppleDouble" + endIdent),
        Rule("stripExtendedAttributes", notIdent + "stripExtendedAttributes" + endIdent),
        Rule("writeAndSync", notIdent + "writeAndSync" + endIdent),
        Rule("discardTemp", notIdent + "discardTemp" + endIdent),
        Rule("DeviceFileIO.remove", notIdent + "DeviceFileIO\\.remove" + endIdent),
        Rule("DeviceFileIO.createDirectory", notIdent + "DeviceFileIO\\.createDirectory" + endIdent),
        Rule("DeviceFileIO.rename", notIdent + "DeviceFileIO\\.rename" + endIdent),
        Rule("DeviceFileIO.renameExclusively", notIdent + "DeviceFileIO\\.renameExclusively" + endIdent),
        Rule("DeviceFileIO.removeEmptyFolders", notIdent + "DeviceFileIO\\.removeEmptyFolders" + endIdent),
        // Ways to reach those without naming them here.
        Rule("extension DeviceFileIO", "\(notIdent)extension\\s+DeviceFileIO\(endIdent)"),
        Rule("alias of DeviceFileIO", "=\\s*DeviceFileIO(?:\\.self)?\(endIdent)(?!\\.)"),
    ]

    struct Violation: Equatable, CustomStringConvertible {
        let file: String
        let line: Int
        let call: String
        let text: String
        var description: String { "\(file):\(line): \(call) in `\(text)`" }
    }

    // MARK: Scanning

    /// Backticks dropped, whitespace around `.` and before `(` or after `(`
    /// removed, `.init(` read as `(`.
    static func normalise(_ line: String) -> String {
        var text = line.replacingOccurrences(of: "`", with: "")
        for (pattern, replacement) in [("\\s*\\.\\s*", "."), ("\\s+\\(", "("), ("\\(\\s+", "("), ("\\.init\\(", "(")] {
            text = text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        return text
    }

    /// The code on one line with `/* */` comments removed; `inBlock` carries a
    /// comment that runs on to later lines. A `/*` inside a string literal is
    /// not a comment.
    static func stripBlockComments(_ line: String, inBlock: inout Bool) -> String {
        var code = ""
        var rest = Substring(line)
        while !rest.isEmpty {
            if inBlock {
                guard let end = rest.range(of: "*/") else { return code }
                rest = rest[end.upperBound...]
                inBlock = false
            } else {
                guard let start = rest.range(of: "/*") else { code += rest; break }
                let before = rest[..<start.lowerBound]
                if before.filter({ $0 == "\"" }).count % 2 == 1 { // inside a string
                    code += rest[..<start.upperBound]
                    rest = rest[start.upperBound...]
                    continue
                }
                code += before
                rest = rest[start.upperBound...]
                inBlock = true
            }
        }
        return code
    }

    /// Scans one file's source against `rules`. Returns the violations and,
    /// per `allowed` entry, how many lines it excused.
    static func scan(_ source: String, file: String, rules: [Rule] = forbidden,
                     allowed: [Exemption] = allowedLines) -> (violations: [Violation], usedExemptions: [Int: Int]) {
        var violations: [Violation] = []
        var used: [Int: Int] = [:]
        var inBlock = false
        let mayCallDoor = doorFiles.contains { file.hasSuffix($0) }
        for (index, rawLine) in source.components(separatedBy: "\n").enumerated() {
            let code = stripBlockComments(rawLine, inBlock: &inBlock).trimmingCharacters(in: .whitespaces)
            if code.isEmpty || code.hasPrefix("//") { continue }
            var normalised = normalise(code)
            if mayCallDoor {
                // The executor calls the door by name; that is the point of it.
                normalised = normalised.replacingOccurrences(
                    of: "DeviceFileIO\\.[A-Za-z_]+", with: "DeviceFileIO.door", options: .regularExpression)
            }
            let hits = rules.compactMap { rule in rule.firstMatch(in: normalised).map { (rule.label, $0) } }
            guard let call = hits.min(by: { $0.1 < $1.1 })?.0 else { continue }
            if let exemption = allowed.indices.first(where: {
                file.hasSuffix(allowed[$0].fileSuffix) && code.contains(allowed[$0].substring)
            }) {
                used[exemption, default: 0] += 1
                continue
            }
            violations.append(Violation(file: file, line: index + 1, call: call, text: code))
        }
        return (violations, used)
    }

    /// One line on its own, for the spelling tests.
    static func hits(_ line: String, rules: [Rule] = forbidden, file: String = "Planted.swift") -> Int {
        scan(line, file: file, rules: rules, allowed: []).violations.count
    }

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // CrateDiggerCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent()
    }

    /// The Swift files under one path, sorted. nil when it is missing.
    private static func sources(_ path: String, excluding: Set<String> = []) -> [URL]? {
        let url = repoRoot.appendingPathComponent(path)
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) else { return nil }
        guard isFolder.boolValue else { return [url] }
        let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil)
        return (walker?.allObjects as? [URL] ?? [])
            .filter { $0.pathExtension == "swift" && !excluding.contains($0.lastPathComponent) }
            .sorted { $0.path < $1.path }
    }

    private static func relative(_ url: URL) -> String {
        String(url.path.dropFirst(repoRoot.path.count + 1))
    }

    // MARK: Tests

    func testNoDirectFileMutationOutsideTheDoor() throws {
        var violations: [Violation] = []
        var used: [Int: Int] = [:]
        var scanned = 0

        // Rule 1: guarded code calls no mutator.
        for guarded in Self.guardedPaths {
            guard let files = Self.sources(guarded.path, excluding: guarded.excluding) else {
                XCTFail("\(guarded.path) is guarded but does not exist; was it moved?")
                continue
            }
            for file in files {
                let result = Self.scan(try String(contentsOf: file, encoding: .utf8), file: Self.relative(file))
                violations += result.violations
                used.merge(result.usedExemptions, uniquingKeysWith: +)
                scanned += 1
            }
        }
        XCTAssertGreaterThan(scanned, 15, "the lint read almost nothing; is the repo root right?")

        // Rule 2: nothing in Sources calls the door's mutators but the executor.
        let everything = try XCTUnwrap(Self.sources("Sources"))
        XCTAssertGreaterThan(everything.count, 200)
        for file in everything where !Self.doorFiles.contains(Self.relative(file)) {
            let result = Self.scan(try String(contentsOf: file, encoding: .utf8), file: Self.relative(file),
                                   rules: Self.doorRules)
            violations += result.violations
            used.merge(result.usedExemptions, uniquingKeysWith: +)
        }

        for violation in violations {
            XCTFail("Device file mutation outside the door: \(violation). Go through DeviceFileExecutor, or add an allowedLines entry with a reason if this writes only on the Mac.")
        }
        for index in Self.allowedLines.indices {
            let entry = Self.allowedLines[index]
            switch used[index, default: 0] {
            case 1:
                break
            case 0:
                XCTFail("allowedLines entry matches nothing any more, remove it: \(entry.fileSuffix) / \(entry.substring)")
            case let count:
                XCTFail("allowedLines entry excuses \(count) lines, not one; give each its own entry: \(entry.fileSuffix) / \(entry.substring)")
            }
        }
    }

    func testEveryExemptionHasAReason() {
        for entry in Self.allowedLines {
            XCTAssertFalse(entry.reason.trimmingCharacters(in: .whitespaces).isEmpty, entry.substring)
            XCTAssertFalse(entry.substring.isEmpty, entry.fileSuffix)
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
                                  call: "removeItem", text: "try fm.removeItem(at: x)")])
    }

    /// Every way round the old substring match the review found, and the
    /// calls it asked for. Each must be caught.
    func testBypassSpellingsAreCaught() {
        let spellings = [
            // Spelling.
            "try fm.`removeItem`(at: x)",
            "try fm.removeItem (at: x)",
            "try fm . removeItem(at: x)",
            "try fm.removeItem( at: x)",
            "let zap = fm.removeItem",                    // a method reference, no paren
            "let zap = FileManager.removeItem(at:)",
            "try FileManager.default",                   // (first line of a call split over two)
            "    .removeItem(at: x)",                    // (its second line)
            "/* hidden */ try fm.removeItem(at: x)",     // after a block comment on the same line
            "try fm.moveItem(at: a, to: b)",
            "try fm.copyItem(at: a, to: b)",
            "try fm.trashItem(at: a, resultingItemURL: nil)",
            "_ = try fm.replaceItemAt(a, withItemAt: b)",
            "fm.createFile(atPath: p, contents: d)",
            "try fm.createDirectory(atPath: p, withIntermediateDirectories: true)",
            "try fm.setAttributes([:], ofItemAtPath: p)",
            "try fm.createSymbolicLink(at: a, withDestinationURL: b)",
            "try fm.linkItem(at: a, to: b)",
            // Writes.
            "try data.write(to: url)",
            "try write(to: url)",                        // implicit self
            "try data.write(to: url, options: .atomic)",
            "try text.write(toFile: p, atomically: true, encoding: .utf8)",
            "let h = try FileHandle(forWritingTo: url)",
            "let h = try FileHandle.init(forWritingTo: url)",
            "let h = FileHandle(forUpdatingAtPath: p)",
            "let h = FileHandle(forWritingAtPath: p)",
            "let s = OutputStream(url: url, append: false)",
            "let s = OutputStream(toFileAtPath: p, append: true)",
            "let fd = open(p, O_WRONLY)",
            "let fd = open(p, O_RDWR)",
            "let fd = open(p, O_CREAT | O_EXCL, 0o644)",
            // POSIX.
            "Darwin.remove(p)",
            "remove(p)",
            "unlink(p)",
            "Darwin.unlink(p)",
            "let f = unlink",
            "unlinkat(fd, p, 0)",
            "rename(a, b)",
            "Darwin.rename(a, b)",
            "renameat(fd, a, fd, b)",
            "renamex_np(a, b, UInt32(RENAME_SWAP))",
            "rmdir(p)",
            "mkdir(p, 0o755)",
            "creat(p, 0o644)",
            "let f = fopen(p, \"w\")",
            "truncate(p, 0)",
            "try handle.truncate(atOffset: 0)",
            "clonefile(a, b, 0)",
            "copyfile(a, b, nil, copyfile_flags_t(COPYFILE_DATA))",
            "setxattr(p, n, v, 1, 0, 0)",
            "removexattr(p, n, 0)",
            "symlink(a, b)",
            "chmod(p, 0o644)",
            // A tool launched with Process.
            "process.executableURL = URL(fileURLWithPath: \"/bin/rm\")",
            "process.arguments = [\"rm\", \"-rf\", path]",
            "process.executableURL = URL(fileURLWithPath: \"/bin/mv\")",
            "process.executableURL = URL(fileURLWithPath: \"/bin/cp\")",
            "Process.launchedProcess(launchPath: \"/usr/bin/ditto\", arguments: [a, b])",
            "process.executableURL = URL(fileURLWithPath: \"/bin/sh\")",
            // File writers the first version missed.
            "NSWorkspace.shared.recycle([url]) { _, _ in }",
            "try await NSWorkspace.shared.recycle([url])",
            "try url.setResourceValues(values)",
            "var values = URLResourceValues(); values.name = n; try target.setResourceValues(values)",
            "let dest = CGImageDestinationCreateWithURL(url as CFURL, type, 1, nil)",
            "let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)",
            "AudioFileCreateWithURL(url as CFURL, kAudioFileM4AType, &format, [], &file)",
            "ExtAudioFileCreateWithURL(url as CFURL, kAudioFileM4AType, &format, nil, 0, &file)",
        ]
        // The split call: its second line must be caught on its own.
        for spelling in spellings where spelling != "try FileManager.default" {
            XCTAssertEqual(Self.hits(spelling), 1, spelling)
        }
    }

    func testDoorCallsOutsideTheExecutorAreCaught() {
        let calls = [
            "try DeviceFileIO.copyDataOnly(from: a, to: b)",
            "try DeviceFileIO.writeAtomically(data, to: b)",
            "try DeviceFileIO.remove(url)",
            "try DeviceFileIO . remove(url)",
            "try DeviceFileIO.createDirectory(url)",
            "DeviceFileIO.stripExtendedAttributes(at: url)",
            "_ = try DeviceFileIO.removeProvenAppleDouble(url, proof: p)",
            "let w = DeviceFileIO.writeAtomically",
            "typealias IO = DeviceFileIO",
            "let io = DeviceFileIO.self",
            "extension DeviceFileIO {",
        ]
        for call in calls {
            XCTAssertEqual(Self.hits(call, rules: Self.doorRules, file: "Sources/CrateDiggerApp/Somewhere.swift"), 1,
                           call)
        }
        // The executor may: that is the door.
        for call in calls.prefix(7) {
            XCTAssertEqual(Self.hits(call, rules: Self.doorRules,
                                     file: "Sources/CrateDiggerCore/Services/DeviceFiles/DeviceFileExecutor.swift"),
                           0, call)
            XCTAssertEqual(Self.hits(call, rules: Self.forbidden,
                                     file: "Sources/CrateDiggerCore/Services/DeviceFiles/DeviceFileExecutor.swift"),
                           0, call)
        }
        // Reading through DeviceFileIO is fine anywhere.
        for read in ["let h = try DeviceFileIO.sha256(of: url)", "DeviceFileIO.isAppleDoubleHeader(header)",
                     "let t = path + DeviceFileIO.tempSuffix"] {
            XCTAssertEqual(Self.hits(read, rules: Self.doorRules, file: "Sources/CrateDiggerApp/Somewhere.swift"), 0,
                           read)
        }
    }

    func testOrdinaryCodeIsNotFlagged() {
        for line in [
            "queue.remove(at: index)",
            "names.removeAll()",
            "let renamed = true",
            "let symlinks = 3",
            "dictionary.removeValue(forKey: k)",
            "let fd = open(p, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)",
            "try handle.write(contentsOf: data)",
            "let link = url",
            "label = \"/Music/*.mp3\"",
            "createdDirectoryCount += 1",
            "public func remove(_ ids: Set<DeviceAlbumIdentity>, profileID: UUID) {",
            "func rename(_ name: String) -> String {",
        ] {
            XCTAssertEqual(Self.hits(line), 0, line)
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
        let ok = true /* unlink(p) */
        let pattern = "Music/*.mp3" // a glob in a string is not a comment
        """
        XCTAssertEqual(Self.scan(source, file: "Planted.swift").violations, [])
    }

    func testStringThatLooksLikeACommentStartDoesNotHideCode() {
        XCTAssertEqual(Self.hits("let glob = \"/*\"; try fm.removeItem(at: x)"), 1)
    }

    func testAnExemptionCountsEveryLineItExcuses() {
        let source = """
        try data.write(to: url)
        try data.write(to: url)
        """
        let file = "Sources/x/DeviceFiles/DeviceWriteJournal.swift"
        let entry = Self.allowedLines.firstIndex { $0.substring == "try data.write(to: url)" }
        let result = Self.scan(source, file: file)
        XCTAssertEqual(result.violations, [])
        XCTAssertEqual(entry.flatMap { result.usedExemptions[$0] }, 2,
                       "two lines under one entry: testNoDirectFileMutationOutsideTheDoor fails on that")
    }

    func testAllowedLineNeedsBothFileAndSubstring() {
        let line = "try data.write(to: url)"
        XCTAssertEqual(Self.scan(line, file: "Sources/x/DeviceFiles/DeviceWriteJournal.swift").violations, [])
        XCTAssertEqual(Self.scan(line, file: "Sources/x/DeviceFiles/DeviceFileExecutor.swift").violations.count, 1)
        XCTAssertEqual(Self.scan("try other.write(to: url)",
                                 file: "Sources/x/DeviceFiles/DeviceWriteJournal.swift").violations.count, 1)
    }
}
