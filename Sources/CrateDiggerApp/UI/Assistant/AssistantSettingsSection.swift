import AppKit
import AssistantKit
import SwiftUI

/// Settings ▸ Advanced, only while the hidden assistant preference is on:
/// whether the app is listening, one button to add CrateDigger to Claude
/// Desktop, and the undo history.
struct AssistantSettingsSection: View {
    @ObservedObject private var controller = AssistantController.shared
    @State private var claudeStatus: ClaudeDesktopConfig.Status = .notInstalled
    @State private var message: String?

    var body: some View {
        Section("Library Assistant (Labs)") {
            LabeledContent("Status") {
                HStack(spacing: 6) {
                    Circle()
                        .fill(controller.isListening ? Color.green : Color.red)
                        .frame(width: 8, height: 8)
                    Text(controller.isListening ? "Ready for Claude" : (controller.listenError ?? "Not running"))
                        .foregroundStyle(controller.isListening ? .primary : .secondary)
                }
            }

            LabeledContent("Claude Desktop") {
                HStack {
                    Text(statusText)
                        .foregroundStyle(.secondary)
                    Button(claudeStatus == .installed ? "Added" : "Add to Claude Desktop") { install() }
                        .disabled(claudeStatus == .installed || !controller.helperExists)
                    Button("Copy Configuration") { copyConfiguration() }
                        .disabled(!controller.helperExists)
                }
            }
            if !controller.helperExists {
                Text("This build has no CrateDiggerMCP helper beside the app, so Claude can't reach it.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            LabeledContent("Undo history") {
                HStack {
                    Text(controller.changeCount == 0
                         ? "Nothing to undo"
                         : "\(controller.changeCount) change\(controller.changeCount == 1 ? "" : "s") can be undone")
                        .foregroundStyle(.secondary)
                    Button("Clear History") { controller.clearHistory() }
                        .disabled(controller.changeCount == 0)
                }
            }

            Text("Lets Claude Desktop read your library and organise it while CrateDigger is open. Claude sees tags, crates, playlists and play counts, never file paths. Crates, playlists and streams it changes can be undone with Edit ▸ Undo AI Change; tag edits wait for you in a review sheet here before anything is written.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onAppear { refresh() }
    }

    private var statusText: String {
        switch claudeStatus {
        case .installed: return "Added"
        case .notInstalled: return "Not added"
        case .pointsElsewhere: return "Added from another copy of CrateDigger"
        }
    }

    private func refresh() {
        claudeStatus = controller.claudeDesktopStatus()
    }

    private func install() {
        do {
            try controller.installInClaudeDesktop()
            message = "Added. Quit and reopen Claude Desktop to load CrateDigger, then ask Claude about your library."
        } catch {
            message = error.localizedDescription
        }
        refresh()
    }

    private func copyConfiguration() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(controller.configSnippet, forType: .string)
        message = "Copied. Paste it into your MCP client's settings."
    }
}
