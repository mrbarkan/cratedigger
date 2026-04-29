import AppKit
import CrateDiggerCore
import SwiftUI

final class PreferencesWindowController: NSWindowController {
    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 360),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "CrateDigger Preferences"
        window.titlebarAppearsTransparent = false
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("CrateDiggerPreferences")

        let host = NSHostingController(rootView: PreferencesView())
        window.contentViewController = host

        self.init(window: window)
    }
}

private struct PreferencesView: View {
    var body: some View {
        TabView {
            GeneralPreferencesView()
                .tabItem { Label("General", systemImage: "gearshape") }
            AdvancedPreferencesView()
                .tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }
        }
        .frame(minWidth: 480, minHeight: 320)
        .padding(20)
    }
}

private struct GeneralPreferencesView: View {
    @State private var outputFolderPath: String = ""

    var body: some View {
        Form {
            Section("Default output folder") {
                HStack(alignment: .firstTextBaseline) {
                    Text(displayPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .foregroundStyle(displayPath == "Not set" ? .secondary : .primary)
                    Button("Choose…") { chooseFolder() }
                    Button("Reveal") { revealFolder() }
                        .disabled(currentURL == nil)
                    Button("Clear") { clearFolder() }
                        .disabled(currentURL == nil)
                }
                Text("Used as the destination for converted files. The first conversion will prompt you if this is empty.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { refresh() }
    }

    private var currentURL: URL? {
        guard let data = PreferencesStore.shared.savedOutputDestinationBookmark else { return nil }
        return PreferencesStore.resolveBookmark(data)?.url
    }

    private var displayPath: String {
        currentURL?.path ?? "Not set"
    }

    private func refresh() {
        outputFolderPath = displayPath
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "Choose default output folder"
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try PreferencesStore.makeBookmark(for: url)
            PreferencesStore.shared.savedOutputDestinationBookmark = data
            refresh()
        } catch {
            AppLog.prefs.warning("Could not bookmark default output folder: \(String(describing: error), privacy: .public)")
        }
    }

    private func revealFolder() {
        guard let url = currentURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func clearFolder() {
        PreferencesStore.shared.savedOutputDestinationBookmark = nil
        refresh()
    }
}

private struct AdvancedPreferencesView: View {
    @State private var ffmpegPath: String = ""
    @State private var ffprobePath: String = ""
    @State private var clickSoundsEnabled: Bool = PreferencesStore.shared.clickSoundsEnabled
    @State private var showResetConfirmation = false

    var body: some View {
        Form {
            Section("Interface") {
                Toggle("Click sounds", isOn: $clickSoundsEnabled)
                    .onChange(of: clickSoundsEnabled) { newValue in
                        PreferencesStore.shared.clickSoundsEnabled = newValue
                    }
                Text("Plays short hardware-style click sounds when you press chassis buttons. Off if you'd rather have silent chrome.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("External tools") {
                LabeledContent("ffmpeg path") {
                    HStack {
                        TextField("Auto-detect", text: $ffmpegPath, onCommit: persistFFmpeg)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: .infinity)
                        Button("Browse…") { browseFor(\.ffmpegPath) }
                    }
                }
                LabeledContent("ffprobe path") {
                    HStack {
                        TextField("Auto-detect", text: $ffprobePath, onCommit: persistFFprobe)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: .infinity)
                        Button("Browse…") { browseFor(\.ffprobePath) }
                    }
                }
                Text("Leave blank to use the bundled binaries (or system PATH for development builds). Restart the app after changing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Diagnostics") {
                Button("Open Console for CrateDigger") {
                    openConsole()
                }
                Text("Opens Console.app filtered to com.cratedigger.app for live log inspection.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Reset") {
                Button("Reset Preferences…") { showResetConfirmation = true }
                    .foregroundColor(.red)
                Text("Clears window position, recent folders, output folder, custom tool paths, and all UI state. Library files are not touched.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { refresh() }
        .alert("Reset all preferences?", isPresented: $showResetConfirmation) {
            Button("Reset", role: .destructive) { resetAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This affects only CrateDigger settings. Your music and converted files are not touched.")
        }
    }

    private struct PathBindings {
        var ffmpegPath: String
        var ffprobePath: String
    }

    private func refresh() {
        ffmpegPath = PreferencesStore.shared.customFFmpegPath ?? ""
        ffprobePath = PreferencesStore.shared.customFFprobePath ?? ""
    }

    private func persistFFmpeg() {
        PreferencesStore.shared.customFFmpegPath = ffmpegPath.isEmpty ? nil : ffmpegPath
    }

    private func persistFFprobe() {
        PreferencesStore.shared.customFFprobePath = ffprobePath.isEmpty ? nil : ffprobePath
    }

    private func browseFor(_ keyPath: WritableKeyPath<PathBindings, String>) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        panel.title = "Locate executable"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if keyPath == \PathBindings.ffmpegPath {
            ffmpegPath = url.path
            persistFFmpeg()
        } else if keyPath == \PathBindings.ffprobePath {
            ffprobePath = url.path
            persistFFprobe()
        }
    }

    private func openConsole() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") ?? URL(fileURLWithPath: "/System/Applications/Utilities/Console.app")
        // Easier: open Console.app directly. The user filters from there.
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Console.app"))
        _ = url // silence unused
    }

    private func resetAll() {
        PreferencesStore.shared.resetAll()
        refresh()
    }
}
