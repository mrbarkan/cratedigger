import Foundation

/// One tool as MCP's `tools/list` describes it.
public struct MCPTool: Sendable, Equatable {
    public var name: String
    public var title: String
    public var description: String
    public var inputSchema: JSONValue
    /// MCP tool annotations. Hints for the client (Claude Desktop shows a
    /// read-only tool differently and can skip asking for one), never a
    /// security boundary: the review sheet is that.
    public var readOnly: Bool
    public var destructive: Bool

    public init(name: String, title: String, description: String,
                inputSchema: JSONValue, readOnly: Bool, destructive: Bool = false) {
        self.name = name
        self.title = title
        self.description = description
        self.inputSchema = inputSchema
        self.readOnly = readOnly
        self.destructive = destructive
    }

    var listing: JSONValue {
        [
            "name": .string(name),
            "title": .string(title),
            "description": .string(description),
            "inputSchema": inputSchema,
            "annotations": [
                "title": .string(title),
                "readOnlyHint": .bool(readOnly),
                "destructiveHint": .bool(destructive),
                // Every tool works on the user's own library and nothing else.
                "openWorldHint": false,
            ],
        ]
    }
}

/// What a tool call returns: text for the model, and whether it failed. A
/// failed call is still a successful JSON-RPC response (MCP's `isError`), so
/// the model reads the message and can explain or retry.
public struct MCPToolResult: Codable, Sendable, Equatable {
    public var text: String
    public var isError: Bool

    public init(text: String, isError: Bool = false) {
        self.text = text
        self.isError = isError
    }

    public static func failure(_ message: String) -> MCPToolResult {
        MCPToolResult(text: message, isError: true)
    }

    var response: JSONValue {
        ["content": [["type": "text", "text": .string(text)]], "isError": .bool(isError)]
    }
}

/// The JSON-RPC half of an MCP server over stdio: one message per line in,
/// at most one line out. Only what a tools-only server needs: `initialize`,
/// `ping`, `tools/list`, `tools/call` and notifications. Kept free of any I/O,
/// so it is tested by feeding it lines.
public struct MCPServer: Sendable {
    public typealias CallTool = @Sendable (_ name: String, _ arguments: [String: JSONValue]) async -> MCPToolResult

    /// Newest first. The server answers with the client's version when it
    /// knows it, else with the newest it knows; a tools-only server reads and
    /// writes the same messages in all of them.
    public static let supportedProtocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    public var name: String
    public var version: String
    public var instructions: String
    public var tools: [MCPTool]
    public var callTool: CallTool

    public init(name: String, version: String, instructions: String,
                tools: [MCPTool], callTool: @escaping CallTool) {
        self.name = name
        self.version = version
        self.instructions = instructions
        self.tools = tools
        self.callTool = callTool
    }

    enum ErrorCode: Int {
        case parse = -32700
        case invalidRequest = -32600
        case methodNotFound = -32601
        case invalidParams = -32602
    }

    /// Handles one line of input. Returns the reply line, or nil when there is
    /// nothing to send (a notification, a blank line).
    public func handle(line: String) async -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let message = try? JSONDecoder().decode(JSONValue.self, from: Data(trimmed.utf8)) else {
            return Self.error(id: .null, code: .parse, message: "Not valid JSON").encodedString()
        }
        // Batches were in 2025-03-26 and left again; answering one costs
        // nothing, so a client that sends one is served.
        if case .array(let batch) = message {
            var replies: [JSONValue] = []
            for item in batch {
                if let reply = await respond(to: item) { replies.append(reply) }
            }
            return replies.isEmpty ? nil : JSONValue.array(replies).encodedString()
        }
        return await respond(to: message)?.encodedString()
    }

    func respond(to message: JSONValue) async -> JSONValue? {
        guard let method = message["method"]?.stringValue else {
            // A response sent to us (we never ask the client anything) or junk.
            if let id = message["id"], message["result"] == nil, message["error"] == nil {
                return Self.error(id: id, code: .invalidRequest, message: "Missing method")
            }
            return nil
        }
        // No id: a notification. Never answered, whatever it is.
        guard let id = message["id"], id != .null else { return nil }
        let params = message["params"]?.objectValue ?? [:]

        switch method {
        case "initialize":
            let requested = params["protocolVersion"]?.stringValue ?? ""
            let version = Self.supportedProtocolVersions.contains(requested)
                ? requested : Self.supportedProtocolVersions[0]
            return Self.result(id: id, [
                "protocolVersion": .string(version),
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": .string(name), "version": .string(self.version)],
                "instructions": .string(instructions),
            ])
        case "ping":
            return Self.result(id: id, [:])
        case "tools/list":
            return Self.result(id: id, ["tools": .array(tools.map(\.listing))])
        case "tools/call":
            guard let toolName = params["name"]?.stringValue else {
                return Self.error(id: id, code: .invalidParams, message: "tools/call needs a tool name")
            }
            guard tools.contains(where: { $0.name == toolName }) else {
                return Self.error(id: id, code: .invalidParams, message: "Unknown tool: \(toolName)")
            }
            let arguments = params["arguments"]?.objectValue ?? [:]
            let outcome = await callTool(toolName, arguments)
            return Self.result(id: id, outcome.response)
        default:
            return Self.error(id: id, code: .methodNotFound, message: "Method not found: \(method)")
        }
    }

    static func result(id: JSONValue, _ result: JSONValue) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    static func error(id: JSONValue, code: ErrorCode, message: String) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "error": ["code": .number(Double(code.rawValue)), "message": .string(message)]]
    }
}
