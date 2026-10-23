import AppKit
import Combine
import BigBangCore
import BigBangSelection

/// Packaged, native-control verification against the owned loopback fixture.
@MainActor enum StickyPresetSwitchVerification {
    private static var previewSticky: StickyWindow?
    static func run(baseURL: String, reportURL: URL, registerPreview: ((StickyWindow) -> Void)? = nil) async {
        var checks: [String: Bool] = [:]
        var diagnostics: [String: Any] = [:]
        for mode in APIMode.allCases {
            let a = Preset(name: "Fixture A", prompt: "fixture-preset-A", shortcut: Shortcut(keyCode: 18, modifiers: 6144, label: "⌃⌥1"))
            let b = Preset(name: "Fixture B", prompt: "fixture-preset-B", shortcut: Shortcut(keyCode: 19, modifiers: 6144, label: "⌃⌥2"))
            let c = Preset(name: "Fixture C", prompt: "fixture-preset-C", shortcut: Shortcut(keyCode: 20, modifiers: 6144, label: "⌃⌥3"))
            var configuration = Configuration(language: .simplifiedChinese)
            configuration.apiBaseURL = baseURL
            configuration.apiMode = mode
            configuration.model = "test-model"
            configuration.presets = [a, b, c]
            var rejectKey = false
            var starts: [String] = []
            var sources: [String] = []
            let note = StickyWindow(preset: a, source: "preset-switch-input", offset: 0)
            let independent = StickyWindow(preset: a, source: "independent-note", offset: 1)
            independent.model.output = "Independent output"
            note.configureProcessing(configuration: { configuration }, readKey: {
                if rejectKey { throw ValidationError("Fixture key unavailable") }
                return "local-test-key"
            }, start: { sticky, config, key in
                starts.append(sticky.model.preset.prompt)
                sources.append(sticky.model.source)
                sticky.model.start(configuration: config, key: key)
            })
            note.updateConfiguration(configuration)
            independent.updateConfiguration(configuration)
            note.showWindow(nil)
            independent.showWindow(nil)
            note.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            let originalWindow = note.window
            var local: [String: Bool] = [:]
            local["nativePopupAvailable"] = await waitFor { popup(in: note.hostingView) != nil }
            guard let button = popup(in: note.hostingView) else {
                checks[mode.rawValue + ".nativePopupAvailable"] = false
                note.window?.close(); independent.window?.close()
                continue
            }
            local["menuInitiallyMatchesConfiguration"] = menuIDs(button) == [a.id, b.id, c.id]
            note.model.retry?()
            local["firstPresetStreams"] = await waitFor { note.model.output == "A first" && note.model.running }
            let count = starts.count
            local["samePresetUsesNativeActionWithoutRequest"] = select(a.id, in: button) && starts.count == count
            local["switchUsesNativePopupAction"] = select(b.id, in: button)
            local["switchClearsPreviousOutput"] = note.model.output.isEmpty && note.model.preset.id == b.id
            local["newPresetCompletes"] = await waitFor { !note.model.running && note.model.output == "B first\nB complete" }
            // A sends a deliberately delayed tail after B has completed.
            try? await Task.sleep(for: .milliseconds(1050))
            local["cancelledSessionCannotPolluteNewOutput"] = note.model.output == "B first\nB complete" && note.model.error == nil
            local["sameWindowAndOriginalInput"] = note.window === originalWindow && note.model.source == "preset-switch-input"
            local["nativeRetryInvokesCurrentPreset"] = await press(in: note.window, identifier: "sticky.arrow.clockwise")
            local["retryCompletesWithSelectedPreset"] = await waitFor { !note.model.running && note.model.output == "B first\nB complete" && starts.count == 3 }
            local["rapidFirstNativeSelection"] = select(c.id, in: button)
            local["rapidFirstRequestActuallyStreams"] = await waitFor { note.model.output == "C first" && note.model.running }
            local["rapidSecondNativeSelection"] = select(b.id, in: button)
            local["rapidSecondSelectionWins"] = await waitFor { !note.model.running && note.model.output == "B first\nB complete" }
            try? await Task.sleep(for: .milliseconds(550))
            local["rapidCancelledTailCannotPolluteOutput"] = note.model.output == "B first\nB complete" && note.model.preset.id == b.id
            rejectKey = true
            let beforeFailure = note.model.output
            let countBeforeFailure = starts.count
            local["failedKeyReadUsesNativeAction"] = select(c.id, in: button)
            local["failedKeyReadPreservesPresetAndOutput"] = note.model.preset.id == b.id && note.model.output == beforeFailure &&
                !note.model.running && note.model.error != nil && starts.count == countBeforeFailure
            local["failedSelectionRestoresNativeSelection"] = button.selectedItem?.representedObject as? UUID == b.id
            rejectKey = false
            // Exercise a stale menu item whose ID has vanished from the live configuration.
            let staleID = UUID()
            let staleItem = NSMenuItem(title: "Stale fixture", action: nil, keyEquivalent: "")
            staleItem.representedObject = staleID
            staleItem.isEnabled = true
            button.menu?.addItem(staleItem)
            local["staleNativeMenuIDIsIgnored"] = select(staleID, in: button) && starts.count == countBeforeFailure &&
                note.model.preset.id == b.id && note.model.output == beforeFailure && button.selectedItem?.representedObject as? UUID == b.id

            var renamedB = b
            renamedB.name = "Updated B"
            renamedB.prompt = "fixture-preset-C"
            var longC = c
            longC.name = String(repeating: "Very long preset name 🌍 中文 ", count: 12)
            configuration.presets = [longC, renamedB, a]
            configuration.language = .english
            note.updateConfiguration(configuration)
            local["configurationUpdatesMenuOrderAndNames"] = await waitFor {
                menuIDs(button) == [c.id, b.id, a.id] && button.menu?.items.first?.title == longC.name &&
                    button.menu?.items.dropFirst().first?.title == renamedB.name && note.model.availablePresets == configuration.presets
            }
            local["configurationUpdateDoesNotRequest"] = starts.count == countBeforeFailure
            local["configurationUpdatesLanguage"] = note.model.language == .english
            local["retryAfterPromptEditUsesNativeControl"] = await press(in: note.window, identifier: "sticky.arrow.clockwise")
            local["retryUsesLatestPromptForSelectedIdentity"] = await waitFor {
                !note.model.running && note.model.output == "C first\nC complete" && note.model.preset.id == b.id && note.model.preset.prompt == "fixture-preset-C"
            }
            configuration.presets = [longC, a]
            note.updateConfiguration(configuration)
            local["deletionRemovesPresetFromAvailableList"] = note.model.availablePresets.map(\.id) == [c.id, a.id]
            local["deletionPreservesCurrentSnapshot"] = note.model.preset.id == b.id && note.model.preset.prompt == "fixture-preset-C"
            local["deletedSnapshotIsDisabledInNativeMenu"] = await waitFor {
                button.menu?.items.first?.representedObject as? UUID == b.id && button.menu?.items.first?.isEnabled == false &&
                    button.menu?.items.filter(\.isEnabled).compactMap { $0.representedObject as? UUID } == [c.id, a.id]
            }
            local["deletedPresetStillRetriesViaNativeControl"] = await press(in: note.window, identifier: "sticky.arrow.clockwise")
            local["deletedPresetRetriesItsSnapshot"] = await waitFor { !note.model.running && note.model.output == "C first\nC complete" }

            // Re-add the current identity with a long title without issuing a request.
            renamedB.name = longC.name
            configuration.presets = [longC, renamedB, a]
            note.updateConfiguration(configuration)
            try? await Task.sleep(for: .milliseconds(100))
            local["longPresetTitleKeepsHeaderActionsVisible"] = headerFits(note, button: button)
            note.window?.appearance = NSAppearance(named: .aqua)
            try? await Task.sleep(for: .milliseconds(100))
            local["lightScreenshotSaved"] = snapshot(note.window, url: reportURL.deletingLastPathComponent().appendingPathComponent("preset-switch-\(mode.rawValue)-light.png"))
            note.window?.appearance = NSAppearance(named: .darkAqua)
            try? await Task.sleep(for: .milliseconds(100))
            local["darkScreenshotSaved"] = snapshot(note.window, url: reportURL.deletingLastPathComponent().appendingPathComponent("preset-switch-\(mode.rawValue)-dark.png"))
            local["otherNoteIsIndependent"] = independent.model.output == "Independent output" && independent.model.preset.id == a.id && !independent.model.running
            let localized = StickyWindow(preset: Preset.defaults[0], source: "localization-only", offset: 2)
            var localizedConfiguration = Configuration(language: .simplifiedChinese)
            localized.showWindow(nil)
            localized.updateConfiguration(localizedConfiguration)
            local["builtInChineseNameAndLabel"] = await waitFor {
                guard let localizedButton = popup(in: localized.hostingView) else { return false }
                return localizedButton.selectedItem?.title == "🌐 翻译" &&
                    localizedButton.accessibilityLabel() == L10n.string("切换预设", language: .simplifiedChinese)
            }
            localizedConfiguration.language = .english
            localizedConfiguration.presets = Preset.defaults(for: .english)
            localized.updateConfiguration(localizedConfiguration)
            local["builtInEnglishNameAndLabel"] = await waitFor {
                guard let localizedButton = popup(in: localized.hostingView) else { return false }
                return localizedButton.selectedItem?.title == "🌐 Translate" &&
                    localizedButton.accessibilityLabel() == L10n.string("切换预设", language: .english)
            }
            localized.window?.close()

            var longA = a
            longA.name = longC.name
            configuration.presets = [longC, renamedB, longA]
            note.updateConfiguration(configuration)
            _ = await waitFor { menuIDs(button) == [c.id, b.id, a.id] }
            local["stopStartsSelectedSlowPreset"] = select(a.id, in: button)
            _ = await waitFor { note.model.output == "A first" && note.model.running }
            note.window?.appearance = NSAppearance(named: .aqua)
            try? await Task.sleep(for: .milliseconds(100))
            local["runningLongTitleFitsWithSpinner"] = note.model.running && headerFits(note, button: button)
            local["runningLightScreenshotSaved"] = snapshot(note.window, url: reportURL.deletingLastPathComponent().appendingPathComponent("preset-switch-\(mode.rawValue)-running-light.png"))
            note.window?.appearance = NSAppearance(named: .darkAqua)
            try? await Task.sleep(for: .milliseconds(100))
            local["runningDarkScreenshotSaved"] = note.model.running && snapshot(note.window, url: reportURL.deletingLastPathComponent().appendingPathComponent("preset-switch-\(mode.rawValue)-running-dark.png"))
            local["nativeStopControlWorks"] = await press(in: note.window, identifier: "sticky.stop.fill") && !note.model.running
            let stopped = note.model.output
            try? await Task.sleep(for: .milliseconds(950))
            local["stopPreventsLateUpdates"] = note.model.output == stopped && note.model.state == "已停止"
            local["nativeRetryAfterStopWorks"] = await press(in: note.window, identifier: "sticky.arrow.clockwise")
            // Wait for the running view's AX tree before pressing once; the first model delta
            // can arrive before SwiftUI replaces the previous retry control.
            local["closeStartsWithLiveStream"] = await waitFor {
                note.model.output == "A first" && note.model.running &&
                    element(in: note.window, identifier: "sticky.stop.fill") != nil
            }
            diagnostics[mode.rawValue + ".closeBefore"] = [
                "running": note.model.running, "visible": note.window?.isVisible == true,
                "hasStopControl": element(in: note.window, identifier: "sticky.stop.fill") != nil
            ]
            let closeAccepted = await press(in: note.window, identifier: "sticky.xmark")
            diagnostics[mode.rawValue + ".closePressAccepted"] = closeAccepted
            local["nativeCloseCancelsStream"] = await waitFor {
                !note.model.running && note.model.state == "已停止" && note.window?.isVisible == false
            } && closeAccepted && local["closeStartsWithLiveStream"] == true
            diagnostics[mode.rawValue + ".closeAfter"] = [
                "running": note.model.running, "visible": note.window?.isVisible == true,
                "stopped": note.model.state == "已停止"
            ]
            let closed = note.model.output
            try? await Task.sleep(for: .milliseconds(950))
            local["closePreventsLateUpdates"] = note.model.output == closed
            note.window?.close()
            independent.window?.close()
            let expected = ["fixture-preset-A", "fixture-preset-B", "fixture-preset-B", "fixture-preset-C", "fixture-preset-B", "fixture-preset-C", "fixture-preset-C", "fixture-preset-A", "fixture-preset-A"]
            local["requestStartSequenceMatchesUserActions"] = starts == expected && sources.allSatisfy { $0 == "preset-switch-input" }
            diagnostics[mode.rawValue + ".startedInstructions"] = starts
            for (name, passed) in local { checks[mode.rawValue + "." + name] = passed }
        }
        var report: [String: Any] = checks
        report["passed"] = !checks.isEmpty && checks.values.allSatisfy { $0 }
        report["diagnostics"] = diagnostics
        report["scope"] = "Packaged NSPanel, native NSPopUpButton target/action and native retry/stop/close accessibility actions; both API modes against loopback SSE. No live API, selection, keychain, or saved settings. Menu tracking interaction is not exercised."
        do {
            try FileManager.default.createDirectory(at: reportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: reportURL, options: .atomic)
        } catch { fputs("Preset switch report: \(error.localizedDescription)\n", stderr) }
        if CommandLine.arguments.contains("--preset-switch-preview") {
            var configuration = Configuration(language: .simplifiedChinese)
            configuration.apiBaseURL = baseURL
            configuration.model = "test-model"
            configuration.presets = ["A", "B", "C"].enumerated().map { index, name in
                Preset(name: "Fixture " + name, prompt: "fixture-preset-" + name,
                       shortcut: Shortcut(keyCode: UInt32(18 + index), modifiers: 6144, label: "⌃⌥" + String(index + 1)))
            }
            let note = StickyWindow(preset: configuration.presets[1], source: "preset-switch-input", offset: 0)
            registerPreview?(note)
            note.configureProcessing(configuration: { configuration }, readKey: { "local-test-key" })
            note.updateConfiguration(configuration)
            previewSticky = note
            note.showWindow(nil)
            note.window?.makeKeyAndOrderFront(nil)
            note.window?.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
            note.model.retry?()
            _ = await waitFor { !note.model.running && note.model.output == "B first\nB complete" }
            return
        }
        NSApp.terminate(nil)
    }

    private static func waitFor(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<150 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }
    private static func popup(in view: NSView) -> NSPopUpButton? {
        if let button = view as? NSPopUpButton, button.accessibilityIdentifier() == "sticky.preset" { return button }
        return view.subviews.lazy.compactMap { popup(in: $0) }.first
    }
    private static func menuIDs(_ button: NSPopUpButton) -> [UUID] {
        button.menu?.items.compactMap { $0.representedObject as? UUID } ?? []
    }
    private static func select(_ id: UUID, in button: NSPopUpButton) -> Bool {
        guard let index = button.menu?.items.firstIndex(where: { $0.representedObject as? UUID == id && $0.isEnabled }),
              let action = button.action, button.isEnabled else { return false }
        button.selectItem(at: index)
        return NSApp.sendAction(action, to: button.target, from: button)
    }
    private static func element(in root: Any?, identifier: String) -> NSObject? {
        guard let object = root as? NSObject else { return nil }
        let idSelector = NSSelectorFromString("accessibilityIdentifier")
        if object.responds(to: idSelector), object.perform(idSelector)?.takeUnretainedValue() as? String == identifier { return object }
        let children = NSSelectorFromString("accessibilityChildren")
        guard object.responds(to: children), let items = object.perform(children)?.takeUnretainedValue() as? [Any] else { return nil }
        return items.lazy.compactMap { element(in: $0, identifier: identifier) }.first
    }
    private static func press(in root: Any?, identifier: String) async -> Bool {
        _ = await waitFor { element(in: root, identifier: identifier) != nil }
        guard let object = element(in: root, identifier: identifier) else { return false }
        let selector = NSSelectorFromString("accessibilityPerformPress")
        guard object.responds(to: selector) else { return false }
        typealias Action = @convention(c) (AnyObject, Selector) -> ObjCBool
        return unsafeBitCast(object.method(for: selector), to: Action.self)(object, selector).boolValue
    }
    private static func frame(_ object: NSObject) -> NSRect {
        let selector = NSSelectorFromString("accessibilityFrame")
        guard object.responds(to: selector) else { return .zero }
        typealias Frame = @convention(c) (AnyObject, Selector) -> NSRect
        return unsafeBitCast(object.method(for: selector), to: Frame.self)(object, selector)
    }
    private static func headerFits(_ note: StickyWindow, button: NSPopUpButton) -> Bool {
        guard let window = note.window else { return false }
        let selectorFrame = frame(button)
        let actions = ["sticky.copy", "sticky.arrow.uturn.backward", note.model.running ? "sticky.stop.fill" : "sticky.arrow.clockwise", "sticky.pin", "sticky.xmark"].compactMap {
            element(in: window, identifier: $0).map(frame)
        }
        return selectorFrame.width > 30 && selectorFrame.height > 15 && actions.count == 5 && actions.allSatisfy {
            $0.width >= 30 && $0.height >= 30 && window.frame.contains($0) && selectorFrame.maxX <= $0.minX + 1
        }
    }
    private static func snapshot(_ window: NSWindow?, url: URL) -> Bool {
        guard let view = window?.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return false }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return true
        } catch { return false }
    }
}

extension StickyPresetSwitchVerification {
    /// The production selection-to-note path, with an injected selection boundary and request sink.
    static func runManualInput(reportURL: URL,
        open: @escaping (Preset, @escaping () async throws -> String, @escaping () throws -> String,
               @escaping (StickyWindow, Configuration, String) -> Void) async throws -> StickyWindow) async {
        var checks: [String: Bool] = [:]
        var diagnostics: [String: Any] = [:]
        var errors: [String] = []
        var notes: [StickyWindow] = []
        if let index = CommandLine.arguments.firstIndex(of: "--fixture-app") {
            if CommandLine.arguments.indices.contains(index + 1) {
                let result = await verifyNativeAX(fixturePath: CommandLine.arguments[index + 1], reportURL: reportURL)
                checks.merge(result.checks) { _, new in new }
                diagnostics.merge(result.diagnostics) { _, new in new }
            } else {
                checks["nativeAX.fixtureArgumentIsValid"] = false
                diagnostics["nativeAX.error"] = "Missing --fixture-app path"
            }
        } else {
            diagnostics["nativeAX.included"] = false
        }
        let frontmostApplication = NSWorkspace.shared.frontmostApplication
        let frontmost = frontmostApplication?.processIdentifier
        var configuration = Configuration(language: .simplifiedChinese)
        configuration.model = "fixture-model"
        let a = configuration.presets[0], b = configuration.presets[1]
        var requests: [(String, UUID, String)] = []
        var keyReads = 0
        var rejectKey = false
        var missingKey = false
        let readKey: () throws -> String = {
            keyReads += 1
            if rejectKey { throw ValidationError("Fixture credential unavailable") }
            return missingKey ? "" : "fixture-key"
        }
        let start: (StickyWindow, Configuration, String) -> Void = { note, _, _ in
            requests.append((note.model.source, note.model.preset.id, note.model.preset.prompt))
            note.model.output = "Fixture result"
            note.model.error = nil
            note.model.running = false
        }
        let editReturn = await verifyEditReturnToResult(reportURL: reportURL)
        checks.merge(editReturn.checks) { _, new in new }
        diagnostics.merge(editReturn.diagnostics) { _, new in new }
        let copyFeedback = await verifyCopyFeedback()
        checks.merge(copyFeedback) { _, new in new }
        if let frontmostApplication {
            frontmostApplication.activate(options: [])
            checks["editReturn.restoresOriginalForegroundApplication"] = await waitFor {
                NSWorkspace.shared.frontmostApplication?.processIdentifier == frontmost
            }
        }
        // Hold selection open so this verifies the actual presentation boundary rather than
        // relying on how quickly a particular machine completes Accessibility/clipboard work.
        do {
            let previousWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
            var selectionContinuation: CheckedContinuation<String, Error>?
            var pendingKeyReads = 0
            var pendingRequests = 0
            let began = ProcessInfo.processInfo.systemUptime
            let pending = Task { @MainActor in
                try await open(a, {
                    try await withCheckedThrowingContinuation { selectionContinuation = $0 }
                }, {
                    pendingKeyReads += 1
                    return "fixture-key"
                }, { _, _, _ in pendingRequests += 1 })
            }
            let selectionStarted = await waitFor { selectionContinuation != nil }
            checks["pendingSelectionBoundaryReached"] = selectionStarted
            let becameVisible = await waitFor {
                NSApp.windows.contains { $0 is StickyPanel && $0.isVisible && !previousWindows.contains(ObjectIdentifier($0)) }
            }
            let pendingWindow = NSApp.windows.first {
                $0 is StickyPanel && $0.isVisible && !previousWindows.contains(ObjectIdentifier($0))
            }
            diagnostics["pendingSelectionMillisecondsToVisible"] =
                (ProcessInfo.processInfo.systemUptime - began) * 1000
            checks["pendingSelectionShowsWindowBeforeCaptureCompletes"] = becameVisible
            checks["pendingSelectionDoesNotStealKeyboardFocus"] = pendingWindow != nil &&
                pendingWindow?.isKeyWindow == false &&
                (pendingWindow?.firstResponder as? SettingsEditingTextView)?.accessibilityIdentifier() != "sticky.input"
            checks["pendingSelectionDoesNotReadCredentialsOrRequest"] = pendingKeyReads == 0 && pendingRequests == 0
            let pendingNote = pendingWindow?.windowController as? StickyWindow
            checks["pendingSelectionHasNoInputComponents"] = pendingNote.map {
                $0.model.capturingSelection && !$0.model.awaitingInput && input(in: $0.hostingView) == nil &&
                    element(in: $0.window, identifier: "sticky.submit") == nil
            } == true
            checks["pendingSelectionRemainsCompact"] = pendingWindow.map {
                abs($0.frame.height - StickyWindow.minimumHeight) <= 1
            } == true
            pendingWindow?.close()
            selectionContinuation?.resume(returning: "Late captured text after close")
            selectionContinuation = nil
            if selectionStarted {
                do {
                    let closed = try await pending.value
                    notes.append(closed)
                    checks["closingPendingSelectionPreventsLateRequest"] = pendingWindow != nil &&
                        pendingRequests == 0 && pendingKeyReads == 0 && closed.window?.isVisible == false
                    closed.window?.close()
                } catch is CancellationError {
                    checks["closingPendingSelectionPreventsLateRequest"] = pendingWindow != nil &&
                        pendingRequests == 0 && pendingKeyReads == 0 && pendingWindow?.isVisible == false
                }
            } else {
                pending.cancel()
                checks["closingPendingSelectionPreventsLateRequest"] = false
            }
        } catch { errors.append(String(describing: error)) }
        // Observe the published input mode while selection is gated. A successful capture
        // must never pass through input mode; an empty capture enters it exactly once.
        for (scenario, selection) in [("success", "Gated captured selection"), ("empty", " \n")] {
            do {
                let prefix = "gatedCapture." + scenario + "."
                let previousWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
                var selectionContinuation: CheckedContinuation<String, Error>?
                var scenarioKeyReads = 0
                var scenarioRequests: [String] = []
                let began = ProcessInfo.processInfo.systemUptime
                let pending = Task { @MainActor in
                    try await open(a, {
                        try await withCheckedThrowingContinuation { selectionContinuation = $0 }
                    }, {
                        scenarioKeyReads += 1
                        return "fixture-key"
                    }, { note, _, _ in scenarioRequests.append(note.model.source) })
                }
                let selectionStarted = await waitFor { selectionContinuation != nil }
                checks[prefix + "selectionBoundaryReached"] = selectionStarted
                let becameVisible = await waitFor {
                    NSApp.windows.contains { $0 is StickyPanel && $0.isVisible && !previousWindows.contains(ObjectIdentifier($0)) }
                }
                let pendingWindow = NSApp.windows.first {
                    $0 is StickyPanel && $0.isVisible && !previousWindows.contains(ObjectIdentifier($0))
                }
                let pendingNote = pendingWindow?.windowController as? StickyWindow
                diagnostics[prefix + "millisecondsToVisible"] = (ProcessInfo.processInfo.systemUptime - began) * 1000
                // Test top anchoring where expansion fits. A window opened beside the mouse
                // at the screen bottom may legitimately move up to keep its input visible.
                let placementBounds = pendingWindow?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
                diagnostics[prefix + "originalPendingFrame"] = pendingWindow.map { NSStringFromRect($0.frame) }
                if let pendingWindow, let placementBounds {
                    pendingWindow.setFrameTopLeftPoint(NSPoint(
                        x: placementBounds.midX - pendingWindow.frame.width / 2,
                        y: placementBounds.maxY - 20))
                }
                diagnostics[prefix + "placementVisibleFrame"] = placementBounds.map(NSStringFromRect)
                diagnostics[prefix + "topAnchorScope"] = "Controlled upper-screen placement with room for expansion"
                var inputModes: [Bool] = []
                let modeObservation = pendingNote?.model.$awaitingInput.removeDuplicates().sink { inputModes.append($0) }
                checks[prefix + "startsAsCompactOrdinaryNote"] = becameVisible && pendingNote.map {
                    $0.model.capturingSelection && !$0.model.awaitingInput && input(in: $0.hostingView) == nil &&
                        element(in: $0.window, identifier: "sticky.submit") == nil &&
                        abs(($0.window?.frame.height ?? 0) - StickyWindow.minimumHeight) <= 1
                } == true
                checks[prefix + "pendingScreenshotSaved"] = snapshot(pendingWindow,
                    url: reportURL.deletingLastPathComponent().appendingPathComponent("capture-\(scenario)-pending.png"))
                let initialFrame = pendingWindow?.frame
                diagnostics[prefix + "pendingHeight"] = initialFrame?.height
                diagnostics[prefix + "pendingFrame"] = initialFrame.map(NSStringFromRect)
                let resumed = ProcessInfo.processInfo.systemUptime
                selectionContinuation?.resume(returning: selection)
                selectionContinuation = nil
                if selectionStarted {
                    let completed = try await pending.value
                    notes.append(completed)
                    checks[prefix + "preservesWindowIdentity"] = pendingWindow != nil && completed.window === pendingWindow
                    if scenario == "success" {
                        checks[prefix + "startsRequestWithoutInputMode"] = scenarioRequests == [selection] && scenarioKeyReads == 1 &&
                            completed.model.source == selection && !completed.model.awaitingInput && !completed.model.capturingSelection
                        checks[prefix + "remainsCompactWithoutInputComponents"] = await waitFor {
                            input(in: completed.hostingView) == nil && element(in: completed.window, identifier: "sticky.submit") == nil &&
                                abs((completed.window?.frame.height ?? 0) - StickyWindow.minimumHeight) <= 1
                        }
                        checks[prefix + "neverFlashesInputMode"] = inputModes == [false]
                    } else {
                        checks[prefix + "entersInputOnlyAfterEmptyResult"] = await waitFor {
                            guard let editor = input(in: completed.hostingView) else { return false }
                            return completed.model.awaitingInput && !completed.model.capturingSelection &&
                                element(in: completed.window, identifier: "sticky.submit") != nil &&
                                completed.window?.firstResponder === editor && editor.isEditable && editor.isSelectable &&
                                inputLayoutFits(completed, editor: editor) &&
                                (completed.window?.frame.height ?? 0) > StickyWindow.minimumHeight
                        }
                        checks[prefix + "entersInputModeExactlyOnce"] = inputModes == [false, true]
                        checks[prefix + "emptyResultDoesNotReadCredentialsOrRequest"] = scenarioKeyReads == 0 && scenarioRequests.isEmpty
                    }
                    diagnostics[prefix + "millisecondsFromSelectionToReady"] =
                        (ProcessInfo.processInfo.systemUptime - resumed) * 1000
                    diagnostics[prefix + "inputModeTransitions"] = inputModes
                    diagnostics[prefix + "completedHeight"] = completed.window?.frame.height
                    diagnostics[prefix + "completedFrame"] = completed.window.map { NSStringFromRect($0.frame) }
                    checks[prefix + "controlledPlacementHasExpansionRoom"] = initialFrame.flatMap { initial in
                        placementBounds.map { visible in
                            initial.maxY - visible.minY >= (completed.window?.frame.height ?? .greatestFiniteMagnitude)
                        }
                    } == true
                    checks[prefix + "preservesTopAnchorWhenExpansionFits"] = initialFrame.map {
                        abs((completed.window?.frame.maxY ?? 0) - $0.maxY) <= 1
                    } == true
                    checks[prefix + "readyScreenshotSaved"] = snapshot(completed.window,
                        url: reportURL.deletingLastPathComponent().appendingPathComponent("capture-\(scenario)-ready.png"))
                    completed.window?.close()
                } else {
                    pending.cancel()
                    checks[prefix + "completed"] = false
                }
                modeObservation?.cancel()
            } catch { errors.append("Gated capture \(scenario): \(error)") }
        }
        do {
          var takeoverChecks: [String: Bool] = [:]
          var takeoverDiagnostics: [String: Any] = [:]
          do {
            let previousWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
            var selectionContinuation: CheckedContinuation<String, Error>?
            defer { selectionContinuation?.resume(returning: "Late captured text after user takeover") }
            var takeoverKeyReads = 0
            var takeoverRequests = 0
            let began = ProcessInfo.processInfo.systemUptime
            let pending = Task { @MainActor in
                try await open(a, {
                    try await withCheckedThrowingContinuation { selectionContinuation = $0 }
                }, {
                    takeoverKeyReads += 1
                    return "fixture-key"
                }, { _, _, _ in takeoverRequests += 1 })
            }
            let selectionStarted = await waitFor { selectionContinuation != nil }
            let becameVisible = await waitFor {
                NSApp.windows.contains { $0 is StickyPanel && $0.isVisible && !previousWindows.contains(ObjectIdentifier($0)) }
            }
            let pendingWindow = NSApp.windows.first {
                $0 is StickyPanel && $0.isVisible && !previousWindows.contains(ObjectIdentifier($0))
            }
            takeoverDiagnostics["takeoverMillisecondsToVisible"] = (ProcessInfo.processInfo.systemUptime - began) * 1000
            var gateHeld = true
            ClipboardAccessGate.shared.begin()
            defer { if gateHeld { ClipboardAccessGate.shared.end() } }
            defer { pendingWindow?.close() }
            let requested = ProcessInfo.processInfo.systemUptime
            pendingWindow?.makeKeyAndOrderFront(nil)
            takeoverChecks["pendingSelectionAllowsExplicitKeyboardTakeover"] = becameVisible && pendingWindow?.isKeyWindow == true
            let typedText = "Keep my manual input🙂\nsecond line"
            let draft = typedText + "\n"
            let pendingNote = pendingWindow?.windowController as? StickyWindow
            takeoverChecks["takeoverFocusesEditableInputBeforeSelectionCleanup"] = await waitFor {
                guard let pendingNote, let editor = input(in: pendingNote.hostingView) else { return false }
                return pendingNote.model.awaitingInput && pendingNote.model.capturingSelection &&
                    pendingWindow?.firstResponder === editor && editor.isEditable && editor.isSelectable
            }
            takeoverDiagnostics["takeoverMillisecondsFromRequestToEditableInput"] =
                (ProcessInfo.processInfo.systemUptime - requested) * 1000
            guard let pendingNote, let immediateEditor = input(in: pendingNote.hostingView) else {
                throw ValidationError("Missing immediate takeover editor")
            }
            immediateEditor.insertText(typedText, replacementRange: NSRange(location: 0, length: immediateEditor.string.utf16.count))
            let newlineDelivered = sendInputKey(to: pendingWindow, modifiers: [])
            takeoverChecks["takeoverAcceptsNativeTypingWhileSelectionPending"] = await waitFor { pendingNote.model.draft == draft }
            takeoverChecks["takeoverRoutesReturnToEditorBeforeSelectionCleanup"] = newlineDelivered && pendingNote.model.draft == draft
            let privateBoard = NSPasteboard(name: .init("BigBang.takeover.\(UUID().uuidString)"))
            defer { privateBoard.releaseGlobally() }
            privateBoard.setString("Private paste fixture", forType: .string)
            immediateEditor.setSelectedRange(NSRange(location: 0, length: immediateEditor.string.utf16.count))
            let generalCount = NSPasteboard.general.changeCount
            let privateCount = privateBoard.changeCount
            let beforeClipboard = immediateEditor.string
            let nativeWritableTypes = immediateEditor.writablePasteboardTypes
            guard let nativeWriteType = nativeWritableTypes.first else {
                throw ValidationError("Native editor provides no writable pasteboard type")
            }
            let untypedRead = immediateEditor.readSelection(from: privateBoard)
            let typedRead = immediateEditor.readSelection(from: privateBoard, type: .string)
            let typedWrite = immediateEditor.writeSelection(to: privateBoard, type: nativeWriteType)
            let multipleWrite = immediateEditor.writeSelection(to: privateBoard, types: nativeWritableTypes)
            immediateEditor.copy(nil)
            immediateEditor.cut(nil)
            immediateEditor.paste(nil)
            immediateEditor.pasteAsPlainText(nil)
            immediateEditor.pasteAsRichText(nil)
            takeoverChecks["clipboardProbeBlocksNativeActionsAndPrivateTransfers"] =
                !untypedRead && !typedRead && !typedWrite && !multipleWrite &&
                immediateEditor.string == beforeClipboard && privateBoard.changeCount == privateCount &&
                privateBoard.string(forType: .string) == "Private paste fixture" && NSPasteboard.general.changeCount == generalCount
            let editMenu = NSApp.mainMenu?.items.last?.submenu
            editMenu?.update()
            let clipboardItems = editMenu?.items.filter { ["c", "x", "v"].contains($0.keyEquivalent) } ?? []
            takeoverChecks["clipboardProbeDisablesEditMenuActions"] = clipboardItems.count == 3 && clipboardItems.allSatisfy { !$0.isEnabled }
            for item in clipboardItems {
                if let action = item.action { _ = NSApp.sendAction(action, to: item.target, from: item) }
            }
            takeoverChecks["clipboardProbeRejectsForcedEditMenuActions"] = immediateEditor.string == beforeClipboard &&
                NSPasteboard.general.changeCount == generalCount && privateBoard.changeCount == privateCount
            immediateEditor.setSelectedRange(NSRange(location: immediateEditor.string.utf16.count, length: 0))
            immediateEditor.setMarkedText("拼音中", selectedRange: NSRange(location: 3, length: 0),
                replacementRange: NSRange(location: NSNotFound, length: 0))
            let composedString = immediateEditor.string
            let composedRange = immediateEditor.markedRange()
            pendingNote.model.submit?()
            _ = sendInputKey(to: pendingWindow)
            takeoverChecks["takeoverDefersSubmissionUntilCaptureCleanup"] = !pendingNote.model.canSubmit &&
                takeoverKeyReads == 0 && takeoverRequests == 0 && pendingNote.model.source.isEmpty
            takeoverChecks["takeoverPreservesNativeCompositionWhileCapturePending"] = immediateEditor.hasMarkedText() &&
                immediateEditor.string == composedString && pendingNote.model.draft == draft
            takeoverChecks["takeoverPendingInputScreenshotSaved"] = snapshot(pendingWindow,
                url: reportURL.deletingLastPathComponent().appendingPathComponent("takeover-key-pending-input.png"))
            let resumed = ProcessInfo.processInfo.systemUptime
            ClipboardAccessGate.shared.end()
            gateHeld = false
            selectionContinuation?.resume(returning: "Late captured text after user takeover")
            selectionContinuation = nil
            if selectionStarted {
                let takenOver = try await pending.value
                notes.append(takenOver)
                takeoverChecks["takeoverIgnoresLateSelectionAndPreservesDraft"] = takenOver.model.awaitingInput &&
                    takenOver.model.source.isEmpty && takenOver.model.draft == draft &&
                    takeoverRequests == 0 && takeoverKeyReads == 0
                takeoverChecks["takeoverCleanupKeepsEditorAndComposition"] = input(in: takenOver.hostingView) === immediateEditor &&
                    immediateEditor.hasMarkedText() && immediateEditor.string == composedString &&
                    immediateEditor.markedRange() == composedRange && !takenOver.model.capturingSelection && takenOver.model.canSubmit
                takeoverChecks["takeoverFocusesInputAfterSelectionCleanup"] = await waitFor {
                    guard let editor = input(in: takenOver.hostingView) else { return false }
                    return takenOver.window?.firstResponder === editor
                }
                takeoverDiagnostics["takeoverMillisecondsFromSelectionCleanupToInputFocus"] =
                    (ProcessInfo.processInfo.systemUptime - resumed) * 1000
                takeoverChecks["takeoverReadyInputScreenshotSaved"] = snapshot(takenOver.window,
                    url: reportURL.deletingLastPathComponent().appendingPathComponent("takeover-key-ready-input.png"))
                immediateEditor.insertText(draft, replacementRange: NSRange(location: 0, length: immediateEditor.string.utf16.count))
                immediateEditor.setSelectedRange(NSRange(location: 0, length: immediateEditor.string.utf16.count))
                let pasteRestored = immediateEditor.readSelection(from: privateBoard)
                immediateEditor.didChangeText()
                takeoverChecks["clipboardProbeCompletionRestoresPrivatePaste"] = pasteRestored &&
                    immediateEditor.string == "Private paste fixture"
                immediateEditor.setSelectedRange(NSRange(location: 0, length: immediateEditor.string.utf16.count))
                // Cocoa's single-type primitive requires a declared native writable type;
                // a plain NSTextView advertises NSStringPboardType, not the modern .string UTI.
                let selectionBeforeWrite = immediateEditor.selectedRange()
                let stringBeforeWrite = immediateEditor.string
                privateBoard.declareTypes(nativeWritableTypes, owner: nil)
                let declaredTypes = privateBoard.types?.map(\.rawValue) ?? []
                let writeRestored = immediateEditor.writeSelection(to: privateBoard, type: nativeWriteType)
                let singleWrittenText = privateBoard.string(forType: .string)
                let multipleWriteRestored = immediateEditor.writeSelection(to: privateBoard, types: nativeWritableTypes)
                takeoverChecks["clipboardProbeCompletionRestoresPrivateSelectionWrite"] = writeRestored && multipleWriteRestored &&
                    singleWrittenText == "Private paste fixture" && privateBoard.string(forType: .string) == "Private paste fixture"
                takeoverDiagnostics["clipboardWriteRestoration"] = [
                    "nativeWritableTypes": nativeWritableTypes.map(\.rawValue), "singleWriteType": nativeWriteType.rawValue,
                    "declaredTypes": declaredTypes, "selectionBefore": NSStringFromRange(selectionBeforeWrite),
                    "selectionAfter": NSStringFromRange(immediateEditor.selectedRange()),
                    "editorStringBefore": stringBeforeWrite, "editorStringAfter": immediateEditor.string,
                    "singleWriteSucceeded": writeRestored, "multipleWriteSucceeded": multipleWriteRestored,
                    "singleWrittenText": singleWrittenText ?? "nil", "multipleWrittenText": privateBoard.string(forType: .string) ?? "nil",
                    "typesAfter": privateBoard.types?.map(\.rawValue) ?? []
                ]
                let copyAction = NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
                let cutAction = NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
                takeoverChecks["clipboardProbeCompletionRestoresNativeCopyCutValidation"] =
                    immediateEditor.validateUserInterfaceItem(copyAction) && immediateEditor.validateUserInterfaceItem(cutAction)
                takeoverChecks["clipboardProbeDoesNotQueueBlockedTransfers"] = NSPasteboard.general.changeCount == generalCount &&
                    takeoverKeyReads == 0 && takeoverRequests == 0
                let editor = input(in: takenOver.hostingView)
                let window = takenOver.window
                func nativeInputs(in view: NSView) -> [SettingsEditingTextView] {
                    let own = (view as? SettingsEditingTextView).map { [$0] } ?? []
                    return own + view.subviews.flatMap { nativeInputs(in: $0) }
                }
                let editors = nativeInputs(in: takenOver.hostingView)
                var focusDiagnostics: [String: Any] = [
                    "editorIdentity": editor.map { String(describing: ObjectIdentifier($0)) } ?? "nil",
                    "editorWindowNumber": editor?.window?.windowNumber ?? -1,
                    "editorWindowIdentity": editor?.window.map { String(describing: ObjectIdentifier($0)) } ?? "nil",
                    "editorHidden": editor?.isHidden ?? false,
                    "editorHasHiddenAncestor": editor?.isHiddenOrHasHiddenAncestor ?? false,
                    "editorIsEditable": editor?.isEditable ?? false,
                    "editorIsSelectable": editor?.isSelectable ?? false,
                    "editorWindowIsKey": editor?.window?.isKeyWindow ?? false,
                    "noteWindowNumber": window?.windowNumber ?? -1,
                    "noteWindowIdentity": window.map { String(describing: ObjectIdentifier($0)) } ?? "nil",
                    "noteWindowIsKey": window?.isKeyWindow ?? false,
                    "firstResponderClass": window?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil",
                    "firstResponderIdentity": window?.firstResponder.map { String(describing: ObjectIdentifier($0)) } ?? "nil",
                    "nativeInputCount": editors.count,
                    "identifiedInputCount": editors.filter { $0.accessibilityIdentifier() == "sticky.input" }.count
                ]
                if takeoverChecks["takeoverFocusesInputAfterSelectionCleanup"] == false {
                    focusDiagnostics["failureScreenshotSaved"] = snapshot(window,
                        url: reportURL.deletingLastPathComponent().appendingPathComponent("takeover-key-focus-failure.png"))
                }
                takeoverDiagnostics["takeoverFocus"] = focusDiagnostics
                if let window, let content = window.contentView {
                    // Exercise the app menu's real forwarding with a native responder that
                    // records delivery without reading or writing the user's clipboard.
                    let probe = NativeClipboardMenuProbe(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
                    content.addSubview(probe)
                    let clipboardCount = NSPasteboard.general.changeCount
                    let ownsResponder = window.makeFirstResponder(probe) && window.firstResponder === probe
                    takeoverChecks["unlockedEditMenuProbeOwnsResponder"] = window.isKeyWindow && ownsResponder
                    editMenu?.update()
                    takeoverChecks["unlockedEditMenuEnablesValidatedNativeActions"] = clipboardItems.count == 3 &&
                        clipboardItems.allSatisfy(\.isEnabled)
                    if ownsResponder {
                        for item in clipboardItems {
                            if let action = item.action { _ = NSApp.sendAction(action, to: item.target, from: item) }
                        }
                    }
                    takeoverChecks["unlockedEditMenuForwardsEachNativeActionOnce"] =
                        probe.copyCount == 1 && probe.cutCount == 1 && probe.pasteCount == 1 &&
                        NSPasteboard.general.changeCount == clipboardCount
                    probe.acceptsClipboardActions = false
                    editMenu?.update()
                    takeoverChecks["unlockedEditMenuHonorsNativeValidationRejection"] = clipboardItems.count == 3 &&
                        clipboardItems.allSatisfy { !$0.isEnabled }
                    takeoverDiagnostics["unlockedEditMenuProbeCounts"] = ["copy": probe.copyCount, "cut": probe.cutCount, "paste": probe.pasteCount]
                    takeoverChecks["unlockedEditMenuProbeRestoresEditor"] = window.makeFirstResponder(immediateEditor)
                    probe.removeFromSuperview()
                    editMenu?.update()
                }
                takenOver.window?.close()
            } else {
                pending.cancel()
                takeoverChecks["takeoverIgnoresLateSelectionAndPreservesDraft"] = false
                takeoverChecks["takeoverFocusesInputAfterSelectionCleanup"] = false
            }
          } catch { errors.append("Keyboard takeover: \(error)") }
          for (name, value) in takeoverChecks { checks[name] = value }
          for (name, value) in takeoverDiagnostics { diagnostics[name] = value }
        }
        do {
            rejectKey = true
            let began = ProcessInfo.processInfo.systemUptime
            let note = try await open(a, { throw ValidationError("Selection unavailable") }, readKey, start)
            notes.append(note)
            note.configureProcessing(configuration: { configuration }, readKey: readKey, start: start)
            checks["selectionFailureOpensDraftWithoutCredentialsOrRequest"] = note.model.awaitingInput &&
                note.model.source.isEmpty && note.model.draft.isEmpty && requests.isEmpty && keyReads == 0
            checks["panelRemainsNonactivating"] = note.window?.styleMask.contains(.nonactivatingPanel) == true &&
                NSWorkspace.shared.frontmostApplication?.processIdentifier == frontmost
            guard await waitFor({ input(in: note.hostingView) != nil }), let editor = input(in: note.hostingView) else {
                throw ValidationError("Missing manual input editor")
            }
            checks["inputOwnsKeyboardFocus"] = await waitFor { note.window?.firstResponder === editor && editor.isEditable && editor.isSelectable }
            diagnostics["emptySelectionMillisecondsToInputFocus"] = (ProcessInfo.processInfo.systemUptime - began) * 1000
            let returnSent = sendInputKey(to: note.window, modifiers: [])
            let newlineInserted = await waitFor { note.model.draft == "\n" }
            checks["plainReturnInsertsNewline"] = returnSent && newlineInserted && requests.isEmpty && keyReads == 0
            editor.insertText("", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
            _ = await waitFor { note.model.draft.isEmpty }
            checks["emptySubmissionIsDisabled"] = !note.model.canSubmit
            note.model.submit?()
            checks["emptySubmissionDoesNotReadCredentials"] = keyReads == 0 && requests.isEmpty
            editor.insertText(" \n\t", replacementRange: NSRange(location: 0, length: 0))
            _ = await waitFor { note.model.draft == " \n\t" }
            note.model.submit?()
            checks["whitespaceIsRejected"] = !note.model.canSubmit && keyReads == 0 && requests.isEmpty
            editor.insertText("", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
            editor.setMarkedText("中文", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: 0, length: 0))
            note.setLanguage(to: .english)
            _ = await waitFor { editor.accessibilityLabel() == "Type or paste text" }
            checks["languageSwitchPreservesComposition"] = editor.hasMarkedText() && editor.string == "中文" && note.model.draft.isEmpty
            note.model.submit?()
            checks["compositionDoesNotSubmit"] = requests.isEmpty && keyReads == 0
            editor.insertText("中文🙂\n", replacementRange: NSRange(location: NSNotFound, length: 0))
            _ = await waitFor { note.model.draft == "中文🙂\n" }
            let pasteboard = NSPasteboard(name: .init("BigBang.manual-input.\(UUID().uuidString)"))
            defer { pasteboard.releaseGlobally() }
            pasteboard.setString("  pasted text\n末尾  ", forType: .string)
            editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
            checks["nativePasteAccepted"] = editor.readSelection(from: pasteboard)
            // AppKit's paste primitive updates the text storage; publish as the responder paste action does.
            editor.didChangeText()
            let expected = "中文🙂\n  pasted text\n末尾  "
            checks["multilineUnicodePastePreserved"] = await waitFor { note.model.draft == expected }
            guard let button = popup(in: note.hostingView) else { throw ValidationError("Missing preset picker") }
            checks["draftPresetSwitchDoesNotProcess"] = select(b.id, in: button) && note.model.preset.id == b.id &&
                note.model.draft == expected && requests.isEmpty && keyReads == 0
            for (name, modifier) in [("shift", NSEvent.ModifierFlags.shift), ("control", .control), ("option", .option)] {
                let readsBefore = keyReads
                checks[name + "CommandReturnDoesNotSubmit"] = sendInputKey(to: note.window, modifiers: [.command, modifier]) &&
                    keyReads == readsBefore && requests.isEmpty && note.model.awaitingInput
            }
            editor.insertText(expected, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
            _ = await waitFor { note.model.draft == expected }
            checks["repeatedCommandReturnDoesNotSubmit"] = sendInputKey(to: note.window, isRepeat: true) &&
                keyReads == 0 && requests.isEmpty && note.model.awaitingInput
            editor.setMarkedText("拼音", selectedRange: NSRange(location: 2, length: 0),
                replacementRange: NSRange(location: editor.string.utf16.count, length: 0))
            checks["commandReturnDuringCompositionDoesNotSubmitOldDraft"] = sendInputKey(to: note.window) &&
                requests.isEmpty && keyReads == 0 && note.model.awaitingInput
            editor.insertText(expected, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
            _ = await waitFor { note.model.draft == expected }
            checks["inputAndSubmitFitVisiblePanel"] = await waitFor {
                guard let window = note.window,
                      let submit = element(in: window, identifier: "sticky.submit") else { return false }
                return window.frame.height > 280 && window.frame.contains(frame(submit))
            }
            checks["inputScreenshotSaved"] = snapshot(note.window, url: reportURL.deletingLastPathComponent().appendingPathComponent("manual-input.png"))
            let originalLanguage = note.model.language
            let originalAppearance = note.window?.appearance
            for language in AppLanguage.allCases {
                note.setLanguage(to: language)
                for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                    note.window?.appearance = NSAppearance(named: appearance)
                    let key = language.rawValue + "." + appearance.rawValue
                    let labelReady = await waitFor { editor.accessibilityLabel() == L10n.string("输入或粘贴文本", language: language) }
                    // Give SwiftUI's language/appearance change and panel sizing a layout pass.
                    try? await Task.sleep(for: .milliseconds(150))
                    note.hostingView.layoutSubtreeIfNeeded()
                    checks[key + ".inputAndSubmitVisible"] = labelReady && inputLayoutFits(note, editor: editor)
                    checks[key + ".draftAndFocusPreserved"] = editor.string == expected &&
                        note.model.draft == expected && note.window?.firstResponder === editor
                    checks[key + ".screenshotSaved"] = snapshot(note.window,
                        url: reportURL.deletingLastPathComponent().appendingPathComponent("manual-input-\(key).png"))
                }
            }
            note.setLanguage(to: originalLanguage)
            note.window?.appearance = originalAppearance
            _ = await waitFor { editor.accessibilityLabel() == L10n.string("输入或粘贴文本", language: originalLanguage) }
            let readsBeforeShortcut = keyReads
            checks["commandReturnReachesSubmitAndRetainsDraftOnCredentialFailure"] = sendInputKey(to: note.window) &&
                keyReads == readsBeforeShortcut + 1 && note.model.awaitingInput && note.model.draft == expected && requests.isEmpty
            let readsBeforeKeypad = keyReads
            checks["commandKeypadEnterReachesSubmit"] = sendInputKey(to: note.window, keyCode: 76) &&
                keyReads == readsBeforeKeypad + 1 && note.model.awaitingInput && note.model.draft == expected && requests.isEmpty
            let submitted = await press(in: note.window, identifier: "sticky.submit")
            checks["credentialFailureRetainsDraft"] = submitted && note.model.awaitingInput && note.model.draft == expected &&
                note.model.error != nil && requests.isEmpty && note.model.source.isEmpty
            rejectKey = false; missingKey = true
            note.model.submit?()
            checks["missingCredentialRetainsDraft"] = note.model.awaitingInput && note.model.draft == expected && requests.isEmpty
            missingKey = false
            editor.insertText(String(repeating: "中", count: 33_334), replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
            _ = await waitFor { note.model.draft.utf8.count > 100_000 }
            editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
            editor.scrollRangeToVisible(editor.selectedRange())
            checks["longInputScrollsInsideEditorAndKeepsSubmitVisible"] = await waitFor {
                guard let scroll = editor.enclosingScrollView, let window = note.window,
                      let submit = element(in: window, identifier: "sticky.submit") else { return false }
                return editor.bounds.height > scroll.contentView.bounds.height + 100 &&
                    scroll.documentVisibleRect.maxY >= editor.bounds.maxY - 25 && window.frame.contains(frame(submit))
            }
            let readsBeforeLimit = keyReads
            note.model.submit?()
            checks["utf8LimitRetainsInputWithoutRequest"] = note.model.awaitingInput && requests.isEmpty &&
                keyReads == readsBeforeLimit && note.model.error?.contains("100 KB") == true
            editor.insertText(expected, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
            _ = await waitFor { note.model.draft == expected }
            configuration.presets[1].prompt = "Latest saved prompt"
            checks["nativeSubmitProcessesSelectedPreset"] = sendInputKey(to: note.window) &&
                requests.count == 1 && requests.first?.0 == expected && requests.first?.1 == b.id &&
                requests.first?.2 == "Latest saved prompt" && !note.model.awaitingInput && note.model.source == expected
            _ = await waitFor { input(in: note.hostingView) == nil }
            checks["resultReplacesInputEditor"] = input(in: note.hostingView) == nil && note.model.output == "Fixture result"
            note.model.retry?()
            checks["retryRetainsSubmittedInput"] = requests.count == 2 && requests.last?.0 == expected
            note.model.selectPreset?(a.id)
            checks["resultPresetSwitchRetainsSubmittedInput"] = requests.count == 3 && requests.last?.0 == expected && requests.last?.1 == a.id
            let captured = try await open(a, { "Captured selection" }, readKey, start)
            notes.append(captured)
            checks["capturedSelectionStillStartsImmediately"] = !captured.model.awaitingInput &&
                requests.count == 4 && requests.last?.0 == "Captured selection"
            let beforeBlank = requests.count
            let blank = try await open(a, { " \n" }, readKey, start)
            notes.append(blank)
            checks["emptyCaptureOpensIndependentDraft"] = blank.model.awaitingInput && blank.model.draft.isEmpty && requests.count == beforeBlank
            blank.window?.close()
            checks["closingDraftMakesNoRequest"] = requests.count == beforeBlank && !blank.model.running
            // Edit a completed result through its native action, preserving the submitted
            // text until a replacement passes the same submission checks as manual input.
            let editing = StickyWindow(preset: b, source: expected, offset: 0)
            notes.append(editing)
            var editedRequests: [(String, UUID, String)] = []
            var editKeyReads = 0
            var rejectEditKey = false
            editing.configureProcessing(configuration: { configuration }, readKey: {
                editKeyReads += 1
                if rejectEditKey { throw ValidationError("Fixture credential unavailable") }
                return "fixture-key"
            }, start: { note, _, _ in
                editedRequests.append((note.model.source, note.model.preset.id, note.model.preset.prompt))
                note.model.output = "Replacement fixture result"
                note.model.error = nil
                note.model.running = false
            })
            editing.showWindow(nil)
            editing.model.retry?()
            let originalWindow = editing.window
            let readsBeforeEdit = editKeyReads
            checks["editNativeActionReturnsToInput"] = await press(in: editing.window, identifier: "sticky.arrow.uturn.backward")
            guard await waitFor({ input(in: editing.hostingView) != nil }), let editView = input(in: editing.hostingView) else {
                throw ValidationError("Missing returned input editor")
            }
            checks["editRestoresExactSubmittedTextAndFocus"] = await waitFor {
                editView.string == expected && editing.model.draft == expected && editing.window?.firstResponder === editView
            }
            checks["editPreservesWindowPresetAndSourceWithoutRequest"] = editing.window === originalWindow &&
                editing.model.preset.id == b.id && editing.model.source == expected &&
                editedRequests.count == 1 && editKeyReads == readsBeforeEdit && editing.model.output.isEmpty && editing.model.error == nil
            checks["editHidesResultActionsAndFitsInput"] = await waitFor {
                element(in: editing.window, identifier: "sticky.arrow.uturn.backward") == nil &&
                    element(in: editing.window, identifier: "sticky.arrow.clockwise") == nil && inputLayoutFits(editing, editor: editView)
            }
            let edited = "  修改后的问题🙂\nSecond submission  "
            editView.insertText(edited, replacementRange: NSRange(location: 0, length: editView.string.utf16.count))
            _ = await waitFor { editing.model.draft == edited }
            rejectEditKey = true
            _ = await press(in: editing.window, identifier: "sticky.submit")
            checks["editFailedSubmissionRetainsDraftAndOriginalSource"] = editing.model.awaitingInput &&
                editing.model.draft == edited && editing.model.source == expected && editing.model.preset.id == b.id &&
                editing.model.error != nil && editedRequests.count == 1
            rejectEditKey = false
            configuration.presets[1].prompt = "Latest edited submission prompt"
            checks["editCommandReturnResubmitsCurrentPresetAndLatestPrompt"] = sendInputKey(to: editing.window) &&
                editedRequests.count == 2 && editedRequests.last?.0 == edited && editedRequests.last?.1 == b.id &&
                editedRequests.last?.2 == "Latest edited submission prompt" && editing.model.source == edited && !editing.model.awaitingInput
            _ = await waitFor { input(in: editing.hostingView) == nil }
            checks["editRetryUsesReplacementSource"] = await press(in: editing.window, identifier: "sticky.arrow.clockwise") &&
                editedRequests.count == 3 && editedRequests.last?.0 == edited
            for language in AppLanguage.allCases {
                editing.setLanguage(to: language)
                checks["editActionLocalized." + language.rawValue] = await waitFor {
                    guard let action = element(in: editing.window, identifier: "sticky.arrow.uturn.backward") else { return false }
                    let selector = NSSelectorFromString("accessibilityLabel")
                    guard action.responds(to: selector) else { return false }
                    return action.perform(selector)?.takeUnretainedValue() as? String == L10n.string("回退并编辑", language: language)
                }
            }
            checks["editSecondReturnUsesLatestSubmission"] = await press(in: editing.window, identifier: "sticky.arrow.uturn.backward") &&
                editing.model.draft == edited && editedRequests.count == 3
            _ = await waitFor {
                guard let editor = input(in: editing.hostingView) else { return false }
                return inputLayoutFits(editing, editor: editor)
            }
            checks["editScreenshotSaved"] = snapshot(editing.window,
                url: reportURL.deletingLastPathComponent().appendingPathComponent("returned-input.png"))
            editing.window?.close()
            checks["editClosingDraftDoesNotResubmit"] = editedRequests.count == 3 && !editing.model.running
            if let index = CommandLine.arguments.firstIndex(of: "--test-base-url"), CommandLine.arguments.count > index + 1,
               let url = URL(string: CommandLine.arguments[index + 1]), url.scheme == "http", url.host == "127.0.0.1" {
                for mode in APIMode.allCases {
                    var localConfiguration = configuration
                    localConfiguration.apiBaseURL = url.absoluteString
                    localConfiguration.apiMode = mode
                    let streamed = StickyWindow(preset: a, source: "", offset: 0)
                    notes.append(streamed)
                    streamed.configureProcessing(configuration: { localConfiguration }, readKey: { "fixture-key" })
                    streamed.showWindow(nil)
                    streamed.model.draft = "手动输入🙂\n loopback text "
                    streamed.model.submit?()
                    checks[mode.rawValue + ".manualInputCompletesRealStream"] = await waitFor {
                        !streamed.model.running && streamed.model.output == "你好 🌍\n流式完成" && streamed.model.error == nil
                    }
                    streamed.model.retry?()
                    checks[mode.rawValue + ".retryKeepsManualSource"] = await waitFor {
                        !streamed.model.running && streamed.model.output == "你好 🌍\n流式完成" &&
                            streamed.model.source == "手动输入🙂\n loopback text "
                    }
                    checks[mode.rawValue + ".completedStreamReturnsToEditor"] = await press(in: streamed.window, identifier: "sticky.arrow.uturn.backward")
                    guard await waitFor({ input(in: streamed.hostingView) != nil }), let returned = input(in: streamed.hostingView) else {
                        throw ValidationError("Missing loopback input editor")
                    }
                    returned.insertText("cancel", replacementRange: NSRange(location: 0, length: returned.string.utf16.count))
                    _ = await waitFor { streamed.model.draft == "cancel" }
                    streamed.model.submit?()
                    checks[mode.rawValue + ".editCancellationStartsRealStream"] = await waitFor {
                        streamed.model.running && !streamed.model.output.isEmpty
                    }
                    checks[mode.rawValue + ".runningStreamReturnsToEditor"] = await press(in: streamed.window, identifier: "sticky.arrow.uturn.backward")
                    _ = await waitFor { input(in: streamed.hostingView) != nil }
                    try? await Task.sleep(for: .milliseconds(350))
                    checks[mode.rawValue + ".editCancelsOldStreamWithoutLateUpdates"] = streamed.model.awaitingInput &&
                        !streamed.model.running && streamed.model.output.isEmpty && streamed.model.error == nil &&
                        streamed.model.source == "cancel" && streamed.model.draft == "cancel"
                    guard let replacement = input(in: streamed.hostingView) else { throw ValidationError("Missing replacement editor") }
                    replacement.insertText("preset-switch-input", replacementRange: NSRange(location: 0, length: replacement.string.utf16.count))
                    _ = await waitFor { streamed.model.draft == "preset-switch-input" }
                    localConfiguration.presets[0].prompt = "fixture-preset-B"
                    checks[mode.rawValue + ".editResubmitsThroughNativeKeyboard"] = sendInputKey(to: streamed.window)
                    checks[mode.rawValue + ".editReplacementStreamUsesNewInputAndPrompt"] = await waitFor {
                        !streamed.model.running && streamed.model.output == "B first\nB complete" &&
                            streamed.model.source == "preset-switch-input" && streamed.model.preset.id == a.id && streamed.model.error == nil
                    }
                    streamed.window?.close()
                }
            }
        } catch { errors.append(String(describing: error)) }
        for note in notes { note.window?.close() }
        let report: [String: Any] = ["passed": !checks.isEmpty && checks.values.allSatisfy { $0 } && errors.isEmpty,
            "checks": checks, "errors": errors, "requestCount": requests.count,
            "diagnostics": diagnostics,
            "scope": "Packaged nonactivating panel; production selection-to-note path with injected selection failures and request sink; native editor composition, private-pasteboard paste, accessibility submit/cancel-edit and NSApp.sendEvent keyboard routing. Cancel-edit verifies restored result snapshots and stopped-stream isolation. Copy feedback uses deterministic published output deltas; the general clipboard is fully materialized by item/type before copying and restored byte-for-byte only if no external write is detected. An explicitly supplied loopback endpoint additionally exercises both real streaming API clients. Conditional nativeAX checks run only with --fixture-app: real AX-only SelectionReader against an owned foreground ExternalSelectionFixture, without sending copy. No live model, Keychain access, global hotkey registration or settings writes. Installed IME candidate UI and physical hotkey are not exercised."]
        do {
            try FileManager.default.createDirectory(at: reportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: reportURL, options: .atomic)
        } catch { fputs("Manual input report: \(error.localizedDescription)\n", stderr) }
        NSApp.terminate(nil)
    }

    private static func verifyNativeAX(fixturePath: String, reportURL: URL) async ->
        (checks: [String: Bool], diagnostics: [String: Any]) {
        var checks: [String: Bool] = [:]
        var diagnostics: [String: Any] = ["nativeAX.included": true, "nativeAX.trusted": SelectionReader.isTrusted]
        let fixtureURL = URL(fileURLWithPath: fixturePath)
        guard fixturePath.hasPrefix("/"), let bundle = Bundle(url: fixtureURL),
              bundle.bundleIdentifier == "local.bigbang.external-selection-fixture",
              bundle.object(forInfoDictionaryKey: "CFBundleExecutable") as? String == "ExternalSelectionFixture" else {
            return (["nativeAX.fixtureArgumentIsValid": false],
                    ["nativeAX.included": true, "nativeAX.error": "Expected the owned external selection fixture bundle"])
        }
        checks["nativeAX.fixtureArgumentIsValid"] = true
        let previousFrontmost = NSWorkspace.shared.frontmostApplication
        let readyURL = reportURL.deletingLastPathComponent()
            .appendingPathComponent("native-ax-fixture-ready-\(UUID().uuidString).json")
        let fixture = Process()
        fixture.executableURL = fixtureURL.appendingPathComponent("Contents/MacOS/ExternalSelectionFixture")
        fixture.arguments = ["--ready", readyURL.path]
        var launched = false
        do {
            try FileManager.default.createDirectory(at: readyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fixture.run()
            launched = true
            diagnostics["nativeAX.fixturePID"] = fixture.processIdentifier
            diagnostics["nativeAX.readyReport"] = readyURL.path
            let ready = await waitFor {
                guard let data = try? Data(contentsOf: readyURL),
                      let report = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
                return report["ready"] as? Bool == true &&
                    (report["pid"] as? NSNumber)?.int32Value == fixture.processIdentifier &&
                    NSWorkspace.shared.frontmostApplication?.processIdentifier == fixture.processIdentifier
            }
            checks["nativeAX.fixtureBecameReadyAndFrontmost"] = ready
            if ready {
                let began = ProcessInfo.processInfo.systemUptime
                defer { diagnostics["nativeAX.millisecondsToRead"] = (ProcessInfo.processInfo.systemUptime - began) * 1000 }
                let selection = try await SelectionReader.read(copyFallback: false)
                checks["nativeAX.realSelectionMatchesFixture"] = selection == "外部原始选区"
                diagnostics["nativeAX.selectionUTF8Bytes"] = selection.utf8.count
            } else {
                checks["nativeAX.realSelectionMatchesFixture"] = false
            }
        } catch {
            checks["nativeAX.realSelectionMatchesFixture"] = false
            diagnostics["nativeAX.error"] = String(describing: error)
        }
        if launched {
            if fixture.isRunning { fixture.terminate() }
            checks["nativeAX.ownedFixtureTerminated"] = await waitFor { !fixture.isRunning }
        }
        if let previousFrontmost {
            previousFrontmost.activate(options: [])
            checks["nativeAX.previousFrontmostRestored"] = await waitFor {
                NSWorkspace.shared.frontmostApplication?.processIdentifier == previousFrontmost.processIdentifier
            }
        }
        return (checks, diagnostics)
    }

    private static func input(in view: NSView) -> SettingsEditingTextView? {
        if let text = view as? SettingsEditingTextView, text.accessibilityIdentifier() == "sticky.input" { return text }
        return view.subviews.lazy.compactMap { input(in: $0) }.first
    }

    /// Independent snapshots keep cancellation assertions from depending on earlier fixture edits.
    private static func verifyEditReturnToResult(reportURL: URL) async ->
        (checks: [String: Bool], diagnostics: [String: Any]) {
        var checks: [String: Bool] = [:]
        var diagnostics: [String: Any] = [:]
        for language in AppLanguage.allCases {
            let prefix = "editReturn." + language.rawValue + "."
            let configuration = Configuration(language: language)
            let original = configuration.presets[0], alternative = configuration.presets[1]
            let source = "  Original question🙂\n原始问题  "
            let output = "Original result\n原始结果"
            let originalError = "Fixture retained error"
            let note = StickyWindow(preset: original, source: source, offset: 0)
            defer { note.window?.close() }
            var requests = 0, reads = 0
            var rejectKey = true
            note.configureProcessing(configuration: { configuration }, readKey: {
                reads += 1
                if rejectKey { throw ValidationError("Fixture credential unavailable") }
                return "fixture-key"
            }, start: { sticky, _, _ in
                requests += 1
                sticky.model.output = "New submitted result"
                sticky.model.error = nil
                sticky.model.state = "已完成"
                sticky.model.running = false
            })
            note.updateConfiguration(configuration)
            note.model.output = output
            note.model.error = originalError
            note.model.state = "请求失败"
            note.model.autoScroll = false
            note.showWindow(nil)
            note.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            checks[prefix + "opensEditor"] = await press(in: note.window, identifier: "sticky.arrow.uturn.backward")
            guard await waitFor({ input(in: note.hostingView) != nil }), let editor = input(in: note.hostingView) else {
                checks[prefix + "editorAvailable"] = false
                continue
            }
            editor.insertText("Discard this unsubmitted draft", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
            _ = await waitFor { note.model.draft == "Discard this unsubmitted draft" }
            let switched = popup(in: note.hostingView).map { select(alternative.id, in: $0) } == true
            checks[prefix + "draftPresetChangeDoesNotReadOrRequest"] = switched &&
                note.model.preset.id == alternative.id && reads == 0 && requests == 0
            let failedSubmission = await press(in: note.window, identifier: "sticky.submit")
            checks[prefix + "credentialFailureRemainsEditable"] = failedSubmission && reads == 1 && requests == 0 &&
                note.model.awaitingInput && note.model.error != nil
            // Input AX children can appear before the deferred panel resize runs. Wait for
            // visible controls and stable geometry rather than measuring the old result frame.
            var previousGeometry: [NSRect] = []
            var stableLayouts = 0
            checks[prefix + "cancelLabelAndLayout"] = await waitFor {
                note.hostingView.layoutSubtreeIfNeeded()
                guard let window = note.window,
                      let cancel = element(in: window, identifier: "sticky.cancel-edit"),
                      let submit = element(in: window, identifier: "sticky.submit"),
                      let scroll = editor.enclosingScrollView else { return false }
                let inputFrame = window.convertToScreen(scroll.convert(scroll.bounds, to: nil))
                let cancelFrame = frame(cancel), submitFrame = frame(submit)
                let geometry = [window.frame, inputFrame, cancelFrame, submitFrame]
                stableLayouts = geometry == previousGeometry ? stableLayouts + 1 : 0
                previousGeometry = geometry
                return stableLayouts >= 3 &&
                    accessibilityLabel(cancel) == (language == .english ? "Back to Result" : "返回结果") &&
                    window.frame.contains(cancelFrame) && cancelFrame.width >= 50 && cancelFrame.height >= 20 &&
                    inputLayoutFits(note, editor: editor)
            }
            let cancel = element(in: note.window, identifier: "sticky.cancel-edit")
            let scrollFrame = editor.enclosingScrollView.flatMap { scroll in
                note.window.map { $0.convertToScreen(scroll.convert(scroll.bounds, to: nil)) }
            }
            diagnostics[prefix + "inputLayout"] = [
                "windowFrame": note.window.map { NSStringFromRect($0.frame) } ?? "nil",
                "editorFrame": note.window.map { NSStringFromRect($0.convertToScreen(editor.convert(editor.bounds, to: nil))) } ?? "nil",
                "editorScrollFrame": scrollFrame.map(NSStringFromRect) ?? "nil",
                "cancelFrame": cancel.map { NSStringFromRect(frame($0)) } ?? "nil",
                "cancelLabel": cancel.flatMap(accessibilityLabel) ?? "nil",
                "submitFrame": element(in: note.window, identifier: "sticky.submit").map { NSStringFromRect(frame($0)) } ?? "nil",
                "stableLayoutPolls": stableLayouts
            ]
            checks[prefix + "inputScreenshotSaved"] = snapshot(note.window,
                url: reportURL.deletingLastPathComponent().appendingPathComponent("edit-return-\(language.rawValue).png"))
            let cancelled = cancel != nil ? await press(in: note.window, identifier: "sticky.cancel-edit") : false
            checks[prefix + "cancelRestoresCompleteOriginalSnapshot"] = cancelled && !note.model.awaitingInput &&
                note.model.source == source && note.model.preset == original && note.model.output == output &&
                note.model.error == originalError && note.model.state == "请求失败" && !note.model.autoScroll && !note.model.running
            checks[prefix + "cancelDoesNotReadCredentialsOrRequest"] = cancelled && reads == 1 && requests == 0
            let resultReady = await waitFor {
                input(in: note.hostingView) == nil && element(in: note.window, identifier: "sticky.arrow.clockwise") != nil &&
                    element(in: note.window, identifier: "sticky.cancel-edit") == nil
            }
            checks[prefix + "resultActionsReturn"] = cancelled && resultReady
            guard cancelled else { continue }
            _ = await press(in: note.window, identifier: "sticky.arrow.uturn.backward")
            checks[prefix + "reopeningDiscardsCancelledDraft"] = await waitFor {
                note.model.draft == source && input(in: note.hostingView)?.string == source
            }
            guard let replacement = input(in: note.hostingView) else { continue }
            let newSource = "New submitted question🙂"
            replacement.insertText(newSource, replacementRange: NSRange(location: 0, length: replacement.string.utf16.count))
            _ = await waitFor { note.model.draft == newSource }
            rejectKey = false
            _ = await press(in: note.window, identifier: "sticky.submit")
            checks[prefix + "successfulSubmissionCreatesNewResult"] = requests == 1 && reads == 2 &&
                note.model.source == newSource && note.model.output == "New submitted result" && !note.model.awaitingInput
            _ = await press(in: note.window, identifier: "sticky.arrow.uturn.backward")
            _ = await waitFor { input(in: note.hostingView) != nil }
            let cancelledNew = await press(in: note.window, identifier: "sticky.cancel-edit")
            checks[prefix + "nextCancelRestoresNewSubmission"] = cancelledNew && !note.model.awaitingInput &&
                note.model.source == newSource && note.model.output == "New submitted result" && note.model.error == nil &&
                note.model.state == "已完成" && requests == 1 && reads == 2
            diagnostics[prefix + "requests"] = requests
            diagnostics[prefix + "credentialReads"] = reads
        }
        let empty = StickyWindow(preset: Preset.defaults[0], source: "", offset: 0)
        empty.showWindow(nil)
        _ = await waitFor { input(in: empty.hostingView) != nil }
        checks["editReturn.initialEmptyInputHasNoReturnAction"] = empty.model.awaitingInput &&
            element(in: empty.window, identifier: "sticky.cancel-edit") == nil
        empty.window?.close()
        if let index = CommandLine.arguments.firstIndex(of: "--test-base-url"), CommandLine.arguments.count > index + 1,
           let url = URL(string: CommandLine.arguments[index + 1]), url.scheme == "http", url.host == "127.0.0.1" {
            for mode in APIMode.allCases {
                let prefix = "editReturn.streaming." + mode.rawValue + "."
                let original = Preset(name: "Slow fixture", prompt: "fixture-preset-A", shortcut: Preset.defaults[0].shortcut)
                let alternative = Preset(name: "Other fixture", prompt: "fixture-preset-B", shortcut: Preset.defaults[1].shortcut)
                var configuration = Configuration(language: .simplifiedChinese)
                configuration.apiBaseURL = url.absoluteString
                configuration.apiMode = mode
                configuration.model = "test-model"
                configuration.presets = [original, alternative]
                let note = StickyWindow(preset: original, source: "preset-switch-input", offset: 0)
                defer { note.window?.close() }
                var reads = 0, starts = 0
                note.configureProcessing(configuration: { configuration }, readKey: { reads += 1; return "fixture-key" },
                    start: { sticky, config, key in
                        starts += 1
                        sticky.model.start(configuration: config, key: key)
                    })
                note.updateConfiguration(configuration)
                note.showWindow(nil)
                note.model.retry?()
                checks[prefix + "slowStreamStarts"] = await waitFor { note.model.running && note.model.output == "A first" }
                let partial = note.model.output
                let edited = await press(in: note.window, identifier: "sticky.arrow.uturn.backward")
                _ = await waitFor { input(in: note.hostingView) != nil }
                if let editor = input(in: note.hostingView) {
                    editor.insertText("Unsubmitted running edit", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
                }
                let switched = popup(in: note.hostingView).map { select(alternative.id, in: $0) } == true
                checks[prefix + "editingStopsStreamWithoutRequest"] = edited && switched &&
                    note.model.awaitingInput && !note.model.running && starts == 1 && reads == 1
                let cancelled = element(in: note.window, identifier: "sticky.cancel-edit") != nil ?
                    await press(in: note.window, identifier: "sticky.cancel-edit") : false
                checks[prefix + "cancelRestoresStoppedPartialOutput"] = cancelled && !note.model.awaitingInput &&
                    !note.model.running && note.model.output == partial && partial == "A first" &&
                    note.model.state == "已停止" && note.model.preset == original && note.model.source == "preset-switch-input"
                try? await Task.sleep(for: .milliseconds(1400))
                checks[prefix + "lateStreamCannotMutateRestoredResult"] = cancelled && note.model.output == partial &&
                    note.model.state == "已停止" && !note.model.running && note.model.error == nil && starts == 1 && reads == 1
                diagnostics[prefix + "starts"] = starts
            }
        }
        return (checks, diagnostics)
    }

    private static func accessibilityLabel(_ object: NSObject) -> String? {
        let selector = NSSelectorFromString("accessibilityLabel")
        guard object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue() as? String
    }

    /// Copy feedback is a view boundary: deterministic published stream deltas avoid the
    /// 1.5 second confirmation timeout masking whether a new delta clears the confirmation.
    private static func verifyCopyFeedback() async -> [String: Bool] {
        var checks: [String: Bool] = [:]
        let board = NSPasteboard.general
        let initialCount = board.changeCount
        var saved: [[NSPasteboard.PasteboardType: Data]] = []
        // Materialize every representation before mutating the shared clipboard. An unreadable
        // promised type or concurrent external write makes this fixture read-only.
        for item in board.pasteboardItems ?? [] {
            var representations: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                guard let data = item.data(forType: type) else {
                    return ["copyFeedback.clipboardSnapshotComplete": false]
                }
                representations[type] = data
            }
            saved.append(representations)
        }
        checks["copyFeedback.clipboardSnapshotComplete"] = board.changeCount == initialCount
        guard board.changeCount == initialCount else { return checks }
        var ownedCount = initialCount
        var expectedClipboard: String?
        var externalChange = false
        for language in AppLanguage.allCases {
            let prefix = "copyFeedback." + language.rawValue + "."
            let note = StickyWindow(preset: Preset.defaults[0], source: "Copy fixture", offset: 0)
            defer { note.window?.close() }
            note.setLanguage(to: language)
            note.model.running = true
            note.model.output = "First streamed fragment"
            note.showWindow(nil)
            _ = await waitFor { element(in: note.window, identifier: "sticky.copy") != nil }
            guard board.changeCount == ownedCount else { externalChange = true; break }
            let copied = await press(in: note.window, identifier: "sticky.copy")
            ownedCount = board.changeCount
            expectedClipboard = "First streamed fragment"
            checks[prefix + "copyTakesClickTimeSnapshot"] = copied && board.string(forType: .string) == expectedClipboard
            checks[prefix + "copyConfirmsInCurrentLanguage"] = await waitFor {
                element(in: note.window, identifier: "sticky.copy").flatMap(accessibilityLabel) ==
                    L10n.string("已复制", language: language)
            }
            let changedAt = ProcessInfo.processInfo.systemUptime
            note.model.output += "\nLater streamed fragment"
            // Allow a normal SwiftUI update, while keeping the deadline well below feedback expiry.
            for _ in 0..<20 {
                if element(in: note.window, identifier: "sticky.copy").flatMap(accessibilityLabel) == L10n.string("复制", language: language) { break }
                try? await Task.sleep(for: .milliseconds(20))
            }
            checks[prefix + "newStreamDeltaClearsCopyConfirmation"] =
                ProcessInfo.processInfo.systemUptime - changedAt < 0.8 &&
                element(in: note.window, identifier: "sticky.copy").flatMap(accessibilityLabel) == L10n.string("复制", language: language)
            guard board.changeCount == ownedCount, board.string(forType: .string) == expectedClipboard else {
                externalChange = true; break
            }
            checks[prefix + "streamDeltaDoesNotRewriteClipboard"] = true
            let recopied = await press(in: note.window, identifier: "sticky.copy")
            ownedCount = board.changeCount
            expectedClipboard = note.model.output
            checks[prefix + "secondCopyGetsFullCurrentOutput"] = recopied && board.string(forType: .string) == expectedClipboard
            note.window?.close()
        }
        // Never overwrite a clipboard modified outside the actions owned by this fixture.
        if !externalChange && board.changeCount == ownedCount &&
            (expectedClipboard == nil || board.string(forType: .string) == expectedClipboard) {
            let restored = saved.map { representations in
                let item = NSPasteboardItem()
                for (type, data) in representations { item.setData(data, forType: type) }
                return item
            }
            board.clearContents()
            let wrote = restored.isEmpty || board.writeObjects(restored)
            let actual = (board.pasteboardItems ?? []).map { item in
                Dictionary(uniqueKeysWithValues: item.types.compactMap { type in item.data(forType: type).map { (type, $0) } })
            }
            checks["copyFeedback.restoresEveryClipboardRepresentation"] = wrote && actual == saved
        } else {
            checks["copyFeedback.externalClipboardChangeDetected"] = true
            checks["copyFeedback.restoresEveryClipboardRepresentation"] = false
        }
        return checks
    }

    private static func inputLayoutFits(_ note: StickyWindow, editor: SettingsEditingTextView) -> Bool {
        guard let window = note.window, let scroll = editor.enclosingScrollView,
              let submit = element(in: window, identifier: "sticky.submit") else { return false }
        let inputFrame = window.convertToScreen(scroll.convert(scroll.bounds, to: nil))
        return scroll.bounds.height >= 100 && inputFrame.width >= 200 &&
            window.frame.contains(inputFrame) && window.frame.contains(frame(submit))
    }

    @discardableResult private static func sendInputKey(to window: NSWindow?, modifiers: NSEvent.ModifierFlags = .command,
                                                       keyCode: UInt16 = 36, isRepeat: Bool = false) -> Bool {
        guard let window, let event = NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil,
            characters: keyCode == 76 ? "\u{3}" : "\r", charactersIgnoringModifiers: keyCode == 76 ? "\u{3}" : "\r",
            isARepeat: isRepeat, keyCode: keyCode) else { return false }
        NSApp.sendEvent(event)
        return true
    }
}

/// Clipboard forwarding acceptance boundary; these overrides never touch a pasteboard.
@MainActor private final class NativeClipboardMenuProbe: NSTextView {
    var acceptsClipboardActions = true
    private(set) var copyCount = 0
    private(set) var cutCount = 0
    private(set) var pasteCount = 0

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool { acceptsClipboardActions }
    override func copy(_ sender: Any?) { copyCount += 1 }
    override func cut(_ sender: Any?) { cutCount += 1 }
    override func paste(_ sender: Any?) { pasteCount += 1 }
}
