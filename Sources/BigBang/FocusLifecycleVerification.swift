import AppKit
import SwiftUI
import BigBangCore

/// Native focus cancellation and release boundaries, without saved settings or clipboard access.
@MainActor enum FocusLifecycleVerification {
    static func run() async -> (checks: [String: Bool], observations: [[String: Any]]) {
        var checks: [String: Bool] = [:]
        var observations: [[String: Any]] = []
        let sentinel = StickyPanel(contentRect: NSRect(x: 40, y: 40, width: 240, height: 120),
                                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        sentinel.isReleasedWhenClosed = false
        let sentinelText = NSTextView(frame: NSRect(x: 0, y: 0, width: 240, height: 120))
        sentinel.contentView = sentinelText
        sentinel.makeKeyAndOrderFront(nil)
        sentinel.makeFirstResponder(sentinelText)
        defer { sentinel.close() }

        // Run first: requestFocus is reentered by an actual NSWindow deinitializer,
        // while AppKit still reports that window through its content view.
        let events = DeinitEvents()
        weak var releasedWindow: NSWindow?
        weak var releasedEditor: SettingsEditingTextView?
        autoreleasepool {
            let editor = SettingsEditingTextView()
            editor.isEditable = true
            editor.onFocusChange = { if $0 { events.acceptedFocus += 1 } }
            let parent = SettingsTextEditor(text: .constant("deinit fixture"), focused: .constant(true),
                                            palette: .init(dark: false), label: "Deinit fixture", identifier: "focus.deinit")
            let coordinator = parent.makeCoordinator()
            coordinator.registerEditor(editor)
            var window: ReentrantWindow? = ReentrantWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
                                                           styleMask: [.titled], backing: .buffered, defer: false)
            window?.isReleasedWhenClosed = false
            window?.contentView = editor
            releasedWindow = window
            releasedEditor = editor
            window?.whenDeinitializing = {
                events.entered = true
                events.editorStillAttached = editor.window != nil
                coordinator.requestFocus(editor)
                events.requestReturned = true
                CFRunLoopPerformBlock(CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue) {
                    events.nestedMarker = true
                }
                CFRunLoopWakeUp(CFRunLoopGetCurrent())
                let deadline = ProcessInfo.processInfo.systemUptime + 0.25
                while !events.nestedMarker && ProcessInfo.processInfo.systemUptime < deadline {
                    CFRunLoopRunInMode(.defaultMode, 0.01, true)
                }
                events.exited = true
            }
            window?.close()
            window = nil
        }
        await drainMainQueue()
        let deinitEditorInitiallyReleased = autoreleasepool { releasedEditor == nil }
        let deinitRelease = await observeRelease { releasedWindow == nil && releasedEditor == nil }
        checks["focusLifecycle.deinit.entersRealWindowDeinitializer"] = events.entered && events.editorStillAttached
        checks["focusLifecycle.deinit.requestReturnsDuringTeardown"] = events.requestReturned && events.exited
        checks["focusLifecycle.deinit.nestedRunLoopProcessesMarker"] = events.nestedMarker
        checks["focusLifecycle.deinit.windowAndEditorRelease"] = deinitRelease.released
        checks["focusLifecycle.deinit.neverAcceptsFocus"] = events.acceptedFocus == 0
        checks["focusLifecycle.deinit.preservesSentinelFocus"] = sentinel.firstResponder === sentinelText
        observations.append(["phase": "focusLifecycle.deinit", "entered": events.entered,
            "editorAttachedDuringDeinit": events.editorStillAttached, "requestReturned": events.requestReturned,
            "nestedRunLoopMarker": events.nestedMarker, "acceptedFocusCount": events.acceptedFocus,
            "windowReleased": releasedWindow == nil, "editorReleased": releasedEditor == nil,
            "editorReleasedAfterQueueBarriers": deinitEditorInitiallyReleased,
            "releaseRunLoopTurns": deinitRelease.turns, "releaseMilliseconds": deinitRelease.milliseconds])

        for kind in Consumer.allCases {
            let prefix = "focusLifecycle." + kind.rawValue + "."
            do {
                let owner = Owner(kind: kind)
                let initiallyFocused = await waitUntil { owner.editor.map { owner.window.firstResponder === $0 } == true }
                checks[prefix + "nativeHostingEditorAcceptsFocus"] = initiallyFocused
                if let editor = owner.editor {
                    owner.enqueueFocus(editor)
                    owner.state.focused = false
                    await drainMainQueue()
                    checks[prefix + "changedFocusIntentCancelsQueuedRequest"] = owner.window.firstResponder !== editor
                    owner.state.focused = true
                    editor.onWindowAttached?(editor)
                    checks[prefix + "focusIntentCanRecover"] = await waitUntil { owner.window.firstResponder === editor }

                    owner.enqueueFocus(editor)
                    owner.state.enabled = false
                    editor.isEditable = false
                    owner.hosting.layoutSubtreeIfNeeded()
                    await drainMainQueue()
                    checks[prefix + "disabledEditorCancelsQueuedRequest"] = owner.window.firstResponder !== editor && !editor.isEditable
                    owner.state.enabled = true
                    editor.isEditable = true
                    owner.state.focused = true
                    editor.onWindowAttached?(editor)
                    checks[prefix + "enabledEditorCanRecover"] = await waitUntil { owner.window.firstResponder === editor }

                    owner.enqueueFocus(editor)
                    owner.window.contentView = nil
                    let detached = editor.window == nil
                    await drainMainQueue()
                    checks[prefix + "detachCancelsQueuedRequest"] = detached && editor.window == nil && owner.window.firstResponder !== editor
                    owner.state.focused = true
                    owner.window.contentView = owner.hosting
                    owner.hosting.layoutSubtreeIfNeeded()
                    checks[prefix + "sameEditorRefocusesAfterReattachment"] = await waitUntil {
                        owner.editor === editor && editor.window === owner.window && owner.window.firstResponder === editor
                    }
                    observations.append(["phase": prefix + "cancelAndRecover", "nativeType": String(reflecting: type(of: editor)),
                        "windowType": String(reflecting: type(of: owner.window)), "detachedBeforeDrain": detached,
                        "sameEditorAfterReattach": owner.editor === editor])

                    owner.window.close()
                    let closedFocus = (owner.window as? TextEditorFocusWindow)?.textEditorFocus
                    checks[prefix + "closeDisallowsFocusUntilNormalShow"] = closedFocus?.allowsFocus == false
                    owner.state.focused = true
                    owner.window.makeKeyAndOrderFront(nil)
                    checks[prefix + "sameWindowAndEditorRefocusAfterReopen"] = await waitUntil {
                        owner.editor === editor && owner.window.firstResponder === editor && closedFocus?.allowsFocus == true
                    }
                } else {
                    checks[prefix + "nativeEditorAvailable"] = false
                }
                owner.window.close()
            }

            // A close delegate may reenter show and replace the hosting tree before
            // super.close returns. Observe the production close boundary without changing it.
            do {
                let owner = Owner(kind: kind)
                _ = await waitUntil { owner.editor.map { owner.window.firstResponder === $0 } == true }
                let delegate = CloseReentryDelegate()
                let events = CloseEvents()
                let focus = (owner.window as? TextEditorFocusWindow)?.textEditorFocus
                delegate.whenClosing = {
                    events.entered = true
                    events.insideClose = true
                    defer { events.insideClose = false }
                    events.focusAllowedAtEntry = focus?.allowsFocus ?? true
                    let state = State()
                    let hosting = NSHostingView(rootView: Root(state: state))
                    hosting.frame = NSRect(x: 0, y: 0, width: 320, height: 180)
                    events.state = state
                    events.hosting = hosting
                    hosting.layoutSubtreeIfNeeded()
                    events.editor = Owner.editor(in: hosting)
                    events.editorCreatedBeforeAttachment = events.editor != nil && events.editor?.window == nil
                    if let editor = events.editor {
                        let original = editor.onFocusChange
                        editor.onFocusChange = { [weak closeEvents = events] focused in
                            if focused, closeEvents?.insideClose == true { closeEvents?.acceptedFocusInsideClose += 1 }
                            original?(focused)
                        }
                    }
                    owner.window.contentView = hosting
                    owner.window.makeKeyAndOrderFront(nil)
                    hosting.layoutSubtreeIfNeeded()
                    events.editor = Owner.editor(in: hosting)
                    if let editor = events.editor { editor.onWindowAttached?(editor) }
                    events.focusAllowedAfterReentrantShow = focus?.allowsFocus ?? true
                    CFRunLoopPerformBlock(CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue) {
                        events.nestedMarker = true
                    }
                    CFRunLoopWakeUp(CFRunLoopGetCurrent())
                    let deadline = ProcessInfo.processInfo.systemUptime + 0.25
                    while !events.nestedMarker && ProcessInfo.processInfo.systemUptime < deadline {
                        CFRunLoopRunInMode(.defaultMode, 0.01, true)
                    }
                    events.focusedInsideClose = events.editor.map { owner.window.firstResponder === $0 } ?? true
                    events.focusAllowedAfterNestedLoop = focus?.allowsFocus ?? true
                }
                owner.window.delegate = delegate
                owner.window.close()
                owner.window.delegate = nil
                checks[prefix + "closeDelegateReentersShowWithNewNativeEditor"] =
                    events.entered && events.editorCreatedBeforeAttachment && events.editor != nil && events.nestedMarker
                checks[prefix + "reentrantShowCannotUnlockClosingWindow"] = !events.focusAllowedAtEntry &&
                    !events.focusAllowedAfterReentrantShow && !events.focusAllowedAfterNestedLoop &&
                    !events.focusedInsideClose && events.acceptedFocusInsideClose == 0
                events.state?.focused = true
                owner.window.makeKeyAndOrderFront(nil)
                checks[prefix + "normalShowAfterReentrantCloseRestoresNewEditorFocus"] = await waitUntil {
                    events.editor.map { $0.window === owner.window && owner.window.firstResponder === $0 } == true && focus?.allowsFocus == true
                }
                observations.append(["phase": prefix + "closeDelegateReentry", "entered": events.entered,
                    "nestedRunLoopMarker": events.nestedMarker, "focusAllowedAtEntry": events.focusAllowedAtEntry,
                    "focusAllowedAfterReentrantShow": events.focusAllowedAfterReentrantShow,
                    "focusAllowedAfterNestedLoop": events.focusAllowedAfterNestedLoop,
                    "newEditorFocusedInsideClose": events.focusedInsideClose,
                    "editorCreatedBeforeAttachment": events.editorCreatedBeforeAttachment,
                    "acceptedFocusInsideClose": events.acceptedFocusInsideClose])
                owner.window.close()
            }

            // No automatic attachment callback is installed in this narrow generation case:
            // after moving the same native view, only the explicit new request may focus it.
            do {
                let source = makeWindow(kind: kind)
                let destination = makeWindow(kind: kind)
                let editor = SettingsEditingTextView()
                editor.isEditable = true
                let parent = SettingsTextEditor(text: .constant("reattach fixture"), focused: .constant(true),
                                                palette: .init(dark: false), label: "Reattach fixture", identifier: "focus.reattach")
                let coordinator = parent.makeCoordinator()
                coordinator.registerEditor(editor)
                source.contentView = editor
                source.makeKeyAndOrderFront(nil)
                coordinator.requestFocus(editor)
                let oldAttachment = editor.focusAttachmentRevision
                source.contentView = nil
                destination.contentView = editor
                destination.makeKeyAndOrderFront(nil)
                destination.makeFirstResponder(destination)
                let newAttachment = editor.focusAttachmentRevision
                let attachedWithoutNewRequest = editor.window === destination && destination.firstResponder !== editor
                await drainMainQueue()
                checks[prefix + "oldWindowRequestCannotFocusReattachedEditor"] = attachedWithoutNewRequest &&
                    destination.firstResponder !== editor
                coordinator.requestFocus(editor)
                checks[prefix + "newWindowRequestCanFocusReattachedEditor"] = await waitUntil { destination.firstResponder === editor }
                observations.append(["phase": prefix + "crossWindowReattachment", "oldAttachmentRevision": oldAttachment,
                    "newAttachmentRevision": newAttachment, "attachedWithoutNewRequest": attachedWithoutNewRequest])
                source.close()
                destination.close()
            }
            weak var closedOwner: Owner?
            weak var closedWindow: NSWindow?
            weak var closedEditor: SettingsEditingTextView?
            weak var closedHosting: NSView?
            var queuedWhileAttached = false
            autoreleasepool {
                let owner = Owner(kind: kind)
                closedOwner = owner
                closedWindow = owner.window
                closedHosting = owner.hosting
                if let editor = owner.editor {
                    closedEditor = editor
                    owner.enqueueFocus(editor)
                    queuedWhileAttached = owner.state.focused && editor.window === owner.window && owner.window.firstResponder !== editor
                }
                owner.window.close()
            }
            sentinel.makeKeyAndOrderFront(nil)
            sentinel.makeFirstResponder(sentinelText)
            func observeSentinel(_ stage: String) {
                observations.append(["phase": prefix + "sentinel." + stage,
                    "applicationIsActive": NSApp.isActive, "sentinelIsKey": sentinel.isKeyWindow,
                    "sentinelFirstResponderIsText": sentinel.firstResponder === sentinelText,
                    "keyWindowIsSentinel": NSApp.keyWindow === sentinel,
                    "keyWindowType": NSApp.keyWindow.map { String(reflecting: type(of: $0)) } ?? "none"])
            }
            observeSentinel("immediate")
            await drainMainQueue()
            observeSentinel("afterDrain")
            let editorInitiallyReleased = autoreleasepool { closedEditor == nil }
            let release = await observeRelease {
                closedOwner == nil && closedWindow == nil && closedEditor == nil && closedHosting == nil
            }
            observeSentinel("afterRelease")
            checks[prefix + "closeStartsWithAttachedPendingFocus"] = queuedWhileAttached
            checks[prefix + "closeReleasesOwnerWindowEditorAndHosting"] = release.released
            checks[prefix + "lateFocusDoesNotStealSentinel"] = sentinel.isKeyWindow && sentinel.firstResponder === sentinelText
            observations.append(["phase": prefix + "closeAndRelease", "pendingFocusBeforeClose": queuedWhileAttached,
                "ownerReleased": closedOwner == nil, "windowReleased": closedWindow == nil,
                "editorReleased": closedEditor == nil, "hostingReleased": closedHosting == nil,
                "editorReleasedAfterQueueBarriers": editorInitiallyReleased,
                "releaseRunLoopTurns": release.turns, "releaseMilliseconds": release.milliseconds])
        }
        return (checks, observations)
    }

    private static func drainMainQueue() async {
        for _ in 0..<2 {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }
    private static func observeRelease(_ condition: () -> Bool) async -> (released: Bool, turns: Int, milliseconds: Double) {
        // Native NSTextView can outlive its NSWindow beyond consecutive GCD turns.
        // Observe the unchanged nil condition while the native run loop services its
        // deferred work; isolate each weak load from the observer's autorelease lifetime.
        let began = ProcessInfo.processInfo.systemUptime
        let deadline = began + 3
        var turns = 0
        while !autoreleasepool(invoking: condition), ProcessInfo.processInfo.systemUptime < deadline {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                Timer.scheduledTimer(withTimeInterval: 0.01, repeats: false) { _ in continuation.resume() }
            }
            turns += 1
        }
        return (autoreleasepool(invoking: condition), turns, (ProcessInfo.processInfo.systemUptime - began) * 1000)
    }
    private static func waitUntil(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<30 {
            if condition() { return true }
            await drainMainQueue()
        }
        return condition()
    }
    private enum Consumer: String, CaseIterable { case settings, sticky }
    private static func makeWindow(kind: Consumer) -> NSWindow {
        let window: NSWindow
        if kind == .settings { window = SettingsWindow() }
        else {
            window = StickyPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
                                 styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        }
        window.isReleasedWhenClosed = false
        return window
    }
    @MainActor private final class State: ObservableObject {
        @Published var text = "Focus lifecycle fixture"
        @Published var focused = true
        @Published var enabled = true
    }
    @MainActor private struct Root: View {
        @ObservedObject var state: State
        var body: some View {
            SettingsTextEditor(text: $state.text, focused: $state.focused, palette: .init(dark: false),
                               label: "Focus lifecycle fixture", identifier: "focus.lifecycle.editor")
                .disabled(!state.enabled).frame(width: 300, height: 140)
        }
    }
    @MainActor private final class Owner {
        let state = State()
        let window: NSWindow
        let hosting: NSHostingView<Root>
        var editor: SettingsEditingTextView? { Self.editor(in: hosting) }
        init(kind: Consumer) {
            hosting = NSHostingView(rootView: Root(state: state))
            hosting.frame = NSRect(x: 0, y: 0, width: 320, height: 180)
            if kind == .settings { window = SettingsWindow() }
            else {
                window = StickyPanel(contentRect: hosting.frame, styleMask: [.borderless, .nonactivatingPanel],
                                     backing: .buffered, defer: false)
            }
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            window.makeKeyAndOrderFront(nil)
            hosting.layoutSubtreeIfNeeded()
        }
        func enqueueFocus(_ editor: SettingsEditingTextView) {
            window.makeFirstResponder(window)
            state.focused = true
            hosting.layoutSubtreeIfNeeded()
            // Invoke the real attachment callback installed by SettingsTextEditor, without
            // reproducing Coordinator logic or creating a replacement editor.
            editor.onWindowAttached?(editor)
        }
        static func editor(in view: NSView) -> SettingsEditingTextView? {
            if let editor = view as? SettingsEditingTextView { return editor }
            return view.subviews.lazy.compactMap { editor(in: $0) }.first
        }
    }
    @MainActor private final class DeinitEvents {
        var entered = false
        var editorStillAttached = false
        var requestReturned = false
        var nestedMarker = false
        var exited = false
        var acceptedFocus = 0
    }
    @MainActor private final class ReentrantWindow: NSWindow {
        var whenDeinitializing: (() -> Void)?
        deinit { whenDeinitializing?() }
    }
    @MainActor private final class CloseReentryDelegate: NSObject, NSWindowDelegate {
        var whenClosing: (() -> Void)?
        func windowWillClose(_ notification: Notification) { whenClosing?() }
    }
    @MainActor private final class CloseEvents {
        var entered = false
        var nestedMarker = false
        var focusAllowedAtEntry = true
        var focusAllowedAfterReentrantShow = true
        var focusAllowedAfterNestedLoop = true
        var focusedInsideClose = true
        var editorCreatedBeforeAttachment = false
        var acceptedFocusInsideClose = 0
        var insideClose = false
        var state: State?
        var hosting: NSHostingView<Root>?
        weak var editor: SettingsEditingTextView?
    }
}
