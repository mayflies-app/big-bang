import AppKit
import SwiftUI

/// A window owns this value; editors may retain it without retaining the window.
/// Close invalidates focus before delegates, input methods or SwiftUI can reenter.
@MainActor final class TextEditorWindowFocus {
    private(set) var revision = 0
    private(set) var allowsFocus = true
    private var closeDepth = 0

    func beginClose() { closeDepth += 1; revision &+= 1; allowsFocus = false }
    func endClose() { closeDepth -= 1 }
    func prepareToShow() {
        guard closeDepth == 0, !allowsFocus else { return }
        revision &+= 1
        allowsFocus = true
    }
}

@MainActor protocol TextEditorFocusWindow: AnyObject {
    var textEditorFocus: TextEditorWindowFocus { get }
}

/// Clipboard probing temporarily owns pasteboard contents. Keep this live gate
/// separate from editor focus so typing and input methods remain available.
@MainActor final class ClipboardAccessGate: ObservableObject {
    static let shared = ClipboardAccessGate()
    @Published private(set) var isBusy = false
    private var activeProbes = 0

    func begin() {
        activeProbes += 1
        if !isBusy { isBusy = true }
    }
    func end() {
        guard activeProbes > 0 else {
            assertionFailure("Unbalanced clipboard access gate")
            return
        }
        activeProbes -= 1
        if activeProbes == 0 { isBusy = false }
    }
}

/// The input method owns marked text until it commits. SwiftUI updates must not
/// replace that text with the last committed value when save status changes.
struct SettingsTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool
    let palette: SettingsPalette
    let label: String
    let identifier: String
    var onSubmit: (() -> Void)? = nil
    var isolatesScrolling = false

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = SettingsEditorScrollView()
        scroll.isolatesScrolling = isolatesScrolling
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let view = SettingsEditingTextView()
        context.coordinator.registerEditor(view)
        view.isRichText = false
        view.allowsUndo = true
        view.drawsBackground = false
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = true
        view.autoresizingMask = [.width]
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        view.textContainerInset = .zero
        view.font = .systemFont(ofSize: 13)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        view.defaultParagraphStyle = paragraph
        view.string = text
        view.delegate = context.coordinator
        view.onCommittedChange = { [weak coordinator = context.coordinator] view in coordinator?.publish(view) }
        view.onFocusChange = { [weak coordinator = context.coordinator] value in
            guard let coordinator, coordinator.parent.focused != value else { return }
            coordinator.parent.focused = value
        }
        view.onWindowAttached = { [weak coordinator = context.coordinator] view in
            coordinator?.requestFocus(view)
        }
        scroll.documentView = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        (scroll as? SettingsEditorScrollView)?.isolatesScrolling = isolatesScrolling
        guard let view = scroll.documentView as? SettingsEditingTextView else { return }
        view.isEditable = context.environment.isEnabled
        view.isSelectable = context.environment.isEnabled
        if onSubmit != nil {
            view.onSubmit = { [weak coordinator = context.coordinator] view in
                guard let coordinator else { return }
                coordinator.publish(view)
                coordinator.parent.onSubmit?()
            }
        } else {
            view.onSubmit = nil
        }
        if view.textColor != palette.nativeText { view.textColor = palette.nativeText }
        if view.insertionPointColor != palette.nativeText { view.insertionPointColor = palette.nativeText }
        view.setAccessibilityLabel(label)
        view.setAccessibilityIdentifier(identifier)
        // Binding echoes and unrelated redraws leave AppKit's selection, undo
        // history and live input context intact. Only external edits replace text.
        if !view.hasMarkedText(), !view.isHandlingInput, view.string != text {
            let selection = view.selectedRange()
            view.string = text
            let length = text.utf16.count
            let location = min(selection.location, length)
            view.setSelectedRange(NSRange(location: location, length: min(selection.length, length - location)))
            view.undoManager?.removeAllActions()
        }
        context.coordinator.requestFocus(view)
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.retireFocus()
        if let view = scroll.documentView as? SettingsEditingTextView {
            view.invalidateFocusAttachment()
            view.onWindowAttached = nil
        }
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SettingsTextEditor
        private weak var editor: SettingsEditingTextView?
        private var focusRevision = 0
        private var focusRetired = false
        init(_ parent: SettingsTextEditor) { self.parent = parent }
        // Register the weak reference while makeNSView owns a newly created view,
        // never from a callback reentered during AppKit destruction.
        func registerEditor(_ view: SettingsEditingTextView) { editor = view }
        func retireFocus() { focusRetired = true; focusRevision &+= 1; editor = nil }
        func requestFocus(_ view: SettingsEditingTextView) {
            focusRevision &+= 1
            guard !focusRetired, editor === view, view.acceptsFocusRequests,
                  parent.focused, view.isEditable else { return }
            let request = focusRevision
            let attachment = view.focusAttachmentRevision
            let windowFocus = view.windowFocus
            let windowRevision = windowFocus?.revision
            guard windowFocus?.allowsFocus != false else { return }
            // NSView.window is unsafe_unretained. Even creating a weak capture of
            // it can abort during NSWindow.dealloc, before any closure guard runs.
            // Retain only this coordinator for the queued turn; the registered
            // editor stays weak and attachment/close generations cancel stale work.
            DispatchQueue.main.async { [self] in
                guard !focusRetired, focusRevision == request, let view = editor,
                      view.acceptsFocusRequests, view.focusAttachmentRevision == attachment,
                      view.windowFocus === windowFocus, windowFocus?.revision == windowRevision,
                      windowFocus?.allowsFocus != false, parent.focused, view.isEditable,
                      let window = view.window, window.isVisible, window.firstResponder !== view else { return }
                window.makeFirstResponder(view)
            }
        }
        func publish(_ view: SettingsEditingTextView) {
            guard !view.isHandlingInput, !view.hasMarkedText(), parent.text != view.string else { return }
            parent.text = view.string
        }
        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? SettingsEditingTextView else { return }
            publish(view)
        }
        func textDidEndEditing(_ notification: Notification) {
            guard let view = notification.object as? SettingsEditingTextView else { return }
            publish(view)
        }
    }
}

/// Wheel input over an editor belongs to that editor, including at its limits.
/// NSScrollView otherwise forwards boundary events to the settings page's scroll view.
final class SettingsEditorScrollView: NSScrollView {
    var isolatesScrolling = false
    override func scrollWheel(with event: NSEvent) {
        guard isolatesScrolling else { super.scrollWheel(with: event); return }
        guard let document = documentView else { return }
        let viewport = documentVisibleRect
        let delta = event.scrollingDeltaY
        if delta > 0, viewport.minY <= document.bounds.minY { return }
        if delta < 0, viewport.maxY >= document.bounds.maxY { return }
        super.scrollWheel(with: event)
    }
}

final class SettingsEditingTextView: NSTextView {
    private(set) var focusAttachmentRevision = 0
    private(set) var acceptsFocusRequests = false
    private(set) var windowFocus: TextEditorWindowFocus?
    func invalidateFocusAttachment() {
        acceptsFocusRequests = false
        focusAttachmentRevision &+= 1
        windowFocus = nil
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        // Invalidate before AppKit can deactivate the input context and run a
        // nested event loop while the old window is being destroyed.
        invalidateFocusAttachment()
        super.viewWillMove(toWindow: newWindow)
    }
    var onWindowAttached: ((SettingsEditingTextView) -> Void)?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // SwiftUI can create the editor before it has a window. Honor the latest
        // focus intent after attachment instead of relying on one queued update.
        if let window {
            windowFocus = (window as? TextEditorFocusWindow)?.textEditorFocus
            acceptsFocusRequests = true
            onWindowAttached?(self)
        }
    }
    static func requestFocus(in root: NSView?) {
        guard let root else { return }
        if let editor = root as? SettingsEditingTextView { editor.onWindowAttached?(editor) }
        for child in root.subviews { requestFocus(in: child) }
    }
    var onCommittedChange: ((SettingsEditingTextView) -> Void)?
    var onFocusChange: ((Bool) -> Void)?
    var onSubmit: ((SettingsEditingTextView) -> Void)?
    private var inputDepth = 0
    private let editingUndoManager = UndoManager()
    var isHandlingInput: Bool { inputDepth > 0 }
    override var undoManager: UndoManager? { editingUndoManager }

    private static let clipboardActions: Set<Selector> = [
        #selector(NSText.copy(_:)), #selector(NSText.cut(_:)), #selector(NSText.paste(_:)),
        #selector(NSTextView.pasteAsPlainText(_:)), #selector(NSTextView.pasteAsRichText(_:))
    ]
    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(undo(_:)) { return !hasMarkedText() && editingUndoManager.canUndo }
        if item.action == #selector(redo(_:)) { return !hasMarkedText() && editingUndoManager.canRedo }
        if ClipboardAccessGate.shared.isBusy, let action = item.action, Self.clipboardActions.contains(action) { return false }
        return super.validateUserInterfaceItem(item)
    }
    // This editor owns an independent undo stack. Route responder-chain actions
    // here instead of letting NSWindow consume them with its unrelated stack.
    @objc func undo(_ sender: Any?) {
        guard !hasMarkedText() else { return }
        editingUndoManager.undo()
    }
    @objc func redo(_ sender: Any?) {
        guard !hasMarkedText() else { return }
        editingUndoManager.redo()
    }
    override func copy(_ sender: Any?) {
        guard !ClipboardAccessGate.shared.isBusy else { return }
        super.copy(sender)
    }
    override func cut(_ sender: Any?) {
        guard !ClipboardAccessGate.shared.isBusy else { return }
        super.cut(sender)
    }
    override func paste(_ sender: Any?) {
        guard !ClipboardAccessGate.shared.isBusy else { return }
        super.paste(sender)
    }
    override func pasteAsPlainText(_ sender: Any?) {
        guard !ClipboardAccessGate.shared.isBusy else { return }
        super.pasteAsPlainText(sender)
    }
    override func pasteAsRichText(_ sender: Any?) {
        guard !ClipboardAccessGate.shared.isBusy else { return }
        super.pasteAsRichText(sender)
    }
    override func readSelection(from pboard: NSPasteboard) -> Bool {
        guard !ClipboardAccessGate.shared.isBusy else { return false }
        return super.readSelection(from: pboard)
    }
    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard !ClipboardAccessGate.shared.isBusy else { return false }
        return super.readSelection(from: pboard, type: type)
    }
    override func writeSelection(to pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard !ClipboardAccessGate.shared.isBusy else { return false }
        return super.writeSelection(to: pboard, type: type)
    }
    override func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        guard !ClipboardAccessGate.shared.isBusy else { return false }
        return super.writeSelection(to: pboard, types: types)
    }

    private func handleSubmission(_ event: NSEvent) -> Bool {
        guard let onSubmit, event.type == .keyDown, event.keyCode == 36 || event.keyCode == 76,
              event.modifierFlags.intersection([.command, .shift, .control, .option]) == .command else { return false }
        // Consume this shortcut while the IME owns marked text, including an old
        // committed draft. A later keyDown phase must not submit after composition.
        guard !event.isARepeat, !hasMarkedText(), !isHandlingInput else { return true }
        onSubmit(self)
        return true
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if handleSubmission(event) { return true }
        return super.performKeyEquivalent(with: event)
    }
    override func keyDown(with event: NSEvent) {
        if handleSubmission(event) { return }
        super.keyDown(with: event)
    }

    private func handleInput(_ operation: () -> Void) {
        inputDepth += 1
        operation()
        inputDepth -= 1
        if inputDepth == 0 { onCommittedChange?(self) }
    }
    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        handleInput { super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange) }
    }
    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        handleInput { super.insertText(insertString, replacementRange: replacementRange) }
    }
    override func unmarkText() {
        handleInput { super.unmarkText() }
    }
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocusChange?(true) }
        return accepted
    }
    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted {
            onCommittedChange?(self)
            onFocusChange?(false)
        }
        return accepted
    }
}
