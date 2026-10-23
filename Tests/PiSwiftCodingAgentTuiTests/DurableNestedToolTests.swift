import Foundation
import MiniTui
import PiSwiftAI
import PiSwiftChord
import PiSwiftCodingAgentDurable
import PiSwiftDurable
import Testing
@testable import PiSwiftCodingAgentTui

private final class DurableNestedTerminal: Terminal {
    var columns = 120
    var rows = 30
    var kittyProtocolActive = false
    func start(onInput: @escaping (String) -> Void, onResize: @escaping () -> Void) {}
    func stop() {}
    func drainInput(maxMs: Int, idleMs: Int) {}
    func write(_ data: String) {}
    func moveBy(lines: Int) {}
    func hideCursor() {}
    func showCursor() {}
    func clearLine() {}
    func clearFromCursor() {}
    func clearScreen() {}
    func setTitle(_ title: String) {}
}

@MainActor @Suite(.serialized)
struct DurableNestedToolTests {
    private func makeTui() -> DurableTui {
        DurableTui(cwd: "/tmp", handlers: DurableTuiHandlers(
            submit: { _ in }, followUp: { _ in }, abort: {}, exit: {}, selectModel: {}, cycleThinking: {}
        ), terminal: DurableNestedTerminal())
    }

    private func slot(_ id: Int64, parent: Int64 = 10, call: String = "opaque/child/id",
                      parentCall: String = "model/already/has/slashes", status: ToolSlot.Status = .running) throws -> NestedToolSlot {
        NestedToolSlot(callId: call, name: "nested-probe", parentCallId: parentCall,
                       parentTaskId: try TaskID(parent), taskId: try TaskID(id), arguments: ["value": "argument"], status: status)
    }

    private func view(_ live: LiveState, entries: [EntryRecord] = []) throws -> DurableView {
        DurableView(session: .init(id: "test", directory: "/tmp/session", cwd: "/tmp"),
                    conversation: .init(conversation: .init(id: rootConversationID), entries: entries,
                                        docs: ["pi.live": try #require(JSONValue(encoding: live).objectValue)]),
                    conversations: [.init(id: rootConversationID, label: "root")], models: [])
    }

    private func text(_ component: any Component) -> String {
        component.render(width: 120).joined(separator: "\n")
            .replacingOccurrences(of: "\u{001B}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression)
    }

    @Test func parentsUseTaskIdentityWhenCallIDsAreEqual() throws {
        let tui = makeTui(); defer { tui.stop() }
        let first = try slot(11, parent: 10, call: "same", parentCall: "same/parent")
        let second = try slot(21, parent: 20, call: "same", parentCall: "same/parent")
        tui.apply(try view(LiveState(nestedTools: [first, second])))
        #expect(tui.nestedTools.cards.count == 2)
        #expect(tui.nestedTools.cards[first.taskId] !== tui.nestedTools.cards[second.taskId])
        #expect(tui.nestedTools.groups.count == 2)
        #expect(tui.nestedTools.groups[.init(taskId: first.parentTaskId, callId: first.parentCallId)] == [first.taskId])
        #expect(tui.nestedTools.groups[.init(taskId: second.parentTaskId, callId: second.parentCallId)] == [second.taskId])
        #expect(tui.tools.isEmpty)
        #expect(tui.cards.isEmpty)
    }

    @Test func opaqueIDsDoNotSupplyParentStructure() throws {
        let tui = makeTui(); defer { tui.stop() }
        let child = try slot(12, parent: 11, call: "unrelated", parentCall: "not/a/path")
        let parent = try slot(11, call: "not/a/path")
        let separate = try slot(21, parent: 20, call: "not/a/path/child", parentCall: "not/a")
        tui.apply(try view(LiveState(nestedTools: [child, separate, parent])))
        #expect(tui.nestedTools.groups.count == 2)
        #expect(tui.nestedTools.groups[.init(taskId: parent.parentTaskId, callId: parent.parentCallId)] == [parent.taskId])
        let lines = text(tui.nestedTools.container).components(separatedBy: "\n")
        #expect(lines.first { $0.contains("#12 · running") }?.hasPrefix("    ") == true)
        #expect(lines.first { $0.contains("#11 · running") }?.hasPrefix("  ") == true)
        #expect(!text(tui.chat).contains("nested-probe"))
    }

    @Test func parentCallIDsUseExactBytes() throws {
        let tui = makeTui(); defer { tui.stop() }
        let composed = try slot(11, parentCall: "\u{00E9}")
        let decomposed = try slot(12, parentCall: "e\u{0301}")
        tui.apply(try view(LiveState(nestedTools: [composed, decomposed])))
        #expect(tui.nestedTools.groups.count == 2)
    }

    @Test func progressShowsOutputDetailsDiagnosticsAndRemovalCounts() throws {
        let tui = makeTui(); defer { tui.stop() }
        var child = try slot(11)
        child.output = "Nested output"
        child.details = ["progress": 42]
        child.diagnostics = [.init(severity: .warn, message: "Check value", code: "check")]
        child.droppedBytes = 100
        child.droppedLines = 3
        tui.apply(try view(LiveState(nestedTools: [child])))
        let rendered = text(tui.nestedTools.container)
        #expect(rendered.contains("Nested output"))
        #expect(rendered.contains("Details:") && rendered.contains("\"progress\":42"))
        #expect(rendered.contains("warn [check]: Check value"))
        #expect(rendered.contains("Output removed: 100 bytes, 3 lines"))
        #expect(!text(tui.chat).contains("Nested output"))

        child.output = "Replacement output"
        child.details = .null
        child.diagnostics = []
        child.droppedBytes = nil
        child.droppedLines = nil
        tui.apply(try view(LiveState(nestedTools: [child])))
        let changed = text(tui.nestedTools.container)
        #expect(changed.contains("Replacement output"))
        #expect(!changed.contains("Nested output"))
        #expect(changed.contains("Details: null"))
        #expect(!changed.contains("Check value"))
        #expect(!changed.contains("Output removed"))
    }

    @Test func doneSummaryReplacesProgressAndStaysUntilCallerFinishes() throws {
        let tui = makeTui(); defer { tui.stop() }
        var child = try slot(11)
        child.output = "Old progress"
        child.details = ["old": true]
        child.diagnostics = [.init(severity: .info, message: "Old diagnostic")]
        tui.apply(try view(LiveState(nestedTools: [child])))
        let card = try #require(tui.nestedTools.cards[child.taskId])
        child.status = .done
        child.summary = NestedToolSummary(isError: true, durationMs: 24,
            usage: Usage(input: 2, output: 3, cacheRead: 4, cacheWrite: 5, totalTokens: 14), error: "Nested failure")
        tui.apply(try view(LiveState(nestedTools: [child])))
        #expect(tui.nestedTools.cards[child.taskId] === card)
        let done = text(tui.nestedTools.container)
        #expect(done.contains("Failed · 24 ms"))
        #expect(done.contains("↑2 ↓3 R4 W5"))
        #expect(done.contains("Nested failure"))
        #expect(!done.contains("Old progress"))
        #expect(!done.contains("Old diagnostic"))
        #expect(!done.contains("Details:"))
        tui.apply(try view(LiveState()))
        #expect(tui.nestedTools.cards.isEmpty)
        #expect(text(tui.nestedTools.container).isEmpty)
    }

    @Test func callerSettlementRemovesAllDescendants() throws {
        let tui = makeTui(); defer { tui.stop() }
        let parent = try slot(11)
        let child = try slot(12, parent: 11, parentCall: parent.callId)
        let grandchild = try slot(13, parent: 12, parentCall: child.callId)
        let other = try slot(21, parent: 20)
        let nested = [grandchild, child, parent, other]
        tui.apply(try view(LiveState(nestedTools: nested)))
        #expect(tui.nestedTools.cards.count == 4)
        let done = ToolSlot(callId: parent.parentCallId, name: "caller", taskId: parent.parentTaskId, status: .done)
        tui.apply(try view(LiveState(tools: [done], nestedTools: nested)))
        #expect(Set(tui.nestedTools.cards.keys) == [other.taskId])
        #expect(!text(tui.nestedTools.container).contains("#11 ·"))
        #expect(!text(tui.nestedTools.container).contains("#12 ·"))
        #expect(!text(tui.nestedTools.container).contains("#13 ·"))
    }

    @Test func nestedSummaryDoesNotReplaceAModelResultWithTheSameCallID() throws {
        let tui = makeTui(); defer { tui.stop() }
        var child = try slot(11, call: "same/opaque/id", status: .done)
        child.summary = NestedToolSummary(isError: true, error: "Nested result summary")
        let model: JSONValue = ["role": "toolResult", "toolCallId": "same/opaque/id", "toolName": "model-probe",
            "content": [["type": "text", "text": "Model transcript result"]], "isError": false, "timestamp": 1]
        let entry = EntryRecord(id: try EntryID(2), conversationId: rootConversationID,
                                kind: "pi.tool-result", model: [model])
        tui.apply(try view(LiveState(nestedTools: [child]), entries: [entry]))
        #expect(tui.cards.count == 1)
        #expect(tui.nestedTools.cards.count == 1)
        #expect(tui.tools[child.callId] !== tui.nestedTools.cards[child.taskId])
        #expect(text(tui.chat).contains("Model transcript result"))
        #expect(!text(tui.chat).contains("Nested result summary"))
        #expect(text(tui.nestedTools.container).contains("Nested result summary"))
        #expect(!text(tui.nestedTools.container).contains("Model transcript result"))
    }

    @Test func finishedNestedCallerRemovesItsChildrenButKeepsItsSummary() throws {
        let tui = makeTui(); defer { tui.stop() }
        var caller = try slot(11)
        let child = try slot(12, parent: 11, parentCall: caller.callId)
        tui.apply(try view(LiveState(nestedTools: [caller, child])))
        caller.status = .done
        caller.summary = NestedToolSummary(isError: false, durationMs: 10)
        tui.apply(try view(LiveState(nestedTools: [caller, child])))
        #expect(Set(tui.nestedTools.cards.keys) == [caller.taskId])
        #expect(text(tui.nestedTools.container).contains("Done · 10 ms"))
    }

    @Test func noProgressAndStopLeaveNoRetainedCards() throws {
        let tui = makeTui()
        tui.apply(try view(LiveState(nestedTools: [slot(11)])))
        let running = text(tui.nestedTools.container)
        #expect(running.contains("running"))
        #expect(!running.contains("Details:"))
        #expect(!running.contains("Output removed:"))
        tui.stop()
        #expect(tui.nestedTools.cards.isEmpty)
        #expect(text(tui.nestedTools.container).isEmpty)
    }
}
