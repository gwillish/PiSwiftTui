import Foundation
import PiSwiftAI
import PiSwiftAgent
import PiSwiftCodingAgent
import Testing
@testable import PiSwiftCodingAgentTui

private actor T1HostGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        opened = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

@MainActor
private func t1CapturePrint(_ body: (PrintModeOutput) async throws -> Int) async throws -> (status: Int, output: String, error: String, writes: [String]) {
    let captured = LockedState((output: "", error: "", writes: [String]()))
    let output = PrintModeOutput(
        writeString: { text in captured.withLock { $0.output += text; $0.writes.append("stdout") } },
        writeError: { text in captured.withLock { $0.error += text; $0.writes.append("stderr") } },
        flush: { captured.withLock { $0.writes.append("flush") } }
    )
    let status = try await body(output)
    return captured.withLock { (status, $0.output, $0.error, $0.writes) }
}

private func t1HookSession(_ handlers: [String: [HookHandler]]) -> AgentSession {
    let manager = SessionManager.inMemory("/tmp")
    let auth = AuthStorage.inMemory()
    auth.setRuntimeApiKey("test", "test-key")
    let registry = ModelRegistry(auth, nil, modelsStore: InMemoryModelsStore(), networkEnabled: false)
    let runner = HookRunner([LoadedHook(path: "<t1-host>", resolvedPath: "<t1-host>", handlers: handlers, isExtension: true)],
        "/tmp", manager, registry)
    let session = t3aSession(manager: manager, registry: registry, runner: runner)
    session.agent.streamFn = { model, _, _ in
        let message = t3aAssistant(model)
        let stream = AssistantMessageEventStream()
        stream.push(.done(reason: .stop, message: message))
        stream.end(message)
        return stream
    }
    return session
}

// v1.3.0 print-mode.ts:139-162 and print-mode.test.ts:144.
@MainActor @Suite(.serialized) struct T1PrintRpcTests {
    @Test(arguments: ["partial response", ""])
    func truncatedPrintReturnsFailureAfterPartialOutput(_ text: String) async throws {
        let session = t3aSession()
        defer { session.dispose() }
        var message = t3aAssistant()
        message.content = [.text(TextContent(text: text))]
        message.stopReason = .length
        session.agent.messages = [.assistant(message)]
        #expect(session.toolHtmlRenderer == nil)
        let result = try await t1CapturePrint { try await runPrintMode(session, .text, [], output: $0) }
        #expect(result.status == 1)
        #expect(result.output == (text.isEmpty ? "" : text + "\n"))
        #expect(result.error == "Response was truncated: the model reached its output token limit.\n")
        #expect(result.writes == (text.isEmpty ? ["flush", "stderr"] : ["stdout", "flush", "stderr"]))
        #expect(session.toolHtmlRenderer != nil)
    }

    @Test func completedPrintReturnsSuccess() async throws {
        let session = t3aSession()
        defer { session.dispose() }
        session.agent.messages = [.assistant(t3aAssistant())]
        let result = try await t1CapturePrint { try await runPrintMode(session, .text, [], output: $0) }
        #expect(result.status == 0)
        #expect(result.output == "answer\n")
        #expect(result.error.isEmpty)
    }

    @Test(arguments: [StopReason.error, .aborted])
    func failedPrintReturnsStatusForCallerCleanup(_ reason: StopReason) async throws {
        let session = t3aSession()
        defer { session.dispose() }
        var message = t3aAssistant()
        message.stopReason = reason
        message.errorMessage = "provider failure"
        session.agent.messages = [.assistant(message)]
        let result = try await t1CapturePrint { try await runPrintMode(session, .text, [], output: $0) }
        #expect(result.status == 1)
        #expect(result.output.isEmpty)
        #expect(result.error == "provider failure\n")
    }

    @Test func truncatedJsonKeepsEventStreamAndSuccessStatus() async throws {
        let session = t3aSession()
        defer { session.dispose() }
        session.agent.streamFn = { model, _, _ in
            var message = t3aAssistant(model)
            message.stopReason = .length
            let stream = AssistantMessageEventStream()
            stream.push(.done(reason: .length, message: message))
            stream.end(message)
            return stream
        }
        let result = try await t1CapturePrint { try await runPrintMode(session, .json, ["hello"], output: $0) }
        #expect(result.status == 0)
        #expect(result.error.isEmpty)
        let events = try result.output.split(separator: "\n").map {
            try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
        let ended = try #require(events.first { $0["type"] as? String == "message_end" && ($0["message"] as? [String: Any])?["role"] as? String == "assistant" })
        let assistant = try #require(ended["message"] as? [String: Any])
        #expect(assistant["stopReason"] as? String == "length")
        #expect(events.contains { $0["type"] as? String == "agent_settled" })
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func hostIdleCallbackIncludesManualCompaction(_ interactive: Bool) async throws {
        let entered = T1HostGate()
        let release = T1HostGate()
        let session = t1HookSession(["session_before_compact": [{ _, context in
            #expect(!context.isIdle())
            await entered.open()
            await release.wait()
            return SessionBeforeCompactResult(cancel: true)
        }]])
        defer { session.dispose() }
        var settings = Settings()
        settings.compaction = CompactionSettingsOverrides(keepRecentTokens: 1)
        session.settingsManager.applyOverrides(settings)
        for text in ["first", "second"] {
            session.sessionManager.appendMessage(.user(UserMessage(content: .text(text))))
            var message = t3aAssistant()
            message.usage = t3aUsage(input: 100, output: 100)
            session.sessionManager.appendMessage(.assistant(message))
        }
        session.refreshContext()
        _ = try #require(prepareCompaction(session.sessionManager.getBranch(), session.settingsManager.getCompactionSettings(model: session.agent.state.model)))
        let mode = interactive ? InteractiveMode(session: session, version: "t1-test") : nil
        if let mode { await mode.initializeHooksAndCustomTools() }
        else { _ = try await t1CapturePrint { try await runPrintMode(session, .text, [], output: $0) } }
        let runner = try #require(session.hookRunner)
        #expect(runner.createShortcutContext().isIdle())
        let compact = Task { try? await session.compact() }
        await entered.wait()
        #expect(session.isCompacting)
        #expect(!session.isStreaming)
        #expect(!runner.createShortcutContext().isIdle())
        await release.open()
        _ = await compact.value
        await session.waitForIdle()
        #expect(runner.createShortcutContext().isIdle())
        withExtendedLifetime(mode) {}
    }

    @Test(.timeLimit(.minutes(1))) func rpcStateIsStreamingWhileStartHookIsHeld() async throws {
        let entered = T1HostGate()
        let release = T1HostGate()
        let session = t1HookSession(["before_agent_start": [{ _, _ in
            await entered.open()
            await release.wait()
            return nil
        }]])
        defer { session.dispose() }
        let output = RpcOutput(write: { _ in })
        let prompt = Task { _ = try await handleRpcCommand("prompt", ["message": "hello"], session, output) }
        await entered.wait()
        let response = try await handleRpcCommand("get_state", ["id": "held-start"], session, output)
        let state = try #require(response["data"] as? [String: Any])
        #expect(response["id"] as? String == "held-start")
        #expect(response["success"] as? Bool == true)
        #expect(state["isStreaming"] as? Bool == true)
        #expect(!session.agent.state.isStreaming)
        await release.open()
        try await prompt.value
        await session.waitForIdle()
        let settled = try await handleRpcCommand("get_state", [:], session, output)
        #expect((settled["data"] as? [String: Any])?["isStreaming"] as? Bool == false)
    }
}
