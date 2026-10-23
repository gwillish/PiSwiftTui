import Foundation
import Testing
import MiniTui
import PiSwiftCodingAgent
@testable import PiSwiftCodingAgentTui

@MainActor
@Suite(.serialized)
struct T1KeybindingTests {
    private let validKeys = [
        "a", "9", "pageUp", "+", "ctrl+shift+x", "alt+ctrl+?",
        "ctrl+shift+alt+super+f12", "ctrl++", "shift+=", "insert", "clear",
    ]
    private let invalidKeys = [
        "", "Ctrl+x", "control+x", "ctrl+not-a-key", "ctrl+ctrl+x",
        "ctrl+shift+alt+super+ctrl+x", "A", "pageup", "f13", "ctrl+",
        "ctrl+x+y", " x", "x\n", "é", "ctrl+super+cmd+x", "meta+cmd+x",
    ]

    private func withFile(_ document: String, check: (KeybindingsManager) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pi-t1-keybindings-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
            _ = KeybindingsManager.create(agentDir: directory.path)
        }
        try document.write(to: directory.appendingPathComponent("keybindings.json"), atomically: true, encoding: .utf8)
        try check(KeybindingsManager.create(agentDir: directory.path))
    }

    private func withBindings(_ bindings: [String: Any], check: (KeybindingsManager) throws -> Void) throws {
        let data = try JSONSerialization.data(withJSONObject: bindings)
        let document = try #require(String(data: data, encoding: .utf8))
        try withFile(document, check: check)
    }

    @Test func fileKeyGrammar() throws {
        var bindings: [String: Any] = [:]
        for (index, key) in validKeys.enumerated() { bindings["extension.valid.\(index)"] = key }
        for (index, key) in invalidKeys.enumerated() { bindings["extension.invalid.\(index)"] = key }
        try withBindings(bindings) { manager in
            let config = manager.getEffectiveConfig()
            for (index, key) in validKeys.enumerated() {
                #expect(config["extension.valid.\(index)"] == [key])
            }
            for index in invalidKeys.indices {
                #expect(config["extension.invalid.\(index)"] == nil)
            }
        }
    }

    @Test func bundledSchemaKeyGrammar() throws {
        let url = try #require(BundledConfigSchema.keybindings.url)
        let schema = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let definitions = try #require(schema["$defs"] as? [String: Any])
        let value = try #require(definitions["KeybindingValue"] as? [String: Any])
        let alternatives = try #require(value["anyOf"] as? [[String: Any]])
        let scalar = try #require(alternatives.first)
        let pattern = try #require(scalar["pattern"] as? String)
        let expression = try NSRegularExpression(pattern: pattern)
        for key in validKeys.prefix(7) {
            #expect(expression.firstMatch(in: key, range: NSRange(key.startIndex..., in: key)) != nil)
        }
        for key in invalidKeys.prefix(6) {
            #expect(expression.firstMatch(in: key, range: NSRange(key.startIndex..., in: key)) == nil)
        }
        let properties = try #require(schema["properties"] as? [String: Any])
        let metadata = try #require(properties["$schema"] as? [String: Any])
        #expect(metadata["type"] as? String == "string")
        let extensions = try #require(schema["additionalProperties"] as? [String: Any])
        #expect(extensions["$ref"] as? String == "#/$defs/KeybindingValue")
    }

    @Test func schemaMetadataAndExtensionActions() throws {
        try withBindings([
            "$schema": "https://pi.dev/schemas/keybindings.schema.json",
            "app.session.new": "ctrl+n", "extension.action": ["alt+x"],
            "extension.invalid": "ctrl+not-a-key", "extension.number": 42,
        ]) { manager in
            let config = manager.getEffectiveConfig()
            #expect(config["$schema"] == nil)
            #expect(config["app.session.new"] == ["ctrl+n"])
            #expect(config["extension.action"] == ["alt+x"])
            #expect(config["extension.invalid"] == nil)
            #expect(config["extension.number"] == nil)
        }
        try withBindings(["$schema": "a"]) { manager in
            #expect(manager.getEffectiveConfig()["$schema"] == nil)
        }
    }

    @Test func invalidWholeValuesKeepDefaults() throws {
        try withBindings([
            "interrupt": ["ctrl+c", "ctrl+not-a-key"], "clear": ["a", 42],
            "exit": NSNull(), "suspend": true, "expandTools": ["nested": "a"],
            "extension.mixed": ["a", false], "extension.invalid": ["a", "Ctrl+x"],
            "extension.valid": ["a", "ctrl+x"],
        ]) { manager in
            for action: AppAction in [.interrupt, .clear, .exit, .suspend, .expandTools] {
                #expect(manager.getKeys(action) == DEFAULT_APP_KEYBINDINGS[action])
            }
            let config = manager.getEffectiveConfig()
            #expect(config["extension.mixed"] == nil)
            #expect(config["extension.invalid"] == nil)
            #expect(config["extension.valid"] == ["a", "ctrl+x"])
        }
    }

    @Test func emptyArraysDisableDefaultsAndKeepMappings() throws {
        try withBindings([
            "interrupt": [], "submit": [], "tui.select.confirm": [],
            "app.models.save": [], "extension.disabled": [],
            "clear": "ctrl+k", "cursorUp": "ctrl+y", "app.thinking.save": "alt+s",
        ]) { manager in
            #expect(manager.getKeys(.interrupt).isEmpty)
            #expect(!manager.matches("\u{001B}", .interrupt))
            #expect(manager.getKeys(.clear) == ["ctrl+k"])
            #expect(manager.matches("\u{000B}", .clear))
            #expect(getKeybindings().getKeys(TUIKeybinding.inputSubmit).isEmpty)
            #expect(getKeybindings().getKeys("tui.select.confirm").isEmpty)
            #expect(getKeybindings().getKeys("tui.editor.cursorUp") == ["ctrl+y"])
            #expect(selectorKeyText("app.models.save").isEmpty)
            #expect(selectorKeyText("app.thinking.save") == "alt+s")
            #expect(manager.getEffectiveConfig()["extension.disabled"] == [])
        }
    }

    @Test func superAliasesKeepTheirSpelling() throws {
        try withBindings([
            "interrupt": "cmd+x", "clear": "meta+x",
            "extension.aliases": ["ctrl+shift+alt+cmd+x", "meta+ctrl+x"],
        ]) { manager in
            #expect(manager.getKeys(.interrupt) == ["cmd+x"])
            #expect(manager.getKeys(.clear) == ["meta+x"])
            #expect(manager.getEffectiveConfig()["extension.aliases"] == ["ctrl+shift+alt+cmd+x", "meta+ctrl+x"])
        }
    }

    @Test func invalidDocumentsKeepDefaults() throws {
        for document in ["[]", "null", "42", "{", "\"a\""] {
            try withFile(document) { manager in
                #expect(manager.getKeys(.interrupt) == DEFAULT_APP_KEYBINDINGS[.interrupt])
                #expect(manager.getKeys(.clear) == DEFAULT_APP_KEYBINDINGS[.clear])
            }
        }
    }

    @Test func inMemoryConfigRemainsUnfiltered() {
        let manager = KeybindingsManager.inMemory(config: [
            "interrupt": ["Ctrl+x"], "clear": [], "$schema": ["a"], "extension.action": ["not-a-key"],
        ])
        #expect(manager.getKeys(.interrupt) == ["Ctrl+x"])
        #expect(manager.getKeys(.clear).isEmpty)
        #expect(manager.getEffectiveConfig()["$schema"] == ["a"])
        #expect(manager.getEffectiveConfig()["extension.action"] == ["not-a-key"])
    }
}
