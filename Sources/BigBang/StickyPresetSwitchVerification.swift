import AppKit
import ApplicationServices
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
                if rejectKey { throw ValidationError("请先在设置中保存 API Key。") }
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
            local["completedResultHasNoStoppedIndicator"] = await waitFor {
                element(in: note.window, identifier: "sticky.stopped-state") == nil
            }
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
            // A failed switch must be noticeable while reading the start of an
            // overflowing result, without moving that result to its error footer.
            note.window?.appearance = NSAppearance(named: mode == .responses ? .aqua : .darkAqua)
            configuration.presets[1].name = String(repeating: "Long selected preset 🌍 中文 ", count: 10)
            note.updateConfiguration(configuration)
            note.model.autoScroll = false
            let longResult = (1...100).map { "段落 \($0) 🌍 · 保留阅读位置和原始内容。Paragraph \($0) remains available after a failed request." }.joined(separator: "\n\n")
            note.model.output = longResult
            local["failedKeyReadLongResultOverflows"] = await waitFor {
                guard let output = outputView(in: note.hostingView), let scroll = outerScrollView(for: output),
                      let document = scroll.documentView else { return false }
                return output.renderingComplete && output.renderedSource == longResult && note.model.contentOverflows &&
                    document.bounds.height > scroll.contentView.bounds.height + 100
            }
            local["failedKeyReadNativeLayoutSettled"] = await settledOutputLayout(note, source: longResult)
            let failureScroll = outputView(in: note.hostingView).flatMap { outerScrollView(for: $0) }
            if let scroll = failureScroll {
                scroll.contentView.scroll(to: NSPoint(x: scroll.documentVisibleRect.minX, y: 0))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
            local["failedKeyReadStartsWithPausedTopReading"] = await waitFor {
                failureScroll.map { abs($0.documentVisibleRect.minY) < 1 } == true && !note.model.autoScroll
            }
            let offsetBeforeFailure = failureScroll?.documentVisibleRect.minY
            rejectKey = true
            let beforeFailure = note.model.output
            let presetBeforeFailure = note.model.preset
            let sourceBeforeFailure = note.model.source
            let followingBeforeFailure = note.model.autoScroll
            let countBeforeFailure = starts.count
            local["failedKeyReadUsesNativeAction"] = select(c.id, in: button)
            local["failedKeyReadPreservesPresetAndOutput"] = note.model.preset.id == b.id && note.model.output == beforeFailure &&
                !note.model.running && note.model.error != nil && starts.count == countBeforeFailure
            local["failedSelectionRestoresNativeSelection"] = button.selectedItem?.representedObject as? UUID == b.id
            // Observe the failure before any language fixture repositions the
            // reader. This barrier measures layout only and never scrolls.
            local["failedKeyReadLayoutSettlesWithoutFixtureRepositioning"] = await settledOutputLayout(note, source: beforeFailure)
            let offsetAfterInitialFailure = failureScroll?.documentVisibleRect.minY
            local["failedKeyReadKeepsReadingBeforeAnyFixtureRepositioning"] = offsetBeforeFailure != nil &&
                offsetAfterInitialFailure.map { abs($0 - (offsetBeforeFailure ?? 0)) < 1 } == true &&
                note.model.autoScroll == followingBeforeFailure
            local["failedKeyReadInitialFailureScreenshotSaved"] = snapshot(note.window,
                url: reportURL.deletingLastPathComponent().appendingPathComponent("request-failure-\(mode.rawValue)-initial.png"))
            diagnostics[mode.rawValue + ".failedKeyReadBeforeAnyFixtureRepositioning"] = [
                "offsetBeforeFailure": offsetBeforeFailure ?? -1,
                "offsetAfterFailure": offsetAfterInitialFailure ?? -1,
                "followingBeforeFailure": followingBeforeFailure,
                "followingAfterFailure": note.model.autoScroll,
                "rendererRevision": outputView(in: note.hostingView)?.revision ?? -1,
                "nativeOutputHeight": outputView(in: note.hostingView)?.bounds.height ?? -1,
                "rendererHeight": outputView(in: note.hostingView)?.contentHeight ?? -1,
                "documentHeight": failureScroll?.documentView?.bounds.height ?? -1
            ]
            for language in AppLanguage.allCases {
                let prefix = "failedKeyReadFeedback." + language.rawValue + "."
                let revisionBeforeLanguage = outputView(in: note.hostingView)?.revision ?? -1
                let languageChanged = note.model.language != language
                note.setLanguage(to: language)
                local[prefix + "languageLayoutSettlesBeforePositioning"] = await settledOutputLayout(
                    note, source: beforeFailure, minimumRevision: revisionBeforeLanguage + (languageChanged ? 1 : 0))
                // Position only after the new language's settled renderer and
                // native document have agreed on their geometry. A single scroll
                // avoids concealing later unintended product movement.
                if let scroll = failureScroll {
                    scroll.contentView.scroll(to: NSPoint(x: scroll.documentVisibleRect.minX, y: 0))
                    scroll.reflectScrolledClipView(scroll.contentView)
                }
                let expectedReason = L10n.string("请先在设置中保存 API Key。", language: language)
                let indicatorReady = await waitFor {
                    guard let indicator = element(in: note.window, identifier: "sticky.error-state"),
                          let label = accessibilityLabel(indicator) else { return false }
                    return label.contains(L10n.string("请求失败", language: language)) && label.contains(expectedReason)
                }
                let indicator = element(in: note.window, identifier: "sticky.error-state")
                let indicatorFrame = indicator.map(frame) ?? .zero
                let viewportBeforeAction = viewportScreenFrame(note, scroll: failureScroll)
                let offsetAfterLanguagePositioning = failureScroll?.documentVisibleRect.minY
                local[prefix + "headerNoticeVisibleWithoutScrolling"] = indicatorReady && hasVisibleArea(indicatorFrame) &&
                    note.window?.frame.contains(indicatorFrame) == true &&
                    viewportBeforeAction.map { indicatorFrame.minY >= $0.maxY - 1 } == true
                local[prefix + "helpIncludesLocalizedReason"] = indicator.flatMap {
                    accessibilityString($0, attribute: "accessibilityHelp")
                }?.contains(expectedReason) == true
                local[prefix + "longTitleAndAllHeaderActionsFit"] = indicator != nil && headerFits(note, button: button)
                local[prefix + "languageSetupKeepsReadingOffsetAndFollowing"] = offsetBeforeFailure != nil &&
                    offsetAfterLanguagePositioning.map { abs($0 - (offsetBeforeFailure ?? 0)) < 1 } == true && !note.model.autoScroll
                local[prefix + "failureKeepsCompleteResultAndRequestState"] = note.model.output == beforeFailure &&
                    note.model.source == sourceBeforeFailure && note.model.preset == presetBeforeFailure && starts.count == countBeforeFailure
                local[prefix + "pausedTopScreenshotSaved"] = snapshot(note.window,
                    url: reportURL.deletingLastPathComponent().appendingPathComponent("request-failure-\(mode.rawValue)-\(language.rawValue)-top.png"))

                // Missing feedback is a direct failure, rather than spending a
                // second timeout looking for an action absent in the baseline.
                let pressed = indicator != nil ? await press(in: note.window, identifier: "sticky.error-state") : false
                let visibleError = pressed ? await waitForVisibleError(in: note, scroll: failureScroll) : false
                local[prefix + "headerActionShowsCompleteError"] = pressed && visibleError
                local[prefix + "showingErrorKeepsManualReading"] = pressed && !note.model.autoScroll
                local[prefix + "followActionRemainsAvailable"] = element(in: note.window, identifier: "sticky.follow-latest").map {
                    let followFrame = frame($0)
                    return hasVisibleArea(followFrame) && note.window?.frame.contains(followFrame) == true
                } == true
                local[prefix + "errorDetailUsesCurrentLanguage"] = element(in: note.window, identifier: "sticky.error-detail")
                    .flatMap(staticTextContent)?.contains(expectedReason) == true
                local[prefix + "showingErrorDoesNotRequestOrReplaceContent"] = pressed && note.model.output == beforeFailure &&
                    note.model.source == sourceBeforeFailure && note.model.preset == presetBeforeFailure && starts.count == countBeforeFailure
                local[prefix + "visibleErrorScreenshotSaved"] = snapshot(note.window,
                    url: reportURL.deletingLastPathComponent().appendingPathComponent("request-failure-\(mode.rawValue)-\(language.rawValue)-detail.png"))
                let detail = element(in: note.window, identifier: "sticky.error-detail")
                let follow = element(in: note.window, identifier: "sticky.follow-latest")
                diagnostics[mode.rawValue + "." + prefix + "geometry"] = [
                    "windowFrame": note.window.map { NSStringFromRect($0.frame) } ?? "nil",
                    "indicatorFrame": NSStringFromRect(indicatorFrame),
                    "indicatorLabel": indicator.flatMap(accessibilityLabel) ?? "nil",
                    "indicatorHelp": indicator.flatMap { accessibilityString($0, attribute: "accessibilityHelp") } ?? "nil",
                    "detailFrame": detail.map { NSStringFromRect(frame($0)) } ?? "nil",
                    "viewportFrame": viewportScreenFrame(note, scroll: failureScroll).map(NSStringFromRect) ?? "nil",
                    "followButtonFrame": follow.map { NSStringFromRect(frame($0)) } ?? "nil",
                    "offsetBeforeFailure": offsetBeforeFailure ?? -1,
                    "offsetAfterLanguagePositioning": offsetAfterLanguagePositioning ?? -1,
                    "offsetAfterShowingError": failureScroll?.documentVisibleRect.minY ?? -1,
                    "followingAfterShowingError": note.model.autoScroll,
                    "revisionBeforeLanguageChange": revisionBeforeLanguage,
                    "revisionAfterSettling": outputView(in: note.hostingView)?.revision ?? -1,
                    "nativeOutputHeight": outputView(in: note.hostingView)?.bounds.height ?? -1,
                    "rendererHeight": outputView(in: note.hostingView)?.contentHeight ?? -1,
                    "documentHeight": failureScroll?.documentView?.bounds.height ?? -1
                ]
            }
            // These two presentation checks do not start another HTTP request.
            note.model.autoScroll = true
            let followsBeforeClick = await waitFor { note.model.autoScroll }
            let followIndicator = element(in: note.window, identifier: "sticky.error-state")
            let followingPress = followIndicator != nil ? await press(in: note.window, identifier: "sticky.error-state") : false
            let followingErrorVisible = followingPress ? await waitForVisibleError(in: note, scroll: failureScroll) : false
            local["failedKeyReadFeedback.explicitFollowingSurvivesDetailAction"] = followsBeforeClick && followingPress &&
                followingErrorVisible && note.model.autoScroll
            local["failedKeyReadFeedback.followingActionDoesNotRequest"] = starts.count == countBeforeFailure &&
                note.model.output == beforeFailure && note.model.source == sourceBeforeFailure && note.model.preset == presetBeforeFailure

            note.model.running = true
            local["failedKeyReadFeedback.syntheticRunningHeaderFitsWithSpinner"] = await waitFor {
                guard let indicator = element(in: note.window, identifier: "sticky.error-state"),
                      let spinnerFrame = headerSpinnerFrame(in: note),
                      let window = note.window else { return false }
                let indicatorFrame = frame(indicator)
                let neighbors = [frame(button), indicatorFrame] +
                    ["sticky.copy", "sticky.arrow.uturn.backward", "sticky.stop.fill", "sticky.pin", "sticky.xmark"].compactMap {
                        element(in: window, identifier: $0).map(frame)
                    }
                return note.model.running && hasVisibleArea(spinnerFrame) && window.frame.contains(spinnerFrame) &&
                    headerFits(note, button: button) && neighbors.allSatisfy { !hasVisibleArea(spinnerFrame.intersection($0)) }
            }
            note.model.autoScroll = false
            local["failedKeyReadFeedback.syntheticRunningKeepsPausedFollowAction"] = await waitFor {
                guard let follow = element(in: note.window, identifier: "sticky.follow-latest") else { return false }
                return !note.model.autoScroll && hasVisibleArea(frame(follow)) && note.window?.frame.contains(frame(follow)) == true
            }
            local["failedKeyReadFeedback.syntheticRunningScreenshotSaved"] = snapshot(note.window,
                url: reportURL.deletingLastPathComponent().appendingPathComponent("request-failure-\(mode.rawValue)-running.png"))
            local["failedKeyReadFeedback.syntheticRunningDoesNotRequestOrReplaceContent"] = starts.count == countBeforeFailure &&
                note.model.output == beforeFailure && note.model.source == sourceBeforeFailure && note.model.preset == presetBeforeFailure
            diagnostics[mode.rawValue + ".failedKeyReadFeedback.syntheticRunning"] = [
                "spinnerFrame": headerSpinnerFrame(in: note).map(NSStringFromRect) ?? "nil",
                "headerNativeViews": headerNativeViewDiagnostics(in: note),
                "indicatorFrame": element(in: note.window, identifier: "sticky.error-state").map { NSStringFromRect(frame($0)) } ?? "nil",
                "following": note.model.autoScroll,
                "requestCount": starts.count,
                "requestCountBeforeFailure": countBeforeFailure
            ]
            note.model.running = false
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
            local["retryStartClearsErrorNotice"] = await waitFor {
                note.model.running && note.model.error == nil && element(in: note.window, identifier: "sticky.error-state") == nil
            }
            local["retryUsesLatestPromptForSelectedIdentity"] = await waitFor {
                !note.model.running && note.model.output == "C first\nC complete" && note.model.preset.id == b.id && note.model.preset.prompt == "fixture-preset-C"
            }
            local["retrySuccessKeepsErrorNoticeHidden"] = note.model.error == nil && element(in: note.window, identifier: "sticky.error-state") == nil
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
            local["runningResultHasNoStoppedIndicator"] = element(in: note.window, identifier: "sticky.stopped-state") == nil
            let sourceBeforeStop = note.model.source
            let outputBeforeStop = note.model.output
            local["nativeStopControlWorks"] = await press(in: note.window, identifier: "sticky.stop.fill") && !note.model.running
            let stopped = note.model.output
            local["stoppingPreservesBodyAndOriginalInput"] = stopped == outputBeforeStop && !stopped.isEmpty &&
                note.model.source == sourceBeforeStop && sourceBeforeStop == "preset-switch-input"
            for language in AppLanguage.allCases {
                note.setLanguage(to: language)
                local["stoppedIndicatorLocalized." + language.rawValue] = await waitFor {
                    guard let indicator = element(in: note.window, identifier: "sticky.stopped-state") else { return false }
                    return staticTextContent(indicator) == L10n.string("已停止", language: language) &&
                        note.window?.frame.contains(frame(indicator)) == true && !note.model.running &&
                        note.model.output == stopped && note.model.source == sourceBeforeStop
                }
                diagnostics[mode.rawValue + ".stoppedIndicator." + language.rawValue] =
                    element(in: note.window, identifier: "sticky.stopped-state").map(staticTextDiagnostics) ?? [:]
            }
            try? await Task.sleep(for: .milliseconds(950))
            local["stopPreventsLateUpdates"] = note.model.output == stopped && note.model.state == "已停止"
            local["nativeRetryAfterStopWorks"] = await press(in: note.window, identifier: "sticky.arrow.clockwise")
            // Wait for the running view's AX tree before pressing once; the first model delta
            // can arrive before SwiftUI replaces the previous retry control.
            local["closeStartsWithLiveStream"] = await waitFor {
                note.model.output == "A first" && note.model.running &&
                    element(in: note.window, identifier: "sticky.stop.fill") != nil &&
                    element(in: note.window, identifier: "sticky.stopped-state") == nil
            }
            local["retryHidesStoppedIndicator"] = local["closeStartsWithLiveStream"] == true
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
    private static func outputView(in view: NSView) -> StickyTextView? {
        if let output = view as? StickyTextView { return output }
        return view.subviews.lazy.compactMap { outputView(in: $0) }.first
    }
    private static func settledOutputLayout(_ note: StickyWindow, source: String, minimumRevision: Int = -1) async -> Bool {
        var previous: [CGFloat]?
        var stableSamples = 0
        for _ in 0..<150 {
            if let output = outputView(in: note.hostingView), let scroll = outerScrollView(for: output),
               let document = scroll.documentView, output.revision >= minimumRevision,
               output.renderingComplete, output.renderedSource == source,
               output.readingPosition(following: false) != nil,
               abs(output.bounds.height - output.contentHeight) <= 1,
               abs(output.bounds.width - output.contentWidth) <= 1,
               document.bounds.height >= output.contentHeight {
                let sample = [CGFloat(output.revision), output.bounds.width, output.bounds.height,
                              document.bounds.width, document.bounds.height,
                              scroll.contentView.bounds.width, scroll.contentView.bounds.height]
                stableSamples = previous == sample ? stableSamples + 1 : 1
                previous = sample
                if stableSamples >= 3 { return true }
            } else {
                previous = nil
                stableSamples = 0
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }
    private static func accessibilityElement(in root: Any?, role: String) -> NSObject? {
        guard let object = root as? NSObject else { return nil }
        if accessibilityString(object, attribute: "accessibilityRole") == role { return object }
        let children = NSSelectorFromString("accessibilityChildren")
        guard object.responds(to: children), let items = object.perform(children)?.takeUnretainedValue() as? [Any] else { return nil }
        return items.lazy.compactMap { accessibilityElement(in: $0, role: role) }.first
    }
    private static func nativeProgressIndicator(in root: NSView, window: NSWindow) -> NSProgressIndicator? {
        if let spinner = root as? NSProgressIndicator, !spinner.isHiddenOrHasHiddenAncestor,
           spinner.window === window {
            let visibleFrame = window.convertToScreen(spinner.convert(spinner.bounds, to: nil))
            let header = NSRect(x: window.frame.minX, y: window.frame.maxY - StickyView.headerHeight,
                                width: window.frame.width, height: StickyView.headerHeight)
            if hasVisibleArea(visibleFrame), header.contains(visibleFrame) { return spinner }
        }
        return root.subviews.lazy.compactMap { nativeProgressIndicator(in: $0, window: window) }.first
    }
    private static func headerSpinnerFrame(in note: StickyWindow) -> NSRect? {
        guard let window = note.window else { return nil }
        // SwiftUI can render a native spinner without exposing an AX progress
        // role. Measure that actual view in the same screen coordinates as AX.
        if let spinner = nativeProgressIndicator(in: note.hostingView, window: window) {
            return window.convertToScreen(spinner.convert(spinner.bounds, to: nil))
        }
        guard let spinner = accessibilityElement(in: window, role: NSAccessibility.Role.progressIndicator.rawValue) else { return nil }
        let spinnerFrame = frame(spinner)
        let header = NSRect(x: window.frame.minX, y: window.frame.maxY - StickyView.headerHeight,
                            width: window.frame.width, height: StickyView.headerHeight)
        return hasVisibleArea(spinnerFrame) && header.contains(spinnerFrame) ? spinnerFrame : nil
    }
    private static func headerNativeViewDiagnostics(in note: StickyWindow) -> [[String: String]] {
        guard let window = note.window else { return [] }
        let header = NSRect(x: window.frame.minX, y: window.frame.maxY - StickyView.headerHeight,
                            width: window.frame.width, height: StickyView.headerHeight)
        func entries(in view: NSView) -> [[String: String]] {
            let rectangle = window.convertToScreen(view.convert(view.bounds, to: nil))
            let own: [[String: String]] = !view.isHiddenOrHasHiddenAncestor && hasVisibleArea(rectangle) && header.contains(rectangle) ? [
                ["class": String(String(describing: type(of: view)).prefix(120)), "frame": NSStringFromRect(rectangle),
                 "role": accessibilityString(view, attribute: "accessibilityRole") ?? "nil"]
            ] : []
            return own + view.subviews.flatMap { entries(in: $0) }
        }
        return Array(entries(in: note.hostingView).prefix(24))
    }
    private static func outerScrollView(for view: NSView) -> NSScrollView? {
        var ancestor = view.superview
        while let current = ancestor {
            if let scroll = current as? NSScrollView { return scroll }
            ancestor = current.superview
        }
        return nil
    }
    private static func hasVisibleArea(_ rectangle: NSRect) -> Bool {
        rectangle.width > 1 && rectangle.height > 1 &&
            rectangle.origin.x.isFinite && rectangle.origin.y.isFinite && rectangle.width.isFinite && rectangle.height.isFinite
    }
    private static func viewportScreenFrame(_ note: StickyWindow, scroll: NSScrollView?) -> NSRect? {
        guard let window = note.window, let scroll else { return nil }
        return window.convertToScreen(scroll.contentView.convert(scroll.contentView.bounds, to: nil))
    }
    private static func waitForVisibleError(in note: StickyWindow, scroll: NSScrollView?) async -> Bool {
        await waitFor {
            guard let detail = element(in: note.window, identifier: "sticky.error-detail"),
                  let viewport = viewportScreenFrame(note, scroll: scroll), let window = note.window else { return false }
            let detailFrame = frame(detail)
            guard hasVisibleArea(detailFrame), hasVisibleArea(viewport), viewport.contains(detailFrame),
                  window.frame.contains(detailFrame) else { return false }
            if let follow = element(in: window, identifier: "sticky.follow-latest") {
                let overlap = detailFrame.intersection(frame(follow))
                if hasVisibleArea(overlap) { return false }
            }
            return true
        }
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
        let error = element(in: window, identifier: "sticky.error-state").map(frame)
        let errorFits = error.map { errorFrame in
            hasVisibleArea(errorFrame) && window.frame.contains(errorFrame) && selectorFrame.maxX <= errorFrame.minX + 1 &&
                actions.allSatisfy { errorFrame.maxX <= $0.minX + 1 }
        } ?? true
        return errorFits && selectorFrame.width > 30 && selectorFrame.height > 15 && actions.count == 5 && actions.allSatisfy {
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
    /// A late selection cleanup must respect the user's more recent window choice.
    private static func verifyCaptureCleanupFocus(
        open: @escaping (Preset, @escaping () async throws -> String, @escaping () throws -> String,
               @escaping (StickyWindow, Configuration, String) -> Void) async throws -> StickyWindow
    ) async -> [String: Bool] {
        var checks: [String: Bool] = [:]
        // Keep prior windows alive so AppKit cannot recycle their object identities
        // into the next scenario's newly created panel.
        var ownedNotes: [StickyWindow] = []
        let originalApplication = NSWorkspace.shared.frontmostApplication
        let preset = Preset.defaults(for: .simplifiedChinese)[0]
        for scenario in ["stay", "switchAway", "returnBeforeCleanup"] {
            let prefix = "captureFocus.\(scenario)."
            let previousWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
            var continuation: CheckedContinuation<String, Error>?
            var keyReads = 0
            var requests: [String] = []
            let pending = Task { @MainActor in
                try await open(preset, {
                    try await withCheckedThrowingContinuation { continuation = $0 }
                }, { keyReads += 1; return "fixture-key" }, { note, _, _ in
                    requests.append(note.model.source)
                })
            }
            let started = await waitFor { continuation != nil }
            let note = NSApp.windows.first {
                $0 is StickyPanel && $0.isVisible && !previousWindows.contains(ObjectIdentifier($0))
            }?.windowController as? StickyWindow
            guard started, let note, let panel = note.window else {
                checks[prefix + "selectionBoundaryReached"] = false
                continuation?.resume(returning: "")
                pending.cancel()
                _ = try? await pending.value
                note?.window?.close()
                continue
            }
            ownedNotes.append(note)
            panel.makeKeyAndOrderFront(nil)
            let ready = await waitFor {
                guard let editor = input(in: note.hostingView) else { return false }
                return panel.isKeyWindow && panel.firstResponder === editor &&
                    note.captureCancelled && note.model.awaitingInput && note.model.capturingSelection
            }
            checks[prefix + "takeoverReadyBeforeCleanup"] = ready
            let editor = input(in: note.hostingView)
            let draft = "User draft \(scenario)"
            editor?.insertText(draft, replacementRange: NSRange(location: 0, length: editor?.string.utf16.count ?? 0))
            checks[prefix + "draftAcceptedBeforeCleanup"] = await waitFor { note.model.draft == draft }

            let sentinel = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 320, height: 140),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            sentinel.isReleasedWhenClosed = false
            sentinel.title = "Capture focus fixture"
            let sentinelText = NSTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 140))
            sentinelText.string = "Keep keyboard focus here"
            sentinel.contentView = sentinelText
            if scenario != "stay" {
                NSApp.activate(ignoringOtherApps: true)
                sentinel.makeKeyAndOrderFront(nil)
                sentinel.makeFirstResponder(sentinelText)
                checks[prefix + "newWindowOwnsFocus"] = await waitFor {
                    sentinel.isKeyWindow && sentinel.firstResponder === sentinelText && !panel.isKeyWindow
                }
                if scenario == "returnBeforeCleanup" {
                    panel.makeKeyAndOrderFront(nil)
                    checks[prefix + "explicitReturnOwnsFocus"] = await waitFor { panel.isKeyWindow }
                }
            }
            continuation?.resume(returning: "Late selection must be ignored")
            continuation = nil
            do {
                let completed = try await pending.value
                // Flush queued SwiftUI/editor updates as well as the immediate completion.
                try? await Task.sleep(for: .milliseconds(100))
                checks[prefix + "cleanupPreservesDraftWithoutRequest"] = completed === note &&
                    note.model.awaitingInput && !note.model.capturingSelection && note.model.draft == draft &&
                    note.model.source.isEmpty && keyReads == 0 && requests.isEmpty
                checks[prefix + "cleanupRespectsLatestFocus"] = scenario == "switchAway" ?
                    sentinel.isKeyWindow && sentinel.firstResponder === sentinelText && !panel.isKeyWindow :
                    panel.isKeyWindow && panel.firstResponder === editor
                if scenario == "switchAway" { panel.makeKeyAndOrderFront(nil) }
                checks[prefix + "explicitReturnRemainsEditable"] = await waitFor {
                    panel.isKeyWindow && panel.firstResponder === input(in: note.hostingView) && note.model.canSubmit
                }
                note.model.submit?()
                checks[prefix + "explicitSubmissionUsesDraftExactlyOnce"] = requests == [draft] && keyReads == 1
                if checks[prefix + "explicitSubmissionUsesDraftExactlyOnce"] == false {
                    print("Capture focus fixture \(scenario): keyReads=\(keyReads), requests=\(requests.count), sourceMatches=\(note.model.source == draft), error=\(note.model.error ?? "none"), marked=\(editor?.hasMarkedText() ?? false)")
                }
            } catch {
                checks[prefix + "cleanupCompletes"] = false
            }
            panel.close()
            sentinel.close()
        }
        if let originalApplication, originalApplication.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            originalApplication.activate(options: [])
            checks["captureFocus.restoresForegroundApplication"] = await waitFor {
                NSWorkspace.shared.frontmostApplication?.processIdentifier == originalApplication.processIdentifier
            }
        }
        return checks
    }

    /// The production selection-to-note path, with an injected selection boundary and request sink.
    static func runManualInput(reportURL: URL,
        open: @escaping (Preset, @escaping () async throws -> String, @escaping () throws -> String,
               @escaping (StickyWindow, Configuration, String) -> Void) async throws -> StickyWindow) async {
        if CommandLine.arguments.contains("--capture-focus-only") {
            let checks = await verifyCaptureCleanupFocus(open: open)
            let report: [String: Any] = ["passed": !checks.isEmpty && checks.values.allSatisfy { $0 },
                "checks": checks,
                "scope": "Production selection-to-note path with a gated selection and native owned windows. User takeover, switching away, and explicit return before/after cleanup. In-memory draft and request sink; no clipboard, external application, Keychain, settings writes or model calls."]
            do {
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                    .write(to: reportURL, options: .atomic)
            } catch { fputs("Capture focus report: \(error)\n", stderr) }
            NSApp.terminate(nil)
            return
        }
        var checks: [String: Bool] = [:]
        var diagnostics: [String: Any] = [:]
        var errors: [String] = []
        var notes: [StickyWindow] = []
        checks.merge(await verifyCaptureCleanupFocus(open: open)) { _, new in new }
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
            "scope": "Packaged nonactivating panel; production selection-to-note path with injected selection failures and request sink; native editor composition, private-pasteboard paste, accessibility submit/cancel-edit and NSApp.sendEvent keyboard routing. Cancel-edit verifies restored result snapshots and stopped-stream isolation. Copy feedback uses deterministic published output deltas; the general clipboard is fully materialized by item/type before copying and restored byte-for-byte only if no external write is detected. An explicitly supplied loopback endpoint additionally exercises both real streaming API clients. Conditional nativeAX checks run only with --fixture-app: real SelectionReader against owned ordinary and nonactivating ExternalSelectionFixture windows, plus a nonactivating copy-only selection that hides AX text and receives targeted native copy. Each process has a fresh readiness report, owned termination and frontmost-app restoration; copy phases and complete in-memory item/type snapshots verify clipboard preservation without writing a test restoration. No live model, Keychain access, global hotkey registration or settings writes. Installed IME candidate UI and physical hotkey are not exercised."]
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
        let expected = "外部原始选区"
        // Diagnostic samples only: never use these later observations to change
        // SelectionReader's verdict or infer what its private snapshot captured.
        func focusedUISnapshot() -> (element: AXUIElement?, metadata: [String: Any]) {
            let began = ProcessInfo.processInfo.systemUptime
            let system = AXUIElementCreateSystemWide()
            AXUIElementSetMessagingTimeout(system, 0.04)
            var value: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &value)
            var metadata: [String: Any] = ["axError": status.rawValue,
                "workspacePID": NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1,
                "uptimeSeconds": began]
            guard status == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
                metadata["available"] = false
                metadata["elapsedMilliseconds"] = (ProcessInfo.processInfo.systemUptime - began) * 1000
                return (nil, metadata)
            }
            let element = unsafeBitCast(value, to: AXUIElement.self)
            AXUIElementSetMessagingTimeout(element, 0.04)
            var pid: pid_t = 0
            let pidStatus = AXUIElementGetPid(element, &pid)
            AXUIElementSetMessagingTimeout(element, 0.04)
            var role: CFTypeRef?
            let roleStatus = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
            metadata["available"] = true
            metadata["pid"] = Int(pid)
            metadata["pidError"] = pidStatus.rawValue
            metadata["role"] = role as? String ?? ""
            metadata["roleError"] = roleStatus.rawValue
            metadata["elapsedMilliseconds"] = (ProcessInfo.processInfo.systemUptime - began) * 1000
            return (element, metadata)
        }
        func focusComparison(_ before: (element: AXUIElement?, metadata: [String: Any]),
                             _ after: (element: AXUIElement?, metadata: [String: Any])) -> [String: Any] {
            var result: [String: Any] = ["before": before.metadata, "after": after.metadata,
                                       "comparisonSamplesAreObservational": true]
            if let original = before.element, let current = after.element {
                result["sameElement"] = CFEqual(original, current)
            }
            return result
        }
        // Materialize every representation in memory. Only comparison booleans
        // enter the report; SelectionReader alone owns clipboard restoration.
        func clipboardSnapshot() -> (items: [[String: Data]], complete: Bool) {
            let board = NSPasteboard.general
            let change = board.changeCount
            var items: [[String: Data]] = []
            var complete = true
            for item in board.pasteboardItems ?? [] {
                var representations: [String: Data] = [:]
                for type in item.types {
                    if let data = item.data(forType: type) { representations[type.rawValue] = data }
                    else { complete = false }
                }
                items.append(representations)
            }
            return (items, complete && board.changeCount == change)
        }
        let scenarios: [(name: String, nonactivating: Bool, copyOnly: Bool)] = [
            ("", false, false), ("nonactivating.", true, false), ("nonactivatingCopyOnly.", true, true)
        ]
        for scenario in scenarios {
            // Keep the ordinary scenario's original check and diagnostic keys.
            let prefix = "nativeAX." + scenario.name
            let previousFrontmost = NSWorkspace.shared.frontmostApplication
            let originalWorkspacePID = previousFrontmost?.processIdentifier
            let readyURL = reportURL.deletingLastPathComponent()
                .appendingPathComponent("native-ax-fixture-\(scenario.name)ready-\(UUID().uuidString).json")
            let fixture = Process()
            fixture.executableURL = fixtureURL.appendingPathComponent("Contents/MacOS/ExternalSelectionFixture")
            fixture.arguments = ["--ready", readyURL.path] +
                (scenario.nonactivating ? ["--nonactivating"] : []) + (scenario.copyOnly ? ["--copy-only"] : [])
            var launched = false
            do {
                try FileManager.default.createDirectory(at: readyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fixture.run()
                launched = true
                diagnostics[prefix + "fixturePID"] = fixture.processIdentifier
                diagnostics[prefix + "readyReport"] = readyURL.path
                diagnostics[prefix + "originalWorkspacePID"] = originalWorkspacePID ?? -1
                let ready = await waitFor {
                    guard let data = try? Data(contentsOf: readyURL),
                          let report = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          report["ready"] as? Bool == true,
                          (report["pid"] as? NSNumber)?.int32Value == fixture.processIdentifier,
                          report["nonactivating"] as? Bool == scenario.nonactivating,
                          report["copyOnly"] as? Bool == scenario.copyOnly,
                          (report["selectedUTF16Length"] as? NSNumber)?.intValue == expected.utf16.count,
                          (report["windowNumber"] as? NSNumber)?.intValue ?? 0 > 0 else { return false }
                    let workspacePID = NSWorkspace.shared.frontmostApplication?.processIdentifier
                    if scenario.nonactivating {
                        return originalWorkspacePID != nil && workspacePID == originalWorkspacePID &&
                            workspacePID != fixture.processIdentifier &&
                            (report["workspacePID"] as? NSNumber)?.int32Value == originalWorkspacePID
                    }
                    return workspacePID == fixture.processIdentifier &&
                        (report["workspacePID"] as? NSNumber)?.int32Value == fixture.processIdentifier
                }
                checks[prefix + (scenario.nonactivating ? "fixtureBecameReadyWithoutActivation" : "fixtureBecameReadyAndFrontmost")] = ready
                if ready {
                    let before = clipboardSnapshot()
                    checks[prefix + "clipboardSnapshotBeforeComplete"] = before.complete
                    var phases: [String] = []
                    var copiedTypes: [[String]] = []
                    var copiedExpected: [Bool] = []
                    let began = ProcessInfo.processInfo.systemUptime
                    do {
                        if scenario.copyOnly {
                            do {
                                let focusBefore = focusedUISnapshot()
                                defer {
                                    diagnostics[prefix + "axOnlyProbeFocus"] = focusComparison(focusBefore, focusedUISnapshot())
                                }
                                let unexpected = try await SelectionReader.read(copyFallback: false)
                                checks[prefix + "axOnlyRejectsHiddenSelection"] = false
                                diagnostics[prefix + "unexpectedAXSelectionUTF8Bytes"] = unexpected.utf8.count
                            } catch {
                                checks[prefix + "axOnlyRejectsHiddenSelection"] = true
                                diagnostics[prefix + "axOnlyError"] = error.localizedDescription
                            }
                        }
                        // Never enter a copy transaction after an incomplete snapshot.
                        if !scenario.copyOnly || before.complete {
                            let focusBefore = focusedUISnapshot()
                            defer {
                                diagnostics[prefix + "selectionReadFocus"] = focusComparison(focusBefore, focusedUISnapshot())
                            }
                            let selection = try await SelectionReader.read(copyFallback: scenario.copyOnly,
                                onClipboardPhase: { phase in phases.append(phase == .began ? "began" : "ended") },
                                onCopiedClipboard: { observation in
                                    copiedTypes.append(observation.types.sorted())
                                    copiedExpected.append(observation.text == expected)
                                })
                            checks[prefix + "realSelectionMatchesFixture"] = selection == expected
                            diagnostics[prefix + "selectionUTF8Bytes"] = selection.utf8.count
                        } else { checks[prefix + "realSelectionMatchesFixture"] = false }
                    } catch {
                        checks[prefix + "realSelectionMatchesFixture"] = false
                        diagnostics[prefix + "error"] = error.localizedDescription
                    }
                    diagnostics[prefix + "millisecondsToRead"] = (ProcessInfo.processInfo.systemUptime - began) * 1000
                    diagnostics[prefix + "clipboardPhases"] = phases
                    diagnostics[prefix + "copiedTypes"] = copiedTypes
                    if scenario.copyOnly {
                        checks[prefix + "copyTransactionCompletes"] = phases == ["began", "ended"]
                        checks[prefix + "copyContainsExpectedSelection"] = copiedExpected == [true] &&
                            copiedTypes.count == 1 && !copiedTypes[0].isEmpty
                    } else {
                        checks[prefix + "axOnlyDoesNotCopy"] = phases.isEmpty && copiedTypes.isEmpty
                    }
                    let after = clipboardSnapshot()
                    checks[prefix + "clipboardSnapshotAfterComplete"] = after.complete
                    checks[prefix + "clipboardPreservesEveryRepresentation"] = before.complete && after.complete && before.items == after.items
                    if scenario.nonactivating {
                        let workspacePID = NSWorkspace.shared.frontmostApplication?.processIdentifier
                        checks[prefix + "workspaceRemainsDifferentFromFixture"] = workspacePID == originalWorkspacePID &&
                            workspacePID != fixture.processIdentifier
                        diagnostics[prefix + "workspacePIDAfterRead"] = workspacePID ?? -1
                    }
                } else { checks[prefix + "realSelectionMatchesFixture"] = false }
            } catch {
                checks[prefix + "realSelectionMatchesFixture"] = false
                diagnostics[prefix + "error"] = String(describing: error)
            }
            if launched {
                if fixture.isRunning { fixture.terminate() }
                checks[prefix + "ownedFixtureTerminated"] = await waitFor { !fixture.isRunning }
            }
            if let previousFrontmost {
                previousFrontmost.activate(options: [])
                checks[prefix + "previousFrontmostRestored"] = await waitFor {
                    NSWorkspace.shared.frontmostApplication?.processIdentifier == previousFrontmost.processIdentifier
                }
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
                checks[prefix + "restoredPartialResultShowsStoppedIndicator"] = await waitFor {
                    guard let indicator = element(in: note.window, identifier: "sticky.stopped-state") else { return false }
                    return cancelled && staticTextContent(indicator) == L10n.string("已停止", language: note.model.language) &&
                        note.window?.frame.contains(frame(indicator)) == true && note.model.output == partial
                }
                diagnostics[prefix + "stoppedIndicatorAccessibility"] =
                    element(in: note.window, identifier: "sticky.stopped-state").map(staticTextDiagnostics) ?? [:]
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

    /// Keep button-label checks strict; only static text permits the native AXValue representation.
    private static func staticTextContent(_ object: NSObject) -> String? {
        let label = accessibilityLabel(object)
        return label?.isEmpty == false ? label : accessibilityString(object, attribute: "accessibilityValue")
    }
    private static func accessibilityString(_ object: NSObject, attribute: String) -> String? {
        let selector = NSSelectorFromString(attribute)
        guard object.responds(to: selector) else { return nil }
        let value = object.perform(selector)?.takeUnretainedValue()
        return (value as? String) ?? (value as? NSAttributedString)?.string
    }
    private static func staticTextDiagnostics(_ object: NSObject) -> [String: String] {
        ["role": accessibilityString(object, attribute: "accessibilityRole") ?? "nil",
         "label": accessibilityString(object, attribute: "accessibilityLabel") ?? "nil",
         "value": accessibilityString(object, attribute: "accessibilityValue") ?? "nil"]
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
