import AppKit
import SwiftUI
import WebKit
import BigBangCore

/// One selectable document. Its vertical scrolling belongs to the native host.
/// All Markdown, formula and diagram dependencies ship in the application.
struct StickyMarkdownView: NSViewRepresentable {
    var text: String
    var dark: Bool
    var language: AppLanguage = L10n.currentLanguage
    var onSelection: () -> Void
    var close: () -> Void
    var toggleFollowing: () -> Void = {}
    var following = true
    @State private var measuredHeight: CGFloat = 1

    func makeNSView(context: Context) -> StickyTextView { StickyTextView() }
    func updateNSView(_ view: StickyTextView, context: Context) {
        view.onSelection = onSelection; view.close = close; view.toggleFollowing = toggleFollowing
        view.following = following
        view.heightChanged = { height in
            if abs(measuredHeight - height) > 0.5 { measuredHeight = height }
        }
        view.update(text: text, dark: dark, language: language)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: StickyTextView, context: Context) -> CGSize? {
        CGSize(width: max(1, proposal.width ?? 354), height: max(measuredHeight, nsView.contentHeight))
    }
    static func dismantleNSView(_ view: StickyTextView, coordinator: ()) { view.dispose() }
}

/// The historical name still identifies the single output selection surface.
/// WebKit's content view may own keyboard focus; descendants count as focused.
@MainActor final class StickyTextView: WKWebView, WKNavigationDelegate {
    private let messageProxy: StickyMessageProxy
    private var source = ""
    private var dark = false
    private var language = L10n.currentLanguage
    private var initialized = false
    private var disposed = false
    private var pendingRender = false
    private var wheelMonitor: Any?
    private var clipboardMonitor: Any?
    private var cachedRange = NSRange(location: 0, length: 0)
    private var pageURL: URL?
    private var plainTextFallback = false
    private(set) var resourceLocation = ""
    private(set) var ready = false
    private(set) var revision = 0
    private(set) var renderedRevision = -1
    private(set) var renderedSource = ""
    private(set) var renderedText = ""
    private(set) var selectedText = ""
    private(set) var contentHeight: CGFloat = 1
    private(set) var contentWidth: CGFloat = 354
    private(set) var rendererErrors: [String] = []
    var renderingComplete: Bool { ready && revision == renderedRevision }
    var onSelection: (() -> Void)?
    var close: (() -> Void)?
    var toggleFollowing: (() -> Void)?
    var following = true
    var heightChanged: ((CGFloat) -> Void)?

    init() {
        messageProxy = StickyMessageProxy()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(messageProxy, name: "sticky")
        configuration.userContentController.addUserScript(WKUserScript(source: """
            window.addEventListener('error', e => window.webkit.messageHandlers.sticky.postMessage({type:'error',message:e.message || 'Resource failed: ' + (e.target?.src || e.target?.href || '')}), true);
            document.addEventListener('securitypolicyviolation', e => window.webkit.messageHandlers.sticky.postMessage({type:'error',message:'CSP: ' + e.violatedDirective + ' ' + e.blockedURI}));
            """, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        super.init(frame: NSRect(x: 0, y: 0, width: 354, height: 1), configuration: configuration)
        messageProxy.owner = self
        navigationDelegate = self
        setValue(false, forKey: "drawsBackground")
        setAccessibilityIdentifier("sticky.output")
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, !self.disposed, self.window?.isVisible == true, event.window === self.window,
                  self.visibleRect.contains(self.convert(event.locationInWindow, from: nil)),
                  let scroll = self.outerScrollView else { return event }
            if event.modifierFlags.contains(.shift) || abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) {
                guard self.ready, !self.plainTextFallback else { return event }
                let point = self.convert(event.locationInWindow, from: nil)
                let delta = event.scrollingDeltaX != 0 ? event.scrollingDeltaX : event.scrollingDeltaY
                self.callAsyncJavaScript("window.sticky.scrollHorizontal(x, y, delta);",
                                         arguments: ["x": point.x, "y": self.isFlipped ? point.y : self.bounds.height - point.y,
                                                     "delta": -delta * (event.hasPreciseScrollingDeltas ? 1 : 10)],
                                         in: nil, in: .page, completionHandler: nil)
                return nil
            }
            // WKContentView consumes wheel events even when its document cannot
            // scroll vertically. Keep horizontal events inside tables/code, but
            // hand native vertical scrolling (including momentum) to the host.
            scroll.scrollWheel(with: event)
            return nil
        }
        // WKContentView may own focus and handle clipboard shortcuts before the
        // WKWebView responder. Intercept only this focused output during a probe.
        clipboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, !self.disposed, event.window === self.window,
                  self.isOutputFocused, self.blocksClipboardShortcut(event) else { return event }
            return nil
        }
        loadRenderer()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: contentHeight) }
    var isOutputFocused: Bool {
        guard let responder = window?.firstResponder as? NSView else { return false }
        return responder === self || responder.isDescendant(of: self)
    }
    func update(text: String, dark: Bool, language: AppLanguage) {
        guard !disposed else { return }
        setAccessibilityLabel(L10n.string("输出内容", language: language))
        guard !initialized || source != text || self.dark != dark || self.language != language else { return }
        initialized = true
        source = text; self.dark = dark; self.language = language; revision += 1
        // Coalesce changes in one run-loop turn. JS also rejects obsolete diagram results.
        guard !pendingRender else { return }
        pendingRender = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingRender = false; self.renderLatest()
        }
    }
    private func loadRenderer() {
        plainTextFallback = false
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("Markdown/index.html"),
              FileManager.default.fileExists(atPath: url.path) else {
            showFailure(); return
        }
        pageURL = url
        resourceLocation = url.absoluteString
        loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }
    private func renderLatest() {
        guard ready, !disposed else { return }
        let payload: [String: Any] = ["text": source, "dark": dark,
                                     "language": language == .english ? "en" : "zh-CN", "revision": revision]
        callAsyncJavaScript("window.sticky.render(payload);", arguments: ["payload": payload], in: nil, in: .page) { [weak self] result in
            if case .failure(let error) = result {
                self?.rendererErrors.append("Rendering failed: " + error.localizedDescription)
                self?.showFailure()
            }
        }
    }
    func evaluate(_ script: String) async throws -> Any { try await evaluateJavaScript(script) ?? NSNull() }
    func selectedRange() -> NSRange { cachedRange }
    func setSelectedRange(_ range: NSRange) {
        guard ready, range.location != NSNotFound else { return }
        callAsyncJavaScript("window.sticky.selectRange(location, length);",
                            arguments: ["location": range.location, "length": range.length], in: nil, in: .page,
                            completionHandler: nil)
    }
    /// Read live DOM selection for hotkeys rather than relying on delayed IPC messages.
    func selectionSnapshot() async throws -> String {
        guard ready, !disposed else { return "" }
        guard let selection = try await evaluate("window.sticky.selection()") as? [String: Any] else { return "" }
        return selection["text"] as? String ?? ""
    }
    fileprivate func receive(_ message: WKScriptMessage) {
        guard !disposed, message.frameInfo.isMainFrame,
              let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        if type == "ready" { ready = true; renderLatest(); return }
        let incoming = body["revision"] as? Int ?? -1
        switch type {
        case "error":
            if rendererErrors.count < 20 { rendererErrors.append(body["message"] as? String ?? "Renderer error") }
        case "layout":
            guard incoming == revision, let height = body["height"] as? Double, height.isFinite, height >= 0 else { return }
            renderedRevision = incoming; renderedSource = source
            renderedText = body["text"] as? String ?? renderedText
            contentWidth = CGFloat(body["width"] as? Double ?? Double(bounds.width))
            let next = max(1, ceil(height))
            if abs(next - contentHeight) > 0.5 {
                contentHeight = next; invalidateIntrinsicContentSize(); heightChanged?(next)
            }
        case "selection":
            guard incoming == renderedRevision || incoming == revision else { return }
            selectedText = body["text"] as? String ?? ""
            cachedRange = NSRange(location: max(0, body["location"] as? Int ?? 0), length: max(0, body["length"] as? Int ?? 0))
            // Streaming can restore the same selected fragment at a different offset
            // when Markdown closes. Only a fresh selection pauses the reader's follow choice.
            if !selectedText.isEmpty && body["restored"] as? Bool != true { onSelection?() }
        case "anchor":
            guard incoming == revision, let y = body["y"] as? Double, y.isFinite else { return }
            scrollToDocumentY(CGFloat(y))
        case "toggleFollow": toggleFollowing?()
        case "contextMenu":
            showContextMenu(x: CGFloat(body["x"] as? Double ?? 0), y: CGFloat(body["y"] as? Double ?? 0))
        case "close": close?()
        default: break
        }
    }
    private func showContextMenu(x: CGFloat, y: CGFloat) {
        let menu = NSMenu()
        let copy = menu.addItem(withTitle: L10n.string("复制", language: language), action: #selector(copySelection), keyEquivalent: "")
        copy.target = self; copy.isEnabled = !ClipboardAccessGate.shared.isBusy && !selectedText.isEmpty
        let all = menu.addItem(withTitle: L10n.string("全选", language: language), action: #selector(selectOutput), keyEquivalent: "")
        all.target = self
        menu.addItem(.separator())
        let follow = menu.addItem(withTitle: L10n.string("跟随输出", language: language), action: #selector(toggleOutputFollowing), keyEquivalent: "")
        follow.target = self; follow.state = following ? .on : .off
        menu.autoenablesItems = false
        menu.popUp(positioning: nil, at: NSPoint(x: x, y: isFlipped ? y : bounds.height - y), in: self)
    }
    @objc private func copySelection() {
        guard !ClipboardAccessGate.shared.isBusy else { return }
        Task { @MainActor [weak self] in
            guard !ClipboardAccessGate.shared.isBusy,
                  let selected = try? await self?.selectionSnapshot(), !selected.isEmpty,
                  !ClipboardAccessGate.shared.isBusy else { return }
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(selected, forType: .string)
        }
    }
    @objc private func selectOutput() { setSelectedRange(NSRange(location: 0, length: (renderedText as NSString).length)) }
    @objc private func toggleOutputFollowing() { toggleFollowing?() }
    private func scrollToDocumentY(_ y: CGFloat) {
        guard let scroll = outerScrollView, let document = scroll.documentView else { return }
        let point = document.convert(NSPoint(x: 0, y: isFlipped ? y : bounds.height - y), from: self)
        let target = max(0, min(point.y, document.bounds.height - scroll.contentView.bounds.height))
        scroll.contentView.scroll(to: NSPoint(x: scroll.documentVisibleRect.minX, y: target))
        scroll.reflectScrolledClipView(scroll.contentView)
    }
    private var outerScrollView: NSScrollView? {
        var ancestor = superview
        while let view = ancestor {
            if let scroll = view as? NSScrollView { return scroll }
            ancestor = view.superview
        }
        return nil
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { decisionHandler(.cancel); return }
        if action.navigationType == .linkActivated {
            if ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") { NSWorkspace.shared.open(url) }
            decisionHandler(.cancel)
        } else if plainTextFallback && url.absoluteString == "about:blank" {
            decisionHandler(.allow)
        } else if url.isFileURL, url.standardizedFileURL.path == pageURL?.standardizedFileURL.path {
            // WebKit creates an absolute URL; Bundle may supply a relative URL
            // with a base. URL equality can fail despite identical file locations.
            decisionHandler(.allow)
        }
        else {
            if rendererErrors.count < 20 { rendererErrors.append("Blocked navigation: " + url.absoluteString + " expected: " + (pageURL?.absoluteString ?? "nil")) }
            decisionHandler(.cancel)
        }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        rendererErrors.append("Navigation failed: " + error.localizedDescription)
        if (error as NSError).code != NSURLErrorCancelled { showFailure() }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        rendererErrors.append("Page failed: " + error.localizedDescription)
        if (error as NSError).code != NSURLErrorCancelled { showFailure() }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.ready, !self.plainTextFallback else { return }
            self.showFailure()
        }
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard !disposed else { return }
        ready = false; renderedRevision = -1; selectedText = ""; cachedRange = NSRange(location: 0, length: 0)
        loadRenderer()
    }
    private func showFailure() {
        guard !disposed, !plainTextFallback else { return }
        ready = false; plainTextFallback = true
        let escaped = source.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        // A self-contained fallback preserves the response, sizing, selection and
        // copy when local assets fail. Source is text, never executable HTML.
        loadHTMLString("""
            <!doctype html><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'">
            <style>html,body{margin:0;background:transparent;overflow:hidden}pre{margin:0;white-space:pre-wrap;overflow-wrap:anywhere;font:14px/18px -apple-system}</style>
            <pre id="markdown-root">\(escaped)</pre><script>
            const root=document.getElementById('markdown-root');let revision=0;
            const post=m=>window.webkit.messageHandlers.sticky.postMessage(m);
            const layout=()=>post({type:'layout',revision,height:root.getBoundingClientRect().height+1,width:innerWidth,text:root.textContent});
            const selection=()=>{const s=getSelection();if(!s.rangeCount)return {revision,location:0,length:0,text:''};
              const r=s.getRangeAt(0);if(!root.contains(r.startContainer)||!root.contains(r.endContainer))return {revision,location:0,length:0,text:''};
              const p=document.createRange();p.selectNodeContents(root);p.setEnd(r.startContainer,r.startOffset);
              return {revision,location:p.toString().length,length:r.toString().length,text:s.toString()};};
            window.sticky={render:p=>{revision=p.revision;root.textContent=p.text;root.style.color=p.dark?'#ededed':'#222';layout();},selection,
              selectRange:(location,length)=>{const n=root.firstChild;if(!n)return;const r=document.createRange(),s=getSelection();
                const start=Math.min(n.length,Math.max(0,location));r.setStart(n,start);r.setEnd(n,Math.min(n.length,start+Math.max(0,length)));s.removeAllRanges();s.addRange(r);}};
            document.addEventListener('selectionchange',()=>post({type:'selection',...selection()}));
            document.addEventListener('contextmenu',e=>{e.preventDefault();post({type:'contextMenu',revision,x:e.clientX,y:e.clientY});});
            new ResizeObserver(layout).observe(root);post({type:'ready'});
            </script>
            """, baseURL: nil)
    }
    private func blocksClipboardShortcut(_ event: NSEvent) -> Bool {
        ClipboardAccessGate.shared.isBusy && event.type == .keyDown &&
            event.modifierFlags.contains(.command) && ["c", "x", "v"].contains(event.charactersIgnoringModifiers?.lowercased() ?? "")
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if isOutputFocused, blocksClipboardShortcut(event) { return true }
        return super.performKeyEquivalent(with: event)
    }
    override func keyDown(with event: NSEvent) {
        if blocksClipboardShortcut(event) { return }
        if event.keyCode == 53 { close?() } else { super.keyDown(with: event) }
    }
    func dispose() {
        disposed = true; stopLoading()
        if let wheelMonitor { NSEvent.removeMonitor(wheelMonitor) }
        wheelMonitor = nil
        if let clipboardMonitor { NSEvent.removeMonitor(clipboardMonitor) }
        clipboardMonitor = nil
        configuration.userContentController.removeScriptMessageHandler(forName: "sticky")
        navigationDelegate = nil; onSelection = nil; heightChanged = nil; close = nil; toggleFollowing = nil
    }
}

@MainActor private final class StickyMessageProxy: NSObject, WKScriptMessageHandler {
    weak var owner: StickyTextView?
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        owner?.receive(message)
    }
}
