import XCTest
@testable import BigBangCore

@MainActor private final class PresetOrderingSink {
    var configuration: Configuration
    var writes = 0
    var configurationChanges = 0
    var keyWrites = 0
    var keyDidSave: (() -> Void)?
    var fail = false
    init(_ configuration: Configuration = Configuration(language: .simplifiedChinese)) { self.configuration = configuration }
    func editor(saveDelay: Duration = .seconds(30)) -> SettingsEditor {
        SettingsEditor(configuration: configuration, hasKey: true, saveDelay: saveDelay, save: { candidate, key in
            if self.fail { throw ValidationError("保存失败") }
            try candidate.validate()
            if self.configuration != candidate { self.configurationChanges += 1 }
            self.configuration = candidate; self.writes += 1
            if !key.isEmpty { self.keyWrites += 1; self.keyDidSave?() }
        }, deleteKey: { XCTFail("排序不能删除 Key") })
    }
}

final class PresetOrderingTests: XCTestCase {
    @MainActor func testPendingKeyAutosavesOnceAfterSuccessfulMoveWithoutAnotherOrderChange() async throws {
        let sink = PresetOrderingSink(); let form = sink.editor(saveDelay: .milliseconds(30))
        let original = form.draft.presets
        let keySaved = expectation(description: "Pending key is saved after the order transaction")
        keySaved.assertForOverFulfill = true
        sink.keyDidSave = { keySaved.fulfill() }
        form.apiKeyInput = "new-key"
        XCTAssertTrue(form.movePreset(id: original[1].id, by: -1))
        XCTAssertEqual(sink.writes, 1)
        XCTAssertEqual(sink.keyWrites, 0)
        await fulfillment(of: [keySaved], timeout: 2)
        XCTAssertEqual(sink.keyWrites, 1)
        XCTAssertEqual(sink.writes, 2)
        XCTAssertEqual(sink.configurationChanges, 1)
        XCTAssertEqual(sink.configuration.presets, [original[1], original[0]] + Array(original.dropFirst(2)))
        form.flush()
        XCTAssertEqual(sink.keyWrites, 1)
        XCTAssertEqual(sink.writes, 2)
    }
    @MainActor func testPendingKeyAutosavesAfterFailedMoveUsingRolledBackOrder() async throws {
        let sink = PresetOrderingSink(); let form = sink.editor(saveDelay: .milliseconds(30))
        let original = form.draft
        let keySaved = expectation(description: "Pending key is saved using the rolled-back order")
        keySaved.assertForOverFulfill = true
        sink.keyDidSave = { keySaved.fulfill() }
        form.apiKeyInput = "new-key"
        sink.fail = true
        XCTAssertFalse(form.movePreset(id: original.presets[1].id, by: -1))
        XCTAssertEqual(form.draft, original)
        XCTAssertEqual(sink.keyWrites, 0)
        XCTAssertNotNil(form.error)
        sink.fail = false
        await fulfillment(of: [keySaved], timeout: 2)
        XCTAssertEqual(sink.keyWrites, 1)
        XCTAssertEqual(sink.writes, 1)
        XCTAssertEqual(sink.configurationChanges, 0)
        XCTAssertEqual(sink.configuration, original)
        XCTAssertNil(form.error)
    }
    @MainActor func testMoveUpAndDownSavesEachOrderImmediatelyOnce() {
        let sink = PresetOrderingSink(); let form = sink.editor()
        let original = form.draft.presets
        XCTAssertTrue(form.movePreset(id: original[1].id, by: -1))
        XCTAssertEqual(form.draft.presets, [original[1], original[0]] + Array(original.dropFirst(2)))
        XCTAssertEqual(sink.configuration, form.draft)
        XCTAssertEqual(sink.writes, 1)
        XCTAssertTrue(form.movePreset(id: original[1].id, by: 1))
        XCTAssertEqual(form.draft.presets, original)
        XCTAssertEqual(sink.configuration, form.draft)
        XCTAssertEqual(sink.writes, 2)
        XCTAssertEqual(sink.keyWrites, 0)
    }
    @MainActor func testBoundaryMissingIDAndUnsupportedDistanceDoNothing() {
        let sink = PresetOrderingSink(); let form = sink.editor()
        let original = form.draft
        XCTAssertFalse(form.movePreset(id: original.presets[0].id, by: -1))
        XCTAssertFalse(form.movePreset(id: original.presets.last!.id, by: 1))
        XCTAssertFalse(form.movePreset(id: UUID(), by: 1))
        XCTAssertFalse(form.movePreset(id: original.presets[1].id, by: 0))
        XCTAssertFalse(form.movePreset(id: original.presets[1].id, by: Int.min))
        XCTAssertEqual(form.draft, original)
        XCTAssertEqual(sink.configuration, original)
        XCTAssertEqual(sink.writes, 0)
        XCTAssertNil(form.error)
    }
    @MainActor func testCustomContentIdentityAndSettingsSurviveMoveAndJSONReopen() throws {
        var configuration = Configuration(language: .simplifiedChinese)
        configuration.model = "custom-model"; configuration.apiMode = .chatCompletions
        configuration.apiBaseURL = "http://localhost:11434/v1"; configuration.copyFallback = false
        configuration.presets[0].name = "自选名字"; configuration.presets[0].prompt = "修改的提示词"
        configuration.presets[0].shortcut = .init(keyCode: 22, modifiers: 6144, label: "⌃⌥6")
        let custom = Preset(name: "自定义", prompt: "自定义提示词", shortcut: .init(keyCode: 28, modifiers: 6144, label: "⌃⌥8"))
        configuration.presets.append(custom)
        let sink = PresetOrderingSink(configuration); let form = sink.editor()
        form.apiKeyInput = "待保存的 Key"
        XCTAssertTrue(form.movePreset(id: custom.id, by: -1))
        var expected = configuration
        expected.presets.swapAt(expected.presets.count - 1, expected.presets.count - 2)
        XCTAssertEqual(form.draft, expected)
        XCTAssertEqual(sink.configuration, expected)
        XCTAssertEqual(sink.keyWrites, 0)
        XCTAssertEqual(form.apiKeyInput, "待保存的 Key")
        let reopened = try JSONDecoder().decode(Configuration.self, from: JSONEncoder().encode(sink.configuration))
        XCTAssertEqual(reopened, expected)
        XCTAssertEqual(PresetOrderingSink(reopened).editor().draft.presets.map(\.id), expected.presets.map(\.id))
    }
    @MainActor func testFailedSaveRollsBackOrderAndRetryPersistsOnce() {
        let sink = PresetOrderingSink(); let form = sink.editor()
        let original = form.draft
        sink.fail = true
        XCTAssertFalse(form.movePreset(id: original.presets[1].id, by: -1))
        XCTAssertEqual(form.draft, original)
        XCTAssertEqual(sink.configuration, original)
        XCTAssertEqual(sink.writes, 0)
        XCTAssertEqual(form.error, "保存失败")
        sink.fail = false
        XCTAssertTrue(form.movePreset(id: original.presets[1].id, by: -1))
        XCTAssertEqual(sink.configuration.presets, [original.presets[1], original.presets[0]] + Array(original.presets.dropFirst(2)))
        XCTAssertEqual(form.draft, sink.configuration)
        XCTAssertEqual(sink.writes, 1)
        XCTAssertNil(form.error)
    }
    @MainActor func testInvalidDraftRejectsMoveWithoutChangingOrderOrSavedSettings() {
        let sink = PresetOrderingSink(); let form = sink.editor()
        let saved = sink.configuration
        form.draft.presets[1].prompt = ""
        let beforeMove = form.draft
        XCTAssertFalse(form.movePreset(id: beforeMove.presets[1].id, by: -1))
        XCTAssertEqual(form.draft, beforeMove)
        XCTAssertEqual(sink.configuration, saved)
        XCTAssertEqual(sink.writes, 0)
        XCTAssertNotNil(form.error)
        form.draft.presets[1].prompt = saved.presets[1].prompt
        XCTAssertTrue(form.movePreset(id: beforeMove.presets[1].id, by: -1))
        XCTAssertEqual(sink.writes, 1)
        XCTAssertNil(form.error)
    }
}
