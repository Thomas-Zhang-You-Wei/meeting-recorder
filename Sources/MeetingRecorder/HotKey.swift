import Carbon
import Foundation

/// 全域快捷鍵。用 Carbon RegisterEventHotKey，不需要「輔助使用」權限。
final class HotKey {
    private var ref: EventHotKeyRef?
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var installed = false
    private let id: UInt32

    init?(keyCode: UInt32, modifiers: UInt32, id: UInt32, handler: @escaping () -> Void) {
        self.id = id
        HotKey.installHandlerOnce()
        HotKey.handlers[id] = handler
        let hkID = EventHotKeyID(signature: OSType(0x4D524543), id: id) // 'MREC'
        let status = RegisterEventHotKey(keyCode, modifiers, hkID, GetApplicationEventTarget(), 0, &ref)
        if status != noErr { return nil }
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        HotKey.handlers[id] = nil
    }

    private static func installHandlerOnce() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            if let h = HotKey.handlers[hk.id] { DispatchQueue.main.async { h() } }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
