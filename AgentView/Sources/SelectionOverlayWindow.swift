import AppKit

final class SelectionOverlayWindow: NSWindow {
  var onFinish: ((CGRect) -> Void)?
  var onCancel: (() -> Void)?

  private let overlayView: SelectionOverlayView

  init(frame: CGRect) {
    // The window is placed in global screen coordinates; the view must be local to the window (origin 0,0).
    overlayView = SelectionOverlayView(frame: CGRect(origin: .zero, size: frame.size))

    super.init(
      contentRect: frame,
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )

    isOpaque = false
    backgroundColor = NSColor.clear
    level = .screenSaver
    // Show on the active Space/desktop where the user is.
    collectionBehavior = [.moveToActiveSpace, .transient, .ignoresCycle, .fullScreenAuxiliary]
    ignoresMouseEvents = false
    hasShadow = false
    isReleasedWhenClosed = false

    contentView = overlayView

    overlayView.onCancel = { [weak self] in self?.onCancel?() }
    overlayView.onFinish = { [weak self] cocoaGlobalRect in self?.onFinish?(cocoaGlobalRect) }
  }

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { true }
}


