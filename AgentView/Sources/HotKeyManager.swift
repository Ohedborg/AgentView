import AppKit
import Carbon

final class HotKeyManager {
  enum Kind: UInt32, CaseIterable {
    case grab = 1
    case quickChat = 2
    case threads = 3
  }

  struct Spec: Codable, Equatable {
    let keyCode: UInt32
    let modifiers: UInt32
  }

  private var hotKeyRefs: [UInt32: EventHotKeyRef] = [:]
  private var handlers: [UInt32: () -> Void] = [:]
  private var eventHandlerRef: EventHandlerRef?

  deinit {
    unregisterAll()
  }

  func register(kind: Kind, spec: Spec, handler: @escaping () -> Void) {
    unregister(kind: kind)
    ensureEventHandlerInstalled()

    var hotKeyRef: EventHotKeyRef?
    var hotKeyID = EventHotKeyID(signature: OSType(bitPattern: 0x41_56_48_4B), id: kind.rawValue) // "AVHK"
    let status = RegisterEventHotKey(
      spec.keyCode,
      spec.modifiers,
      hotKeyID,
      GetApplicationEventTarget(),
      0,
      &hotKeyRef
    )
    guard status == noErr, let hotKeyRef else {
      NSLog("RegisterEventHotKey failed: \(status)")
      return
    }

    hotKeyRefs[kind.rawValue] = hotKeyRef
    handlers[kind.rawValue] = handler
  }

  func unregister(kind: Kind) {
    if let hotKeyRef = hotKeyRefs[kind.rawValue] {
      UnregisterEventHotKey(hotKeyRef)
    }
    hotKeyRefs[kind.rawValue] = nil
    handlers[kind.rawValue] = nil
    if hotKeyRefs.isEmpty {
      uninstallEventHandlerIfNeeded()
    }
  }

  func unregisterAll() {
    for (_, ref) in hotKeyRefs {
      UnregisterEventHotKey(ref)
    }
    hotKeyRefs.removeAll()
    handlers.removeAll()
    uninstallEventHandlerIfNeeded()
  }

  private func ensureEventHandlerInstalled() {
    guard eventHandlerRef == nil else { return }

    var eventType = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard),
      eventKind: UInt32(kEventHotKeyPressed)
    )

    let handlerUPP: EventHandlerUPP = { _, event, userData in
      guard let event, let userData else { return noErr }
      let mgr = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()

      var hotKeyID = EventHotKeyID()
      let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
      )
      guard status == noErr else { return noErr }
      mgr.handleHotKeyPressed(id: hotKeyID.id)
      return noErr
    }

    let installStatus = InstallEventHandler(
      GetApplicationEventTarget(),
      handlerUPP,
      1,
      &eventType,
      UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
      &eventHandlerRef
    )
    if installStatus != noErr {
      NSLog("InstallEventHandler failed: \(installStatus)")
    }
  }

  private func uninstallEventHandlerIfNeeded() {
    if let eventHandlerRef {
      RemoveEventHandler(eventHandlerRef)
      self.eventHandlerRef = nil
    }
  }

  private func handleHotKeyPressed(id: UInt32) {
    guard let cb = handlers[id] else { return }
    DispatchQueue.main.async { cb() }
  }
}


