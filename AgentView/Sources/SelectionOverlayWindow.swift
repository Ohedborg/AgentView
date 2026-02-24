import AppKit

final class SelectionOverlayWindow: NSWindow {
  var onFinish: ((CGRect) -> Void)?
  var onCancel: (() -> Void)?

  private let overlayView: SelectionOverlayView

  init(frame: CGRect) {
    overlayView = SelectionOverlayView(frame: frame)

    super.init(
      contentRect: frame,
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )

    isOpaque = false
    backgroundColor = NSColor.clear
    level = .screenSaver
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    ignoresMouseEvents = false
    hasShadow = false

    contentView = overlayView

    overlayView.onCancel = { [weak self] in self?.onCancel?() }
    overlayView.onFinish = { [weak self] cocoaGlobalRect in self?.onFinish?(cocoaGlobalRect) }
  }

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { true }
}


