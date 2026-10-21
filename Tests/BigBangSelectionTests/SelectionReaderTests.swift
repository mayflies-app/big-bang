import XCTest
import BigBangCore
@testable import BigBangSelection

@MainActor private final class SelectionFixture: SelectionEnvironment {
    var isTrusted = true
    var frontmostPID: Int32? = 42
    var ownPID: Int32 = 99
    var ax = AccessibilitySelection()
    var clipboard = SelectionClipboard(changeCount: 7, text: "Old clipboard")
    var storedClipboard: ClipboardSnapshot = [["public.utf8-plain-text": Data("Old clipboard".utf8), "public.rtf": Data([1, 2, 3])]]
    var copiedText: String? = "Selected in editor"
    var copiedCustomData: [String: Data] = [:]
    var heldForPauses = 0
    var copySent = false
    var sentWhileHeld = false
    var snapshots = 0
    var markerWrites = 0
    var restores = 0
    var pauses = 0
    var pausedMilliseconds = 0
    var copyError: Error?
    var onPause: ((SelectionFixture) throws -> Void)?
    var onSelection: (() async -> Void)?

    func selection(pid: Int32) async -> AccessibilitySelection {
        await onSelection?()
        return ax
    }
    func shortcutIsHeld(keyCode: UInt16?) -> Bool { pauses < heldForPauses }
    func clipboardSnapshot() -> ClipboardSnapshot { snapshots += 1; return storedClipboard }
    func installMarker(_ marker: String) { markerWrites += 1; clipboard = .init(changeCount: clipboard.changeCount + 1, text: nil) }
    func restoreClipboard(_ snapshot: ClipboardSnapshot) { restores += 1; storedClipboard = snapshot; clipboard.changeCount += 1; clipboard.text = "Old clipboard" }
    func sendCopy(pid: Int32) throws {
        if let copyError { throw copyError }
        copySent = true; sentWhileHeld = shortcutIsHeld(keyCode: nil)
    }
    func pause(milliseconds: Int) async throws {
        pauses += 1
        pausedMilliseconds += milliseconds
        if let onPause { try onPause(self) }
        else if copySent, let copiedText {
            clipboard = .init(changeCount: clipboard.changeCount + 1, text: copiedText, customData: copiedCustomData)
        }
    }
}

final class SelectionReaderTests: XCTestCase {
    private var savedLanguage: AppLanguage?

    override func setUp() {
        super.setUp()
        savedLanguage = L10n.currentLanguage
        L10n.currentLanguage = .simplifiedChinese
    }

    override func tearDown() {
        if let savedLanguage { L10n.currentLanguage = savedLanguage }
        super.tearDown()
    }

    @MainActor func testEmptyAXTextFallsBackToActualEditorSelection() async throws {
        let fixture = SelectionFixture(); fixture.ax.text = ""; fixture.ax.rangeLength = 0
        let expected = String(repeating: "中文选区\n", count: 100)
        fixture.copiedText = expected
        var phases: [SelectionClipboardPhase] = []
        let text = try await SelectionReader.read(copyFallback: true, environment: fixture, onClipboardPhase: { phase in
            phases.append(phase)
            if phase == .began {
                XCTAssertEqual(fixture.markerWrites, 0); XCTAssertEqual(fixture.clipboard.text, "Old clipboard")
            } else {
                XCTAssertEqual(fixture.restores, 1); XCTAssertEqual(fixture.clipboard.text, "Old clipboard")
            }
        })
        XCTAssertEqual(text, expected)
        XCTAssertEqual(fixture.restores, 1)
        XCTAssertEqual(phases, [.began, .ended])
    }

    @MainActor func testZeroAXRangeFallsBackToCopy() async throws {
        let fixture = SelectionFixture(); fixture.ax.rangeLength = 0
        let text = try await SelectionReader.read(copyFallback: true, environment: fixture)
        XCTAssertEqual(text, fixture.copiedText)
    }

    @MainActor func testRangeCanSupplyTextWhenSelectedTextAttributeIsEmpty() async throws {
        let fixture = SelectionFixture(); fixture.ax.text = ""; fixture.ax.rangeLength = 12; fixture.ax.rangeText = "真实选区"
        let text = try await SelectionReader.read(copyFallback: false, environment: fixture)
        XCTAssertEqual(text, "真实选区")
        XCTAssertFalse(fixture.copySent)
    }

    @MainActor func testCopyWaitsForTriggerKeyAndModifiersToBeReleased() async throws {
        let fixture = SelectionFixture(); fixture.heldForPauses = 3
        let text = try await SelectionReader.read(copyFallback: true, triggerKeyCode: 18, environment: fixture)
        XCTAssertEqual(text, fixture.copiedText)
        XCTAssertFalse(fixture.sentWhileHeld)
        XCTAssertGreaterThanOrEqual(fixture.pauses, 4)
    }

    @MainActor func testElectronClipboardClearBeforeTextDoesNotFailEarly() async throws {
        let fixture = SelectionFixture()
        fixture.onPause = { state in
            state.clipboard = .init(changeCount: state.clipboard.changeCount + 1, text: state.pauses == 1 ? nil : "稍后到达的选区")
        }
        let text = try await SelectionReader.read(copyFallback: true, environment: fixture)
        XCTAssertEqual(text, "稍后到达的选区")
        XCTAssertEqual(fixture.restores, 1)
    }

    @MainActor func testVSCodeEmptySelectionCopyIsRejected() async {
        let fixture = SelectionFixture()
        fixture.copiedText = "Entire current line\n"
        fixture.copiedCustomData["vscode-editor-data"] = Data(#"{"version":1,"isFromEmptySelection":true}"#.utf8)
        do { _ = try await SelectionReader.read(copyFallback: true, environment: fixture); XCTFail("An empty editor selection must not process the current line") }
        catch { XCTAssertTrue(error.localizedDescription.contains("没有选中")) }
        XCTAssertEqual(fixture.restores, 1)
    }

    @MainActor func testNativeSelectionDoesNotTouchClipboard() async throws {
        let fixture = SelectionFixture(); fixture.ax.text = "  选中的原文\n"
        var phases: [SelectionClipboardPhase] = []
        let text = try await SelectionReader.read(copyFallback: true, environment: fixture, onClipboardPhase: { phases.append($0) })
        XCTAssertEqual(text, fixture.ax.text)
        XCTAssertFalse(fixture.copySent); XCTAssertEqual(fixture.snapshots, 0)
        XCTAssertTrue(phases.isEmpty)
    }

    @MainActor func testDisabledFallbackNeverSendsCopy() async {
        let fixture = SelectionFixture(); fixture.ax.text = ""
        do { _ = try await SelectionReader.read(copyFallback: false, environment: fixture); XCTFail("Expected unavailable selection") } catch {}
        XCTAssertFalse(fixture.copySent); XCTAssertEqual(fixture.snapshots, 0)
    }

    @MainActor func testSecureFieldNeverFallsBack() async {
        let fixture = SelectionFixture(); fixture.ax.isSecure = true
        do { _ = try await SelectionReader.read(copyFallback: true, environment: fixture); XCTFail("Expected secure field rejection") }
        catch { XCTAssertTrue(error.localizedDescription.contains("密码")) }
        XCTAssertFalse(fixture.copySent); XCTAssertEqual(fixture.snapshots, 0)
    }

    @MainActor func testOversizedAXTextDoesNotFallBack() async {
        let fixture = SelectionFixture(); fixture.ax.text = String(repeating: "中", count: 33_334)
        do { _ = try await SelectionReader.read(copyFallback: true, environment: fixture); XCTFail("Expected byte limit") }
        catch { XCTAssertTrue(error.localizedDescription.contains("100 KB")) }
        XCTAssertFalse(fixture.copySent)
    }

    @MainActor func testStaleClipboardNeverCountsAsSelection() async {
        let fixture = SelectionFixture(); fixture.copiedText = nil
        do { _ = try await SelectionReader.read(copyFallback: true, environment: fixture); XCTFail("Old clipboard must not be returned") } catch {}
        XCTAssertEqual(fixture.restores, 1)
    }

    @MainActor func testCancellationBeforePostingNeverTouchesClipboard() async {
        let fixture = SelectionFixture(); fixture.heldForPauses = 3
        var task: Task<String, Error>!
        fixture.onPause = { _ in task.cancel() }
        task = Task { try await SelectionReader.read(copyFallback: true, environment: fixture) }
        do { _ = try await task.value; XCTFail("Expected cancellation before posting") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(fixture.copySent); XCTAssertEqual(fixture.snapshots, 0); XCTAssertEqual(fixture.restores, 0)
    }

    @MainActor func testCancellationAfterPostingWaitsForLateCopyBeforeRestoringAllFormats() async {
        let fixture = SelectionFixture(); let original = fixture.storedClipboard
        var phases: [SelectionClipboardPhase] = []
        var task: Task<String, Error>!
        fixture.onPause = { state in
            if state.pauses == 1 { task.cancel() }
            XCTAssertEqual(state.restores, 0, "Do not restore before the posted copy arrives")
            if state.pauses == 5 {
                state.clipboard = .init(changeCount: state.clipboard.changeCount + 1, text: "Late selection")
            }
        }
        task = Task {
            try await SelectionReader.read(copyFallback: true, environment: fixture, onClipboardPhase: { phase in
                phases.append(phase)
                if phase == .ended {
                    XCTAssertEqual(fixture.pausedMilliseconds, 150); XCTAssertEqual(fixture.restores, 1)
                    XCTAssertEqual(fixture.storedClipboard, original)
                }
            })
        }
        do { _ = try await task.value; XCTFail("Cancelled callers must not receive the late selection") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(fixture.copySent); XCTAssertEqual(fixture.pausedMilliseconds, 150)
        XCTAssertEqual(fixture.restores, 1); XCTAssertEqual(fixture.storedClipboard, original)
        XCTAssertEqual(fixture.clipboard.text, "Old clipboard")
        XCTAssertEqual(phases, [.began, .ended])
    }

    @MainActor func testCancellationAtClipboardBeganEndsWithoutWritingMarkerOrPostingCopy() async {
        let fixture = SelectionFixture(); let original = fixture.storedClipboard
        var phases: [SelectionClipboardPhase] = []
        var task: Task<String, Error>!
        task = Task {
            try await SelectionReader.read(copyFallback: true, environment: fixture, onClipboardPhase: { phase in
                phases.append(phase)
                if phase == .began { task.cancel() }
                XCTAssertEqual(fixture.markerWrites, 0)
            })
        }
        do { _ = try await task.value; XCTFail("Expected cancellation at clipboard begin") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(phases, [.began, .ended])
        XCTAssertFalse(fixture.copySent); XCTAssertEqual(fixture.restores, 0)
        XCTAssertEqual(fixture.storedClipboard, original); XCTAssertEqual(fixture.clipboard.text, "Old clipboard")
    }

    @MainActor func testCancellationDuringAccessibilityReadNeverTouchesClipboard() async {
        let fixture = SelectionFixture()
        fixture.onSelection = { withUnsafeCurrentTask { $0?.cancel() } }
        let task = Task { try await SelectionReader.read(copyFallback: true, environment: fixture) }
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(fixture.copySent); XCTAssertEqual(fixture.snapshots, 0); XCTAssertEqual(fixture.restores, 0)
    }

    @MainActor func testFocusChangeDuringAccessibilityReadRejectsOldSourceText() async {
        let fixture = SelectionFixture(); fixture.ax.text = "Old source selection"
        fixture.onSelection = { fixture.frontmostPID = 43 }
        do { _ = try await SelectionReader.read(copyFallback: true, environment: fixture); XCTFail("Old source text must not be returned") }
        catch { XCTAssertTrue(error.localizedDescription.contains("前台应用")) }
        XCTAssertFalse(fixture.copySent); XCTAssertEqual(fixture.snapshots, 0)
    }

    @MainActor func testUncertainSecureFieldCheckDoesNotReadTextOrSendCopy() async {
        let fixture = SelectionFixture(); fixture.ax.isSecureCheckUncertain = true
        fixture.ax.text = "Must not be read after a security check timeout"
        do { _ = try await SelectionReader.read(copyFallback: true, environment: fixture); XCTFail("Uncertain field security must fall back to manual input") }
        catch { XCTAssertTrue(error.localizedDescription.contains("没有提供可读取")) }
        XCTAssertFalse(fixture.copySent); XCTAssertEqual(fixture.snapshots, 0)
    }

    @MainActor func testFocusChangeDoesNotOverwriteNewClipboard() async {
        for (language, expectedError) in [(AppLanguage.simplifiedChinese, "前台应用"), (.english, "foreground app")] {
            L10n.currentLanguage = language
            let fixture = SelectionFixture()
            fixture.onPause = { state in
                state.frontmostPID = 43
                state.clipboard = .init(changeCount: state.clipboard.changeCount + 1, text: "New user copy")
            }
            var phases: [SelectionClipboardPhase] = []
            do {
                _ = try await SelectionReader.read(copyFallback: true, environment: fixture, onClipboardPhase: { phase in
                    phases.append(phase)
                    if phase == .ended {
                        XCTAssertEqual(fixture.restores, 0); XCTAssertEqual(fixture.clipboard.text, "New user copy")
                    }
                })
                XCTFail("Expected front application change")
            }
            catch { XCTAssertTrue(error.localizedDescription.contains(expectedError), error.localizedDescription) }
            XCTAssertEqual(fixture.restores, 0); XCTAssertEqual(fixture.clipboard.text, "New user copy")
            XCTAssertEqual(phases, [.began, .ended])
        }
    }

    @MainActor func testCancellationRestoresAllOriginalClipboardFormats() async {
        let fixture = SelectionFixture(); let original = fixture.storedClipboard
        fixture.onPause = { _ in throw CancellationError() }
        do { _ = try await SelectionReader.read(copyFallback: true, environment: fixture); XCTFail("Expected cancellation") } catch {}
        XCTAssertEqual(fixture.storedClipboard, original); XCTAssertEqual(fixture.restores, 1)
    }

    @MainActor func testVSCodeEditorMetadataConfirmsActualSelection() async throws {
        let fixture = SelectionFixture(); fixture.ax.isEditorInput = true
        fixture.ax.text = ""; fixture.ax.rangeLength = 0
        fixture.copiedCustomData["vscode-editor-data"] = Data(#"{"version":1,"isFromEmptySelection":false}"#.utf8)
        let text = try await SelectionReader.read(copyFallback: true, environment: fixture)
        XCTAssertEqual(text, fixture.copiedText)
    }

    @MainActor func testVSCodeCopyPasteControllerMetadataConfirmsActualSelection() async throws {
        let fixture = SelectionFixture(); fixture.ax.isEditorInput = true
        fixture.ax.text = ""; fixture.ax.rangeLength = 0
        fixture.copiedCustomData["application/vnd.code.copymetadata"] = Data(#"{"defaultPastePayload":{"pasteOnNewLine":false,"multicursorText":null,"isBlock":false,"mode":null}}"#.utf8)
        let text = try await SelectionReader.read(copyFallback: true, environment: fixture)
        XCTAssertEqual(text, fixture.copiedText); XCTAssertEqual(fixture.restores, 1)
    }

    @MainActor func testVSCodeCopyPasteControllerEmptySelectionStillRejectsWholeLine() async {
        let fixture = SelectionFixture(); fixture.ax.isEditorInput = true
        fixture.copiedText = "Entire current line\n"
        fixture.copiedCustomData["application/vnd.code.copymetadata"] = Data(#"{"defaultPastePayload":{"pasteOnNewLine":true,"multicursorText":null,"isBlock":false,"mode":null}}"#.utf8)
        do { _ = try await SelectionReader.read(copyFallback: true, environment: fixture); XCTFail("Must reject copy from an empty selection") }
        catch { XCTAssertTrue(error.localizedDescription.contains("没有选中")) }
        XCTAssertEqual(fixture.restores, 1)
    }

    @MainActor func testVSCodePlainTextOnlyCopyReadsCompleteSelectedFixture() async throws {
        // Reproduced with VS Code 1.141.0: full fixture copied, only UTF-8/string types,
        // no Chromium/VS Code metadata. See selection-0.3.2-metadata-before/vscode-live.json.
        let fixture = SelectionFixture(); fixture.ax.isEditorInput = true
        fixture.ax.text = ""; fixture.ax.rangeLength = 0
        fixture.copiedText = "Big Bang VS Code selection fixture.\n" + String(repeating: "Selected text 中文选区 verification: alpha beta gamma delta.\n", count: 24)
        let text = try await SelectionReader.read(copyFallback: true, environment: fixture)
        XCTAssertEqual(text, fixture.copiedText)
        XCTAssertEqual(fixture.pauses, 4)
        XCTAssertEqual(fixture.restores, 1)
    }

    @MainActor func testTerminalAndOrdinaryInputCopyDoesNotRequireEditorMetadata() async throws {
        let fixture = SelectionFixture(); fixture.ax.text = ""; fixture.ax.rangeLength = 0
        fixture.copiedText = "selected terminal output"
        let text = try await SelectionReader.read(copyFallback: true, environment: fixture)
        XCTAssertEqual(text, "selected terminal output"); XCTAssertEqual(fixture.pauses, 1)
    }

    @MainActor func testVSCodeMetadataArrivingAfterTextIsReadBeforeAcceptingCopy() async {
        let fixture = SelectionFixture(); fixture.ax.isEditorInput = true
        fixture.onPause = { state in
            state.clipboard = .init(changeCount: state.clipboard.changeCount + 1, text: "Entire current line\n",
                                   customData: state.pauses == 1 ? [:] : ["vscode-editor-data": Data(#"{"version":1,"isFromEmptySelection":true}"#.utf8)])
        }
        do { _ = try await SelectionReader.read(copyFallback: true, environment: fixture); XCTFail("Must await editor metadata") }
        catch { XCTAssertTrue(error.localizedDescription.contains("没有选中")) }
        XCTAssertEqual(fixture.pauses, 2)
    }

    @MainActor func testEmptySelectionMetadataAtGraceBoundaryStillRejectsWholeLine() async {
        let fixture = SelectionFixture(); fixture.ax.isEditorInput = true
        fixture.onPause = { state in
            state.clipboard = .init(changeCount: state.clipboard.changeCount + 1, text: "Entire current line\n",
                customData: state.pauses < 4 ? [:] : ["vscode-editor-data": Data(#"{"version":1,"isFromEmptySelection":true}"#.utf8)])
        }
        do { _ = try await SelectionReader.read(copyFallback: true, environment: fixture); XCTFail("Metadata wins at grace boundary") }
        catch { XCTAssertTrue(error.localizedDescription.contains("没有选中")) }
        XCTAssertEqual(fixture.pauses, 4); XCTAssertEqual(fixture.restores, 1)
    }

    @MainActor func testLatePlainTextGetsItsOwnMetadataGracePeriod() async throws {
        let fixture = SelectionFixture(); fixture.ax.isEditorInput = true
        fixture.onPause = { state in
            state.clipboard = .init(changeCount: state.clipboard.changeCount + 1, text: state.pauses < 5 ? nil : "Late selected text")
        }
        let text = try await SelectionReader.read(copyFallback: true, environment: fixture)
        XCTAssertEqual(text, "Late selected text"); XCTAssertEqual(fixture.pauses, 8)
        XCTAssertEqual(fixture.restores, 1)
    }

    @MainActor func testMalformedMetadataIsNotTreatedAsPlainTextOnlyCopy() async {
        for isEditor in [true, false] {
            let fixture = SelectionFixture(); fixture.ax.isEditorInput = isEditor
            var phases: [SelectionClipboardPhase] = []
            fixture.copiedCustomData["vscode-editor-data"] = Data(#"{"version":1,"isFromEmptySelection":"false"}"#.utf8)
            do {
                _ = try await SelectionReader.read(copyFallback: true, environment: fixture, onClipboardPhase: { phase in
                    phases.append(phase)
                    if phase == .ended { XCTAssertEqual(fixture.restores, 1) }
                })
                XCTFail("Invalid metadata must not be ignored")
            }
            catch { XCTAssertTrue(error.localizedDescription.contains("元数据无效")) }
            XCTAssertEqual(fixture.restores, 1)
            XCTAssertEqual(phases, [.began, .ended])
        }
    }

    @MainActor func testHoldingShortcutTooLongDoesNotTouchClipboard() async {
        let fixture = SelectionFixture(); fixture.heldForPauses = 101
        do { _ = try await SelectionReader.read(copyFallback: true, triggerKeyCode: 18, environment: fixture); XCTFail("Expected key-release timeout") }
        catch { XCTAssertTrue(error.localizedDescription.contains("松开")) }
        XCTAssertFalse(fixture.copySent); XCTAssertEqual(fixture.snapshots, 0)
    }

    @MainActor func testFocusChangesWhileWaitingForReleaseDoesNotTouchClipboard() async {
        let fixture = SelectionFixture(); fixture.heldForPauses = 3
        fixture.onPause = { state in state.frontmostPID = 43 }
        do { _ = try await SelectionReader.read(copyFallback: true, environment: fixture); XCTFail("Expected focus change") } catch {}
        XCTAssertFalse(fixture.copySent); XCTAssertEqual(fixture.snapshots, 0)
    }

    @MainActor func testCopyFailureRestoresClipboard() async {
        let fixture = SelectionFixture(); fixture.copyError = NSError(domain: "FixtureCopyError", code: 1)
        let original = fixture.storedClipboard
        var phases: [SelectionClipboardPhase] = []
        do {
            _ = try await SelectionReader.read(copyFallback: true, environment: fixture, onClipboardPhase: { phase in
                phases.append(phase)
                if phase == .ended {
                    XCTAssertEqual(fixture.restores, 1); XCTAssertEqual(fixture.storedClipboard, original)
                }
            })
            XCTFail("Expected copy failure")
        } catch {}
        XCTAssertEqual(fixture.storedClipboard, original); XCTAssertEqual(fixture.restores, 1)
        XCTAssertEqual(phases, [.began, .ended])
    }

    @MainActor func testOversizedCopiedTextIsRejectedAndClipboardRestored() async {
        let fixture = SelectionFixture(); fixture.copiedText = String(repeating: "中", count: 33_334)
        do { _ = try await SelectionReader.read(copyFallback: true, environment: fixture); XCTFail("Expected byte limit") }
        catch { XCTAssertTrue(error.localizedDescription.contains("100 KB")) }
        XCTAssertEqual(fixture.restores, 1)
    }

    @MainActor func testByteLimitAllowsExactly100000Bytes() async throws {
        let fixture = SelectionFixture(); fixture.ax.text = String(repeating: "a", count: 100_000)
        let text = try await SelectionReader.read(copyFallback: true, environment: fixture)
        XCTAssertEqual(text.utf8.count, 100_000); XCTAssertFalse(fixture.copySent)
    }

    @MainActor func testClipboardReadChangingMidSnapshotIsRetried() async throws {
        let fixture = SelectionFixture()
        fixture.onPause = { state in
            state.clipboard = .init(changeCount: state.clipboard.changeCount + 1,
                                   text: state.pauses == 1 ? "Stale partial read" : "Stable selection", isStable: state.pauses != 1)
        }
        let text = try await SelectionReader.read(copyFallback: true, environment: fixture)
        XCTAssertEqual(text, "Stable selection"); XCTAssertEqual(fixture.pauses, 2)
    }

    @MainActor func testPermissionDeniedAndOwnAppNeverTouchClipboard() async {
        for permissionDenied in [true, false] {
            let fixture = SelectionFixture()
            if permissionDenied { fixture.isTrusted = false } else { fixture.frontmostPID = fixture.ownPID }
            do { _ = try await SelectionReader.read(copyFallback: true, environment: fixture); XCTFail("Expected precondition rejection") } catch {}
            XCTAssertFalse(fixture.copySent); XCTAssertEqual(fixture.snapshots, 0)
        }
    }
}
