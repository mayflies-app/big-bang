import AppKit
import BigBangCore

@MainActor final class SettingsWindow: NSWindow, TextEditorFocusWindow {
    let textEditorFocus = TextEditorWindowFocus()
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 710, height: 690),
                   styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                   backing: .buffered, defer: false)
        title = L10n.string("大爆炸设置")
        titleVisibility = .hidden
        isReleasedWhenClosed = false
        minSize = NSSize(width: 680, height: 600)
        titlebarAppearsTransparent = true
        isOpaque = false
        backgroundColor = .clear
        center()
    }

    override func cancelOperation(_ sender: Any?) {
        performClose(sender)
    }

    override func close() {
        textEditorFocus.beginClose()
        defer { textEditorFocus.endClose() }
        super.close()
    }

    override func makeKeyAndOrderFront(_ sender: Any?) {
        textEditorFocus.prepareToShow()
        super.makeKeyAndOrderFront(sender)
        SettingsEditingTextView.requestFocus(in: contentView)
    }
}
