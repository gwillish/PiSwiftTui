import Darwin
import Foundation
import PiSwiftAI
import PiSwiftAgent
import MiniTui
import PiSwiftCodingAgent

struct PrintModeOutput: Sendable {
    let writeString: @Sendable (String) -> Void
    let writeError: @Sendable (String) -> Void
    let flush: @Sendable () -> Void

    func writeJSONLine(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        writeString(String(decoding: data, as: UTF8.self) + "\n")
    }

    static func standard() -> PrintModeOutput {
        let output = takeOverStdoutForMachineReadableOutput()
        return PrintModeOutput(
            writeString: { output.writeString($0) },
            writeError: { fputs($0, stderr) },
            flush: { fflush(stdout) }
        )
    }
}

@discardableResult
public func runPrintMode(
    _ session: AgentSession,
    _ mode: Mode,
    _ messages: [String],
    _ initialMessage: String? = nil,
    _ initialImages: [ImageContent]? = nil
) async throws -> Int {
    try await runPrintMode(session, mode, messages, initialMessage, initialImages, output: nil)
}

@discardableResult
func runPrintMode(
    _ session: AgentSession,
    _ mode: Mode,
    _ messages: [String],
    _ initialMessage: String? = nil,
    _ initialImages: [ImageContent]? = nil,
    output: PrintModeOutput?
) async throws -> Int {
    await installDefaultToolHtmlRenderer(session)
    let outputJson = mode == .json
    let machineOutput = output ?? .standard()

    if outputJson, let header = session.sessionManager.getHeader() {
        machineOutput.writeJSONLine(encodeSessionHeader(header))
    }

    _ = session.subscribe { event in
        guard outputJson else { return }
        // Ordered encoding keeps system-prompt section order in the JSON event stream.
        machineOutput.writeString(encodeSessionEventJSON(event) + "\n")
    }

    if let hookRunner = session.hookRunner {
        hookRunner.initialize(
            getModel: { [weak session] in session?.agent.state.model },
            getSystemPrompt: { [weak session] in session?.agent.state.systemPrompt },
            getSystemPromptOptions: { [weak session] in
                session?.getCurrentSystemPromptOptions() ?? BuildSystemPromptOptions()
            },
            isProjectTrusted: { [weak session] in session?.projectTrusted ?? true },
            sendMessageHandler: { [weak session] message, options in
                Task {
                    await session?.sendHookMessage(message, options: options)
                }
            },
            appendEntryHandler: { [weak session] customType, data in
                session?.sessionManager.appendCustomEntry(customType, data)
            },
            setSessionNameHandler: { [weak session] name in
                _ = session?.sessionManager.appendSessionInfo(name)
            },
            getSessionNameHandler: { [weak session] in
                session?.sessionManager.getSessionName()
            },
            getActiveToolsHandler: { [weak session] in
                session?.getActiveToolNames() ?? []
            },
            getAllToolsHandler: { [weak session] in
                session?.getAllTools() ?? []
            },
            setActiveToolsHandler: { [weak session] toolNames in
                session?.setActiveToolsByName(toolNames)
            },
            isIdle: { [weak session] in
                session?.isIdle ?? false
            },
            waitForIdle: { [weak session] in
                await session?.waitForIdle()
            },
            abort: { [weak session] in
                guard let session else { return }
                Task { [session] in
                    await session.abort()
                }
            },
            hasPendingMessages: { [weak session] in
                (session?.pendingMessageCount ?? 0) > 0
            },
            mode: mode == .json ? .json : .print,
            hasUI: false
        )

        _ = hookRunner.onError { error in
            machineOutput.writeError("Hook error (\(error.hookPath)): \(error.error)\n")
        }

        _ = await hookRunner.emit(SessionStartEvent())
    }

    await session.emitCustomToolSessionEvent(.start, previousSessionFile: nil)

    if let initialMessage {
        try await session.prompt(initialMessage, options: PromptOptions(expandSlashCommands: nil, images: initialImages))
    }

    for message in messages {
        try await session.prompt(message)
    }

    await session.waitForIdle()

    if mode == .text {
        let lastMessage = session.agent.state.messages.last
        if case .assistant(let assistant) = lastMessage {
            if assistant.stopReason == .error || assistant.stopReason == .aborted {
                let message = assistant.errorMessage ?? "Request \(assistant.stopReason.rawValue)"
                machineOutput.writeError("\(message)\n")
                machineOutput.flush()
                return 1
            }
            let textBlocks = assistant.content.compactMap { block -> String? in
                if case .text(let text) = block { return text.text }
                return nil
            }
            let combined = textBlocks.joined(separator: "\n")
            if !combined.isEmpty {
                if shouldUseAnsiOutput() {
                    let terminal = ProcessTerminal()
                    let width = max(40, terminal.columns)
                    let rendered = await MainActor.run { () -> String in
                        let markdown = Markdown(combined, paddingX: 0, paddingY: 0, theme: getMarkdownTheme())
                        return markdown.render(width: width).joined(separator: "\n")
                    }
                    machineOutput.writeString(rendered + "\n")
                } else {
                    machineOutput.writeString(combined + "\n")
                }
            }
            if let notice = latestCacheMissNotice(session) {
                machineOutput.writeString(notice + "\n")
            }
            if assistant.stopReason == .length {
                machineOutput.flush()
                machineOutput.writeError("Response was truncated: the model reached its output token limit.\n")
                return 1
            }
        }
    }

    machineOutput.flush()
    return 0
}

private func latestCacheMissNotice(_ session: AgentSession) -> String? {
    guard session.settingsManager.getShowCacheMissNotices() else { return nil }
    let entries = session.sessionManager.getEntries()
    let misses = collectCacheMisses(entries, modelRegistry: session.modelRegistry)
    guard let entry = entries.last(where: {
        if case .message(let message) = $0, case .assistant = message.message { return true }
        return false
    }), let miss = misses[entry.id] else {
        return nil
    }
    let tokens = NumberFormatter.localizedString(from: NSNumber(value: miss.missedTokens), number: .decimal)
    let reason = miss.modelChanged ? " after a model change" : miss.idleMs > CACHE_TTL_MS ? " after cache expiry" : ""
    return "[Prompt cache miss] " + tokens + " tokens re-billed" + reason
}

private func shouldUseAnsiOutput() -> Bool {
    isatty(STDOUT_FILENO) != 0
}

private func encodeSessionHeader(_ header: SessionHeader) -> [String: Any] {
    var dict: [String: Any] = [
        "type": header.type,
        "id": header.id,
        "timestamp": header.timestamp,
        "cwd": header.cwd,
    ]
    if let version = header.version {
        dict["version"] = version
    }
    if let parent = header.parentSession {
        dict["parentSession"] = parent
    }
    return dict
}
