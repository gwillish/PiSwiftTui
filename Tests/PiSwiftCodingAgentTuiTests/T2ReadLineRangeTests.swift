import Foundation
import MiniTui
import PiSwiftAI
import PiSwiftAgent
@testable import PiSwiftCodingAgent
import Testing
@testable import PiSwiftCodingAgentTui

@MainActor @Suite(.serialized) struct T2ReadLineRangeTests {
    private var cases: [([String: AnyCodable], String)] {
        [
            (["offset": AnyCodable(25), "limit": AnyCodable(13)], ":25-37"),
            (["offset": AnyCodable("25"), "limit": AnyCodable("13")], ":25-37"),
            (["offset": AnyCodable(NSNull()), "limit": AnyCodable("13")], ":1-13"),
            (["offset": AnyCodable("25"), "limit": AnyCodable(NSNull())], ":25"),
            ([:], ""),
            (["offset": AnyCodable("abc"), "limit": AnyCodable(13)], ""),
            (["offset": AnyCodable(25), "limit": AnyCodable("")], ""),
            (["offset": AnyCodable(25), "limit": AnyCodable("Infinity")], ""),
        ]
    }

    private func selector(args: [String: AnyCodable], includeCall: Bool = true) -> TreeSelectorComponent {
        let assistant = AssistantMessage(
            content: [.toolCall(ToolCall(id: "other", name: "read", arguments: ["path": AnyCodable("other.txt")])),
                      .toolCall(ToolCall(id: "call", name: "read", arguments: args))],
            api: .anthropicMessages, provider: "anthropic", model: "test-model",
            usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
            stopReason: .toolUse, timestamp: 0
        )
        let result = SessionTreeNode(
            entry: .message(SessionMessageEntry(
                id: "result", parentId: "assistant", timestamp: "1970-01-01T00:00:00Z",
                message: .toolResult(ToolResultMessage(toolCallId: "call", toolName: "read", content: [], isError: false))
            )), children: [], label: nil
        )
        let tree = includeCall ? [SessionTreeNode(
            entry: .message(SessionMessageEntry(
                id: "assistant", parentId: nil, timestamp: "1970-01-01T00:00:00Z", message: .assistant(assistant)
            )), children: [result], label: nil
        )] : [result]
        return TreeSelectorComponent(tree: tree, currentLeafId: "result", terminalHeight: 40,
                                     onSelect: { _ in }, onCancel: {})
    }

    @Test func normalReadRowsUseRawRangeArguments() {
        initTheme("dark")
        let savedCapabilities = getCapabilities()
        setCapabilities(TerminalCapabilities(images: nil, trueColor: true, hyperlinks: false))
        defer { setCapabilities(savedCapabilities) }
        for (rangeArgs, range) in cases {
            let args = rangeArgs.merging(["path": AnyCodable("notes.txt")]) { _, value in value }
            let row = ToolExecutionComponent(toolName: "read", toolCallId: "call", args: args,
                                             ui: TUI(terminal: ToolTestTerminal()), cwd: "/tmp/pi-read-range")
            #expect(toolTestText(row).contains("read notes.txt\(range)"))
            if range.isEmpty {
                #expect(!toolTestText(row).contains("notes.txt:"))
            }
        }
    }

    @Test func compactReadRowsUseRawRangeArguments() throws {
        initTheme("dark")
        let savedCapabilities = getCapabilities()
        setCapabilities(TerminalCapabilities(images: nil, trueColor: true, hyperlinks: false))
        defer { setCapabilities(savedCapabilities) }
        let renderer = try #require(createReadRenderers().renderCall)
        let compactPaths = [
            ("AGENTS.md", "read resource AGENTS.md"),
            ("skills/example/SKILL.md", "[skill] example"),
            (getReadmePath(), "read docs README.md"),
        ]
        for (path, label) in compactPaths {
            for (rangeArgs, range) in cases {
                let args = rangeArgs.merging(["path": AnyCodable(path)]) { _, value in value }
                let context = ToolRenderContext(args: args, cwd: "/tmp/pi-read-range", expanded: false)
                let text = toolTestText(try renderer(args, theme, context))
                #expect(text.contains(label + range + " ("))
            }
        }
    }

    @Test func treeReadLabelsUseTheirCallArguments() {
        initTheme("dark")
        for (rangeArgs, range) in cases {
            let args = rangeArgs.merging(["path": AnyCodable("notes.txt")]) { _, value in value }
            let tree = selector(args: args)
            #expect(toolTestText(tree.getTreeList()).contains("[read: notes.txt\(range)]"))
        }
    }

    @Test func treeSearchIncludesReadPathAndRange() {
        initTheme("dark")
        let tree = selector(args: ["path": AnyCodable("notes.txt"), "offset": AnyCodable("25"), "limit": AnyCodable("13")])
        tree.handleInput("notes.txt:25-37")
        #expect(tree.getSelectedEntryId() == "result")
        #expect(toolTestText(tree.getTreeList()).contains("[read: notes.txt:25-37]"))
        #expect(!toolTestText(tree.getTreeList()).contains("assistant:"))
    }

    @Test func treeReadLabelsKeepAliasHomeAndMissingCallRules() {
        initTheme("dark")
        let tree = selector(args: ["path": AnyCodable(""), "file_path": AnyCodable(NSHomeDirectory() + "/notes.txt"),
                                   "offset": AnyCodable("25"), "limit": AnyCodable("13")])
        #expect(toolTestText(tree.getTreeList()).contains("[read: ~/notes.txt:25-37]"))
        #expect(toolTestText(selector(args: [:], includeCall: false).getTreeList()).contains("[read]"))
    }

    @Test func treeReadPathsUseJavaScriptTruthinessAndStringConversion() {
        initTheme("dark")
        let paths: [(Any, String)] = [
            (true, "true"),
            (false, "fallback.txt"),
            (42, "42"),
            (0, "fallback.txt"),
            (-0.0, "fallback.txt"),
            (Double.nan, "fallback.txt"),
            (Double.infinity, "Infinity"),
            (-Double.infinity, "-Infinity"),
            (1e21, "1e+21"),
            (1e-7, "1e-7"),
            (NSNull(), "fallback.txt"),
            ("", "fallback.txt"),
            ("0", "0"),
            ([String: Any](), "[object Object]"),
            (["name": "notes.txt"], "[object Object]"),
            ([Any](), ""),
            ([1, NSNull(), "notes"] as [Any], "1,,notes"),
            ([[1, 2], [3]] as [Any], "1,2,3"),
            ([true, false, ["name": "notes.txt"]] as [Any], "true,false,[object Object]"),
        ]
        for (path, expected) in paths {
            let tree = selector(args: ["path": AnyCodable(path), "file_path": AnyCodable("fallback.txt")])
            #expect(toolTestText(tree.getTreeList()).contains("[read: \(expected)]"))
        }
        let empty = selector(args: ["path": AnyCodable(false), "file_path": AnyCodable(0)])
        #expect(toolTestText(empty.getTreeList()).contains("[read: ]"))
    }
}
