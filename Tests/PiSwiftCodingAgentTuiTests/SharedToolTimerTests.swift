import Foundation
import MiniTui
import PiSwiftAI
import PiSwiftAgent
import PiSwiftCodingAgent
import Testing
@testable import PiSwiftCodingAgentTui

@MainActor @Suite(.serialized) struct SharedToolTimerTests {
    private func renderers(_ name: String) -> ToolRenderers {
        name == "bash" ? createShellRenderers(prompt: "$") : createCodemodeRenderers()
    }

    private func context(clock: ToolTimerTestClock, started: Bool = true) -> ToolRenderContext {
        let state = ToolRenderState()
        state.values["timer"] = ToolTimerState(now: { clock.now })
        return ToolRenderContext(state: state, executionStarted: started, showImages: false)
    }

    private func result(_ renderers: ToolRenderers, _ context: ToolRenderContext, partial: Bool) throws -> String {
        let render = try #require(renderers.renderResult)
        let result = AgentToolResult(content: [], details: AnyCodable(["calls": []]))
        return toolTestText(try render(result, RenderResultOptions(expanded: false, isPartial: partial), theme, context))
    }

    @Test(arguments: ["bash", "codemode"])
    func emptyProgressShowsElapsedAndFinalRecordedDurationWins(_ name: String) throws {
        let clock = ToolTimerTestClock()
        let context = context(clock: clock)
        let renderers = renderers(name)
        _ = try renderers.renderCall?([:], theme, context)
        clock.advance(3)
        #expect(try result(renderers, context, partial: true) == "\nElapsed 3.0s")
        var final = context
        final.durationMs = 5100
        let text = try result(renderers, final, partial: false)
        #expect(text == "\nTook 5.1s")
        #expect(!text.contains("Elapsed"))
    }

    @Test(arguments: ["bash", "codemode"])
    func executionStartsClockOnceAndFinalWithoutDurationFreezesIt(_ name: String) throws {
        let clock = ToolTimerTestClock()
        let context = context(clock: clock)
        let renderers = renderers(name)
        _ = try renderers.renderCall?([:], theme, context)
        clock.advance(4.2)
        _ = try renderers.renderCall?([:], theme, context)
        #expect(try result(renderers, context, partial: false) == "\nTook 4.2s")
        clock.advance(10)
        #expect(try result(renderers, context, partial: false) == "\nTook 4.2s")
    }

    @Test(arguments: ["bash", "codemode"])
    func partialErrorFreezesElapsedAndCancelsRedraws(_ name: String) throws {
        let clock = ToolTimerTestClock()
        let context = context(clock: clock)
        let renderers = renderers(name)
        _ = try renderers.renderCall?([:], theme, context)
        _ = try result(renderers, context, partial: true)
        let timer = try #require(toolTimerState(context).timer)
        clock.advance(4.2)
        var error = context
        error.isError = true
        #expect(try result(renderers, error, partial: true) == "\nElapsed 4.2s")
        #expect(timer.isCancelled)
        #expect(toolTimerState(context).timer == nil)
        clock.advance(10)
        #expect(try result(renderers, error, partial: true) == "\nElapsed 4.2s")
        #expect(toolTimerState(context).timer == nil)
    }

    @Test(arguments: ["bash", "codemode"])
    func restoredDurationIncludesZeroWithoutStartingClock(_ name: String) throws {
        let clock = ToolTimerTestClock()
        var context = context(clock: clock, started: false)
        let renderers = renderers(name)
        _ = try renderers.renderCall?([:], theme, context)
        context.durationMs = 4200
        #expect(try result(renderers, context, partial: false) == "\nTook 4.2s")
        context.durationMs = 0
        #expect(try result(renderers, context, partial: false) == "\nTook 0.0s")
        #expect(toolTimerState(context).startedAt == nil)
        #expect(toolTimerState(context).timer == nil)
    }

    @Test(arguments: ["bash", "codemode"])
    func noStartAndNoDurationHasNoTimerText(_ name: String) throws {
        let clock = ToolTimerTestClock()
        var context = context(clock: clock, started: false)
        let renderers = renderers(name)
        _ = try renderers.renderCall?([:], theme, context)
        #expect(try result(renderers, context, partial: true).isEmpty)
        context.durationMs = 4200
        #expect(try result(renderers, context, partial: true).isEmpty)
        context.durationMs = nil
        #expect(try result(renderers, context, partial: false).isEmpty)
        #expect(toolTimerState(context).timer == nil)
    }

    @Test(arguments: [(0.0, "0.0s"), (4.2, "4.2s"), (59.9, "59.9s"), (60.0, "1m 0s"),
                      (90.9, "1m 30s"), (3599.9, "59m 59s"), (3600.0, "1h 0m 0s"), (7384.9, "2h 3m 4s")])
    func durationFormatsSecondsMinutesAndHours(_ value: (Double, String)) {
        #expect(formatToolDuration(value.0) == value.1)
    }

    @Test func releasingRendererStateCancelsRedrawTask() throws {
        var state: ToolRenderState? = ToolRenderState()
        var context: ToolRenderContext? = ToolRenderContext(state: try #require(state), executionStarted: true)
        startToolTimer(try #require(context))
        _ = toolTimerText(try #require(context), isPartial: true)
        let pendingTimer = toolTimerState(try #require(context)).timer
        let timer = try #require(pendingTimer)
        weak var timerState = toolTimerState(try #require(context))
        context = nil
        state = nil
        #expect(timerState == nil)
        #expect(timer.isCancelled)
    }

    @Test func codemodeRedrawsWhilePartialAndStopsOnFinalResult() async throws {
        let clock = ToolTimerTestClock()
        var context = context(clock: clock)
        var invalidations = 0
        context.invalidate = { invalidations += 1 }
        let renderers = createCodemodeRenderers()
        _ = try renderers.renderCall?(["code": AnyCodable("")], theme, context)
        _ = try result(renderers, context, partial: true)
        let timer = try #require(toolTimerState(context).timer)
        try await Task.sleep(for: .milliseconds(1150))
        #expect(invalidations >= 1)
        _ = try result(renderers, context, partial: false)
        #expect(timer.isCancelled)
        #expect(toolTimerState(context).timer == nil)
        let finalCount = invalidations
        try await Task.sleep(for: .milliseconds(1100))
        #expect(invalidations == finalCount)
    }

    @Test func codemodeOuterRowShowsInitialEmptyCorePublish() async throws {
        let manager = SessionManager.inMemory("/tmp")
        let registry = ModelRegistry(AuthStorage.inMemory(), nil, modelsStore: InMemoryModelsStore(), networkEnabled: false)
        let definition = createCodemodeToolDefinition()
        let hook = LoadedHook(path: "builtin:codemode", resolvedPath: "builtin:codemode", handlers: [:],
            tools: [definition.name: definition], isExtension: true)
        let runner = HookRunner([hook], "/tmp", manager, registry)
        let session = t3aSession(manager: manager, registry: registry, runner: runner)
        defer { session.dispose() }
        let tui = TUI(terminal: ToolTestTerminal())
        let editor = CustomEditor(ui: tui, theme: getEditorTheme(), keybindings: .inMemory())
        let mode = InteractiveMode(session: session, tui: tui, editor: editor)
        let args = ["code": AnyCodable("return 7")]
        mode.handleSessionEvent(.agent(.toolExecutionStart(toolCallId: "timer-script", toolName: "codemode", args: args)))
        let (updates, continuation) = AsyncStream<AgentToolResult>.makeStream()
        let rendering = Task { @MainActor in
            var texts: [String] = []
            for await update in updates {
                #expect(update.content.isEmpty)
                #expect(((update.details?.value as? [String: Any])?["calls"] as? [Any])?.isEmpty == true)
                mode.handleSessionEvent(.agent(.toolExecutionUpdate(toolCallId: "timer-script", toolName: "codemode",
                    args: args, partialResult: update)))
                texts.append(toolTestText(mode.chatContainer))
            }
            return texts
        }
        defer { continuation.finish() }
        _ = try await executeCodemode(toolCallId: "timer-script", params: ["code": AnyCodable("return 7")],
            onUpdate: { continuation.yield($0) })
        continuation.finish()
        let texts = await rendering.value
        #expect(!texts.isEmpty)
        #expect(texts.first?.contains("Elapsed") == true)
        mode.handleSessionEvent(.agent(.toolExecutionEnd(toolCallId: "timer-script", toolName: "codemode",
            result: AgentToolResult(content: []), isError: false, durationMs: 5100)))
        #expect(toolTestText(mode.chatContainer).contains("Took 5.1s"))
        #expect(!toolTestText(mode.chatContainer).contains("Elapsed"))
        _ = manager.appendMessage(.toolResult(ToolResultMessage(toolCallId: "timer-script", toolName: "codemode",
            content: [], isError: false, durationMs: 5100)))
        mode.renderInitialMessages()
        #expect(toolTestText(mode.chatContainer).contains("Took 5.1s"))
        #expect(!toolTestText(mode.chatContainer).contains("Elapsed"))
    }
}

@MainActor
private final class ToolTimerTestClock {
    var now = Date(timeIntervalSince1970: 0)

    func advance(_ seconds: TimeInterval) {
        now.addTimeInterval(seconds)
    }
}
