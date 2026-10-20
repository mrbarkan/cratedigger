import AssistantKit
import XCTest

final class AssistantKitTests: XCTestCase {

    // MARK: - JSONValue

    func testJSONValueRoundTripsAndKeepsWholeNumbersWhole() throws {
        let value: JSONValue = ["id": 7, "ratio": 0.5, "ok": true, "none": .null, "tags": ["a", "b"]]
        let text = value.encodedString()
        XCTAssertTrue(text.contains("\"id\":7"), text)          // not 7.0: ids are matched by value
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)), value)
    }

    func testIntValueAcceptsWholeNumbersAndNumericStrings() {
        XCTAssertEqual(JSONValue.number(20).intValue, 20)
        XCTAssertEqual(JSONValue.string(" 20 ").intValue, 20)
        XCTAssertNil(JSONValue.number(2.5).intValue)
        XCTAssertNil(JSONValue.bool(true).intValue)
    }

    // MARK: - MCPServer

    private func server(calls: CallLog = CallLog()) -> MCPServer {
        MCPServer(name: "test", version: "1.0", instructions: "Be nice.",
                  tools: AssistantTool.catalog) { name, arguments in
            await calls.record(name, arguments)
            return MCPToolResult(text: "ran \(name)")
        }
    }

    private func reply(_ server: MCPServer, _ line: String) async throws -> JSONValue? {
        guard let text = await server.handle(line: line) else { return nil }
        return try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    func testInitializeEchoesAKnownProtocolVersion() async throws {
        let response = try await reply(server(), #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26"}}"#)
        XCTAssertEqual(response?["id"], 1)
        XCTAssertEqual(response?["result"]?["protocolVersion"], "2025-03-26")
        XCTAssertEqual(response?["result"]?["serverInfo"]?["name"], "test")
        XCTAssertEqual(response?["result"]?["instructions"], "Be nice.")
        XCTAssertNotNil(response?["result"]?["capabilities"]?["tools"])
    }

    func testInitializeAnswersAnUnknownVersionWithTheNewest() async throws {
        let response = try await reply(server(), #"{"jsonrpc":"2.0","id":"a","method":"initialize","params":{"protocolVersion":"1999-01-01"}}"#)
        XCTAssertEqual(response?["id"], "a")
        XCTAssertEqual(response?["result"]?["protocolVersion"]?.stringValue, MCPServer.supportedProtocolVersions[0])
    }

    func testNotificationsAndBlankLinesGetNoReply() async throws {
        let s = server()
        let notification = try await reply(s, #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        XCTAssertNil(notification)
        let blank = try await reply(s, "   ")
        XCTAssertNil(blank)
    }

    func testToolsListCarriesEveryToolWithSchemaAndAnnotations() async throws {
        let response = try await reply(server(), #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        let tools = try XCTUnwrap(response?["result"]?["tools"]?.arrayValue)
        XCTAssertEqual(tools.compactMap { $0["name"]?.stringValue }, AssistantTool.allCases.map(\.rawValue))
        for tool in tools {
            XCTAssertEqual(tool["inputSchema"]?["type"], "object")
            XCTAssertNotNil(tool["annotations"]?["readOnlyHint"]?.boolValue)
        }
        let overview = tools.first { $0["name"] == "library_overview" }
        XCTAssertEqual(overview?["annotations"]?["readOnlyHint"], true)
        let file = tools.first { $0["name"] == "file_into_crates" }
        XCTAssertEqual(file?["annotations"]?["readOnlyHint"], false)
        XCTAssertEqual(file?["inputSchema"]?["required"], ["summary", "assignments"])
    }

    func testToolsCallPassesArgumentsAndWrapsTheResult() async throws {
        let calls = CallLog()
        let response = try await reply(server(calls: calls),
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"search_tracks","arguments":{"genre":"jazz","limit":5}}}"#)
        XCTAssertEqual(response?["result"]?["content"]?.arrayValue?.first?["text"], "ran search_tracks")
        XCTAssertEqual(response?["result"]?["isError"], false)
        let recorded = await calls.all
        XCTAssertEqual(recorded.count, 1)
        XCTAssertEqual(recorded.first?.0, "search_tracks")
        XCTAssertEqual(recorded.first?.1["genre"], "jazz")
        XCTAssertEqual(recorded.first?.1["limit"]?.intValue, 5)
    }

    func testUnknownToolAndMethodAreJSONRPCErrors() async throws {
        let s = server()
        let tool = try await reply(s, #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"rm_rf"}}"#)
        XCTAssertEqual(tool?["error"]?["code"]?.intValue, -32602)
        let method = try await reply(s, #"{"jsonrpc":"2.0","id":5,"method":"resources/list"}"#)
        XCTAssertEqual(method?["error"]?["code"]?.intValue, -32601)
    }

    func testGarbageIsAParseError() async throws {
        let response = try await reply(server(), "{nope")
        XCTAssertEqual(response?["error"]?["code"]?.intValue, -32700)
        XCTAssertEqual(response?["id"], .null)
    }

    func testABatchIsAnsweredAsABatch() async throws {
        let response = try await reply(server(),
            #"[{"jsonrpc":"2.0","id":1,"method":"ping"},{"jsonrpc":"2.0","method":"notifications/x"},{"jsonrpc":"2.0","id":2,"method":"ping"}]"#)
        XCTAssertEqual(response?.arrayValue?.compactMap { $0["id"]?.intValue }, [1, 2])
    }

    func testEveryTagFieldIsInTheProposalSchema() {
        let schema = AssistantTool.proposeTagChanges.definition.inputSchema
        let fields = schema["properties"]?["changes"]?["items"]?["properties"]?.objectValue ?? [:]
        for field in AssistantTool.tagFields { XCTAssertNotNil(fields[field], field) }
        XCTAssertNotNil(fields["track_id"])
    }

    // MARK: - Socket

    private func socketPath() -> String {
        // Short on purpose: sun_path holds 104 bytes.
        let dir = URL(fileURLWithPath: "/tmp").appendingPathComponent("cd-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir.appendingPathComponent("a.sock").path
    }

    func testSocketCarriesCallsBothWays() throws {
        let path = socketPath()
        let server = AssistantSocketServer(path: path) { call in
            MCPToolResult(text: "\(call.tool):\(call.arguments["n"]?.intValue ?? -1)")
        }
        try server.start()
        defer { server.stop() }

        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        let client = AssistantSocketClient(path: path, timeout: 5)
        XCTAssertEqual(try client.call(AssistantCall(tool: "a", arguments: ["n": 1])).text, "a:1")
        XCTAssertEqual(try client.call(AssistantCall(tool: "b", arguments: ["n": 2])).text, "b:2")
    }

    func testClientReconnectsWhenTheAppRestarts() throws {
        let path = socketPath()
        let first = AssistantSocketServer(path: path) { _ in MCPToolResult(text: "first") }
        try first.start()
        let client = AssistantSocketClient(path: path, timeout: 5)
        XCTAssertEqual(try client.call(AssistantCall(tool: "x", arguments: [:])).text, "first")
        first.stop()

        let second = AssistantSocketServer(path: path) { _ in MCPToolResult(text: "second") }
        try second.start()
        defer { second.stop() }
        // Give the old connection's thread a moment to notice it was shut.
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertEqual(try client.call(AssistantCall(tool: "x", arguments: [:])).text, "second")
    }

    func testNoServerIsAConnectError() {
        let client = AssistantSocketClient(path: socketPath(), timeout: 1)
        XCTAssertThrowsError(try client.call(AssistantCall(tool: "x", arguments: [:]))) { error in
            guard case AssistantSocketError.system("connect", _) = error else {
                return XCTFail("expected a connect error, got \(error)")
            }
        }
    }

    func testASecondServerLeavesALiveSocketAlone() throws {
        let path = socketPath()
        let first = AssistantSocketServer(path: path) { _ in MCPToolResult(text: "first") }
        try first.start()
        defer { first.stop() }
        let second = AssistantSocketServer(path: path) { _ in MCPToolResult(text: "second") }
        XCTAssertThrowsError(try second.start()) { error in
            XCTAssertEqual(error as? AssistantSocketError, .alreadyServed(path))
        }
        XCTAssertEqual(try AssistantSocketClient(path: path, timeout: 5)
            .call(AssistantCall(tool: "x", arguments: [:])).text, "first")
    }

    func testAStaleSocketFileIsReplaced() throws {
        let path = socketPath()
        FileManager.default.createFile(atPath: path, contents: Data())   // left by a crash
        let server = AssistantSocketServer(path: path) { _ in MCPToolResult(text: "ok") }
        try server.start()
        defer { server.stop() }
        XCTAssertEqual(try AssistantSocketClient(path: path, timeout: 5)
            .call(AssistantCall(tool: "x", arguments: [:])).text, "ok")
    }

    func testAPathTooLongForMacOSIsRefused() {
        let path = "/tmp/" + String(repeating: "x", count: 120)
        XCTAssertThrowsError(try AssistantSocketServer(path: path) { _ in MCPToolResult(text: "") }.start()) { error in
            XCTAssertEqual(error as? AssistantSocketError, .pathTooLong(path))
        }
    }

    // MARK: - Claude Desktop config

    func testMergeAddsCrateDiggerAndKeepsEverythingElse() throws {
        let existing = Data(#"{"mcpServers":{"other":{"command":"/bin/other"}},"globalShortcut":"Cmd+Space"}"#.utf8)
        let merged = try ClaudeDesktopConfig.merged(existing: existing, helperPath: "/Apps/C.app/Contents/MacOS/CrateDiggerMCP")
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: merged) as? [String: Any])
        XCTAssertEqual(root["globalShortcut"] as? String, "Cmd+Space")
        let servers = try XCTUnwrap(root["mcpServers"] as? [String: Any])
        XCTAssertEqual((servers["other"] as? [String: Any])?["command"] as? String, "/bin/other")
        XCTAssertEqual((servers["cratedigger"] as? [String: Any])?["command"] as? String,
                       "/Apps/C.app/Contents/MacOS/CrateDiggerMCP")
        XCTAssertEqual(ClaudeDesktopConfig.status(of: merged, helperPath: "/Apps/C.app/Contents/MacOS/CrateDiggerMCP"), .installed)
        XCTAssertEqual(ClaudeDesktopConfig.status(of: merged, helperPath: "/elsewhere"),
                       .pointsElsewhere("/Apps/C.app/Contents/MacOS/CrateDiggerMCP"))
    }

    func testMergeStartsAFileThatIsMissingOrEmpty() throws {
        for existing in [nil, Data(), Data("\n".utf8)] {
            let merged = try ClaudeDesktopConfig.merged(existing: existing, helperPath: "/h")
            XCTAssertEqual(ClaudeDesktopConfig.status(of: merged, helperPath: "/h"), .installed)
        }
        XCTAssertEqual(ClaudeDesktopConfig.status(of: nil, helperPath: "/h"), .notInstalled)
    }

    func testMergeRefusesAFileItCannotRead() {
        XCTAssertThrowsError(try ClaudeDesktopConfig.merged(existing: Data("{ broken".utf8), helperPath: "/h"))
        XCTAssertThrowsError(try ClaudeDesktopConfig.merged(existing: Data("[1,2]".utf8), helperPath: "/h"))
    }

    func testInstallKeepsABackupOfThePreviousFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("Claude/claude_desktop_config.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data(#"{"theme":"dark"}"#.utf8)
        try original.write(to: url)

        try ClaudeDesktopConfig.install(helperPath: "/h", at: url)

        XCTAssertEqual(try Data(contentsOf: url.appendingPathExtension("bak")), original)
        XCTAssertEqual(ClaudeDesktopConfig.status(of: try Data(contentsOf: url), helperPath: "/h"), .installed)
    }
}

private actor CallLog {
    private(set) var all: [(String, [String: JSONValue])] = []
    func record(_ name: String, _ arguments: [String: JSONValue]) { all.append((name, arguments)) }
}
