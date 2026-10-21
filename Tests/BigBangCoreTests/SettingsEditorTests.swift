import XCTest
import Combine
@testable import BigBangCore

@MainActor private final class SettingsSink {
    var configuration = Configuration(language: .simplifiedChinese)
    var key = "existing-key"
    var writes = 0
    var keyWrites = 0
    var didSave: ((String) -> Void)?
    var fail = false
    func save(_ configuration: Configuration, _ key: String) throws {
        if fail { throw ValidationError("保存失败") }
        try configuration.validate()
        self.configuration = configuration; writes += 1
        if !key.isEmpty { self.key = key; keyWrites += 1 }
        didSave?(key)
    }
    func editor() -> SettingsEditor {
        SettingsEditor(configuration: configuration, hasKey: true, saveDelay: .milliseconds(30),
                       save: save, deleteKey: { self.key = "" })
    }
}

final class SettingsEditorTests: XCTestCase {
    @MainActor func testTypingSavesLatestValueOnceWithoutSaveButton() async {
        let sink = SettingsSink()
        let form = sink.editor()
        let saved = expectation(description: "The latest typed settings are saved")
        saved.assertForOverFulfill = true
        sink.didSave = { _ in saved.fulfill() }
        form.draft.model = "first"
        form.draft.model = "second"
        form.draft.presets[0].prompt = "最新提示词"
        await fulfillment(of: [saved], timeout: 2)
        XCTAssertEqual(sink.writes, 1)
        XCTAssertEqual(sink.configuration.model, "second")
        XCTAssertEqual(sink.configuration.presets[0].prompt, "最新提示词")
        XCTAssertEqual(sink.keyWrites, 0)
    }
    @MainActor func testSwitchAndRecordedShortcutApplyImmediately() {
        let sink = SettingsSink()
        let form = sink.editor()
        form.draft.copyFallback = false
        XCTAssertFalse(sink.configuration.copyFallback)
        form.draft.apiMode = .chatCompletions
        XCTAssertEqual(sink.configuration.apiMode, .chatCompletions)
        form.draft.presets[0].shortcut = .init(keyCode: 22, modifiers: 6144, label: "⌃⌥6")
        XCTAssertEqual(sink.configuration.presets[0].shortcut.keyCode, 22)
    }
    @MainActor func testInvalidEditPreservesSavedSettingsAndRecovers() async {
        let sink = SettingsSink()
        let form = sink.editor()
        let rejected = expectation(description: "An invalid endpoint reports a validation error")
        rejected.assertForOverFulfill = true
        let errorObservation = form.$error.dropFirst().compactMap { $0 }.sink { _ in rejected.fulfill() }
        defer { errorObservation.cancel() }
        form.draft.apiBaseURL = "https://"
        await fulfillment(of: [rejected], timeout: 2)
        XCTAssertEqual(sink.configuration.apiBaseURL, "https://api.openai.com/v1")
        XCTAssertNotNil(form.error)
        XCTAssertEqual(sink.writes, 0)
        XCTAssertEqual(sink.keyWrites, 0)
        let recovered = expectation(description: "The corrected endpoint is saved")
        recovered.assertForOverFulfill = true
        sink.didSave = { _ in recovered.fulfill() }
        form.draft.apiBaseURL = "https://example.com/proxy/v1/"
        await fulfillment(of: [recovered], timeout: 2)
        XCTAssertEqual(sink.configuration.apiBaseURL, "https://example.com/proxy/v1")
        XCTAssertEqual(sink.writes, 1)
        XCTAssertEqual(sink.keyWrites, 0)
        XCTAssertNil(form.error)
    }
    @MainActor func testCloseFlushesPendingTextAndKeyWithoutRepeatedKeyWrites() {
        let sink = SettingsSink()
        let form = sink.editor()
        form.draft.model = "custom-model"
        form.apiKeyInput = "new-key"
        form.flush()
        XCTAssertEqual(sink.configuration.model, "custom-model")
        XCTAssertEqual(sink.key, "new-key")
        form.draft.copyFallback = false
        XCTAssertEqual(sink.keyWrites, 1)
        form.flush()
        XCTAssertEqual(sink.writes, 2)
    }
    @MainActor func testDeleteKeyDoesNotRestoreItFromPendingTyping() async {
        let sink = SettingsSink()
        let form = sink.editor()
        let keySaved = expectation(description: "Deleting the credential prevents pending key writes")
        keySaved.isInverted = true
        sink.didSave = { key in if !key.isEmpty { keySaved.fulfill() } }
        form.apiKeyInput = "pending-key"
        form.deleteCredential()
        // This is an absence check, not a deadline for successful autosave completion.
        await fulfillment(of: [keySaved], timeout: 0.09)
        form.flush()
        form.draft.apiMode = .chatCompletions
        XCTAssertEqual(sink.key, "")
        XCTAssertEqual(sink.keyWrites, 0)
        XCTAssertFalse(form.hasKey)
        XCTAssertTrue(form.apiKeyInput.isEmpty)
        XCTAssertEqual(sink.writes, 1)
    }
    @MainActor func testFailedSaveCanBeRetriedAndReopenedStateMatchesSavedValue() {
        let sink = SettingsSink()
        let form = sink.editor()
        sink.fail = true
        form.draft.model = "new-model"; form.flush()
        XCTAssertNotNil(form.error)
        XCTAssertEqual(sink.configuration.model, "gpt-4.1-mini")
        sink.fail = false; form.flush()
        XCTAssertNil(form.error)
        XCTAssertEqual(sink.editor().draft.model, "new-model")
    }
}
