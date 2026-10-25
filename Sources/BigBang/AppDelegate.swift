import AppKit
import SwiftUI
import Carbon
import BigBangCore
import BigBangSelection
import CryptoKit

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
    private var statusItem: NSStatusItem!
    let store = SettingsStore()
    private let hotKeys = HotKeyManager()
    private var settingsWindow: NSWindow?
    private var settingsEditor: SettingsEditor?
    private var stickies: [UUID: StickyWindow] = [:]
    private var reading = false
    private var escapeMonitor: Any?
    private lazy var loginItems = LoginItemService.controller()

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--diagnose-live-api") {
            Task { @MainActor [self] in await LiveAPIDiagnostic.run(configuration: store.configuration) }
            return
        }
        NSApp.setActivationPolicy(.accessory)
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"), let icon = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = icon
        }
        setupMainMenu()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let image = NSImage(systemSymbolName: "text.quote", accessibilityDescription: L10n.string("大爆炸"))?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.title = ""
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.toolTip = L10n.string("大爆炸 · 按 ⌃⌥1 / 2 / 3 / 4 / 5 处理文本")
        hotKeys.onTrigger = { [weak self] preset in self?.trigger(preset) }
        let testing = CommandLine.arguments.contains("--smoke-test") || CommandLine.arguments.contains("--integration-test") ||
            CommandLine.arguments.contains("--selection-test") || CommandLine.arguments.contains("--sticky-selection-test") ||
            CommandLine.arguments.contains("--preferences-test") || CommandLine.arguments.contains("--preset-switch-test") ||
            CommandLine.arguments.contains("--preset-layout-test") || CommandLine.arguments.contains("--sticky-streaming-test") ||
            CommandLine.arguments.contains("--settings-input-test") || CommandLine.arguments.contains("--sticky-markdown-test") ||
            CommandLine.arguments.contains("--sticky-markdown-preview") || CommandLine.arguments.contains("--sticky-input-test")
        if !testing {
            do { try hotKeys.register(store.configuration.presets) } catch { notify(error.localizedDescription) }
        }
        rebuildMenu()
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53, let window = NSApp.keyWindow,
               self?.stickies.values.contains(where: { $0.window === window }) == true {
                if let editor = window.firstResponder as? NSTextView, editor.hasMarkedText() { return event }
                window.close(); return nil
            }
            return event
        }
        if CommandLine.arguments.contains("--sticky-input-test") {
            guard let index = CommandLine.arguments.firstIndex(of: "--report"), CommandLine.arguments.count > index + 1 else {
                NSApp.terminate(nil); return
            }
            Task { @MainActor [self] in
                store.configuration = Configuration(language: .simplifiedChinese)
                await StickyPresetSwitchVerification.runManualInput(
                    reportURL: URL(fileURLWithPath: CommandLine.arguments[index + 1]),
                    open: { preset, selection, readKey, start in
                        try await self.prepareTriggeredSticky(preset, selection: selection, readKey: readKey, start: start)
                    })
            }
        } else if CommandLine.arguments.contains("--sticky-markdown-test") || CommandLine.arguments.contains("--sticky-markdown-preview") {
            guard let reportIndex = CommandLine.arguments.firstIndex(of: "--report"),
                  CommandLine.arguments.count > reportIndex + 1 else { NSApp.terminate(nil); return }
            Task { @MainActor [self] in
                await StickyMarkdownVerification.run(
                    reportURL: URL(fileURLWithPath: CommandLine.arguments[reportIndex + 1]),
                    registerPreview: { [weak self] sticky in
                        let id = UUID()
                        self?.stickies[id] = sticky
                        sticky.onClose = { [weak self] in self?.stickies.removeValue(forKey: id) }
                    })
            }
        } else if CommandLine.arguments.contains("--settings-input-test") {
            guard let reportIndex = CommandLine.arguments.firstIndex(of: "--report"),
                  CommandLine.arguments.count > reportIndex + 1 else { NSApp.terminate(nil); return }
            Task { @MainActor [self] in
                await SettingsInputVerification.run(
                    reportURL: URL(fileURLWithPath: CommandLine.arguments[reportIndex + 1]),
                    verifyHotkeys: { await self.checkPresetKeyboardShortcuts() })
            }
        } else if CommandLine.arguments.contains("--sticky-streaming-test") {
            guard let reportIndex = CommandLine.arguments.firstIndex(of: "--report"),
                  CommandLine.arguments.count > reportIndex + 1 else { NSApp.terminate(nil); return }
            Task { @MainActor in
                await StickyStreamingLayoutVerification.run(
                    reportURL: URL(fileURLWithPath: CommandLine.arguments[reportIndex + 1]))
            }
        } else if CommandLine.arguments.contains("--preset-layout-test") {
            guard let reportIndex = CommandLine.arguments.firstIndex(of: "--report"),
                  CommandLine.arguments.count > reportIndex + 1 else { NSApp.terminate(nil); return }
            Task { @MainActor [weak self] in
                await StickyPresetLayoutVerification.run(
                    reportURL: URL(fileURLWithPath: CommandLine.arguments[reportIndex + 1]),
                    registerPreview: { [weak self] sticky in
                        let id = UUID()
                        self?.stickies[id] = sticky
                        sticky.onClose = { [weak self] in self?.stickies.removeValue(forKey: id) }
                    })
            }
        } else if CommandLine.arguments.contains("--preset-switch-test") {
            guard let baseIndex = CommandLine.arguments.firstIndex(of: "--test-base-url"),
                  let reportIndex = CommandLine.arguments.firstIndex(of: "--report"),
                  CommandLine.arguments.count > max(baseIndex, reportIndex) + 1,
                  let url = URL(string: CommandLine.arguments[baseIndex + 1]),
                  url.host == "127.0.0.1", url.scheme == "http" else { NSApp.terminate(nil); return }
            Task { @MainActor [self] in
                await StickyPresetSwitchVerification.run(baseURL: url.absoluteString,
                    reportURL: URL(fileURLWithPath: CommandLine.arguments[reportIndex + 1]),
                    registerPreview: { [weak self] sticky in
                        let id = UUID()
                        self?.stickies[id] = sticky
                        sticky.onClose = { [weak self] in self?.stickies.removeValue(forKey: id) }
                    })
            }
        } else if CommandLine.arguments.contains("--preferences-test") {
            runPreferencesTest()
        } else if CommandLine.arguments.contains("--sticky-selection-test") {
            runStickySelectionTest()
        } else if CommandLine.arguments.contains("--selection-test") {
            runSelectionTest()
        } else if CommandLine.arguments.contains("--integration-test") {
            runIntegrationTest()
        } else if CommandLine.arguments.contains("--smoke-test") {
            runSmokeTest()
        } else if CommandLine.arguments.contains("--demo") {
            showDemo()
        } else {
            if !launchedAtLogin { showSettings() }
            if let error = store.loadError { notify(error) }
        }
    }
    private var launchedAtLogin: Bool {
        Self.isLoginLaunch(NSAppleEventManager.shared().currentAppleEvent)
    }
    private static func isLoginLaunch(_ event: NSAppleEventDescriptor?) -> Bool {
        event?.eventID == kAEOpenApplication &&
            event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }
    private func refreshLocalization(configuration: Configuration? = nil) {
        let configuration = configuration ?? store.configuration
        L10n.currentLanguage = configuration.language
        setupMainMenu()
        statusItem.button?.setAccessibilityLabel(L10n.string("大爆炸"))
        rebuildMenu(configuration: configuration)
        statusItem.button?.toolTip = L10n.string("大爆炸 · 按 ⌃⌥1 / 2 / 3 / 4 / 5 处理文本")
        settingsWindow?.title = L10n.string("大爆炸设置")
        for sticky in stickies.values { sticky.updateConfiguration(configuration) }
    }
    func applicationWillTerminate(_ notification: Notification) {
        settingsEditor?.flush()
        for sticky in stickies.values { sticky.model.stop() }
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
    }
    private func setupMainMenu() {
        let main = NSMenu()
        let app = NSMenuItem(); let appMenu = NSMenu()
        appMenu.addItem(withTitle: L10n.string("大爆炸设置…"), action: #selector(showSettings), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L10n.string("退出大爆炸"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        app.submenu = appMenu; main.addItem(app)
        let file = NSMenuItem(title: L10n.string("文件"), action: nil, keyEquivalent: "")
        let fileMenu = NSMenu(title: L10n.string("文件"))
        fileMenu.addItem(withTitle: L10n.string("关闭窗口"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        file.submenu = fileMenu; main.addItem(file)
        let edit = NSMenuItem(title: L10n.string("编辑"), action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: L10n.string("编辑"))
        for (title, action, key) in [("撤销", Selector(("undo:")), "z"), ("重做", Selector(("redo:")), "Z"), ("剪切", #selector(cutFromMenu(_:)), "x"),
                                     ("复制", #selector(copyFromMenu(_:)), "c"), ("粘贴", #selector(pasteFromMenu(_:)), "v"),
                                     ("全选", #selector(NSText.selectAll(_:)), "a")] {
            let item = editMenu.addItem(withTitle: L10n.string(title), action: action, keyEquivalent: key)
            if action == Selector(("redo:")) { item.keyEquivalentModifierMask = [.command, .shift] }
            if clipboardAction(for: action) != nil { item.target = self }
        }
        edit.submenu = editMenu; main.addItem(edit); NSApp.mainMenu = main
    }
    private func clipboardAction(for action: Selector?) -> Selector? {
        switch action {
        case #selector(copyFromMenu(_:)): #selector(NSText.copy(_:))
        case #selector(cutFromMenu(_:)): #selector(NSText.cut(_:))
        case #selector(pasteFromMenu(_:)): #selector(NSText.paste(_:))
        default: nil
        }
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let action = clipboardAction(for: menuItem.action) else { return true }
        guard !ClipboardAccessGate.shared.isBusy, let target = NSApp.target(forAction: action) else { return false }
        let nativeItem = NSMenuItem(title: menuItem.title, action: action, keyEquivalent: menuItem.keyEquivalent)
        if let validator = target as? NSMenuItemValidation { return validator.validateMenuItem(nativeItem) }
        if let validator = target as? NSUserInterfaceValidations { return validator.validateUserInterfaceItem(nativeItem) }
        return true
    }
    private func forwardClipboardAction(_ action: Selector, sender: Any?) {
        guard !ClipboardAccessGate.shared.isBusy else { return }
        NSApp.sendAction(action, to: nil, from: sender)
    }
    @objc private func copyFromMenu(_ sender: Any?) { forwardClipboardAction(#selector(NSText.copy(_:)), sender: sender) }
    @objc private func cutFromMenu(_ sender: Any?) { forwardClipboardAction(#selector(NSText.cut(_:)), sender: sender) }
    @objc private func pasteFromMenu(_ sender: Any?) { forwardClipboardAction(#selector(NSText.paste(_:)), sender: sender) }
    private func rebuildMenu(configuration: Configuration? = nil) {
        let configuration = configuration ?? store.configuration
        let menu = NSMenu()
        menu.addItem(withTitle: L10n.string("大爆炸 · 选中文字后使用快捷键"), action: nil, keyEquivalent: "")
        for preset in configuration.presets {
            menu.addItem(withTitle: "\(preset.name)    \(preset.shortcut.label)", action: nil, keyEquivalent: "")
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: L10n.string("设置…"), action: #selector(showSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: L10n.string("预览便签"), action: #selector(showDemo), keyEquivalent: "").target = self
        menu.addItem(withTitle: L10n.string("关闭全部便签"), action: #selector(closeAll), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: L10n.string("退出"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }
    @objc func showSettings() {
        if settingsWindow == nil {
            let window = SettingsWindow()
            window.delegate = self
            settingsWindow = window
        }
        if settingsEditor == nil {
            settingsEditor = SettingsEditor(configuration: store.configuration, save: { [weak self] config, key in
                guard let self else { return }
                try config.validate()
                let old = self.store.configuration
                try self.hotKeys.register(config.presets)
                do {
                    if !key.isEmpty { try Keychain.save(key) }
                    try self.store.save(config)
                } catch { try? self.hotKeys.register(old.presets); throw error }
                self.refreshLocalization()
            }, deleteKey: { try Keychain.delete() })
        }
        guard let settingsEditor else { return }
        do { settingsEditor.hasKey = !(try Keychain.read()).isEmpty }
        catch { settingsEditor.error = error.localizedDescription }
        if settingsWindow?.contentView == nil || settingsWindow?.contentView?.subviews.isEmpty == true {
            let content = NSHostingView(rootView: SettingsView(editor: settingsEditor, demo: { [weak self] in self?.showDemo() }, onRecordingChange: { [weak self] recording in
                guard let self else { return }
                if recording { self.hotKeys.pause() }
                else { do { try self.hotKeys.resume() } catch { self.notify(error.localizedDescription) } }
            }, loginItems: loginItems))
            settingsWindow?.contentView = GlassSurface.wrap(content, cornerRadius: 12)
        }
        loginItems.refresh()
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window === settingsWindow { settingsEditor?.flush() }
    }
    private func trigger(_ preset: Preset) {
        beginTrigger(preset, readKey: { try Keychain.read() }, start: { sticky, configuration, key in
            sticky.model.start(configuration: configuration, key: key)
        }, failure: { [weak self] in self?.notify($0) })
    }
    // A nonactivating panel can own keyboard focus while another application remains frontmost.
    // Snapshot our focused note first; never ask that other application for a stale selection.
    private func localStickySelection() throws -> String? {
        guard let focused = NSApp.keyWindow,
              let sticky = stickies.values.first(where: { $0.window === focused }) else { return nil }
        return try sticky.selectedOutputText()
    }
    private func beginTrigger(_ preset: Preset, readKey: @escaping () throws -> String,
                              start: @escaping (StickyWindow, Configuration, String) -> Void,
                              failure: @escaping (String) -> Void) {
        guard !reading else { return }
        guard stickies.count < 8 else { failure(L10n.string("最多同时打开 8 个便签，请先关闭部分便签。")); return }
        let focusedSticky = stickies.values.first(where: { $0.window === NSApp.keyWindow })
        reading = true
        Task { @MainActor [self] in
            defer { reading = false }
            do {
                _ = try await prepareTriggeredSticky(preset, selection: {
                    if let focusedSticky { return try await focusedSticky.selectedOutputTextSnapshot() }
                    return try await SelectionReader.read(copyFallback: self.store.configuration.copyFallback,
                                                          triggerKeyCode: UInt16(exactly: preset.shortcut.keyCode),
                                                          onClipboardPhase: { phase in
                        switch phase {
                        case .began: ClipboardAccessGate.shared.begin()
                        case .ended: ClipboardAccessGate.shared.end()
                        }
                    })
                }, readKey: readKey, start: start)
            } catch { failure(error.localizedDescription) }
        }
    }
    /// Show the note before reading, while preserving the source application's keyboard focus.
    private func prepareTriggeredSticky(_ preset: Preset, selection: @escaping () async throws -> String,
                                        readKey: @escaping () throws -> String,
                                        start: @escaping (StickyWindow, Configuration, String) -> Void) async throws -> StickyWindow {
        let sticky = createSticky(preset: preset, source: "", capturingSelection: true)
        sticky.configureProcessing(configuration: { [weak self] in self?.store.configuration ?? Configuration() },
                                   readKey: readKey, start: start)
        // showWindow makes the panel key; orderFront alone leaves copying in the source app.
        sticky.window?.orderFrontRegardless()
        let capture = Task { @MainActor in try await selection() }
        sticky.cancelCapture = { capture.cancel() }
        let result = await withTaskCancellationHandler(operation: { await capture.result }, onCancel: { capture.cancel() })
        // SelectionReader's clipboard restoration runs before this result becomes available.
        sticky.cancelCapture = nil
        guard sticky.window?.isVisible == true else {
            sticky.model.finishCapture()
            return sticky
        }
        if Task.isCancelled || sticky.captureCancelled {
            sticky.model.finishCapture(needsInput: true)
            // Manual takeover already focused the editor. Clipboard cleanup may
            // finish after the user chooses another window; keep that newer focus.
            return sticky
        }
        let text: String
        switch result {
        case .success(let selected): text = selected
        case .failure(is CancellationError):
            sticky.model.finishCapture()
            sticky.window?.close()
            throw CancellationError()
        case .failure: text = ""
        }
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            do {
                let key = try readKey()
                guard !store.configuration.requiresAPIKey || !key.isEmpty else { throw ValidationError("请先在设置中保存 API Key。") }
                sticky.model.acceptInput(text)
                sticky.model.finishCapture()
                start(sticky, store.configuration, key)
            } catch {
                sticky.model.draft = text
                sticky.model.error = error.localizedDescription
                sticky.model.finishCapture(needsInput: true)
            }
        } else {
            sticky.model.finishCapture(needsInput: true)
        }
        if sticky.model.awaitingInput { sticky.window?.makeKeyAndOrderFront(nil) }
        return sticky
    }
    @discardableResult private func createSticky(preset: Preset, source: String, capturingSelection: Bool = false) -> StickyWindow {
        let id = UUID()
        let sticky = StickyWindow(preset: preset, source: source, offset: stickies.count, capturingSelection: capturingSelection)
        sticky.updateConfiguration(store.configuration)
        sticky.onClose = { [weak self] in self?.stickies.removeValue(forKey: id) }
        stickies[id] = sticky
        return sticky
    }
    @objc func closeAll() { for sticky in Array(stickies.values) { sticky.window?.close() } }
    @objc func showDemo() {
        guard stickies.count < 8 else { return }
        let language = L10n.currentLanguage
        let sticky = createSticky(preset: Preset.defaults(for: language)[2], source: "Select any text. Press a shortcut. See your ideas unfold.")
        sticky.model.running = true; sticky.model.state = "演示 · 本地模拟"
        sticky.showWindow(nil); sticky.window?.orderFrontRegardless()
        Task { @MainActor [weak sticky] in
            let chunks = (1...7).map { L10n.string("demo.chunk.\($0)", language: language) }
            for chunk in chunks {
                try? await Task.sleep(for: .milliseconds(180))
                guard let sticky, sticky.model.running else { return }
                sticky.model.output += chunk
            }
            sticky?.model.running = false; sticky?.model.state = "演示已完成"
        }
    }
    private func notify(_ message: String) {
        let alert = NSAlert(); alert.messageText = L10n.string("大爆炸"); alert.informativeText = message
        alert.addButton(withTitle: L10n.string("好"))
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
    @MainActor private final class PreferencesLoginItemManager: LoginItemManaging {
        var status: LoginItemStatus = .disabled
        var fail = false
        var registrations = 0
        var removals = 0
        func register() throws {
            registrations += 1
            if fail { throw ValidationError("fixture failure") }
            status = .enabled
        }
        func unregister() throws {
            removals += 1
            if fail { throw ValidationError("fixture failure") }
            status = .disabled
        }
        func openSystemSettings() {}
    }
    private func runPreferencesTest() {
        // Real native controls and persistent settings, with isolated credentials,
        // login-item operations, and output. Never register a real login item.
        guard let index = CommandLine.arguments.firstIndex(of: "--report"), CommandLine.arguments.count > index + 1 else {
            NSApp.terminate(nil); return
        }
        let reportURL = URL(fileURLWithPath: CommandLine.arguments[index + 1])
        let previouslyFrontmost = NSWorkspace.shared.frontmostApplication
        let environment = ProcessInfo.processInfo.environment
        let mode = environment["MACOS_LOCALIZATION_TEST_MODE"] ?? "normal"
        // Preserve the fresh absolute path reserved by the runner. Foundation may
        // alias an existing /private/tmp directory to /tmp after reservation.
        let outputURL = reportURL.deletingLastPathComponent()
        let suiteDigest = SHA256.hash(data: Data(outputURL.path.utf8)).map { String(format: "%02x", $0) }.joined()
        let managedSuite = environment["MACOS_LOCALIZATION_TEST_SUITE"]
        let suiteName = managedSuite ?? "app.mayfiles.BigBang.preferences-test.\(UUID().uuidString)"
        let expectedSuite = "app.mayfiles.BigBang.localization-test.\(suiteDigest)"
        let progressURL = outputURL.appendingPathComponent("localization-progress.json")
        let runtimeURL = outputURL.appendingPathComponent("fixture-data", isDirectory: true)
        func rejectControl(_ message: String) {
            let report: [String: Any] = ["passed": false, "error": message, "realLoginItemMutations": 0,
                "modelRequests": 0, "keychainOperations": 0]
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: reportURL, options: .atomic)
            }
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
        guard ["normal", "fail", "hold"].contains(mode) else { rejectControl("Unknown localization fixture mode"); return }
        if let managedSuite {
            guard managedSuite == expectedSuite,
                environment["MACOS_LOCALIZATION_TEST_DIRECTORY"] == runtimeURL.path,
                environment["MACOS_LOCALIZATION_TEST_PROGRESS"] == progressURL.path else {
                rejectControl("Localization fixture ownership does not match the fresh output directory"); return
            }
        } else if mode != "normal" {
            rejectControl("Controlled localization checks require the common native test runner"); return
        }
        guard let defaults = UserDefaults(suiteName: suiteName) else { NSApp.terminate(nil); return }
        let isolatedStore = SettingsStore(defaults: defaults)
        let firstLaunchLanguage = isolatedStore.configuration.language
        try? isolatedStore.save(Configuration(language: .simplifiedChinese))
        let manager = PreferencesLoginItemManager()
        let controller = LoginItemController(manager: manager)
        let preview = SettingsWindow()
        let editor = SettingsEditor(configuration: isolatedStore.configuration, save: { [weak self] configuration, key in
            guard key.isEmpty else { throw ValidationError("fixture must not write credentials") }
            try isolatedStore.save(configuration)
            self?.refreshLocalization(configuration: configuration)
            preview.title = L10n.string("大爆炸设置")
        }, deleteKey: {})
        let note = createSticky(preset: Preset.defaults[2], source: "Local fixture")
        note.updateConfiguration(isolatedStore.configuration)
        note.model.output = "Existing output stays unchanged."
        note.model.state = "已完成"
        note.showWindow(nil)
        preview.contentView = GlassSurface.wrap(NSHostingView(rootView: SettingsView(editor: editor,
            demo: {}, onRecordingChange: { _ in }, initialSection: .general, loginItems: controller)), cornerRadius: 12)
        preview.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        func label(_ window: NSWindow, _ identifier: String) -> String? {
            guard let element = accessibilityElement(in: window, identifier: identifier) else { return nil }
            let selector = NSSelectorFromString("accessibilityLabel")
            guard element.object.responds(to: selector) else { return nil }
            return element.object.perform(selector)?.takeUnretainedValue() as? String
        }
        func versionText() -> String? {
            guard let element = accessibilityElement(in: preview, identifier: "app.version") else { return nil }
            for attribute in ["accessibilityValue", "accessibilityLabel"] {
                let selector = NSSelectorFromString(attribute)
                if element.object.responds(to: selector),
                   let value = element.object.perform(selector)?.takeUnretainedValue() as? String, !value.isEmpty {
                    return value
                }
            }
            return nil
        }
        func press(_ identifier: String) -> Bool {
            accessibilityElement(in: preview, identifier: identifier)?.accessibilityPerformPress() == true
        }
        func finish(_ checks: [String: Bool], error: String? = nil, realStatus: String? = nil) {
            var report: [String: Any] = checks
            report["passed"] = error == nil && !checks.isEmpty && checks.values.allSatisfy { $0 }
            report["macOS"] = ProcessInfo.processInfo.operatingSystemVersionString
            report["realLoginItemStatusReadOnly"] = realStatus
            report["realLoginItemMutations"] = 0
            report["modelRequests"] = 0
            report["keychainOperations"] = 0
            report["fixtureSuite"] = suiteName
            report["fixtureMode"] = mode
            report["error"] = error
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: reportURL, options: .atomic)
            }
            preview.close(); closeAll()
            defaults.removePersistentDomain(forName: suiteName)
            _ = defaults.synchronize()
            previouslyFrontmost?.activate(options: [])
            if let error { fputs("FAIL: \(error)\n", stderr); exit(1) }
            NSApp.terminate(nil)
        }
        Task { @MainActor in
            var checks: [String: Bool] = [:]
            checks["firstLaunchMatchesSystemLanguage"] = firstLaunchLanguage == AppLanguage.preferred(in: Locale.preferredLanguages)
            checks["chineseApplicationTitleRendered"] = preview.title == "大爆炸设置" && note.window?.title == "大爆炸 · 📝 总结"
            let loginEvent = NSAppleEventDescriptor.appleEvent(withEventClass: AEEventClass(kCoreEventClass),
                eventID: AEEventID(kAEOpenApplication), targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
            loginEvent.setParam(NSAppleEventDescriptor(enumCode: keyAELaunchedAsLogInItem), forKeyword: keyAEPropData)
            checks["loginLaunchEventIsRecognized"] = Self.isLoginLaunch(loginEvent)
            checks["manualLaunchIsNotLoginLaunch"] = !Self.isLoginLaunch(nil) &&
                !Self.isLoginLaunch(NSAppleEventDescriptor.appleEvent(withEventClass: AEEventClass(kCoreEventClass),
                    eventID: AEEventID(kAEOpenApplication), targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID)))
            checks["generalPageExposesNativeControls"] = await waitFor {
                accessibilityElement(in: preview, identifier: "settings.launchAtLogin") != nil &&
                    accessibilityElement(in: preview, identifier: "settings.language.en") != nil
            }
            let version = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let build = (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let versionValue = build.isEmpty ? version : "\(version) (\(build))"
            checks["chineseSettingsVersionMatchesBundle"] = !version.isEmpty &&
                versionText() == "版本 \(versionValue)"
            print("DIAGNOSTIC: settings-version language=zh-Hans expected=版本 \(versionValue) observed=\(versionText() ?? "<missing>")")
            snapshot(preview, name: "settings-general-zh.png", includeFrame: true)
            checks["loginToggleRegistersThroughController"] = press("settings.launchAtLogin") && controller.status == .enabled && manager.registrations == 1
            checks["loginToggleUnregistersThroughController"] = press("settings.launchAtLogin") && controller.status == .disabled && manager.removals == 1
            checks["languageButtonSavesEnglishImmediately"] = press("settings.language.en") && isolatedStore.configuration.language == .english
            checks["englishGeneralLabelsRendered"] = await waitFor {
                label(preview, "settings.section.general") == "General" && label(preview, "settings.launchAtLogin") == "Launch at Login"
            }
            checks["englishSettingsVersionMatchesBundle"] = await waitFor {
                !version.isEmpty && versionText() == "Version \(versionValue)"
            }
            print("DIAGNOSTIC: settings-version language=en expected=Version \(versionValue) observed=\(versionText() ?? "<missing>")")
            checks["languagePersistsAcrossStoreReload"] = SettingsStore(defaults: defaults).configuration == isolatedStore.configuration
            checks["englishApplicationTitleAndTooltip"] = preview.title == "Big Bang Settings" &&
                note.window?.title == "Big Bang · 📝 Summarize" && statusItem.button?.toolTip == "Big Bang · Press ⌃⌥1 / 2 / 3 / 4 / 5 to process text"
            checks["englishStatusAccessibility"] = statusItem.button?.accessibilityLabel() == "Big Bang"
            checks["menuLanguageUpdatesImmediately"] = statusItem.menu?.items.contains(where: { $0.title == "Settings…" }) == true &&
                NSApp.mainMenu?.items.last?.title == "Edit"
            checks["existingNoteLanguageUpdatesWithoutChangingOutput"] = note.model.language == .english &&
                note.model.displayedPresetName == "📝 Summarize" && note.model.output == "Existing output stays unchanged."
            if let window = note.window {
                checks["noteAccessibilityIsEnglish"] = await waitFor { label(window, "sticky.copy") == "Copy" }
                snapshot(window, name: "sticky-en.png")
            }
            snapshot(preview, name: "settings-general-en.png", includeFrame: true)
            if managedSuite != nil {
                let englishChecks = ["languageButtonSavesEnglishImmediately", "englishGeneralLabelsRendered",
                    "englishApplicationTitleAndTooltip", "englishStatusAccessibility", "menuLanguageUpdatesImmediately",
                    "existingNoteLanguageUpdatesWithoutChangingOutput", "noteAccessibilityIsEnglish"]
                guard englishChecks.allSatisfy({ checks[$0] == true }) else {
                    finish(checks, error: "Native English localization checkpoint was not established"); return
                }
                do {
                    // The runtime snapshot is isolated fixture data; the recorder
                    // reclaims it after normal exit, failure, timeout or interruption.
                    try JSONEncoder().encode(isolatedStore.configuration).write(
                        to: runtimeURL.appendingPathComponent("configuration.json"), options: .atomic)
                    let progress: [String: Any] = ["stage": "english-visible", "language": "en",
                        "pid": Int(getpid()), "mode": mode, "settingsTitle": preview.title,
                        "fixtureSuite": suiteName]
                    try JSONSerialization.data(withJSONObject: progress, options: [.prettyPrinted, .sortedKeys])
                        .write(to: progressURL, options: .atomic)
                } catch {
                    finish(checks, error: "Could not write the owned localization checkpoint: \(error.localizedDescription)"); return
                }
                if mode == "fail" {
                    finish(checks, error: "Controlled failure after native English localization"); return
                }
                while mode == "hold" { try? await Task.sleep(for: .seconds(60)) }
            }
            preview.appearance = NSAppearance(named: .darkAqua)
            try? await Task.sleep(for: .milliseconds(150))
            snapshot(preview, name: "settings-general-en-dark.png", includeFrame: true)
            preview.appearance = NSAppearance(named: .aqua)
            manager.status = .requiresApproval; controller.refresh()
            checks["systemApprovalStateVisible"] = await waitFor {
                controller.isEnabled && accessibilityElement(in: preview, identifier: "settings.launchAtLogin.openSettings") != nil
            }
            manager.fail = true
            checks["failedSystemWriteKeepsRealState"] = press("settings.launchAtLogin") && controller.status == .requiresApproval &&
                controller.error == "Could not change launch at login. Check Login Items in System Settings, then try again."
            checks["systemWriteErrorRenderedInEnglish"] = await waitFor {
                accessibilityElement(in: preview, identifier: "settings.launchAtLogin.error") != nil
            }
            snapshot(preview, name: "settings-login-approval-en.png", includeFrame: true)
            manager.fail = false
            _ = press("settings.launchAtLogin")
            manager.status = .unavailable; controller.refresh()
            checks["unavailableStatusKeepsToggleOff"] = !controller.canToggle && !controller.isEnabled &&
                controller.error?.hasPrefix("Launch at login is unavailable.") == true
            manager.status = .disabled; controller.refresh()
            checks["presetsNavigationWorksInEnglish"] = press("settings.section.presets")
            checks["englishPresetsRendered"] = await waitFor {
                label(preview, "settings.preset.\(Preset.defaults[0].id).name") == "Preset Name" &&
                    isolatedStore.configuration.presets[0].name == "🌐 Translate"
            }
            checks["englishVisualizationPresetAvailable"] = await waitFor {
                label(preview, "settings.preset.\(Preset.defaults[3].id).name") == "Preset Name" &&
                    isolatedStore.configuration.presets[3].name == "📊 Visualize" &&
                    statusItem.menu?.items.contains(where: { $0.title == "📊 Visualize    ⌃⌥4" }) == true &&
                    note.model.availablePresets.contains(where: { $0.id == Preset.defaults[3].id && $0.name == "📊 Visualize" })
            }
            checks["englishAssistantPresetAvailable"] = await waitFor {
                label(preview, "settings.preset.\(Preset.defaults[4].id).name") == "Preset Name" &&
                    isolatedStore.configuration.presets[4].name == "🤖 Assistant" &&
                    statusItem.menu?.items.contains(where: { $0.title == "🤖 Assistant    ⌃⌥5" }) == true &&
                    note.model.availablePresets.contains(where: { $0.id == Preset.defaults[4].id && $0.name == "🤖 Assistant" })
            }
            snapshot(preview, name: "settings-presets-en.png", includeFrame: true)
            let previousCount = editor.draft.presets.count
            _ = press("settings.preset.add")
            checks["englishNewPresetHasEnglishInstructions"] = await waitFor {
                editor.draft.presets.count == previousCount + 1 && editor.draft.presets.last?.name == "New Preset" &&
                    editor.draft.presets.last?.prompt == "Process the text provided by the user."
            }
            let custom = editor.draft.presets.last!
            _ = press("settings.section.connection")
            checks["englishConnectionLabelsRendered"] = await waitFor { label(preview, "settings.endpoint") == "API URL" }
            snapshot(preview, name: "settings-connection-en.png", includeFrame: true)
            editor.draft.model = ""; editor.flush()
            checks["englishValidationErrorVisible"] = await waitFor {
                editor.error == "Enter a model name." && accessibilityElement(in: preview, identifier: "settings.error") != nil
            }
            editor.draft.model = "local-model"; editor.flush()
            _ = press("settings.section.reading")
            checks["englishReadingLabelsRendered"] = await waitFor { label(preview, "settings.copyFallback") == "Read via Clipboard" }
            snapshot(preview, name: "settings-reading-en.png", includeFrame: true)
            _ = press("settings.section.general")
            _ = await waitFor { accessibilityElement(in: preview, identifier: "settings.language.zh-Hans") != nil }
            checks["languageSwitchBackPreservesCustomPreset"] = press("settings.language.zh-Hans") &&
                isolatedStore.configuration.language == .simplifiedChinese && isolatedStore.configuration.presets.last == custom &&
                isolatedStore.configuration.presets.first?.name == "🌐 翻译"
            checks["chineseVisualizationPresetAvailable"] =
                isolatedStore.configuration.presets[3].name == "📊 可视化" &&
                statusItem.menu?.items.contains(where: { $0.title == "📊 可视化    ⌃⌥4" }) == true &&
                note.model.availablePresets.contains(where: { $0.id == Preset.defaults[3].id && $0.name == "📊 可视化" })
            checks["chineseAssistantPresetAvailable"] =
                isolatedStore.configuration.presets[4].name == "🤖 助手" &&
                statusItem.menu?.items.contains(where: { $0.title == "🤖 助手    ⌃⌥5" }) == true &&
                note.model.availablePresets.contains(where: { $0.id == Preset.defaults[4].id && $0.name == "🤖 助手" })
            checks["chineseApplicationTitleAndTooltip"] = preview.title == "大爆炸设置" && note.window?.title == "大爆炸 · 📝 总结" &&
                statusItem.button?.toolTip == "大爆炸 · 按 ⌃⌥1 / 2 / 3 / 4 / 5 处理文本" && statusItem.button?.accessibilityLabel() == "大爆炸"
            checks["menuAndExistingNoteSwitchBack"] = statusItem.menu?.items.contains(where: { $0.title == "设置…" }) == true &&
                note.model.displayedPresetName == "📝 总结" && note.model.displayedState == "已完成"
            _ = press("settings.section.presets")
            _ = await waitFor { accessibilityElement(in: preview, identifier: "settings.preset.restore") != nil }
            snapshot(preview, name: "settings-presets-zh.png", includeFrame: true)
            let productionController = LoginItemService.controller()
            let realStatus = productionController.status
            checks["packagedApplicationSupportsLoginRegistration"] = productionController.canToggle
            finish(checks, realStatus: String(describing: realStatus))
        }
    }
    private func runSelectionTest() {
        // Local cross-app verification: no settings writes, keychain/API access, or sticky creation.
        func argument(_ name: String) -> String? {
            guard let index = CommandLine.arguments.firstIndex(of: name), CommandLine.arguments.count > index + 1 else { return nil }
            return CommandLine.arguments[index + 1]
        }
        guard let path = argument("--report"), let fixturePath = argument("--selection-fixture"),
              let expected = try? String(contentsOfFile: fixturePath, encoding: .utf8) else { NSApp.terminate(nil); return }
        func digest(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
        func save(_ report: [String: Any]) {
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
            }
        }
        var preset = Preset.defaults[0]
        preset.shortcut = .init(keyCode: 25, modifiers: 6144, label: "⌃⌥9")
        hotKeys.onTrigger = { [weak self] _ in
            guard let self, !self.reading else { return }
            self.reading = true
            Task { @MainActor in
                var observations: [[String: Any]] = []
                var report: [String: Any] = ["ready": true, "expectedSHA256": digest(expected), "modelRequests": 0]
                do {
                    let text = try await SelectionReader.read(copyFallback: true, triggerKeyCode: 25, onCopiedClipboard: { copy in
                        var observation: [String: Any] = ["types": copy.types, "textMatchesFixture": copy.text == expected,
                            "dataBytes": copy.customData.mapValues(\.count)]
                        // Only save metadata produced while copying our exact known fixture.
                        if copy.text == expected { observation["fixtureMetadataBase64"] = copy.customData.mapValues { $0.base64EncodedString() } }
                        if observations.count < 3 { observations.append(observation) }
                        else { observations[2] = observation }
                    })
                    report["textMatchesFixture"] = text == expected
                    report["actualSHA256"] = digest(text)
                    report["actualUTF8Bytes"] = text.utf8.count
                    report["success"] = text == expected
                } catch {
                    report["success"] = false
                    report["error"] = error.localizedDescription
                }
                report["clipboardObservations"] = observations
                save(report)
                NSApp.terminate(nil)
            }
        }
        do {
            try hotKeys.register([preset])
            save(["ready": true, "shortcut": preset.shortcut.label, "trusted": SelectionReader.isTrusted, "modelRequests": 0])
        } catch { save(["ready": false, "error": error.localizedDescription]); NSApp.terminate(nil) }
    }
    private func runStickySelectionTest() {
        // Own two local test processes. No API, keychain, clipboard, TCC, or settings writes.
        func argument(_ name: String) -> String? {
            guard let index = CommandLine.arguments.firstIndex(of: name), CommandLine.arguments.count > index + 1 else { return nil }
            return CommandLine.arguments[index + 1]
        }
        guard let path = argument("--report"), let fixturePath = argument("--fixture-app") else { NSApp.terminate(nil); return }
        let folder = URL(fileURLWithPath: path).deletingLastPathComponent()
        let ready = folder.appendingPathComponent("external-fixture-ready.json")
        try? FileManager.default.removeItem(at: ready)
        let previouslyFrontmost = NSWorkspace.shared.frontmostApplication
        let previousMouse = NSEvent.mouseLocation
        let fixture = Process()
        fixture.executableURL = URL(fileURLWithPath: fixturePath).appendingPathComponent("Contents/MacOS/ExternalSelectionFixture")
        fixture.arguments = ["--ready", ready.path]
        var checks: [String: Bool] = [:]
        var problem: String?
        var diagnostics: [String: Any] = [:]
        var nativeMouseDownCount = 0
        var nativeMouseUpCount = 0
        var nativeKeyDownCount = 0
        var nativeKeyUpCount = 0
        let inputSource = CGEventSource(stateID: .combinedSessionState)
        let eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .keyDown, .keyUp]) { event in
            switch event.type {
            case .leftMouseDown: nativeMouseDownCount += 1
            case .leftMouseUp: nativeMouseUpCount += 1
            case .keyDown where event.keyCode == 25: nativeKeyDownCount += 1
            case .keyUp where event.keyCode == 25: nativeKeyUpCount += 1
            default: return event
            }
            fputs("note-event type=\(event.type.rawValue) windowNumber=\(event.windowNumber) keyCode=\(event.type == .keyDown || event.type == .keyUp ? event.keyCode : 0) modifiers=\(event.modifierFlags.rawValue)\n", stderr)
            return event
        }
        func finish() {
            if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
            try? hotKeys.register([]); hotKeys.onTrigger = nil
            closeAll()
            if fixture.isRunning { fixture.terminate() }
            previouslyFrontmost?.activate(options: [])
            if let primary = NSScreen.screens.first {
                CGWarpMouseCursorPosition(CGPoint(x: previousMouse.x, y: primary.frame.maxY - previousMouse.y))
            }
            var report: [String: Any] = checks
            report["passed"] = !checks.isEmpty && checks.values.allSatisfy { $0 } && problem == nil
            report["macOS"] = ProcessInfo.processInfo.operatingSystemVersionString
            diagnostics["nativeMouseDownCount"] = nativeMouseDownCount
            diagnostics["nativeMouseUpCount"] = nativeMouseUpCount
            diagnostics["nativeKeyDownCount"] = nativeKeyDownCount
            diagnostics["nativeKeyUpCount"] = nativeKeyUpCount
            report["diagnostics"] = diagnostics
            report["scope"] = "Packaged application, nonactivating panel selection, separate frontmost fixture, posted physical key events, Carbon handler, new note with simulated model start; no API or user data writes."
            if let problem { report["error"] = problem }
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
            }
            NSApp.terminate(nil)
        }
        do { try fixture.run() } catch { problem = error.localizedDescription; finish(); return }
        Task { @MainActor in
            checks["externalFixtureIsFrontmost"] = await waitFor {
                FileManager.default.fileExists(atPath: ready.path) && NSWorkspace.shared.frontmostApplication?.processIdentifier == fixture.processIdentifier
            }
            guard checks["externalFixtureIsFrontmost"] == true else { problem = "Fixture did not acquire foreground"; finish(); return }
            let sticky = createSticky(preset: .defaults[0], source: "触发旧便签时的原始输入")
            sticky.model.output = "便签中的 **新输入 🌍**，请继续处理这段文字。"
            sticky.showWindow(nil); sticky.window?.orderFrontRegardless()
            _ = await waitFor { self.stickyTextView(in: sticky.hostingView) != nil }
            guard let window = sticky.window, let textView = stickyTextView(in: sticky.hostingView) else {
                problem = "Native output missing"; finish(); return
            }
            guard await waitFor({ textView.ready && textView.renderingComplete && textView.renderedSource == sticky.model.output }) else {
                problem = "Native output did not finish initial rendering"; finish(); return
            }
            try? await Task.sleep(for: .milliseconds(150))
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(textView)
            // A real click exercises the nonactivating panel's keyboard-focus path.
            let point = window.convertPoint(toScreen: textView.convert(NSPoint(x: 8, y: 8), to: nil))
            diagnostics["noteWindowNumber"] = window.windowNumber
            diagnostics["noteWindowFrame"] = NSStringFromRect(window.frame)
            diagnostics["textVisibleRect"] = NSStringFromRect(textView.visibleRect)
            diagnostics["textFrame"] = NSStringFromRect(textView.frame)
            diagnostics["screenPoint"] = NSStringFromPoint(point)
            diagnostics["hitWindowNumber"] = NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0)
            if let primary = NSScreen.screens.first, let source = inputSource {
                let position = CGPoint(x: point.x, y: primary.frame.maxY - point.y)
                diagnostics["quartzPoint"] = NSStringFromPoint(position)
                CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: position, mouseButton: .left)?.post(tap: .cghidEventTap)
                try? await Task.sleep(for: .milliseconds(60))
                CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: position, mouseButton: .left)?.post(tap: .cghidEventTap)
            }
            try? await Task.sleep(for: .milliseconds(150))
            let selected = "新输入 🌍"
            textView.setSelectedRange((textView.renderedText as NSString).range(of: selected))
            try? await Task.sleep(for: .milliseconds(80))
            checks["fixtureRemainsFrontmostWithNoteFocused"] = NSWorkspace.shared.frontmostApplication?.processIdentifier == fixture.processIdentifier
            checks["nonactivatingPanelOwnsNativeSelection"] = window.isKeyWindow && textView.isOutputFocused &&
                window.styleMask.contains(.nonactivatingPanel) && NSWorkspace.shared.frontmostApplication?.processIdentifier == fixture.processIdentifier
            diagnostics["noteIsKeyWindow"] = window.isKeyWindow
            diagnostics["noteOwnsFirstResponder"] = textView.isOutputFocused
            diagnostics["noteAppIsActive"] = NSApp.isActive
            diagnostics["frontmostPIDAfterClick"] = NSWorkspace.shared.frontmostApplication?.processIdentifier
            checks["inputPostingIsAuthorized"] = CGPreflightPostEventAccess()
            var child: StickyWindow?
            var failure: String?
            var eventCount = 0
            var probe = Preset.defaults[1]
            probe.shortcut = .init(keyCode: 25, modifiers: UInt32(cmdKey | controlKey | optionKey | shiftKey), label: "Test ⌃⌥⇧⌘9")
            hotKeys.onTrigger = { preset in
                eventCount += 1
                self.beginTrigger(preset, readKey: { "local-fixture-key" }, start: { note, _, _ in
                    child = note; note.model.output = "链式处理已启动"
                }, failure: { failure = $0 })
            }
            func postShortcut() async {
                guard let source = inputSource,
                      let down = CGEvent(keyboardEventSource: source, virtualKey: 25, keyDown: true),
                      let up = CGEvent(keyboardEventSource: source, virtualKey: 25, keyDown: false) else { return }
                // Post complete modifier transitions as required by CGEventCreateKeyboardEvent.
                let modifiers: [(CGKeyCode, CGEventFlags)] = [(55, .maskCommand), (59, .maskControl), (58, .maskAlternate), (56, .maskShift)]
                var flags: CGEventFlags = []
                for (code, flag) in modifiers {
                    flags.insert(flag)
                    let modifier = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true)
                    modifier?.flags = flags; modifier?.post(tap: .cghidEventTap)
                    try? await Task.sleep(for: .milliseconds(30))
                }
                down.flags = flags; up.flags = flags
                diagnostics["flagsBeforeShortcut"] = CGEventSource.flagsState(.combinedSessionState).rawValue
                diagnostics["carbonModifiersBeforeShortcut"] = GetCurrentKeyModifiers()
                down.post(tap: .cghidEventTap)
                try? await Task.sleep(for: .milliseconds(60))
                up.post(tap: .cghidEventTap)
                try? await Task.sleep(for: .milliseconds(60))
                for (code, flag) in modifiers.reversed() {
                    flags.remove(flag)
                    let modifier = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)
                    modifier?.flags = flags; modifier?.post(tap: .cghidEventTap)
                    try? await Task.sleep(for: .milliseconds(30))
                }
            }
            do {
                try hotKeys.register([probe])
                await postShortcut()
                _ = await waitFor { child != nil || failure != nil }
                checks["physicalHotkeyReachesCarbonHandler"] = eventCount == 1
                diagnostics["carbonCountAfterSelection"] = eventCount
                diagnostics["selectionTriggerFailure"] = failure
                checks["newNoteUsesOwnRenderedSelection"] = child?.model.source == selected && child?.model.preset.id == probe.id
                checks["neitherOriginalInputIsReused"] = child?.model.source != sticky.model.source && child?.model.source != "外部原始选区" && child != nil
                snapshot(child?.window, name: "nonactivating-chained-note.png")
                child?.window?.close(); child = nil; failure = nil
                window.makeKeyAndOrderFront(nil); window.makeFirstResponder(textView)
                textView.setSelectedRange(NSRange(location: 0, length: 0))
                try? await Task.sleep(for: .milliseconds(80))
                await postShortcut()
                _ = await waitFor { failure != nil || self.stickies.values.contains { $0.model.awaitingInput } }
                let draft = self.stickies.values.first { $0.model.awaitingInput }
                checks["emptySelectionOpensDraftWithoutForeignText"] = eventCount == 2 && failure == nil && child == nil &&
                    draft?.model.source.isEmpty == true && draft?.model.draft.isEmpty == true
                draft?.window?.close()
                checks["foreignAppStaysFrontmostAfterChaining"] = NSWorkspace.shared.frontmostApplication?.processIdentifier == fixture.processIdentifier
                diagnostics["carbonCountAfterEmptySelection"] = eventCount
                diagnostics["emptyTriggerFailure"] = failure
            } catch { problem = error.localizedDescription }
            finish()
        }
    }

    private func runSmokeTest() {
        // UI-only run: no permissions, keychain, clipboard, settings, or API mutations.
        NSApp.appearance = NSAppearance(named: .aqua)
        let first = createSticky(preset: .defaults[0], source: "Native smoke test")
        let second = createSticky(preset: .defaults[1], source: "Second independent note")
        var previewSaved = Configuration(language: .simplifiedChinese)
        var previewRecording = false
        var previewDemoCount = 0
        let previewEditor = SettingsEditor(configuration: Configuration(language: .simplifiedChinese), save: { config, _ in previewSaved = config }, deleteKey: {})
        let previewSettings = SettingsWindow()
        previewSettings.contentView = GlassSurface.wrap(NSHostingView(rootView: SettingsView(editor: previewEditor, demo: { previewDemoCount += 1 }, onRecordingChange: { previewRecording = $0 })), cornerRadius: 12)
        previewSettings.center(); previewSettings.orderFront(nil)
        first.showWindow(nil); second.showWindow(nil)
        first.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        first.model.output = "分片一 🌍"
        let markdownFixture = """
        ## 让文字更清楚

        保留 **重点**，让信息更容易阅读。

        - 翻译保留原意
        - 解释突出概念
        1. 选中一段文字
        2. 使用 `⌃⌥1` 快捷键

        > 便签保持轻盈，内容自然展开。

        ```swift
        let idea = "Hello, world"
        print(idea)
        ```

        查看 [使用说明](https://example.com/guide)。
        """
        second.model.autoScroll = false
        second.model.output = markdownFixture
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            first.model.output += "\n分片二"
            var checks: [String: Bool] = [
                "twoIndependentPanels": stickies.count == 2 && first.window !== second.window,
                "incrementalUnicodeOutput": first.model.output == "分片一 🌍\n分片二",
                "floatingAcrossSpaces": first.window?.level == .floating && first.window?.collectionBehavior.contains(.canJoinAllSpaces) == true,
                "nativeHostingView": first.hostingView.window === first.window,
                "transparentCompactPanel": first.window?.isOpaque == false && first.window!.frame.height <= 300,
                "borderlessPanelAcceptsFocus": first.window?.canBecomeKey == true
            ]
            if #available(macOS 26.0, *), !CommandLine.arguments.contains("--standard-appearance"),
               !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
                checks["nativeGlassSurface"] = first.window?.contentView is NSGlassEffectView && previewSettings.contentView is NSGlassEffectView
            } else {
                checks["nativeMaterialFallback"] = first.window?.contentView is NSVisualEffectView && previewSettings.contentView is NSVisualEffectView
            }
            checks.merge(checkHotKeyRegistration()) { _, new in new }
            _ = await waitFor {
                guard let firstWindow = first.window, let secondWindow = second.window else { return false }
                return accessibilityElement(in: firstWindow, identifier: "sticky.pin") != nil &&
                    accessibilityElement(in: secondWindow, identifier: "sticky.xmark") != nil
            }
            if let window = second.window {
                let frames = ["sticky.copy", "sticky.arrow.clockwise", "sticky.pin", "sticky.xmark"].compactMap {
                    accessibilityElement(in: window, identifier: $0)?.accessibilityFrame()
                }
                print("header action frames", frames)
                checks["headerActionsShareSizeAndAlignment"] = frames.count == 4 && frames.allSatisfy {
                    // The common desktop action target is 34pt; retain the existing alignment check.
                    abs($0.height - 34) < 1 && abs($0.width - 34) < 1 && abs($0.midY - frames[0].midY) < 1
                }
            }
            if let textView = stickyTextView(in: second.hostingView) {
                _ = await waitFor { textView.ready && textView.renderedSource == second.model.output }
                checks["markdownRendersBlocksAndInlineStyles"] = (try? await textView.evaluate("""
                    (() => { const root = document.querySelector('#markdown-root');
                    return !!root && !!root.querySelector('h2') && !!root.querySelector('strong') &&
                    !!root.querySelector('pre code') && !!root.querySelector('ul li') &&
                    root.querySelector('a[href="https://example.com/guide"]')?.textContent === '使用说明' &&
                    !root.isContentEditable; })()
                    """)) as? Bool == true
                checks["markdownViewUsesMeasuredTextHeight"] = textView.contentHeight > 0 && abs(textView.bounds.height - textView.contentHeight) < 2
                checks["codeBlocksUseContinuousSurface"] = (try? await textView.evaluate("""
                    (() => { const pre = document.querySelector('#markdown-root pre');
                    return !!pre && getComputedStyle(pre).backgroundColor !== 'rgba(0, 0, 0, 0)'; })()
                    """)) as? Bool == true
            } else { checks["markdownRendersBlocksAndInlineStyles"] = false }
            if let window = first.window { _ = accessibilityElement(in: window, identifier: "sticky.pin")?.accessibilityPerformPress() }
            try? await Task.sleep(for: .milliseconds(50))
            checks["unpinChangesWindowLevel"] = first.window?.level == .normal && !first.model.pinned
            snapshot(second.window, name: "sticky-preview.png")
            previewSettings.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            try? await Task.sleep(for: .milliseconds(100))
            snapshot(previewSettings, name: "settings-preview.png")
            snapshot(previewSettings, name: "settings-window-preview.png", includeFrame: true)
            checks["settingsTitlebarHasSurface"] = titlebarHasSurface(previewSettings)
            checks["sidebarDividerContinuesThroughTitlebar"] = sidebarDividerIsContinuous(previewSettings)
            checks["settingsHidesDuplicateWindowTitle"] = previewSettings.titleVisibility == .hidden
            checks["settingsDisplaysAppIcon"] = accessibilityElement(in: previewSettings, identifier: "settings.appIcon")?.accessibilityFrame().height == 44
            checks["settingsActionButtonsHaveComfortableHeight"] = ["settings.preview", "settings.api.responses", "settings.api.chatCompletions"].allSatisfy {
                (accessibilityElement(in: previewSettings, identifier: $0)?.accessibilityFrame().height ?? 0) >= 34
            }
            _ = accessibilityElement(in: previewSettings, identifier: "settings.preview")?.accessibilityPerformPress()
            checks["previewButtonResponds"] = previewDemoCount == 1
            _ = accessibilityElement(in: previewSettings, identifier: "settings.api.chatCompletions")?.accessibilityPerformPress()
            checks["apiModeSelectionImmediatelySaves"] = previewEditor.draft.apiMode == .chatCompletions && previewSaved.apiMode == .chatCompletions
            _ = accessibilityElement(in: previewSettings, identifier: "settings.api.responses")?.accessibilityPerformPress()
            previewSettings.appearance = NSAppearance(named: .darkAqua)
            try? await Task.sleep(for: .milliseconds(150))
            snapshot(previewSettings, name: "settings-dark-window-preview.png", includeFrame: true)
            checks["darkSettingsTitlebarHasSurface"] = titlebarHasSurface(previewSettings)
            checks["darkSidebarDividerContinuesThroughTitlebar"] = sidebarDividerIsContinuous(previewSettings)
            checks["darkEndpointHasDarkSurface"] = darkFieldHasSurface(previewSettings, identifier: "settings.endpoint")
            checks["darkKeyHasDarkSurface"] = darkFieldHasSurface(previewSettings, identifier: "settings.key")
            previewSettings.appearance = NSAppearance(named: .aqua)
            accessibilityElement(in: previewSettings, identifier: "settings.endpoint")?.setAccessibilityFocused(true)
            try? await Task.sleep(for: .milliseconds(100))
            if let fieldEditor = previewSettings.firstResponder as? NSTextView,
               fieldEditor.string == previewEditor.draft.apiBaseURL {
                fieldEditor.insertText("https://edited.example/v1", replacementRange: NSRange(location: 0, length: fieldEditor.string.utf16.count))
                checks["restyledFieldAutosavesNativeTextInput"] = await waitFor { previewSaved.apiBaseURL == "https://edited.example/v1" }
            } else { checks["restyledFieldAutosavesNativeTextInput"] = false }
            let presetsButton = accessibilityElement(in: previewSettings, identifier: "settings.section.presets")
            _ = presetsButton?.accessibilityPerformPress()
            try? await Task.sleep(for: .milliseconds(150))
            checks["presetNavigationResponds"] = accessibilityElement(in: previewSettings, identifier: "settings.preset.\(previewEditor.draft.presets[0].id).prompt") != nil
            checks["presetActionsHaveComfortableHeight"] = ["settings.preset.restore", "settings.preset.add"].allSatisfy {
                (accessibilityElement(in: previewSettings, identifier: $0)?.accessibilityFrame().height ?? 0) >= 34
            }
            let originalOrder = previewEditor.draft.presets.map(\.id)
            let movedID = originalOrder[0]
            _ = accessibilityElement(in: previewSettings, identifier: "settings.preset.\(movedID).moveUp")?.accessibilityPerformPress()
            checks["firstPresetCannotMovePastBoundary"] = previewSaved.presets.map(\.id) == originalOrder
            _ = accessibilityElement(in: previewSettings, identifier: "settings.preset.\(movedID).moveDown")?.accessibilityPerformPress()
            try? await Task.sleep(for: .milliseconds(120))
            checks["nativeMoveDownImmediatelySavesOrder"] = previewSaved.presets.map(\.id) == [originalOrder[1], originalOrder[0]] + Array(originalOrder.dropFirst(2))
            checks["reorderedPresetRetainsNativeFieldIdentity"] = accessibilityElement(in: previewSettings, identifier: "settings.preset.\(movedID).prompt") != nil
            _ = accessibilityElement(in: previewSettings, identifier: "settings.preset.\(movedID).moveUp")?.accessibilityPerformPress()
            try? await Task.sleep(for: .milliseconds(120))
            checks["nativeMoveUpRestoresOrder"] = previewSaved.presets.map(\.id) == originalOrder
            checks["reorderingButtonsHaveComfortableHeight"] = ["moveUp", "moveDown"].allSatisfy {
                (accessibilityElement(in: previewSettings, identifier: "settings.preset.\(movedID).\($0)")?.accessibilityFrame().height ?? 0) >= 34
            }
            snapshot(previewSettings, name: "settings-presets-preview.png", includeFrame: true)
            previewSettings.appearance = NSAppearance(named: .darkAqua)
            try? await Task.sleep(for: .milliseconds(150))
            snapshot(previewSettings, name: "settings-presets-dark-preview.png", includeFrame: true)
            checks["darkPromptHasDarkSurface"] = darkFieldHasSurface(previewSettings, identifier: "settings.preset.\(previewEditor.draft.presets[0].id).prompt")
            let firstPresetID = previewEditor.draft.presets[0].id
            accessibilityElement(in: previewSettings, identifier: "settings.preset.\(firstPresetID).prompt")?.setAccessibilityFocused(true)
            try? await Task.sleep(for: .milliseconds(100))
            if let textView = previewSettings.firstResponder as? NSTextView,
               textView.string == previewEditor.draft.presets[0].prompt {
                textView.insertText("请简洁地处理选中文本。", replacementRange: NSRange(location: 0, length: textView.string.utf16.count))
                checks["promptAutosavesNativeTextInput"] = await waitFor { previewSaved.presets[0].prompt == "请简洁地处理选中文本。" }
            } else { checks["promptAutosavesNativeTextInput"] = false }
            if let recorder = recorderButton(in: previewSettings.contentView) {
                recorder.performClick(nil)
                checks["recorderFocusAndPauseCallback"] = previewSettings.firstResponder === recorder && previewRecording
                // Keep the CJK recording prompt onscreen and force real native paint;
                // prior smoke cancelled before the draw path in the crash reports ran.
                try? await Task.sleep(for: .milliseconds(100))
                previewSettings.contentView?.layoutSubtreeIfNeeded()
                snapshot(previewSettings, name: "recorder-active-preview.png", includeFrame: true)
                checks["recordingPromptPaintsAsNativeLabel"] = recorder.subviews.contains {
                    ($0 as? NSTextField)?.stringValue == "按下快捷键…"
                }
                for iteration in 0..<24 {
                    previewSettings.appearance = NSAppearance(named: iteration % 2 == 0 ? .aqua : .darkAqua)
                    try? await Task.sleep(for: .milliseconds(20))
                    recorder.needsDisplay = true
                    _ = renderedBitmap(recorder)
                }
                checks["recorderSurvivesRecordingThemeRepaints"] = previewRecording && recorder.title == "按下快捷键…" && previewSettings.isVisible
                previewSettings.appearance = NSAppearance(named: .darkAqua)
                if let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: previewSettings.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53) {
                    recorder.keyDown(with: escape)
                    checks["recorderEscapeRestoresCallback"] = !previewRecording && recorder.title == previewEditor.draft.presets[0].shortcut.label
                }
                recorder.performClick(nil)
                if let shortcut = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.control, .option], timestamp: 0,
                    windowNumber: previewSettings.windowNumber, context: nil, characters: "6", charactersIgnoringModifiers: "6", isARepeat: false, keyCode: 22) {
                    recorder.keyDown(with: shortcut)
                    checks["recorderSavesNativeKeyEvent"] = !previewRecording && previewSaved.presets[0].shortcut.keyCode == 22 &&
                        previewSaved.presets[0].shortcut.modifiers == UInt32(controlKey | optionKey)
                }
            } else { checks["recorderFocusAndPauseCallback"] = false }
            let presetCount = previewEditor.draft.presets.count
            _ = accessibilityElement(in: previewSettings, identifier: "settings.preset.add")?.accessibilityPerformPress()
            try? await Task.sleep(for: .milliseconds(200))
            if previewEditor.draft.presets.count == presetCount + 1, let added = previewEditor.draft.presets.last {
                let frame = accessibilityElement(in: previewSettings, identifier: "settings.preset.\(added.id).name")?.accessibilityFrame() ?? .zero
                checks["addingPresetScrollsAndFocusesName"] = frame.height > 0 && previewSettings.frame.contains(frame) &&
                    (previewSettings.firstResponder as? NSTextView)?.string == added.name
                if let textView = previewSettings.firstResponder as? NSTextView, textView.string == added.name {
                    textView.insertText("本地测试预设", replacementRange: NSRange(location: 0, length: textView.string.utf16.count))
                    checks["presetNameAutosavesNativeTextInput"] = await waitFor { previewSaved.presets.last?.name == "本地测试预设" }
                } else { checks["presetNameAutosavesNativeTextInput"] = false }
                _ = accessibilityElement(in: previewSettings, identifier: "settings.preset.\(added.id).delete")?.accessibilityPerformPress()
                try? await Task.sleep(for: .milliseconds(100))
                checks["deletePresetUpdatesSavedConfiguration"] = previewEditor.draft.presets.count == presetCount && previewSaved.presets.count == presetCount
            } else { checks["addingPresetScrollsAndFocusesName"] = false }
            let editedPreset = previewEditor.draft.presets[0]
            let removedPreset = previewEditor.draft.presets[2]
            _ = accessibilityElement(in: previewSettings, identifier: "settings.preset.\(removedPreset.id).delete")?.accessibilityPerformPress()
            try? await Task.sleep(for: .milliseconds(100))
            checks["builtinCanBeDeleted"] = previewEditor.draft.presets.count == presetCount - 1 && previewSaved.presets.count == presetCount - 1
            _ = accessibilityElement(in: previewSettings, identifier: "settings.preset.restore")?.accessibilityPerformPress()
            try? await Task.sleep(for: .milliseconds(250))
            checks["restoreButtonRecoversOnlyMissingBuiltin"] = previewEditor.draft.presets.count == presetCount &&
                previewSaved.presets.contains(where: { $0.builtIn == removedPreset.builtIn }) &&
                previewSaved.presets.first == editedPreset
            if let restored = previewEditor.draft.presets.last {
                let frame = accessibilityElement(in: previewSettings, identifier: "settings.preset.\(restored.id).name")?.accessibilityFrame() ?? .zero
                checks["restoredPresetIsVisibleAndFocused"] = frame.height > 0 && previewSettings.frame.contains(frame) &&
                    (previewSettings.firstResponder as? NSTextView)?.string == restored.name
            }
            _ = accessibilityElement(in: previewSettings, identifier: "settings.preset.restore")?.accessibilityPerformPress()
            checks["repeatedRestoreDoesNotDuplicatePresets"] = previewEditor.draft.presets.count == presetCount
            _ = accessibilityElement(in: previewSettings, identifier: "settings.section.reading")?.accessibilityPerformPress()
            try? await Task.sleep(for: .milliseconds(150))
            checks["readingNavigationResponds"] = accessibilityElement(in: previewSettings, identifier: "settings.copyFallback") != nil
            snapshot(previewSettings, name: "settings-reading-dark-preview.png", includeFrame: true)
            previewSettings.appearance = NSAppearance(named: .aqua)
            try? await Task.sleep(for: .milliseconds(150))
            snapshot(previewSettings, name: "settings-reading-preview.png", includeFrame: true)
            _ = accessibilityElement(in: previewSettings, identifier: "settings.copyFallback")?.accessibilityPerformPress()
            checks["fallbackToggleImmediatelySaves"] = !previewEditor.draft.copyFallback && !previewSaved.copyFallback
            _ = accessibilityElement(in: previewSettings, identifier: "settings.section.connection")?.accessibilityPerformPress()
            try? await Task.sleep(for: .milliseconds(100))
            checks["connectionNavigationResponds"] = accessibilityElement(in: previewSettings, identifier: "settings.endpoint") != nil
            checks["navigationPreservesEditedEndpoint"] = previewEditor.draft.apiBaseURL == "https://edited.example/v1" &&
                accessibilityElement(in: previewSettings, identifier: "settings.endpoint") != nil
            // Removing the status footer must retain visible validation errors and recovery.
            accessibilityElement(in: previewSettings, identifier: "settings.endpoint")?.setAccessibilityFocused(true)
            try? await Task.sleep(for: .milliseconds(100))
            if let fieldEditor = previewSettings.firstResponder as? NSTextView {
                fieldEditor.insertText("invalid-address", replacementRange: NSRange(location: 0, length: fieldEditor.string.utf16.count))
                previewEditor.flush()
                try? await Task.sleep(for: .milliseconds(100))
                let errorFrame = accessibilityElement(in: previewSettings, identifier: "settings.error")?.accessibilityFrame() ?? .zero
                checks["validationErrorVisibleWithoutFooter"] = previewEditor.error != nil && errorFrame.height > 0 && previewSettings.frame.contains(errorFrame)
                checks["invalidAddressPreservesSavedConfiguration"] = previewSaved.apiBaseURL == "https://edited.example/v1"
                snapshot(previewSettings, name: "settings-error-preview.png", includeFrame: true)
                fieldEditor.insertText("https://edited.example/v1", replacementRange: NSRange(location: 0, length: fieldEditor.string.utf16.count))
                previewEditor.flush()
                try? await Task.sleep(for: .milliseconds(100))
                checks["validAddressClearsVisibleError"] = previewEditor.error == nil && accessibilityElement(in: previewSettings, identifier: "settings.error") == nil
            } else { checks["validationErrorVisibleWithoutFooter"] = false }
            second.window?.appearance = NSAppearance(named: .darkAqua)
            try? await Task.sleep(for: .milliseconds(200))
            snapshot(second.window, name: "sticky-dark-preview.png")
            if let textView = stickyTextView(in: second.hostingView) {
                checks["darkMarkdownHasReadableForeground"] = (try? await textView.evaluate("(() => { const color = getComputedStyle(document.querySelector('#markdown-root')).color; return Number(color.match(/\\d+/)?.[0]) > 200; })()")) as? Bool == true
                second.model.output = "尚未结束的 **重点"
                try? await Task.sleep(for: .milliseconds(150))
                let selection = (textView.renderedText as NSString).range(of: "重点")
                if selection.location != NSNotFound {
                    textView.setSelectedRange(selection)
                    try? await Task.sleep(for: .milliseconds(80))
                    print("markdown selection before", textView.renderedText, selection, textView.selectedRange())
                    second.model.output += "**\n\n下一段"
                    try? await Task.sleep(for: .milliseconds(150))
                    let newSelection = textView.selectedRange()
                    print("markdown selection after", textView.renderedText, newSelection)
                    checks["closingMarkdownPreservesSelectedText"] = newSelection.length == selection.length &&
                        textView.selectedText == "重点"
                } else { checks["closingMarkdownPreservesSelectedText"] = false }
            }
            first.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            try? await Task.sleep(for: .milliseconds(100))
            checks["panelGetsKeyboardFocus"] = NSApp.keyWindow === first.window
            checks["inactiveSettingsTitlebarHasSurface"] = titlebarHasSurface(previewSettings)
            snapshot(first.window, name: "sticky-active-window.png", includeFrame: true)
            checks["activePanelCornersStayTransparent"] = cornersAreTransparent(first.window)
            checks["activeWindowClipsRectangularHighlight"] = clipsRectangularHighlight(first.window)
            first.model.output = "短结果"
            try? await Task.sleep(for: .milliseconds(150))
            checks["shortResultStartsAtMinimumHeight"] = first.window?.frame.height == StickyWindow.minimumHeight
            if let window = first.window, let visible = window.screen?.visibleFrame {
                window.setFrameOrigin(NSPoint(x: visible.midX - StickyWindow.width / 2, y: visible.maxY - 40 - window.frame.height))
            }
            let top = first.window!.frame.maxY
            first.model.output = (1...5).map { "段落 \($0)：用于检查流式内容增长。" }.joined(separator: "\n\n")
            try? await Task.sleep(for: .milliseconds(250))
            let intermediateHeight = first.window!.frame.height
            checks["streamingGrowsWindow"] = intermediateHeight > StickyWindow.minimumHeight && intermediateHeight < StickyWindow.maximumHeight
            if let scroll = scrollView(in: first.hostingView), let document = scroll.documentView {
                checks["mediumResultFitsWithoutClipping"] = document.bounds.height <= scroll.contentView.bounds.height + 1
            } else { checks["mediumResultFitsWithoutClipping"] = false }
            first.model.output += "\n\n" + (6...9).map { "段落 \($0)：继续增加内容。" }.joined(separator: "\n\n")
            try? await Task.sleep(for: .milliseconds(250))
            checks["subsequentChunksKeepGrowing"] = first.window!.frame.height > intermediateHeight
            checks["growthKeepsWidthAndTopEdge"] = first.window!.frame.width == StickyWindow.width && abs(first.window!.frame.maxY - top) < 1
            first.model.output = (1...80).map { "段落 \($0)：用于检查长文本滚动。" }.joined(separator: "\n\n")
            try? await Task.sleep(for: .milliseconds(250))
            let visibleHeight = first.window?.screen?.visibleFrame.height ?? 560
            let expectedMax = min(StickyWindow.maximumHeight, max(StickyWindow.minimumHeight, visibleHeight - 40))
            checks["longResultStopsAtMaximumHeight"] = abs(first.window!.frame.height - expectedMax) < 1
            checks["grownActivePanelCornersStayTransparent"] = cornersAreTransparent(first.window)
            checks["grownWindowClipsRectangularHighlight"] = clipsRectangularHighlight(first.window)
            if #available(macOS 15.0, *), let scroll = scrollView(in: first.hostingView), let document = scroll.documentView {
                checks["longOutputFollowsBottom"] = scroll.documentVisibleRect.maxY >= document.bounds.height - 25
                let bottomOffset = scroll.documentVisibleRect.minY
                scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, bottomOffset - 600)))
                scroll.reflectScrolledClipView(scroll.contentView)
                try? await Task.sleep(for: .milliseconds(150))
                checks["readingOlderTextPausesFollowing"] = scroll.documentVisibleRect.minY < bottomOffset - 100 && !first.model.autoScroll
                let offset = scroll.documentVisibleRect.minY
                first.model.output += "\n\n新增流式段落"
                try? await Task.sleep(for: .milliseconds(150))
                checks["newOutputPreservesReadingPosition"] = abs(scroll.documentVisibleRect.minY - offset) < 2
                scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, document.bounds.height - scroll.contentView.bounds.height)))
                scroll.reflectScrolledClipView(scroll.contentView)
                try? await Task.sleep(for: .milliseconds(150))
                checks["returnToBottomResumesFollowing"] = first.model.autoScroll
            } else if #available(macOS 15.0, *) { checks["nativeScrollViewPresent"] = false }
            if let textView = stickyTextView(in: first.hostingView), let scroll = scrollView(in: first.hostingView) {
                let before = textView.renderedText as NSString
                let firstParagraph = before.range(of: "段落 1：用于检查长文本滚动。")
                let secondParagraph = before.range(of: "段落 2")
                if firstParagraph.location != NSNotFound && secondParagraph.location != NSNotFound {
                    let prefix = NSRange(location: firstParagraph.location,
                                         length: NSMaxRange(secondParagraph) - firstParagraph.location)
                    textView.setSelectedRange(prefix)
                    try? await Task.sleep(for: .milliseconds(80))
                    let selectedBefore = try? await textView.selectionSnapshot()
                    checks["selectingTextPausesFollowing"] = !first.model.autoScroll
                    let offset = scroll.documentVisibleRect.minY
                    first.model.output += "\n\n保留正在选中的段落。"
                    try? await Task.sleep(for: .milliseconds(150))
                    checks["streamingPreservesCrossParagraphSelection"] = textView.selectedRange() == prefix &&
                        textView.selectedText == selectedBefore && selectedBefore?.contains("段落 1") == true &&
                        selectedBefore?.contains("段落 2") == true
                    checks["streamingSelectionPreservesReadingPosition"] = abs(scroll.documentVisibleRect.minY - offset) < 2
                    textView.setSelectedRange(NSRange(location: 0, length: 0))
                    try? await Task.sleep(for: .milliseconds(80))
                } else { checks["streamingPreservesCrossParagraphSelection"] = false }
                first.window?.makeFirstResponder(textView)
            }
            first.model.output = "## 标题\n\n便签中的 **新选区 🌍**，不是原始输入。"
            try? await Task.sleep(for: .milliseconds(150))
            first.window?.makeKeyAndOrderFront(nil)
            if let textView = stickyTextView(in: first.hostingView) {
                first.window?.makeFirstResponder(textView)
                let selected = "新选区 🌍"
                textView.setSelectedRange((textView.renderedText as NSString).range(of: selected))
                try? await Task.sleep(for: .milliseconds(80))
                var captured: StickyWindow?
                var triggerFailure: String?
                var requestSources: [String] = []
                var probe = Preset.defaults[2]
                probe.shortcut = .init(keyCode: 79, modifiers: UInt32(cmdKey | optionKey | controlKey | shiftKey), label: "Test F18")
                hotKeys.onTrigger = { preset in
                    self.beginTrigger(preset, readKey: { "local-fixture-key" }, start: { sticky, _, _ in
                        captured = sticky
                        requestSources.append(sticky.model.source)
                        sticky.model.output = "链式处理结果"
                    }, failure: { triggerFailure = $0 })
                }
                do {
                    try hotKeys.register([probe])
                    dispatchHotKeyEvent(index: 1)
                    let started = await waitFor { captured != nil || triggerFailure != nil }
                    checks["stickySelectionStartsNewNoteViaCarbon"] = started && captured?.model.source == selected &&
                        captured?.model.source != first.model.source && captured?.model.preset.id == probe.id && stickies.count == 3
                    checks["stickySelectionUsesRenderedUnicodeText"] = requestSources == [selected] && !selected.contains("**")
                    if let chained = captured {
                        chained.model.retry?()
                        checks["chainedRetryKeepsSelectedInput"] = requestSources == [selected, selected]
                        snapshot(chained.window, name: "chained-sticky-preview.png")
                        chained.window?.close()
                    }
                    captured = nil; triggerFailure = nil
                    first.window?.makeKeyAndOrderFront(nil)
                    first.window?.makeFirstResponder(textView)
                    textView.setSelectedRange(NSRange(location: 0, length: 0))
                    try? await Task.sleep(for: .milliseconds(80))
                    dispatchHotKeyEvent(index: 1)
                    _ = await waitFor { triggerFailure != nil || self.stickies.values.contains { $0.model.awaitingInput } }
                    let draft = stickies.values.first { $0.model.awaitingInput }
                    checks["emptyStickySelectionOpensDraftWithoutReusingInput"] = triggerFailure == nil && captured == nil &&
                        draft?.model.source.isEmpty == true && draft?.model.draft.isEmpty == true && stickies.count == 3
                    draft?.window?.close()
                    first.window?.makeKeyAndOrderFront(nil)
                    first.window?.makeFirstResponder(textView)
                    textView.setSelectedRange((textView.renderedText as NSString).range(of: " "))
                    try? await Task.sleep(for: .milliseconds(80))
                    triggerFailure = nil
                    dispatchHotKeyEvent(index: 1)
                    _ = await waitFor { triggerFailure != nil || self.stickies.values.contains { $0.model.awaitingInput } }
                    let whitespaceDraft = stickies.values.first { $0.model.awaitingInput }
                    checks["whitespaceStickySelectionOpensEmptyDraft"] = triggerFailure == nil && captured == nil &&
                        whitespaceDraft?.model.source.isEmpty == true && requestSources == [selected, selected]
                    whitespaceDraft?.window?.close()
                    previewSettings.makeKeyAndOrderFront(nil)
                    checks["settingsDoNotRouteAsStickySelection"] = (try? localStickySelection()) == nil
                } catch { checks["stickySelectionStartsNewNoteViaCarbon"] = false }
                try? hotKeys.register([]); hotKeys.onTrigger = nil
                first.window?.makeKeyAndOrderFront(nil)
                first.window?.makeFirstResponder(textView)
            } else { checks["stickySelectionStartsNewNoteViaCarbon"] = false }
            first.model.output = "短结果"
            try? await Task.sleep(for: .milliseconds(150))
            checks["shorterResultShrinksWindow"] = first.window?.frame.height == StickyWindow.minimumHeight
            if let window = first.window,
               let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53) {
                NSApp.postEvent(escape, atStart: false)
                checks["escapeClosesFocusedPanel"] = await waitFor { self.stickies.count == 1 }
            } else { checks["escapeClosesFocusedPanel"] = false }
            previewSettings.close()
            closeAll()
            var report: [String: Any] = checks
            report["macOS"] = ProcessInfo.processInfo.operatingSystemVersionString
            report["closeRemovesPanels"] = stickies.isEmpty
            report["passed"] = checks.values.allSatisfy { $0 } && stickies.isEmpty
            if let pathIndex = CommandLine.arguments.firstIndex(of: "--report"), CommandLine.arguments.count > pathIndex + 1,
               let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: CommandLine.arguments[pathIndex + 1]))
            }
            NSApp.terminate(nil)
        }
    }

    private func snapshot(_ window: NSWindow?, name: String, includeFrame: Bool = false) {
        guard let view = includeFrame ? window?.contentView?.superview : window?.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds),
              let index = CommandLine.arguments.firstIndex(of: "--report"), CommandLine.arguments.count > index + 1 else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        if let data = bitmap.representation(using: .png, properties: [:]) {
            let url = URL(fileURLWithPath: CommandLine.arguments[index + 1]).deletingLastPathComponent().appendingPathComponent(name)
            try? data.write(to: url)
        }
    }

    private func titlebarHasSurface(_ window: NSWindow) -> Bool {
        guard let view = window.contentView?.superview, let bitmap = renderedBitmap(view) else { return false }
        let x = Int((view.bounds.width - 55) * CGFloat(bitmap.pixelsWide) / view.bounds.width)
        let y = Int(14 * CGFloat(bitmap.pixelsHigh) / view.bounds.height)
        return (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.15
    }
    private struct NativeAccessibleElement {
        let object: NSObject
        func accessibilityPerformPress() -> Bool {
            let selector = NSSelectorFromString("accessibilityPerformPress")
            guard object.responds(to: selector) else { return false }
            typealias Action = @convention(c) (AnyObject, Selector) -> ObjCBool
            return unsafeBitCast(object.method(for: selector), to: Action.self)(object, selector).boolValue
        }
        func setAccessibilityFocused(_ focused: Bool) {
            let selector = NSSelectorFromString("setAccessibilityFocused:")
            guard object.responds(to: selector) else { return }
            typealias Focus = @convention(c) (AnyObject, Selector, ObjCBool) -> Void
            unsafeBitCast(object.method(for: selector), to: Focus.self)(object, selector, ObjCBool(focused))
        }
        func accessibilityFrame() -> NSRect {
            let selector = NSSelectorFromString("accessibilityFrame")
            guard object.responds(to: selector) else { return .zero }
            typealias Frame = @convention(c) (AnyObject, Selector) -> NSRect
            return unsafeBitCast(object.method(for: selector), to: Frame.self)(object, selector)
        }
    }
    private func accessibilityElement(in root: Any, identifier: String) -> NativeAccessibleElement? {
        // SwiftUI nodes implement the public selectors without declaring NSAccessibilityProtocol.
        guard let object = root as? NSObject else { return nil }
        let idSelector = NSSelectorFromString("accessibilityIdentifier")
        if object.responds(to: idSelector), object.perform(idSelector)?.takeUnretainedValue() as? String == identifier {
            return NativeAccessibleElement(object: object)
        }
        let childrenSelector = NSSelectorFromString("accessibilityChildren")
        guard object.responds(to: childrenSelector),
              let children = object.perform(childrenSelector)?.takeUnretainedValue() as? [Any] else { return nil }
        for child in children {
            if let found = accessibilityElement(in: child, identifier: identifier) { return found }
        }
        return nil
    }
    private func recorderButton(in root: NSView?) -> RecorderButton? {
        guard let root else { return nil }
        if let recorder = root as? RecorderButton { return recorder }
        return root.subviews.lazy.compactMap { self.recorderButton(in: $0) }.first
    }
    private func darkFieldHasSurface(_ window: NSWindow, identifier: String) -> Bool {
        guard let element = accessibilityElement(in: window, identifier: identifier),
              let view = window.contentView?.superview, let bitmap = renderedBitmap(view) else { return false }
        let frame = element.accessibilityFrame()
        let scale = CGFloat(bitmap.pixelsWide) / view.bounds.width
        // Read empty padding at the trailing edge, away from text and focus outlines.
        let x = Int((frame.maxX - window.frame.minX - 10) * scale)
        let y = Int((window.frame.maxY - frame.midY) * scale)
        guard x >= 0, y >= 0, x < bitmap.pixelsWide, y < bitmap.pixelsHigh,
              let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
        return color.alphaComponent > 0.9 && max(color.redComponent, color.greenComponent, color.blueComponent) < 0.45
    }
    private func cornersAreTransparent(_ window: NSWindow?) -> Bool {
        guard let view = window?.contentView?.superview, let bitmap = renderedBitmap(view) else { return false }
        let scale = CGFloat(bitmap.pixelsWide) / view.bounds.width
        let offsets: [(CGFloat, CGFloat)] = [(0.5, 0.5), (5, 0.5), (0.5, 5), (8, 0.5), (0.5, 8)]
        for (dx, dy) in offsets {
            let x = Int(dx * scale), y = Int(dy * scale)
            for point in [(x, y), (bitmap.pixelsWide - 1 - x, y), (x, bitmap.pixelsHigh - 1 - y),
                          (bitmap.pixelsWide - 1 - x, bitmap.pixelsHigh - 1 - y)] {
                if (bitmap.colorAt(x: point.0, y: point.1)?.alphaComponent ?? 1) > 0.1 { return false }
            }
        }
        return true
    }
    private func renderedBitmap(_ view: NSView) -> NSBitmapImageRep? {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap
    }
    private func clipsRectangularHighlight(_ window: NSWindow?) -> Bool {
        guard let frame = window?.contentView?.superview else { return false }
        frame.wantsLayer = true
        frame.layoutSubtreeIfNeeded()
        guard let layer = frame.layer else { return false }
        // Model AppKit's rectangular active-window outline at the outer frame boundary.
        // Rendering the actual frame layer tests clipping even when cacheDisplay omits WindowServer chrome.
        let highlight = CALayer()
        highlight.frame = layer.bounds
        highlight.borderWidth = 2
        highlight.borderColor = NSColor.systemBlue.cgColor
        layer.addSublayer(highlight)
        defer { highlight.removeFromSuperlayer() }
        let width = Int(ceil(layer.bounds.width)), height = Int(ceil(layer.bounds.height))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        layer.render(in: context)
        guard let image = context.makeImage() else { return false }
        let bitmap = NSBitmapImageRep(cgImage: image)
        return [(1, 1), (width - 2, 1), (1, height - 2), (width - 2, height - 2)].allSatisfy {
            (bitmap.colorAt(x: $0.0, y: $0.1)?.alphaComponent ?? 1) < 0.1
        }
    }

    private func stickyTextView(in view: NSView) -> StickyTextView? {
        if let textView = view as? StickyTextView { return textView }
        return view.subviews.lazy.compactMap { self.stickyTextView(in: $0) }.first
    }
    private func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.lazy.compactMap { self.scrollView(in: $0) }.first
    }

    private func sidebarDividerIsContinuous(_ window: NSWindow) -> Bool {
        guard let view = window.contentView?.superview, let bitmap = renderedBitmap(view) else { return false }
        let scale = CGFloat(bitmap.pixelsWide) / view.bounds.width
        func sample(_ x: CGFloat, _ y: CGFloat) -> NSColor? {
            bitmap.colorAt(x: Int(x * scale), y: Int(y * scale))?.usingColorSpace(.sRGB)
        }
        guard let line = sample(150.5, 40), let top = sample(150.5, 10),
              let left = sample(148, 10), let right = sample(153, 10) else { return false }
        let difference = abs(top.redComponent - line.redComponent) + abs(top.greenComponent - line.greenComponent) + abs(top.blueComponent - line.blueComponent)
        let contrast = min(abs(top.redComponent - left.redComponent), abs(top.redComponent - right.redComponent))
        print("sidebar divider samples", top.redComponent, line.redComponent, left.redComponent, right.redComponent)
        return top.alphaComponent > 0.98 && difference < 0.05 && contrast > 0.02
    }
    private func dispatchHotKeyEvent(index: UInt32) {
        var event: EventRef?
        if CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed), GetCurrentEventTime(), 0, &event) == noErr, let event {
            var id = EventHotKeyID(signature: 0x42424E47, id: index)
            SetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), MemoryLayout<EventHotKeyID>.size, &id)
            SendEventToEventTarget(event, GetApplicationEventTarget())
            ReleaseEvent(event)
        }
    }

    private func checkPresetKeyboardShortcuts() async -> [String: Bool] {
        var checks = checkHotKeyRegistration()
        let defaults = Preset.defaults(for: .english)
        checks["defaultPresetShortcutMappings"] = defaults.map(\.shortcut.keyCode) == [18, 19, 20, 21, 23] &&
            defaults.map(\.shortcut.modifiers) == Array(repeating: UInt32(controlKey | optionKey), count: 5) &&
            defaults.map(\.shortcut.label) == ["⌃⌥1", "⌃⌥2", "⌃⌥3", "⌃⌥4", "⌃⌥5"] &&
            defaults.map(\.builtIn) == [.translate, .explain, .summarize, .visualize, .assistant]
        // Keep everyday registrations untouched; only the fixture's modifiers change.
        let probes = defaults.map { preset in
            var probe = preset
            probe.shortcut.modifiers |= UInt32(cmdKey | shiftKey)
            return probe
        }
        var received: [UUID] = []
        hotKeys.onTrigger = { received.append($0.id) }
        defer { try? hotKeys.register([]); hotKeys.onTrigger = nil }
        do {
            try hotKeys.register(probes)
            checks["allPresetShortcutsRegister"] = true
            guard CGPreflightPostEventAccess() else { return checks }
            for order in [probes, Array(probes.reversed())] {
                try hotKeys.register(order)
                for preset in probes {
                    received.removeAll()
                    for down in [true, false] {
                        let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(preset.shortcut.keyCode), keyDown: down)
                        event?.flags = down ? [.maskControl, .maskAlternate, .maskShift, .maskCommand] : []
                        event?.post(tap: .cghidEventTap)
                    }
                    for _ in 0..<100 {
                        if !received.isEmpty { break }
                        try? await Task.sleep(for: .milliseconds(20))
                    }
                    checks["physicalPreset.\(preset.builtIn!.rawValue).\(order == probes ? "original" : "reordered")"] = received == [preset.id]
                }
            }
        } catch { checks["allPresetShortcutsRegister"] = false }
        return checks
    }

    private func checkHotKeyRegistration() -> [String: Bool] {
        var triggered: Preset?
        let modifiers = UInt32(cmdKey | optionKey | controlKey | shiftKey)
        let probe = Preset(name: "Probe", prompt: "Test", shortcut: .init(keyCode: 79, modifiers: modifiers, label: "Test F18"))
        let occupied = Preset(name: "Occupied", prompt: "Test", shortcut: .init(keyCode: 80, modifiers: modifiers, label: "Test F19"))
        var competitor: EventHotKeyRef?
        var result: [String: Bool] = [:]
        hotKeys.onTrigger = { triggered = $0 }
        do {
            try hotKeys.register([probe])
            let status = RegisterEventHotKey(occupied.shortcut.keyCode, modifiers,
                                            EventHotKeyID(signature: 0x54455354, id: 99), GetApplicationEventTarget(), 0, &competitor)
            result["nativeHotkeyRegistered"] = status == noErr
            do { try hotKeys.register([occupied]); result["hotkeyConflictRejected"] = false }
            catch { result["hotkeyConflictRejected"] = true }
            dispatchHotKeyEvent(index: 1)
            result["hotkeyRollbackAndEventDispatch"] = triggered?.id == probe.id
            var edited = probe
            edited.name = "Edited"; edited.prompt = "New instructions"
            try hotKeys.register([edited])
            triggered = nil; dispatchHotKeyEvent(index: 1)
            result["autosaveUpdatesHotkeyInstructions"] = triggered == edited
            hotKeys.pause()
            edited.prompt = "Edited while recording"
            try hotKeys.register([edited])
            triggered = nil; dispatchHotKeyEvent(index: 1)
            var pausedProbe: EventHotKeyRef?
            let pausedStatus = RegisterEventHotKey(probe.shortcut.keyCode, modifiers,
                                                  EventHotKeyID(signature: 0x54455354, id: 100), GetApplicationEventTarget(), 0, &pausedProbe)
            result["autosaveDoesNotResumeRecordingHotkeys"] = triggered == nil && pausedStatus == noErr
            if let pausedProbe { UnregisterEventHotKey(pausedProbe) }
            try hotKeys.resume()
            dispatchHotKeyEvent(index: 1)
            result["recordingResumesWithLatestInstructions"] = triggered == edited
            if let competitor { UnregisterEventHotKey(competitor) }
            competitor = nil
            try hotKeys.register([edited, occupied])
            try hotKeys.register([occupied, edited])
            triggered = nil; dispatchHotKeyEvent(index: 1)
            result["reorderedHotkeysDispatchCorrectPreset"] = triggered?.id == occupied.id
        } catch { result["nativeHotkeyRegistered"] = false }
        if let competitor { UnregisterEventHotKey(competitor) }
        try? hotKeys.register([])
        hotKeys.onTrigger = nil
        return result
    }

    private func runIntegrationTest() {
        Task { @MainActor in
            var checks: [String: Bool] = [:]
            var configuration = Configuration()
            configuration.model = "test-model"
            if let index = CommandLine.arguments.firstIndex(of: "--test-base-url"), CommandLine.arguments.count > index + 1,
               let url = URL(string: CommandLine.arguments[index + 1]), url.host == "127.0.0.1", url.scheme == "http" {
                configuration.apiBaseURL = url.absoluteString
            } else { NSApp.terminate(nil); return }
            for mode in APIMode.allCases {
                configuration.apiMode = mode
                var modeChecks: [String: Bool] = [:]
                let first = createSticky(preset: .defaults[0], source: "success")
                let failure = createSticky(preset: .defaults[1], source: "unauthorized")
                let cancelled = createSticky(preset: .defaults[2], source: "cancel")
                let truncated = createSticky(preset: .defaults[2], source: "truncated")
                for sticky in [first, failure, cancelled, truncated] {
                    sticky.showWindow(nil)
                    sticky.model.start(configuration: configuration, key: "local-test-key")
                }
                let receivedFirst = await waitFor { !first.model.output.isEmpty }
                modeChecks["rendersBeforeCompletion"] = receivedFirst && first.model.running
                let receivedCancel = await waitFor { !cancelled.model.output.isEmpty }
                modeChecks["cancelReceivedPartial"] = receivedCancel
                cancelled.model.stop()
                let partial = cancelled.model.output
                let finished = await waitFor { !first.model.running && !failure.model.running && !truncated.model.running }
                modeChecks["streamsComplete"] = finished && first.model.state == "已完成" && first.model.output == "你好 🌍\n流式完成"
                modeChecks["apiFailureVisible"] = failure.model.error?.contains("API Key") == true
                modeChecks["truncatedStreamPreservesOutput"] = truncated.model.error != nil && truncated.model.output == "部分结果"
                try? await Task.sleep(for: .milliseconds(200))
                modeChecks["cancelStopsFurtherUpdates"] = cancelled.model.output == partial && cancelled.model.state == "已停止"
                first.model.start(configuration: configuration, key: "local-test-key")
                let retried = await waitFor { !first.model.running }
                modeChecks["retryStartsFreshStream"] = retried && first.model.output == "你好 🌍\n流式完成" && first.model.error == nil
                let closing = createSticky(preset: .defaults[0], source: "cancel")
                closing.model.start(configuration: configuration, key: "local-test-key")
                _ = await waitFor { !closing.model.output.isEmpty }
                closing.window?.close()
                modeChecks["closeCancelsStream"] = !closing.model.running && closing.model.state == "已停止"
                closeAll()
                modeChecks["allPanelsReleased"] = stickies.isEmpty
                for (name, passed) in modeChecks { checks[mode.rawValue + "." + name] = passed }
            }
            var report: [String: Any] = checks
            report["passed"] = checks.values.allSatisfy { $0 }
            report["scope"] = "Native NSPanel + shared model transport + loopback SSE server for Responses and Chat Completions; no live API, system selection, or TCC authorization"
            if let index = CommandLine.arguments.firstIndex(of: "--report"), CommandLine.arguments.count > index + 1,
               let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
            }
            NSApp.terminate(nil)
        }
    }
    private func waitFor(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<500 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }
}
