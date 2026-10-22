import Foundation
import Combine

/// Valid edits are persisted automatically; temporary invalid input keeps the last valid configuration.
@MainActor public final class SettingsEditor: ObservableObject {
    @Published public var draft: Configuration {
        didSet {
            guard !suppressDraftSave, oldValue != draft else { return }
            let immediate = oldValue.copyFallback != draft.copyFallback || oldValue.apiMode != draft.apiMode || oldValue.language != draft.language ||
                oldValue.presets.map(\.shortcut) != draft.presets.map(\.shortcut) || oldValue.presets.map(\.id) != draft.presets.map(\.id)
            if immediate { flush() } else { scheduleSave() }
        }
    }
    @Published public var apiKeyInput = "" { didSet { if oldValue != apiKeyInput { scheduleSave() } } }
    @Published public var hasKey: Bool
    @Published public var error: String?
    @Published public private(set) var lastDeletedPreset: Preset?
    private let save: (Configuration, String) throws -> Void
    private let deleteKey: () throws -> Void
    private let saveDelay: Duration
    private var pending: Task<Void, Never>?
    private var saved: Configuration
    private var savedKeyInput = ""
    private var deletingKey = false
    private var suppressDraftSave = false
    private var savingPresetTransaction = false
    private var deletedPresetIndex: Int?

    public init(configuration: Configuration, hasKey: Bool = false, saveDelay: Duration = .milliseconds(300),
                save: @escaping (Configuration, String) throws -> Void, deleteKey: @escaping () throws -> Void) {
        draft = configuration; saved = configuration; self.hasKey = hasKey
        self.saveDelay = saveDelay; self.save = save; self.deleteKey = deleteKey
    }
    private func scheduleSave() {
        guard !deletingKey else { return }
        pending?.cancel()
        pending = Task { @MainActor [weak self, saveDelay] in
            do { try await Task.sleep(for: saveDelay) } catch { return }
            self?.flush()
        }
    }
    public func flush() {
        pending?.cancel(); pending = nil
        do {
            var candidate = draft
            candidate.model = candidate.model.trimmingCharacters(in: .whitespacesAndNewlines)
            candidate.apiBaseURL = try APIEndpoint(candidate.apiBaseURL).normalizedURL
            try candidate.validate()
            let key = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
            let keyChanged = !savingPresetTransaction && !key.isEmpty && key != savedKeyInput
            guard candidate != saved || keyChanged else { error = nil; return }
            try save(candidate, keyChanged ? key : "")
            saved = candidate
            if keyChanged { savedKeyInput = key; hasKey = true }
            error = nil
        } catch { self.error = error.localizedDescription }
    }
    /// Adds a custom preset with a free shortcut, keeping an undoable shortcut free when possible.
    @discardableResult public func addPreset() -> UUID? {
        let occupied = Set(draft.presets.map { $0.shortcut.identity })
        let available = Self.presetShortcutCandidates.filter { !occupied.contains($0.identity) }
        let deletedShortcut = lastDeletedPreset?.shortcut.identity
        guard let shortcut = available.first(where: { $0.identity != deletedShortcut }) ?? available.first else {
            error = L10n.string("没有可用的预设快捷键，请先释放一个 Control + Option 数字组合。", language: draft.language)
            return nil
        }
        let preset = Preset(name: L10n.string("新预设", language: draft.language),
                            prompt: L10n.string("请处理用户提供的文本。", language: draft.language), shortcut: shortcut)
        var candidate = draft
        candidate.presets.append(preset)
        return persistPresetTransaction(candidate) ? preset.id : nil
    }
    /// Deletes one preset and retains its complete contents and position for a single undo.
    @discardableResult public func deletePreset(id: UUID) -> Bool {
        guard let index = draft.presets.firstIndex(where: { $0.id == id }) else { return false }
        guard draft.presets.count > 1 else {
            error = L10n.string("至少保留一个预设。", language: draft.language)
            return false
        }
        var candidate = draft
        let deleted = candidate.presets.remove(at: index)
        guard persistPresetTransaction(candidate) else { return false }
        deletedPresetIndex = index
        lastDeletedPreset = deleted
        return true
    }
    /// Restores the last deletion without replacing later edits or remapping its original shortcut.
    @discardableResult public func undoDeletePreset() -> UUID? {
        guard let preset = lastDeletedPreset, let index = deletedPresetIndex else { return nil }
        guard !draft.presets.contains(where: { $0.id == preset.id }) else {
            error = L10n.string("无法撤销删除：此预设已存在。", language: draft.language)
            return nil
        }
        guard !draft.presets.contains(where: { $0.shortcut.identity == preset.shortcut.identity }) else {
            error = L10n.string("无法撤销删除：原快捷键已被其他预设使用，请先更改该快捷键。", language: draft.language)
            return nil
        }
        var candidate = draft
        candidate.presets.insert(preset, at: min(index, candidate.presets.count))
        guard persistPresetTransaction(candidate) else { return nil }
        dismissDeletedPreset()
        return preset.id
    }
    public func dismissDeletedPreset() {
        lastDeletedPreset = nil
        deletedPresetIndex = nil
    }
    private func persistPresetTransaction(_ candidate: Configuration) -> Bool {
        do { try candidate.validate() } catch { self.error = error.localizedDescription; return false }
        let previousDraft = draft
        defer {
            // A preset save must leave credential text to its own debounce, including after rollback.
            let pendingKey = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
            if !pendingKey.isEmpty && pendingKey != savedKeyInput { scheduleSave() }
        }
        savingPresetTransaction = true
        draft = candidate
        savingPresetTransaction = false
        guard error == nil else {
            suppressDraftSave = true; draft = previousDraft; suppressDraftSave = false
            return false
        }
        return true
    }
    private static let presetShortcutCandidates: [Shortcut] = {
        let digitCodes: [UInt32] = [18, 19, 20, 21, 23, 22, 26, 28, 25, 29]
        return [UInt32(6144), UInt32(6656)].flatMap { modifiers in
            digitCodes.enumerated().map { index, keyCode in
                Shortcut(keyCode: keyCode, modifiers: modifiers,
                         label: "⌃⌥\(modifiers == 6656 ? "⇧" : "")\((index + 1) % 10)")
            }
        }
    }()
    /// Updates only untouched default content; identity, order, shortcuts, and custom edits survive.
    @discardableResult public func changeLanguage(to language: AppLanguage) -> Bool {
        guard language != draft.language else { return true }
        let previousDraft = draft
        var candidate = previousDraft
        let previousDefaults = Preset.defaults(for: previousDraft.language)
        let nextDefaults = Preset.defaults(for: language)
        for index in candidate.presets.indices {
            guard let builtIn = candidate.presets[index].builtIn,
                  let oldDefault = previousDefaults.first(where: { $0.builtIn == builtIn }),
                  let newDefault = nextDefaults.first(where: { $0.builtIn == builtIn }) else { continue }
            if candidate.presets[index].name == oldDefault.name { candidate.presets[index].name = newDefault.name }
            if candidate.presets[index].prompt == oldDefault.prompt { candidate.presets[index].prompt = newDefault.prompt }
        }
        candidate.language = language
        do { try candidate.validate() } catch { self.error = error.localizedDescription; return false }
        defer {
            // The configuration transaction must not consume credential text awaiting its own debounce.
            let pendingKey = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
            if !pendingKey.isEmpty && pendingKey != savedKeyInput { scheduleSave() }
        }
        savingPresetTransaction = true
        draft = candidate
        savingPresetTransaction = false
        guard error == nil else {
            suppressDraftSave = true; draft = previousDraft; suppressDraftSave = false
            return false
        }
        L10n.currentLanguage = language
        return true
    }
    /// Adds only missing defaults, preserving every existing preset and its edits.
    @discardableResult public func restoreDefaultPresets() -> [UUID] {
        var candidate = draft
        var added: [UUID] = []
        var occupied = Set(candidate.presets.map { $0.shortcut.identity })
        for var preset in Preset.defaults(for: candidate.language) {
            guard !candidate.presets.contains(where: { $0.builtIn == preset.builtIn || $0.id == preset.id }) else { continue }
            if occupied.contains(preset.shortcut.identity) {
                guard let available = Self.presetShortcutCandidates.first(where: { !occupied.contains($0.identity) }) else {
                    error = L10n.string("没有可用的恢复快捷键，请先释放一个 Control + Option 数字组合。", language: candidate.language)
                    return []
                }
                preset.shortcut = available
            }
            occupied.insert(preset.shortcut.identity)
            candidate.presets.append(preset); added.append(preset.id)
        }
        guard !added.isEmpty else { return [] }
        do { try candidate.validate() } catch { self.error = error.localizedDescription; return [] }
        let previousDraft = draft
        savingPresetTransaction = true
        draft = candidate // A single immediate save for the complete restoration.
        savingPresetTransaction = false
        guard error == nil else {
            suppressDraftSave = true; draft = previousDraft; suppressDraftSave = false
            return []
        }
        return added
    }
    /// Moves an existing preset by one place and persists the complete order atomically.
    @discardableResult public func movePreset(id: UUID, by distance: Int) -> Bool {
        guard distance == -1 || distance == 1,
              let index = draft.presets.firstIndex(where: { $0.id == id }) else { return false }
        let destination = index + distance
        guard draft.presets.indices.contains(destination) else { return false }
        let previousDraft = draft
        var candidate = previousDraft
        candidate.presets.swapAt(index, destination)
        do { try candidate.validate() } catch { self.error = error.localizedDescription; return false }
        defer {
            // The immediate order save cancels the previous debounce; resume unrelated credential typing.
            let pendingKey = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
            if !pendingKey.isEmpty && pendingKey != savedKeyInput { scheduleSave() }
        }
        savingPresetTransaction = true
        draft = candidate
        savingPresetTransaction = false
        guard error == nil else {
            suppressDraftSave = true; draft = previousDraft; suppressDraftSave = false
            return false
        }
        return true
    }
    public func deleteCredential() {
        pending?.cancel(); pending = nil
        do {
            try deleteKey()
            deletingKey = true; apiKeyInput = ""; deletingKey = false
            savedKeyInput = ""; hasKey = false; error = nil
            flush()
        } catch { self.error = error.localizedDescription }
    }
    deinit { pending?.cancel() }
}
