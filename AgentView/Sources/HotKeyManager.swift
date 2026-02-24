import AppKit
import Carbon

final class HotKeyManager {
  var onHotKey: (() -> Void)?

  private var hotKeyRef: EventHotKeyRef?
  private var eventHandlerRef: EventHandlerRef?

  deinit {
    unregister()
  }

  func registerCmdG() {
    unregister()

    // Key code for "G" on US keyboard layout.
    // If you want a different key, change this + the modifier flags below.
    let keyCode: UInt32 = UInt32(kVK_ANSI_G)
    let modifiers: UInt32 = UInt32(cmdKey) // Command only

    var hotKeyID = EventHotKeyID(signature: OSType(bitPattern: 0x4D_47_52_42), id: 1) // "MGRB"

    let status = RegisterEventHotKey(
      keyCode,
      modifiers,
      hotKeyID,
      GetApplicationEventTarget(),
      0,
      &hotKeyRef
    )

    guard status == noErr else {
      NSLog("RegisterEventHotKey failed: \(status)")
      return
    }

    // Install handler for hotkey events.
    var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    let handler: EventHandlerUPP = { _, _, userData in
      let mgr = Unmanaged<HotKeyManager>.fromOpaque(userData!).takeUnretainedValue()
      DispatchQueue.main.async { mgr.onHotKey?() }
      return noErr
    }

    let installStatus = InstallEventHandler(
      GetApplicationEventTarget(),
      handler,
      1,
      &eventType,
      UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
      &eventHandlerRef
    )

    if installStatus != noErr {
      NSLog("InstallEventHandler failed: \(installStatus)")
    }
  }

  private func unregister() {
    if let hotKeyRef {
      UnregisterEventHotKey(hotKeyRef)
      self.hotKeyRef = nil
    }
    if let eventHandlerRef {
      RemoveEventHandler(eventHandlerRef)
      self.eventHandlerRef = nil
    }
  }
}


