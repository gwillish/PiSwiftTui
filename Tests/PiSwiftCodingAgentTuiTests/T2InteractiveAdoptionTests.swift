import Foundation
import MiniTui
import PiSwiftAI
import PiSwiftAgent
import PiSwiftCodingAgent
import Testing
@testable import PiSwiftCodingAgentTui

private final class T2AdoptionTerminal: Terminal {
    var columns = 80
    var rows = 24
    var kittyProtocolActive = false
    var writes = ""
    var input: ((String) -> Void)?
    func start(onInput: @escaping (String) -> Void, onResize: @escaping () -> Void) { input = onInput }
    func stop() { input = nil }
    func drainInput(maxMs: Int, idleMs: Int) {}
    func write(_ data: String) { writes += data }
    func moveBy(lines: Int) {}
    func hideCursor() {}
    func showCursor() {}
    func clearLine() {}
    func clearFromCursor() {}
    func clearScreen() {}
    func setTitle(_ title: String) {}
}

@MainActor
private final class T2OverlayProbe: Component, Focusable {
    var focused = false
    var inputs: [String] = []
    var wheels = 0
    var consumesWheel = false
    var close: HookCustomClose?
    let text: String
    init(_ text: String) { self.text = text }
    func render(width: Int) -> [String] { [text] }
    func handleInput(_ data: String) { inputs.append(data) }
    func handleMouse(_ event: TuiMouseEvent) -> TuiMouseEventResult? {
        guard event.type == .wheel else { return nil }
        wheels += 1
        return consumesWheel ? TuiMouseEventResult(handled: true) : nil
    }
}

@MainActor
private struct T2AdoptionHost {
    let session: AgentSession
    let tui: TUI
    let mode: InteractiveMode
    let terminal: T2AdoptionTerminal
    let editor: CustomEditor
    let runner: HookRunner

    init() {
        initTheme("dark")
        let manager = SessionManager.inMemory("/tmp")
        let registry = ModelRegistry(AuthStorage.inMemory(), nil, modelsStore: InMemoryModelsStore(), networkEnabled: false)
        runner = HookRunner([], "/tmp", manager, registry)
        session = t3aSession(manager: manager, registry: registry, runner: runner)
        terminal = T2AdoptionTerminal()
        tui = TUI(terminal: terminal)
        editor = CustomEditor(ui: tui, theme: getEditorTheme(), keybindings: .inMemory(), embedWorkingStatus: true)
        mode = InteractiveMode(session: session, tui: tui, editor: editor)
        if let container = mode.editorContainer { tui.addChild(container) }
        tui.setFocus(editor)
    }

    func close() {
        mode.handleAgentEvent(.agentEnd(messages: []))
        tui.stop()
        session.dispose()
    }

    func open(_ probe: T2OverlayProbe, nonCapturing: Bool) -> Task<HookCustomResult?, Never> {
        let context = runner.getUIContext()
        return Task { @MainActor in
            await context.custom({ _, _, _, done in
                let component = await MainActor.run { () -> T2OverlayProbe in
                    probe.close = done
                    return probe
                }
                return component
            }, options: HookCustomOptions(overlay: true, overlayOptions: .fixed(HookOverlayOptions(
                width: .absolute(20), anchor: .topLeft, nonCapturing: nonCapturing
            ))))
        }
    }

    func flush() async {
        await Task.yield()
        await tui.waitForRender()
        await Task.yield()
        await tui.waitForRender()
    }

    func waitForOverlay(_ probe: T2OverlayProbe) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while probe.close == nil && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        _ = try #require(probe.close)
        await flush()
    }
}

@MainActor @Suite(.serialized)
struct T2InteractiveAdoptionTests {
    // Upstream interactive-mode-status.test.ts:305-380, through the real hook UI context.
    @Test(arguments: [false, true])
    func closingLowerCustomOverlayKeepsUpper(_ nonCapturing: Bool) async throws {
        let host = T2AdoptionHost()
        defer { host.close() }
        await host.mode.initializeHooksAndCustomTools()
        host.tui.start()
        let lower = T2OverlayProbe("LOWER")
        let upper = T2OverlayProbe("UPPER")
        let lowerTask = host.open(lower, nonCapturing: nonCapturing)
        try await host.waitForOverlay(lower)
        #expect((host.tui.getFocusedComponent() === host.editor) == nonCapturing)
        #expect(lower.focused == !nonCapturing)
        let upperTask = host.open(upper, nonCapturing: false)
        try await host.waitForOverlay(upper)
        #expect(upper.focused)
        defer { lower.close?(nil); upper.close?(nil) }

        lower.close?("lower closed")
        #expect(await lowerTask.value?.value as? String == "lower closed")
        host.terminal.writes = ""
        host.tui.requestRender(force: true)
        await host.flush()
        let frame = stripTerminalSequences(host.terminal.writes)
        #expect(frame.contains("UPPER"))
        #expect(!frame.contains("LOWER"))
        host.terminal.input?("x")
        await host.flush()
        #expect(upper.inputs == ["x"])
        #expect(lower.inputs.isEmpty)
        #expect(host.editor.getText().isEmpty)

        upper.close?("upper closed")
        #expect(await upperTask.value?.value as? String == "upper closed")
        await host.flush()
        #expect(!host.tui.hasOverlay())
        #expect(host.tui.getFocusedComponent() === host.editor)
    }

    @Test(arguments: [false, true])
    func focusedCustomOverlayUsesMouseForWheel(_ handled: Bool) async throws {
        let host = T2AdoptionHost()
        defer { host.close() }
        await host.mode.initializeHooksAndCustomTools()
        let renderer = host.tui.enableAltScreen(options: AltScreenRendererOptions(wheelScrollLines: .lines(3)))
        let transcript = ScrollView(Text((0..<100).map { "line\($0)" }.joined(separator: "\n"), paddingX: 0, paddingY: 0),
                                    options: ScrollViewOptions(follow: .end, primary: true))
        renderer.setLayoutRoot(transcript)
        #expect(host.tui.switchRenderer(to: .altScreen))
        host.tui.start()
        let overlay = T2OverlayProbe("WHEEL")
        overlay.consumesWheel = handled
        let result = host.open(overlay, nonCapturing: false)
        try await host.waitForOverlay(overlay)
        defer { overlay.close?(nil) }
        let before = transcript.scrollTop
        #expect(before > 0)
        host.terminal.input?("\u{1B}[<64;1;1M")
        await host.flush()
        #expect(overlay.wheels == 1)
        #expect(overlay.inputs.isEmpty)
        #expect(transcript.scrollTop == (handled ? before : before - 3))
        overlay.close?("done")
        #expect(await result.value?.value as? String == "done")
    }

    // Swift-specific coverage: upstream has no compaction color test for T8.
    @Test(arguments: [false, true], [false, true])
    func compactionUsesCurrentEmbeddedBorderColor(_ custom: Bool, _ manual: Bool) async throws {
        let host = T2AdoptionHost()
        defer { host.close() }
        host.mode.selectThinkingLevel(.high, persist: false)
        if custom {
            host.editor.borderColor = { "\u{1B}[38;5;196m\($0)\u{1B}[39m" }
        }
        if manual { host.mode.handleCompactCommand(nil) }
        else { host.mode.handleSessionEvent(.autoCompactionStart(reason: .threshold)) }
        let border = try #require(host.editor.render(width: 80).first)
        #expect(border.contains(host.editor.borderColor("Compacting")))
        if !custom {
            #expect(border.contains(theme.getThinkingBorderColor("high")("Compacting")))
        }
        let spinner = try #require(stripTerminalSequences(border).split(separator: " ").dropFirst().first)
        #expect(border.contains(host.editor.borderColor(String(spinner))))
        if manual {
            let deadline = ContinuousClock.now + .seconds(2)
            while host.editor.render(width: 80)[0].contains("Compacting") && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(2))
            }
        } else {
            host.mode.handleSessionEvent(.autoCompactionEnd(result: nil, aborted: true, willRetry: false))
        }
        #expect(!host.editor.render(width: 80)[0].contains("Compacting"))
    }

    @Test func producedSymbolMatchesConfiguredAppBindingAndPhysicalSpelling() {
        let logical = KeybindingsManager.inMemory(config: [AppAction.expandTools.rawValue: ["ctrl++"]])
        let physical = KeybindingsManager.inMemory(config: [AppAction.expandTools.rawValue: ["ctrl+shift+="]])
        let data = "\u{1B}[61:43;6u"
        #expect(parseKey(data) == "ctrl++")
        #expect(logical.matches(data, .expandTools))
        #expect(physical.matches(data, .expandTools))
    }

    @Test func plainEditorAndInputConsumersRemoveFakeCursorMarkers() {
        let host = T2AdoptionHost()
        defer { host.close() }
        host.editor.setText("日本語")
        let editorOutput = host.editor.render(width: 40).joined(separator: "\n")
        #expect(editorOutput.contains("\u{1B}_pi:fc\u{7}"))
        let plain = toolTestPlain(editorOutput)
        #expect(plain.contains("日本語"))
        #expect(!plain.contains("pi:fc"))
        let input = Input(options: InputOptions(prompt: "", placeholder: "Search"))
        input.focused = true
        let raw = input.render(width: 40).joined()
        #expect(raw.contains("\u{1B}_pi:fc\u{7}"))
        #expect(toolTestPlain(raw).trimmingCharacters(in: .whitespaces) == "\u{0000}Search")
    }
}
