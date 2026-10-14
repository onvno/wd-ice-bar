import Carbon

/// A registered hot key does not require keyboard monitoring or Accessibility permission.
@MainActor
final class MenuBarHotKey {
    private var hotKey: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var action: (() -> Void)?

    @discardableResult
    func register(action: @escaping () -> Void) -> Bool {
        unregister()
        self.action = action
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let handlerStatus = InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return OSStatus(eventNotHandledErr) }
            let receiver = Unmanaged<MenuBarHotKey>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in receiver.action?() }
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
        guard handlerStatus == noErr else { unregister(); return false }
        let id = EventHotKeyID(signature: 0x57444943, id: 1)
        let status = RegisterEventHotKey(UInt32(kVK_ANSI_I), UInt32(controlKey | optionKey | cmdKey),
                                         id, GetApplicationEventTarget(), 0, &hotKey)
        guard status == noErr else { unregister(); return false }
        return true
    }

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
        hotKey = nil
        eventHandler = nil
        action = nil
    }
}
