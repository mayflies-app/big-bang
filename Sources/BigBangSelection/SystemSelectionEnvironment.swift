import AppKit
import ApplicationServices
import BigBangCore

@MainActor final class SystemSelectionEnvironment: SelectionEnvironment {
    private let pasteboard: NSPasteboard
    private var capturedFocus: FocusSnapshot?

    // Immutable AX handles are used only by bounded background AX requests.
    private struct FocusSnapshot: @unchecked Sendable {
        enum Origin { case system, application }
        let target: SelectionTarget
        let workspacePID: Int32
        let origin: Origin
        let element: AXUIElement?
    }
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
        let (selection, focus) = await Task.detached(priority: .userInitiated) {
            let deadline = ContinuousClock.now.advanced(by: .milliseconds(120))
            guard let focus = Self.resolveFocus(workspacePID: pid, deadline: deadline) else {
                return (AccessibilitySelection(isSecureCheckUncertain: true), Optional<FocusSnapshot>.none)
            }
            var selection = Self.accessibilitySelection(focus: focus, deadline: deadline)
            selection.target = focus.target
            return (selection, Optional(focus))
        }.value
        capturedFocus = focus
        return selection
    }

    func isCurrentTarget(_ target: SelectionTarget) async -> Bool {
        guard let captured = capturedFocus, captured.target == target,
              frontmostPID == captured.workspacePID else { return false }
        let matches = await Task.detached(priority: .userInitiated) {
            let deadline = ContinuousClock.now.advanced(by: .milliseconds(40))
            guard let current = Self.resolveFocus(workspacePID: captured.workspacePID, deadline: deadline),
                  current.target.pid == target.pid, current.origin == captured.origin else { return false }
            switch (captured.element, current.element) {
            case let (original?, current?): return CFEqual(original, current)
            case (nil, nil): return true
            default: return false
            }
        }.value
        return matches && frontmostPID == captured.workspacePID
    }

    private nonisolated static func resolveFocus(workspacePID: Int32,
                                                 deadline: ContinuousClock.Instant) -> FocusSnapshot? {
        let system = AXUIElementCreateSystemWide()
        let (status, focused) = attribute(system, kAXFocusedUIElementAttribute, deadline: deadline)
        if status == .success {
            return snapshot(focused, workspacePID: workspacePID, origin: .system)
        }
        // Nonactivating panels can hold keyboard focus while NSWorkspace still
        // names the underlying app. Never replace a valid system focus with that
        // app's old selection. Only an explicitly unavailable attribute permits
        // the legacy application lookup; messaging errors fail closed.
        guard status == .attributeUnsupported || status == .noValue else { return nil }
        let app = AXUIElementCreateApplication(workspacePID)
        let (appStatus, appFocused) = attribute(app, kAXFocusedUIElementAttribute, deadline: deadline)
        if appStatus == .success {
            return snapshot(appFocused, workspacePID: workspacePID, origin: .application)
        }
        guard appStatus == .attributeUnsupported || appStatus == .noValue else { return nil }
        return FocusSnapshot(target: .init(pid: workspacePID, identity: UUID()),
                             workspacePID: workspacePID, origin: .application, element: nil)
    }

    private nonisolated static func snapshot(_ value: CFTypeRef?, workspacePID: Int32,
                                             origin: FocusSnapshot.Origin) -> FocusSnapshot? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let element = unsafeBitCast(value, to: AXUIElement.self)
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, pid > 0 else { return nil }
        return FocusSnapshot(target: .init(pid: pid, identity: UUID()),
                             workspacePID: workspacePID, origin: origin, element: element)
    }

    private nonisolated static func accessibilitySelection(focus: FocusSnapshot,
                                                          deadline: ContinuousClock.Instant) -> AccessibilitySelection {
        // If the budget expires before editor classification, retain its metadata
        // grace period rather than accepting a possible whole-line editor copy.
        var result = AccessibilitySelection(isEditorInput: true)
        guard let element = focus.element else { return result }
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
        guard let capturedFocus, capturedFocus.target.pid == pid,
              frontmostPID == capturedFocus.workspacePID else {
            throw ValidationError("前台应用已改变，请重新选择并触发。")
        }
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
