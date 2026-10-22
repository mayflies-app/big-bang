import AppKit
import SwiftUI
import BigBangCore
import BigBangNetworking

@MainActor final class StickyModel: ObservableObject {
    @Published private(set) var preset: Preset
    @Published private(set) var availablePresets: [Preset] = []
    @Published private(set) var source: String
    @Published var draft = ""
    @Published private(set) var awaitingInput: Bool
    @Published private(set) var capturingSelection: Bool
    var canSubmit: Bool { !capturingSelection && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    @Published var output = ""
    @Published var state = "准备连接…"
    @Published var running = false
    @Published var error: String?
    @Published var pinned = true
    @Published var autoScroll = true
    @Published var contentOverflows = false
    @Published var language = L10n.currentLanguage
    var displayedState: String { L10n.string(capturingSelection ? "读取选区…" : state, language: language) }
    var displayedError: String? { error.map { RuntimeTranslations.message($0, language: language) } }
    var displayedPresetName: String {
        guard let builtIn = preset.builtIn else { return preset.name }
        let defaults = Preset.defaults(for: .simplifiedChinese) + Preset.defaults(for: .english)
        guard defaults.contains(where: { $0.builtIn == builtIn && $0.name == preset.name }) else { return preset.name }
        return Preset.defaults(for: language).first(where: { $0.builtIn == builtIn })?.name ?? preset.name
    }
    let service = ModelStream()
    var submit: (() -> Void)?
    var editInput: (() -> Void)?
    var retry: (() -> Void)?
    var selectPreset: ((UUID) -> Void)?
    var close: (() -> Void)?
    var pin: ((Bool) -> Void)?
    var contentHeightChanged: ((CGFloat) -> Void)?
    init(preset: Preset, source: String, capturingSelection: Bool = false) {
        self.preset = preset; self.source = source
        self.capturingSelection = capturingSelection
        awaitingInput = !capturingSelection && source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    func finishCapture(needsInput: Bool = false) {
        awaitingInput = needsInput
        capturingSelection = false
    }
    func beginManualInput() { awaitingInput = true }
    func acceptInput(_ text: String) { source = text; awaitingInput = false }
    func updatePresets(_ presets: [Preset]) {
        availablePresets = presets
        if let current = presets.first(where: { $0.id == preset.id }) { preset = current }
    }
    func usePreset(_ preset: Preset) { self.preset = preset }
    func start(configuration: Configuration, key: String) {
        // Invalidate the old stream even when validating the new request fails.
        service.cancel()
        language = configuration.language
        autoScroll = true
        contentOverflows = false
        output = ""; error = nil; state = "连接中…"; running = true
        do {
            try service.start(.init(text: source, instructions: preset.prompt, configuration: configuration, apiKey: key)) { [weak self] event in
                guard let self, self.running else { return }
                switch event {
                case .delta(let text): self.output += text; self.state = "正在生成"
                case .completed: self.running = false; self.state = "已完成"
                case .failed(let message): self.running = false; self.state = "请求失败"; self.error = message
                }
            }
        } catch { running = false; state = "请求失败"; self.error = error.localizedDescription }
    }
    func stop() { service.cancel(); running = false; state = "已停止" }
}

struct StickyView: View {
    static let headerHeight: CGFloat = 44
    @ObservedObject var model: StickyModel
    @ObservedObject private var clipboardAccess = ClipboardAccessGate.shared
    @Environment(\.colorScheme) private var colorScheme
    @State private var copied = false
    @State private var copyFeedback: Task<Void, Never>?
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 3) {
                StickyPresetPicker(model: model)
                    .frame(height: 32)
                if model.running {
                    ProgressView().controlSize(.mini).frame(width: 14, height: 14).padding(.leading, 5)
                        .accessibilityLabel(model.displayedState)
                }
                Spacer(minLength: 4)
                icon(copied ? "checkmark" : "doc.on.doc", help: copied ? "已复制" : "复制") {
                    guard !clipboardAccess.isBusy else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.output, forType: .string)
                    copied = true
                    copyFeedback?.cancel()
                    copyFeedback = Task { @MainActor in
                        do { try await Task.sleep(for: .milliseconds(1500)) } catch { return }
                        copied = false
                    }
                }.disabled(model.output.isEmpty || clipboardAccess.isBusy)
                if !model.awaitingInput && !model.capturingSelection {
                    icon("arrow.uturn.backward", help: "回退并编辑") { model.editInput?() }.disabled(model.editInput == nil)
                    if model.running {
                        icon("stop.fill", help: "停止") { model.stop() }
                    } else {
                        icon("arrow.clockwise", help: "重试") { model.retry?() }.disabled(model.retry == nil)
                    }
                }
                icon(model.pinned ? "pin.fill" : "pin", help: model.pinned ? "取消置顶" : "保持在最前", selected: model.pinned) {
                    model.pinned.toggle(); model.pin?(model.pinned)
                }
                icon("xmark", help: "关闭（Esc）") { model.close?() }
            }.padding(.leading, 18).padding(.trailing, 10).frame(height: Self.headerHeight)
            Rectangle().fill(Color(nsColor: colorScheme == .dark ? .white : .black).opacity(colorScheme == .dark ? 0.16 : 0.13))
                .frame(height: 1).padding(.horizontal, 18)
                .accessibilityHidden(true).allowsHitTesting(false)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if model.awaitingInput {
                            StickyInputView(model: model)
                        } else if model.output.isEmpty && model.error == nil {
                            Text(model.displayedState).font(.system(size: 13)).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else if !model.output.isEmpty {
                            StickyMarkdownView(text: model.output, dark: colorScheme == .dark, language: model.language,
                                               onSelection: { model.autoScroll = false }, close: { model.close?() },
                                               toggleFollowing: { model.autoScroll.toggle() }, following: model.autoScroll)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if let error = model.displayedError {
                            Label(error, systemImage: "exclamationmark.circle")
                                .font(.system(size: 12)).lineSpacing(3).foregroundStyle(Color(nsColor: .systemRed))
                                .textSelection(.enabled)
                                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                                .background(.red.opacity(0.06), in: RoundedRectangle(cornerRadius: MacAppDesignTokens.controlRadius))
                        }
                        Color.clear.frame(height: 1).id("end")
                    }.padding(.horizontal, 18).padding(.bottom, 18).padding(.top, 12)
                        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { model.contentHeightChanged?($0) }
                }
                // Until the panel reaches its height limit, a layout pass can briefly
                // put new text beyond the old viewport. Keep that pass from inserting
                // a scroller gutter or moving the text before the panel catches up.
                .scrollIndicators(model.contentOverflows ? .automatic : .never)
                .scrollDisabled(!model.contentOverflows)
                .modifier(OutputFollowing(follow: $model.autoScroll, canScroll: model.contentOverflows) {
                    proxy.scrollTo("end", anchor: .bottom)
                })
                .contextMenu { Toggle(L10n.string("跟随输出", language: model.language), isOn: $model.autoScroll) }
                .onChange(of: model.running) { _, running in if running { model.autoScroll = true } }
                .onChange(of: model.output) { _, _ in
                    if model.autoScroll && model.contentOverflows { proxy.scrollTo("end", anchor: .bottom) }
                }
                .overlay(alignment: .bottom) {
                    if model.contentOverflows && !model.autoScroll && !model.awaitingInput && !model.output.isEmpty {
                        Button {
                            model.autoScroll = true
                            proxy.scrollTo("end", anchor: .bottom)
                        } label: {
                            Label(L10n.string("回到最新内容", language: model.language), systemImage: "arrow.down")
                                .font(.system(size: 12, weight: .medium))
                                .padding(.horizontal, 4).padding(.vertical, 2)
                        }
                        .buttonStyle(.bordered).controlSize(.small)
                        .background(.regularMaterial, in: Capsule())
                        .clipShape(Capsule())
                        .help(L10n.string("跟随输出", language: model.language))
                        .accessibilityIdentifier("sticky.follow-latest")
                        .padding(.bottom, 12)
                    }
                }
            }
        }.foregroundStyle(.primary)
            .onChange(of: model.running) { _, running in
                if running { copyFeedback?.cancel(); copied = false }
            }
            .onChange(of: model.preset.id) { _, _ in copyFeedback?.cancel(); copied = false }
            .onChange(of: model.awaitingInput) { _, editing in
                if editing { copyFeedback?.cancel(); copied = false }
            }
            .onDisappear { copyFeedback?.cancel() }
    }
    private func icon(_ name: String, help: String, selected: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.system(size: 12, weight: .medium))
                .frame(width: 14, height: 14)
                .frame(width: MacAppDesignTokens.symbolButtonExtent, height: MacAppDesignTokens.symbolButtonExtent).contentShape(RoundedRectangle(cornerRadius: MacAppDesignTokens.controlRadius))
        }.buttonStyle(StickyActionStyle(selected: selected))
            .help(L10n.string(help, language: model.language))
            .accessibilityLabel(L10n.string(help, language: model.language))
            .accessibilityIdentifier("sticky." + (name.hasPrefix("pin") ? "pin" :
                (name == "checkmark" || name == "doc.on.doc" ? "copy" : name)))
    }
}

/// Keep the editable surface and its footer in the note's existing content column.
private struct StickyInputView: View {
    @ObservedObject var model: StickyModel
    @ObservedObject private var clipboardAccess = ClipboardAccessGate.shared
    @Environment(\.colorScheme) private var colorScheme
    @State private var inputFocused = true
    private var palette: SettingsPalette { .init(dark: colorScheme == .dark) }
    private var editorFocus: Binding<Bool> {
        Binding(get: { inputFocused }, set: { inputFocused = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.string("输入或粘贴文本", language: model.language))
                .font(.system(size: 12)).foregroundStyle(palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SettingsTextEditor(text: $model.draft, focused: editorFocus, palette: palette,
                               label: L10n.string("输入或粘贴文本", language: model.language),
                               identifier: "sticky.input", onSubmit: { model.submit?() })
                .frame(height: 148).padding(.horizontal, 11).padding(.vertical, 12)
                .background(palette.field.opacity(colorScheme == .dark ? 0.5 : 0.75),
                            in: RoundedRectangle(cornerRadius: MacAppDesignTokens.controlRadius))
                .overlay(RoundedRectangle(cornerRadius: MacAppDesignTokens.controlRadius)
                    .strokeBorder(editorFocus.wrappedValue ? palette.accent.opacity(0.85) : palette.border,
                                  lineWidth: editorFocus.wrappedValue ? 1.5 : 1)
                    .allowsHitTesting(false))
            HStack(spacing: 12) {
                if clipboardAccess.isBusy {
                    Text(L10n.string("剪贴板恢复中…", language: model.language))
                        .font(.system(size: 11)).foregroundStyle(palette.secondary)
                }
                Spacer(minLength: 0)
                Button { model.submit?() } label: {
                    HStack(spacing: 8) {
                        Text(L10n.string("提交", language: model.language))
                        Text("⌘↩").foregroundStyle(palette.secondary)
                    }.font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.bordered).controlSize(.large).tint(palette.accent)
                .disabled(!model.canSubmit)
                .help(L10n.string("按 ⌘Enter 提交", language: model.language))
                .accessibilityLabel(L10n.string("提交", language: model.language))
                .accessibilityHint(L10n.string("按 ⌘Enter 提交", language: model.language))
                .accessibilityIdentifier("sticky.submit")
            }
        }.foregroundStyle(palette.text)
    }
}

/// A native popup retains menu tracking, keyboard navigation, and VoiceOver behavior.
private struct StickyPresetPicker: NSViewRepresentable {
    @ObservedObject var model: StickyModel
    func makeCoordinator() -> Coordinator { Coordinator(model: model) }
    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.isBordered = false
        button.font = .systemFont(ofSize: 12, weight: .semibold)
        button.alignment = .left
        button.lineBreakMode = .byTruncatingTail
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.setAccessibilityIdentifier("sticky.preset")
        button.target = context.coordinator
        button.action = #selector(Coordinator.choose(_:))
        return button
    }
    func updateNSView(_ button: NSPopUpButton, context: Context) {
        // Keep a deleted current preset visible until the user chooses another one.
        let missing = !model.availablePresets.contains { $0.id == model.preset.id }
        let presets = missing ? [model.preset] + model.availablePresets : model.availablePresets
        let names = presets.map { $0.id == model.preset.id ? model.displayedPresetName : $0.name }
        if button.itemArray.map({ $0.representedObject as? UUID }) != presets.map({ Optional($0.id) }) ||
            button.itemTitles != names {
            button.removeAllItems()
            for (preset, name) in zip(presets, names) {
                let item = NSMenuItem(title: name, action: nil, keyEquivalent: "")
                item.representedObject = preset.id
                button.menu?.addItem(item)
            }
        }
        button.menu?.autoenablesItems = false
        for item in button.itemArray {
            item.isEnabled = !(missing && item.representedObject as? UUID == model.preset.id)
        }
        button.selectItem(at: presets.firstIndex { $0.id == model.preset.id } ?? 0)
        button.isEnabled = model.selectPreset != nil && !model.availablePresets.isEmpty
        let label = L10n.string("切换预设", language: model.language)
        button.setAccessibilityLabel(label)
        button.toolTip = L10n.string(model.awaitingInput || model.capturingSelection ? "选择用于处理输入文本的预设" : "使用其他预设重新处理原始输入", language: model.language)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSPopUpButton, context: Context) -> CGSize? {
        // With left-aligned text, the extra width separates the title from the native arrow.
        let naturalWidth = nsView.intrinsicContentSize.width + 6
        return CGSize(width: min(naturalWidth, proposal.width ?? naturalWidth), height: 32)
    }
    @MainActor final class Coordinator: NSObject {
        let model: StickyModel
        init(model: StickyModel) { self.model = model }
        @objc func choose(_ sender: NSPopUpButton) {
            guard let id = sender.selectedItem?.representedObject as? UUID else { return }
            model.selectPreset?(id)
            // A failed credential read leaves the current preset and output in place.
            sender.selectItem(at: sender.itemArray.firstIndex { $0.representedObject as? UUID == model.preset.id } ?? 0)
        }
    }
}

private struct StickyActionStyle: ButtonStyle {
    var selected: Bool
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false
    func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        configuration.label
            .foregroundStyle(Color(nsColor: .labelColor).opacity(enabled ? (selected || hovering ? 0.9 : 0.58) : 0.22))
            .background(.primary.opacity(configuration.isPressed ? 0.13 : (hovering && enabled ? 0.07 : (selected ? 0.04 : 0))),
                        in: RoundedRectangle(cornerRadius: MacAppDesignTokens.controlRadius))
            .onHover { hovering = $0 }
    }
}

private struct OutputFollowing: ViewModifier {
    @Binding var follow: Bool
    let canScroll: Bool
    let scrollToEnd: () -> Void
    private struct Position: Equatable {
        let offset: CGFloat
        let height: CGFloat
        let viewportHeight: CGFloat
        let visibleBottom: CGFloat
    }

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content
                .onScrollGeometryChange(for: Position.self, of: {
                    Position(offset: $0.contentOffset.y, height: $0.contentSize.height,
                             viewportHeight: $0.visibleRect.height, visibleBottom: $0.visibleRect.maxY)
                }) { old, new in
                    guard canScroll else { return }
                    if old.height != new.height || old.viewportHeight != new.viewportHeight {
                        // Growing output must not be mistaken for scrolling away from the bottom.
                        if follow { scrollToEnd() }
                    } else if new.visibleBottom >= new.height - 24 {
                        follow = true
                    } else if new.offset < old.offset - 0.5 {
                        follow = false
                    }
                }
                .onChange(of: follow) { _, enabled in if enabled && canScroll { scrollToEnd() } }
                .onChange(of: canScroll) { _, enabled in if enabled && follow { scrollToEnd() } }
        } else {
            content
                .onChange(of: follow) { _, enabled in if enabled && canScroll { scrollToEnd() } }
                .onChange(of: canScroll) { _, enabled in if enabled && follow { scrollToEnd() } }
        }
    }
}

final class StickyPanel: NSPanel, TextEditorFocusWindow {
    let textEditorFocus = TextEditorWindowFocus()
    static let cornerRadius: CGFloat = 16
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func performClose(_ sender: Any?) { close() }

    override func close() {
        textEditorFocus.beginClose()
        defer { textEditorFocus.endClose() }
        super.close()
    }

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(performClose(_:)) { return isKeyWindow }
        return super.validateMenuItem(menuItem)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // This panel can own keyboard focus while another app owns the menu bar.
        if isKeyWindow, event.type == .keyDown,
           event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "w" {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    func roundWindowFrame() {
        // Clip AppKit's frame as well as the glass, including the active-window outline.
        guard let frame = contentView?.superview else { return }
        frame.wantsLayer = true
        frame.layer?.cornerRadius = Self.cornerRadius
        frame.layer?.masksToBounds = true
        invalidateShadow()
    }
    override func becomeKey() {
        super.becomeKey()
        roundWindowFrame()
    }
    override func makeKeyAndOrderFront(_ sender: Any?) {
        textEditorFocus.prepareToShow()
        roundWindowFrame()
        super.makeKeyAndOrderFront(sender)
        SettingsEditingTextView.requestFocus(in: contentView)
    }
}

@MainActor final class StickyWindow: NSWindowController, NSWindowDelegate {
    static let width: CGFloat = 390
    static let minimumHeight: CGFloat = 120
    static let maximumHeight: CGFloat = 520
    let model: StickyModel
    let hostingView: NSHostingView<StickyView>
    var onClose: (() -> Void)?
    private var pendingResize: Task<Void, Never>?
    var cancelCapture: (() -> Void)?
    private(set) var captureCancelled = false
    init(preset: Preset, source: String, offset: Int, capturingSelection: Bool = false) {
        model = StickyModel(preset: preset, source: source, capturingSelection: capturingSelection)
        hostingView = NSHostingView(rootView: StickyView(model: model))
        let initialHeight: CGFloat = model.awaitingInput ? 320 : Self.minimumHeight
        let panel = StickyPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: initialHeight),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.title = "\(L10n.string("大爆炸", language: model.language)) · \(model.displayedPresetName)"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isMovableByWindowBackground = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize = NSSize(width: Self.width, height: Self.minimumHeight)
        panel.maxSize = NSSize(width: Self.width, height: Self.maximumHeight)
        panel.contentView = GlassSurface.wrap(hostingView, cornerRadius: StickyPanel.cornerRadius)
        panel.roundWindowFrame()
        super.init(window: panel)
        panel.delegate = self
        model.close = { [weak self] in self?.window?.close() }
        model.pin = { [weak panel] value in panel?.level = value ? .floating : .normal }
        model.contentHeightChanged = { [weak self] height in
            guard let self else { return }
            self.pendingResize?.cancel()
            self.pendingResize = Task { @MainActor [weak self] in
                await Task.yield()
                guard !Task.isCancelled else { return }
                self?.resizeForOutput(height)
            }
        }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1000, height: 800)
        let delta = CGFloat(offset % 5) * 24
        let origin = NSPoint(x: max(visible.minX, min(mouse.x + 18 + delta, visible.maxX - Self.width)),
                             y: max(visible.minY, min(mouse.y - initialHeight - delta, visible.maxY - initialHeight)))
        panel.setFrameOrigin(origin)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }
    func setLanguage(to language: AppLanguage) {
        model.language = language
        window?.title = "\(L10n.string("大爆炸", language: language)) · \(model.displayedPresetName)"
    }
    func updateConfiguration(_ configuration: Configuration) {
        model.updatePresets(configuration.presets)
        setLanguage(to: configuration.language)
    }
    /// Retry, edited submissions and preset selection use the latest saved service settings.
    func configureProcessing(configuration: @escaping () -> Configuration,
                             readKey: @escaping () throws -> String,
                             start: @escaping @MainActor (StickyWindow, Configuration, String) -> Void = {
                                 $0.model.start(configuration: $1, key: $2)
                             }) {
        func restart(_ sticky: StickyWindow, preset: Preset, configuration: Configuration, input: String? = nil) {
            do {
                if let input {
                    guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                    guard input.utf8.count <= 100_000 else {
                        throw ValidationError("输入文本超过 100 KB，请缩小内容后重试。")
                    }
                }
                let key = try readKey()
                try configuration.validate()
                guard !configuration.requiresAPIKey || !key.isEmpty else {
                    throw ValidationError("请先在设置中保存 API Key。")
                }
                sticky.model.stop()
                if let input { sticky.model.acceptInput(input) }
                sticky.model.usePreset(preset)
                sticky.setLanguage(to: configuration.language)
                start(sticky, configuration, key)
            } catch { sticky.model.error = error.localizedDescription }
        }
        model.submit = { [weak self] in
            guard let self, self.model.awaitingInput, !self.model.capturingSelection else { return }
            // Leave composition with the native input method until the user commits it.
            if let editor = self.window?.firstResponder as? NSTextView, editor.hasMarkedText() { return }
            let latest = configuration()
            let preset = latest.presets.first { $0.id == self.model.preset.id } ?? self.model.preset
            restart(self, preset: preset, configuration: latest, input: self.model.draft)
        }
        model.retry = { [weak self] in
            guard let self, !self.model.awaitingInput, !self.model.capturingSelection else { return }
            let latest = configuration()
            let preset = latest.presets.first { $0.id == self.model.preset.id } ?? self.model.preset
            restart(self, preset: preset, configuration: latest)
        }
        model.editInput = { [weak self] in
            guard let self, !self.model.awaitingInput, !self.model.capturingSelection else { return }
            self.model.stop()
            self.model.draft = self.model.source
            self.model.output = ""
            self.model.error = nil
            self.model.autoScroll = true
            self.model.contentOverflows = false
            self.model.beginManualInput()
            self.window?.makeKeyAndOrderFront(nil)
        }
        model.selectPreset = { [weak self] id in
            guard let self, id != self.model.preset.id else { return }
            let latest = configuration()
            guard let preset = latest.presets.first(where: { $0.id == id }) else { return }
            if self.model.awaitingInput || self.model.capturingSelection {
                self.model.usePreset(preset)
                self.setLanguage(to: latest.language)
            } else {
                restart(self, preset: preset, configuration: latest)
            }
        }
        updateConfiguration(configuration())
    }
    private func resizeForOutput(_ contentHeight: CGFloat) {
        guard let window else { return }
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? window.frame
        let limit = min(Self.maximumHeight, max(Self.minimumHeight, visible.height - 40))
        let height = min(limit, max(Self.minimumHeight, ceil(contentHeight + StickyView.headerHeight + 1)))
        if CommandLine.arguments.contains("--smoke-test") { print("resize", contentHeight, visible.height, height) }
        if abs(window.frame.height - height) > 0.5 {
            var frame = window.frame
            frame.origin.y = max(visible.minY, min(frame.maxY - height, visible.maxY - height))
            frame.size = NSSize(width: Self.width, height: height)
            window.setFrame(frame, display: true)
        }
        // Publish scrolling only after the panel has its final size. Scrolling is
        // needed for genuine overflow at the screen/window limit, never for growth.
        let overflows = contentHeight > height - StickyView.headerHeight - 1
        if model.contentOverflows != overflows { model.contentOverflows = overflows }
    }
    private func focusedOutput() throws -> StickyTextView {
        guard let window, window.isKeyWindow,
              let view = outputView(in: hostingView), view.isOutputFocused else {
            throw ValidationError("请先在便签正文中选中文字，再按快捷键。")
        }
        return view
    }
    private func outputView(in root: NSView) -> StickyTextView? {
        if let view = root as? StickyTextView { return view }
        return root.subviews.lazy.compactMap { self.outputView(in: $0) }.first
    }
    /// Reads only the active rendered selection, never the note's original input.
    func selectedOutputText() throws -> String {
        try validateSelection(focusedOutput().selectedText)
    }
    /// Production hotkeys take a fresh DOM snapshot to avoid selection IPC races.
    func selectedOutputTextSnapshot() async throws -> String {
        let view = try focusedOutput()
        let selected = try await view.selectionSnapshot()
        guard view.window === window, window?.isKeyWindow == true, view.isOutputFocused else {
            throw ValidationError("请先在便签正文中选中文字，再按快捷键。")
        }
        return try validateSelection(selected)
    }
    private func validateSelection(_ selected: String) throws -> String {
        guard !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError("当前便签没有选中的文本。")
        }
        guard selected.utf8.count <= 100_000 else {
            throw ValidationError("选中文本超过 100 KB，请缩小选择范围。")
        }
        return selected
    }
    func cancelSelectionCapture() {
        captureCancelled = true
        cancelCapture?()
    }
    func beginManualInput() {
        guard model.capturingSelection, !model.awaitingInput, window?.isVisible == true else { return }
        cancelSelectionCapture()
        model.beginManualInput()
        if window?.isKeyWindow != true { window?.makeKeyAndOrderFront(nil) }
    }
    func windowDidBecomeKey(_ notification: Notification) {
        beginManualInput()
    }
    func windowWillClose(_ notification: Notification) {
        cancelSelectionCapture()
        pendingResize?.cancel(); pendingResize = nil
        outputView(in: hostingView)?.dispose()
        model.stop(); onClose?()
    }
    func windowDidResize(_ notification: Notification) { (window as? StickyPanel)?.roundWindowFrame() }
}
