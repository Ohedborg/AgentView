import AppKit
import Carbon
import SwiftUI

@MainActor
enum HotKeyRecorderPanel {
  static func present(title: String, onPicked: @escaping (HotKeyManager.Spec) -> Void) {
    let panel = RecorderWindowController(title: title, onPicked: onPicked)
    panel.show()
  }
}

@MainActor
private final class RecorderWindowController: NSWindowController, NSWindowDelegate {
  private let onPicked: (HotKeyManager.Spec) -> Void
  private var isDone = false

  init(title: String, onPicked: @escaping (HotKeyManager.Spec) -> Void) {
    self.onPicked = onPicked

    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 420, height: 170),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false
    )
    panel.title = title
    panel.isFloatingPanel = true
    panel.level = .floating
    panel.collectionBehavior = [.moveToActiveSpace, .transient, .ignoresCycle]
    panel.titlebarAppearsTransparent = true
    panel.isMovableByWindowBackground = true

    super.init(window: panel)
    panel.delegate = self

    let view = RecorderView(
      title: title,
      onCancel: { [weak self] in
        self?.close()
      },
      onPicked: { [weak self] spec in
        guard let self else { return }
        guard !self.isDone else { return }
        self.isDone = true
        self.onPicked(spec)
        self.close()
      }
    )
    let hosting = NSHostingController(rootView: view)
    panel.contentViewController = hosting
  }

  required init?(coder: NSCoder) { nil }

  func show() {
    showWindow(nil)
    window?.center()
    window?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }
}

private struct RecorderView: View {
  let title: String
  let onCancel: () -> Void
  let onPicked: (HotKeyManager.Spec) -> Void

  @State private var lastDisplay: String = "Press a shortcut…"

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(title)
        .font(.system(size: 16, weight: .semibold))
      Text("Press the new shortcut now. Press Esc to cancel.")
        .foregroundStyle(.secondary)
        .font(.callout)

      KeyCaptureView { keyCode, flags in
        if keyCode == UInt16(kVK_Escape) {
          onCancel()
          return
        }
        let spec = HotKeyManager.Spec(
          keyCode: UInt32(keyCode),
          modifiers: carbonModifiers(from: flags)
        )
        lastDisplay = hotKeyDisplay(spec)
        onPicked(spec)
      }
      .frame(height: 46)

      Text(lastDisplay)
        .font(.system(size: 13, design: .monospaced))
        .foregroundStyle(.secondary)

      HStack {
        Spacer()
        Button("Cancel", action: onCancel)
          .keyboardShortcut(.cancelAction)
      }
    }
    .padding(16)
    .background(.regularMaterial)
  }

  private func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
    var m: UInt32 = 0
    if flags.contains(.command) { m |= UInt32(cmdKey) }
    if flags.contains(.shift) { m |= UInt32(shiftKey) }
    if flags.contains(.option) { m |= UInt32(optionKey) }
    if flags.contains(.control) { m |= UInt32(controlKey) }
    return m
  }

  private func hotKeyDisplay(_ spec: HotKeyManager.Spec) -> String {
    // Reuse AppSettings rendering logic by matching its symbols.
    var parts: [String] = []
    let m = spec.modifiers
    if (m & UInt32(cmdKey)) != 0 { parts.append("⌘") }
    if (m & UInt32(shiftKey)) != 0 { parts.append("⇧") }
    if (m & UInt32(optionKey)) != 0 { parts.append("⌥") }
    if (m & UInt32(controlKey)) != 0 { parts.append("⌃") }
    parts.append(keyDisplay(keyCode: spec.keyCode))
    return parts.joined()
  }

  private func keyDisplay(keyCode: UInt32) -> String {
    switch Int(keyCode) {
    case kVK_ANSI_A: return "A"
    case kVK_ANSI_B: return "B"
    case kVK_ANSI_C: return "C"
    case kVK_ANSI_D: return "D"
    case kVK_ANSI_E: return "E"
    case kVK_ANSI_F: return "F"
    case kVK_ANSI_G: return "G"
    case kVK_ANSI_H: return "H"
    case kVK_ANSI_I: return "I"
    case kVK_ANSI_J: return "J"
    case kVK_ANSI_K: return "K"
    case kVK_ANSI_L: return "L"
    case kVK_ANSI_M: return "M"
    case kVK_ANSI_N: return "N"
    case kVK_ANSI_O: return "O"
    case kVK_ANSI_P: return "P"
    case kVK_ANSI_Q: return "Q"
    case kVK_ANSI_R: return "R"
    case kVK_ANSI_S: return "S"
    case kVK_ANSI_T: return "T"
    case kVK_ANSI_U: return "U"
    case kVK_ANSI_V: return "V"
    case kVK_ANSI_W: return "W"
    case kVK_ANSI_X: return "X"
    case kVK_ANSI_Y: return "Y"
    case kVK_ANSI_Z: return "Z"
    case kVK_ANSI_1: return "1"
    case kVK_ANSI_2: return "2"
    case kVK_ANSI_3: return "3"
    case kVK_ANSI_4: return "4"
    case kVK_ANSI_5: return "5"
    case kVK_ANSI_6: return "6"
    case kVK_ANSI_7: return "7"
    case kVK_ANSI_8: return "8"
    case kVK_ANSI_9: return "9"
    case kVK_ANSI_0: return "0"
    case kVK_Space: return "Space"
    case kVK_Return: return "↩"
    case kVK_Escape: return "⎋"
    case kVK_Tab: return "⇥"
    case kVK_Delete: return "⌫"
    default:
      return "Key\(keyCode)"
    }
  }
}

private struct KeyCaptureView: NSViewRepresentable {
  typealias NSViewType = CaptureNSView
  let onKeyDown: (UInt16, NSEvent.ModifierFlags) -> Void

  func makeNSView(context: Context) -> CaptureNSView {
    let v = CaptureNSView()
    v.onKeyDown = onKeyDown
    return v
  }

  func updateNSView(_ nsView: CaptureNSView, context: Context) {
    nsView.onKeyDown = onKeyDown
    DispatchQueue.main.async {
      nsView.window?.makeFirstResponder(nsView)
    }
  }
}

private final class CaptureNSView: NSView {
  var onKeyDown: ((UInt16, NSEvent.ModifierFlags) -> Void)?

  override var acceptsFirstResponder: Bool { true }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    window?.makeFirstResponder(self)
  }

  override func keyDown(with event: NSEvent) {
    onKeyDown?(event.keyCode, event.modifierFlags)
  }

  override func draw(_ dirtyRect: NSRect) {
    NSColor.controlBackgroundColor.setFill()
    dirtyRect.fill()

    let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 10, yRadius: 10)
    NSColor.separatorColor.setStroke()
    path.lineWidth = 1
    path.stroke()

    let attrs: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 13, weight: .medium),
      .foregroundColor: NSColor.secondaryLabelColor
    ]
    let s = "Press keys here"
    let size = s.size(withAttributes: attrs)
    let p = NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2)
    s.draw(at: p, withAttributes: attrs)
  }
}

