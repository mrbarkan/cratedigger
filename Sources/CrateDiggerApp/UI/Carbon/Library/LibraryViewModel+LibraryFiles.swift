import AppKit
import CrateDiggerCore

/// Library-file management (File → Library): import a `.cdlib` crate, export the
/// current crate, and back up all crate indexes into a single dated `.zip`.
@MainActor
extension LibraryViewModel {

    /// The crate the Export action operates on: the open crate, else the target.
    var exportableCrateName: String {
        if case .localCrate(let name) = currentSource { return name }
        return targetCrateName
    }

    /// Import a `.cdlib` crate index into the Library File folder as a new crate.
    func importLibraryFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = "Import Library File"
        panel.message = "Choose a crate index (.cdlib) file to add to your library."
        panel.prompt = "Import"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let src = panel.url else { return }
        guard src.pathExtension.lowercased() == "cdlib" else {
            appAlert = .error(title: "Not a Library File", message: "Choose a .cdlib crate index file.")
            return
        }

        // Collision-safe name within the crates folder.
        let base = src.deletingPathExtension().lastPathComponent
        var name = base
        var dest = cratesDirectoryURL.appendingPathComponent("\(name).cdlib")
        var n = 2
        while FileManager.default.fileExists(atPath: dest.path) {
            name = "\(base) (\(n))"
            dest = cratesDirectoryURL.appendingPathComponent("\(name).cdlib")
            n += 1
        }
        do {
            try FileManager.default.copyItem(at: src, to: dest)
            refreshAvailableCrates()
            appAlert = .info(title: "Imported", message: "Added crate “\(name)” to your library.")
        } catch {
            appAlert = .error(title: "Import Failed", message: error.localizedDescription)
        }
    }

    /// Export the current crate to a `.cdlib` file anywhere (share/move a crate).
    func exportSelectedCrate() {
        let name = exportableCrateName
        let src = cratesDirectoryURL.appendingPathComponent("\(name).cdlib")
        guard FileManager.default.fileExists(atPath: src.path) else {
            appAlert = .error(title: "No Crate to Export", message: "Select a crate first.")
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(name).cdlib"
        panel.title = "Export Library File"
        panel.message = "Save “\(name)” as a .cdlib crate index file."
        panel.prompt = "Export"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        do {
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: src, to: dest)
            appAlert = .info(title: "Exported", message: "Saved “\(name).cdlib”.")
        } catch {
            appAlert = .error(title: "Export Failed", message: error.localizedDescription)
        }
    }

    /// Back up every `.cdlib` crate index into a single dated `.zip`. The audio
    /// files in the Local Library are separate and not included.
    func backUpLibrary() {
        let cratesDir = cratesDirectoryURL
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let stamp = formatter.string(from: Date())

        let panel = NSSavePanel()
        panel.nameFieldStringValue = "CrateDigger-Library-\(stamp).zip"
        panel.title = "Back Up Library"
        panel.message = "Save a .zip backup of all your crate index files. (Your audio files are separate.)"
        panel.prompt = "Back Up"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        do {
            try? FileManager.default.removeItem(at: dest)
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            proc.arguments = ["-c", "-k", "--keepParent", cratesDir.path, dest.path]
            try proc.run()
            proc.waitUntilExit()
            if proc.terminationStatus == 0 {
                let count = availableCrates.count
                appAlert = .info(
                    title: "Library Backed Up",
                    message: "Saved \(count) crate index file\(count == 1 ? "" : "s") to “\(dest.lastPathComponent)”.")
            } else {
                appAlert = .error(title: "Backup Failed", message: "Couldn't create the backup archive.")
            }
        } catch {
            appAlert = .error(title: "Backup Failed", message: error.localizedDescription)
        }
    }
}
