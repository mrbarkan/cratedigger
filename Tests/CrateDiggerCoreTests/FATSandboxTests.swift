import Darwin
import XCTest
@testable import CrateDiggerCore

/// What macOS does on a real FAT volume, settled on a disk image instead of
/// the owner's iPod (spec "How tests prove them without a device", S1 to S7).
/// Skipped unless `CRATEDIGGER_FAT_SANDBOX` names a mounted FAT volume
/// outside /Volumes:
///
///     eval "$(scripts/fat-sandbox.sh up "$SCRATCH")"
///     scripts/test.sh --filter FATSandboxTests
///     scripts/fat-sandbox.sh down "$SCRATCH"
///
/// The S findings are recorded as activities and printed; they assert only
/// what the door relies on. Each test works in a fresh folder on the image
/// and removes it afterwards.
///
/// The process may or may not be tagged with `com.apple.provenance` (a build
/// macOS has assessed is; a fresh worktree build is not), and on FAT a tagged
/// process's every new file and folder gets a `._` twin. The door's
/// assertions hold either way: where the run is untagged, `tagAsProvenance`
/// stands in, so the kernel writes the very twin a tagged run would. Files
/// and folders a test makes itself, as the owner's, go through `ownerFile`
/// and `ownerFolder`, which take their twins away again.
final class FATSandboxTests: XCTestCase {
    private var sandbox: URL!
    private var run: URL!
    private var mac: URL!

    override func setUpWithError() throws {
        guard let raw = ProcessInfo.processInfo.environment["CRATEDIGGER_FAT_SANDBOX"], !raw.isEmpty else {
            throw XCTSkip("CRATEDIGGER_FAT_SANDBOX is not set; see scripts/fat-sandbox.sh")
        }
        guard let real = realpath(raw, nil) else { throw XCTSkip("CRATEDIGGER_FAT_SANDBOX (\(raw)) does not exist") }
        let path = String(cString: real)
        free(real)
        if path == "/Volumes" || path.hasPrefix("/Volumes/") {
            throw XCTSkip("CRATEDIGGER_FAT_SANDBOX is under /Volumes; the sandbox never runs there")
        }
        var fs = statfs()
        guard statfs(path, &fs) == 0 else { throw XCTSkip("cannot read the file system at \(path)") }
        let type = withUnsafeBytes(of: fs.f_fstypename) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        guard type == "msdos" else { throw XCTSkip("\(path) is \(type), not a FAT volume") }

        sandbox = URL(fileURLWithPath: path, isDirectory: true)
        run = sandbox.appendingPathComponent("run-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: run, withIntermediateDirectories: false)
        mac = FileManager.default.temporaryDirectory
            .appendingPathComponent("FATSandboxTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: mac, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let run { try? FileManager.default.removeItem(at: run) } // on the sandbox image only
        if let mac { try? FileManager.default.removeItem(at: mac) }
    }

    // MARK: Helpers

    /// Names in a folder, `._` files included (Foundation hides them).
    private func names(_ folder: URL) -> [String] {
        (AppleDoubleSweeper.entryNames(inFolder: folder.path) ?? []).sorted()
    }

    /// Raw name bytes as the file system hands them back.
    private func rawNames(_ folder: URL) -> [[UInt8]] {
        guard let dir = opendir(folder.path) else { return [] }
        defer { closedir(dir) }
        var result: [[UInt8]] = []
        while let entry = readdir(dir) {
            let length = Int(entry.pointee.d_namlen)
            let bytes = withUnsafeBytes(of: entry.pointee.d_name) { Array($0.prefix(length)) }
            if bytes != [0x2e], bytes != [0x2e, 0x2e] { result.append(bytes) }
        }
        return result.sorted { $0.lexicographicallyPrecedes($1) }
    }

    private func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined(separator: " ") }

    private func hasTwin(_ url: URL) -> Bool {
        names(url.deletingLastPathComponent()).contains("._" + url.lastPathComponent)
    }

    /// Bytes of the attribute name list (0 = none, -1 = could not ask).
    private func attributeCount(_ url: URL) -> Int {
        listxattr(url.path, nil, 0, XATTR_NOFOLLOW)
    }

    private func setAttribute(_ url: URL, name: String = "com.example.test", value: String = "v") {
        setAttribute(url, name: name, bytes: Array(value.utf8))
    }

    private func setAttribute(_ url: URL, name: String, bytes: [UInt8]) {
        _ = bytes.withUnsafeBytes {
            setxattr(url.path, name, $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW)
        }
    }

    private func attributeValue(_ url: URL, _ name: String) -> [UInt8]? {
        let size = getxattr(url.path, name, nil, 0, 0, XATTR_NOFOLLOW)
        guard size >= 0 else { return nil }
        var value = [UInt8](repeating: 0, count: size)
        guard getxattr(url.path, name, &value, size, 0, XATTR_NOFOLLOW) == size else { return nil }
        return value
    }

    private static let provenance = AppleDoubleFile.provenanceAttribute

    /// Whether this test process is tagged: a file it creates on the Mac
    /// carries `com.apple.provenance`.
    private func processIsTagged() throws -> Bool {
        let probe = mac.appendingPathComponent("tag-probe-\(UUID().uuidString)")
        try Data().write(to: probe)
        defer { try? FileManager.default.removeItem(at: probe) }
        return DeviceFileIO.attributeNames(at: probe).contains(Self.provenance)
    }

    /// What a tagged process's file or folder carries from birth. On an
    /// untagged run this sets it, and on FAT the kernel then writes the same
    /// `._` twin it would for a tagged one; a tagged run's already has it.
    private func tagAsProvenance(_ url: URL) {
        guard !DeviceFileIO.attributeNames(at: url).contains(Self.provenance) else { return }
        setAttribute(url, name: Self.provenance, bytes: AppleDoubleFixture.provenanceValue)
    }

    /// A file the owner put there: written, then its `._` twin (a tagged
    /// run's) removed, so it reads as a plain file on the device.
    private func ownerFile(_ url: URL, _ data: Data) throws {
        try data.write(to: url)
        _ = unlink(DeviceFileIO.twinURL(of: url).path)
    }

    /// Folders the owner made, with no twins: every component under `run`.
    private func ownerFolder(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var folder = url
        while folder.path.hasPrefix(run.path + "/") {
            _ = unlink(DeviceFileIO.twinURL(of: folder).path)
            folder = folder.deletingLastPathComponent()
        }
    }

    /// Every `._` name under `folder`, relative, sorted.
    private func twins(under folder: URL) -> [String] {
        leftovers(under: folder).filter { ($0 as NSString).lastPathComponent.hasPrefix("._") }.sorted()
    }

    /// A Mac-side source file carrying an extended attribute, which is what
    /// makes macOS write a `._` twin when the attribute travels to FAT.
    private func macSource(_ name: String, _ data: Data = Data("audio bytes".utf8)) throws -> URL {
        let url = mac.appendingPathComponent(name)
        try data.write(to: url)
        setAttribute(url)
        XCTAssertGreaterThan(attributeCount(url), 0, "the Mac source should carry an attribute")
        return url
    }

    private func finding(_ name: String, _ lines: [String]) {
        let text = lines.joined(separator: "\n")
        print("FAT sandbox \(name):\n\(text)")
        XCTContext.runActivity(named: "\(name): \(lines.joined(separator: "; "))") { _ in }
    }

    private func temporaryItemsExists() -> Bool {
        names(sandbox).contains(".TemporaryItems")
    }

    private func leftovers(under folder: URL) -> [String] {
        var found: [String] = []
        for name in names(folder) {
            let url = folder.appendingPathComponent(name)
            if name.hasPrefix("._") || name.hasSuffix(DeviceFileIO.tempSuffix) { found.append(name) }
            var isFolder: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), isFolder.boolValue {
                found += leftovers(under: url).map { name + "/" + $0 }
            }
        }
        return found
    }

    // MARK: S1 to S3: which writes leave a twin or a staging folder

    func testS1WhichWritesCreateTwins() throws {
        let hadTemporaryItems = temporaryItemsExists()
        var lines: [String] = []
        func report(_ label: String, _ url: URL) {
            lines.append("\(label): twin \(hasTwin(url) ? "YES" : "no"), attributes on the copy \(attributeCount(url) > 0 ? "yes" : "none")")
        }

        let source = try macSource("source.m4a")

        let viaCopyItem = run.appendingPathComponent("copyItem.m4a")
        try FileManager.default.copyItem(at: source, to: viaCopyItem)
        report("FileManager.copyItem from a source with an attribute", viaCopyItem)

        let viaCopyfile = run.appendingPathComponent("copyfileData.m4a")
        XCTAssertEqual(copyfile(source.path, viaCopyfile.path, nil, copyfile_flags_t(COPYFILE_DATA)), 0)
        report("copyfile(COPYFILE_DATA)", viaCopyfile)

        let viaDoor = run.appendingPathComponent("copyDataOnly.m4a")
        let doorTwins = ProvenanceTwins.beforeWriting(viaDoor, through: DeviceFileIO.tempURL(for: viaDoor))
        try DeviceFileIO.copyDataOnly(from: source, to: viaDoor)
        report("DeviceFileIO.copyDataOnly (before the provenance clean-up)", viaDoor)
        DeviceFileIO.removeProvenanceTwins(doorTwins)
        report("DeviceFileIO.copyDataOnly then removeProvenanceTwins", viaDoor)

        let viaDataWrite = run.appendingPathComponent("dataWrite.jpg")
        try Data("jpeg".utf8).write(to: viaDataWrite)
        report("Data.write(to:)", viaDataWrite)

        let viaAtomic = run.appendingPathComponent("dataWriteAtomic.jpg")
        try Data("jpeg".utf8).write(to: viaAtomic, options: .atomic)
        report("Data.write(to:, .atomic)", viaAtomic)
        let atomicLeftStaging = !hadTemporaryItems && temporaryItemsExists()
        lines.append("S3 Data.write(.atomic) left .TemporaryItems at the volume root: \(atomicLeftStaging ? "YES" : "no")")

        if let ffmpeg = ExternalToolLocator().resolveOptional(.ffmpeg) {
            let viaFFmpeg = run.appendingPathComponent("ffmpeg.m4a")
            let process = Process()
            process.executableURL = ffmpeg.url
            process.arguments = ["-nostdin", "-loglevel", "error", "-f", "lavfi", "-i", "anullsrc=r=44100:cl=stereo",
                                 "-t", "0.2", "-c:a", "aac", "-y", viaFFmpeg.path]
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                report("ffmpeg writing straight to FAT", viaFFmpeg)
            } else {
                lines.append("ffmpeg: exited \(process.terminationStatus), not measured")
            }
        } else {
            lines.append("ffmpeg: not installed, not measured")
        }

        // S2: an attribute set on a FAT file, then stripped.
        let tagged = run.appendingPathComponent("tagged.mp3")
        try Data("mp3".utf8).write(to: tagged)
        setAttribute(tagged)
        lines.append("S2 setxattr on a FAT file makes a twin: \(hasTwin(tagged) ? "YES" : "no")")
        DeviceFileIO.stripExtendedAttributes(at: tagged)
        lines.append("S2 stripExtendedAttributes then removes the twin: \(hasTwin(tagged) ? "no, it stays" : "YES")")

        lines.insert("this test process is tagged with com.apple.provenance: \(try processIsTagged() ? "YES" : "no")", at: 0)
        finding("S1-S3", lines)
        // The door's own copy must never leave one; the rest is reported, not asserted.
        XCTAssertFalse(hasTwin(viaDoor))
        XCTAssertEqual(DeviceFileIO.attributeNames(at: viaDoor), [])

        if atomicLeftStaging {
            // Ours to tidy: the sandbox image, made by this test.
            try? FileManager.default.removeItem(at: sandbox.appendingPathComponent(".TemporaryItems"))
        }
    }

    func testCopyDataOnlyLeavesNoTwinOnFAT() throws {
        let source = try macSource("01 - Zebra.m4a", Data(repeating: 0x41, count: 300_000))
        let destination = run.appendingPathComponent("01 - Zebra.m4a")
        let provenanceTwins = ProvenanceTwins.beforeWriting(destination, through: DeviceFileIO.tempURL(for: destination))
        try DeviceFileIO.copyDataOnly(from: source, to: destination)
        DeviceFileIO.removeProvenanceTwins(provenanceTwins)

        XCTAssertEqual(try Data(contentsOf: destination), try Data(contentsOf: source))
        XCTAssertLessThanOrEqual(attributeCount(destination), 0)
        XCTAssertEqual(names(run), ["01 - Zebra.m4a"])
        XCTAssertEqual(leftovers(under: run), [])
    }

    func testWriteAtomicallyLeavesNoTemporaryItemsFolder() throws {
        let hadTemporaryItems = temporaryItemsExists()
        let cover = run.appendingPathComponent("cover.jpg")
        let provenanceTwins = ProvenanceTwins.beforeWriting(cover, through: DeviceFileIO.tempURL(for: cover))
        try DeviceFileIO.writeAtomically(Data([0xff, 0xd8, 0xff, 0xe0, 1, 2, 3]), to: cover)
        DeviceFileIO.removeProvenanceTwins(provenanceTwins)

        XCTAssertEqual(try Data(contentsOf: cover), Data([0xff, 0xd8, 0xff, 0xe0, 1, 2, 3]))
        if !hadTemporaryItems {
            XCTAssertFalse(temporaryItemsExists(), "writeAtomically must not stage through .TemporaryItems")
        }
        XCTAssertEqual(names(run), ["cover.jpg"])
        XCTAssertEqual(leftovers(under: run), [])
    }

    // MARK: S4

    func testRenameOverExistingWorksOnFAT() throws {
        let file = run.appendingPathComponent("cover.jpg")
        try DeviceFileIO.writeAtomically(Data("first".utf8), to: file)
        try DeviceFileIO.writeAtomically(Data("second, longer".utf8), to: file)
        XCTAssertEqual(try Data(contentsOf: file), Data("second, longer".utf8))

        let other = run.appendingPathComponent("other.jpg")
        try Data("third".utf8).write(to: other)
        XCTAssertEqual(Darwin.rename(other.path, file.path), 0, String(cString: strerror(errno)))
        XCTAssertEqual(try Data(contentsOf: file), Data("third".utf8))
        XCTAssertEqual(names(run).filter { !$0.hasPrefix("._") }, ["cover.jpg"], "a tagged run's twins aside")
    }

    // MARK: S5, S6: what names become

    func testS5NFDNameBytes() throws {
        let nfd = "Gdan\u{0301}sk.m4a"
        let nfc = nfd.precomposedStringWithCanonicalMapping
        XCTAssertNotEqual(Array(nfd.utf8), Array(nfc.utf8))
        try DeviceFileIO.writeAtomically(Data("x".utf8), to: run.appendingPathComponent(nfd))

        let stored = rawNames(run).filter { !$0.starts(with: Array("._".utf8)) } // a tagged run's twin aside
        var nfcStat = stat()
        var nfdStat = stat()
        finding("S5", [
            "written as NFD bytes: \(hex(Array(nfd.utf8)))",
            "stored as: \(stored.map(hex).joined(separator: " | "))",
            "stored bytes are NFC: \(stored.contains(Array(nfc.utf8)) ? "YES" : "no"), NFD: \(stored.contains(Array(nfd.utf8)) ? "YES" : "no")",
            "found by its NFC name: \(stat(run.appendingPathComponent(nfc).path, &nfcStat) == 0 ? "YES" : "no"), by its NFD name: \(stat(run.appendingPathComponent(nfd).path, &nfdStat) == 0 ? "YES" : "no")",
        ])
        XCTAssertEqual(stored.count, 1)
    }

    func testS6QuestionMarkAndTrailingDot() throws {
        var lines: [String] = []
        for name in ["What?.m4a", "Trailing.", "Trailing space ", "Dots...m4a"] {
            let url = run.appendingPathComponent(name)
            do {
                try DeviceFileIO.writeAtomically(Data(name.utf8), to: url)
                let readable = (try? Data(contentsOf: url)) == Data(name.utf8)
                lines.append("\"\(name)\": written, read back by the same name: \(readable ? "YES" : "no")")
            } catch {
                lines.append("\"\(name)\": refused, \(error.localizedDescription)")
            }
        }
        lines.append("stored names: \(rawNames(run).map { "\"\(String(decoding: $0, as: UTF8.self))\" (\(hex($0)))" }.joined(separator: ", "))")
        finding("S6", lines)
        XCTAssertEqual(leftovers(under: run).filter { $0.hasSuffix(DeviceFileIO.tempSuffix) }, [],
                       "no temp may survive a refused name")
    }

    // MARK: S7: the executor on real FAT

    func testExecutorSuiteOnFAT() throws {
        let album = "Music/Beach House/2010 Teen Dream"
        let track = "\(album)/01 - Zebra.m4a"
        let coverPath = "\(album)/cover.jpg"
        let source = try macSource("zebra.m4a", Data(repeating: 0x42, count: 200_000))
        let journal = DeviceWriteJournal(profileID: UUID(), directory: mac.appendingPathComponent("journal"))
        let uuid = DeviceFileExecutor.systemVolumeUUID(run)
        // `run` is a folder on the FAT image, not its mount point, so the test opts out of that one check.
        let executor = DeviceFileExecutor(volumeRoot: run, expectedVolumeUUID: uuid,
                                          policy: DeviceWritePolicy(musicSubpath: "Music"), journal: journal,
                                          rootMustBeMountPoint: false)
        let session = UUID()

        // Create.
        let create: [DeviceFileOperation] = [
            .write(relativePath: track, role: .audio, contents: .file(source)),
            .write(relativePath: coverPath, role: .cover, contents: .data(Data("cover v1".utf8))),
        ]
        XCTAssertEqual(executor.apply(create, sessionID: session), [.written, .written])
        XCTAssertEqual(try Data(contentsOf: run.appendingPathComponent(track)), try Data(contentsOf: source))
        XCTAssertEqual(leftovers(under: run), [])

        // Unchanged, dates kept.
        let dateBefore = try FileManager.default.attributesOfItem(
            atPath: run.appendingPathComponent(coverPath).path)[.modificationDate] as? Date
        XCTAssertEqual(executor.apply(create, sessionID: session), [.unchanged, .unchanged])
        XCTAssertEqual(try FileManager.default.attributesOfItem(
            atPath: run.appendingPathComponent(coverPath).path)[.modificationDate] as? Date, dateBefore)

        // Replace an owned file: backed up on the Mac first.
        XCTAssertEqual(executor.apply([.write(relativePath: coverPath, role: .cover,
                                              contents: .data(Data("cover v2".utf8)))], sessionID: session),
                       [.written])
        let replaced = try XCTUnwrap(journal.ownedRecord(forKey: DeviceWritePolicy.key(forRelativePath: coverPath)))
        XCTAssertEqual(replaced.kind, .replaced)
        XCTAssertEqual(try Data(contentsOf: journal.folder.appendingPathComponent(try XCTUnwrap(replaced.backupFile))),
                       Data("cover v1".utf8))

        // A foreign file is refused.
        try ownerFile(run.appendingPathComponent("\(album)/folder.jpg"), Data("the owner's".utf8))
        try ownerFile(run.appendingPathComponent("Music/Beach House/cover.jpg"), Data("the owner's".utf8))
        XCTAssertEqual(executor.apply([.write(relativePath: "Music/Beach House/cover.jpg", role: .cover,
                                              contents: .data(Data("ours".utf8)))], sessionID: session),
                       [.refusedForeign])

        // A proven twin is swept; a look-alike stays.
        try FakeIPod.appleDoubleBytes().write(to: run.appendingPathComponent("\(album)/._02 - Norway.m4a"))
        let lookAlike = Data([0, 0, 0, 0x20]) + Data("ftypM4A ".utf8) + Data(count: 64)
        try lookAlike.write(to: run.appendingPathComponent("\(album)/._03 - Lover.m4a"))
        let sweep = AppleDoubleSweeper().plan(volumeRoot: run, scope: nil,
                                              mediaExtensions: AppleDoubleSweeper.defaultMediaExtensions)
        XCTAssertEqual(sweep.candidates, ["\(album)/._02 - Norway.m4a"])
        XCTAssertEqual(executor.apply(sweep.operations, sessionID: session), [.deleted])
        XCTAssertEqual(try Data(contentsOf: run.appendingPathComponent("\(album)/._03 - Lover.m4a")), lookAlike)
        try FileManager.default.removeItem(at: run.appendingPathComponent("\(album)/._03 - Lover.m4a"))

        // Owned delete and a user's Replace.
        XCTAssertEqual(executor.apply([.delete(relativePath: coverPath, reason: .ownedByCrateDigger),
                                       .delete(relativePath: track, reason: .userReplace)], sessionID: session),
                       [.deleted, .deleted])
        XCTAssertEqual(names(run.appendingPathComponent(album)), ["folder.jpg"])
        XCTAssertEqual(leftovers(under: run), [])
        finding("S7", ["executor create, unchanged, replace, foreign, sweep and delete on FAT: as on APFS",
                       "volume UUID reported for the image: \(uuid ?? "none")"])
    }

    /// The transfer door on real FAT (P1 Task 9): an audio copy from a source
    /// carrying an attribute lands with no `._` twin and no temp; the
    /// exclusive rename, which FAT does not offer, still refuses a file at the
    /// name (the check before a plain rename stands in); a user's Replace
    /// overwrites; a dotted folder name is refused before any write; a cover
    /// with the same bytes is left alone.
    func testTransferDoorOnFAT() throws {
        let album = "Music/R.E.M/1987 Document"
        let source = try macSource("01.m4a", Data(repeating: 0x41, count: 50_000))
        let journal = DeviceWriteJournal(profileID: UUID(), directory: mac.appendingPathComponent("journal"))
        let executor = DeviceFileExecutor(volumeRoot: run, expectedVolumeUUID: DeviceFileExecutor.systemVolumeUUID(run),
                                          policy: DeviceWritePolicy(musicSubpath: "Music"), journal: journal,
                                          rootMustBeMountPoint: false)
        let door = DeviceTransferDoor(executor: executor)
        let track = run.appendingPathComponent("\(album)/01 - Finest Worksong.m4a")

        try door.copyAudio(from: source, to: track)
        XCTAssertFalse(hasTwin(track))
        XCTAssertEqual(leftovers(under: run), [])

        // FAT has no RENAME_EXCL; the copy below meets a file at the name.
        let other = try macSource("02.m4a", Data(repeating: 0x42, count: 50_000))
        XCTAssertThrowsError(try DeviceFileIO.copyDataOnly(from: other, to: track, exclusive: true)) { error in
            XCTAssertEqual((error as? DeviceFileIOError)?.code, EEXIST)
        }
        XCTAssertThrowsError(try door.copyAudio(from: other, to: track)) { error in
            XCTAssertEqual(error as? DeviceTransferDoorError, .appeared)
        }
        XCTAssertEqual(try Data(contentsOf: track), Data(repeating: 0x41, count: 50_000))
        try door.copyAudio(from: other, to: track, overwrites: true)
        XCTAssertEqual(try Data(contentsOf: track), Data(repeating: 0x42, count: 50_000))
        XCTAssertFalse(hasTwin(track))

        XCTAssertThrowsError(try door.copyAudio(from: other, to: run.appendingPathComponent("Music/R.E.M./x.m4a")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: run.appendingPathComponent("Music/R.E.M.").path))

        let cover = run.appendingPathComponent("\(album)/cover.jpg")
        XCTAssertTrue(try door.writeCover(Data("jpeg".utf8), to: cover))
        XCTAssertFalse(try door.writeCover(Data("jpeg".utf8), to: cover))
        XCTAssertTrue(try door.removeReplacedAudio(at: track))
        XCTAssertEqual(names(run.appendingPathComponent(album)), ["cover.jpg"])
        XCTAssertEqual(leftovers(under: run), [])
        finding("Door", ["audio copy, exclusive refusal, Replace, dotted-name refusal, cover and Replace delete on FAT: no twins, no temps"])
    }

    /// P1 Task 10 on real FAT: twins macOS itself made (a Finder-style copy
    /// of a file with an attribute) in a folder a session wrote to are
    /// removed by the session's finish, with a copy on the Mac; a twin in a
    /// folder the session did not touch stays.
    func testSessionFinishSweepsRealTwinsOnFAT() throws {
        let album = run.appendingPathComponent("Music/A/B", isDirectory: true)
        let untouched = run.appendingPathComponent("Music/C/D", isDirectory: true)
        for folder in [album, untouched] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        // FileManager.copyItem carries the attribute, so macOS writes a twin (S1).
        try FileManager.default.copyItem(at: try macSource("old.m4a"), to: album.appendingPathComponent("01.m4a"))
        try FileManager.default.copyItem(at: try macSource("other.m4a"), to: untouched.appendingPathComponent("01.m4a"))
        XCTAssertTrue(hasTwin(album.appendingPathComponent("01.m4a")), "the setup needs a real twin")

        let journal = DeviceWriteJournal(profileID: UUID(), directory: mac.appendingPathComponent("journal"))
        let executor = DeviceFileExecutor(volumeRoot: run, expectedVolumeUUID: DeviceFileExecutor.systemVolumeUUID(run),
                                          policy: DeviceWritePolicy(musicSubpath: "Music"), journal: journal,
                                          rootMustBeMountPoint: false)
        let result = DeviceSessionFinish.finish(written: [album.appendingPathComponent("02.m4a")], deleted: [],
                                                changes: .audio, firmware: nil, sweeps: true, volumeRoot: run,
                                                executor: executor)

        XCTAssertEqual(result.removed, 1)
        XCTAssertFalse(hasTwin(album.appendingPathComponent("01.m4a")))
        XCTAssertTrue(hasTwin(untouched.appendingPathComponent("01.m4a")))
        XCTAssertEqual(journal.records.filter { $0.kind == .deleted }.compactMap(\.backupFile).count, 1)
        finding("Finish", ["a session's finish removed the macOS twin in the folder it wrote to and kept the other: \(result.lines.joined(separator: " "))"])
    }

    /// I4 on real FAT, where a file written into a freed directory slot can
    /// come back with the old inode number: a twin swapped between its backup
    /// and its removal must survive, and the inode seen is recorded.
    func testTwinSwappedAfterBackupIsNotDeletedOnFAT() throws {
        let twin = "Music/A/._01.m4a"
        let twinURL = run.appendingPathComponent(twin)
        try FileManager.default.createDirectory(at: twinURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try FakeIPod.appleDoubleBytes().write(to: twinURL)
        var before = stat()
        XCTAssertEqual(lstat(twinURL.path, &before), 0)
        var replacement = FakeIPod.appleDoubleBytes()
        replacement[200] = 0x55 // same size, same header, other bytes
        var after = stat()
        let executor = DeviceFileExecutor(
            volumeRoot: run, expectedVolumeUUID: DeviceFileExecutor.systemVolumeUUID(run),
            policy: DeviceWritePolicy(musicSubpath: "Music"),
            journal: DeviceWriteJournal(profileID: UUID(), directory: mac.appendingPathComponent("journal")),
            rootMustBeMountPoint: false,
            beforeAppleDoubleRemoval: { url in
                try? FileManager.default.removeItem(at: url)
                try? replacement.write(to: url)
                _ = lstat(url.path, &after)
            })
        XCTAssertEqual(executor.apply([.delete(relativePath: twin, reason: .appleDouble)], sessionID: UUID()),
                       [.refusedNotAppleDouble])
        XCTAssertEqual(try Data(contentsOf: twinURL), replacement)
        finding("S8", ["a twin deleted and rewritten between backup and removal: inode \(before.st_ino) before, \(after.st_ino) after (\(before.st_ino == after.st_ino ? "REUSED" : "new")); refused, nothing deleted"])
    }

    // MARK: S9 and the provenance twin

    /// What the kernel writes for `com.apple.provenance` on FAT is what
    /// `AppleDoubleFixture` builds, byte for byte (the debug tag aside), and
    /// what `AppleDoubleFile` reads as provenance only; a twin that also
    /// carries another attribute is not. Also reports what a rename does to
    /// twins (S9), which is the kernel's doing, not the door's.
    func testKernelProvenanceTwinMatchesTheFixture() throws {
        let tagged = try processIsTagged()
        let song = run.appendingPathComponent("song.m4a")
        try Data("hi".utf8).write(to: song)
        tagAsProvenance(song)
        let value = try XCTUnwrap(attributeValue(song, Self.provenance))
        let twinURL = DeviceFileIO.twinURL(of: song)
        var kernelTwin = try Data(contentsOf: twinURL)
        var fixture = AppleDoubleFixture.twin(attributes: [(Self.provenance, value)])
        kernelTwin.replaceSubrange(88..<92, with: Data(count: 4)) // the ATTR header's debug tag
        fixture.replaceSubrange(88..<92, with: Data(count: 4))
        XCTAssertEqual(kernelTwin, fixture)
        XCTAssertEqual(AppleDoubleFile(kernelTwin)?.holdsOnlyProvenance, true)

        let folder = run.appendingPathComponent("Folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        tagAsProvenance(folder)
        XCTAssertEqual(AppleDoubleFile(try Data(contentsOf: DeviceFileIO.twinURL(of: folder)))?.holdsOnlyProvenance, true)

        setAttribute(song)
        let richer = try XCTUnwrap(AppleDoubleFile(try Data(contentsOf: twinURL)))
        XCTAssertEqual(richer.attributeNames, [Self.provenance, "com.example.test"])
        XCTAssertFalse(richer.holdsOnlyProvenance)

        // S9: a rename moves the source's twin onto the destination's, and
        // where the source has none it deletes the destination's.
        let orphan = run.appendingPathComponent("a.jpg")
        try FakeIPod.appleDoubleBytes().write(to: DeviceFileIO.twinURL(of: orphan))
        let incoming = run.appendingPathComponent("a.jpg.cdtmp")
        try ownerFile(incoming, Data("jpeg".utf8))
        XCTAssertEqual(Darwin.rename(incoming.path, orphan.path), 0)
        let orphanSurvived = FileManager.default.fileExists(atPath: DeviceFileIO.twinURL(of: orphan).path)
        // A `._` file of its own: can it have a twin?
        let twinOfTwin = run.appendingPathComponent("._b.m4a")
        try FakeIPod.appleDoubleBytes().write(to: twinOfTwin)
        tagAsProvenance(twinOfTwin)
        finding("S9", [
            "this test process is tagged with com.apple.provenance: \(tagged ? "YES" : "no")",
            "the kernel's provenance twin matches the fixture: \(kernelTwin == fixture ? "YES" : "no")",
            "rename onto a name whose orphan twin was there, from a source with none, keeps that twin: \(orphanSurvived ? "YES" : "no, the rename deleted it")",
            "a `._` file gets a twin of its own: \(names(run).contains("._._b.m4a") ? "YES" : "no")",
        ])
    }

    /// The door on real FAT with every write's provenance twin made by the
    /// kernel (by a tagged run itself, by `tagAsProvenance` on an untagged
    /// one): new folders, an audio copy, a Replace, covers and a second
    /// album, and afterwards no `._` file anywhere.
    func testDoorLeavesNoProvenanceTwinOnFAT() throws {
        var landed: [String] = []
        var twinsMade = 0
        let journal = DeviceWriteJournal(profileID: UUID(), directory: mac.appendingPathComponent("journal"))
        let executor = DeviceFileExecutor(
            volumeRoot: run, expectedVolumeUUID: DeviceFileExecutor.systemVolumeUUID(run),
            policy: DeviceWritePolicy(musicSubpath: "Music"), journal: journal, rootMustBeMountPoint: false,
            afterLanding: { url in
                self.tagAsProvenance(url)
                landed.append(url.lastPathComponent)
                if self.hasTwin(url) { twinsMade += 1 }
            })
        let door = DeviceTransferDoor(executor: executor)
        let album = run.appendingPathComponent("Music/Beach House/2010 Teen Dream", isDirectory: true)
        let track = album.appendingPathComponent("01 - Zebra.m4a")

        try door.copyAudio(from: try macSource("zebra.m4a", Data(repeating: 0x41, count: 40_000)), to: track)
        try door.copyAudio(from: try macSource("silver.m4a", Data(repeating: 0x42, count: 40_000)),
                           to: album.appendingPathComponent("02 - Silver Soul.m4a"))
        try door.copyAudio(from: try macSource("zebra2.m4a", Data(repeating: 0x43, count: 40_000)), to: track,
                           overwrites: true)
        XCTAssertTrue(try door.writeCover(Data("cover v1".utf8), to: album.appendingPathComponent("cover.jpg")))
        XCTAssertTrue(try door.writeCover(Data("cover v2".utf8), to: album.appendingPathComponent("cover.jpg")))
        XCTAssertTrue(try door.writeCover(Data("low".utf8), to: run.appendingPathComponent("Music/Low/2001 Things/cover.jpg"),
                                          replacesExisting: false))

        XCTAssertEqual(landed, ["Music", "Beach House", "2010 Teen Dream", "01 - Zebra.m4a", "02 - Silver Soul.m4a",
                                "01 - Zebra.m4a", "cover.jpg", "cover.jpg", "Low", "2001 Things", "cover.jpg"])
        XCTAssertEqual(twinsMade, landed.count, "the kernel made a twin for every file and folder the door wrote")
        XCTAssertEqual(twins(under: run), [], "and the door took every one of them away")
        XCTAssertEqual(leftovers(under: run), [])
        XCTAssertEqual(journal.records.filter { $0.kind != .tempIntent }.map { ($0.relativePath as NSString).lastPathComponent },
                       ["01 - Zebra.m4a", "02 - Silver Soul.m4a", "01 - Zebra.m4a", "cover.jpg", "cover.jpg", "cover.jpg"],
                       "nothing is journalled for a twin")
        finding("Provenance", ["\(twinsMade) provenance twins made by the kernel for door writes on FAT, \(twins(under: run).count) left"])
    }

    /// A twin that was there before the write, and a new one that carries
    /// another attribute, are both left where they are.
    func testDoorLeavesPreexistingAndRicherTwinsOnFAT() throws {
        try ownerFolder(run.appendingPathComponent("Music", isDirectory: true))
        let orphan = run.appendingPathComponent("Music/._Low")
        try AppleDoubleFixture.provenanceOnly().write(to: orphan)
        let executor = DeviceFileExecutor(
            volumeRoot: run, expectedVolumeUUID: DeviceFileExecutor.systemVolumeUUID(run),
            policy: DeviceWritePolicy(musicSubpath: "Music"),
            journal: DeviceWriteJournal(profileID: UUID(), directory: mac.appendingPathComponent("journal")),
            rootMustBeMountPoint: false,
            afterLanding: { url in
                self.tagAsProvenance(url)
                if url.path.hasSuffix("Slowdive/cover.jpg") { self.setAttribute(url) } // something else, too
            })
        let door = DeviceTransferDoor(executor: executor)

        XCTAssertTrue(try door.writeCover(Data("low".utf8), to: run.appendingPathComponent("Music/Low/cover.jpg")))
        XCTAssertTrue(try door.writeCover(Data("souvlaki".utf8), to: run.appendingPathComponent("Music/Slowdive/cover.jpg")))

        XCTAssertEqual(twins(under: run), ["Music/._Low", "Music/Slowdive/._cover.jpg"])
        let richer = try XCTUnwrap(AppleDoubleFile(try Data(contentsOf: run.appendingPathComponent("Music/Slowdive/._cover.jpg"))))
        XCTAssertTrue(richer.attributeNames?.contains("com.example.test") ?? false)
        XCTAssertNotNil(AppleDoubleFile(try Data(contentsOf: orphan)), "the twin that was there is still there")
    }
}
