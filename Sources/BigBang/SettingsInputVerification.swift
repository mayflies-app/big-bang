import AppKit
import SwiftUI
import BigBangCore

/// Native IME client contract exercised against the actual settings window.
/// All persistence and login-item operations remain in memory.
@MainActor enum SettingsInputVerification {
    static func run(reportURL: URL, verifyHotkeys: () async -> [String: Bool]) async {
        if CommandLine.arguments.contains("--shortcut-labels-only") {
            let labels = await verifyShortcutLabels()
            let report: [String: Any] = ["passed": !labels.checks.isEmpty && labels.checks.values.allSatisfy { $0 },
                "checks": labels.checks, "observations": labels.observations, "fixtureErrors": [String](),
                "scope": "Real RecorderButton in an owned SettingsWindow; in-process native key events verify readable special-key labels, unchanged key codes and modifiers, cancellation and rejected input. No clipboard, global hotkeys, Keychain, settings writes or model calls."]
            do {
                try FileManager.default.createDirectory(at: reportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                    .write(to: reportURL, options: .atomic)
            } catch { fputs("Shortcut labels report: \(error.localizedDescription)\n", stderr) }
            NSApp.terminate(nil)
            return
        }
        let lifecycle = await FocusLifecycleVerification.run()
        if CommandLine.arguments.contains("--focus-lifecycle-only") {
            let report: [String: Any] = ["passed": !lifecycle.checks.isEmpty && lifecycle.checks.values.allSatisfy { $0 },
                "checks": lifecycle.checks, "observations": lifecycle.observations, "fixtureErrors": [String](),
                "scope": "Native shared editor lifecycle in SettingsWindow and StickyPanel; real window-deinit focus reentry, bounded nested run loop, queued cancellation, release and reattachment. No clipboard, hotkeys, Keychain, settings writes or model calls."]
            do {
                try FileManager.default.createDirectory(at: reportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                    .write(to: reportURL, options: .atomic)
            } catch { fputs("Focus lifecycle report: \(error.localizedDescription)\n", stderr) }
            NSApp.terminate(nil)
            return
        }
        let fixture = Fixture(reportDirectory: reportURL.deletingLastPathComponent())
        fixture.checks.merge(lifecycle.checks) { _, new in new }
        fixture.observations.append(contentsOf: lifecycle.observations)
        let labels = await verifyShortcutLabels()
        fixture.checks.merge(labels.checks) { _, new in new }
        fixture.observations.append(contentsOf: labels.observations)
        do { try await fixture.run() }
        catch {
            fixture.checks["fixture.targetAcquisition"] = false
            fixture.errors.append(String(describing: error))
        }
        fixture.checks.merge(await verifyHotkeys()) { _, new in new }
        let report: [String: Any] = [
            "passed": !fixture.checks.isEmpty && fixture.checks.values.allSatisfy { $0 },
            "checks": fixture.checks, "observations": fixture.observations, "fixtureErrors": fixture.errors,
            "scope": "Real SettingsView, NSHostingView, SettingsWindow and application menu; native key events for close, undo, redo and select-all, nested scroll wheel events for mouse and trackpad phases, plus NSTextInputClient marked-text sequences, focus and navigation; in-memory save sink and login items. Copy/cut/paste use synchronous native menu dispatch, preserving clipboard formats and checking for observed external writes. Temporary Control-Option-Shift-Command digit shortcuts exercise Carbon callbacks without replacing user shortcuts. No keychain writes, defaults writes or model calls. This does not automate an installed input-method candidate panel.",
            "environment": ["os": ProcessInfo.processInfo.operatingSystemVersionString,
                            "bundle": Bundle.main.bundleURL.path,
                            "postEventAccess": CGPreflightPostEventAccess(),
                            "keyboardDispatch": CGPreflightPostEventAccess() ? "system-event-posting" : "in-process-menu-and-window-events",
                            "clipboardKeyboardDispatch": "CGEvent-backed in-process native menu dispatch",
                            "fullKeyboardAccessEnabled": NSApp.isFullKeyboardAccessEnabled]
        ]
        do {
            try FileManager.default.createDirectory(at: reportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: reportURL, options: .atomic)
        } catch { fputs("Settings input report: \(error.localizedDescription)\n", stderr) }
        fixture.window.close()
        NSApp.terminate(nil)
    }

    private static func verifyShortcutLabels() async -> (checks: [String: Bool], observations: [[String: Any]]) {
        var checks: [String: Bool] = [:]
        var observations: [[String: Any]] = []
        let foreground = NSWorkspace.shared.frontmostApplication
        let window = SettingsWindow()
        let recorder = RecorderButton(frame: NSRect(x: 40, y: 40, width: 200, height: 32))
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 120))
        window.contentView?.addSubview(recorder)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        for _ in 0..<50 {
            if window.isKeyWindow { break }
            await pause(20)
        }
        checks["shortcutLabels.nativeRecorderOwnsKeyWindow"] = window.isKeyWindow && recorder.window === window
        defer {
            recorder.endRecording()
            window.close()
            foreground?.activate(options: [])
        }
        func send(_ characters: String, keyCode: UInt16,
                  modifiers: NSEvent.ModifierFlags = [.control, .option]) -> Bool {
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode) else { return false }
            NSApp.sendEvent(event)
            return true
        }
        let cases: [(name: String, keyCode: UInt16, characters: String, expected: String)] = [
            ("return", 36, "\r", "⏎"), ("tab", 48, "\t", "⇥"),
            ("delete", 51, "\u{7f}", "⌫"), ("space", 49, " ", "␣"),
            ("left", 123, "\u{f702}", "←"), ("right", 124, "\u{f703}", "→"),
            ("down", 125, "\u{f701}", "↓"), ("up", 126, "\u{f700}", "↑"),
            ("f1", 122, "\u{f704}", "F1"), ("f20", 90, "\u{f717}", "F20"),
            ("keypadEnter", 76, "\u{3}", "⌅"), ("forwardDelete", 117, "\u{f728}", "⌦"),
            ("ordinaryLetter", 40, "k", "K"), ("ordinaryDigit", 18, "1", "1"),
            ("emptyCharacterFallback", 10, "", "Key 10")
        ]
        for language in [AppLanguage.simplifiedChinese, .english] {
            recorder.language = language
            let prefix = "shortcutLabels.\(language.rawValue)."
            for item in cases {
                var recorded: [Shortcut] = []
                var changes: [Bool] = []
                recorder.title = "⌃⌥1"
                recorder.onRecord = { recorded.append($0) }
                recorder.onRecordingChange = { changes.append($0) }
                recorder.beginRecording()
                let began = window.firstResponder === recorder && changes == [true]
                let sent = send(item.characters, keyCode: item.keyCode)
                let expected = "⌃⌥" + item.expected
                checks[prefix + item.name + ".readableLabel"] = began && sent && recorded.count == 1 &&
                    recorded.first?.label == expected && recorder.title == expected
                checks[prefix + item.name + ".preservesKeyAndModifiers"] = recorded.first?.keyCode == UInt32(item.keyCode) &&
                    recorded.first?.modifiers == 6144 && changes == [true, false]
                observations.append(["phase": prefix + item.name, "expected": expected,
                    "actual": recorder.title, "recordedCount": recorded.count,
                    "keyCode": Int(recorded.first?.keyCode ?? 0), "modifiers": Int(recorded.first?.modifiers ?? 0)])
                recorder.endRecording()
            }
            var recorded: [Shortcut] = []
            var changes: [Bool] = []
            recorder.title = "⌃⌥K"
            recorder.onRecord = { recorded.append($0) }
            recorder.onRecordingChange = { changes.append($0) }
            recorder.beginRecording()
            let escaped = send("\u{1b}", keyCode: 53, modifiers: [])
            checks[prefix + "escapeCancelsWithoutChangingShortcut"] = escaped && recorded.isEmpty &&
                recorder.title == "⌃⌥K" && changes == [true, false] && window.isVisible
            changes.removeAll()
            recorder.beginRecording()
            let rejected = send("k", keyCode: 40, modifiers: [.shift])
            checks[prefix + "shiftAloneKeepsRecordingWithoutSaving"] = rejected && recorded.isEmpty && changes == [true] &&
                window.firstResponder === recorder && recorder.title == L10n.string("按下快捷键…", language: language)
            let accepted = send("k", keyCode: 40, modifiers: [.control, .option, .shift, .command])
            checks[prefix + "validInputAfterRejectionPreservesAllModifiers"] = accepted && recorded.count == 1 &&
                recorded.first == Shortcut(keyCode: 40, modifiers: 6912, label: "⌃⌥⇧⌘K") &&
                changes == [true, false]
            recorder.endRecording()
        }
        return (checks, observations)
    }

    @MainActor private final class Fixture: NSObject, NSWindowDelegate {
        let window = SettingsWindow()
        let reportDirectory: URL
        var persisted = Configuration(language: .simplifiedChinese)
        var saves: [Configuration] = []
        var checks: [String: Bool] = [:]
        var observations: [[String: Any]] = []
        var errors: [String] = []
        var recording = false
        var recordingChanges: [Bool] = []
        init(reportDirectory: URL) {
            self.reportDirectory = reportDirectory
            super.init()
        }
        var rejectsPresetSave = false
        lazy var editor = SettingsEditor(configuration: persisted, save: { [unowned self] configuration, key in
            guard key.isEmpty else { throw ValidationError("Unexpected credential write in IME fixture") }
            try configuration.validate()
            if rejectsPresetSave { throw ValidationError("Fixture rejected preset save") }
            persisted = configuration
            saves.append(configuration)
        }, deleteKey: {})

        func run() async throws {
            persisted.model = "fixture-model"
            persisted.presets[0].name = "已有名称"
            persisted.presets[0].prompt = "开头🙂保留\n末尾"
            window.contentView = GlassSurface.wrap(NSHostingView(rootView: SettingsView(editor: editor,
                demo: {}, onRecordingChange: { [weak self] value in
                    self?.recording = value
                    self?.recordingChanges.append(value)
                }, loginItems: .preview())), cornerRadius: 12)
            window.delegate = self
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            await pause(200)
            for _ in 0..<50 {
                if NSApp.isActive && window.isKeyWindow { break }
                await pause(20)
            }
            observations.append(["phase": "settings.initialActivation",
                "applicationIsActive": NSApp.isActive, "windowIsKey": window.isKeyWindow])
            checkMenuMappings()

            try await compose("model", identifier: "settings.model", baseline: "fixture-model", replacement: "中文模型",
                          current: { $0.model })
            _ = element("settings.section.presets")?.press()
            await pause(150)
            let id = editor.draft.presets[0].id
            let shortcutBeforeRecording = editor.draft.presets[0].shortcut
            func recorders(in view: NSView) -> [RecorderButton] {
                (view as? RecorderButton).map { [$0] } ?? view.subviews.flatMap(recorders)
            }
            let recorderCandidates = recorders(in: window.contentView!).filter { $0.title == shortcutBeforeRecording.label }
            guard recorderCandidates.count == 1, let recorder = recorderCandidates.first else {
                throw targetFailure("settings.preset.\(id).shortcut", "Expected one native recorder for the fixture shortcut")
            }
            observations.append(["phase": "recorder.initial",
                "applicationIsActive": NSApp.isActive, "windowIsKey": window.isKeyWindow,
                "recorderAttached": recorder.window === window])
            recorder.performClick(nil)
            await pause(50)
            let recordingStarted = recording && window.firstResponder === recorder
            await sendKey("\u{1b}", code: 53, modifiers: [])
            checks["escapeCancelsRecorderBeforeClosingSettings"] = recordingStarted && window.isVisible &&
                !recording && editor.draft.presets[0].shortcut == shortcutBeforeRecording
            await recorderWindowLifecycle(recorder, shortcut: shortcutBeforeRecording)
            await presetDeletionRecovery()
            await repeatedPresetAddition()
            try await compose("name", identifier: "settings.preset.\(id).name", baseline: "已有名称", replacement: "中文名称",
                          current: { $0.presets[0].name })
            try await compose("prompt", identifier: "settings.preset.\(id).prompt", baseline: "开头🙂保留\n末尾", replacement: "你好世界",
                          range: NSRange(location: 4, length: 2), current: { $0.presets[0].prompt })
            try await promptEditingBoundaries(identifier: "settings.preset.\(id).prompt")
            try await promptGeometryAndNavigation(id: id)
            try await markedFocusBoundary(id: id)

            // Confirmed ordinary input must still debounce-save without changing focus.
            if let text = try await focus("settings.preset.\(id).prompt") {
                let expected = text.string + "\n普通输入"
                text.insertText("\n普通输入", replacementRange: NSRange(location: text.string.utf16.count, length: 0))
                await pause(450)
                checks["ordinaryInputAutosaves"] = persisted.presets[0].prompt == expected && editor.error == nil
                capture("ordinaryInput.afterDebounce", text: text, current: { $0.presets[0].prompt })

                text.insertText("失焦确认", replacementRange: NSRange(location: text.string.utf16.count, length: 0))
                let focusExpected = text.string
                _ = try await focus("settings.preset.\(id).name")
                await pause(100)
                checks["confirmedInputFlushesOnFocusChange"] = persisted.presets[0].prompt == focusExpected
            } else { checks["ordinaryInputAutosaves"] = false }

            if let text = try await focus("settings.preset.\(id).prompt") {
                text.insertText("切页确认", replacementRange: NSRange(location: text.string.utf16.count, length: 0))
                let expected = text.string
                _ = element("settings.section.connection")?.press()
                await pause(120)
                checks["confirmedInputFlushesOnNavigation"] = persisted.presets[0].prompt == expected
            } else { checks["confirmedInputFlushesOnNavigation"] = false }

            // Invalid committed input preserves the last valid value, then a valid
            // native edit must recover without moving focus or dropping characters.
            if let text = try await focus("settings.model") {
                let previous = persisted.model
                text.insertText("", replacementRange: NSRange(location: 0, length: text.string.utf16.count))
                await pause(450)
                checks["invalidInputRetainsLastValidSave"] = editor.error != nil && persisted.model == previous
                capture("invalidInput", text: text, current: { $0.model })
                text.insertText("恢复🙂模型", replacementRange: NSRange(location: 0, length: text.string.utf16.count))
                await pause(450)
                checks["validInputRecoversAfterError"] = editor.error == nil && persisted.model == "恢复🙂模型" &&
                    text.string == "恢复🙂模型" && window.firstResponder === text
                capture("errorRecovery", text: text, current: { $0.model })
            } else { checks["invalidInputRetainsLastValidSave"] = false; checks["validInputRecoversAfterError"] = false }

            _ = element("settings.section.presets")?.press()
            await pause(150)
            if let text = try await focus("settings.preset.\(id).prompt") {
                // External committed changes should be visible without replacing
                // the native first responder or losing a valid existing selection.
                let selected = NSRange(location: 0, length: 2)
                text.setSelectedRange(selected)
                let external = editor.draft.presets[0].prompt + "\n外部同步"
                editor.draft.presets[0].prompt = external
                await pause(450)
                checks["externalCommittedUpdatePreservesSelectionAndFocus"] = text.string == external &&
                    text.selectedRange() == selected && window.firstResponder === text && persisted.presets[0].prompt == external
                capture("externalCommittedUpdate", text: text, current: { $0.presets[0].prompt })

                let position = text.string.utf16.count
                text.setMarkedText("guanbi", selectedRange: NSRange(location: 6, length: 0),
                                   replacementRange: NSRange(location: position, length: 0))
                text.insertText("关闭确认", replacementRange: NSRange(location: NSNotFound, length: 0))
                let expected = external + "关闭确认"
                // Close before the debounce expires. The fixture uses the same
                // windowWillClose -> flush lifecycle as the production delegate.
                await sendKey("w", code: 13, modifiers: .command)
                checks["confirmedInputFlushesOnImmediateClose"] = editor.draft.presets[0].prompt == expected &&
                    persisted.presets[0].prompt == expected && !window.isVisible
                checks["commandWClosesWithFocusedEditor"] = !window.isVisible
                capture("immediateClose", text: text, current: { $0.presets[0].prompt })
                if window.isVisible { window.close() }

                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                if let closingText = try await focus("settings.preset.\(id).prompt") {
                    let beforeClose = persisted.presets[0].prompt
                    closingText.setMarkedText("weiqueren", selectedRange: NSRange(location: 9, length: 0),
                        replacementRange: NSRange(location: closingText.string.utf16.count, length: 0))
                    await pause(450)
                    checks["markedTextIsNotSavedBeforeClose"] = persisted.presets[0].prompt == beforeClose
                    window.close()
                    await pause(80)
                    let actual = closingText.hasMarkedText() ? beforeClose : closingText.string
                    checks["markedCloseMatchesNativeCompletionState"] = editor.draft.presets[0].prompt == actual &&
                        persisted.presets[0].prompt == actual
                    capture("markedClose", text: closingText, current: { $0.presets[0].prompt })
                } else { checks["markedCloseMatchesNativeCompletionState"] = false }
            } else {
                checks["externalCommittedUpdatePreservesSelectionAndFocus"] = false
                checks["confirmedInputFlushesOnImmediateClose"] = false
            }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            await pause(100)
            window.makeFirstResponder(window)
            await sendKey("W", code: 13, modifiers: [.command, .shift])
            checks["modifiedCloseDoesNotCloseSettings"] = window.isVisible
            await sendKey("w", code: 13, modifiers: .command)
            checks["commandWClosesWithoutTextFocus"] = !window.isVisible
            window.makeKeyAndOrderFront(nil)
            await pause(100)
            checks["settingsReopensAfterCommandW"] = window.isVisible && window.isKeyWindow
            window.makeFirstResponder(window)
            await sendKey("\u{1b}", code: 53, modifiers: [])
            checks["escapeClosesIdleSettings"] = !window.isVisible
            let note = StickyWindow(preset: persisted.presets[0], source: "isolated shortcut fixture", offset: 0)
            note.model.output = "No model call"
            note.showWindow(nil)
            note.window?.makeKeyAndOrderFront(nil)
            await pause(100)
            if let panel = note.window {
                await sendKey("W", code: 13, modifiers: [.command, .shift], to: panel)
                checks["modifiedCloseDoesNotCloseNote"] = panel.isVisible
                await sendKey("w", code: 13, modifiers: .command, to: panel)
                checks["commandWClosesFocusedNote"] = !panel.isVisible
                panel.close()
            }
        }

        func presetDeletionRecovery() async {
            let original = editor.draft
            var customized = original
            customized.presets[1].name = "误删恢复🙂"
            customized.presets[1].prompt = "第一行：保留自定义指令。\n第二行：恢复完整内容🙂。"
            customized.presets[1].shortcut = .init(keyCode: 40, modifiers: 6400, label: "⌃⌥⌘K")
            let deleted = customized.presets[1]
            editor.draft = customized
            editor.flush()
            await pause(120)
            rejectsPresetSave = true
            let failedDeletePressed = element("settings.preset.\(deleted.id).delete")?.press() == true
            await pause(120)
            checks["nativeDeleteSaveFailureKeepsPresetAndNoNotice"] = failedDeletePressed &&
                editor.draft == customized && persisted == customized && editor.error != nil &&
                element("settings.preset.deleted.notice") == nil
            rejectsPresetSave = false
            editor.flush()
            let pressedDelete = element("settings.preset.\(deleted.id).delete")?.press() == true
            await pause(120)
            checks["nativePresetDeletionShowsUndoNotice"] = pressedDelete &&
                !editor.draft.presets.contains(where: { $0.id == deleted.id }) &&
                !persisted.presets.contains(where: { $0.id == deleted.id }) &&
                element("settings.preset.deleted.notice") != nil && element("settings.preset.undoDelete") != nil
            let afterDeletion = editor.draft
            let noticeBeforeScroll = element("settings.preset.deleted.notice")?.frame ?? .zero
            var pageScrollDistance: CGFloat = 0
            if let last = editor.draft.presets.last,
               let target = try? nativeTarget("settings.preset.\(last.id).name"),
               let scroll = target.view.enclosingScrollView, let document = scroll.documentView {
                let previousOffset = scroll.contentView.bounds.minY
                scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, document.bounds.maxY - scroll.contentView.bounds.height)))
                scroll.reflectScrolledClipView(scroll.contentView)
                await pause(120)
                pageScrollDistance = abs(scroll.contentView.bounds.minY - previousOffset)
            }
            let noticeAfterScroll = element("settings.preset.deleted.notice")?.frame ?? .zero
            checks["presetDeletedNoticeRemainsVisibleOutsidePageScroll"] = pageScrollDistance > 30 && noticeBeforeScroll.height > 0 &&
                noticeAfterScroll.height > 0 && window.frame.contains(noticeAfterScroll) &&
                abs(noticeBeforeScroll.minY - noticeAfterScroll.minY) < 2
            let chineseNotice = element("settings.preset.deleted.notice")?.text ?? ""
            checks["deletedPresetChinesePreviewSaved"] = snapshot("preset-deleted-zh.png")
            _ = element("settings.section.general")?.press()
            await pause(80)
            _ = element("settings.language.en")?.press()
            await pause(80)
            _ = element("settings.section.presets")?.press()
            await pause(120)
            let englishNotice = element("settings.preset.deleted.notice")?.text ?? ""
            checks["deletedPresetEnglishPreviewSaved"] = snapshot("preset-deleted-en.png")
            checks["deletedPresetNoticeChangesLanguageAndKeepsCustomName"] = !chineseNotice.isEmpty &&
                englishNotice != chineseNotice && englishNotice.contains(deleted.name) && chineseNotice.contains(deleted.name)
            _ = element("settings.section.general")?.press()
            await pause(80)
            _ = element("settings.language.zh-Hans")?.press()
            await pause(80)
            _ = element("settings.section.presets")?.press()
            await pause(120)
            checks["deletedPresetNoticeReturnsToOriginalLanguage"] =
                element("settings.preset.deleted.notice")?.text == chineseNotice && editor.draft == afterDeletion
            rejectsPresetSave = true
            let failedUndoPressed = element("settings.preset.undoDelete")?.press() == true
            await pause(120)
            checks["nativeUndoSaveFailureKeepsDeletedStateAndRetry"] = failedUndoPressed &&
                editor.draft == afterDeletion && persisted == afterDeletion && editor.error != nil &&
                element("settings.preset.deleted.notice") != nil && element("settings.preset.undoDelete") != nil
            rejectsPresetSave = false
            let pressedUndo = element("settings.preset.undoDelete")?.press() == true
            await pause(300)
            checks["nativeUndoDeleteRestoresCompletePresetAndOrder"] = pressedUndo &&
                editor.draft == customized && persisted == customized && editor.error == nil
            let restoredNameID = "settings.preset.\(deleted.id).name"
            let restoredFrame = element(restoredNameID)?.frame ?? .zero
            checks["undoDeleteScrollsToRestoredNameAndFocusesIt"] = pressedUndo && restoredFrame.height > 0 &&
                window.frame.contains(restoredFrame) && (try? focusedEditor(restoredNameID))?.string == deleted.name
            checks["successfulUndoRemovesDeletedNotice"] = pressedUndo && element("settings.preset.deleted.notice") == nil
            observations.append(["phase": "presetDeletionRecovery", "deletedID": deleted.id.uuidString,
                "deletePressed": pressedDelete, "undoPressed": pressedUndo,
                "draftCount": editor.draft.presets.count, "persistedCount": persisted.presets.count,
                "completePresetRestored": editor.draft.presets.contains(deleted),
                "chineseNotice": chineseNotice, "englishNotice": englishNotice,
                "noticeFrameBeforeScroll": NSStringFromRect(noticeBeforeScroll),
                "noticeFrameAfterScroll": NSStringFromRect(noticeAfterScroll),
                "pageScrollDistance": pageScrollDistance,
                "restoredNameFrame": NSStringFromRect(restoredFrame)])
            _ = element("settings.preset.\(deleted.id).delete")?.press()
            await pause(120)
            let beforeDismiss = editor.draft
            let dismissPressed = element("settings.preset.dismissDeleted")?.press() == true
            await pause(80)
            checks["dismissingDeletedNoticePreservesDeletion"] = dismissPressed &&
                element("settings.preset.deleted.notice") == nil && element("settings.preset.undoDelete") == nil &&
                editor.draft == beforeDismiss && persisted == beforeDismiss
            editor.draft = original
            editor.flush()
            await pause(120)
            let firstDeleted = original.presets[0]
            let latestDeleted = original.presets[2]
            _ = element("settings.preset.\(firstDeleted.id).delete")?.press()
            await pause(120)
            _ = element("settings.preset.\(latestDeleted.id).delete")?.press()
            await pause(120)
            let latestNotice = element("settings.preset.deleted.notice")?.text ?? ""
            let undoLatest = element("settings.preset.undoDelete")?.press() == true
            await pause(200)
            var latestExpected = original
            latestExpected.presets.removeAll { $0.id == firstDeleted.id }
            checks["successivePresetDeletionsOfferOnlyLatestUndo"] = undoLatest && latestNotice.contains(latestDeleted.name) &&
                editor.draft == latestExpected && persisted == latestExpected &&
                element("settings.preset.undoDelete") == nil
            _ = element("settings.preset.dismissDeleted")?.press()
            editor.draft = original
            editor.flush()
            window.makeFirstResponder(window)
            await pause(120)
        }

        func repeatedPresetAddition() async {
            let original = editor.draft
            var savedEveryAddition = true
            var additionObservations: [[String: Any]] = []
            for attempt in 1...6 {
                let pressed = element("settings.preset.add")?.press() == true
                await pause(100)
                let unique = Set(editor.draft.presets.map { $0.shortcut.identity }).count == editor.draft.presets.count
                savedEveryAddition = savedEveryAddition && pressed && unique && editor.draft == persisted &&
                    editor.error == nil && editor.draft.presets.count == original.presets.count + attempt
                additionObservations.append(["attempt": attempt, "pressed": pressed,
                    "draftCount": editor.draft.presets.count, "persistedCount": persisted.presets.count,
                    "uniqueShortcuts": unique, "error": editor.error ?? ""])
            }
            checks["sixNativePresetAdditionsPersistWithoutShortcutConflicts"] = savedEveryAddition
            observations.append(["phase": "repeatedPresetAddition", "attempts": additionObservations])
            _ = element("settings.preset.dismissDeleted")?.press()
            var occupied = original
            let digitCodes: [UInt32] = [18, 19, 20, 21, 23, 22, 26, 28, 25, 29]
            occupied.presets = [UInt32(6144), UInt32(6656)].flatMap { modifiers in
                digitCodes.enumerated().map { index, code in
                    Preset(name: "占用 \(modifiers)-\(index)", prompt: "保留占用组合。",
                        shortcut: .init(keyCode: code, modifiers: modifiers, label: "占用 \(index)"))
                }
            }
            editor.draft = occupied
            editor.flush()
            await pause(120)
            let exhaustedPressed = element("settings.preset.add")?.press() == true
            await pause(120)
            checks["nativeAddWhenAllTwentyShortcutsUsedKeepsConfiguration"] = exhaustedPressed &&
                editor.draft == occupied && persisted == occupied && editor.error != nil
            editor.draft = original
            editor.flush()
            window.makeFirstResponder(window)
            await pause(120)
            _ = element("settings.section.connection")?.press()
            await pause(80)
            _ = element("settings.section.presets")?.press()
            await pause(120)
        }

        func snapshot(_ name: String) -> Bool {
            guard let view = window.contentView?.superview,
                  let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let data = bitmap.representation(using: .png, properties: [:]) else { return false }
            do {
                try FileManager.default.createDirectory(at: reportDirectory, withIntermediateDirectories: true)
                try data.write(to: reportDirectory.appendingPathComponent(name), options: .atomic)
                return true
            } catch { return false }
        }

        func recorderWindowLifecycle(_ recorder: RecorderButton, shortcut: Shortcut) async {
            func reopenSettings(_ phase: String) async {
                // Match AppDelegate.showSettings: reopening an accessory app's
                // only window also requests application activation.
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                await pause(80)
                for _ in 0..<50 {
                    if NSApp.isActive && window.isKeyWindow { break }
                    await pause(20)
                }
                observations.append(["phase": "recorder.reopen.\(phase)",
                    "applicationIsActive": NSApp.isActive, "windowIsKey": window.isKeyWindow,
                    "recorderAttached": recorder.window === window])
            }
            // Closing a retained settings window does not destroy its native controls
            // or necessarily resign its first responder. Cancellation must follow
            // the window lifecycle rather than representable destruction.
            let closeStart = recordingChanges.count
            recorder.performClick(nil)
            let closeStarted = recording && window.firstResponder === recorder
            window.performClose(nil)
            await pause(80)
            checks["closingSettingsCancelsRecorderExactlyOnce"] = closeStarted && !window.isVisible && !recording &&
                recorder.title == shortcut.label && Array(recordingChanges.dropFirst(closeStart)) == [true, false] &&
                editor.draft.presets[0].shortcut == shortcut
            observations.append(["phase": "recorder.close", "recording": recording,
                "title": recorder.title, "callbackChanges": Array(recordingChanges.dropFirst(closeStart)),
                "retainedFirstResponder": window.firstResponder === recorder])
            recorder.endRecording() // Keep later checks independent on a failing baseline.
            await reopenSettings("afterClose")

            let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 100),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            other.isReleasedWhenClosed = false
            let field = NSTextField(string: "")
            field.frame = NSRect(x: 20, y: 30, width: 200, height: 24)
            other.contentView?.addSubview(field)
            defer { other.close() }
            let resignStart = recordingChanges.count
            recorder.performClick(nil)
            let resignStarted = recording && window.firstResponder === recorder
            other.makeKeyAndOrderFront(nil)
            other.makeFirstResponder(field)
            await pause(80)
            checks["losingKeyWindowCancelsRecorderExactlyOnce"] = resignStarted && other.isKeyWindow && !window.isKeyWindow &&
                !recording && recorder.title == shortcut.label &&
                Array(recordingChanges.dropFirst(resignStart)) == [true, false]
            if let event = NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: [.control, .option], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: other.windowNumber, context: nil, characters: "k",
                charactersIgnoringModifiers: "k", isARepeat: false, keyCode: 40) {
                NSApp.sendEvent(event)
            }
            await pause(50)
            checks["otherWindowKeyboardDoesNotChangeShortcut"] = other.isKeyWindow &&
                editor.draft.presets[0].shortcut == shortcut && !recording
            observations.append(["phase": "recorder.resignKey", "recording": recording,
                "otherWindowIsKey": other.isKeyWindow, "title": recorder.title,
                "callbackChanges": Array(recordingChanges.dropFirst(resignStart))])
            recorder.endRecording()
            editor.draft.presets[0].shortcut = shortcut
            if CGPreflightPostEventAccess(), let mainScreen = NSScreen.screens.first {
                // Use a posted mouse event to exercise AppKit's first click on an
                // inactive window, including activation before the action fires.
                window.orderFront(nil)
                let frame = window.convertToScreen(recorder.convert(recorder.bounds, to: nil))
                let location = CGPoint(x: frame.midX, y: mainScreen.frame.maxY - frame.midY)
                let clickStart = recordingChanges.count
                let startsInactive = !window.isKeyWindow && other.isKeyWindow
                let source = CGEventSource(stateID: .privateState)
                CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: location, mouseButton: .left)?.post(tap: .cghidEventTap)
                CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: location, mouseButton: .left)?.post(tap: .cghidEventTap)
                await pause(150)
                checks["inactiveSettingsFirstMouseClickStartsRecording"] = startsInactive && window.isKeyWindow &&
                    recording && window.firstResponder === recorder && Array(recordingChanges.dropFirst(clickStart)) == [true]
                other.makeKeyAndOrderFront(nil)
                await pause(80)
                checks["firstMouseClickRecordingCancelsOnWindowChange"] = !recording && other.isKeyWindow &&
                    recorder.title == shortcut.label && Array(recordingChanges.dropFirst(clickStart)) == [true, false] &&
                    editor.draft.presets[0].shortcut == shortcut
                recorder.endRecording()
            } else {
                observations.append(["phase": "recorder.inactiveWindowMouseClick", "executed": false,
                    "reason": "System mouse-event posting is not available; no permission requested."])
            }
            other.close()
            await reopenSettings("afterOtherWindow")
            let reopenStart = recordingChanges.count
            recorder.performClick(nil)
            let reopened = recording && window.firstResponder === recorder
            await sendKey("\u{1b}", code: 53, modifiers: [])
            checks["reopenedSettingsCanRecordAndCancelAgain"] = reopened && !recording && window.isVisible &&
                recorder.title == shortcut.label && Array(recordingChanges.dropFirst(reopenStart)) == [true, false] &&
                editor.draft.presets[0].shortcut == shortcut
        }

        func windowWillClose(_ notification: Notification) { editor.flush() }

        func sendKey(_ characters: String, code: UInt16, modifiers: NSEvent.ModifierFlags, to target: NSWindow? = nil) async {
            guard NSApp.keyWindow === (target ?? window),
                  let keyboard = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true) else { return }
            // Preserve keyboard-layout metadata used by AppKit's menu matcher.
            // A hand-built NSEvent can reject valid Shift-letter equivalents.
            keyboard.flags = CGEventFlags(rawValue: UInt64(modifiers.rawValue))
            if CGPreflightPostEventAccess() {
                keyboard.post(tap: .cghidEventTap)
                let release = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false)
                release?.flags = []
                release?.post(tap: .cghidEventTap)
                await pause(60)
            } else if modifiers.contains(.command), let event = NSEvent(cgEvent: keyboard) {
                _ = NSApp.mainMenu?.performKeyEquivalent(with: event)
            } else if let event = NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: (target ?? window).windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code) {
                NSApp.sendEvent(event)
            }
        }

        func checkMenuMappings() {
            func entries(_ menu: NSMenu) -> [NSMenuItem] {
                menu.items.flatMap { item in [item] + (item.submenu.map(entries) ?? []) }
            }
            let items = NSApp.mainMenu.map(entries) ?? []
            for (name, key, flags, action) in [
                ("settings", ",", NSEvent.ModifierFlags.command, "showSettings"),
                ("close", "w", .command, "performClose:"),
                ("quit", "q", .command, "terminate:"),
                ("undo", "z", .command, "undo:"),
                ("redo", "Z", [.command, .shift], "redo:"),
                ("cut", "x", .command, "cutFromMenu:"),
                ("copy", "c", .command, "copyFromMenu:"),
                ("paste", "v", .command, "pasteFromMenu:"),
                ("selectAll", "a", .command, "selectAll:")
            ] {
                let matches = items.filter { $0.keyEquivalent == key && $0.keyEquivalentModifierMask == flags }
                checks["menu.\(name).mappedOnce"] = matches.count == 1 && matches.first?.action == NSSelectorFromString(action)
            }
        }

        func markedFocusBoundary(id: UUID) async throws {
            guard let text = try await focus("settings.preset.\(id).prompt") else {
                checks["markedFocusMatchesNativeCompletionState"] = false; return
            }
            let baseline = persisted.presets[0].prompt
            text.setMarkedText("shijiao", selectedRange: NSRange(location: 7, length: 0),
                               replacementRange: NSRange(location: text.string.utf16.count, length: 0))
            await pause(450)
            checks["markedTextIsNotSavedBeforeFocusChange"] = persisted.presets[0].prompt == baseline
            _ = try await focus("settings.preset.\(id).name")
            await pause(450)
            let actual = text.hasMarkedText() ? baseline : text.string
            checks["markedFocusMatchesNativeCompletionState"] = editor.draft.presets[0].prompt == actual &&
                persisted.presets[0].prompt == actual
            capture("markedFocusChange", text: text, current: { $0.presets[0].prompt })
            // If native focus movement keeps an active composition, cancel it before
            // continuing. Do not assume that losing focus commits provisional pinyin.
            if text.hasMarkedText() {
                let identifier = "settings.preset.\(id).prompt"
                guard let refocused = try await focus(identifier), refocused === text else {
                    throw targetFailure(identifier, "Prompt editor changed before cancelling composition")
                }
                text.setMarkedText("", selectedRange: NSRange(location: 0, length: 0),
                                   replacementRange: NSRange(location: NSNotFound, length: 0))
                text.unmarkText()
                await pause(450)
            }
        }

        func promptGeometryAndNavigation(id: UUID) async throws {
            let identifier = "settings.preset.\(id).prompt"
            guard let text = try await focus(identifier), let scroll = text.enclosingScrollView,
                  let document = scroll.documentView else { checks["longPromptNativeScrollAvailable"] = false; return }
            checks["longPromptNativeScrollAvailable"] = true
            // AppKit Tab events exercise SwiftUI's virtual focus system as well as
            // native editors, preserving the user's keyboard access preference.
            let baseline = text.string
            let baselineName = editor.draft.presets[0].name
            let nameIdentifier = "settings.preset.\(id).name"
            _ = try await focus(nameIdentifier)
            let startsFromName = try focusedEditor(nameIdentifier)?.string == editor.draft.presets[0].name
            checks["nativeKeyViewNavigationStartsFromName"] = startsFromName
            var forwardHistory = [navigationResponder(step: 0, target: text)]
            var forwardSteps = 0
            while startsFromName && window.firstResponder !== text && forwardSteps < 20 {
                sendTab(backwards: false)
                await pause(20)
                forwardSteps += 1
                forwardHistory.append(navigationResponder(step: forwardSteps, target: text))
            }
            let forwardReachedPrompt = startsFromName && window.firstResponder === text
            var backwardHistory = [navigationResponder(step: 0, target: text)]
            var backwardSteps = 0
            var returnedToName = false
            while forwardReachedPrompt && !returnedToName && backwardSteps < 20 {
                sendTab(backwards: true)
                await pause(20)
                backwardSteps += 1
                backwardHistory.append(navigationResponder(step: backwardSteps, target: text))
                returnedToName = try focusedEditor(nameIdentifier)?.string == editor.draft.presets[0].name
            }
            checks["keyboardEventsPreserveCommittedText"] = text.string == baseline &&
                editor.draft.presets[0].prompt == baseline && persisted.presets[0].prompt == baseline &&
                editor.draft.presets[0].name == baselineName && persisted.presets[0].name == baselineName
            observations.append(["phase": "nativeKeyViewNavigation", "forwardSteps": forwardSteps,
                "backwardSteps": backwardSteps, "usesSystemTabEvent": true, "startsFromName": startsFromName,
                "forwardReachedPrompt": forwardReachedPrompt, "backwardReturnedToName": returnedToName,
                "backwardExecuted": backwardSteps > 0,
                "forwardHistory": forwardHistory, "backwardHistory": backwardHistory])
            guard let refocused = try await focus(identifier), refocused === text else {
                throw targetFailure(identifier, "Prompt editor changed during key-view navigation")
            }
            let long = (1...60).map { "第 \($0) 行：较长提示词🙂，逐行检查实际滚动和换行。" }.joined(separator: "\n")
            text.insertText(long, replacementRange: NSRange(location: 0, length: text.string.utf16.count))
            await pause(450)
            checks["longPromptOverflowsNativeViewport"] = document.bounds.height > scroll.contentView.bounds.height + 100
            let wheel = await SettingsScrollVerification.run(text: text)
            checks.merge(wheel.checks) { _, new in new }
            observations.append(contentsOf: wheel.observations)
            text.setSelectedRange(NSRange(location: text.string.utf16.count, length: 0))
            text.scrollRangeToVisible(text.selectedRange())
            await pause(100)
            checks["longPromptCanScrollToFocusedCaret"] = scroll.documentVisibleRect.maxY >= document.bounds.maxY - 25 &&
                window.firstResponder === text
            let offset = scroll.contentView.bounds.origin.y
            editor.error = nil
            await pause(80)
            checks["statusNotificationPreservesReadingOffset"] = abs(scroll.contentView.bounds.origin.y - offset) < 2
            let width = text.bounds.width
            var frame = window.frame
            frame.size.width += 120
            window.setFrame(frame, display: true)
            await pause(150)
            checks["resizedPromptTracksViewportWidth"] = text.bounds.width > width + 60 &&
                abs(text.bounds.width - scroll.contentView.bounds.width) < 2
            text.insertText("末行编辑", replacementRange: NSRange(location: text.string.utf16.count, length: 0))
            await pause(450)
            checks["resizedLongPromptLastLineRemainsEditable"] = text.string == long + "末行编辑" &&
                persisted.presets[0].prompt == text.string && window.firstResponder === text
            capture("longPrompt.afterResizeAndEdit", text: text, current: { $0.presets[0].prompt })
            observations.append(["phase": "longPrompt.geometry", "documentHeight": document.bounds.height,
                "viewportHeight": scroll.contentView.bounds.height, "textWidth": text.bounds.width,
                "viewportWidth": scroll.contentView.bounds.width, "offset": scroll.contentView.bounds.origin.y])
        }

        func sendTab(backwards: Bool) {
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: backwards ? .shift : [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: backwards ? "\u{19}" : "\t",
                charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48) else { return }
            NSApp.sendEvent(event)
        }

        func navigationResponder(step: Int, target: NSTextView) -> [String: Any] {
            guard let responder = window.firstResponder else {
                return ["step": step, "type": "none", "accessibilityID": "", "isOriginalPrompt": false,
                        "nativeTextPreview": "", "nativeSelection": [String: Int](), "windowIsKey": window.isKeyWindow]
            }
            let identifier = NSSelectorFromString("accessibilityIdentifier")
            let value = responder.responds(to: identifier) ?
                responder.perform(identifier)?.takeUnretainedValue() as? String : nil
            return ["step": step, "type": String(reflecting: type(of: responder)),
                    "accessibilityID": value ?? "", "isOriginalPrompt": responder === target,
                    "nativeTextPreview": String(((responder as? NSTextView)?.string ?? "").prefix(120)),
                    "nativeSelection": (responder as? NSTextView).map { rangeJSON($0.selectedRange()) } ?? [:],
                    "nativeHasMarkedText": (responder as? NSTextView)?.hasMarkedText() ?? false,
                    "windowIsKey": window.isKeyWindow]
        }

        func promptEditingBoundaries(identifier: String) async throws {
            guard let text = try await focus(identifier) else { checks["promptAdditionalBoundariesAvailable"] = false; return }
            let baseline = text.string
            let end = baseline.utf16.count
            // NSTextInputClient permits finalizing marked text by unmarkText alone;
            // no subsequent character edit should be needed to persist it.
            text.setMarkedText("直接确认", selectedRange: NSRange(location: 4, length: 0),
                               replacementRange: NSRange(location: end, length: 0))
            text.unmarkText()
            await pause(450)
            let committed = baseline + "直接确认"
            checks["unmarkWithoutFurtherInputAutosaves"] = !text.hasMarkedText() && text.string == committed &&
                editor.draft.presets[0].prompt == committed && persisted.presets[0].prompt == committed
            capture("unmarkWithoutFurtherInput", text: text, current: { $0.presets[0].prompt })

            // Cancel provisional text by replacing the current marked range with
            // empty text, the native input client's deletion contract.
            text.setMarkedText("quxiao", selectedRange: NSRange(location: 6, length: 0),
                               replacementRange: NSRange(location: text.string.utf16.count, length: 0))
            text.setMarkedText("", selectedRange: NSRange(location: 0, length: 0),
                               replacementRange: NSRange(location: NSNotFound, length: 0))
            text.unmarkText()
            await pause(450)
            checks["cancelledCompositionLeavesNoPinyin"] = !text.hasMarkedText() && text.string == committed &&
                editor.draft.presets[0].prompt == committed && persisted.presets[0].prompt == committed
            capture("cancelledComposition", text: text, current: { $0.presets[0].prompt })

            text.undoManager?.removeAllActions()
            text.breakUndoCoalescing()
            text.insertText("撤销片段", replacementRange: NSRange(location: text.string.utf16.count, length: 0))
            text.breakUndoCoalescing()
            await pause(450)
            let edited = committed + "撤销片段"
            checks["ordinaryEditCreatesUndo"] = text.undoManager?.canUndo == true && persisted.presets[0].prompt == edited
            observations.append(["phase": "undoRouting", "target": NSApp.target(forAction: Selector(("undo:"))).map { String(reflecting: type(of: $0)) } ?? "none",
                "responder": String(reflecting: type(of: window.firstResponder!)), "windowIsKey": window.isKeyWindow,
                "applicationIsActive": NSApp.isActive, "undoGroupingLevel": text.undoManager?.groupingLevel ?? -1])
            await sendKey("z", code: 6, modifiers: .command)
            await pause(450)
            checks["undoUpdatesDraftAndAutosave"] = text.string == committed && editor.draft.presets[0].prompt == committed &&
                persisted.presets[0].prompt == committed
            capture("undo", text: text, current: { $0.presets[0].prompt })
            let redoMenu = NSApp.mainMenu?.items.last?.submenu
            redoMenu?.update()
            observations.append(["phase": "redoRouting", "canRedo": text.undoManager?.canRedo ?? false,
                "target": NSApp.target(forAction: Selector(("redo:"))).map { String(reflecting: type(of: $0)) } ?? "none",
                "menuEnabled": redoMenu?.items.first(where: { $0.action == Selector(("redo:")) })?.isEnabled ?? false,
                "nativeValidation": redoMenu?.items.first(where: { $0.action == Selector(("redo:")) }).map { text.validateMenuItem($0) } ?? false,
                "genericValidation": redoMenu?.items.first(where: { $0.action == Selector(("redo:")) }).map { text.validateUserInterfaceItem($0) } ?? false])
            await sendKey("Z", code: 6, modifiers: [.command, .shift])
            await pause(450)
            checks["redoUpdatesDraftAndAutosave"] = checks["undoUpdatesDraftAndAutosave"] == true && text.string == edited && editor.draft.presets[0].prompt == edited &&
                persisted.presets[0].prompt == edited
            capture("redo", text: text, current: { $0.presets[0].prompt })
            await sendKey("a", code: 0, modifiers: .command)
            checks["commandASelectsPromptText"] = text.selectedRange() == NSRange(location: 0, length: text.string.utf16.count)
            try await checkClipboardShortcuts(text)
        }

        func checkClipboardShortcuts(_ text: NSTextView) async throws {
            let board = NSPasteboard.general
            let snapshotChangeCount = board.changeCount
            let saved = try (board.pasteboardItems ?? []).map { item in
                try Dictionary(uniqueKeysWithValues: item.types.map { type in
                    guard let data = item.data(forType: type) else {
                        throw targetFailure("clipboard", "Cannot preserve every clipboard format")
                    }
                    return (type, data)
                })
            }
            guard board.changeCount == snapshotChangeCount else {
                throw targetFailure("clipboard", "Clipboard changed while preserving its formats")
            }
            var ownedChangeCount = snapshotChangeCount
            defer {
                // If another application wrote meanwhile, preserve its new clipboard.
                if board.changeCount == ownedChangeCount {
                    let restored = saved.map { values in
                        let item = NSPasteboardItem()
                        for (type, data) in values { item.setData(data, forType: type) }
                        return item
                    }
                    board.clearContents()
                    let written = restored.isEmpty || board.writeObjects(restored)
                    let actual = (board.pasteboardItems ?? []).map { item in
                        Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
                            item.data(forType: type).map { (type, $0) }
                        })
                    }
                    checks["clipboardFormatsRestoredAfterEditing"] = written && actual == saved
                } else { checks["clipboardFormatsRestoredAfterEditing"] = false }
            }
            func dispatch(_ code: UInt16) throws {
                guard board.changeCount == ownedChangeCount else {
                    throw targetFailure("clipboard", "Another application changed the clipboard")
                }
                guard let keyboard = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true) else {
                    throw targetFailure("clipboard", "Cannot create keyboard event")
                }
                keyboard.flags = .maskCommand
                guard let event = NSEvent(cgEvent: keyboard) else {
                    throw targetFailure("clipboard", "Cannot bridge keyboard event")
                }
                // Synchronous dispatch lets cleanup track this action's writes even
                // when its behavior assertion fails; no asynchronous clipboard ownership guess.
                let handled = NSApp.mainMenu?.performKeyEquivalent(with: event) == true
                ownedChangeCount = board.changeCount
                guard handled else { throw targetFailure("clipboard", "Menu did not handle shortcut") }
            }
            let expected = text.string
            try dispatch(8)
            checks["commandCCopiesPromptText"] = board.string(forType: .string) == expected && text.string == expected
            guard checks["commandCCopiesPromptText"] == true else { return }
            try dispatch(7)
            checks["commandXCutsPromptText"] = text.string.isEmpty && board.string(forType: .string) == expected
            guard checks["commandXCutsPromptText"] == true else { return }
            try dispatch(9)
            await pause(450)
            checks["commandVPastesAndAutosavesPromptText"] = text.string == expected &&
                editor.draft.presets[0].prompt == expected && persisted.presets[0].prompt == expected
        }

        func compose(_ name: String, identifier: String, baseline: String, replacement: String,
                     range: NSRange? = nil, current: @escaping (Configuration) -> String) async throws {
            guard let text = try await focus(identifier) else { checks[name + ".nativeEditorAvailable"] = false; return }
            checks[name + ".nativeEditorAvailable"] = true
            checks[name + ".baselineMatches"] = text.string == baseline
            guard text.string == baseline else {
                throw targetFailure(identifier, "Baseline mismatch before composition; no text mutation performed",
                                    details: ["expectedBaseline": baseline, "actualBaseline": text.string])
            }
            let replacementRange = range ?? NSRange(location: 0, length: baseline.utf16.count)
            let before = current(persisted)
            let count = saves.count
            text.setSelectedRange(replacementRange)
            let intermediate = (baseline as NSString).replacingCharacters(in: replacementRange, with: "ni")
            text.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: replacementRange)
            capture(name + ".markedImmediately", text: text, current: current)
            await pause(450)
            checks[name + ".compositionSurvivesDebounce"] = text.hasMarkedText() && text.string == intermediate &&
                text.markedRange() == NSRange(location: replacementRange.location, length: 2) &&
                text.selectedRange() == NSRange(location: replacementRange.location + 2, length: 0) && window.firstResponder === text
            checks[name + ".compositionIsNotSaved"] = current(persisted) == before && saves.count == count
            capture(name + ".afterDebounce", text: text, current: current)

            // A save status notification can redraw the settings view while the
            // input method still owns marked text, even when its value is unchanged.
            editor.error = nil
            await pause(80)
            checks[name + ".compositionSurvivesStatusNotification"] = text.hasMarkedText() && text.string == intermediate &&
                text.markedRange() == NSRange(location: replacementRange.location, length: 2) &&
                text.selectedRange() == NSRange(location: replacementRange.location + 2, length: 0) && window.firstResponder === text
            capture(name + ".afterStatusNotification", text: text, current: current)

            let middle = (baseline as NSString).replacingCharacters(in: replacementRange, with: "nihao")
            text.setMarkedText("nihao", selectedRange: NSRange(location: 5, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            await pause(2200)
            checks[name + ".compositionSurvivesRefreshTimer"] = text.hasMarkedText() && text.string == middle &&
                text.markedRange() == NSRange(location: replacementRange.location, length: 5) &&
                text.selectedRange() == NSRange(location: replacementRange.location + 5, length: 0) && window.firstResponder === text
            checks[name + ".refreshDoesNotSaveComposition"] = current(persisted) == before && saves.count == count
            capture(name + ".afterRefreshTimer", text: text, current: current)

            text.insertText(replacement, replacementRange: NSRange(location: NSNotFound, length: 0))
            let expected = (baseline as NSString).replacingCharacters(in: replacementRange, with: replacement)
            await pause(450)
            checks[name + ".confirmationPreservesAllText"] = !text.hasMarkedText() && text.string == expected &&
                current(editor.draft) == expected && current(persisted) == expected && window.firstResponder === text
            checks[name + ".confirmationPreservesCaret"] = text.selectedRange() ==
                NSRange(location: replacementRange.location + replacement.utf16.count, length: 0)
            capture(name + ".confirmed", text: text, current: current)
        }

        func focus(_ identifier: String) async throws -> NSTextView? {
            let target = try nativeTarget(identifier)
            guard target.view.acceptsFirstResponder else {
                throw targetFailure(identifier, "Matched native control does not accept first responder")
            }
            let accepted = window.makeFirstResponder(target.view)
            await pause(80)
            let focusedTarget = try nativeTarget(identifier)
            guard accepted, let text = focusedTarget.editor(in: window) else {
                throw targetFailure(identifier, "Native focus did not transfer to the matched control",
                                    details: ["focusRequestAccepted": accepted])
            }
            observations.append(["phase": "fixtureTargetFocus", "requestedIdentifier": identifier,
                "matchedIdentifier": focusedTarget.identifier, "accessibilityType": focusedTarget.accessibilityType,
                "accessibilityMatchCount": focusedTarget.accessibilityMatchCount,
                "nativeType": String(reflecting: type(of: focusedTarget.view)), "ownership": focusedTarget.ownership,
                "focusRequestAccepted": accepted, "firstResponderIsOwnedEditor": window.firstResponder === text,
                "isFieldEditor": text.isFieldEditor])
            return text
        }

        func focusedEditor(_ identifier: String) throws -> NSTextView? {
            try nativeTarget(identifier).editor(in: window)
        }

        func nativeTarget(_ identifier: String) throws -> NativeTarget {
            var visited = Set<ObjectIdentifier>()
            let matches = accessibleMatches(window, identifier: identifier, visited: &visited)
            guard !matches.isEmpty else {
                throw targetFailure(identifier, "Accessibility identifier was not found",
                                    details: ["matchCount": matches.count])
            }
            guard let content = window.contentView else { throw targetFailure(identifier, "Window content is missing") }
            let views = nativeEditors(content).filter { $0.window === window && !$0.isHiddenOrHasHiddenAncestor }
            let aliases = try matches.map { match -> NativeTarget in
                let candidates = views.compactMap { view -> NativeTarget? in
                    guard let ownership = ownership(of: match, by: view, identifier: identifier) else { return nil }
                    return NativeTarget(view: view, identifier: identifier, ownership: ownership,
                                        accessibilityType: String(reflecting: type(of: match)), accessibilityMatchCount: 1)
                }
                guard candidates.count == 1, let target = candidates.first else {
                    throw targetFailure(identifier, "Accessibility match does not have one proven native owner",
                                        details: ["nativeOwnerCount": candidates.count,
                                                  "accessibilityType": String(reflecting: type(of: match))])
                }
                return target
            }
            let owners = Set(aliases.map { ObjectIdentifier($0.view) })
            guard owners.count == 1, let target = aliases.first else {
                throw targetFailure(identifier, "Identifier matches multiple native owners",
                                    details: ["nativeOwnerCount": owners.count, "matchCount": matches.count])
            }
            return NativeTarget(view: target.view, identifier: identifier,
                                ownership: aliases.map(\.ownership).joined(separator: "; "),
                                accessibilityType: aliases.map(\.accessibilityType).joined(separator: "; "),
                                accessibilityMatchCount: matches.count)
        }

        func targetFailure(_ identifier: String, _ reason: String, details: [String: Any] = [:]) -> TargetFailure {
            var observation = details
            observation["phase"] = "fixtureTargetFailure"
            observation["requestedIdentifier"] = identifier
            observation["reason"] = reason
            observation["firstResponderType"] = window.firstResponder.map { String(reflecting: type(of: $0)) } ?? "none"
            observations.append(observation)
            return TargetFailure(description: "Fixture target \(identifier): \(reason)")
        }
        func capture(_ phase: String, text: NSTextView, current: (Configuration) -> String) {
            observations.append(["phase": phase, "text": text.string, "marked": rangeJSON(text.markedRange()),
                "selection": rangeJSON(text.selectedRange()), "hasMarkedText": text.hasMarkedText(),
                "isFirstResponder": window.firstResponder === text, "draft": current(editor.draft),
                "persisted": current(persisted), "saveCount": saves.count, "error": editor.error ?? ""])
        }
        func element(_ identifier: String) -> Accessible? { find(window, identifier: identifier) }
    }

    @MainActor private struct Accessible {
        let object: NSObject
        var label: String? {
            let selector = NSSelectorFromString("accessibilityLabel")
            return object.responds(to: selector) ? object.perform(selector)?.takeUnretainedValue() as? String : nil
        }
        var text: String? {
            // Native static text exposes its content as AXValue; buttons use AXLabel.
            let selector = NSSelectorFromString("accessibilityValue")
            return (object.responds(to: selector) ? object.perform(selector)?.takeUnretainedValue() as? String : nil) ?? label
        }
        var frame: NSRect {
            let selector = NSSelectorFromString("accessibilityFrame")
            guard object.responds(to: selector) else { return .zero }
            typealias Frame = @convention(c) (AnyObject, Selector) -> NSRect
            return unsafeBitCast(object.method(for: selector), to: Frame.self)(object, selector)
        }
        func press() -> Bool {
            let selector = NSSelectorFromString("accessibilityPerformPress")
            guard object.responds(to: selector) else { return false }
            typealias Action = @convention(c) (AnyObject, Selector) -> ObjCBool
            return unsafeBitCast(object.method(for: selector), to: Action.self)(object, selector).boolValue
        }
    }

    private struct TargetFailure: Error, CustomStringConvertible { let description: String }

    @MainActor private struct NativeTarget {
        let view: NSView
        let identifier: String
        let ownership: String
        let accessibilityType: String
        let accessibilityMatchCount: Int

        func editor(in window: NSWindow) -> NSTextView? {
            guard view.window === window else { return nil }
            if let field = view as? NSTextField, let text = field.currentEditor() as? NSTextView,
               text.isFieldEditor, window.firstResponder === text { return text }
            if let text = view as? NSTextView, !text.isFieldEditor,
               window.firstResponder === text { return text }
            return nil
        }
    }

    private static func nativeEditors(_ view: NSView) -> [NSView] {
        if let field = view as? NSTextField, field.isEditable, field.isEnabled { return [field] }
        if let text = view as? NSTextView, text.isEditable, !text.isFieldEditor { return [text] }
        return view.subviews.flatMap(nativeEditors)
    }

    private static func identifier(of object: NSObject) -> String? {
        let selector = NSSelectorFromString("accessibilityIdentifier")
        return object.responds(to: selector) ? object.perform(selector)?.takeUnretainedValue() as? String : nil
    }

    private static func accessibleMatches(_ object: NSObject, identifier: String,
                                          visited: inout Set<ObjectIdentifier>) -> [NSObject] {
        guard visited.insert(ObjectIdentifier(object)).inserted else { return [] }
        var matches = self.identifier(of: object) == identifier ? [object] : []
        let selector = NSSelectorFromString("accessibilityChildren")
        if object.responds(to: selector), let children = object.perform(selector)?.takeUnretainedValue() as? [NSObject] {
            for child in children { matches += accessibleMatches(child, identifier: identifier, visited: &visited) }
        }
        return matches
    }

    private static func ownership(of match: NSObject, by view: NSView, identifier: String) -> String? {
        let cell = (view as? NSTextField)?.cell
        if match === view { return "accessibility object is native editor" }
        if self.identifier(of: view) == identifier { return "native editor has exact identifier" }
        if let cell, match === cell || self.identifier(of: cell) == identifier { return "matched field cell belongs to native control" }
        var visited = Set<ObjectIdentifier>()
        var parent: NSObject? = match
        while let current = parent, visited.count < 64, visited.insert(ObjectIdentifier(current)).inserted {
            if current === view || (cell.map { current === $0 } ?? false) { return "accessibility parent chain reaches native owner" }
            // A common window/hosting view does not identify an individual editor.
            if current is NSWindow || (current is NSView && current !== match) { break }
            let selector = NSSelectorFromString("accessibilityParent")
            parent = current.responds(to: selector) ? current.perform(selector)?.takeUnretainedValue() as? NSObject : nil
        }
        for root in [view as NSObject] + (cell.map { [$0 as NSObject] } ?? []) {
            var seen = Set<ObjectIdentifier>()
            if accessibleDescendant(root, contains: match, visited: &seen) { return "native control accessibility subtree contains exact match" }
            seen.removeAll()
            if accessibleDescendant(match, contains: root, visited: &seen) { return "matched accessibility subtree contains native owner" }
            var ancestor: NSObject? = root
            seen.removeAll()
            while let current = ancestor, seen.count < 64, seen.insert(ObjectIdentifier(current)).inserted {
                if current === match { return "native control accessibility parent chain reaches exact match" }
                if current is NSWindow || (current is NSView && current !== root) { break }
                let selector = NSSelectorFromString("accessibilityParent")
                ancestor = current.responds(to: selector) ? current.perform(selector)?.takeUnretainedValue() as? NSObject : nil
            }
        }
        return nil
    }

    private static func accessibleDescendant(_ root: NSObject, contains target: NSObject,
                                            visited: inout Set<ObjectIdentifier>) -> Bool {
        guard visited.count < 512, visited.insert(ObjectIdentifier(root)).inserted else { return false }
        if root === target { return true }
        let selector = NSSelectorFromString("accessibilityChildren")
        guard root.responds(to: selector), let children = root.perform(selector)?.takeUnretainedValue() as? [NSObject] else { return false }
        return children.contains { accessibleDescendant($0, contains: target, visited: &visited) }
    }
    private static func find(_ root: Any, identifier: String) -> Accessible? {
        guard let object = root as? NSObject else { return nil }
        let id = NSSelectorFromString("accessibilityIdentifier")
        if object.responds(to: id), object.perform(id)?.takeUnretainedValue() as? String == identifier {
            return Accessible(object: object)
        }
        let children = NSSelectorFromString("accessibilityChildren")
        guard object.responds(to: children),
              let values = object.perform(children)?.takeUnretainedValue() as? [Any] else { return nil }
        for child in values { if let match = find(child, identifier: identifier) { return match } }
        return nil
    }
    private static func rangeJSON(_ range: NSRange) -> [String: Int] {
        ["location": range.location, "length": range.length]
    }
    private static func pause(_ milliseconds: Int) async { try? await Task.sleep(for: .milliseconds(milliseconds)) }
}

/// Exercises the actual nested settings scroll views through application event dispatch.
@MainActor enum SettingsScrollVerification {
    static func run(text: NSTextView) async -> (checks: [String: Bool], observations: [[String: Any]]) {
        var checks: [String: Bool] = [:]
        var observations: [[String: Any]] = []
        guard let inner = text.enclosingScrollView, let window = text.window,
              let root = window.contentView, let outer = enclosingScrollView(of: inner),
              let innerDocument = inner.documentView, let outerDocument = outer.documentView else {
            return (["nestedScroll.nativeHierarchyAvailable": false], [])
        }
        checks["nestedScroll.nativeHierarchyAvailable"] = true
        // Keep an independent text snapshot for the short-text round trip.
        let originalText = String(decoding: text.string.utf8, as: UTF8.self)
        let originalSelection = text.selectedRange()
        let originalResponder = window.firstResponder
        let originalInner = inner.contentView.bounds.origin
        let originalOuter = outer.contentView.bounds.origin
        observations.append(["phase": "nestedScroll.originalText",
            "textState": textState(text, original: originalText, selection: originalSelection, responder: originalResponder)])
        let geometryBeforeLayout = geometry(inner, outer)
        if let container = text.textContainer { text.layoutManager?.ensureLayout(for: container) }
        root.layoutSubtreeIfNeeded()
        await pause(100)
        observations.append(["phase": "nestedScroll.layoutPreparation", "geometryBefore": geometryBeforeLayout,
            "geometryAfter": geometry(inner, outer)])
        let innerRange = scrollRange(inner)
        let outerRange = scrollRange(outer)
        checks["nestedScroll.innerActuallyOverflows"] = innerRange.upperBound - innerRange.lowerBound > 100
        checks["nestedScroll.outerActuallyOverflows"] = outerRange.upperBound - outerRange.lowerBound > 30

        // Keep the editor visible while leaving room for the parent to move. All
        // targeting below comes from the real view hierarchy after this scroll.
        let editorRect = outerDocument.convert(inner.bounds, from: inner)
        let visibleLower = max(outerRange.lowerBound + 120, editorRect.maxY - outer.contentView.bounds.height + 8)
        let visibleUpper = min(outerRange.upperBound - 120, editorRect.minY - 8)
        let centered = editorRect.midY - outer.contentView.bounds.height / 2
        let baseline = visibleLower <= visibleUpper ? min(visibleUpper, max(visibleLower, centered)) : centered
        setOffset(outer, y: min(outerRange.upperBound, max(outerRange.lowerBound, baseline)))
        await pause(180)
        let outerBaseline = outer.contentView.bounds.origin
        checks["nestedScroll.outerBaselineHasRoomInBothDirections"] =
            outerBaseline.y > outerRange.lowerBound + 100 && outerBaseline.y < outerRange.upperBound - 100
        let editorPoint = inner.contentView.convert(NSPoint(x: inner.contentView.bounds.midX,
            y: inner.contentView.bounds.midY), to: nil)
        let editorHit = root.hitTest(root.convert(editorPoint, from: nil))
        let targetsEditor = editorHit.map { $0 === inner || $0.isDescendant(of: inner) } ?? false
        checks["nestedScroll.editorPointHitsRealEditor"] = targetsEditor &&
            inner.contentView.visibleRect.contains(inner.contentView.convert(editorPoint, from: nil))
        observations.append(["phase": "nestedScroll.geometry", "innerClass": String(describing: type(of: inner)),
            "outerClass": String(describing: type(of: outer)), "innerDocument": NSStringFromRect(innerDocument.bounds),
            "innerViewport": NSStringFromRect(inner.contentView.bounds), "outerDocument": NSStringFromRect(outerDocument.bounds),
            "outerViewport": NSStringFromRect(outer.contentView.bounds), "editorWindowRect": NSStringFromRect(inner.convert(inner.bounds, to: nil)),
            "editorPoint": NSStringFromPoint(editorPoint), "hitTarget": editorHit.map { String(describing: type(of: $0)) } ?? "nil",
            "dispatch": "real CG wheel payload + NSEvent window/location snapshot -> NSApp.sendEvent; no direct scrollWheel fallback"])

        if targetsEditor {
            for trackpad in [false, true] {
                let device = trackpad ? "trackpad" : "mouse"
                for (name, offset, direction, expectsMovement) in [
                    ("middleDown", (innerRange.lowerBound + innerRange.upperBound) / 2, -1, true),
                    ("middleUp", (innerRange.lowerBound + innerRange.upperBound) / 2, 1, true),
                    ("topBoundary", innerRange.lowerBound, 1, false),
                    ("bottomBoundary", innerRange.upperBound, -1, false),
                    ("crossTop", innerRange.lowerBound + 4, 1, true),
                    ("crossBottom", innerRange.upperBound - 4, -1, true)
                ] {
                    outer.contentView.scroll(to: outerBaseline)
                    outer.reflectScrolledClipView(outer.contentView)
                    setOffset(inner, y: offset)
                    await pause(80)
                    let before = offsets(inner, outer)
                    let geometryBefore = geometry(inner, outer)
                    let events = await dispatch(window: window, point: editorPoint,
                        direction: direction, trackpad: trackpad, singleMovement: name.hasPrefix("cross"))
                    let after = offsets(inner, outer)
                    let prefix = "nestedScroll.\(device).\(name)"
                    checks[prefix + ".eventsConstructed"] = !events.isEmpty
                    checks[prefix + ".outerStaysStill"] = abs(after.outer - before.outer) < 1
                    if expectsMovement {
                        checks[prefix + ".innerMovesInRequestedDirection"] =
                            direction < 0 ? after.inner > before.inner + 1 : after.inner < before.inner - 1
                    }
                    if name.hasPrefix("cross") {
                        let boundary = direction < 0 ? innerRange.upperBound : innerRange.lowerBound
                        checks[prefix + ".innerReachesBoundary"] = abs(after.inner - boundary) < 1
                    }
                    observations.append(["phase": prefix, "innerBefore": before.inner, "innerAfter": after.inner,
                        "outerBefore": before.outer, "outerAfter": after.outer,
                        "geometryBefore": geometryBefore, "geometryAfter": geometry(inner, outer), "events": events])
                }
            }
        }

        let scrollingPreservedContent = text.string == originalText && text.selectedRange() == originalSelection &&
            window.firstResponder === originalResponder
        // No-overflow editors must also own the wheel gesture, instead of
        // unexpectedly moving the settings page under the pointer.
        if targetsEditor {
            text.insertText("简短提示词", replacementRange: NSRange(location: 0, length: text.string.utf16.count))
            observations.append(["phase": "nestedScroll.shortTextImmediate",
                "textState": textState(text, original: originalText, selection: originalSelection, responder: originalResponder)])
            await pause(450)
            observations.append(["phase": "nestedScroll.shortTextSaved",
                "textState": textState(text, original: originalText, selection: originalSelection, responder: originalResponder),
                "geometry": geometry(inner, outer)])
            checks["nestedScroll.shortTextDoesNotOverflow"] = innerDocument.bounds.height <= inner.contentView.bounds.height + 1
            for trackpad in [false, true] {
                for direction in [-1, 1] {
                    outer.contentView.scroll(to: outerBaseline)
                    outer.reflectScrolledClipView(outer.contentView)
                    setOffset(inner, y: scrollRange(inner).lowerBound)
                    await pause(80)
                    let before = offsets(inner, outer)
                    let geometryBefore = geometry(inner, outer)
                    let events = await dispatch(window: window, point: editorPoint,
                        direction: direction, trackpad: trackpad)
                    let after = offsets(inner, outer)
                    let prefix = "nestedScroll.\(trackpad ? "trackpad" : "mouse").short\(direction < 0 ? "Down" : "Up")"
                    checks[prefix + ".eventsConstructed"] = !events.isEmpty
                    checks[prefix + ".outerStaysStill"] = abs(after.outer - before.outer) < 1
                    checks[prefix + ".innerStaysStill"] = abs(after.inner - before.inner) < 1
                    observations.append(["phase": prefix, "innerBefore": before.inner, "innerAfter": after.inner,
                        "outerBefore": before.outer, "outerAfter": after.outer,
                        "geometryBefore": geometryBefore, "geometryAfter": geometry(inner, outer), "events": events])
                }
            }
            text.insertText(originalText, replacementRange: NSRange(location: 0, length: text.string.utf16.count))
            observations.append(["phase": "nestedScroll.restoredTextImmediate",
                "textState": textState(text, original: originalText, selection: originalSelection, responder: originalResponder)])
            await pause(450)
            text.setSelectedRange(originalSelection)
            observations.append(["phase": "nestedScroll.restoredTextSaved",
                "textState": textState(text, original: originalText, selection: originalSelection, responder: originalResponder),
                "geometry": geometry(inner, outer)])
            checks["nestedScroll.restoresOriginalTextAfterShortText"] = text.string == originalText
        }

        // A point in the parent's visible viewport, outside every nested editor,
        // establishes that routing still allows ordinary settings-page scrolling.
        outer.contentView.scroll(to: outerBaseline)
        outer.reflectScrolledClipView(outer.contentView)
        await pause(100)
        let outside = outsideEditorPoint(in: outer, root: root)
        checks["nestedScroll.outsidePointAvailable"] = outside != nil
        if let outside {
            for trackpad in [false, true] {
                outer.contentView.scroll(to: outerBaseline)
                outer.reflectScrolledClipView(outer.contentView)
                setOffset(inner, y: (innerRange.lowerBound + innerRange.upperBound) / 2)
                await pause(80)
                let before = offsets(inner, outer)
                let geometryBefore = geometry(inner, outer)
                let hit = root.hitTest(root.convert(outside, from: nil))
                let direction = outerRange.upperBound - before.outer > before.outer - outerRange.lowerBound ? -1 : 1
                let events = await dispatch(window: window, point: outside,
                    direction: direction, trackpad: trackpad)
                let after = offsets(inner, outer)
                let prefix = "nestedScroll.\(trackpad ? "trackpad" : "mouse").outside"
                checks[prefix + ".eventsConstructed"] = !events.isEmpty
                checks[prefix + ".outerMoves"] = direction < 0 ? after.outer > before.outer + 1 : after.outer < before.outer - 1
                checks[prefix + ".innerStaysStill"] = abs(after.inner - before.inner) < 1
                observations.append(["phase": prefix, "windowPoint": NSStringFromPoint(outside),
                    "hitTarget": hit.map { String(describing: type(of: $0)) } ?? "nil",
                    "innerBefore": before.inner, "innerAfter": after.inner,
                    "outerBefore": before.outer, "outerAfter": after.outer,
                    "geometryBefore": geometryBefore, "geometryAfter": geometry(inner, outer), "events": events])
            }
        }
        checks["nestedScroll.preservesTextSelectionAndFocus"] = scrollingPreservedContent && text.string == originalText &&
            text.selectedRange() == originalSelection && window.firstResponder === originalResponder
        if text.selectedRange() != originalSelection { text.setSelectedRange(originalSelection) }
        if window.firstResponder !== originalResponder { window.makeFirstResponder(originalResponder) }
        inner.contentView.scroll(to: originalInner)
        inner.reflectScrolledClipView(inner.contentView)
        outer.contentView.scroll(to: originalOuter)
        outer.reflectScrolledClipView(outer.contentView)
        await pause(100)
        observations.append(["phase": "nestedScroll.finalState",
            "textState": textState(text, original: originalText, selection: originalSelection, responder: originalResponder),
            "geometry": geometry(inner, outer)])
        return (checks, observations)
    }

    private static func textState(_ text: NSTextView, original: String, selection: NSRange,
        responder: NSResponder?) -> [String: Any] {
        ["characterCount": text.string.count, "utf16Count": text.string.utf16.count,
            "originalCharacterCount": original.count, "originalUTF16Count": original.utf16.count,
            "matchesOriginal": text.string == original, "selection": NSStringFromRange(text.selectedRange()),
            "selectionMatchesOriginal": text.selectedRange() == selection,
            "isFirstResponder": text.window?.firstResponder === text,
            "responderMatchesOriginal": text.window?.firstResponder === responder]
    }

    private static func geometry(_ inner: NSScrollView, _ outer: NSScrollView) -> [String: Any] {
        func details(_ scroll: NSScrollView) -> [String: Any] {
            ["documentVisibleRect": NSStringFromRect(scroll.documentVisibleRect),
                "documentBounds": NSStringFromRect(scroll.documentView?.bounds ?? .zero),
                "clipBounds": NSStringFromRect(scroll.contentView.bounds)]
        }
        return ["inner": details(inner), "outer": details(outer)]
    }

    private static func enclosingScrollView(of view: NSView) -> NSScrollView? {
        var parent = view.superview
        while let current = parent {
            if let scroll = current as? NSScrollView { return scroll }
            parent = current.superview
        }
        return nil
    }

    private static func scrollRange(_ scroll: NSScrollView) -> ClosedRange<CGFloat> {
        let bounds = scroll.documentView?.bounds ?? .zero
        return bounds.minY...max(bounds.minY, bounds.maxY - scroll.contentView.bounds.height)
    }

    private static func setOffset(_ scroll: NSScrollView, y: CGFloat) {
        scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.minX, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    private static func offsets(_ inner: NSScrollView, _ outer: NSScrollView) -> (inner: CGFloat, outer: CGFloat) {
        (inner.contentView.bounds.minY, outer.contentView.bounds.minY)
    }

    private static func outsideEditorPoint(in outer: NSScrollView, root: NSView) -> NSPoint? {
        let clip = outer.contentView
        for xFraction in [CGFloat(0.02), 0.98, 0.5, 0.15, 0.85] {
            for yFraction in [CGFloat(0.5), 0.25, 0.75, 0.1, 0.9] {
                let point = clip.convert(NSPoint(x: clip.bounds.minX + clip.bounds.width * xFraction,
                    y: clip.bounds.minY + clip.bounds.height * yFraction), to: nil)
                guard let hit = root.hitTest(root.convert(point, from: nil)) else { continue }
                if hit === clip || hit === outer || hit.enclosingScrollView === outer { return point }
            }
        }
        return nil
    }

    private static func dispatch(window: NSWindow, point: NSPoint, direction: Int, trackpad: Bool,
        singleMovement: Bool = false) async -> [[String: Any]] {
        let sequence: [(NSEvent.Phase, NSEvent.Phase, Int32)] = !trackpad ? [([], [], Int32(direction * 3))] : singleMovement ? [
            (.began, [], Int32(direction * 32)), (.ended, [], 0)
        ] : [
            (.began, [], Int32(direction * 32)), (.changed, [], Int32(direction * 48)), (.ended, [], 0),
            ([], .began, Int32(direction * 24)), ([], .changed, Int32(direction * 16)), ([], .ended, 0)
        ]
        var details: [[String: Any]] = []
        for (phase, momentum, delta) in sequence {
            guard let event = wheelEvent(window: window, point: point, delta: delta,
                trackpad: trackpad, phase: phase, momentum: momentum) else { return [] }
            details.append(["windowNumber": event.windowNumber, "windowMatches": event.window === window,
                "point": NSStringFromPoint(event.locationInWindow), "deltaY": event.scrollingDeltaY,
                "precise": event.hasPreciseScrollingDeltas, "phase": event.phase.rawValue,
                "momentumPhase": event.momentumPhase.rawValue])
            NSApp.sendEvent(event)
            await pause(35)
        }
        await pause(350)
        return details
    }

    private static func wheelEvent(window: NSWindow, point: NSPoint, delta: Int32,
        trackpad: Bool, phase: NSEvent.Phase, momentum: NSEvent.Phase) -> NSEvent? {
        guard let source = CGEventSource(stateID: .privateState),
              let payload = CGEvent(scrollWheelEvent2Source: source, units: trackpad ? .pixel : .line,
                wheelCount: 1, wheel1: delta, wheel2: 0, wheel3: 0) else { return nil }
        let screen = window.convertPoint(toScreen: point)
        payload.location = CGPoint(x: screen.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - screen.y)
        payload.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.windowNumber))
        payload.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window.windowNumber))
        payload.setIntegerValueField(.scrollWheelEventIsContinuous, value: trackpad ? 1 : 0)
        let scrollPhase: Int64 = phase == .began ? 1 : phase == .changed ? 2 : phase == .ended ? 4 : 0
        let momentumPhase: Int64 = momentum == .began ? 1 : momentum == .changed ? 2 : momentum == .ended ? 3 : 0
        payload.setIntegerValueField(.scrollWheelEventScrollPhase, value: scrollPhase)
        payload.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentumPhase)
        guard let base = NSEvent(cgEvent: payload) else { return nil }
        let event = FixtureWheelEvent()
        event.base = base
        event.targetWindow = window
        event.targetWindowNumber = window.windowNumber
        event.targetPoint = point
        event.targetPhase = phase
        event.targetMomentumPhase = momentum
        return event
    }

    /// NSEvent(cgEvent:) cannot publicly attach an owned window. Snapshot only
    /// the association and gesture phases while preserving the CG wheel data.
    private final class FixtureWheelEvent: NSEvent {
        var base: NSEvent?
        weak var targetWindow: NSWindow?
        var targetWindowNumber = 0
        var targetPoint = NSPoint.zero
        var targetPhase: NSEvent.Phase = []
        var targetMomentumPhase: NSEvent.Phase = []
        override var type: NSEvent.EventType { base?.type ?? .scrollWheel }
        override var window: NSWindow? { targetWindow }
        override var windowNumber: Int { targetWindowNumber }
        override var locationInWindow: NSPoint { targetPoint }
        override var scrollingDeltaX: CGFloat { base?.scrollingDeltaX ?? 0 }
        override var scrollingDeltaY: CGFloat { base?.scrollingDeltaY ?? 0 }
        override var deltaX: CGFloat { base?.deltaX ?? 0 }
        override var deltaY: CGFloat { base?.deltaY ?? 0 }
        override var deltaZ: CGFloat { base?.deltaZ ?? 0 }
        override var hasPreciseScrollingDeltas: Bool { base?.hasPreciseScrollingDeltas ?? false }
        override var isDirectionInvertedFromDevice: Bool { base?.isDirectionInvertedFromDevice ?? false }
        override var phase: NSEvent.Phase { targetPhase }
        override var momentumPhase: NSEvent.Phase { targetMomentumPhase }
        override var modifierFlags: NSEvent.ModifierFlags { base?.modifierFlags ?? [] }
        override var timestamp: TimeInterval { base?.timestamp ?? 0 }
        override var cgEvent: CGEvent? { base?.cgEvent }
    }

    private static func pause(_ milliseconds: Int) async { try? await Task.sleep(for: .milliseconds(milliseconds)) }
}
