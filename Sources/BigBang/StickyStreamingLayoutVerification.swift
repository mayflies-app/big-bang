import AppKit
import BigBangCore

/// Exercises the actual native scroll geometry while local output arrives in chunks.
/// This fixture never starts ModelStream or changes persisted settings.
@MainActor enum StickyStreamingLayoutVerification {
    static func run(reportURL: URL) async {
        var checks: [String: Bool] = [:]
        var histories: [String: Any] = [:]
        let supported: [(String, NSScroller.Style)] = [("legacy", .legacy), ("overlay", .overlay)]
        var cases = supported.filter { $0.1 == NSScroller.preferredScrollerStyle }
        if let index = CommandLine.arguments.firstIndex(of: "--sticky-scroller-style"),
           CommandLine.arguments.count > index + 1 {
            let requested = CommandLine.arguments[index + 1]
            cases = supported.filter { $0.0 == requested }
        }
        for (name, style) in cases {
            let note = StickyWindow(preset: Preset.defaults[0], source: "Local streaming geometry fixture", offset: 0)
            var configuration = Configuration(language: .simplifiedChinese)
            configuration.apiBaseURL = "http://127.0.0.1:1/local-streaming-layout"
            note.configureProcessing(configuration: { configuration }, readKey: { "" }, start: { sticky, _, _ in
                sticky.model.autoScroll = true
                sticky.model.output = "稳定首段：串流增长期间保持正文位置与宽度。"
                sticky.model.running = true
                sticky.model.state = "正在生成"
            })
            note.model.retry?()
            note.showWindow(nil)
            note.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            await pause(180)
            guard let window = note.window, let scroll = findScroll(in: note.hostingView),
                  let text = findText(in: note.hostingView), let document = scroll.documentView else {
                checks[name + ".nativeViewsAvailable"] = false
                note.window?.close()
                continue
            }
            checks[name + ".nativeViewsAvailable"] = true
            checks[name + ".preferredScrollerStyleMatchesRequested"] = NSScroller.preferredScrollerStyle == style
            await pause(100)
            for _ in 0..<250 {
                if text.ready && text.renderingComplete && text.renderedSource == note.model.output && text.renderedText.utf16.count >= 4 { break }
                await pause(20)
            }
            checks[name + ".initialRendererReady"] = text.ready && text.renderingComplete && text.renderedSource == note.model.output && text.renderedText.utf16.count >= 4
            guard checks[name + ".initialRendererReady"] == true else { window.close(); continue }
            checks[name + ".shortOutputHidesJumpToLatest"] = element(in: note.hostingView, identifier: "sticky.follow-latest") == nil
            let limit = min(StickyWindow.maximumHeight,
                            max(StickyWindow.minimumHeight, (window.screen?.visibleFrame.height ?? 560) - 40))
            if let visible = window.screen?.visibleFrame {
                window.setFrameOrigin(NSPoint(x: visible.midX - StickyWindow.width / 2,
                                              y: visible.maxY - 30 - window.frame.height))
            }
            let selection = NSRange(location: 0, length: 4)
            let selectedText = (text.renderedText as NSString).substring(with: selection)
            let selectedWidth = text.bounds.width
            let selectedOffset = scroll.documentVisibleRect.minY
            text.setSelectedRange(selection)
            checks[name + ".growingOutputRemainsSelectable"] = await waitFor {
                text.selectedRange() == selection && !note.model.autoScroll
            }
            checks[name + ".pausedShortOutputHidesJumpToLatest"] = element(in: note.hostingView, identifier: "sticky.follow-latest") == nil
            note.model.output += "\n\n选择期间追加的短段落。"
            await pause(100)
            checks[name + ".growthPreservesNativeSelection"] = text.selectedRange() == selection &&
                text.selectedText == selectedText
            checks[name + ".selectionGrowthKeepsWidthAndOffset"] = abs(text.bounds.width - selectedWidth) <= 1 &&
                abs(scroll.documentVisibleRect.minY - selectedOffset) <= 1
            text.setSelectedRange(NSRange(location: 0, length: 0))
            note.model.autoScroll = true
            await pause(80)
            let recorder = Recorder(window: window, scroll: scroll, text: text)
            await recorder.refreshFirstGlyphInset()
            let baselineDOMInset = recorder.firstGlyphInset
            recorder.phase = "baseline"
            recorder.capture("stable")
            let baseline = recorder.samples.last!
            recorder.observe(document: document)
            let top = window.frame.maxY
            let initialHeight = window.frame.height
            let maximumViewportHeight = limit - (initialHeight - scroll.contentView.bounds.height)
            // Short intervals leave the pending native resize exposed. Final-state-only
            // checks would miss the transient overflow that causes the regression.
            recorder.phase = "growth"
            for index in 1...45 {
                note.model.output += "\n\n段落 \(index)：逐段增加内容，观察真实窗口与滚动视图的布局。"
                recorder.capture("append")
                for _ in 0..<12 {
                    await pause(2)
                    recorder.capture("sample")
                }
                if index == 5 {
                    checks[name + ".growthScreenshotSaved"] = snapshot(window, reportURL: reportURL, name: name + "-growth.png")
                }
            }
            await pause(150)
            await recorder.refreshFirstGlyphInset()
            checks[name + ".growthKeepsDOMFirstGlyphInset"] = abs(recorder.firstGlyphInset - baselineDOMInset) <= 1
            recorder.capture("stable")
            // Native frame notifications can observe an unfinished layout transaction.
            // Keep them in the history; assert user-visible stability only after yielding
            // the main run loop, while the output still fits inside the maximum viewport.
            // Once the output itself requires overflow, the growth-to-cap transition may
            // legitimately reveal a scrollbar and move the first glyph above the viewport.
            let growth = recorder.samples.filter {
                $0.phase == "growth" && ($0.event == "sample" || $0.event == "stable") &&
                $0.windowHeight < limit - 1 && $0.documentHeight <= maximumViewportHeight + 1
            }
            checks[name + ".growthSamplesCollected"] = growth.count >= 10 && growth.contains { $0.windowHeight > initialHeight + 10 }
            checks[name + ".growthHasNoTransientScroller"] = !growth.isEmpty && growth.allSatisfy { !$0.scrollerVisible }
            checks[name + ".growthKeepsTextWidth"] = !growth.isEmpty && growth.allSatisfy { abs($0.textWidth - baseline.textWidth) <= 1 }
            checks[name + ".growthKeepsReadingOffset"] = !growth.isEmpty && growth.allSatisfy { abs($0.offsetY) <= 1 }
            checks[name + ".growthKeepsFirstGlyphPosition"] = !growth.isEmpty && growth.allSatisfy { abs($0.firstGlyphTop - baseline.firstGlyphTop) <= 1 }
            checks[name + ".growthKeepsTopAndWindowWidth"] = abs(window.frame.maxY - top) < 1 && abs(window.frame.width - StickyWindow.width) < 1
            checks[name + ".longOutputReachesHeightLimit"] = abs(window.frame.height - limit) < 1
            checks[name + ".heightLimitAllowsOverflow"] = document.bounds.height > scroll.contentView.bounds.height + 100
            checks[name + ".heightLimitFollowsBottom"] = scroll.documentVisibleRect.maxY >= document.bounds.height - 25
            checks[name + ".followingOverflowHidesJumpToLatest"] = element(in: note.hostingView, identifier: "sticky.follow-latest") == nil
            checks[name + ".heightLimitUsesRequestedScrollerStyle"] = scroll.scrollerStyle == style
            checks[name + ".heightLimitRetainsNativeScroller"] = scroll.hasVerticalScroller && scroll.verticalScroller != nil
            if style == .legacy {
                checks[name + ".heightLimitShowsLegacyScroller"] = recorder.samples.last?.scrollerVisible == true
            }
            checks[name + ".overflowScreenshotSaved"] = snapshot(window, reportURL: reportURL, name: name + "-overflow.png")

            recorder.phase = "reading"
            let readingWindowFrame = window.frame
            let readingViewportSize = scroll.contentView.bounds.size
            let readingTextWidth = text.bounds.width
            let bottom = scroll.documentVisibleRect.minY
            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, bottom - 180)))
            scroll.reflectScrolledClipView(scroll.contentView)
            await pause(120)
            let olderOffset = scroll.documentVisibleRect.minY
            if #available(macOS 15.0, *) {
                checks[name + ".readingOlderTextPausesFollowing"] = olderOffset < bottom - 100 && !note.model.autoScroll
            } else {
                // macOS 14 has no onScrollGeometryChange; its context-menu toggle
                // controls following explicitly rather than detecting manual scrolling.
                note.model.autoScroll = false
            }
            checks[name + ".readingOlderTextShowsJumpToLatest"] = await waitFor {
                guard let button = element(in: note.hostingView, identifier: "sticky.follow-latest") else { return false }
                let buttonFrame = accessibilityFrame(button)
                return buttonFrame.width > 0 && buttonFrame.height > 0 && window.frame.contains(buttonFrame) &&
                    accessibilityLabel(button) == "回到最新内容"
            }
            checks[name + ".showingJumpToLatestKeepsGeometry"] = sameGeometry(window.frame, readingWindowFrame) &&
                abs(scroll.contentView.bounds.width - readingViewportSize.width) <= 1 &&
                abs(scroll.contentView.bounds.height - readingViewportSize.height) <= 1 &&
                abs(text.bounds.width - readingTextWidth) <= 1
            note.model.output += "\n\n读旧段落时收到的新内容。"
            await pause(100)
            recorder.capture("stable")
            checks[name + ".newOutputPreservesReadingPosition"] = abs(scroll.documentVisibleRect.minY - olderOffset) < 2
            checks[name + ".newOutputKeepsJumpToLatestVisible"] = element(in: note.hostingView, identifier: "sticky.follow-latest") != nil
            configuration.language = .english
            note.updateConfiguration(configuration)
            checks[name + ".jumpToLatestUpdatesLanguageImmediately"] = await waitFor {
                guard let button = element(in: note.hostingView, identifier: "sticky.follow-latest") else { return false }
                return accessibilityLabel(button) == "Jump to Latest"
            }
            checks[name + ".jumpToLatestLanguageChangeKeepsGeometryAndPosition"] = sameGeometry(window.frame, readingWindowFrame) &&
                abs(scroll.contentView.bounds.width - readingViewportSize.width) <= 1 &&
                abs(scroll.contentView.bounds.height - readingViewportSize.height) <= 1 &&
                abs(text.bounds.width - readingTextWidth) <= 1 && abs(scroll.documentVisibleRect.minY - olderOffset) < 2
            checks[name + ".jumpToLatestScreenshotSaved"] = snapshot(window, reportURL: reportURL, name: name + "-jump-to-latest.png")
            checks[name + ".jumpToLatestAcceptsAccessibilityPress"] = element(in: note.hostingView, identifier: "sticky.follow-latest").map(press) == true
            checks[name + ".jumpToLatestRestoresFollowingAndBottom"] = await waitFor {
                note.model.autoScroll && scroll.documentVisibleRect.maxY >= document.bounds.height - 25
            }
            checks[name + ".jumpToLatestDisappearsAfterResuming"] = await waitFor {
                element(in: note.hostingView, identifier: "sticky.follow-latest") == nil
            }
            checks[name + ".hidingJumpToLatestKeepsGeometry"] = sameGeometry(window.frame, readingWindowFrame) &&
                abs(scroll.contentView.bounds.width - readingViewportSize.width) <= 1 &&
                abs(scroll.contentView.bounds.height - readingViewportSize.height) <= 1 &&
                abs(text.bounds.width - readingTextWidth) <= 1
            note.model.output += "\n\n点击回到最新内容后继续输出。"
            checks[name + ".jumpToLatestContinuesFollowingNewOutput"] = await waitFor {
                text.renderedSource == note.model.output && text.renderingComplete &&
                    scroll.documentVisibleRect.maxY >= document.bounds.height - 25
            }
            configuration.language = .simplifiedChinese
            note.updateConfiguration(configuration)

            // Keep the independent native-scroll route covered after testing the button.
            let resumedBottom = scroll.documentVisibleRect.minY
            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, resumedBottom - 180)))
            scroll.reflectScrolledClipView(scroll.contentView)
            await pause(120)
            if #available(macOS 15.0, *) {
                checks[name + ".readingOlderTextPausesAgainAfterJump"] = !note.model.autoScroll
            } else {
                note.model.autoScroll = false
            }
            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, document.bounds.height - scroll.contentView.bounds.height)))
            scroll.reflectScrolledClipView(scroll.contentView)
            await pause(120)
            if #available(macOS 15.0, *) {
                checks[name + ".returningToBottomResumesFollowing"] = note.model.autoScroll
            } else {
                note.model.autoScroll = true
            }
            note.model.output += "\n\n恢复底部跟随后继续输出。"
            await pause(100)
            checks[name + ".resumedFollowingReachesNewBottom"] = scroll.documentVisibleRect.maxY >= document.bounds.height - 25

            // A live DOM selection must survive a pointer click on the overlay. Rendering
            // later chunks restores that selection and must not pause following again.
            recorder.phase = "selectedTextMouseJump"
            text.setSelectedRange(selection)
            checks[name + ".selectedTextShowsJumpToLatest"] = await waitFor {
                text.selectedRange() == selection && !note.model.autoScroll &&
                    element(in: note.hostingView, identifier: "sticky.follow-latest") != nil
            }
            let liveSelectedText = (try? await text.selectionSnapshot()) ?? ""
            checks[name + ".mouseJumpStartsWithLiveDOMSelection"] = !liveSelectedText.isEmpty && liveSelectedText == selectedText
            checks[name + ".jumpToLatestAcceptsNativeMouseClick"] = element(in: note.hostingView, identifier: "sticky.follow-latest")
                .map { click($0, in: window) } == true
            _ = await waitFor { note.model.autoScroll && scroll.documentVisibleRect.maxY >= document.bounds.height - 25 }
            await pause(120)
            let selectedAfterMouseJump = (try? await text.selectionSnapshot()) ?? ""
            checks[name + ".mouseJumpPreservesSelectionAndResumesFollowing"] = selectedAfterMouseJump == liveSelectedText &&
                !liveSelectedText.isEmpty && text.selectedRange() == selection && note.model.autoScroll &&
                scroll.documentVisibleRect.maxY >= document.bounds.height - 25 &&
                element(in: note.hostingView, identifier: "sticky.follow-latest") == nil
            var selectedChunkObservations: [[String: Any]] = []
            for chunk in 1...2 {
                note.model.output += "\n\n保留正文选区并点击回到最新内容后，第 \(chunk) 次继续输出。"
                let rendered = await waitFor { text.renderedSource == note.model.output && text.renderingComplete }
                // Allow the renderer's selectionchange IPC and SwiftUI updates to settle.
                await pause(160)
                let liveSelection = (try? await text.selectionSnapshot()) ?? ""
                let stillFollowing = note.model.autoScroll && scroll.documentVisibleRect.maxY >= document.bounds.height - 25
                let jumpHidden = element(in: note.hostingView, identifier: "sticky.follow-latest") == nil
                checks[name + ".selectedMouseJumpChunk\(chunk)KeepsFollowing"] = rendered && stillFollowing && jumpHidden
                checks[name + ".selectedMouseJumpChunk\(chunk)KeepsDOMSelection"] = !liveSelectedText.isEmpty &&
                    liveSelection == liveSelectedText && text.selectedRange() == selection
                recorder.capture("stable")
                selectedChunkObservations.append(["chunk": chunk, "rendered": rendered, "selection": liveSelection,
                    "autoScroll": note.model.autoScroll, "jumpHidden": jumpHidden,
                    "visibleBottom": scroll.documentVisibleRect.maxY, "documentHeight": document.bounds.height])
            }
            histories[name + ".selectedMouseJump"] = ["selectionBefore": liveSelectedText,
                "selectionAfterClick": selectedAfterMouseJump, "chunks": selectedChunkObservations]
            let changedSelection = NSRange(location: 1, length: 3)
            text.setSelectedRange(changedSelection)
            checks[name + ".changedNonemptySelectionPausesFollowingAgain"] = await waitFor {
                text.selectedRange() == changedSelection && !note.model.autoScroll &&
                    element(in: note.hostingView, identifier: "sticky.follow-latest") != nil
            }
            text.setSelectedRange(NSRange(location: 0, length: 0))

            let longOutput = note.model.output
            recorder.phase = "retry"
            note.model.retry?()
            checks[name + ".localRetryResetsFollowingAndGeometry"] = await waitFor {
                recorder.capture("settling")
                return text.renderedSource == note.model.output && text.renderingComplete &&
                    note.model.autoScroll && note.model.running &&
                    abs(window.frame.height - StickyWindow.minimumHeight) < 1 &&
                    abs(scroll.documentVisibleRect.minY) < 1 && abs(text.bounds.width - baseline.textWidth) <= 1 &&
                    recorder.samples.last?.scrollerVisible == false
            }
            recorder.capture("stable")

            // Return to overflow so shortening separately exercises the enabled-to-fit
            // transition instead of merely replacing one already-short result.
            recorder.phase = "overflowBeforeShortening"
            note.model.output = longOutput
            await pause(120)
            recorder.capture("stable")
            checks[name + ".shorteningStartsFromOverflow"] = abs(window.frame.height - limit) < 1 &&
                document.bounds.height > scroll.contentView.bounds.height + 100
            recorder.phase = "shortened"
            note.model.output = "短结果"
            note.model.running = false
            await pause(150)
            recorder.capture("stable")
            checks[name + ".shorteningRestoresMinimumHeight"] = abs(window.frame.height - StickyWindow.minimumHeight) < 1
            checks[name + ".shorteningRestoresTopAndNoScroller"] = abs(scroll.documentVisibleRect.minY) < 1 && recorder.samples.last?.scrollerVisible == false
            checks[name + ".shorteningHidesJumpToLatest"] = element(in: note.hostingView, identifier: "sticky.follow-latest") == nil
            recorder.stop()
            histories[name] = recorder.samples.map(\.json)
            note.window?.close()
        }
        let report: [String: Any] = ["passed": !checks.isEmpty && checks.values.allSatisfy { $0 },
                                    "checks": checks, "observations": histories,
                                    "scope": "Packaged native NSPanel and NSScrollView; local incremental output and process-only scrollbar preferences; no model service, keychain or persisted preferences."]
        do {
            try FileManager.default.createDirectory(at: reportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: reportURL, options: .atomic)
        } catch { fputs("Streaming layout report: \(error.localizedDescription)\n", stderr) }
        NSApp.terminate(nil)
    }

    private static func pause(_ milliseconds: Int) async {
        try? await Task.sleep(for: .milliseconds(milliseconds))
    }
    private static func waitFor(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<100 {
            if condition() { return true }
            await pause(20)
        }
        return condition()
    }
    private static func element(in root: Any?, identifier: String) -> NSObject? {
        guard let object = root as? NSObject else { return nil }
        let id = NSSelectorFromString("accessibilityIdentifier")
        if object.responds(to: id), object.perform(id)?.takeUnretainedValue() as? String == identifier { return object }
        let children = NSSelectorFromString("accessibilityChildren")
        guard object.responds(to: children), let items = object.perform(children)?.takeUnretainedValue() as? [Any] else { return nil }
        return items.lazy.compactMap { element(in: $0, identifier: identifier) }.first
    }
    private static func accessibilityLabel(_ object: NSObject) -> String? {
        let selector = NSSelectorFromString("accessibilityLabel")
        guard object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue() as? String
    }
    private static func accessibilityFrame(_ object: NSObject) -> NSRect {
        let selector = NSSelectorFromString("accessibilityFrame")
        guard object.responds(to: selector) else { return .zero }
        typealias Frame = @convention(c) (AnyObject, Selector) -> NSRect
        return unsafeBitCast(object.method(for: selector), to: Frame.self)(object, selector)
    }
    private static func press(_ object: NSObject) -> Bool {
        let selector = NSSelectorFromString("accessibilityPerformPress")
        guard object.responds(to: selector) else { return false }
        typealias Action = @convention(c) (AnyObject, Selector) -> ObjCBool
        return unsafeBitCast(object.method(for: selector), to: Action.self)(object, selector).boolValue
    }
    private static func click(_ object: NSObject, in window: NSWindow) -> Bool {
        let frame = accessibilityFrame(object)
        guard frame.width > 0, frame.height > 0, window.frame.contains(frame) else { return false }
        let location = window.convertPoint(fromScreen: NSPoint(x: frame.midX, y: frame.midY))
        let timestamp = ProcessInfo.processInfo.systemUptime
        guard let down = NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: [],
            timestamp: timestamp, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1),
              let up = NSEvent.mouseEvent(with: .leftMouseUp, location: location, modifierFlags: [],
            timestamp: timestamp + 0.05, windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0) else { return false }
        // AppKit controls may enter a tracking loop in mouseDown. Queue mouseUp
        // first so that loop can consume it before sendEvent returns.
        NSApp.postEvent(up, atStart: true)
        NSApp.sendEvent(down)
        return true
    }
    private static func sameGeometry(_ lhs: NSRect, _ rhs: NSRect) -> Bool {
        abs(lhs.minX - rhs.minX) <= 1 && abs(lhs.minY - rhs.minY) <= 1 &&
            abs(lhs.width - rhs.width) <= 1 && abs(lhs.height - rhs.height) <= 1
    }
    private static func findScroll(in root: NSView) -> NSScrollView? {
        if let scroll = root as? NSScrollView { return scroll }
        return root.subviews.lazy.compactMap { findScroll(in: $0) }.first
    }
    private static func findText(in root: NSView) -> StickyTextView? {
        if let text = root as? StickyTextView { return text }
        return root.subviews.lazy.compactMap { findText(in: $0) }.first
    }
    private static func snapshot(_ window: NSWindow, reportURL: URL, name: String) -> Bool {
        guard let view = window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return false }
        do {
            let folder = reportURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: folder.appendingPathComponent(name), options: .atomic)
            return true
        } catch { return false }
    }

    private struct Sample {
        let phase: String, event: String
        let timestamp: Double
        let windowHeight: CGFloat, viewportHeight: CGFloat, viewportWidth: CGFloat, documentHeight: CGFloat
        let textWidth: CGFloat, offsetY: CGFloat, firstGlyphTop: CGFloat
        let scrollerVisible: Bool, hasScroller: Bool, scrollerHidden: Bool
        let scrollerAlpha: CGFloat
        let scrollerStyle: Int
        var json: [String: Any] {
            ["phase": phase, "event": event, "timestamp": timestamp, "windowHeight": windowHeight,
             "viewportHeight": viewportHeight, "viewportWidth": viewportWidth, "documentHeight": documentHeight,
             "textWidth": textWidth, "offsetY": offsetY, "firstGlyphTop": firstGlyphTop,
             "scrollerVisible": scrollerVisible, "hasScroller": hasScroller, "scrollerHidden": scrollerHidden,
             "scrollerAlpha": scrollerAlpha, "scrollerStyle": scrollerStyle]
        }
    }

    @MainActor private final class Recorder {
        let window: NSWindow, scroll: NSScrollView, text: StickyTextView
        var phase = "baseline"
        var samples: [Sample] = []
        private var observers: [NSObjectProtocol] = []
        private var capturing = false
        private(set) var firstGlyphInset: CGFloat = 0
        func refreshFirstGlyphInset() async {
            if let top = try? await text.evaluate("""
                (() => { const r = document.querySelector('#markdown-root');
                if (!r) return 0; const w = document.createTreeWalker(r, NodeFilter.SHOW_TEXT);
                while (w.nextNode()) { if (!w.currentNode.textContent.trim()) continue;
                const range = document.createRange(); range.setStart(w.currentNode, 0);
                range.setEnd(w.currentNode, Math.min(1, w.currentNode.textContent.length));
                return range.getBoundingClientRect().top; } return 0; })()
                """) as? Double { firstGlyphInset = CGFloat(top) }
        }
        init(window: NSWindow, scroll: NSScrollView, text: StickyTextView) {
            self.window = window; self.scroll = scroll; self.text = text
        }
        func observe(document: NSView) {
            for view in [scroll, scroll.contentView, document, text] {
                view.postsFrameChangedNotifications = true
                view.postsBoundsChangedNotifications = true
                for notification in [NSView.frameDidChangeNotification, NSView.boundsDidChangeNotification] {
                    observers.append(NotificationCenter.default.addObserver(forName: notification, object: view, queue: .main) { [weak self] _ in
                        MainActor.assumeIsolated { self?.capture(notification.rawValue) }
                    })
                }
            }
            observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.capture("windowResize") }
            })
        }
        func capture(_ event: String) {
            guard !capturing else { return }
            capturing = true
            defer { capturing = false }
            let scroller = scroll.verticalScroller
            let visible = scroll.hasVerticalScroller && scroller.map {
                !$0.isHidden && $0.alphaValue > 0.01 && $0.bounds.width > 0 && $0.bounds.height > 0 && $0.knobProportion < 1
            } == true
            // The browser lays out inside a fixed-width native view. Capture its
            // top synchronously with the scroll transaction; the Markdown fixture
            // separately verifies the DOM's first text rectangle and measured height.
            let firstGlyphTop = window.frame.height - text.convert(text.bounds, to: nil).maxY + firstGlyphInset
            samples.append(Sample(phase: phase, event: event, timestamp: Date().timeIntervalSince1970,
                                  windowHeight: window.frame.height, viewportHeight: scroll.contentView.bounds.height,
                                  viewportWidth: scroll.contentView.bounds.width, documentHeight: scroll.documentView?.bounds.height ?? 0,
                                  textWidth: text.bounds.width, offsetY: scroll.documentVisibleRect.minY,
                                  firstGlyphTop: firstGlyphTop, scrollerVisible: visible, hasScroller: scroll.hasVerticalScroller,
                                  scrollerHidden: scroller?.isHidden ?? true, scrollerAlpha: scroller?.alphaValue ?? 0,
                                  scrollerStyle: Int(scroll.scrollerStyle.rawValue)))
        }
        func stop() {
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers.removeAll()
        }
    }
}
