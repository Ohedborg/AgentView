import AppKit

final class ResultWindowController: NSWindowController, NSWindowDelegate {
  private let textView = NSTextView()
  private let scrollView = NSScrollView()
  private let copyButton = NSButton(title: "Copy", target: nil, action: nil)
  private let closeButton = NSButton(title: "Close", target: nil, action: nil)

  static func present(title: String, text: String) {
    let wc = ResultWindowController(title: title, text: text)
    wc.showWindow(nil)
    wc.window?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  init(title: String, text: String) {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false
    )
    window.title = title
    window.center()
    window.isMovableByWindowBackground = true
    window.titlebarAppearsTransparent = true
    window.toolbarStyle = .unifiedCompact

    super.init(window: window)
    window.delegate = self

    setupUI(text: text)
  }

  required init?(coder: NSCoder) {
    nil
  }

  private func setupUI(text: String) {
    guard let window else { return }

    let backgroundView = NSVisualEffectView()
    backgroundView.material = .underWindowBackground
    backgroundView.blendingMode = .behindWindow
    backgroundView.state = .active
    backgroundView.translatesAutoresizingMaskIntoConstraints = false

    window.contentView = backgroundView

    textView.isRichText = false
    textView.isEditable = false
    textView.isSelectable = true
    textView.string = text
    textView.font = NSFont.systemFont(ofSize: 13)
    textView.textContainerInset = NSSize(width: 10, height: 10)
    textView.drawsBackground = true
    textView.backgroundColor = .clear
    textView.textColor = .labelColor

    scrollView.documentView = textView
    scrollView.hasVerticalScroller = true
    scrollView.borderType = .noBorder
    scrollView.scrollerStyle = .overlay
    scrollView.drawsBackground = false
    scrollView.translatesAutoresizingMaskIntoConstraints = false

    let textContainer = NSView()
    textContainer.wantsLayer = true
    textContainer.layer?.cornerRadius = 12
    textContainer.layer?.cornerCurve = .continuous
    textContainer.layer?.borderWidth = 1
    textContainer.layer?.borderColor = NSColor.separatorColor.cgColor
    textContainer.layer?.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.8).cgColor
    textContainer.translatesAutoresizingMaskIntoConstraints = false
    textContainer.addSubview(scrollView)

    NSLayoutConstraint.activate([
      scrollView.leadingAnchor.constraint(equalTo: textContainer.leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: textContainer.trailingAnchor),
      scrollView.topAnchor.constraint(equalTo: textContainer.topAnchor),
      scrollView.bottomAnchor.constraint(equalTo: textContainer.bottomAnchor),
    ])

    copyButton.target = self
    copyButton.action = #selector(copyText)
    copyButton.bezelStyle = .rounded
    copyButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)

    closeButton.target = self
    closeButton.action = #selector(closeWindow)
    closeButton.keyEquivalent = "\u{1b}" // Esc
    closeButton.bezelStyle = .rounded
    closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)

    let buttonStack = NSStackView(views: [closeButton, copyButton])
    buttonStack.orientation = .horizontal
    buttonStack.spacing = 8
    buttonStack.alignment = .centerY
    buttonStack.distribution = .gravityAreas
    buttonStack.translatesAutoresizingMaskIntoConstraints = false
    buttonStack.setHuggingPriority(.required, for: .vertical)

    let stack = NSStackView(views: [textContainer, buttonStack])
    stack.orientation = .vertical
    stack.spacing = 10
    stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
    stack.translatesAutoresizingMaskIntoConstraints = false

    backgroundView.addSubview(stack)

    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: backgroundView.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: backgroundView.trailingAnchor),
      stack.topAnchor.constraint(equalTo: backgroundView.topAnchor),
      stack.bottomAnchor.constraint(equalTo: backgroundView.bottomAnchor),
      textContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 220),
    ])
  }

  @objc private func copyText() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(textView.string, forType: .string)
  }

  @objc private func closeWindow() {
    window?.close()
  }
}

