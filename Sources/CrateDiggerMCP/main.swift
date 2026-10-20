import AssistantKit
import Foundation

// CrateDigger's MCP server, as Claude Desktop launches it: newline-delimited
// JSON-RPC on stdin and stdout, diagnostics on stderr (Claude Desktop keeps
// those in its MCP log). The handshake and the tool list are answered here,
// so the server registers even while CrateDigger is closed; each tool call is
// forwarded to the running app, which does the work.

/// The app bundle's version when this runs from inside it, else "dev".
let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
let client = AssistantSocketClient()

func log(_ message: String) {
    FileHandle.standardError.write(Data("[cratedigger-mcp] \(message)\n".utf8))
}

let server = MCPServer(
    name: AssistantTool.serverName,
    version: version,
    instructions: AssistantTool.instructions,
    tools: AssistantTool.catalog
) { tool, arguments in
    do {
        return try client.call(AssistantCall(tool: tool, arguments: arguments))
    } catch AssistantSocketError.system("connect", _) {
        // No socket file, or nobody listening on it: the app is closed, or
        // its assistant switch is off.
        return .failure("CrateDigger isn't open, or its assistant is switched off. Ask the user to open CrateDigger, then try again.")
    } catch {
        log("\(tool): \(error.localizedDescription)")
        return .failure("CrateDigger couldn't finish that: \(error.localizedDescription)")
    }
}

log("started, version \(version), socket \(AssistantSocket.defaultPath)")
while let line = readLine(strippingNewline: true) {
    guard let reply = await server.handle(line: line) else { continue }
    FileHandle.standardOutput.write(Data((reply + "\n").utf8))
}
log("stdin closed, exiting")
