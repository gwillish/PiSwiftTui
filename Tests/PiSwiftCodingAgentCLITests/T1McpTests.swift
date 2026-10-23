import Foundation
import PiSwiftAI
import PiSwiftCodingAgent
import PiSwiftMCP
import Testing
@testable import PiSwiftCodingAgentCLI

@Suite("T1 MCP CLI")
struct T1McpTests {
    @Test func helpDescribesTheWholeSignInDeadline() {
        #expect(mcpCommandHelp.contains("--timeout <seconds>     Time limit for the whole sign-in (default: 300)"))
    }

    @Test(arguments: [false, true])
    func listReportsResourceCapabilityWithoutListingResources(_ json: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("t1-mcp-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try addMcpServerConfig(path: root.appendingPathComponent("mcp.json"), name: "docs",
            config: McpServerConfig(command: "fixture", timeout: 1))
        let lines = LockedState<[String]>([])
        let requests = LockedState<[String]>([])
        let options = McpCommandOptions(cwd: root, agentDir: root,
            log: { line in lines.withLock { $0.append(line) } },
            error: { line in lines.withLock { $0.append(line) } },
            createTransport: { _, _, _ in
                let (client, server) = InMemoryTransport.pair()
                Task {
                    while let data = try? await server.receive() {
                        guard let message = try? JsonRpc.decodeIncoming(data),
                              case .request(let request) = message else { continue }
                        requests.withLock { $0.append(request.method) }
                        let result: [String: Any]
                        switch request.method {
                        case "initialize":
                            result = ["protocolVersion": LATEST_PROTOCOL_VERSION,
                                      "capabilities": ["tools": [:], "resources": [:]],
                                      "serverInfo": ["name": "fixture", "version": "1"]]
                        case "tools/list": result = ["tools": []]
                        default: result = [:]
                        }
                        try? await server.send(JsonRpc.encodeServerResponseToLine(
                            JsonRpcServerResponse(id: request.id, result: AnyCodable(result), error: nil)))
                    }
                    await server.close()
                }
                return client
            })
        #expect(await runMcpCommand(json ? ["list", "--json"] : ["list"], options: options) == 0)
        let output = lines.withLock { $0.joined(separator: "\n") }
        if json {
            let payload = try #require(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
            let servers = try #require(payload["servers"] as? [[String: Any]])
            #expect(servers.first?["resources"] as? Bool == true)
            #expect(servers.first?["resourceTemplates"] == nil)
        } else {
            #expect(lines.withLock { $0.contains("  offers resources") })
        }
        #expect(!requests.withLock { $0.contains("resources/list") || $0.contains("resources/templates/list") })
    }
}
