import AppKit
import AssistantKit
import CrateDiggerCore
import Foundation

/// The library assistant's life in the app: the socket the MCP helper talks
/// to, the tools behind it, and the undo history. One instance, because the
/// Settings window and the Edit menu need it as much as the main window does,
/// and neither of those holds the view model.
///
/// Nothing here runs unless the hidden preference is on
/// (`PreferencesStore.assistantLabsEnabled`): no socket, no menu item, no
/// Settings section. The design is
/// `docs/superpowers/specs/2026-10-17-llm-library-assistant-design.md`.
@MainActor
final class AssistantController: ObservableObject {
    static let shared = AssistantController()

    /// Read once: the feature appears or not for the whole run.
    let isEnabled = PreferencesStore.shared.assistantLabsEnabled

    @Published private(set) var isListening = false
    @Published private(set) var listenError: String?
    /// The newest change that can be undone, for the Edit menu.
    @Published private(set) var lastChangeSummary: String?
    @Published private(set) var changeCount = 0

    private(set) var assistant: LibraryAssistant?
    private var server: AssistantSocketServer?

    private init() {}

    /// Starts serving the helper with `host` as the library. Does nothing
    /// when the feature is off or already running.
    func start(host: LibraryAssistantHost) {
        guard isEnabled, server == nil else { return }
        let assistant = LibraryAssistant(host: host, journal: AssistantJournal(fileURL: Self.journalURL))
        self.assistant = assistant
        let server = AssistantSocketServer { call in
            await AssistantController.shared.handle(call)
        }
        do {
            try server.start()
            self.server = server
            isListening = true
            listenError = nil
            AppLog.library.notice("Library assistant listening at \(server.path, privacy: .public)")
        } catch {
            isListening = false
            listenError = error.localizedDescription
            AppLog.library.error("Library assistant couldn't start: \(error.localizedDescription, privacy: .public)")
        }
        journalDidChange()
    }

    /// A debug run on a scratch library (`CRATEDIGGER_CRATES_DIR`) keeps its
    /// undo history with that library, so testing never touches the real one.
    private static var journalURL: URL {
        #if DEBUG
        if let dir = LibraryViewModel.debugCratesDirectory {
            return dir.appendingPathComponent("assistant-journal.json")
        }
        #endif
        return AssistantJournal.defaultURL
    }

    func stop() {
        server?.stop()
        server = nil
        isListening = false
    }

    private func handle(_ call: AssistantCall) async -> MCPToolResult {
        guard let assistant else { return .failure("CrateDigger's assistant isn't running.") }
        AppLog.library.info("Assistant tool call: \(call.tool, privacy: .public)")
        return await assistant.call(call)
    }

    func journalDidChange() {
        lastChangeSummary = assistant?.journal.last?.summary
        changeCount = assistant?.journal.entries.count ?? 0
    }

    func undoLast() -> MCPToolResult {
        guard let assistant else { return .failure("CrateDigger's assistant isn't running.") }
        return assistant.undoLast()
    }

    func clearHistory() {
        try? assistant?.journal.removeAll()
        journalDidChange()
    }

    // MARK: - Claude Desktop

    /// The helper Claude Desktop launches: next to the app's own executable,
    /// which is `Contents/MacOS` in the bundle and the build folder in a
    /// `swift build` run.
    var helperURL: URL {
        let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        return executable.deletingLastPathComponent().appendingPathComponent("CrateDiggerMCP")
    }

    var helperExists: Bool { FileManager.default.isExecutableFile(atPath: helperURL.path) }

    func claudeDesktopStatus() -> ClaudeDesktopConfig.Status {
        ClaudeDesktopConfig.status(of: try? Data(contentsOf: ClaudeDesktopConfig.defaultURL),
                                   helperPath: helperURL.path)
    }

    func installInClaudeDesktop() throws {
        try ClaudeDesktopConfig.install(helperPath: helperURL.path)
    }

    /// The entry to paste into another MCP client's settings by hand.
    var configSnippet: String {
        let data = try? ClaudeDesktopConfig.merged(existing: nil, helperPath: helperURL.path)
        return data.map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
}
