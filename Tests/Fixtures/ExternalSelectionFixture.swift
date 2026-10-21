import AppKit

/// Separate, ordinary AppKit process used only by the native selection smoke.
/// It neither invokes Big Bang nor reads credentials, the clipboard, or network.
@MainActor final class ExternalSelectionFixtureDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var textView: NSTextView?
    private var readyTask: Task<Void, Never>?
    private var eventMonitor: Any?
    private var mouseDownCount = 0
    private var mouseUpCount = 0
    private var keyDownCount = 0
    private var keyUpCount = 0
    private let readyURL: URL
    private let selectedText = "外部原始选区"

    init(readyURL: URL) { self.readyURL = readyURL }

    func applicationDidFinishLaunching(_ notification: Notification) {
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .keyDown, .keyUp]) { [weak self] event in
            guard let self else { return event }
            switch event.type {
            case .leftMouseDown:
                self.mouseDownCount += 1
                fputs("fixture-event type=mouseDown count=\(self.mouseDownCount) modifiers=\(event.modifierFlags.rawValue)\n", stderr)
            case .leftMouseUp:
                self.mouseUpCount += 1
                fputs("fixture-event type=mouseUp count=\(self.mouseUpCount) modifiers=\(event.modifierFlags.rawValue)\n", stderr)
            case .keyDown where event.keyCode == 79:
                self.keyDownCount += 1
                fputs("fixture-event type=keyDown keyCode=79 count=\(self.keyDownCount) modifiers=\(event.modifierFlags.rawValue)\n", stderr)
            case .keyUp where event.keyCode == 79:
                self.keyUpCount += 1
                fputs("fixture-event type=keyUp keyCode=79 count=\(self.keyUpCount) modifiers=\(event.modifierFlags.rawValue)\n", stderr)
            default: break
            }
            return event
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 160),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "External Selection Fixture"
        window.isReleasedWhenClosed = false
        window.center()
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 160))
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true
        let textView = NSTextView(frame: scrollView.contentView.bounds)
        textView.autoresizingMask = [.width, .height]
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = .systemFont(ofSize: 18)
        textView.textContainerInset = NSSize(width: 20, height: 24)
        textView.string = selectedText
        textView.setAccessibilityIdentifier("fixture.external-selection")
        scrollView.documentView = textView
        window.contentView = scrollView
        self.window = window
        self.textView = textView
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: 0, length: selectedText.utf16.count))
        NSApp.activate(ignoringOtherApps: true)
        readyTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for _ in 0..<50 {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { return }
                if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier,
                   window.isVisible, window.isKeyWindow, window.firstResponder === textView,
                   textView.selectedRange() == NSRange(location: 0, length: self.selectedText.utf16.count) {
                    window.displayIfNeeded()
                    do {
                        fputs("fixture-ready pid=\(ProcessInfo.processInfo.processIdentifier) windowNumber=\(window.windowNumber) frame=\(NSStringFromRect(window.frame))\n", stderr)
                        let json = try JSONSerialization.data(withJSONObject: ["ready": true, "pid": ProcessInfo.processInfo.processIdentifier], options: [.sortedKeys])
                        try json.write(to: self.readyURL, options: .atomic)
                    } catch {
                        fputs("Fixture readiness write failed: \(error.localizedDescription)\n", stderr)
                        NSApp.terminate(nil)
                    }
                    return
                }
            }
            fputs("Fixture did not become frontmost with its text selected\n", stderr)
            NSApp.terminate(nil)
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) {
        readyTask?.cancel()
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
    }
}

@main enum ExternalSelectionFixtureApplication {
    @MainActor static func main() {
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--ready"), arguments.indices.contains(index + 1) {
            let app = NSApplication.shared
            app.setActivationPolicy(.regular)
            let delegate = ExternalSelectionFixtureDelegate(readyURL: URL(fileURLWithPath: arguments[index + 1]))
            app.delegate = delegate
            app.run()
            withExtendedLifetime(delegate) {}
        } else {
            fputs("Usage: ExternalSelectionFixture --ready /absolute/path/ready.json\n", stderr)
            exit(2)
        }
    }
}
