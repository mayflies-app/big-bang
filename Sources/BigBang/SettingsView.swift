import AppKit
import SwiftUI
import Carbon
import Combine
import BigBangCore
import BigBangSelection

struct ShortcutRecorder: NSViewRepresentable {
    @Binding var shortcut: Shortcut
    let palette: SettingsPalette
    var language: AppLanguage = L10n.currentLanguage
    var onRecordingChange: (Bool) -> Void
    func makeNSView(context: Context) -> RecorderButton {
        let button = RecorderButton()
        button.isBordered = false
        button.focusRingType = .none
        button.target = button; button.action = #selector(RecorderButton.beginRecording)
        return button
    }
    func updateNSView(_ button: RecorderButton, context: Context) {
        button.updateShortcutTitle(shortcut.label)
        button.palette = palette
        button.language = language
        button.onRecord = { shortcut = $0 }
        button.onRecordingChange = onRecordingChange
    }
    static func dismantleNSView(_ button: RecorderButton, coordinator: ()) { button.endRecording() }
}

final class RecorderButton: NSButton {
    var palette = SettingsPalette(dark: false) { didSet { updateTitlePresentation(); needsDisplay = true } }
    private let titleLabel = RecorderTitleLabel(labelWithString: "")
    override var title: String { didSet { updateTitlePresentation() } }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureTitleLabel()
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureTitleLabel()
    }
    private func configureTitleLabel() {
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setAccessibilityElement(false)
        addSubview(titleLabel)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        updateTitlePresentation()
    }
    private func updateTitlePresentation() {
        titleLabel.stringValue = title
        titleLabel.font = NSFont.systemFont(ofSize: recording ? 10 : 12, weight: .medium)
        // A concrete color and native label avoid custom attributed-string measurement
        // in draw(_:), the call site identified by the recorded CoreText exceptions.
        titleLabel.textColor = palette.nativeText
    }
    var onRecord: ((Shortcut) -> Void)?
    var onRecordingChange: ((Bool) -> Void)?
    var language: AppLanguage = L10n.currentLanguage {
        didSet { if recording { title = L10n.string("按下快捷键…", language: language) } }
    }
    private var recording = false
    private var hovered = false
    private var previousTitle = ""
    private var monitor: Any?
    override var acceptsFirstResponder: Bool { true }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    func updateShortcutTitle(_ value: String) {
        if !recording { title = value }
    }
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        needsDisplay = true
        return accepted
    }
    override func draw(_ dirtyRect: NSRect) {
        let focused = window?.firstResponder === self
        let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 7, yRadius: 7)
        (hovered ? palette.nativeHover : palette.nativeField).setFill(); outline.fill()
        (focused || recording ? palette.nativeAccent : palette.nativeBorder).setStroke()
        outline.lineWidth = focused || recording ? 1.5 : 1; outline.stroke()
    }
    @objc func beginRecording() {
        guard !recording, let window, window.isKeyWindow, window.makeFirstResponder(self) else { return }
        previousTitle = title; recording = true; title = L10n.string("按下快捷键…", language: language); needsDisplay = true
        // A retained window keeps its first responder when it closes or loses key
        // status. End capture there so shortcuts resume before another window types.
        for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(recordingWindowEnded(_:)), name: name, object: window)
        }
        onRecordingChange?(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.recording else { return event }
            guard let window = self.window, window.isKeyWindow, event.window === window else {
                self.endRecording()
                return event
            }
            self.keyDown(with: event)
            return nil
        }
    }
    @objc private func recordingWindowEnded(_ notification: Notification) { endRecording() }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        endRecording()
        super.viewWillMove(toWindow: newWindow)
    }
    func endRecording() {
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
            NotificationCenter.default.removeObserver(self, name: name, object: nil)
        }
        if recording { recording = false; title = previousTitle; onRecordingChange?(false) }
        needsDisplay = true
    }
    override func resignFirstResponder() -> Bool { endRecording(); needsDisplay = true; return super.resignFirstResponder() }
    override func keyDown(with event: NSEvent) {
        guard recording else { super.keyDown(with: event); return }
        if event.keyCode == 53 { endRecording(); window?.makeFirstResponder(nil); return }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.intersection([.command, .control, .option]).isEmpty else { NSSound.beep(); return }
        var modifiers: UInt32 = 0
        var label = ""
        if flags.contains(.control) { modifiers |= UInt32(controlKey); label += "⌃" }
        if flags.contains(.option) { modifiers |= UInt32(optionKey); label += "⌥" }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey); label += "⇧" }
        if flags.contains(.command) { modifiers |= UInt32(cmdKey); label += "⌘" }
        label += Self.keyLabel(for: event)
        endRecording()
        onRecord?(.init(keyCode: UInt32(event.keyCode), modifiers: modifiers, label: label))
        title = label; window?.makeFirstResponder(nil)
    }
    private static func keyLabel(for event: NSEvent) -> String {
        // Special keys produce control or private-use characters, not visible key names.
        switch Int(event.keyCode) {
        case kVK_Return: return "⏎"
        case kVK_ANSI_KeypadEnter: return "⌅"
        case kVK_Tab: return "⇥"
        case kVK_Space: return "␣"
        case kVK_Delete: return "⌫"
        case kVK_ForwardDelete: return "⌦"
        case kVK_ANSI_KeypadClear: return "⌧"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_DownArrow: return "↓"
        case kVK_UpArrow: return "↑"
        case kVK_Home: return "↖"
        case kVK_End: return "↘"
        case kVK_PageUp: return "⇞"
        case kVK_PageDown: return "⇟"
        case kVK_Help: return "Help"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        case kVK_F13: return "F13"
        case kVK_F14: return "F14"
        case kVK_F15: return "F15"
        case kVK_F16: return "F16"
        case kVK_F17: return "F17"
        case kVK_F18: return "F18"
        case kVK_F19: return "F19"
        case kVK_F20: return "F20"
        default: break
        }
        if let characters = event.charactersIgnoringModifiers, !characters.isEmpty,
           characters.unicodeScalars.allSatisfy({
               !CharacterSet.controlCharacters.contains($0) && !CharacterSet.whitespacesAndNewlines.contains($0) &&
                   $0.properties.generalCategory != .privateUse
           }) {
            return characters.uppercased()
        }
        return "Key \(event.keyCode)"
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event); return true
    }
}

private final class RecorderTitleLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor struct SettingsView: View {
    @ObservedObject var editor: SettingsEditor
    @ObservedObject private var loginItems: LoginItemController
    @Environment(\.colorScheme) private var colorScheme
    @State private var trusted = SelectionReader.isTrusted
    @State private var section = Section.connection
    @State private var newPresetID: UUID?
    @State private var presetRevealRequest = UUID()
    @FocusState private var focusedField: Field?
    @FocusState private var focusedAction: Action?
    let demo: () -> Void
    let onRecordingChange: (Bool) -> Void
    let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()
    private enum Field: Hashable { case key, model, endpoint, presetName(UUID), prompt(UUID) }
    private enum Action: Hashable { case preview, add, restore, undoDelete, dismissDeleted, permission, loginSettings, languageChinese, languageEnglish, deleteKey, deletePreset(UUID), movePresetUp(UUID), movePresetDown(UUID), apiResponses, apiChatCompletions }
    enum Section: String, CaseIterable, Identifiable {
        case general = "常规"
        case connection = "模型服务", presets = "处理预设", selection = "文本读取"
        var id: Self { self }
        var accessibilityID: String {
            switch self {
            case .general: "settings.section.general"
            case .connection: "settings.section.connection"
            case .presets: "settings.section.presets"
            case .selection: "settings.section.reading"
            }
        }
        var symbol: String {
            switch self { case .general: "gearshape"; case .connection: "network"; case .presets: "command"; case .selection: "text.cursor" }
        }
        var detail: String {
            switch self {
            case .general: "设置界面语言和登录时启动。"
            case .connection: "设置模型服务的地址、类型和凭据。"
            case .presets: "编辑处理指令和快捷键。"
            case .selection: "管理文本读取权限和方式。"
            }
        }
    }
    private var palette: SettingsPalette { .init(dark: colorScheme == .dark) }
    private func tr(_ value: String) -> String { L10n.string(value, language: editor.draft.language) }
    private func trFormat(_ value: String, _ argument: String) -> String { L10n.format(value, argument, language: editor.draft.language) }

    init(editor: SettingsEditor, demo: @escaping () -> Void, onRecordingChange: @escaping (Bool) -> Void, initialSection: Section = .connection, loginItems: LoginItemController? = nil) {
        self.editor = editor
        self.loginItems = loginItems ?? LoginItemController.preview()
        self.demo = demo
        self.onRecordingChange = onRecordingChange
        _section = State(initialValue: initialSection)
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(palette.border).frame(width: 1).allowsHitTesting(false)
            VStack(spacing: 0) {
                header
                Rectangle().fill(palette.border).frame(height: 1).allowsHitTesting(false)
                if let error = editor.error {
                    Label(tr(error), systemImage: "exclamationmark.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 28).padding(.vertical, 12)
                        .accessibilityIdentifier("settings.error")
                }
                if section == .presets, let deleted = editor.lastDeletedPreset {
                    deletedPresetNotice(deleted)
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            switch section {
                            case .general: generalPane
                            case .connection: connectionPane
                            case .presets: presetsPane
                            case .selection: selectionPane
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                            .padding(28)
                    }
                    .onChange(of: presetRevealRequest) { _, _ in
                        guard let id = newPresetID else { return }
                        DispatchQueue.main.async {
                            withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .bottom) }
                            focusedField = .presetName(id)
                        }
                    }
                }
            }.background(palette.canvas)
        }
        .frame(minWidth: 680, minHeight: 570)
        .background {
            // Continue the surfaces beneath the native titlebar without moving its controls
            // or the content out of the titlebar's safe area.
            HStack(spacing: 0) {
                palette.sidebar.frame(width: 150)
                palette.border.frame(width: 1)
                palette.canvas
            }.ignoresSafeArea(.container, edges: .top).allowsHitTesting(false)
        }
        .foregroundStyle(palette.text)
        .font(.system(size: 13))
        .textFieldStyle(.plain)
        .tint(palette.accent)
        .onAppear { loginItems.refresh(); if section == .connection { focusedField = .endpoint } }
        .onChange(of: focusedField) { _, _ in editor.flush() }
        .onChange(of: section) { _, _ in focusedField = nil; editor.flush() }
        .onDisappear { editor.flush() }
        .onReceive(timer) { _ in trusted = SelectionReader.isTrusted; loginItems.refresh() }
    }

    private var appVersion: String? {
        guard let version = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !version.isEmpty else { return nil }
        let build = (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return build.isEmpty ? version : "\(version) (\(build))"
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11).fill(palette.iconTile)
                    RoundedRectangle(cornerRadius: 11).strokeBorder(palette.iconBorder, lineWidth: 1)
                    Image(systemName: "text.quote")
                        .font(.system(size: 24, weight: .medium)).foregroundStyle(palette.text)
                        .offset(x: -1, y: 2)
                    Image(systemName: "sparkle")
                        .font(.system(size: 10, weight: .medium)).foregroundStyle(palette.accent)
                        .offset(x: 12, y: -12)
                }
                    .frame(width: 44, height: 44)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(tr("大爆炸应用图标"))
                    .accessibilityIdentifier("settings.appIcon")
                Text(tr("大爆炸")).font(.system(size: 17, weight: .semibold))
            }.padding(.horizontal, 20).padding(.top, 34).padding(.bottom, 27)
            VStack(spacing: 5) {
                ForEach(Section.allCases) { item in
                    Button { section = item } label: {
                        HStack(spacing: 9) {
                            Image(systemName: item.symbol).font(.system(size: 13)).frame(width: 17)
                            Text(tr(item.rawValue)).font(.system(size: 12, weight: section == item ? .semibold : .regular))
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(section == item ? palette.text : palette.secondary)
                        .padding(.horizontal, 11).padding(.vertical, 10)
                        .background(section == item ? palette.selected : .clear, in: RoundedRectangle(cornerRadius: MacAppDesignTokens.controlRadius))
                        .contentShape(RoundedRectangle(cornerRadius: MacAppDesignTokens.controlRadius))
                    }.buttonStyle(.plain)
                        .accessibilityAddTraits(section == item ? .isSelected : [])
                        .accessibilityIdentifier(item.accessibilityID)
                }
            }.padding(.horizontal, 10)
            Spacer()
            if let version = appVersion {
                Text(trFormat("版本 %@", version))
                    .font(.system(size: 11)).foregroundStyle(palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 20).padding(.bottom, 18)
                    .accessibilityIdentifier("app.version")
            }
        }.frame(width: 150).background(palette.sidebar)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(tr(section.rawValue)).font(.system(size: 21, weight: .semibold))
                Text(tr(section.detail)).font(.system(size: 12)).foregroundStyle(palette.secondary)
            }
            Spacer(minLength: 8)
            Button(action: demo) {
                Label(tr("预览便签"), systemImage: "rectangle.on.rectangle")
            }.buttonStyle(SettingsButtonStyle(palette: palette, focused: focusedAction == .preview))
                .focused($focusedAction, equals: .preview)
                .help(tr("预览便签")).accessibilityLabel(tr("预览便签"))
                .accessibilityIdentifier("settings.preview")
        }.padding(.horizontal, 28).padding(.vertical, 23)
    }

    private var generalPane: some View {
        VStack(alignment: .leading, spacing: 28) {
            field(tr("界面语言"), detail: tr("立即切换界面语言和未修改的内置预设。")) {
                HStack(spacing: 3) {
                    languageButton(.simplifiedChinese, title: "简体中文", action: .languageChinese, identifier: "settings.language.zh-Hans")
                    languageButton(.english, title: "English", action: .languageEnglish, identifier: "settings.language.en")
                }.padding(3)
                    .background(palette.field, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(palette.border).allowsHitTesting(false))
                    .accessibilityElement(children: .contain).accessibilityLabel(tr("界面语言"))
            }
            Rectangle().fill(palette.border).frame(height: 1).allowsHitTesting(false)
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(tr("登录时启动")).font(.system(size: 13, weight: .semibold))
                    Text(tr("登录 Mac 后自动启动大爆炸。"))
                        .font(.system(size: 12)).foregroundStyle(palette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Toggle(tr("登录时启动"), isOn: Binding(get: { loginItems.isEnabled }, set: { loginItems.setEnabled($0) }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .disabled(!loginItems.canToggle)
                    .accessibilityIdentifier("settings.launchAtLogin")
            }
            VStack(alignment: .leading, spacing: 12) {
                Text(tr(loginStatusDescription)).font(.system(size: 12)).foregroundStyle(palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings.launchAtLogin.status")
                if loginItems.status == .requiresApproval {
                    Button(tr("打开登录项设置")) { loginItems.openSystemSettings() }
                        .buttonStyle(SettingsButtonStyle(palette: palette, focused: focusedAction == .loginSettings))
                        .focused($focusedAction, equals: .loginSettings)
                        .accessibilityIdentifier("settings.launchAtLogin.openSettings")
                }
                if let error = loginItems.error {
                    Label(tr(error), systemImage: "exclamationmark.circle")
                        .font(.system(size: 12)).foregroundStyle(Color.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("settings.launchAtLogin.error")
                }
            }
        }
    }

    private var loginStatusDescription: String {
        switch loginItems.status {
        case .enabled: "已启用登录时启动。"
        case .disabled: "登录时启动已关闭。"
        case .requiresApproval: "请在系统设置的登录项中允许大爆炸启动。"
        case .unavailable: "请从应用程序文件夹运行已安装的大爆炸，以设置登录时启动。"
        }
    }

    private func languageButton(_ language: AppLanguage, title: String, action: Action, identifier: String) -> some View {
        Button { editor.changeLanguage(to: language); loginItems.refresh() } label: { Text(title).frame(maxWidth: .infinity) }
            .buttonStyle(SettingsButtonStyle(palette: palette, focused: focusedAction == action, selected: editor.draft.language == language, segmented: true))
            .focused($focusedAction, equals: action)
            .accessibilityAddTraits(editor.draft.language == language ? .isSelected : [])
            .accessibilityIdentifier(identifier)
            .onKeyPress(.leftArrow) { editor.changeLanguage(to: .simplifiedChinese); focusedAction = .languageChinese; return .handled }
            .onKeyPress(.rightArrow) { editor.changeLanguage(to: .english); focusedAction = .languageEnglish; return .handled }
    }

    private var connectionPane: some View {
        VStack(alignment: .leading, spacing: 23) {
            field(tr("API 地址"), detail: tr("填写基础地址，例如 https://api.openai.com/v1。")) {
                TextField(tr("API 地址"), text: $editor.draft.apiBaseURL,
                    prompt: Text("https://api.openai.com/v1").foregroundStyle(palette.secondary))
                    .modifier(SettingsInputSurface(palette: palette, focused: focusedField == .endpoint))
                    .focused($focusedField, equals: .endpoint)
                    .accessibilityLabel(tr("API 地址"))
                    .accessibilityIdentifier("settings.endpoint")
            }
            field(tr("API 类型")) {
                HStack(spacing: 3) {
                    ForEach(APIMode.allCases) { mode in
                        Button { editor.draft.apiMode = mode } label: {
                            Text(mode.title).frame(maxWidth: .infinity)
                        }
                        .buttonStyle(SettingsButtonStyle(palette: palette, focused: focusedAction == apiAction(mode), selected: editor.draft.apiMode == mode, segmented: true))
                        .focused($focusedAction, equals: apiAction(mode))
                        .accessibilityAddTraits(editor.draft.apiMode == mode ? .isSelected : [])
                        .accessibilityIdentifier("settings.api.\(mode.rawValue)")
                        .onKeyPress(.leftArrow) { editor.draft.apiMode = .responses; focusedAction = .apiResponses; return .handled }
                        .onKeyPress(.rightArrow) { editor.draft.apiMode = .chatCompletions; focusedAction = .apiChatCompletions; return .handled }
                    }
                }.padding(3)
                    .background(palette.field, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(palette.border).allowsHitTesting(false))
                    .accessibilityElement(children: .contain).accessibilityLabel(tr("API 类型"))
            }
            field(tr("模型名称"), detail: tr("填写服务支持的模型名称。")) {
                TextField(tr("模型名称"), text: $editor.draft.model,
                    prompt: Text(tr("模型名称")).foregroundStyle(palette.secondary))
                    .modifier(SettingsInputSurface(palette: palette, focused: focusedField == .model))
                    .focused($focusedField, equals: .model).accessibilityLabel(tr("模型名称"))
                    .accessibilityIdentifier("settings.model")
            }
            field("API Key", detail: editor.hasKey ? tr("留空保留已有 Key，输入新 Key 可替换。无认证服务请先删除 Key。") : tr("保存在系统钥匙串；无认证服务可留空。")) {
                HStack(spacing: 10) {
                    SecureField("API Key", text: $editor.apiKeyInput, prompt: Text(""))
                        .overlay(alignment: .leading) {
                            if editor.apiKeyInput.isEmpty {
                                Text(editor.hasKey ? tr("已保存在钥匙串") : tr("输入 API Key"))
                                    .foregroundStyle(palette.secondary)
                                    .allowsHitTesting(false).accessibilityHidden(true)
                            }
                        }
                        .modifier(SettingsInputSurface(palette: palette, focused: focusedField == .key))
                        .focused($focusedField, equals: .key).accessibilityLabel("API Key")
                        .accessibilityIdentifier("settings.key")
                    if editor.hasKey {
                        Button { editor.deleteCredential() } label: {
                            Image(systemName: "trash").frame(width: 16)
                        }.buttonStyle(SettingsButtonStyle(palette: palette, focused: focusedAction == .deleteKey))
                            .focused($focusedAction, equals: .deleteKey)
                            .help(tr("删除已保存的 API Key")).accessibilityLabel(tr("删除已保存的 API Key"))
                    }
                }
            }
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "lock.shield").font(.system(size: 12)).padding(.top, 1)
                Text(tr("选中的文字与 Key 会发送到此 API 地址。"))
                    .fixedSize(horizontal: false, vertical: true)
            }.font(.system(size: 11)).foregroundStyle(palette.secondary).padding(.top, 1)
        }
    }

    private var presetsPane: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 8) {
                Button { restorePresets() } label: { Text(tr("恢复默认预设")) }
                    .buttonStyle(SettingsButtonStyle(palette: palette, focused: focusedAction == .restore))
                    .focused($focusedAction, equals: .restore)
                    .help(tr("补回缺失的默认预设，保留现有修改和自定义预设"))
                    .accessibilityIdentifier("settings.preset.restore")
                Spacer()
                Button { addPreset() } label: { Label(tr("添加预设"), systemImage: "plus") }
                    .buttonStyle(SettingsButtonStyle(palette: palette, focused: focusedAction == .add))
                    .focused($focusedAction, equals: .add)
                    .accessibilityIdentifier("settings.preset.add")
            }
            Text(tr("恢复只补回缺失的默认预设，保留已有修改。"))
                .font(.system(size: 11)).foregroundStyle(palette.secondary)
            ForEach(editor.draft.presets) { preset in
                let presetBinding = binding(for: preset)
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        TextField(tr("预设名称"), text: presetBinding.name,
                            prompt: Text(tr("预设名称")).foregroundStyle(palette.secondary))
                            .font(.system(size: 13, weight: .medium))
                            .modifier(SettingsInputSurface(palette: palette, focused: focusedField == .presetName(preset.id)))
                            .focused($focusedField, equals: .presetName(preset.id))
                            .accessibilityLabel(tr("预设名称"))
                            .accessibilityIdentifier("settings.preset.\(preset.id).name")
                        ShortcutRecorder(shortcut: presetBinding.shortcut, palette: palette, language: editor.draft.language, onRecordingChange: onRecordingChange)
                            .frame(width: 104, height: 36)
                            .accessibilityLabel(trFormat("%@的快捷键", preset.name))
                            .accessibilityIdentifier("settings.preset.\(preset.id).shortcut")
                        Button { deletePreset(preset.id) } label: {
                            Image(systemName: "trash").frame(width: 16)
                        }.buttonStyle(SettingsButtonStyle(palette: palette, focused: focusedAction == .deletePreset(preset.id)))
                            .focused($focusedAction, equals: .deletePreset(preset.id))
                            .disabled(editor.draft.presets.count <= 1)
                            .help(tr("删除预设")).accessibilityLabel(trFormat("删除%@预设", preset.name))
                            .accessibilityIdentifier("settings.preset.\(preset.id).delete")
                    }
                    HStack(spacing: 6) {
                        Text(tr("处理指令")).font(.system(size: 11, weight: .medium)).foregroundStyle(palette.secondary)
                        Spacer()
                        Button { _ = editor.movePreset(id: preset.id, by: -1) } label: {
                            Image(systemName: "arrow.up").frame(width: 16)
                        }.buttonStyle(SettingsButtonStyle(palette: palette, focused: focusedAction == .movePresetUp(preset.id)))
                            .focused($focusedAction, equals: .movePresetUp(preset.id))
                            .disabled(!canMovePreset(preset.id, by: -1))
                            .help(tr("上移预设")).accessibilityLabel(trFormat("上移%@预设", preset.name))
                            .accessibilityIdentifier("settings.preset.\(preset.id).moveUp")
                        Button { _ = editor.movePreset(id: preset.id, by: 1) } label: {
                            Image(systemName: "arrow.down").frame(width: 16)
                        }.buttonStyle(SettingsButtonStyle(palette: palette, focused: focusedAction == .movePresetDown(preset.id)))
                            .focused($focusedAction, equals: .movePresetDown(preset.id))
                            .disabled(!canMovePreset(preset.id, by: 1))
                            .help(tr("下移预设")).accessibilityLabel(trFormat("下移%@预设", preset.name))
                            .accessibilityIdentifier("settings.preset.\(preset.id).moveDown")
                    }
                    SettingsTextEditor(text: presetBinding.prompt, focused: focusBinding(for: .prompt(preset.id)),
                        palette: palette, label: trFormat("%@的处理指令", preset.name),
                        identifier: "settings.preset.\(preset.id).prompt", isolatesScrolling: true)
                        .frame(height: 92).padding(8)
                        .modifier(SettingsFieldOutline(palette: palette, focused: focusedField == .prompt(preset.id)))
                }.id(preset.id)
                if preset.id != editor.draft.presets.last?.id {
                    Rectangle().fill(palette.border).frame(height: 1).padding(.vertical, 1).allowsHitTesting(false)
                }
            }
            Text(tr("点击快捷键后，按包含 ⌃、⌥ 或 ⌘ 的组合键；按 Esc 取消。"))
                .font(.system(size: 11)).foregroundStyle(palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func deletedPresetNotice(_ preset: Preset) -> some View {
        HStack(spacing: 10) {
            Text(trFormat("已删除“%@”", preset.name))
                .font(.system(size: 12)).lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("settings.preset.deleted.notice")
            Button(tr("撤销删除")) { undoDeletePreset() }
                .buttonStyle(SettingsButtonStyle(palette: palette, focused: focusedAction == .undoDelete))
                .focused($focusedAction, equals: .undoDelete)
                .accessibilityIdentifier("settings.preset.undoDelete")
            Button { editor.dismissDeletedPreset() } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .medium)).frame(width: 12)
            }
            .buttonStyle(SettingsButtonStyle(palette: palette, focused: focusedAction == .dismissDeleted))
            .focused($focusedAction, equals: .dismissDeleted)
            .help(tr("关闭撤销提示")).accessibilityLabel(tr("关闭撤销提示"))
            .accessibilityIdentifier("settings.preset.dismissDeleted")
        }
        .padding(.horizontal, 28).padding(.vertical, 10)
        .background(palette.field)
        .overlay(alignment: .bottom) { Rectangle().fill(palette.border).frame(height: 1).allowsHitTesting(false) }
    }

    private var selectionPane: some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 14) {
                Text(tr("辅助功能权限")).font(.system(size: 13, weight: .semibold))
                HStack(spacing: 12) {
                    Image(systemName: trusted ? "checkmark.circle.fill" : "lock.circle")
                        .font(.system(size: 24)).foregroundStyle(trusted ? palette.accent : palette.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(trusted ? tr("已授权") : tr("需要授权")).font(.system(size: 13, weight: .medium))
                        Text(tr("读取其他应用中选中的文字。"))
                            .font(.system(size: 11)).foregroundStyle(palette.secondary)
                    }
                    Spacer(minLength: 4)
                    if !trusted {
                        Button(tr("打开系统设置")) { requestPermission() }
                            .buttonStyle(SettingsButtonStyle(palette: palette, focused: focusedAction == .permission))
                            .focused($focusedAction, equals: .permission)
                    }
                }
            }
            Rectangle().fill(palette.border).frame(height: 1).allowsHitTesting(false)
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(tr("使用剪贴板读取")).font(.system(size: 13, weight: .semibold))
                    Text(tr("无法直接读取选中文字时，自动复制并恢复剪贴板。"))
                        .font(.system(size: 12)).foregroundStyle(palette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Toggle(tr("使用剪贴板读取"), isOn: $editor.draft.copyFallback)
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .accessibilityIdentifier("settings.copyFallback")
            }
        }
    }

    private func field<Content: View>(_ name: String, detail: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(name).font(.system(size: 12, weight: .semibold))
            content()
            if let detail { Text(detail).font(.system(size: 11)).foregroundStyle(palette.secondary).fixedSize(horizontal: false, vertical: true) }
        }
    }
    private func requestPermission() {
        SelectionReader.requestPermission()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(url) }
    }
    private func apiAction(_ mode: APIMode) -> Action { mode == .responses ? .apiResponses : .apiChatCompletions }
    private func focusBinding(for field: Field) -> Binding<Bool> {
        Binding { focusedField == field } set: { value in
            if value { focusedField = field }
            else if focusedField == field { focusedField = nil }
        }
    }
    private func binding(for snapshot: Preset) -> Binding<Preset> {
        Binding {
            editor.draft.presets.first { $0.id == snapshot.id } ?? snapshot
        } set: { value in
            // Native field editors may deliver one last edit after deletion or reordering.
            // Resolve the current index by identity and ignore edits to removed rows.
            guard let index = editor.draft.presets.firstIndex(where: { $0.id == snapshot.id }) else { return }
            editor.draft.presets[index] = value
        }
    }
    private func canMovePreset(_ id: UUID, by offset: Int) -> Bool {
        guard let index = editor.draft.presets.firstIndex(where: { $0.id == id }) else { return false }
        return editor.draft.presets.indices.contains(index + offset)
    }
    private func restorePresets() {
        guard let firstID = editor.restoreDefaultPresets().first else { return }
        newPresetID = firstID
        presetRevealRequest = UUID()
    }
    private func deletePreset(_ id: UUID) {
        guard editor.deletePreset(id: id) else { return }
        focusedField = nil
        focusedAction = .undoDelete
    }
    private func undoDeletePreset() {
        guard let id = editor.undoDeletePreset() else { return }
        focusedAction = nil
        newPresetID = id
        presetRevealRequest = UUID()
    }
    private func addPreset() {
        guard let id = editor.addPreset() else { return }
        section = .presets
        newPresetID = id
        presetRevealRequest = UUID()
    }
}

typealias SettingsPalette = MacAppSettingsPalette

private struct SettingsButtonStyle: ButtonStyle {
    let palette: SettingsPalette
    var focused = false
    var selected = false
    var segmented = false
    @Environment(\.isEnabled) private var enabled
    @State private var hovered = false

    func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        let fill = selected ? palette.segmentSelected : configuration.isPressed ? palette.pressed : hovered && enabled ? palette.hover : segmented ? Color.clear : palette.field
        return configuration.label
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 10).frame(minHeight: 36)
            .foregroundStyle(palette.text)
            .background(fill, in: RoundedRectangle(cornerRadius: MacAppDesignTokens.controlRadius))
            .overlay(RoundedRectangle(cornerRadius: MacAppDesignTokens.controlRadius)
                .strokeBorder(focused ? palette.accent : segmented ? .clear : palette.border, lineWidth: focused ? 1.5 : 1)
                .allowsHitTesting(false))
            .contentShape(RoundedRectangle(cornerRadius: MacAppDesignTokens.controlRadius))
            .opacity(enabled ? 1 : 0.4)
            .onHover { hovered = $0 }
    }
}

private struct SettingsFieldOutline: ViewModifier {
    let palette: SettingsPalette
    var focused = false
    func body(content: Content) -> some View {
        content
            .foregroundStyle(palette.text)
            .background(palette.field, in: RoundedRectangle(cornerRadius: MacAppDesignTokens.controlRadius))
            .overlay(RoundedRectangle(cornerRadius: MacAppDesignTokens.controlRadius)
                .strokeBorder(focused ? palette.accent : palette.border, lineWidth: focused ? 1.5 : 1)
                .allowsHitTesting(false))
    }
}

private struct SettingsInputSurface: ViewModifier {
    let palette: SettingsPalette
    var focused = false
    func body(content: Content) -> some View {
        content.padding(.horizontal, 11).padding(.vertical, 10)
            .modifier(SettingsFieldOutline(palette: palette, focused: focused))
    }
}
