import AppKit
import Carbon.HIToolbox

/// A system-wide shortcut.
///
/// Carbon's `RegisterEventHotKey` is still the only way to claim a global
/// shortcut without asking for the Accessibility permission a CGEventTap needs.
///
/// Two structural facts this class encodes, both learned the hard way:
/// 1. The Carbon *event handler* is installed **once per process**. Installing
///    one per instance fails with OSStatus -9866 the moment a second hotkey
///    exists — which is exactly how the expand/collapse shortcut shipped
///    silently dead. Per-key registration only adds a hot-key reference; the
///    handler dispatches by id to the right instance.
/// 2. The callback is a C function pointer and cannot capture context, so the
///    per-key actions live in a type-level box keyed by hotkey id.
final class GlobalHotkey {
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var nextIdentifier: UInt32 = 1
    private static var handlerReference: EventHandlerRef?

    /// Installs the shared dispatcher exactly once per process. Returns false
    /// only if Carbon refuses, which leaves every registration non-functional
    /// and is reported by diagnostics.
    private static func ensureHandlerInstalled() -> Bool {
        guard handlerReference == nil else { return true }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        var reference: EventHandlerRef?
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr else { return status }
            DispatchQueue.main.async { GlobalHotkey.handlers[id.id]?() }
            return noErr
        }, 1, &type, nil, &reference)
        guard status == noErr else {
            NSLog("DockDeck: could not install the hotkey handler (OSStatus %d)", status)
            return false
        }
        handlerReference = reference
        return true
    }

    private var reference: EventHotKeyRef?
    private var identifier: UInt32 = 0
    /// True while a hot key is actually registered with Carbon — a failed
    /// registration is otherwise indistinguishable from a working one.
    private(set) var isRegistered = false

    /// 'DKDK' — four-char signature identifying this app's hotkeys to Carbon.
    private let signature: FourCharCode = 0x444B444B

    deinit { unregister() }

    @discardableResult
    func register(_ shortcut: Shortcut, action: @escaping () -> Void) -> Bool {
        register(keyCode: shortcut.keyCode, modifiers: shortcut.carbonModifiers, action: action)
    }

    @discardableResult
    func register(keyCode: UInt32 = UInt32(kVK_ANSI_D),
                  modifiers: UInt32 = UInt32(optionKey | shiftKey),
                  action: @escaping () -> Void) -> Bool {
        unregister()
        guard Self.ensureHandlerInstalled() else { return false }
        identifier = Self.nextIdentifier
        Self.nextIdentifier += 1
        Self.handlers[identifier] = action

        let hotKeyID = EventHotKeyID(signature: signature, id: identifier)
        var newReference: EventHotKeyRef?
        let registerStatus = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &newReference)
        guard registerStatus == noErr else {
            // Almost always because another app already owns the combination.
            NSLog("DockDeck: hotkey registration failed (OSStatus %d) — the shortcut is probably taken", registerStatus)
            Self.handlers[identifier] = nil
            identifier = 0
            isRegistered = false
            return false
        }
        reference = newReference
        isRegistered = true
        return true
    }

    func unregister() {
        if let reference { UnregisterEventHotKey(reference); self.reference = nil }
        if identifier != 0 { Self.handlers[identifier] = nil; identifier = 0 }
        isRegistered = false
        // The shared dispatcher stays installed for the process lifetime:
        // removing it would race a concurrent registration, and it costs
        // nothing while no hot key is registered.
    }
}
