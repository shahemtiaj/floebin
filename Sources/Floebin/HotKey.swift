import AppKit
import Carbon

/// A system-wide keyboard shortcut that opens the recent list at the mouse pointer.
/// Uses the classic Carbon hot key API: no Accessibility permission needed.
@MainActor
enum HotKeyCenter {

    struct Preset {
        let title: String
        let keyCode: UInt32
        let modifiers: UInt32
    }

    /// Index 0 = off. Stored in settings by index.
    static let presets: [Preset] = [
        Preset(title: "Off", keyCode: 0, modifiers: 0),
        Preset(title: "⌃⌥D", keyCode: UInt32(kVK_ANSI_D), modifiers: UInt32(controlKey | optionKey)),
        Preset(title: "⌃⌥Space", keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | optionKey)),
        Preset(title: "⌥⇧D", keyCode: UInt32(kVK_ANSI_D), modifiers: UInt32(optionKey | shiftKey)),
        Preset(title: "⌃⇧Space", keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | shiftKey)),
        Preset(title: "⌃⌥⌘V", keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(controlKey | optionKey | cmdKey))
    ]

    static let defaultPreset = 1

    /// What the shortcut does.
    static var action: (() -> Void)?

    private static var hotKeyRef: EventHotKeyRef?
    private static var handlerInstalled = false

    /// Registers the preset (0 = off). Returns false if another app already owns that shortcut.
    @discardableResult
    static func register(presetIndex: Int) -> Bool {
        unregister()
        guard presetIndex > 0, presetIndex < presets.count else { return true }
        installHandlerIfNeeded()

        let preset = presets[presetIndex]
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x464C_4F45), id: 1) // "FLOE"
        let status = RegisterEventHotKey(preset.keyCode, preset.modifiers, id, GetApplicationEventTarget(), 0, &ref)
        guard status == OSStatus(noErr), let ref else { return false }
        hotKeyRef = ref
        return true
    }

    static func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
    }

    static func fire() {
        action?()
    }

    private static func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        _ = InstallEventHandler(GetApplicationEventTarget(), floebinHotKeyHandler, 1, &spec, nil, nil)
        handlerInstalled = true
    }
}

/// C callback for the hot key; hops to the main thread.
private func floebinHotKeyHandler(_ call: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    DispatchQueue.main.async {
        MainActor.assumeIsolated {
            HotKeyCenter.fire()
        }
    }
    return OSStatus(noErr)
}
