import AppKit

/// Separate AppKit process used only by native selection checks. The default is
/// the original ordinary window; explicit modes exercise nonactivating focus and
/// native copy fallback without reading credentials, pasteboard contents or network.
@MainActor private final class ExternalSelectionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Hide only the AX selection surface in copy-only mode. NSTextView still owns
/// the real selection and its standard copy implementation.
@MainActor private final class ExternalSelectionTextView: NSTextView {
    var copyOnly = false

    override func accessibilitySelectedText() -> String? {
        copyOnly ? nil : super.accessibilitySelectedText()
    }

    override func accessibilitySelectedTextRange() -> NSRange {
        copyOnly ? NSRange(location: NSNotFound, length: 0) : super.accessibilitySelectedTextRange()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // A nonactivating panel can own input while another app owns the menu
        // bar. Dispatch this real local shortcut through NSTextView's copy path.
        if window?.isKeyWindow == true, window?.firstResponder === self, event.type == .keyDown,
           event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "c" {
            super.copy(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

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
    private let nonactivating: Bool
    private let copyOnly: Bool
    private let originalWorkspacePID: pid_t?
    private let selectedText = "外部原始选区"

    init(readyURL: URL, nonactivating: Bool = false, copyOnly: Bool = false,
         originalWorkspacePID: pid_t? = nil) {
        self.readyURL = readyURL
        self.nonactivating = nonactivating
        self.copyOnly = copyOnly
        self.originalWorkspacePID = originalWorkspacePID
    }

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
        let window: NSWindow
        if nonactivating {
            let panel = ExternalSelectionPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 160),
                                               styleMask: [.titled, .closable, .nonactivatingPanel],
                                               backing: .buffered, defer: false)
            panel.hidesOnDeactivate = false
            panel.level = .floating
            window = panel
        } else {
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 160),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        }
        window.title = "External Selection Fixture"
        window.isReleasedWhenClosed = false
        window.center()
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 160))
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true
        let textView: NSTextView
        if nonactivating || copyOnly {
            let native = ExternalSelectionTextView(frame: scrollView.contentView.bounds)
            native.copyOnly = copyOnly
            textView = native
        } else {
            textView = NSTextView(frame: scrollView.contentView.bounds)
        }
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
        if !nonactivating { NSApp.activate(ignoringOtherApps: true) }
        readyTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for _ in 0..<50 {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { return }
                let workspacePID = NSWorkspace.shared.frontmostApplication?.processIdentifier
                let correctWorkspace = self.nonactivating ?
                    (self.originalWorkspacePID != nil && self.originalWorkspacePID != ProcessInfo.processInfo.processIdentifier &&
                     workspacePID == self.originalWorkspacePID) :
                    workspacePID == ProcessInfo.processInfo.processIdentifier
                if correctWorkspace,
                   window.isVisible, window.isKeyWindow, window.firstResponder === textView,
                   textView.selectedRange() == NSRange(location: 0, length: self.selectedText.utf16.count) {
                    window.displayIfNeeded()
                    do {
                        fputs("fixture-ready pid=\(ProcessInfo.processInfo.processIdentifier) windowNumber=\(window.windowNumber) frame=\(NSStringFromRect(window.frame))\n", stderr)
                        let json = try JSONSerialization.data(withJSONObject: [
                            "ready": true, "pid": ProcessInfo.processInfo.processIdentifier,
                            "workspacePID": workspacePID ?? -1, "windowNumber": window.windowNumber,
                            "selectedUTF16Length": textView.selectedRange().length,
                            "nonactivating": self.nonactivating, "copyOnly": self.copyOnly
                        ], options: [.sortedKeys])
                        try json.write(to: self.readyURL, options: .atomic)
                    } catch {
                        fputs("Fixture readiness write failed: \(error.localizedDescription)\n", stderr)
                        NSApp.terminate(nil)
                    }
                    return
                }
            }
            fputs(self.nonactivating ? "Fixture did not retain the original frontmost app with its panel key and text selected\n" :
                  "Fixture did not become frontmost with its text selected\n", stderr)
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
            let nonactivating = arguments.contains("--nonactivating")
            let originalWorkspacePID = NSWorkspace.shared.frontmostApplication?.processIdentifier
            let app = NSApplication.shared
            app.setActivationPolicy(nonactivating ? .accessory : .regular)
            let delegate = ExternalSelectionFixtureDelegate(readyURL: URL(fileURLWithPath: arguments[index + 1]),
                nonactivating: nonactivating, copyOnly: arguments.contains("--copy-only"),
                originalWorkspacePID: originalWorkspacePID)
            app.delegate = delegate
            app.run()
            withExtendedLifetime(delegate) {}
        } else {
            fputs("Usage: ExternalSelectionFixture --ready /absolute/path/ready.json [--nonactivating] [--copy-only]\n", stderr)
            exit(2)
        }
    }
}
