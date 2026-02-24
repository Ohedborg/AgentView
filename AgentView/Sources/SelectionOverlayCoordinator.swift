import AppKit

final class SelectionOverlayCoordinator: NSObject {
  private(set) var isActive: Bool = false

  private var window: SelectionOverlayWindow?
  private var keyMonitor: Any?
  private var completion: ((CGRect?) -> Void)?

  func beginSelection(completion: @escaping (CGRect?) -> Void) {
    guard !isActive else { return }
    isActive = true
    self.completion = completion

    let unionFrame = NSScreen.screens.reduce(CGRect.zero) { $0.union($1.frame) }
    let overlayWindow = SelectionOverlayWindow(frame: unionFrame)
    self.window = overlayWindow

    overlayWindow.onCancel = { [weak self] in self?.finish(rect: nil) }
    overlayWindow.onFinish = { [weak self] rect in self?.finish(rect: rect) }

    // Escape to cancel.
    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
      guard let self else { return event }
      if event.keyCode == 53 { // Esc
        self.finish(rect: nil)
        return nil
      }
      return event
    }

    NSApp.activate(ignoringOtherApps: true)
    overlayWindow.makeKeyAndOrderFront(nil)
  }

  private func finish(rect: CGRect?) {
    if let keyMonitor {
      NSEvent.removeMonitor(keyMonitor)
      self.keyMonitor = nil
    }

    window?.orderOut(nil)
    window = nil

    isActive = false
    let cb = completion
    completion = nil
    cb?(rect)
  }
}


