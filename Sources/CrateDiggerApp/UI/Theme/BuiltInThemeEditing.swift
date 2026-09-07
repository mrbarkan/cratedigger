import CrateDiggerCore
import Foundation

/// **Beta-only escape hatch: lets the theme editor change the shipped themes
/// in place instead of forking them.**
///
/// Normally opening Carbon in the editor gives you "Carbon Copy", a user theme
/// that inherits from it — the built-ins live in the app bundle, which is not
/// ours to write to, and reusing a built-in's id would collide with the
/// bundled copy on the next scan. That is the right behaviour for anyone
/// running the app.
///
/// While 2.0 is in beta the defaults themselves are still being tuned, and
/// doing that through a fork means hand-merging JSON back into the repo every
/// time. So during the beta the editor writes a built-in straight back to
/// **its source file in the checkout**, plus the copy inside the running
/// build's resource bundle so the change shows up without a rebuild.
///
/// Two things keep this from reaching anybody it shouldn't:
///
/// - it does nothing unless this build can see the repository it was compiled
///   from, so a packaged app behaves exactly as it does today;
/// - `isOpen` turns it off outright.
///
/// ## Closing it for the RC
///
/// Set `isOpen` to `false`. `BuiltInThemeEditingTests` asserts the flag's
/// effect either way, so the switch is one line and the tests say what it
/// does.
enum BuiltInThemeEditing {
    /// Flip to `false` for the RC.
    static let isOpen = true

    /// The theme sources in the checkout this build was compiled from, when
    /// they are still there.
    ///
    /// `#filePath` is the compile-time location of this file, the same trick
    /// `BundledThemeTests` uses to read the source themes. It resolves to
    /// nothing on any machine but the one that built the app, which is what
    /// makes this safe to ship in a beta.
    static let repositoryThemesDirectory: URL? = {
        let thisFile = URL(fileURLWithPath: #filePath)
        // .../Sources/CrateDiggerApp/UI/Theme/BuiltInThemeEditing.swift
        let target = thisFile
            .deletingLastPathComponent()  // Theme
            .deletingLastPathComponent()  // UI
            .deletingLastPathComponent()  // CrateDiggerApp
            .appendingPathComponent("Resources/Themes", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { return nil }
        return target
    }()

    /// Whether this theme may be edited in place rather than forked.
    static func isEditable(_ manifest: ThemeManifest) -> Bool {
        guard isOpen, manifest.origin == .builtIn else { return false }
        return manifestURL(forThemeID: manifest.id, in: repositoryThemesDirectory) != nil
    }

    /// Every file an edited built-in has to be written to: its source in the
    /// checkout, which is the one that lasts, and the copy in the running
    /// build's resource bundle, which is the one on screen. SwiftPM rewrites
    /// the second from the first on the next build, so they cannot drift.
    static func destinations(forThemeID themeID: String) -> [URL] {
        guard isOpen else { return [] }
        var directories = [repositoryThemesDirectory]
        directories += Bundle.crateDiggerSearchBundles.map {
            $0.resourceURL?.appendingPathComponent("Themes", isDirectory: true)
        }
        return directories.compactMap { manifestURL(forThemeID: themeID, in: $0) }
    }

    /// Writes `definition` to `destination`, keeping any top-level keys the
    /// file already carries that the model does not describe.
    ///
    /// `Llama 97` opens with a `"//"` note explaining the theme, and decoding
    /// into `ThemeDefinition` drops anything it does not know about — so a
    /// plain re-encode would quietly delete a paragraph of the author's prose
    /// the first time somebody nudged a colour. Also ends the file with a
    /// newline, which `JSONEncoder` does not.
    static func write(_ definition: ThemeDefinition, to destination: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var object = (try JSONSerialization.jsonObject(with: encoder.encode(definition))
            as? [String: Any]) ?? [:]

        if let existing = try? Data(contentsOf: destination),
           let previous = try? JSONSerialization.jsonObject(with: existing) as? [String: Any] {
            for (key, value) in previous where object[key] == nil {
                object[key] = value
            }
        }

        var data = try JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys]
        )
        data.append(0x0A)
        try data.write(to: destination, options: .atomic)
    }

    /// The `theme.json` declaring `themeID` inside `directory`.
    ///
    /// Found by reading each manifest rather than by folder name: a theme's
    /// folder is free-form, so `Llama 97.cdtheme` can perfectly well declare
    /// `"id": "llama-97"` — the same reason `ThemeAuthoringService` resolves
    /// destinations from the file a theme came from.
    static func manifestURL(forThemeID themeID: String, in directory: URL?) -> URL? {
        guard let directory,
              let entries = try? FileManager.default.contentsOfDirectory(
                  at: directory, includingPropertiesForKeys: nil
              )
        else { return nil }

        let decoder = JSONDecoder()
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where entry.pathExtension.lowercased() == "cdtheme" {
            let manifest = entry.appendingPathComponent("theme.json")
            guard let data = try? Data(contentsOf: manifest),
                  let definition = try? decoder.decode(ThemeDefinition.self, from: data),
                  definition.id == themeID
            else { continue }
            return manifest
        }
        return nil
    }
}
