import AppKit

final class SelectionOverlayView: NSView {
  var onFinish: ((CGRect) -> Void)?
  var onCancel: (() -> Void)?

  private var startPoint: CGPoint?
  private var currentPoint: CGPoint?
  private var isDragging: Bool = false

  override var acceptsFirstResponder: Bool { true }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    window?.makeFirstResponder(self)
  }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)

    // Dim background slightly (fill full bounds for consistency).
    NSColor.black.withAlphaComponent(0.18).setFill()
    bounds.fill()

    guard let selectionRect = selectionRectInViewCoordinates() else { return }

    // Clear selection interior (so you can see the screen more clearly).
    NSColor.clear.setFill()
    selectionRect.fill(using: .clear)

    // Draw outline.
    let path = NSBezierPath(rect: selectionRect)
    path.lineWidth = 2
    NSColor.systemBlue.setStroke()
    path.stroke()

    // Draw helper text.
    let text = "Drag to select • Release to capture • Esc to cancel"
    let attrs: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
      .foregroundColor: NSColor.white
    ]
    let size = (text as NSString).size(withAttributes: attrs)
    let origin = CGPoint(x: 16, y: bounds.height - size.height - 16)
    (text as NSString).draw(at: origin, withAttributes: attrs)
  }

  override func mouseDown(with event: NSEvent) {
    let p = convert(event.locationInWindow, from: nil)
    startPoint = p
    currentPoint = p
    isDragging = true
    needsDisplay = true
  }

  override func mouseDragged(with event: NSEvent) {
    guard isDragging else { return }
    currentPoint = convert(event.locationInWindow, from: nil)
    needsDisplay = true
  }

  override func mouseUp(with event: NSEvent) {
    guard isDragging else { return }
    currentPoint = convert(event.locationInWindow, from: nil)
    isDragging = false
    needsDisplay = true

    guard let window, let selectionInView = selectionRectInViewCoordinates(), selectionInView.width >= 3, selectionInView.height >= 3 else {
      onCancel?()
      return
    }

    // Convert selection rect to cocoa global screen coordinates.
    let selectionInWindow = convert(selectionInView, to: nil)
    let cocoaGlobalRect = window.convertToScreen(selectionInWindow).standardized
    onFinish?(cocoaGlobalRect)
  }

  override func keyDown(with event: NSEvent) {
    // Esc is handled by a local monitor in the coordinator, but keep this as a fallback.
    if event.keyCode == 53 {
      onCancel?()
      return
    }
    super.keyDown(with: event)
  }

  private func selectionRectInViewCoordinates() -> CGRect? {
    guard let startPoint, let currentPoint else { return nil }
    return CGRect(
      x: min(startPoint.x, currentPoint.x),
      y: min(startPoint.y, currentPoint.y),
      width: abs(startPoint.x - currentPoint.x),
      height: abs(startPoint.y - currentPoint.y)
    )
  }
}


