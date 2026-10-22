import XCTest
@testable import BigBangCore

@MainActor private final class PresetTransactionSink {
    var configuration: Configuration
    var writes = 0
    var keys: [String] = []
    var fail = false
    var keyDidSave: (() -> Void)?
    init(_ configuration: Configuration = Configuration(language: .simplifiedChinese)) { self.configuration = configuration }
    func editor(saveDelay: Duration = .seconds(30)) -> SettingsEditor {
        SettingsEditor(configuration: configuration, hasKey: true, saveDelay: saveDelay, save: { candidate, key in
            if self.fail { throw ValidationError("保存失败") }
            try candidate.validate()
            self.configuration = candidate; self.writes += 1
            if !key.isEmpty { self.keys.append(key); self.keyDidSave?() }
        }, deleteKey: { XCTFail("Preset operations cannot delete credentials") })
    }
}

final class PresetTransactionTests: XCTestCase {
    @MainActor func testDeleteUndoRestoresIdentityContentShortcutAndOriginalPositionWithoutOverwritingLaterEdits() throws {
        var configuration = Configuration(language: .simplifiedChinese)
        configuration.presets[2].name = "My 名称"; configuration.presets[2].prompt = "My prompt\n用户内容"
        configuration.presets[2].shortcut = .init(keyCode: 29, modifiers: 6656, label: "⌃⌥⇧0")
        let sink = PresetTransactionSink(configuration); let form = sink.editor()
        let deleted = configuration.presets[2]
        XCTAssertTrue(form.deletePreset(id: deleted.id))
        XCTAssertEqual(form.lastDeletedPreset, deleted)
        XCTAssertEqual(sink.configuration.presets, configuration.presets.filter { $0.id != deleted.id })
        form.draft.presets[0].prompt = "Later edit"
        let addedID = try XCTUnwrap(form.addPreset())
        XCTAssertEqual(form.undoDeletePreset(), deleted.id)
        XCTAssertEqual(form.draft.presets[2], deleted)
        XCTAssertEqual(form.draft.presets[0].prompt, "Later edit")
        XCTAssertEqual(form.draft.presets.last?.id, addedID)
        XCTAssertNil(form.lastDeletedPreset)
        XCTAssertEqual(sink.configuration, form.draft)
        let reopened = try JSONDecoder().decode(Configuration.self, from: JSONEncoder().encode(sink.configuration))
        XCTAssertEqual(reopened, form.draft)
    }

    @MainActor func testOnlyMostRecentSuccessfulDeletionCanBeUndoneAndFailureRetainsPreviousSnapshot() {
        let sink = PresetTransactionSink(); let form = sink.editor()
        let original = form.draft.presets
        XCTAssertTrue(form.deletePreset(id: original[0].id))
        sink.fail = true
        let beforeFailure = form.draft
        XCTAssertFalse(form.deletePreset(id: original[1].id))
        XCTAssertEqual(form.draft, beforeFailure)
        XCTAssertEqual(form.lastDeletedPreset, original[0])
        sink.fail = false
        XCTAssertTrue(form.deletePreset(id: original[1].id))
        XCTAssertEqual(form.lastDeletedPreset, original[1])
        XCTAssertEqual(form.undoDeletePreset(), original[1].id)
        XCTAssertNil(form.undoDeletePreset())
        XCTAssertFalse(form.draft.presets.contains { $0.id == original[0].id })
        XCTAssertEqual(form.draft.presets[0], original[1])
    }

    @MainActor func testFailedUndoRollsBackAndCanBeRetriedWithSnapshotIntact() {
        let sink = PresetTransactionSink(); let form = sink.editor()
        let deleted = form.draft.presets[2]
        XCTAssertTrue(form.deletePreset(id: deleted.id))
        let afterDelete = form.draft
        sink.fail = true
        XCTAssertNil(form.undoDeletePreset())
        XCTAssertEqual(form.draft, afterDelete)
        XCTAssertEqual(sink.configuration, afterDelete)
        XCTAssertEqual(form.lastDeletedPreset, deleted)
        XCTAssertNotNil(form.error)
        sink.fail = false
        XCTAssertEqual(form.undoDeletePreset(), deleted.id)
        XCTAssertEqual(form.draft.presets[2], deleted)
        XCTAssertNil(form.error)
    }

    @MainActor func testUndoClampsOriginalPositionAfterLaterListChangesAndMissingDeleteKeepsSnapshot() {
        let sink = PresetTransactionSink(); let form = sink.editor()
        let deleted = form.draft.presets.last!
        XCTAssertTrue(form.deletePreset(id: deleted.id))
        form.draft.presets = Array(form.draft.presets.prefix(1))
        let shortened = form.draft
        XCTAssertFalse(form.deletePreset(id: UUID()))
        XCTAssertEqual(form.draft, shortened)
        XCTAssertEqual(form.lastDeletedPreset, deleted)
        XCTAssertEqual(form.undoDeletePreset(), deleted.id)
        XCTAssertEqual(form.draft.presets, shortened.presets + [deleted])
        XCTAssertEqual(sink.configuration, form.draft)
    }

    @MainActor func testLastPresetCannotBeDeletedAndDismissOnlyClearsUndoSnapshot() {
        var configuration = Configuration(language: .simplifiedChinese)
        configuration.presets = Array(configuration.presets.prefix(2))
        let sink = PresetTransactionSink(configuration); let form = sink.editor()
        XCTAssertTrue(form.deletePreset(id: configuration.presets[0].id))
        let remaining = form.draft
        XCTAssertFalse(form.deletePreset(id: configuration.presets[1].id))
        XCTAssertEqual(form.draft, remaining)
        XCTAssertEqual(form.lastDeletedPreset, configuration.presets[0])
        XCTAssertEqual(sink.writes, 1)
        form.dismissDeletedPreset()
        XCTAssertNil(form.lastDeletedPreset)
        XCTAssertNil(form.undoDeletePreset())
        XCTAssertEqual(form.draft, remaining)
        XCTAssertEqual(sink.writes, 1)
    }

    @MainActor func testUndoRefusesExistingIdentityAndCanRecoverAfterConflictRemoved() {
        let sink = PresetTransactionSink(); let form = sink.editor()
        let deleted = form.draft.presets[1]
        XCTAssertTrue(form.deletePreset(id: deleted.id))
        var replacement = deleted
        replacement.name = "Replacement"; replacement.shortcut = .init(keyCode: 29, modifiers: 6656, label: "⌃⌥⇧0")
        form.draft.presets.append(replacement)
        let conflicted = form.draft; let writes = sink.writes
        XCTAssertNil(form.undoDeletePreset())
        XCTAssertEqual(form.draft, conflicted)
        XCTAssertEqual(sink.writes, writes)
        XCTAssertEqual(form.lastDeletedPreset, deleted)
        XCTAssertEqual(form.error, "无法撤销删除：此预设已存在。")
        form.draft.presets.removeAll { $0.id == replacement.id }
        XCTAssertEqual(form.undoDeletePreset(), deleted.id)
        XCTAssertEqual(form.draft.presets[1], deleted)
    }

    @MainActor func testUndoRefusesOccupiedOriginalShortcutAndPreservesSnapshotForRetry() {
        let sink = PresetTransactionSink(); let form = sink.editor()
        let deleted = form.draft.presets[1]
        XCTAssertTrue(form.deletePreset(id: deleted.id))
        let previousShortcut = form.draft.presets[0].shortcut
        form.draft.presets[0].shortcut = deleted.shortcut
        let conflicted = form.draft
        XCTAssertNil(form.undoDeletePreset())
        XCTAssertEqual(form.draft, conflicted)
        XCTAssertEqual(form.lastDeletedPreset, deleted)
        XCTAssertEqual(form.error, "无法撤销删除：原快捷键已被其他预设使用，请先更改该快捷键。")
        form.draft.presets[0].shortcut = previousShortcut
        XCTAssertEqual(form.undoDeletePreset(), deleted.id)
    }

    @MainActor func testConsecutiveAddsChooseUniqueShortcutsUntilPoolExhaustion() throws {
        let sink = PresetTransactionSink(); let form = sink.editor()
        let original = form.draft
        for _ in 0..<15 {
            XCTAssertNotNil(form.addPreset())
            XCTAssertNoThrow(try form.draft.validate())
        }
        XCTAssertEqual(form.draft.presets.count, 20)
        XCTAssertEqual(Set(form.draft.presets.map { $0.shortcut.identity }).count, 20)
        XCTAssertEqual(Array(form.draft.presets.prefix(original.presets.count)), original.presets)
        XCTAssertEqual(form.draft.presets[5].shortcut.label, "⌃⌥6")
        XCTAssertEqual(form.draft.presets[10].shortcut.label, "⌃⌥⇧1")
        XCTAssertEqual(form.draft.presets.last?.shortcut.label, "⌃⌥⇧0")
        let full = form.draft; let writes = sink.writes
        XCTAssertNil(form.addPreset())
        XCTAssertEqual(form.draft, full)
        XCTAssertEqual(sink.writes, writes)
        XCTAssertNotNil(form.error)
    }

    @MainActor func testAddPrefersKeepingDeletedShortcutFreeButCanUseItWhenOnlyChoice() throws {
        let sink = PresetTransactionSink(); let form = sink.editor()
        let deleted = form.draft.presets[0]
        XCTAssertTrue(form.deletePreset(id: deleted.id))
        for _ in 0..<15 {
            let id = try XCTUnwrap(form.addPreset())
            XCTAssertNotEqual(form.draft.presets.first { $0.id == id }?.shortcut.identity, deleted.shortcut.identity)
        }
        XCTAssertEqual(form.lastDeletedPreset, deleted)
        let finalID = try XCTUnwrap(form.addPreset())
        XCTAssertEqual(form.draft.presets.first { $0.id == finalID }?.shortcut.identity, deleted.shortcut.identity)
        XCTAssertNil(form.undoDeletePreset())
        XCTAssertEqual(form.lastDeletedPreset, deleted)
    }

    @MainActor func testEnglishNewPresetUsesDraftLanguageAndFailedAddRollsBack() throws {
        let sink = PresetTransactionSink(Configuration(language: .english)); let form = sink.editor()
        let original = form.draft
        sink.fail = true
        XCTAssertNil(form.addPreset())
        XCTAssertEqual(form.draft, original)
        XCTAssertEqual(sink.configuration, original)
        XCTAssertEqual(sink.writes, 0)
        sink.fail = false
        let id = try XCTUnwrap(form.addPreset())
        let added = try XCTUnwrap(form.draft.presets.first { $0.id == id })
        XCTAssertEqual(added.name, "New Preset")
        XCTAssertEqual(added.prompt, "Process the text provided by the user.")
        XCTAssertNil(added.builtIn)
        XCTAssertNil(form.error)
    }

    @MainActor func testFailedAddKeepsExistingDeleteSnapshot() {
        let sink = PresetTransactionSink(); let form = sink.editor()
        let deleted = form.draft.presets[1]
        XCTAssertTrue(form.deletePreset(id: deleted.id))
        let beforeAdd = form.draft
        sink.fail = true
        XCTAssertNil(form.addPreset())
        XCTAssertEqual(form.draft, beforeAdd)
        XCTAssertEqual(form.lastDeletedPreset, deleted)
    }

    @MainActor func testInvalidDraftRejectsAllPresetTransactionsWithoutChangingUndoState() {
        let sink = PresetTransactionSink(); let form = sink.editor()
        let deleted = form.draft.presets[1]
        XCTAssertTrue(form.deletePreset(id: deleted.id))
        form.draft.model = ""
        let invalid = form.draft; let saved = sink.configuration; let writes = sink.writes
        XCTAssertNil(form.addPreset())
        XCTAssertFalse(form.deletePreset(id: form.draft.presets[0].id))
        XCTAssertNil(form.undoDeletePreset())
        XCTAssertEqual(form.draft, invalid)
        XCTAssertEqual(sink.configuration, saved)
        XCTAssertEqual(sink.writes, writes)
        XCTAssertEqual(form.lastDeletedPreset, deleted)
    }

    @MainActor func testPendingKeyContinuesDebounceAfterEachSuccessfulPresetTransaction() async throws {
        for operation in ["add", "delete", "undo"] {
            let sink = PresetTransactionSink(); let form = sink.editor(saveDelay: .milliseconds(30))
            let id = form.draft.presets[1].id
            if operation == "undo" { XCTAssertTrue(form.deletePreset(id: id)) }
            let baselineWrites = sink.writes
            let saved = expectation(description: "Pending credential after \(operation)")
            saved.assertForOverFulfill = true; sink.keyDidSave = { saved.fulfill() }
            form.apiKeyInput = "new-key"
            switch operation {
            case "add": XCTAssertNotNil(form.addPreset())
            case "delete": XCTAssertTrue(form.deletePreset(id: id))
            default: XCTAssertEqual(form.undoDeletePreset(), id)
            }
            XCTAssertEqual(sink.writes, baselineWrites + 1)
            XCTAssertTrue(sink.keys.isEmpty)
            await fulfillment(of: [saved], timeout: 2)
            XCTAssertEqual(sink.keys, ["new-key"])
            XCTAssertEqual(sink.configuration, form.draft)
            form.flush()
            XCTAssertEqual(sink.writes, baselineWrites + 2)
        }
    }

    @MainActor func testPendingKeyContinuesDebounceAfterFailedPresetTransactionUsingRolledBackDraft() async {
        for operation in ["add", "delete", "undo"] {
            let sink = PresetTransactionSink(); let form = sink.editor(saveDelay: .milliseconds(30))
            let id = form.draft.presets[1].id
            if operation == "undo" { XCTAssertTrue(form.deletePreset(id: id)) }
            let original = form.draft
            let saved = expectation(description: "Pending credential after failed \(operation)")
            saved.assertForOverFulfill = true; sink.keyDidSave = { saved.fulfill() }
            form.apiKeyInput = "new-key"; sink.fail = true
            switch operation {
            case "add": XCTAssertNil(form.addPreset())
            case "delete": XCTAssertFalse(form.deletePreset(id: id))
            default: XCTAssertNil(form.undoDeletePreset())
            }
            XCTAssertEqual(form.draft, original)
            XCTAssertTrue(sink.keys.isEmpty)
            sink.fail = false
            await fulfillment(of: [saved], timeout: 2)
            XCTAssertEqual(sink.keys, ["new-key"])
            XCTAssertEqual(sink.configuration, original)
        }
    }
}
