import AppKit
import WebKit
import BigBangCore

/// Real offline renderer, native panel, selection bridge and incremental output.
/// No model request, credentials, global hotkeys or persisted settings are used.
@MainActor enum StickyMarkdownVerification {
    private static var previewNote: StickyWindow?
    static func run(reportURL: URL, registerPreview: ((StickyWindow) -> Void)? = nil) async {
        let preview = CommandLine.arguments.contains("--sticky-markdown-preview")
        var checks: [String: Bool] = [:]
        var observations: [String: Any] = [:]
        let note = StickyWindow(preset: Preset.defaults[0], source: "Local Markdown contract fixture", offset: 0)
        registerPreview?(note)
        if preview { previewNote = note }
        note.model.output = matrix
        note.model.running = false
        note.showWindow(nil)
        note.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        guard await wait({ findText(in: note.hostingView) != nil }),
              let text = findText(in: note.hostingView), let window = note.window else {
            checks["nativeRendererAvailable"] = false
            finish(checks, observations: observations, reportURL: reportURL)
            return
        }
        checks["nativeRendererAvailable"] = true
        checks["initialRevisionRendered"] = await rendered(text, source: matrix)
        observations["initialRenderer"] = await diagnostics(text)
        guard checks["initialRevisionRendered"] == true else {
            checks["rendererEvaluationSucceeded"] = false
            if !preview { window.close() }
            finish(checks, observations: observations, reportURL: reportURL)
            return
        }
        if preview {
            checks["previewLayoutStable"] = await stableMatrixLayout(text)
            if checks["previewLayoutStable"] == true {
                checks["previewBodyScreenshotSaved"] = await snapshot(text, reportURL: reportURL, name: "markdown-preview.png")
                checks["previewWindowScreenshotSaved"] = nativeSnapshot(window, reportURL: reportURL, name: "markdown-preview-window.png")
            } else { checks["previewBodyScreenshotSaved"] = false; checks["previewWindowScreenshotSaved"] = false }
            observations["mode"] = "Visible format matrix preview; behavioral test sequence not executed."
            finish(checks, observations: observations, reportURL: reportURL)
            return
        }
        do {
            let matrixResult = try await text.evaluate("""
                (() => { const r = document.querySelector('#markdown-root');
                const has = s => !!r.querySelector(s);
                return {headings: has('h1') && has('h2') && has('h3') && has('h4') && has('h5') && has('h6'),
                inline: has('strong') && has('em') && has('s,del') && has('p code'),
                lists: has('ol li') && has('ul li ul li'), tasks: r.querySelectorAll('input[type=checkbox]').length === 2 && !!r.querySelector('input:checked'),
                blocks: has('blockquote') && has('hr') && has('pre code'),
                alerts: r.querySelector('.markdown-alert-note .markdown-alert-title')?.textContent === 'NOTE' && r.querySelector('.markdown-alert-note')?.textContent.includes('提示内容') === true,
                table: has('table thead th') && r.querySelectorAll('table tbody tr').length === 2,
                links: r.querySelector('a[href="https://example.com/reference"]')?.textContent === '引用链接' && has('a[href="https://example.com/auto"]'),
                footnotes: has('.footnote-ref a[href="#fn1"]') && !!r.querySelector('.footnotes #fn1 strong') && has('.footnote-backref'),
                image: has('img[alt="Embedded pixel"]'),
                readOnly: !r.isContentEditable,
                localAssets: [...document.scripts].filter(s=>s.src).every(s=>s.src.startsWith('file:') || s.src.startsWith('sticky-resource:')),
                rootWidth: r.getBoundingClientRect().width, bodyWidth: document.body.getBoundingClientRect().width,
                domHeight: document.documentElement.scrollHeight,
                firstTextTop: r.querySelector('h1').getBoundingClientRect().top,
                resources: [...document.scripts].map(s=>s.src)}; })()
                """)
            observations["formatMatrix"] = matrixResult
            if let values = matrixResult as? [String: Any] {
                for name in ["headings", "inline", "lists", "tasks", "blocks", "alerts", "table", "links", "footnotes", "image", "readOnly", "localAssets"] {
                    checks["format." + name] = values[name] as? Bool == true
                }
                checks["measuredNativeHeightMatchesDOM"] = abs(text.bounds.height - text.contentHeight) < 2 && text.contentHeight > 100
            }
            checks["mathAndMermaidRendered"] = await waitJS(text, "(() => { const svg = document.querySelector('#markdown-root .diagram-rendered svg'); return document.querySelectorAll('#markdown-root .katex').length === 4 && document.querySelectorAll('#markdown-root .math-display .katex').length === 2 && !!svg && svg.getBoundingClientRect().width > 0 && svg.getBoundingClientRect().height > 0 && svg.textContent.includes('输入') && svg.textContent.includes('输出'); })()")
            checks["embeddedImageLoaded"] = await waitJS(text, "(() => { const i = document.querySelector('img[alt=\"Embedded pixel\"]'); return !!i && i.complete && i.naturalWidth > 0; })()")
            observations["renderedHTML"] = try await text.evaluate("document.querySelector('#markdown-root').innerHTML")
            checks["lightLayoutStableBeforeSnapshot"] = await stableMatrixLayout(text)
            if checks["lightLayoutStableBeforeSnapshot"] == true {
                checks["lightScreenshotSaved"] = await snapshot(text, reportURL: reportURL, name: "markdown-light.png")
                checks["lightWindowScreenshotSaved"] = nativeSnapshot(window, reportURL: reportURL, name: "markdown-light-window.png")
            } else { checks["lightScreenshotSaved"] = false; checks["lightWindowScreenshotSaved"] = false }
            let originalWidth = window.frame.width
            let originalTextWidth = text.bounds.width
            let documentFitsWidth = (try await text.evaluate("document.documentElement.scrollWidth <= innerWidth + 1")) as? Bool == true
            checks["longBlocksDoNotExpandWindow"] = abs(originalWidth - StickyWindow.width) < 1 && documentFitsWidth
            window.appearance = NSAppearance(named: .darkAqua)
            checks["darkForegroundUpdated"] = await waitJS(text, "(() => { const c=getComputedStyle(document.querySelector('#markdown-root')).color; return Number(c.match(/\\d+/)?.[0]) > 200; })()")
            checks["darkLayoutStableBeforeSnapshot"] = await stableMatrixLayout(text)
            if checks["darkLayoutStableBeforeSnapshot"] == true {
                checks["darkScreenshotSaved"] = await snapshot(text, reportURL: reportURL, name: "markdown-dark.png")
                checks["darkWindowScreenshotSaved"] = nativeSnapshot(window, reportURL: reportURL, name: "markdown-dark-window.png")
            } else { checks["darkScreenshotSaved"] = false; checks["darkWindowScreenshotSaved"] = false }
            checks["darkAppearanceKeepsWidth"] = abs(text.bounds.width - originalTextWidth) < 1 && abs(window.frame.width - originalWidth) < 1
            // Internal links must move the native outer viewport, not a hidden
            // WebKit viewport. Check both the note and its return link.
            var ancestor = text.superview
            while let parent = ancestor, !(parent is NSScrollView) { ancestor = parent.superview }
            if let scroll = ancestor as? NSScrollView {
                note.model.autoScroll = false
                let wheels = try await verifyWheelBehavior(text, window: window, scroll: scroll)
                checks.merge(wheels.checks) { _, new in new }
                observations["wheelBehavior"] = wheels.observations
                scroll.contentView.scroll(to: .zero)
                scroll.reflectScrolledClipView(scroll.contentView)
                await pause(100)
                _ = try await text.evaluate("document.querySelector('.footnote-ref a').click(); true")
                checks["footnoteLinkScrollsNativeViewport"] = await wait { scroll.documentVisibleRect.minY > 100 }
                let footnoteOffset = scroll.documentVisibleRect.minY
                _ = try await text.evaluate("document.querySelector('.footnote-backref').click(); true")
                checks["footnoteBacklinkReturnsToReference"] = await wait { scroll.documentVisibleRect.minY < footnoteOffset - 50 }
                observations["anchorNavigation"] = ["outputIsFlipped": text.isFlipped, "footnoteOffset": footnoteOffset,
                                                     "referenceOffset": scroll.documentVisibleRect.minY]
            } else { checks["footnoteLinkScrollsNativeViewport"] = false }

            // The header copy action exports exactly the source. Preserve all clipboard
            // representations and restore only if nobody else wrote during this check.
            let board = NSPasteboard.general
            let saved = board.pasteboardItems?.map { item in item.types.compactMap { type in item.data(forType: type).map { (type, $0) } } } ?? []
            if let button = accessible(in: window, identifier: "sticky.copy") {
                checks["headerCopyActionResponds"] = press(button)
                let ownedChange = board.changeCount
                await pause(80)
                checks["headerCopiesRawMarkdown"] = board.string(forType: .string) == matrix
                if board.changeCount == ownedChange {
                    board.clearContents()
                    let items = saved.map { values in let item = NSPasteboardItem(); for (type, data) in values { item.setData(data, forType: type) }; return item }
                    if !items.isEmpty { board.writeObjects(items) }
                }
            } else { checks["headerCopyActionResponds"] = false }

            let tableCases = try await verifyTableRegressions(note, text: text, window: window, reportURL: reportURL)
            checks.merge(tableCases.checks) { _, new in new }
            observations["tableRegression"] = tableCases.observations

            let syntaxCases = try await verifyExtendedSyntax(note, text: text, window: window, reportURL: reportURL)
            checks.merge(syntaxCases.checks) { _, new in new }
            observations["extendedSyntax"] = syntaxCases.observations

            let diagramCases = try await verifyMermaidRegressions(note, text: text)
            checks.merge(diagramCases.checks) { _, new in new }
            observations["mermaidRegression"] = diagramCases.observations

            let selectedSource = "第一段 🌍 café\n\n第二段含 **重点** 和尾声。"
            note.model.output = selectedSource
            checks["selectionFixtureRendered"] = await rendered(text, source: selectedSource)
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(text)
            let selection = NSRange(location: 0, length: (text.renderedText as NSString).range(of: "重点").location + 2)
            text.setSelectedRange(selection)
            checks["crossParagraphUnicodeSelection"] = await wait({ text.selectedRange() == selection && text.selectedText.contains("🌍 café") && text.selectedText.contains("第二段") })
            let selected = text.selectedText
            checks["nativeSelectedOutputReadsDOM"] = (try? await note.selectedOutputTextSnapshot()) == selected && !selected.isEmpty
            checks["selectingPausesFollowing"] = !note.model.autoScroll
            note.model.output += "\n\n流式新段落"
            checks["selectionGrowthRendered"] = await rendered(text, source: note.model.output)
            checks["streamingKeepsUnicodeSelection"] = text.selectedText == selected && text.selectedRange() == selection

            note.model.output = "尚未结束的 **重点 🌍"
            checks["unclosedInlineRendered"] = await rendered(text, source: note.model.output)
            text.setSelectedRange((text.renderedText as NSString).range(of: "重点 🌍"))
            checks["unclosedInlineSelectionPausesFollowing"] = await wait {
                text.selectedText == "重点 🌍" && !note.model.autoScroll
            }
            let unclosedSelectionRange = text.selectedRange()
            note.model.autoScroll = true
            note.model.output += "**\n\n下一段"
            checks["closedInlineRendered"] = await rendered(text, source: note.model.output)
            _ = await wait { text.selectedText == "重点 🌍" && text.selectedRange() != unclosedSelectionRange }
            // Restoring the same selected text can move its DOM range when Markdown
            // delimiters close. Let selectionchange IPC settle before checking following.
            await pause(160)
            checks["closingMarkersKeepSelectedText"] = text.selectedText == "重点 🌍"
            checks["closingMarkersMoveSelectedRange"] = text.selectedRange().length > 0 &&
                text.selectedRange() != unclosedSelectionRange
            let restoredInlineSelection = try? await text.selectionSnapshot()
            checks["closingMarkersKeepFollowingWithRestoredSelection"] = note.model.autoScroll &&
                restoredInlineSelection == "重点 🌍"
            observations["inlineSelectionRestoration"] = ["rangeBefore": NSStringFromRange(unclosedSelectionRange),
                "rangeAfter": NSStringFromRange(text.selectedRange()), "selectedText": text.selectedText,
                "autoScroll": note.model.autoScroll]
            let differentInlineSelection = (text.renderedText as NSString).range(of: "下一段")
            text.setSelectedRange(differentInlineSelection)
            checks["userSelectionAfterInlineRestorePausesFollowing"] = await wait {
                differentInlineSelection.location != NSNotFound && text.selectedRange() == differentInlineSelection &&
                    text.selectedText == "下一段" && !note.model.autoScroll
            }

            note.model.output = "```swift\nlet unfinished = 1\n\n**still code"
            let unclosedRendered = await rendered(text, source: note.model.output)
            let unclosedReadable = await waitJS(text, "document.querySelector('pre code')?.textContent.includes('unfinished') === true")
            checks["unclosedFenceReadable"] = unclosedRendered && unclosedReadable
            note.model.output = "<script>window.injected=true</script>\n\n[unsafe](javascript:alert(1))\n\n![local](file:///etc/passwd)\n\n$$\\notARealCommand{x}$$\n\n```mermaid\nthis is invalid syntax\n```"
            checks["invalidSyntaxSettles"] = await rendered(text, source: note.model.output)
            checks["unsafeContentInert"] = await waitJS(text, "window.injected !== true && !document.querySelector('#markdown-root script') && !document.querySelector('#markdown-root a[href^=\"javascript:\"]') && !document.querySelector('#markdown-root img[src^=\"file:\"]')")
            checks["invalidMathAndMermaidRemainReadable"] = await waitJS(text, "document.querySelector('#markdown-root').textContent.includes('notARealCommand') && document.querySelector('#markdown-root').textContent.includes('this is invalid syntax')")
            observations["invalidSyntaxHTML"] = try await text.evaluate("document.querySelector('#markdown-root').innerHTML")

            // Queue expensive diagrams, then shorten before their render can settle.
            // Old asynchronous SVG/height callbacks must not resurrect the old source.
            note.model.output = matrix + "\n\n```mermaid\ngraph TD\n" + (1...60).map { "A\($0) --> A\($0+1)" }.joined(separator: "\n") + "\n```"
            await pause(5)
            note.model.output = "短结果 🌍"
            note.model.stop()
            checks["latestRevisionWins"] = await rendered(text, source: note.model.output)
            await pause(500)
            let finalDOMMatches = await waitJS(text, "!document.querySelector('#markdown-root svg') && document.querySelector('#markdown-root').textContent.trim() === '短结果 🌍'")
            checks["staleDiagramDoesNotReturn"] = text.renderedSource == "短结果 🌍" && finalDOMMatches
            checks["shorteningRestoresMinimumHeight"] = abs(window.frame.height - StickyWindow.minimumHeight) < 1 && abs(window.frame.width - originalWidth) < 1
            checks["shorteningClearsObsoleteSelection"] = text.selectedText.isEmpty
            observations["final"] = ["nativeHeight": text.bounds.height, "measuredHeight": text.contentHeight, "windowFrame": NSStringFromRect(window.frame), "source": text.renderedSource]

            // Simulate a genuine bundled renderer failure through its public JS seam.
            // The recovery document must preserve plain source and remain selectable.
            _ = try await text.evaluate("delete window.sticky.render; true")
            let fallbackSource = "## 资源故障原文 🌍\n\n<script>window.fallbackInjected = true</script>"
            note.model.output = fallbackSource
            checks["failedRendererFallsBackToPlainSource"] = await rendered(text, source: fallbackSource)
            checks["fallbackUsesSelfContainedDocument"] = text.ready && text.url?.absoluteString == "about:blank"
            checks["fallbackKeepsInertRawMarkdown"] = await waitJS(text, "(() => { const r=document.querySelector('#markdown-root'); return r.textContent.includes('## 资源故障原文 🌍') && r.textContent.includes('<script>window.fallbackInjected = true</script>') && !r.querySelector('script') && window.fallbackInjected !== true; })()")
            checks["fallbackMeasuredHeightMatchesNative"] = await wait { abs(text.bounds.height - text.contentHeight) < 2 && text.contentHeight > 18 }
            checks["fallbackPreservesSource"] = text.renderedSource == fallbackSource && text.renderedText == fallbackSource
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(text)
            text.setSelectedRange((text.renderedText as NSString).range(of: "资源故障原文 🌍"))
            checks["fallbackTextRemainsSelectable"] = await wait { text.selectedText == "资源故障原文 🌍" }
            checks["fallbackNativeSelectionSnapshot"] = (try? await note.selectedOutputTextSnapshot()) == "资源故障原文 🌍"
            checks["fallbackScreenshotSaved"] = await snapshot(text, reportURL: reportURL, name: "markdown-resource-fallback.png")
            let fallbackSelection = "资源故障原文 🌍"
            let fallbackRange = (fallbackSource as NSString).range(of: fallbackSelection)
            func selectFallbackText() async -> Bool {
                // A repeated range can already match the native cache while its
                // asynchronous user-selection event is still in flight. Establish
                // a fresh selection before the next explicit follow action.
                text.setSelectedRange(NSRange(location: 0, length: 0))
                guard await wait({ text.selectedText.isEmpty && text.selectedRange().length == 0 }) else { return false }
                text.setSelectedRange(fallbackRange)
                return await wait { text.selectedText == fallbackSelection && text.selectedRange() == fallbackRange && !note.model.autoScroll }
            }
            func fallbackSelectionIsIntact() async -> Bool {
                (try? await text.selectionSnapshot()) == fallbackSelection && text.selectedText == fallbackSelection && text.selectedRange() == fallbackRange
            }
            note.model.output += "\n\n追加流式原文 **保持可读**。"
            checks["fallbackStreamingUpdatesSource"] = await rendered(text, source: note.model.output)
            checks["fallbackStreamingRemainsInert"] = await waitJS(text, "document.querySelector('#markdown-root').textContent.includes('追加流式原文 **保持可读**。') && window.fallbackInjected !== true")
            await pause(160)
            checks["fallbackStreamingPreservesLiveUnicodeSelection"] = await fallbackSelectionIsIntact()

            // Reset the user selection for each redraw so a prior failure cannot
            // make the appearance/language cases pass with an already empty range.
            let languageSelectionReady = await selectFallbackText()
            let languageRevision = text.revision
            note.setLanguage(to: .english)
            checks["fallbackLanguageChangeRendered"] = await wait { text.revision > languageRevision && text.renderingComplete }
            await pause(160)
            let languageSelectionIntact = await fallbackSelectionIsIntact()
            checks["fallbackLanguageChangePreservesSelection"] = languageSelectionReady && languageSelectionIntact

            let appearanceSelectionReady = await selectFallbackText()
            let appearanceRevision = text.revision
            window.appearance = NSAppearance(named: .aqua)
            checks["fallbackAppearanceChangeRendered"] = await wait { text.revision > appearanceRevision && text.renderingComplete }
            await pause(160)
            let appearanceSelectionIntact = await fallbackSelectionIsIntact()
            checks["fallbackAppearanceChangePreservesSelection"] = appearanceSelectionReady && appearanceSelectionIntact

            let followingSelectionReady = await selectFallbackText()
            note.model.autoScroll = true
            note.model.output += "\n\n继续跟随的新内容。"
            checks["fallbackFollowingGrowthRendered"] = await rendered(text, source: note.model.output)
            await pause(160)
            let followingSelectionIntact = await fallbackSelectionIsIntact()
            observations["fallbackFollowingSelection"] = ["selectionEstablishedBeforeFollowing": followingSelectionReady,
                "liveSelectionIntactAfterGrowth": followingSelectionIntact, "followingAfterGrowth": note.model.autoScroll,
                "nativeRange": NSStringFromRange(text.selectedRange()), "expectedRange": NSStringFromRange(fallbackRange)]
            checks["fallbackRestoredSelectionKeepsExplicitFollowing"] = followingSelectionReady &&
                followingSelectionIntact && note.model.autoScroll

            let obsoleteSelectionReady = await selectFallbackText()
            note.model.output = "全新的结果，不含旧的选中文本。"
            checks["fallbackReplacementRendered"] = await rendered(text, source: note.model.output)
            await pause(160)
            let replacedSelection = try? await text.selectionSnapshot()
            checks["fallbackReplacementClearsObsoleteSelection"] = obsoleteSelectionReady && replacedSelection == "" &&
                text.selectedText.isEmpty && text.selectedRange().length == 0
            observations["fallbackRenderer"] = await diagnostics(text)
        } catch {
            observations["error"] = error.localizedDescription
            observations["failedRenderer"] = await diagnostics(text)
            checks["rendererEvaluationSucceeded"] = false
        }
        window.makeKeyAndOrderFront(nil)
        if let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53) {
            NSApp.postEvent(escape, atStart: false)
            checks["escapeClosesFocusedPanel"] = await wait({ !window.isVisible })
        } else { checks["escapeClosesFocusedPanel"] = false }
        window.close()
        finish(checks, observations: observations, reportURL: reportURL)
    }

    private static func verifyTableRegressions(_ note: StickyWindow, text: StickyTextView, window: NSWindow, reportURL: URL) async throws -> (checks: [String: Bool], observations: [String: Any]) {
        var checks: [String: Bool] = [:], evidence: [String: Any] = [:]
        let following = note.model.autoScroll
        defer { note.model.autoScroll = following }
        note.model.autoScroll = false
        let source = """
        | 内容 | 状态 | 数量 |
        | :--- | :---: | ---: |
        | 中文内容包含很长的说明文字和表情 🌍，应完整显示并允许自然换行直到这一段的末尾。 | 好 | 42 |
        | English prose should wrap naturally while keeping every word visible inside the note window. | OK | 7 |
        | identifier_abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 | ID | 99 |
        | <https://example.com/very/long/path/abcdefghijklmnopqrstuvwxyz0123456789?query=unbrokenvalue> | URL | 3 |
        | `inline_code_abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789` | Code | 8 |

        > | 引用内表格内容 | 值 |
        > | :--- | ---: |
        > | 嵌套引用里的长内容仍然需要在可用宽度内换行且尾部清晰可见。 | 21 |

        表格尾部可访问 TABLE_END
        """
        note.model.output = source
        checks["table.fixtureRendered"] = await rendered(text, source: source)
        _ = try await text.evaluate("window.__tableFixtureWidth=document.querySelector('#markdown-root').style.width; true")
        do {
            // Content-width coverage only: the product's sticky panel stays fixed-width.
            for (name, width) in [("narrow", min(240, text.bounds.width)), ("wide", text.bounds.width)] {
                _ = try await text.evaluate("document.querySelector('#markdown-root').style.width='\(width)px'; true")
                checks["table." + name + ".nativeHeightMatchesDOM"] = await wait {
                    abs(text.bounds.height - text.contentHeight) < 2 && text.contentHeight > 100
                }
                await pause(100)
                let metrics = try await text.evaluate("""
                    (()=>{const r=document.querySelector('#markdown-root'),rb=r.getBoundingClientRect();
                    const tables=[...r.querySelectorAll('table')],cells=[...r.querySelectorAll('th,td')];
                    const box=e=>{const b=e.getBoundingClientRect();return {x:b.x,y:b.y,width:b.width,height:b.height,right:b.right,bottom:b.bottom};};
                    const rows=[...tables[0].querySelectorAll('tbody tr')];
                    const visible=c=>{const b=c.getBoundingClientRect(),range=document.createRange();range.selectNodeContents(c);
                    return b.width>0 && b.left>=rb.left-1 && b.right<=rb.right+1 &&
                    [...range.getClientRects()].every(q=>q.left>=b.left-1 && q.right<=b.right+1);};
                    const first=rows[0].cells,last=r.lastElementChild.getBoundingClientRect();
                    return {root:box(r),tables:tables.map(box),cells:cells.map(c=>({text:c.textContent,box:box(c)})),
                    fit:tables.length===2 && tables.every(t=>t.getBoundingClientRect().right<=rb.right+1 && t.scrollWidth<=t.clientWidth+1),
                    allCellTextVisible:cells.every(visible),longRowsWrap:rows.every(row=>row.cells[0].getBoundingClientRect().height>40),
                    naturalColumnWidths:first[2].getBoundingClientRect().width<first[0].getBoundingClientRect().width,
                    shortValuesSingleLine:rows.every(row=>[row.cells[1],row.cells[2]].every(c=>{const range=document.createRange();range.selectNodeContents(c);return range.getClientRects().length===1;})),
                    alignment:getComputedStyle(first[0]).textAlign==='left' && getComputedStyle(first[1]).textAlign==='center' && getComputedStyle(first[2]).textAlign==='right',
                    nested:!!r.querySelector('blockquote table'),tail:r.lastElementChild.textContent.includes('TABLE_END') && last.bottom<=rb.bottom+1,
                    height:Math.ceil(rb.height)+1,documentFits:document.documentElement.scrollWidth<=innerWidth+1};})()
                    """) as? [String: Any] ?? [:]
                evidence[name] = metrics
                for key in ["fit", "allCellTextVisible", "longRowsWrap", "naturalColumnWidths", "shortValuesSingleLine", "alignment", "nested", "tail", "documentFits"] {
                    checks["table." + name + "." + key] = metrics[key] as? Bool == true
                }
                if let height = metrics["height"] as? Double {
                    checks["table." + name + ".nativeHeightMatchesDOM"] = abs(text.contentHeight - CGFloat(height)) < 2 && abs(text.bounds.height - text.contentHeight) < 2
                }
                checks["table." + name + ".screenshotSaved"] = await snapshot(text, reportURL: reportURL, name: "markdown-table-" + name + ".png")
            }
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(text)
            let selected = "中文内容包含很长的说明文字和表情 🌍"
            let range = (text.renderedText as NSString).range(of: selected)
            text.setSelectedRange(range)
            checks["table.selectionEstablished"] = await wait { text.selectedText == selected }
            note.model.output += "\n\n流式追加后的尾部 TABLE_STREAM_END"
            checks["table.streamingRevisionRendered"] = await rendered(text, source: note.model.output)
            checks["table.streamingKeepsSelection"] = text.selectedText == selected && text.selectedRange() == range
            checks["table.streamingTailAccessible"] = await waitJS(text, "document.querySelector('#markdown-root').lastElementChild.textContent.includes('TABLE_STREAM_END')")
            _ = try await text.evaluate("document.querySelector('#markdown-root').style.width=window.__tableFixtureWidth; delete window.__tableFixtureWidth; true")
        } catch {
            _ = try? await text.evaluate("document.querySelector('#markdown-root').style.width=window.__tableFixtureWidth; delete window.__tableFixtureWidth; true")
            throw error
        }
        // At physically impossible widths, horizontal access belongs to the wrapper.
        let columns = (1...32).map { "C\($0)" }
        let dense = "| " + columns.joined(separator: " | ") + " |\n| " + columns.map { _ in "---" }.joined(separator: " | ") + " |\n| " + columns.joined(separator: " | ") + " |\n\nDENSE_END"
        note.model.output = dense
        checks["table.denseFixtureRendered"] = await rendered(text, source: dense)
        let denseMetrics = try await text.evaluate("""
            (()=>{const r=document.querySelector('#markdown-root'),t=r.querySelector('table'),w=t.closest('.table-scroll');
            if(!w)return {wrapper:false};const b=w.getBoundingClientRect(),last=t.rows[0].cells[31];
            w.scrollLeft=0;const first=t.rows[0].cells[0].getBoundingClientRect();
            const moved=window.sticky.scrollHorizontal(b.left+10,b.top+10,10000);
            return {wrapper:true,overflow:w.scrollWidth>w.clientWidth+1,wrapperWidth:b.width,rootWidth:r.getBoundingClientRect().width,
            scrollLeft:w.scrollLeft,scrollWidth:w.scrollWidth,seamMoved:moved,
            firstInitiallyVisible:first.left>=b.left-1,lastReachable:last.getBoundingClientRect().right<=b.right+1,
            tail:r.lastElementChild.textContent.includes('DENSE_END'),documentFits:document.documentElement.scrollWidth<=innerWidth+1};})()
            """) as? [String: Any] ?? [:]
        evidence["dense"] = denseMetrics
        for key in ["wrapper", "overflow", "seamMoved", "firstInitiallyVisible", "lastReachable", "tail", "documentFits"] {
            checks["table.dense." + key] = denseMetrics[key] as? Bool == true
        }
        checks["table.dense.screenshotSaved"] = await snapshot(text, reportURL: reportURL, name: "markdown-table-dense.png")
        evidence["scope"] = "Native fixed-width sticky panel; root widths 240px and actual available width exercise content reflow. Dense-table scrolling uses the public JS seam; native event routing remains covered by the code-block wheel fixture."
        return (checks, evidence)
    }
    private static func verifyExtendedSyntax(_ note: StickyWindow, text: StickyTextView, window: NSWindow, reportURL: URL) async throws -> (checks: [String: Bool], observations: [String: Any]) {
        var checks: [String: Bool] = [:], evidence: [String: Any] = [:]
        let following = note.model.autoScroll
        note.model.autoScroll = false
        defer { note.model.autoScroll = following }
        let source = #"""
        # fn1
        ## fnref1

        > [!NOTE]
        > **提示**包含脚注[^note]，再次引用[^note]和内联脚注^[内联脚注内容]。

        外部引用[^note]。

        $$x^2 +
        y^2 = z^2$$

        \[\frac{1}{2} +
        \frac{1}{3}\]

        > $$a +
        > b = c$$

        - \[u +
          v = w\]

        ```math
        \int_0^1 x^2\,dx = \frac{1}{3}
        ```

        | 内容 | 数量 |
        | :--- | ---: |
        | 第一行<br>第二行<br />第三行 | 42 |
        | `<br>` 与 <br title="inert">文字 | 7 |

        """# + "\n\n标准换行第一行  \n标准换行第二行\n\n" + (1...18).map { "段落 \($0)：用于验证脚注跳转和返回对应引用的位置，内容始终保持可读。" }.joined(separator: "\n\n") + "\n\n[^note]: 脚注正文。\n"
        note.model.output = source
        checks["syntax.fixtureRendered"] = await rendered(text, source: source)
        checks["syntax.nativeHeightSettled"] = await wait { abs(text.bounds.height - text.contentHeight) < 2 && text.contentHeight > 500 }
        let metrics = try await text.evaluate("""
            (()=>{const r=document.querySelector('#markdown-root'),ids=[...r.querySelectorAll('[id]')].map(n=>n.id),
            refs=[...r.querySelectorAll('.footnote-ref a')],backs=[...r.querySelectorAll('.footnote-backref')],
            target=a=>document.getElementById(decodeURIComponent(a.hash.slice(1))),rows=r.querySelectorAll('table tbody tr');
            return {mathCount:r.querySelectorAll('.math-display .katex').length,
            nestedMath:!!r.querySelector('blockquote .math-display .katex') && !!r.querySelector('li .math-display .katex'),
            uniqueIDs:ids.length===new Set(ids).size,ids,
            footnotesResolve:refs.length===4 && refs.every(a=>target(a)?.matches('li.footnote-item')),
            backlinksResolve:backs.length===4 && backs.every(a=>target(a)?.matches('.footnote-ref a')),
            alertFormatting:!!r.querySelector('.markdown-alert-note strong') && r.querySelector('.markdown-alert-title')?.textContent==='NOTE',
            tableBreaks:rows[0]?.querySelectorAll('br').length===2 && rows[0].cells[0].getBoundingClientRect().height>50,
            rawHTMLInert:rows[1]?.querySelectorAll('br').length===0 && rows[1]?.textContent.includes('<br title="inert">') && rows[1]?.querySelector('code')?.textContent==='<br>',
            documentFits:document.documentElement.scrollWidth<=innerWidth+1,height:Math.ceil(r.getBoundingClientRect().height)+1};})()
            """) as? [String: Any] ?? [:]
        evidence["layout"] = metrics
        checks["syntax.multilineAndFencedMathRendered"] = metrics["mathCount"] as? Int == 5
        for key in ["nestedMath", "uniqueIDs", "footnotesResolve", "backlinksResolve", "alertFormatting", "tableBreaks", "rawHTMLInert", "documentFits"] {
            checks["syntax." + key] = metrics[key] as? Bool == true
        }
        if let height = metrics["height"] as? Double { checks["syntax.nativeHeightMatchesDOM"] = abs(text.contentHeight - CGFloat(height)) < 2 }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(text)
        let selected = "第一行\n第二行\n第三行"
        let range = (text.renderedText as NSString).range(of: selected)
        text.setSelectedRange(range)
        checks["syntax.tableBreakSelection"] = await wait { text.selectedText == selected }
        note.model.output += "\n\n追加内容 EXTENDED_STREAM_END"
        checks["syntax.streamingRevisionRendered"] = await rendered(text, source: note.model.output)
        checks["syntax.streamingKeepsTableSelection"] = text.selectedText == selected && text.selectedRange() == range
        checks["syntax.screenshotSaved"] = await snapshot(text, reportURL: reportURL, name: "markdown-extended-syntax.png")
        let hardbreak = "标准换行第一行\n标准换行第二行"
        text.setSelectedRange((text.renderedText as NSString).range(of: hardbreak))
        checks["syntax.commonMarkHardbreakSelection"] = await wait { text.selectedText == hardbreak }
        var ancestor = text.superview
        while let parent = ancestor, !(parent is NSScrollView) { ancestor = parent.superview }
        if let scroll = ancestor as? NSScrollView {
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
            _ = try await text.evaluate("document.querySelector('.markdown-alert .footnote-ref a').click(); true")
            checks["syntax.alertFootnoteScrollsNativeViewport"] = await wait { scroll.documentVisibleRect.minY > 100 }
            let footnoteOffset = scroll.documentVisibleRect.minY
            _ = try await text.evaluate("document.querySelector('#fn1 .footnote-backref').click(); true")
            checks["syntax.alertBacklinkReturnsToReference"] = await wait { scroll.documentVisibleRect.minY < footnoteOffset - 100 }
            evidence["nativeAnchorOffsets"] = ["footnote": footnoteOffset, "reference": scroll.documentVisibleRect.minY]
        } else { checks["syntax.alertFootnoteScrollsNativeViewport"] = false }
        return (checks, evidence)
    }

    private static func verifyMermaidRegressions(_ note: StickyWindow, text: StickyTextView) async throws -> (checks: [String: Bool], observations: [String: Any]) {
        let cases: [(name: String, source: String, labels: [String], math: Bool)] = [
            ("sequence", """
            sequenceDiagram
              participant A as Alice
              participant B as Bob
              A->>B: $$E=mc^2$$
              B-->>A: Plain message preserved
            """, ["Alice", "Bob", "Plain message preserved"], true),
            ("class", """
            classDiagram
              class Animal {
                +String name
                +eat()
              }
              class Duck
              Animal <|-- Duck
            """, ["Animal", "Duck", "name", "eat"], false),
            ("classFormula", """
            classDiagram
              class Energy["$$E=mc^2$$"]
              class Plain
              Energy --> Plain : uses
            """, ["Plain", "uses"], true),
            ("state", """
            stateDiagram-v2
              [*] --> Idle
              Idle --> Done: process
              Done --> [*]
            """, ["Idle", "Done", "process"], false)
        ]
        var checks: [String: Bool] = [:]
        var evidence: [String: Any] = [:]
        for item in cases {
            let source = "```mermaid\n" + item.source + "\n```"
            note.model.output = source
            checks["mermaid." + item.name + ".revisionRendered"] = await rendered(text, source: source)
            checks["mermaid." + item.name + ".diagramLayoutSettled"] = await stableDiagramLayout(text)
            guard let metrics = try await text.evaluate("""
                (() => { const r=document.querySelector('#markdown-root'),svg=r.querySelector('.diagram-rendered svg');
                if(!svg)return {svgAvailable:false,source:r.textContent};
                const box=n=>{const b=n.getBoundingClientRect();return {width:b.width,height:b.height};};
                const math=[...svg.querySelectorAll('.katex')].map(box);
                return {svgAvailable:true,labels:svg.textContent,foreignObjects:svg.querySelectorAll('foreignObject').length,
                mathBoxes:math,mathVisible:math.some(b=>b.width>0 && b.height>0),
                inert:!svg.querySelector('script,iframe,object,embed,image,img') &&
                ![...svg.querySelectorAll('*')].some(e=>[...e.attributes].some(a=>/^on/i.test(a.name)||((a.name==='href'||a.name==='xlink:href')&&!a.value.startsWith('#')))),
                svgBox:box(svg),svgHTML:svg.outerHTML}; })()
                """) as? [String: Any] else {
                checks["mermaid." + item.name + ".inspectionAvailable"] = false
                continue
            }
            evidence[item.name] = metrics
            let labels = metrics["labels"] as? String ?? ""
            checks["mermaid." + item.name + ".labelsPreserved"] = item.labels.allSatisfy { labels.contains($0) }
            checks["mermaid." + item.name + ".activeContentAbsent"] = metrics["inert"] as? Bool == true
            if item.math {
                checks["mermaid." + item.name + ".formulaForeignObjectVisible"] = (metrics["foreignObjects"] as? Int ?? 0) > 0 && metrics["mathVisible"] as? Bool == true
            }
        }
        return (checks, evidence)
    }
    private static func stableDiagramLayout(_ text: StickyTextView) async -> Bool {
        var priorRevision = -1
        var priorHeight: CGFloat = -1
        var samples = 0
        for _ in 0..<250 {
            let revision = text.revision
            if let result = try? await text.evaluate("""
                (()=>{const r=document.querySelector('#markdown-root');const svg=r?.querySelector('.diagram-rendered svg');
                return {ready:document.fonts.status==='loaded' && !!svg && svg.id.startsWith('sticky-diagram-\(revision)-') &&
                svg.getBoundingClientRect().width>0 && svg.getBoundingClientRect().height>0 &&
                svg.getBoundingClientRect().bottom<=r.getBoundingClientRect().bottom+1,
                height:r?Math.ceil(r.getBoundingClientRect().height)+1:0};})()
                """) as? [String: Any], result["ready"] as? Bool == true,
               let height = result["height"] as? Double,
               text.renderingComplete, text.renderedRevision == revision,
               abs(CGFloat(height) - text.contentHeight) < 2, abs(text.bounds.height - text.contentHeight) < 2 {
                if priorRevision == revision && abs(priorHeight - text.contentHeight) < 0.5 { samples += 1 }
                else { samples = 1 }
                priorRevision = revision; priorHeight = text.contentHeight
                if samples >= 2 { return true }
            } else { samples = 0 }
            await pause(30)
        }
        return false
    }
    private static func verifyWheelBehavior(_ text: StickyTextView, window: NSWindow, scroll: NSScrollView) async throws -> (checks: [String: Bool], observations: [String: Any]) {
        var checks: [String: Bool] = [:]
        var evidence: [String: Any] = [:]
        let initialOffset = scroll.documentVisibleRect.minY
        let initialWidth = window.frame.width
        let tableGeometry = try await text.evaluate("""
            (()=>{const t=document.querySelector('#markdown-root table'),r=t.getBoundingClientRect();
            const cells=[...t.querySelectorAll('th,td')];
            return {fits:cells.every(c=>c.getBoundingClientRect().right<=r.right+1) && t.scrollWidth<=t.clientWidth+1,
            wraps:cells.some(c=>c.getBoundingClientRect().height>50),width:t.clientWidth,scrollWidth:t.scrollWidth};})()
            """) as? [String: Any] ?? [:]
        checks["table.matrixFitsAndWraps"] = tableGeometry["fits"] as? Bool == true && tableGeometry["wraps"] as? Bool == true
        evidence["table"] = tableGeometry
        for (name, selector) in [("code", "pre:has(code.language-swift)")] {
            guard let geometry = try await text.evaluate("""
                (() => { const e=document.querySelector('#markdown-root \(selector)');
                if(!e)return null; e.scrollLeft=0;const r=e.getBoundingClientRect();
                return {x:r.left+Math.min(30,r.width/2),y:r.top+Math.min(15,r.height/2),
                width:e.clientWidth,scrollWidth:e.scrollWidth,left:e.scrollLeft}; })()
                """) as? [String: Any], let x = geometry["x"] as? Double, let y = geometry["y"] as? Double,
                  let width = geometry["width"] as? Double, let scrollWidth = geometry["scrollWidth"] as? Double,
                  let document = scroll.documentView else {
                checks["wheel." + name + ".nativeTargetAvailable"] = false
                continue
            }
            checks["wheel." + name + ".contentActuallyOverflowsHorizontally"] = scrollWidth > width + 1
            let nativePoint = NSPoint(x: x, y: text.isFlipped ? y : Double(text.bounds.height) - y)
            let documentPoint = document.convert(nativePoint, from: text)
            let maximum = max(0, document.bounds.height - scroll.contentView.bounds.height)
            let offset = max(0, min(maximum, documentPoint.y - 25))
            scroll.contentView.scroll(to: NSPoint(x: 0, y: offset))
            scroll.reflectScrolledClipView(scroll.contentView)
            await pause(100)
            let windowPoint = text.convert(nativePoint, to: nil)
            let beforeOffset = scroll.documentVisibleRect.minY
            let forward = wheelEvent(window: window, point: windowPoint, horizontal: -80, vertical: 0)
            let nativeAssociation = forward?.window === window
            let nativeCoordinatesMatch = forward.map { abs($0.locationInWindow.x - windowPoint.x) < 1 && abs($0.locationInWindow.y - windowPoint.y) < 1 } ?? false
            let useMonitor = nativeAssociation && nativeCoordinatesMatch
            var details: [String: Any] = ["geometry": geometry, "nativePoint": NSStringFromPoint(nativePoint),
                "windowPoint": NSStringFromPoint(windowPoint), "targetVisible": text.visibleRect.contains(nativePoint),
                "nativeEventWindowMatches": nativeAssociation, "nativeEventCoordinatesMatch": nativeCoordinatesMatch,
                "horizontalBoundary": useMonitor ? "Isolated NSEvent fixture with real CG wheel payload -> NSApp.sendEvent -> local NSEvent monitor -> WKWebView" : "window.sticky.scrollHorizontal public JS seam; native event association unavailable",
                "event": forward.map(eventDetails) ?? [:], "outerOffsetBefore": beforeOffset]
            checks["wheel." + name + ".targetInsideNativeViewport"] = text.visibleRect.contains(nativePoint)
            if useMonitor, let forward { NSApp.sendEvent(forward) }
            else { _ = try await text.evaluate("window.sticky.scrollHorizontal(\(x),\(y),80)") }
            checks["wheel." + name + ".scrollsRight"] = await waitJS(text, "document.querySelector('#markdown-root \(selector)').scrollLeft > 20")
            details["rightScrollLeft"] = try await text.evaluate("document.querySelector('#markdown-root \(selector)').scrollLeft")
            checks["wheel." + name + ".horizontalKeepsNativeOffsetAndWidth"] = abs(scroll.documentVisibleRect.minY - beforeOffset) < 1 && abs(window.frame.width - initialWidth) < 1
            let reverse = wheelEvent(window: window, point: windowPoint, horizontal: 80, vertical: 0)
            if useMonitor, let reverse, reverse.window === window { NSApp.sendEvent(reverse) }
            else { _ = try await text.evaluate("window.sticky.scrollHorizontal(\(x),\(y),-80)") }
            checks["wheel." + name + ".scrollsBackLeft"] = await waitJS(text, "Math.abs(document.querySelector('#markdown-root \(selector)').scrollLeft) < 1")
            details["leftScrollLeft"] = try await text.evaluate("document.querySelector('#markdown-root \(selector)').scrollLeft")
            details["outerOffsetAfterHorizontal"] = scroll.documentVisibleRect.minY
            if let vertical = wheelEvent(window: window, point: windowPoint, horizontal: 0, vertical: -70) {
                let throughMonitor = vertical.window === window && abs(vertical.locationInWindow.x - windowPoint.x) < 1 && abs(vertical.locationInWindow.y - windowPoint.y) < 1
                details["verticalEvent"] = eventDetails(vertical)
                details["verticalBoundary"] = throughMonitor ? "Isolated NSEvent fixture with real CG wheel payload -> NSApp.sendEvent -> local NSEvent monitor -> native NSScrollView" : "NSScrollView.scrollWheel(with:) public native endpoint; native event association unavailable"
                if throughMonitor { NSApp.sendEvent(vertical) }
                else { scroll.scrollWheel(with: vertical) }
                checks["wheel." + name + ".verticalMovesOuterViewport"] = await wait { scroll.documentVisibleRect.minY > beforeOffset + 10 }
                checks["wheel." + name + ".verticalKeepsWindowWidth"] = abs(window.frame.width - initialWidth) < 1
                details["outerOffsetAfterVertical"] = scroll.documentVisibleRect.minY
            } else { checks["wheel." + name + ".verticalMovesOuterViewport"] = false }
            evidence[name] = details
        }
        if let content = window.contentView {
            let headerLocal = NSPoint(x: content.bounds.midX, y: content.isFlipped ? 15 : content.bounds.height - 15)
            let headerPoint = content.convert(headerLocal, to: nil)
            let headerTextPoint = text.convert(headerPoint, from: nil)
            let headerOffset = scroll.documentVisibleRect.minY
            if let header = wheelEvent(window: window, point: headerPoint, horizontal: 0, vertical: -70), header.window === window {
                checks["wheel.headerIsOutsideOutputViewport"] = !text.visibleRect.contains(headerTextPoint)
                NSApp.sendEvent(header)
                await pause(100)
                checks["wheel.headerInputDoesNotScrollOutput"] = abs(scroll.documentVisibleRect.minY - headerOffset) < 1
                evidence["header"] = ["windowPoint": NSStringFromPoint(headerPoint), "textPoint": NSStringFromPoint(headerTextPoint),
                    "textVisibleRect": NSStringFromRect(text.visibleRect), "event": eventDetails(header),
                    "offsetBefore": headerOffset, "offsetAfter": scroll.documentVisibleRect.minY,
                    "boundary": "Isolated NSEvent fixture -> NSApp.sendEvent -> actual local monitor visibleRect guard"]
            }
        }
        scroll.contentView.scroll(to: NSPoint(x: 0, y: initialOffset))
        scroll.reflectScrolledClipView(scroll.contentView)
        await pause(80)
        evidence["scope"] = "Fixtures only dispatch into this application's owned test window. No CGEvent system posting. When public NSEvent construction cannot attach a window, horizontal and vertical endpoint checks explicitly exclude the native monitor boundary."
        return (checks, evidence)
    }
    private static func wheelEvent(window: NSWindow, point: NSPoint, horizontal: Int32, vertical: Int32) -> NSEvent? {
        guard let source = CGEventSource(stateID: .privateState),
              let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                                  wheel1: vertical, wheel2: horizontal, wheel3: 0) else { return nil }
        let screen = window.convertPoint(toScreen: point)
        event.location = CGPoint(x: screen.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - screen.y)
        event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.windowNumber))
        event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window.windowNumber))
        guard let base = NSEvent(cgEvent: event) else { return nil }
        let fixture = FixtureWheelEvent()
        fixture.base = base; fixture.targetWindow = window; fixture.targetPoint = point
        fixture.targetWindowNumber = window.windowNumber
        return fixture
    }
    /// NSEvent(cgEvent:) has no public window assignment. These public getters
    /// associate an actual wheel payload with only the owned verification window.
    /// sendEvent preserves this fixture; postEvent reconstructs it and loses those
    /// coordinates. A standalone probe verified actual local-monitor delivery.
    private final class FixtureWheelEvent: NSEvent {
        var base: NSEvent?
        weak var targetWindow: NSWindow?
        // NSEvent getters are nonisolated; snapshot the NSWindow property on MainActor.
        var targetWindowNumber = 0
        var targetPoint = NSPoint.zero
        override var type: NSEvent.EventType { base?.type ?? .scrollWheel }
        override var window: NSWindow? { targetWindow }
        override var windowNumber: Int { targetWindowNumber }
        override var locationInWindow: NSPoint { targetPoint }
        override var scrollingDeltaX: CGFloat { base?.scrollingDeltaX ?? 0 }
        override var scrollingDeltaY: CGFloat { base?.scrollingDeltaY ?? 0 }
        override var deltaX: CGFloat { base?.deltaX ?? 0 }
        override var deltaY: CGFloat { base?.deltaY ?? 0 }
        override var deltaZ: CGFloat { base?.deltaZ ?? 0 }
        override var hasPreciseScrollingDeltas: Bool { base?.hasPreciseScrollingDeltas ?? false }
        override var isDirectionInvertedFromDevice: Bool { base?.isDirectionInvertedFromDevice ?? false }
        override var phase: NSEvent.Phase { base?.phase ?? [] }
        override var momentumPhase: NSEvent.Phase { base?.momentumPhase ?? [] }
        override var modifierFlags: NSEvent.ModifierFlags { base?.modifierFlags ?? [] }
        override var timestamp: TimeInterval { base?.timestamp ?? 0 }
        override var cgEvent: CGEvent? { base?.cgEvent }
    }
    private static func eventDetails(_ event: NSEvent) -> [String: Any] {
        ["windowNumber": event.windowNumber, "point": NSStringFromPoint(event.locationInWindow),
         "scrollingDeltaX": event.scrollingDeltaX, "scrollingDeltaY": event.scrollingDeltaY,
         "deltaX": event.deltaX, "deltaY": event.deltaY, "precise": event.hasPreciseScrollingDeltas]
    }
    private static func stableMatrixLayout(_ text: StickyTextView) async -> Bool {
        var priorHeight: CGFloat = -1
        var priorRevision = -1
        var stableSamples = 0
        for _ in 0..<250 {
            let revision = text.revision
            if let values = try? await text.evaluate("""
                (() => { const r=document.querySelector('#markdown-root');
                const svg=r?.querySelector('.diagram-rendered svg');
                return {ready: document.fonts.status === 'loaded' && !!svg &&
                svg.id.startsWith('sticky-diagram-\(revision)-') &&
                svg.getBoundingClientRect().height > 0 &&
                svg.getBoundingClientRect().bottom <= r.getBoundingClientRect().bottom + 1 &&
                r.querySelectorAll('.katex').length === 4,
                height: r ? Math.ceil(r.getBoundingClientRect().height)+1 : 0}; })()
                """) as? [String: Any], values["ready"] as? Bool == true,
               let domHeight = values["height"] as? Double,
               text.renderingComplete, text.renderedRevision == revision,
               abs(text.contentHeight - CGFloat(domHeight)) < 2,
               abs(text.bounds.height - text.contentHeight) < 2 {
                if priorRevision == revision && abs(priorHeight - text.contentHeight) < 0.5 { stableSamples += 1 }
                else { stableSamples = 1 }
                priorRevision = revision; priorHeight = text.contentHeight
                if stableSamples >= 2 { return true }
            } else { stableSamples = 0 }
            await pause(30)
        }
        return false
    }
    private static func diagnostics(_ text: StickyTextView) async -> [String: Any] {
        var result: [String: Any] = ["ready": text.ready, "url": text.url?.absoluteString ?? "",
            "renderedSource": text.renderedSource, "revision": text.revision,
            "renderedRevision": text.renderedRevision, "renderingComplete": text.renderingComplete,
            "resourceLocation": text.resourceLocation, "rendererErrors": text.rendererErrors]
        do {
            result["document"] = try await text.evaluate("({html:document.documentElement.outerHTML,stickyType:typeof window.sticky,scripts:[...document.scripts].map(x=>x.src)})")
        } catch { result["documentEvaluationError"] = error.localizedDescription }
        return result
    }
    private static func rendered(_ text: StickyTextView, source: String) async -> Bool {
        await wait { text.ready && text.renderingComplete && text.renderedSource == source && text.renderedRevision == text.revision }
    }
    private static func wait(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<250 { if condition() { return true }; await pause(20) }
        return condition()
    }
    private static func waitJS(_ text: StickyTextView, _ script: String) async -> Bool {
        for _ in 0..<150 { if (try? await text.evaluate(script)) as? Bool == true { return true }; await pause(20) }
        return false
    }
    private static func pause(_ milliseconds: Int) async { try? await Task.sleep(for: .milliseconds(milliseconds)) }
    private static func findText(in root: NSView) -> StickyTextView? {
        if let text = root as? StickyTextView { return text }
        return root.subviews.lazy.compactMap { findText(in: $0) }.first
    }
    private static func accessible(in root: Any, identifier: String) -> NSObject? {
        guard let object = root as? NSObject else { return nil }
        let id = NSSelectorFromString("accessibilityIdentifier")
        if object.responds(to: id), object.perform(id)?.takeUnretainedValue() as? String == identifier { return object }
        let children = NSSelectorFromString("accessibilityChildren")
        guard object.responds(to: children), let nodes = object.perform(children)?.takeUnretainedValue() as? [Any] else { return nil }
        return nodes.lazy.compactMap { accessible(in: $0, identifier: identifier) }.first
    }
    private static func press(_ object: NSObject) -> Bool {
        let selector = NSSelectorFromString("accessibilityPerformPress")
        guard object.responds(to: selector) else { return false }
        typealias Action = @convention(c) (AnyObject, Selector) -> ObjCBool
        return unsafeBitCast(object.method(for: selector), to: Action.self)(object, selector).boolValue
    }
    private static func snapshot(_ text: StickyTextView, reportURL: URL, name: String) async -> Bool {
        do {
            let image: NSImage = try await withCheckedThrowingContinuation { continuation in
                text.takeSnapshot(with: nil) { image, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let image { continuation.resume(returning: image) }
                    else { continuation.resume(throwing: NSError(domain: "MarkdownSnapshot", code: 1)) }
                }
            }
            guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let data = bitmap.representation(using: .png, properties: [:]) else { return false }
            try FileManager.default.createDirectory(at: reportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: reportURL.deletingLastPathComponent().appendingPathComponent(name), options: .atomic)
            return true
        } catch { return false }
    }
    private static func nativeSnapshot(_ window: NSWindow, reportURL: URL, name: String) -> Bool {
        guard let view = window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return false }
        do { try data.write(to: reportURL.deletingLastPathComponent().appendingPathComponent(name), options: .atomic); return true } catch { return false }
    }
    private static func finish(_ checks: [String: Bool], observations: [String: Any], reportURL: URL) {
        let report: [String: Any] = ["passed": !checks.isEmpty && checks.values.allSatisfy { $0 }, "checks": checks,
            "observations": observations, "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
            "scope": "Packaged offline WKWebView in native sticky panel; CommonMark/GFM, KaTeX, Mermaid, native selection and copy, appearance and revisions; no model service, credentials, global hotkeys or settings writes."]
        do { try FileManager.default.createDirectory(at: reportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: reportURL, options: .atomic)
        } catch { fputs("Markdown verification report: \(error.localizedDescription)\n", stderr) }
        if !CommandLine.arguments.contains("--sticky-markdown-preview") { NSApp.terminate(nil) }
    }

    private static let matrix = #"""
    # Markdown 渲染矩阵 🌍
    ## 二级标题
    ### 三级标题
    #### 四级标题
    ##### 五级标题
    ###### 六级标题

    Setext title
    -----------

    **粗体**、*斜体*、~~删除线~~、`inlineCode` 和转义 \*literal\*。

    > 引用段落
    >
    > - 引用内列表

    > [!NOTE]
    > 提示内容：模型输出中的重点说明。

    - 无序列表
      - 嵌套列表
    1. 有序列表
    2. 第二项

    - [x] 已完成
    - [ ] 未完成

    ---

    [引用链接][guide] 和 <https://example.com/auto>，脚注引用[^note]。

    [guide]: https://example.com/reference

    | 左对齐 | 右对齐 |
    | :--- | ---: |
    | 中文 🌍 | 42 |
    | VeryLongUnbrokenTableCellabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz | 99 |

    ```swift
    let greeting = "你好 🌍"
    let longLine = "abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz"
    ```

    ![Embedded pixel](data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aP9sAAAAASUVORK5CYII=)

    行内公式 $E=mc^2$ 和 \(y_1\)。

    $$
    \int_0^1 x^2\,dx=\frac{1}{3}
    $$

    \[
    a^2+b^2=c^2
    \]

    [^note]: 脚注中的 **说明**。

    ```mermaid
    flowchart TD
      A[输入] --> B{处理}
      B --> C[输出]
    ```
    """#
}
