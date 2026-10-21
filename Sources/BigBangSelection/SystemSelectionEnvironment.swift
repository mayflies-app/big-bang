import AppKit
import ApplicationServices
import BigBangCore

@MainActor struct SystemSelectionEnvironment: SelectionEnvironment {
    private let pasteboard: NSPasteboard
    init(pasteboard: NSPasteboard = .general) { self.pasteboard = pasteboard }
    var isTrusted: Bool { AXIsProcessTrusted() }
    var frontmostPID: Int32? { NSWorkspace.shared.frontmostApplication?.processIdentifier }
    var ownPID: Int32 { ProcessInfo.processInfo.processIdentifier }

    static func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    func selection(pid: Int32) async -> AccessibilitySelection {
        // AX messaging can block on an unresponsive source app. Keep only those C
        // calls off the main actor so the note can appear while capture finishes.
        await Task.detached(priority: .userInitiated) {
            Self.accessibilitySelection(pid: pid)
        }.value
    }

    private nonisolated static func accessibilitySelection(pid: Int32) -> AccessibilitySelection {
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(120))
        let app = AXUIElementCreateApplication(pid)
        let (focusStatus, focused) = attribute(app, kAXFocusedUIElementAttribute, deadline: deadline)
        // If the budget expires before editor classification, retain its metadata
        // grace period rather than accepting a possible whole-line editor copy.
        var result = AccessibilitySelection(isEditorInput: true)
        if focusStatus == .cannotComplete {
            result.isSecureCheckUncertain = true
            return result
        }
        guard let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return result }
        let element = unsafeBitCast(focused, to: AXUIElement.self)
        let (subroleStatus, subrole) = attribute(element, kAXSubroleAttribute, deadline: deadline)
        if subrole as? String == "AXSecureTextField" { return AccessibilitySelection(isSecure: true) }
        guard subroleStatus == .success || subroleStatus == .attributeUnsupported || subroleStatus == .noValue else {
            // A messaging timeout cannot establish that this is an ordinary field.
            // Offer manual input without reading text or sending a fallback copy.
            result.isSecureCheckUncertain = true
            return result
        }
        let (_, text) = attribute(element, kAXSelectedTextAttribute, deadline: deadline)
        result.text = text as? String
        if let text = result.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return result }
        let (_, rangeValue) = attribute(element, kAXSelectedTextRangeAttribute, deadline: deadline)
        if let rangeValue, CFGetTypeID(rangeValue) == AXValueGetTypeID() {
            let value = unsafeBitCast(rangeValue, to: AXValue.self)
            var range = CFRange()
            if AXValueGetValue(value, .cfRange, &range) {
                result.rangeLength = range.length
                if range.length > 0, setMessageTimeout(element, deadline: deadline) {
                    var textValue: CFTypeRef?
                    if AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString,
                                                                 value, &textValue) == .success {
                        result.rangeText = textValue as? String
                    }
                }
            }
        }
        let (classesStatus, classes) = attribute(element, "AXDOMClassList", deadline: deadline)
        if classesStatus == .success {
            result.isEditorInput = isEditorInput(classes: classes as? [String] ?? [])
        } else if classesStatus == .attributeUnsupported || classesStatus == .noValue {
            result.isEditorInput = false
        }
        return result
    }

    private nonisolated static func setMessageTimeout(_ element: AXUIElement, deadline: ContinuousClock.Instant) -> Bool {
        let remaining = ContinuousClock.now.duration(to: deadline)
        guard remaining > .zero else { return false }
        let components = remaining.components
        let seconds = Double(components.seconds) + Double(components.attoseconds) / 1e18
        AXUIElementSetMessagingTimeout(element, Float(min(0.04, seconds)))
        return true
    }

    private nonisolated static func attribute(_ element: AXUIElement, _ name: String,
                                             deadline: ContinuousClock.Instant) -> (AXError, CFTypeRef?) {
        guard setMessageTimeout(element, deadline: deadline) else { return (.cannotComplete, nil) }
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        return (status, value)
    }

    // Chromium exposes the focused DOM node's classes through AXDOMClassList.
    // Use exact editor input markers, not app identity or ancestors: Code's terminal,
    // Find input and webviews also live in the same process but copy ordinary text.
    // https://github.com/microsoft/vscode/blob/main/src/vs/editor/browser/controller/editContext/textArea/textAreaEditContext.ts
    // https://github.com/microsoft/vscode/blob/main/src/vs/editor/browser/controller/editContext/native/nativeEditContext.ts
    nonisolated static func isEditorInput(classes: [String]) -> Bool {
        !Set(classes).isDisjoint(with: ["inputarea", "native-edit-context", "ime-text-area"])
    }

    func shortcutIsHeld(keyCode: UInt16?) -> Bool {
        let modifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
        return !CGEventSource.flagsState(.combinedSessionState).intersection(modifiers).isEmpty ||
            keyCode.map { CGEventSource.keyState(.combinedSessionState, key: $0) } == true
    }

    func clipboardSnapshot() -> ClipboardSnapshot {
        (pasteboard.pasteboardItems ?? []).map { item in
            var snapshot: [String: Data] = [:]
            for type in item.types { if let data = item.data(forType: type) { snapshot[type.rawValue] = data } }
            return snapshot
        }
    }
    var clipboard: SelectionClipboard {
        let board = pasteboard
        let count = board.changeCount
        let text = board.string(forType: .string)
        let types = (board.types ?? []).map(\.rawValue)
        var customData: [String: Data] = [:]
        for name in types where name.contains("chromium") || name == "vscode-editor-data" || name == "application/vnd.code.copymetadata" {
            if let data = board.data(forType: .init(name)) { customData[name] = data }
        }
        return SelectionClipboard(changeCount: count, text: text, customData: customData, isStable: board.changeCount == count, types: types)
    }
    func installMarker(_ marker: String) {
        pasteboard.clearContents()
        pasteboard.setString(marker, forType: .init("app.mayfiles.BigBang.selection-probe"))
    }
    func restoreClipboard(_ snapshot: ClipboardSnapshot) {
        let board = pasteboard
        board.clearContents()
        let items = snapshot.map { types -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in types { item.setData(data, forType: .init(type)) }
            return item
        }
        if !items.isEmpty { board.writeObjects(items) }
    }
    func sendCopy(pid: Int32) throws {
        guard frontmostPID == pid else { throw ValidationError("前台应用已改变，请重新选择并触发。") }
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: false) else {
            throw ValidationError("无法发送复制快捷键。")
        }
        down.flags = .maskCommand; up.flags = .maskCommand
        down.postToPid(pid); up.postToPid(pid)
    }
    func pause(milliseconds: Int) async throws { try await Task.sleep(for: .milliseconds(milliseconds)) }
}
