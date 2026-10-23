import Foundation
import MiniTui
import PiSwiftAI
import PiSwiftAgent
import PiSwiftCodingAgent
import Testing
@testable import PiSwiftCodingAgentTui

@MainActor @Suite(.serialized) struct T2SessionShareTests {
    private func config() -> SettingsConfig {
        SettingsConfig(autoCompact: true, showImages: true, autoResizeImages: true, blockImages: false,
            enableSkillCommands: true, steeringMode: "all", followUpMode: "all", transport: .sse,
            thinkingLevel: .high, availableThinkingLevels: [.off, .high], availableThemes: ["dark"],
            hideThinkingBlock: false, showCacheMissNotices: true, collapseChangelog: false, quietStartup: .off,
            doubleEscapeAction: "tree", editorPaddingX: 0, autocompleteMaxVisible: 5,
            tuiMode: .regular, fullscreenScrollbar: .auto, mouseWheelStep: 1,
            mermaidEnabled: false, mermaidRenderWhileStreaming: false, latexEnabled: false, outputPad: 1)
    }

    private func callbacks(_ onChange: @escaping (SessionShareDestination) -> Void) -> SettingsCallbacks {
        SettingsCallbacks(onAutoCompactChange: { _ in }, onShowImagesChange: { _ in }, onAutoResizeImagesChange: { _ in },
            onBlockImagesChange: { _ in }, onEnableSkillCommandsChange: { _ in }, onSteeringModeChange: { _ in },
            onFollowUpModeChange: { _ in }, onTransportChange: { _ in }, onSessionShareDestinationChange: onChange,
            onThinkingLevelChange: { _ in }, onThemeChange: { _ in }, onHideThinkingBlockChange: { _ in },
            onShowCacheMissNoticesChange: { _ in }, onCollapseChangelogChange: { _ in }, onQuietStartupChange: { _ in },
            onDoubleEscapeActionChange: { _ in }, onEditorPaddingXChange: { _ in }, onAutocompleteMaxVisibleChange: { _ in },
            onTuiModeChange: { _ in }, onFullscreenScrollbarChange: { _ in }, onMouseWheelStepChange: { _ in },
            onMermaidEnabledChange: { _ in }, onMermaidRenderWhileStreamingChange: { _ in },
            onLatexEnabledChange: { _ in }, onOutputPadChange: { _ in }, onCancel: {})
    }

    private func session(_ settings: SettingsManager, cwd: String = "/tmp") -> AgentSession {
        let model = t3aModel()
        let registry = ModelRegistry(AuthStorage.inMemory(), nil, modelsStore: InMemoryModelsStore(), networkEnabled: false)
        return AgentSession(config: AgentSessionConfig(
            agent: Agent(AgentOptions(initialState: AgentState(systemPrompt: "test", model: model, tools: []))),
            sessionManager: .inMemory(cwd), settingsManager: settings,
            resourceLoader: DefaultResourceLoader(DefaultResourceLoaderOptions(cwd: cwd, settingsManager: settings)),
            modelRegistry: registry))
    }

    private func host(_ session: AgentSession) -> (mode: InteractiveMode, editor: CustomEditor) {
        let tui = TUI(terminal: ToolTestTerminal())
        let editor = CustomEditor(ui: tui, theme: getEditorTheme(), keybindings: .inMemory())
        return (InteractiveMode(session: session, tui: tui, editor: editor), editor)
    }

    private func openShareSetting(_ mode: InteractiveMode) async throws -> SettingsList {
        await mode.handleEditorSubmit("/settings")
        let selector = try #require(mode.editorContainer?.children.first as? SettingsSelectorComponent)
        let list = selector.getSettingsList()
        list.selectItem(id: "share-destination")
        return list
    }

    private func shareValue(_ list: SettingsList) throws -> String {
        let line = try #require(list.render(width: 160).map(stripTerminalSequences).first {
            $0.contains("Session share destination")
        })
        return try #require(line.split(whereSeparator: \.isWhitespace).last.map(String.init))
    }

    private func settingsFile(_ root: URL, destination: SessionShareDestination) throws -> URL {
        let agent = root.appendingPathComponent("agent")
        try FileManager.default.createDirectory(at: agent, withIntermediateDirectories: true)
        let path = agent.appendingPathComponent("settings.json")
        try Data("{\"sessionShareDestination\":\"\(destination.rawValue)\"}".utf8).write(to: path)
        return path
    }

    // settings-selector.test.ts:66-86, with the two destinations allowed by SQ.
    @Test func shareSelectorCyclesGistAndAutoThroughTheCallback() throws {
        var changes: [SessionShareDestination] = []
        let list = SettingsSelectorComponent(config: config(), callbacks: callbacks { changes.append($0) }).getSettingsList()
        list.selectItem(id: "share-destination")
        #expect(try shareValue(list) == "auto")
        list.handleInput("\r")
        #expect(try shareValue(list) == "gist")
        list.handleInput("\r")
        #expect(try shareValue(list) == "auto")
        #expect(changes == [.gist, .auto])
    }

    @Test(arguments: [SessionShareDestination.auto, .gist])
    func savedDestinationReachesTheSelectorAndShareCommandAfterReload(_ destination: SessionShareDestination) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("t2-share-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let initial: SessionShareDestination = destination == .auto ? .gist : .auto
        let path = try settingsFile(root, destination: initial)
        let settings = SettingsManager.create(root.path, path.deletingLastPathComponent().path)
        let originalSession = session(settings, cwd: root.path)
        defer { originalSession.dispose() }
        let originalHost = host(originalSession)
        let originalList = try await openShareSetting(originalHost.mode)
        #expect(try shareValue(originalList) == initial.rawValue)
        originalList.handleInput("\r")
        #expect(settings.getSessionShareDestination() == destination)
        #expect(try shareValue(originalList) == destination.rawValue)
        originalList.handleInput("\u{1B}")
        await settings.flush()
        let saved = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        #expect(saved["sessionShareDestination"] as? String == destination.rawValue)

        let loaded = SettingsManager.create(root.path, path.deletingLastPathComponent().path)
        await loaded.reload()
        let loadedSession = session(loaded, cwd: root.path)
        defer { loadedSession.dispose() }
        let loadedHost = host(loadedSession)
        let loadedList = try await openShareSetting(loadedHost.mode)
        #expect(try shareValue(loadedList) == destination.rawValue)
        loadedList.handleInput("\u{1B}")

        let calls = LockedState<[[String]]>([])
        var exportedPaths: [String] = []
        loadedHost.mode.sessionShareDependencies = SessionShareDependencies(runGH: { arguments, _ in
            calls.withLock { $0.append(arguments) }
            if arguments.first == "gist" {
                #expect(arguments.prefix(3) == ["gist", "create", "--public=false"])
                let path = try #require(arguments.last)
                #expect(try String(contentsOfFile: path, encoding: .utf8) == "saved share")
                return ExecResult(stdout: "https://gist.github.com/test/saved-destination\n", stderr: "", code: 0, killed: false)
            }
            #expect(arguments == ["auth", "status"])
            return ExecResult(stdout: "", stderr: "", code: 0, killed: false)
        }, exportHTML: { sharedSession, path, themeName in
            #expect(sharedSession === loadedSession)
            #expect(sharedSession.settingsManager.getSessionShareDestination() == destination)
            #expect(!themeName.isEmpty)
            exportedPaths.append(path)
            try "saved share".write(toFile: path, atomically: true, encoding: .utf8)
        })
        await loadedHost.mode.handleEditorSubmit("/share")
        #expect(calls.withLock { $0.count } == 2)
        #expect(calls.withLock { $0.first } == ["auth", "status"])
        #expect(exportedPaths.count == 1)
        #expect(exportedPaths.allSatisfy { !FileManager.default.fileExists(atPath: $0) })
        let text = toolTestText(loadedHost.mode.chatContainer, width: 200)
        #expect(text.contains("Share URL:"))
        #expect(text.contains("#saved-destination"))
        #expect(text.contains("Gist:"))
        #expect(!text.contains("Error:"))
        #expect(loadedHost.mode.editorContainer?.children.first === loadedHost.editor)
        #expect(loaded.drainErrors().isEmpty)
    }

    // session-share.test.ts:135-155, with the deferred-Radius error required by SQ.
    @Test func savedRadiusRemainsInTheSelectorAndStopsShareBeforeGistWork() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("t2-share-radius-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let path = try settingsFile(root, destination: .radius)
        let settings = SettingsManager.create(root.path, path.deletingLastPathComponent().path)
        await settings.reload()
        let loadedSession = session(settings, cwd: root.path)
        defer { loadedSession.dispose() }
        let loadedHost = host(loadedSession)
        let list = try await openShareSetting(loadedHost.mode)
        #expect(try shareValue(list) == "radius")
        list.handleInput("\u{1B}")
        #expect(settings.getSessionShareDestination() == .radius)
        let calls = LockedState<[[String]]>([])
        var exports = 0
        loadedHost.mode.sessionShareDependencies = SessionShareDependencies(runGH: { arguments, _ in
            calls.withLock { $0.append(arguments) }
            return ExecResult(stdout: "", stderr: "", code: 0, killed: false)
        }, exportHTML: { _, _, _ in exports += 1 })
        await loadedHost.mode.handleEditorSubmit("/share")
        #expect(calls.withLock { $0 }.isEmpty)
        #expect(exports == 0)
        let text = toolTestText(loadedHost.mode.chatContainer)
        let expectedError = "Radius sharing is not available in this version."
        #expect(SessionShareError.radiusUnavailable.localizedDescription == expectedError)
        #expect(text.contains("Error: " + expectedError))
        #expect(!text.contains("/login radius"))
        #expect(!text.contains("Share URL:"))
        #expect(loadedHost.mode.editorContainer?.children.first === loadedHost.editor)
        await settings.flush()
        await settings.reload()
        #expect(settings.getSessionShareDestination() == .radius)
        let saved = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        #expect(saved["sessionShareDestination"] as? String == "radius")
    }
}
