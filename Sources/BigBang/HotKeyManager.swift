import AppKit
import Carbon
import BigBangCore

@MainActor final class HotKeyManager {
    private var refs: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    private var presets: [Preset] = []
    private var paused = false
    var onTrigger: ((Preset) -> Void)?
    private let signature: OSType = 0x42424E47

    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard result == noErr else { return result }
            let manager = Unmanaged<HotKeyManager>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { manager.trigger(id) }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }
    func register(_ newPresets: [Preset]) throws {
        if paused || (refs.count == newPresets.count && presets.map(\.shortcut) == newPresets.map(\.shortcut)) {
            presets = newPresets
            return
        }
        let old = presets
        unregister()
        do { try install(newPresets) }
        catch {
            unregister()
            try? install(old)
            throw error
        }
    }
    func pause() {
        guard !paused else { return }
        paused = true
        let saved = presets
        unregister()
        presets = saved
    }
    func resume() throws {
        guard paused else { return }
        paused = false
        let saved = presets
        unregister()
        do { try install(saved) }
        catch { unregister(); presets = saved; throw error }
    }
    private func install(_ list: [Preset]) throws {
        for (index, preset) in list.enumerated() {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: signature, id: UInt32(index + 1))
            let status = RegisterEventHotKey(preset.shortcut.keyCode, preset.shortcut.modifiers, id, GetApplicationEventTarget(), 0, &ref)
            guard status == noErr, let ref else { throw ValidationError(format: "无法注册 %@（%@），可能被其他应用占用。请修改快捷键。", arguments: [preset.shortcut.label, String(status)]) }
            refs.append(ref)
        }
        presets = list
    }
    private func unregister() {
        for ref in refs { UnregisterEventHotKey(ref) }
        refs.removeAll(); presets.removeAll()
    }
    private func trigger(_ id: EventHotKeyID) {
        guard !paused, id.signature == signature, id.id > 0, Int(id.id) <= presets.count else { return }
        onTrigger?(presets[Int(id.id) - 1])
    }
}
