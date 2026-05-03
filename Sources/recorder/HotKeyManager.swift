import AppKit
import Carbon.HIToolbox

final class HotKeyManager {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private let callback: () -> Void

    init(_ callback: @escaping () -> Void) {
        self.callback = callback
        register()
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let eventHandlerRef { RemoveEventHandler(eventHandlerRef) }
    }

    private func register() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, _, userData -> OSStatus in
                guard let userData else { return noErr }
                let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
                manager.callback()
                return noErr
            },
            1,
            &eventType,
            selfPtr,
            &eventHandlerRef
        )

        // 'rcdr' signature
        let signature: OSType = 0x72636472
        let hotKeyID = EventHotKeyID(signature: signature, id: 1)
        let modifiers = UInt32(cmdKey | shiftKey)
        let keyCode = UInt32(kVK_ANSI_2)

        RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &hotKeyRef
        )
    }
}
