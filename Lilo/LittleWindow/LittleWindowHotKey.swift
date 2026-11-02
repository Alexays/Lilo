import AppKit
import Carbon.HIToolbox

/// The `littleWindow.new` binding from any app, Lilo frontmost or not, following its changes. A Carbon
/// hot key, unlike an event tap, needs no Accessibility permission.
@MainActor
@safe final class LittleWindowHotKey {
    private let action: @MainActor () -> Void
    private var enabled = false
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    /// The combo registered now; nil when off, unbound, or refused.
    private(set) var combo: String?

    init(action: @escaping @MainActor () -> Void) {
        self.action = action
        // Posted from the main actor: no queue, so the hot key changes before the post returns.
        NotificationCenter.default.addObserver(forName: KeyboardShortcuts.didChange, object: nil, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.register() }
        }
    }

    isolated deinit {
        if let hotKey = unsafe hotKey { unsafe UnregisterEventHotKey(hotKey) }
        if let handler = unsafe handler { unsafe RemoveEventHandler(handler) }
    }

    func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        register()
    }

    private func register() {
        let next = enabled ? KeyboardShortcuts.bindings("littleWindow.new").first : nil
        guard next != combo else { return }
        if let hotKey = unsafe hotKey { unsafe UnregisterEventHotKey(hotKey) }
        unsafe hotKey = nil
        combo = nil
        guard let next, let stroke = KeyboardShortcuts.keyStroke(next) else { return }
        if unsafe handler == nil {
            var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            // Unretained: deinit removes the handler.
            unsafe InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
                guard let userData = unsafe userData else { return OSStatus(eventNotHandledErr) }
                let hotKey = unsafe Unmanaged<LittleWindowHotKey>.fromOpaque(userData).takeUnretainedValue()
                // Carbon delivers hot keys on the main thread's event loop.
                MainActor.assumeIsolated { hotKey.action() }
                return noErr
            }, 1, &pressed, unsafe Unmanaged.passUnretained(self).toOpaque(), &handler)
        }
        var modifiers = 0
        for (flag, carbon) in [(NSEvent.ModifierFlags.command, cmdKey), (.option, optionKey), (.control, controlKey), (.shift, shiftKey)]
            where stroke.modifiers.contains(flag) { modifiers |= carbon }
        // 'Lilo'
        let id = EventHotKeyID(signature: 0x4C69_6C6F, id: 1)
        if unsafe RegisterEventHotKey(UInt32(stroke.keyCode), UInt32(modifiers), id, GetApplicationEventTarget(), 0, &hotKey) == noErr { combo = next }
    }
}
