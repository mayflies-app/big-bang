import AppKit
import BigBangCore

@MainActor enum StickyPresetLayoutVerification {
    private static var previewNote: StickyWindow?
    private static var movementObserver: NSObjectProtocol?
    private static var frameHistory: [[String: Any]] = []

    static func run(reportURL: URL, registerPreview: ((StickyWindow) -> Void)? = nil) async {
        let short = Preset.defaults[0]
        let medium = Preset(name: "Explain concepts", prompt: "local-layout-medium",
                            shortcut: Shortcut(keyCode: 19, modifiers: 6144, label: "⌃⌥2"))
        let huge = Preset(name: String(repeating: "超长预设 Very long name 🌍 ", count: 20), prompt: "local-layout-huge",
                          shortcut: Shortcut(keyCode: 20, modifiers: 6144, label: "⌃⌥3"))
        var configuration = Configuration(language: .simplifiedChinese)
        configuration.presets = [short, medium, huge]
        let note = StickyWindow(preset: short, source: "Local layout fixture", offset: 0)
        note.configureProcessing(configuration: { configuration }, readKey: { "" }, start: { sticky, _, _ in
            sticky.model.output = "仅用于标题布局验证的本地模拟正文。\nLocal layout preview."
            sticky.model.state = "演示已完成"
            sticky.model.running = false
        })
        // The production callback checks the default endpoint's key requirement before invoking the local start.
        configuration.apiBaseURL = "http://127.0.0.1:1/local-layout"
        note.updateConfiguration(configuration)
        note.model.retry?()
        note.showWindow(nil)
        note.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        await settle(note)
        var checks: [String: Bool] = [:]
        var observations: [String: Any] = [:]
        guard let button = popup(in: note.hostingView), let window = note.window else {
            write(["passed": false, "nativePopupAvailable": false], to: reportURL)
            NSApp.terminate(nil)
            return
        }
        checks["nativePopupAvailable"] = true
        let originalWindow = window
        let first = observe(note, button: button)
        observations["shortWithUnselectedHuge"] = first.details
        checks["unselectedHugeDoesNotExpandShortSelection"] = first.compact
        checks["shortSelectedTitleIsComplete"] = first.completeTitle
        checks["shortLeavesDraggableHeaderBlank"] = first.blankIsNotControl
        checks["shortHeaderActionsAndBodyFit"] = first.actionsFit && first.bodyFits
        checks["shortLightScreenshot"] = snapshot(window, reportURL: reportURL, name: "preset-layout-short-light.png")

        checks["mediumNativeSelection"] = select(medium.id, button: button)
        await settle(note)
        let middle = observe(note, button: button)
        observations["medium"] = middle.details
        checks["mediumSelectionGrowsNaturally"] = middle.compact && middle.width > first.width + 8 && middle.completeTitle
        checks["mediumHeaderActionsAndBodyFit"] = middle.actionsFit && middle.bodyFits

        checks["hugeNativeSelection"] = select(huge.id, button: button)
        await settle(note)
        let long = observe(note, button: button)
        observations["huge"] = long.details
        checks["hugeUsesAvailableWidthAndTailTruncation"] = long.width > middle.width && long.truncates && long.fillsAvailableSpace
        checks["hugeHeaderActionsAndBodyFit"] = long.actionsFit && long.bodyFits
        checks["hugeLightScreenshot"] = snapshot(window, reportURL: reportURL, name: "preset-layout-huge-light.png")
        window.appearance = NSAppearance(named: .darkAqua)
        await settle(note)
        checks["hugeDarkScreenshot"] = snapshot(window, reportURL: reportURL, name: "preset-layout-huge-dark.png")

        note.model.running = true
        await settle(note)
        let longRunning = observe(note, button: button)
        observations["hugeRunning"] = longRunning.details
        checks["hugeWithSpinnerPreservesActionsAndBody"] = longRunning.truncates && longRunning.actionsFit && longRunning.bodyFits && longRunning.width < long.width
        checks["hugeRunningDarkScreenshot"] = snapshot(window, reportURL: reportURL, name: "preset-layout-huge-running-dark.png")
        window.appearance = NSAppearance(named: .aqua)
        await settle(note)
        checks["hugeRunningLightScreenshot"] = snapshot(window, reportURL: reportURL, name: "preset-layout-huge-running-light.png")

        checks["returnToShortNativeSelection"] = select(short.id, button: button)
        await settle(note)
        let restored = observe(note, button: button)
        observations["shortRestored"] = restored.details
        checks["returnToShortRestoresCompactWidthAndBlank"] = restored.compact && abs(restored.width - first.width) < 3 && restored.blankIsNotControl
        note.model.running = true
        await settle(note)
        let shortRunning = observe(note, button: button)
        observations["shortRunning"] = shortRunning.details
        checks["shortWithSpinnerRetainsNaturalWidthAndBlank"] = shortRunning.compact && shortRunning.completeTitle && shortRunning.blankIsNotControl && shortRunning.actionsFit
        checks["shortRunningLightScreenshot"] = snapshot(window, reportURL: reportURL, name: "preset-layout-short-running-light.png")
        note.model.running = false
        var renamed = short
        renamed.name = "改名后的翻译预设"
        configuration.presets[0] = renamed
        note.updateConfiguration(configuration)
        await settle(note)
        let renamedObservation = observe(note, button: button)
        observations["renamed"] = renamedObservation.details
        checks["selectedNameEditRefreshesNaturalWidth"] = button.selectedItem?.title == renamed.name && renamedObservation.compact &&
            renamedObservation.completeTitle && renamedObservation.width > first.width + 8

        configuration.language = .english
        configuration.presets[0] = Preset.defaults(for: .english)[0]
        note.updateConfiguration(configuration)
        await settle(note)
        let english = observe(note, button: button)
        observations["english"] = english.details
        checks["languageChangeRefreshesNameAndNaturalWidth"] = button.selectedItem?.title == "🌐 Translate" && english.compact && english.completeTitle &&
            english.width > first.width + 8 && english.blankIsNotControl
        checks["sameWindowAndOriginalInput"] = note.window === originalWindow && note.model.source == "Local layout fixture"
        var report: [String: Any] = checks
        report["passed"] = checks.values.allSatisfy { $0 }
        report["observations"] = observations
        report["scope"] = "Native packaged panel layout, current-title AppKit cell measurement, popup target/action, title drawing rect and header hitTest. Local simulation only; no API, keychain, clipboard, or saved settings. Real drag/menu tracking is verified separately."
        write(report, to: reportURL)
        if CommandLine.arguments.contains("--preset-layout-preview") {
            configuration.language = .simplifiedChinese
            configuration.presets[0] = short
            note.updateConfiguration(configuration)
            note.model.running = false
            previewNote = note
            registerPreview?(note)
            startMovementRecording(window, url: reportURL.deletingLastPathComponent().appendingPathComponent("live-frame.json"))
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            return
        }
        window.close()
        NSApp.terminate(nil)
    }

    private struct Observation {
        var details: [String: Any]
        var width: CGFloat
        var compact: Bool
        var completeTitle: Bool
        var blankIsNotControl: Bool
        var actionsFit: Bool
        var bodyFits: Bool
        var truncates: Bool
        var fillsAvailableSpace: Bool
    }
    private static func observe(_ note: StickyWindow, button: NSPopUpButton) -> Observation {
        guard let window = note.window, let root = window.contentView else {
            return Observation(details: [:], width: 0, compact: false, completeTitle: false, blankIsNotControl: false,
                               actionsFit: false, bodyFits: false, truncates: false, fillsAvailableSpace: false)
        }
        let title = button.selectedItem?.title ?? ""
        let textCell = NSTextFieldCell(textCell: title)
        textCell.font = button.font
        // This independently measures the selected title using AppKit, with a generous native-arrow/inset allowance.
        let naturalText = textCell.cellSize.width
        let titleRect = button.cell?.titleRect(forBounds: button.bounds) ?? .zero
        let popupRect = button.convert(button.bounds, to: root)
        let ids = ["sticky.copy", "sticky.arrow.uturn.backward", note.model.running ? "sticky.stop.fill" : "sticky.arrow.clockwise", "sticky.pin", "sticky.xmark"]
        let actionFrames = ids.compactMap { identifier -> NSRect? in
            guard let element = accessible(in: window, identifier: identifier) else { return nil }
            let screen = accessibilityFrame(element)
            let base = window.convertFromScreen(screen)
            return root.convert(base, from: nil)
        }
        let copy = actionFrames.first ?? .zero
        let proposedBlankX = max(popupRect.minX + naturalText + 48, copy.minX - 36)
        let blankPoint = NSPoint(x: min(copy.minX - 10, proposedBlankX), y: popupRect.midY)
        let hitPoint = root.convert(blankPoint, to: root.superview)
        let hit = root.hitTest(hitPoint)
        var ancestry: [String] = []
        var controlAncestor: String?
        var cursor = hit
        while let view = cursor {
            ancestry.append(String(describing: type(of: view)))
            if view is NSControl, controlAncestor == nil { controlAncestor = String(describing: type(of: view)) }
            cursor = view.superview
        }
        let blankClear = blankPoint.x > popupRect.maxX + 4 && blankPoint.x < copy.minX - 4 && hit != nil && controlAncestor == nil
        let compact = button.bounds.width >= naturalText + 5 && button.bounds.width <= naturalText + 45
        let fits = actionFrames.count == 5 && actionFrames.allSatisfy {
            $0.width >= 30 && $0.height >= 30 && root.bounds.insetBy(dx: -1, dy: -1).contains($0) && popupRect.maxX <= $0.minX + 1
        }
        let body = findTextView(in: note.hostingView)
        let bodyFits = body.map { root.bounds.insetBy(dx: -1, dy: -1).contains($0.convert($0.bounds, to: root)) } ?? false
        let details: [String: Any] = [
            "selectedTitle": title, "windowFrame": rect(window.frame), "popupFrame": rect(popupRect),
            "nativeTitleRect": rect(titleRect), "expectedNaturalTextWidth": naturalText,
            "actualBoundsWidth": button.bounds.width, "nativeIntrinsicWidth": button.intrinsicContentSize.width,
            "boundsMinusNativeIntrinsicWidth": button.bounds.width - button.intrinsicContentSize.width,
            "alignmentRectInsets": ["left": button.alignmentRectInsets.left, "right": button.alignmentRectInsets.right],
            "expectedNaturalWidthRange": [naturalText + 5, naturalText + 45],
            "nativeCellSize": rect(NSRect(origin: .zero, size: button.cell?.cellSize ?? .zero)),
            "blankPoint": ["x": blankPoint.x, "y": blankPoint.y], "blankHitClass": hit.map { String(describing: type(of: $0)) } ?? "nil",
            "blankHitAncestry": ancestry, "blankNSControlAncestor": controlAncestor ?? "none",
            "blankHitMouseDownCanMoveWindow": hit?.mouseDownCanMoveWindow ?? false,
            "rootMouseDownCanMoveWindow": root.mouseDownCanMoveWindow,
            "hostingMouseDownCanMoveWindow": note.hostingView.mouseDownCanMoveWindow,
            "actionFrames": actionFrames.map(rect), "running": note.model.running,
            "bodyFrame": body.map { rect($0.convert($0.bounds, to: root)) } ?? [:]
        ]
        return Observation(details: details, width: button.bounds.width, compact: compact,
                           completeTitle: titleRect.width >= naturalText - 4, blankIsNotControl: blankClear,
                           actionsFit: fits, bodyFits: bodyFits,
                           truncates: naturalText > titleRect.width + 30 && button.lineBreakMode == .byTruncatingTail,
                           fillsAvailableSpace: copy.minX - popupRect.maxX >= 0 && copy.minX - popupRect.maxX <= 22)
    }
    private static func settle(_ note: StickyWindow) async {
        try? await Task.sleep(for: .milliseconds(90))
        note.window?.contentView?.layoutSubtreeIfNeeded()
        note.window?.displayIfNeeded()
        // SwiftUI publishes the accessibility subtree after the first native layout.
        // Wait for actual geometry, including the currently rendered stop/retry control.
        for _ in 0..<100 {
            if let window = note.window, findTextView(in: note.hostingView) != nil {
                let ids = ["sticky.copy", "sticky.arrow.uturn.backward", note.model.running ? "sticky.stop.fill" : "sticky.arrow.clockwise", "sticky.pin", "sticky.xmark"]
                let ready = ids.allSatisfy { identifier in
                    guard let object = accessible(in: window, identifier: identifier) else { return false }
                    let frame = accessibilityFrame(object)
                    return frame.width > 0 && frame.height > 0
                }
                if ready { break }
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
    private static func popup(in root: NSView) -> NSPopUpButton? {
        if let button = root as? NSPopUpButton, button.accessibilityIdentifier() == "sticky.preset" { return button }
        return root.subviews.lazy.compactMap { popup(in: $0) }.first
    }
    private static func findTextView(in root: NSView) -> StickyTextView? {
        if let text = root as? StickyTextView { return text }
        return root.subviews.lazy.compactMap { findTextView(in: $0) }.first
    }
    private static func select(_ id: UUID, button: NSPopUpButton) -> Bool {
        guard let index = button.itemArray.firstIndex(where: { $0.representedObject as? UUID == id }), let action = button.action else { return false }
        button.selectItem(at: index)
        return NSApp.sendAction(action, to: button.target, from: button)
    }
    private static func accessible(in root: Any, identifier: String) -> NSObject? {
        guard let object = root as? NSObject else { return nil }
        let idSelector = NSSelectorFromString("accessibilityIdentifier")
        if object.responds(to: idSelector), object.perform(idSelector)?.takeUnretainedValue() as? String == identifier { return object }
        let children = NSSelectorFromString("accessibilityChildren")
        guard object.responds(to: children), let items = object.perform(children)?.takeUnretainedValue() as? [Any] else { return nil }
        return items.lazy.compactMap { accessible(in: $0, identifier: identifier) }.first
    }
    private static func accessibilityFrame(_ object: NSObject) -> NSRect {
        let selector = NSSelectorFromString("accessibilityFrame")
        guard object.responds(to: selector) else { return .zero }
        typealias Frame = @convention(c) (AnyObject, Selector) -> NSRect
        return unsafeBitCast(object.method(for: selector), to: Frame.self)(object, selector)
    }
    private static func rect(_ value: NSRect) -> [String: CGFloat] {
        ["x": value.minX, "y": value.minY, "width": value.width, "height": value.height]
    }
    private static func snapshot(_ window: NSWindow, reportURL: URL, name: String) -> Bool {
        guard let view = window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return false }
        do {
            try FileManager.default.createDirectory(at: reportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: reportURL.deletingLastPathComponent().appendingPathComponent(name), options: .atomic)
            return true
        } catch { return false }
    }
    private static func write(_ report: [String: Any], to url: URL) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
        } catch { fputs("Preset layout report: \(error.localizedDescription)\n", stderr) }
    }
    private static func startMovementRecording(_ window: NSWindow, url: URL) {
        if let movementObserver { NotificationCenter.default.removeObserver(movementObserver) }
        frameHistory = []
        recordMovement(window, url: url)
        movementObserver = NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: window, queue: .main) { [weak window] _ in
            Task { @MainActor in
                guard let window else { return }
                recordMovement(window, url: url)
            }
        }
    }
    private static func recordMovement(_ window: NSWindow, url: URL) {
        frameHistory.append(["timestamp": Date().timeIntervalSince1970, "frame": rect(window.frame)])
        write(["frame": rect(window.frame), "history": frameHistory, "moveCount": max(0, frameHistory.count - 1)], to: url)
    }
}
