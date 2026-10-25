import XCTest
@testable import BigBangCore

@MainActor private final class PresetRecoverySink {
    var configuration: Configuration
    var writes = 0
    var keyWrites = 0
    var savedKeys: [String] = []
    var keyDidSave: (() -> Void)?
    var fail = false
    init(_ configuration: Configuration = Configuration(language: .simplifiedChinese)) { self.configuration = configuration }
    func editor(saveDelay: Duration = .seconds(30)) -> SettingsEditor {
        SettingsEditor(configuration: configuration, hasKey: true, saveDelay: saveDelay, save: { candidate, key in
            if self.fail { throw ValidationError("保存失败") }
            try candidate.validate()
            self.configuration = candidate; self.writes += 1
            if !key.isEmpty { self.keyWrites += 1; self.savedKeys.append(key); self.keyDidSave?() }
        }, deleteKey: { XCTFail("恢复预设不能删除 Key") })
    }
}

final class PresetRecoveryTests: XCTestCase {
    @MainActor func testPendingKeyAutosavesAfterRestoreWithoutAnotherConfigurationWrite() async {
        var configuration = Configuration(language: .simplifiedChinese); configuration.presets.remove(at: 1)
        let sink = PresetRecoverySink(configuration); let form = sink.editor(saveDelay: .milliseconds(30))
        let keySaved = expectation(description: "Pending credential is saved after restoring defaults")
        keySaved.assertForOverFulfill = true
        sink.keyDidSave = { keySaved.fulfill() }
        form.apiKeyInput = "synthetic-recovery-key"
        XCTAssertEqual(form.restoreDefaultPresets().count, 1)
        let restored = form.draft
        XCTAssertEqual(sink.configuration, restored)
        XCTAssertEqual(sink.writes, 1)
        XCTAssertEqual(sink.keyWrites, 0)
        await fulfillment(of: [keySaved], timeout: 2)
        XCTAssertEqual(sink.savedKeys, ["synthetic-recovery-key"])
        XCTAssertEqual(sink.configuration, restored)
        XCTAssertEqual(sink.writes, 2)
        form.flush()
        XCTAssertEqual(sink.writes, 2)
    }
    @MainActor func testPendingKeyAutosavesUsingRolledBackDraftAfterFailedRestoreAndRestoreCanRetry() async {
        var configuration = Configuration(language: .simplifiedChinese); configuration.presets.remove(at: 1)
        let sink = PresetRecoverySink(configuration); let form = sink.editor(saveDelay: .milliseconds(30))
        let keySaved = expectation(description: "Pending credential is saved using the configuration before failed restoration")
        keySaved.assertForOverFulfill = true
        sink.keyDidSave = { keySaved.fulfill() }
        form.apiKeyInput = "synthetic-recovery-key"
        sink.fail = true
        XCTAssertTrue(form.restoreDefaultPresets().isEmpty)
        XCTAssertEqual(form.draft, configuration)
        XCTAssertEqual(sink.configuration, configuration)
        XCTAssertEqual(sink.writes, 0)
        XCTAssertEqual(sink.keyWrites, 0)
        XCTAssertNotNil(form.error)
        sink.fail = false
        await fulfillment(of: [keySaved], timeout: 2)
        XCTAssertEqual(sink.savedKeys, ["synthetic-recovery-key"])
        XCTAssertEqual(sink.configuration, configuration)
        XCTAssertEqual(sink.writes, 1)
        XCTAssertNil(form.error)
        XCTAssertEqual(form.restoreDefaultPresets().count, 1)
        XCTAssertEqual(sink.configuration, form.draft)
        XCTAssertEqual(sink.writes, 2)
        XCTAssertEqual(sink.keyWrites, 1)
        form.flush()
        XCTAssertEqual(sink.writes, 2)
    }
    func testDecodingCustomPresetDoesNotInferIdentityOrRewriteContent() throws {
        var preset = Preset.defaults[0]
        preset.builtIn = nil
        preset.name = "翻译"
        let decoded = try JSONDecoder().decode(Preset.self, from: JSONEncoder().encode(preset))
        XCTAssertEqual(decoded, preset)
        XCTAssertNil(decoded.builtIn)
    }
    func testCurrentBuiltInNamesRemainExactlyAsEditedAcrossPersistence() throws {
        var configuration = Configuration(language: .simplifiedChinese)
        for index in configuration.presets.indices {
            configuration.presets[index].name = ["翻译", "解释", "总结", "可视化", "助手"][index]
        }
        let reopened = try JSONDecoder().decode(Configuration.self, from: JSONEncoder().encode(configuration))
        XCTAssertEqual(reopened.presets.map(\.name), ["翻译", "解释", "总结", "可视化", "助手"])
        XCTAssertEqual(reopened, configuration)
    }
    @MainActor func testRestoreOneMissingDefaultPreservesExistingEditsAndCustomPreset() {
        var configuration = Configuration(language: .simplifiedChinese)
        configuration.model = "local-model"; configuration.apiBaseURL = "http://localhost:11434/v1"
        configuration.apiMode = .chatCompletions; configuration.copyFallback = false
        configuration.presets.remove(at: 1)
        configuration.presets[0].name = "阅读外文"; configuration.presets[0].prompt = "自定义指令"
        configuration.presets[0].shortcut = .init(keyCode: 22, modifiers: 6144, label: "⌃⌥6")
        let custom = Preset(name: "自己的预设", prompt: "自己的指令", shortcut: .init(keyCode: 26, modifiers: 6144, label: "⌃⌥7"))
        configuration.presets.append(custom)
        let sink = PresetRecoverySink(configuration); let form = sink.editor()
        let ids = form.restoreDefaultPresets()
        XCTAssertEqual(ids.count, 1)
        XCTAssertEqual(Array(form.draft.presets.prefix(configuration.presets.count)), configuration.presets)
        XCTAssertEqual(form.draft.presets.last?.name, "💡 解释")
        XCTAssertEqual(sink.writes, 1)
        var expected = configuration; expected.presets = form.draft.presets
        XCTAssertEqual(sink.configuration, expected)
        XCTAssertTrue(form.restoreDefaultPresets().isEmpty)
        XCTAssertEqual(sink.writes, 1)
        XCTAssertEqual(sink.keyWrites, 0)
    }
    @MainActor func testRestoreAllFromEmptyListAndReopenIsIdempotent() throws {
        var configuration = Configuration(language: .simplifiedChinese); configuration.presets = []
        let sink = PresetRecoverySink(configuration); let form = sink.editor()
        XCTAssertEqual(form.restoreDefaultPresets().count, Preset.defaults.count)
        XCTAssertEqual(sink.configuration.presets, Preset.defaults)
        XCTAssertEqual(sink.writes, 1)
        sink.configuration = try JSONDecoder().decode(Configuration.self, from: JSONEncoder().encode(sink.configuration))
        let reopened = sink.editor()
        reopened.draft.presets[0].name = "改名后的翻译"
        reopened.flush()
        sink.configuration = try JSONDecoder().decode(Configuration.self, from: JSONEncoder().encode(sink.configuration))
        XCTAssertTrue(sink.editor().restoreDefaultPresets().isEmpty)
        XCTAssertEqual(sink.configuration.presets.count, Preset.defaults.count)
        XCTAssertEqual(sink.configuration.presets[0].name, "改名后的翻译")
    }
    @MainActor func testRecoveryAvoidsCustomShortcutCollisionsIncludingShiftFallback() {
        var configuration = Configuration(language: .simplifiedChinese); configuration.presets = []
        let codes: [UInt32] = [18, 19, 20, 21, 23, 22, 26, 28, 25, 29]
        for (index, code) in codes.enumerated() {
            configuration.presets.append(Preset(name: "自定义 \(index)", prompt: "自定义", shortcut: .init(keyCode: code, modifiers: 6144, label: "占用")))
        }
        let sink = PresetRecoverySink(configuration); let form = sink.editor()
        XCTAssertEqual(form.restoreDefaultPresets().count, Preset.defaults.count)
        XCTAssertEqual(Array(form.draft.presets.suffix(Preset.defaults.count)).map(\.shortcut.modifiers), Array(repeating: UInt32(6656), count: Preset.defaults.count))
        XCTAssertEqual(Array(form.draft.presets.suffix(Preset.defaults.count)).map(\.shortcut.label), ["⌃⌥⇧1", "⌃⌥⇧2", "⌃⌥⇧3", "⌃⌥⇧4", "⌃⌥⇧5"])
        XCTAssertNoThrow(try form.draft.validate())
    }
    @MainActor func testExhaustedShortcutPoolDoesNotPartiallyRestore() {
        var configuration = Configuration(language: .simplifiedChinese); configuration.presets = []
        let codes: [UInt32] = [18, 19, 20, 21, 23, 22, 26, 28, 25, 29]
        for modifiers: UInt32 in [6144, 6656] {
            for (index, code) in codes.enumerated() {
                configuration.presets.append(Preset(name: "自定义 \(index)", prompt: "自定义", shortcut: .init(keyCode: code, modifiers: modifiers, label: "占用")))
            }
        }
        configuration.presets.removeLast() // One free shortcut cannot accommodate all missing presets.
        let sink = PresetRecoverySink(configuration); let form = sink.editor()
        XCTAssertTrue(form.restoreDefaultPresets().isEmpty)
        XCTAssertEqual(form.draft, configuration)
        XCTAssertEqual(sink.configuration, configuration)
        XCTAssertEqual(sink.writes, 0)
        XCTAssertNotNil(form.error)
    }
    @MainActor func testFailedSaveRollsBackRecoveryAndRetryDoesNotWriteKey() {
        var configuration = Configuration(language: .simplifiedChinese); configuration.presets.remove(at: 1)
        let sink = PresetRecoverySink(configuration); let form = sink.editor()
        form.apiKeyInput = "pending-key"
        sink.fail = true
        XCTAssertTrue(form.restoreDefaultPresets().isEmpty)
        XCTAssertEqual(form.draft, configuration)
        XCTAssertEqual(sink.configuration, configuration)
        XCTAssertNotNil(form.error)
        XCTAssertEqual(sink.keyWrites, 0)
        sink.fail = false
        XCTAssertEqual(form.restoreDefaultPresets().count, 1)
        XCTAssertNil(form.error)
        XCTAssertTrue(form.hasKey)
        XCTAssertEqual(form.apiKeyInput, "pending-key")
        XCTAssertEqual(sink.keyWrites, 0)
    }

    @MainActor func testExistingFourPresetConfigurationOnlyAddsAssistantOnRestore() throws {
        for language in AppLanguage.allCases {
            var configuration = Configuration(language: language)
            configuration.presets = Array(configuration.presets.prefix(4))
            configuration.presets[0].name = "My name"
            configuration.presets[1].prompt = "My prompt"
            configuration.presets.reverse()
            let occupiedFifth = Preset(name: "Custom", prompt: "Custom prompt",
                shortcut: .init(keyCode: 23, modifiers: 6144, label: "⌃⌥5"))
            configuration.presets.append(occupiedFifth)
            let decoded = try JSONDecoder().decode(Configuration.self, from: JSONEncoder().encode(configuration))
            XCTAssertEqual(decoded, configuration)
            let sink = PresetRecoverySink(decoded); let editor = sink.editor()
            XCTAssertEqual(editor.restoreDefaultPresets().count, 1)
            XCTAssertEqual(Array(editor.draft.presets.dropLast()), configuration.presets)
            let assistant = try XCTUnwrap(editor.draft.presets.last)
            XCTAssertEqual(assistant.builtIn?.rawValue, "assistant")
            XCTAssertEqual(assistant.name, language == .english ? "🤖 Assistant" : "🤖 助手")
            XCTAssertNotEqual(assistant.shortcut.identity, occupiedFifth.shortcut.identity)
            XCTAssertNoThrow(try editor.draft.validate())
            XCTAssertTrue(editor.restoreDefaultPresets().isEmpty)
            XCTAssertEqual(sink.writes, 1)
        }
    }
}
