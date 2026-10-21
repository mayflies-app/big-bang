import Foundation
import BigBangCore

struct AccessibilitySelection: Sendable {
    var isSecure = false
    var isSecureCheckUncertain = false
    var text: String?
    var rangeLength: Int?
    var rangeText: String?
    // Give an editor's optional copy metadata a short opportunity to arrive.
    var isEditorInput = false
}

struct SelectionClipboard {
    var changeCount: Int
    var text: String?
    var customData: [String: Data] = [:]
    var isStable = true
    var types: [String] = []
}

/// Opt-in local verification only. Normal reads do not record clipboard observations.
public struct SelectionCopyObservation {
    public let types: [String]
    public let text: String?
    public let customData: [String: Data]
}

/// The copy probe temporarily owns the clipboard between these synchronous events.
/// `ended` follows restoration or the decision to preserve an external clipboard write.
public enum SelectionClipboardPhase: Sendable, Equatable {
    case began
    case ended
}

typealias ClipboardSnapshot = [[String: Data]]

/// A posted copy cannot be recalled. Cancellation may prevent posting, but must
/// let an already posted transaction finish observing and restoring the clipboard.
private final class SelectionCopyCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var isCancelled = false

    func cancel() { lock.withLock { isCancelled = true } }
    func check() throws {
        try lock.withLock { if isCancelled { throw CancellationError() } }
    }
    func post(_ action: () throws -> Void) throws {
        try lock.withLock {
            if isCancelled { throw CancellationError() }
            try action()
        }
    }
}

/// OS boundary: tests exercise the same read/copy transaction without TCC or global input.
@MainActor protocol SelectionEnvironment {
    var isTrusted: Bool { get }
    var frontmostPID: Int32? { get }
    var ownPID: Int32 { get }
    func selection(pid: Int32) async -> AccessibilitySelection
    func shortcutIsHeld(keyCode: UInt16?) -> Bool
    func clipboardSnapshot() -> ClipboardSnapshot
    var clipboard: SelectionClipboard { get }
    func installMarker(_ marker: String)
    func restoreClipboard(_ snapshot: ClipboardSnapshot)
    func sendCopy(pid: Int32) throws
    func pause(milliseconds: Int) async throws
}

@MainActor public enum SelectionReader {
    public static var isTrusted: Bool { SystemSelectionEnvironment().isTrusted }
    public static func requestPermission() { SystemSelectionEnvironment.requestPermission() }
    public static func read(copyFallback: Bool, triggerKeyCode: UInt16? = nil,
                            onClipboardPhase: (@MainActor (SelectionClipboardPhase) -> Void)? = nil,
                            onCopiedClipboard: ((SelectionCopyObservation) -> Void)? = nil) async throws -> String {
        try await read(copyFallback: copyFallback, triggerKeyCode: triggerKeyCode,
                       environment: SystemSelectionEnvironment(), onClipboardPhase: onClipboardPhase,
                       onCopiedClipboard: onCopiedClipboard)
    }

    static func read(copyFallback: Bool, triggerKeyCode: UInt16? = nil, environment: any SelectionEnvironment,
                     onClipboardPhase: (@MainActor (SelectionClipboardPhase) -> Void)? = nil,
                     onCopiedClipboard: ((SelectionCopyObservation) -> Void)? = nil) async throws -> String {
        try Task.checkCancellation()
        guard environment.isTrusted else { throw ValidationError("请先在系统设置 → 隐私与安全性 → 辅助功能中允许大爆炸，然后再次触发快捷键。") }
        guard let pid = environment.frontmostPID, pid != environment.ownPID else {
            throw ValidationError("请先在其他应用中选中文本，再按快捷键。")
        }
        let selection = await environment.selection(pid: pid)
        try Task.checkCancellation()
        guard environment.frontmostPID == pid else { throw ValidationError("前台应用已改变，请重新选择并触发。") }
        guard !selection.isSecure else { throw ValidationError("密码输入框中的文本不会被读取。") }
        guard !selection.isSecureCheckUncertain else {
            throw ValidationError("当前应用没有提供可读取的选中文本。可在设置中启用复制回退，或换一个支持辅助功能的应用。")
        }
        // An empty AX attribute can describe an editor's hidden input, not its selection.
        if let text = selection.text, hasText(text) { return try checked(text) }
        if let text = selection.rangeText, (selection.rangeLength ?? 0) > 0, hasText(text) { return try checked(text) }
        guard copyFallback else { throw ValidationError("当前应用没有提供可读取的选中文本。可在设置中启用复制回退，或换一个支持辅助功能的应用。") }
        let cancellation = SelectionCopyCancellation()
        return try await withTaskCancellationHandler {
            // An unstructured task does not inherit the caller's cancellation.
            // Once copy is posted, keep its original observation/restore lifetime.
            let transaction = Task { @MainActor in
                try await copiedSelection(pid: pid, triggerKeyCode: triggerKeyCode,
                    metadataGracePolls: selection.isEditorInput && (selection.rangeLength ?? 0) <= 0 ? 3 : 0,
                    environment: environment, cancellation: cancellation,
                    onClipboardPhase: onClipboardPhase, onCopiedClipboard: onCopiedClipboard)
            }
            let result = await transaction.result
            try Task.checkCancellation()
            return try result.get()
        } onCancel: {
            cancellation.cancel()
        }
    }

    private static func checked(_ text: String) throws -> String {
        guard hasText(text) else { throw ValidationError("当前没有选中的文本。") }
        guard text.utf8.count <= 100_000 else { throw ValidationError("选中文本超过 100 KB，请缩小选择范围。") }
        return text
    }
    private static func hasText(_ text: String) -> Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private static func copiedSelection(pid: Int32, triggerKeyCode: UInt16?, metadataGracePolls: Int,
                                        environment: any SelectionEnvironment, cancellation: SelectionCopyCancellation,
                                        onClipboardPhase: (@MainActor (SelectionClipboardPhase) -> Void)?,
                                        onCopiedClipboard: ((SelectionCopyObservation) -> Void)?) async throws -> String {
        // Carbon fires on key-down. Don't send Command-C while the triggering chord is held.
        for _ in 0..<100 {
            try cancellation.check()
            guard environment.frontmostPID == pid else { throw ValidationError("前台应用已改变，请重新选择并触发。") }
            if !environment.shortcutIsHeld(keyCode: triggerKeyCode) { break }
            try await environment.pause(milliseconds: 20)
        }
        guard !environment.shortcutIsHeld(keyCode: triggerKeyCode) else { throw ValidationError("请松开快捷键后重新触发，以便复制选中文本。") }
        try cancellation.check()
        let saved = environment.clipboardSnapshot()
        guard environment.frontmostPID == pid else { throw ValidationError("前台应用已改变，请重新选择并触发。") }
        let marker = UUID().uuidString
        var ownedCount = 0
        var markerInstalled = false
        defer {
            if markerInstalled, environment.clipboard.changeCount == ownedCount { environment.restoreClipboard(saved) }
            onClipboardPhase?(.ended)
        }
        onClipboardPhase?(.began)
        try cancellation.check()
        guard environment.frontmostPID == pid else { throw ValidationError("前台应用已改变，请重新选择并触发。") }
        environment.installMarker(marker)
        markerInstalled = true
        ownedCount = environment.clipboard.changeCount
        // This lock defines the atomic cancellation boundary: cancellation that
        // wins it prevents posting; once posting wins, polling is allowed to drain.
        try cancellation.post { try environment.sendCopy(pid: pid) }
        var changed = false
        var firstTextPoll: Int?
        for poll in 0..<40 {
            try await environment.pause(milliseconds: 30)
            guard environment.frontmostPID == pid else { throw ValidationError("复制期间前台应用改变，请重试。") }
            let clipboard = environment.clipboard
            guard clipboard.isStable else { continue }
            if clipboard.changeCount != ownedCount {
                ownedCount = clipboard.changeCount
                changed = true
            }
            if changed, let text = clipboard.text, text != marker {
                onCopiedClipboard?(.init(types: clipboard.types, text: text, customData: clipboard.customData))
                if firstTextPoll == nil { firstTextPoll = poll }
                switch EditorClipboardMetadata.inspect(clipboard.customData) {
                case .emptySelection:
                    throw ValidationError("当前没有选中的文本。编辑器复制的整行不会被读取。")
                case .invalid:
                    throw ValidationError("编辑器提供的复制元数据无效或矛盾，请重新选择并复制。")
                case .absent:
                    // Electron's native copy workaround and extensions may only write text.
                    // Give delayed metadata a short opportunity, then accept the fresh copy.
                    if poll - (firstTextPoll ?? poll) < metadataGracePolls { continue }
                case .selection: break
                }
                return try checked(text)
            }
        }
        if changed { throw ValidationError("选择的内容不是文本，或复制尚未完成。") }
        throw ValidationError("未能复制选中文本。请确认当前应用支持 ⌘C 且已选中文本。")
    }
}
