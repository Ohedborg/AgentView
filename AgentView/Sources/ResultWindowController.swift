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

    super.init(window: window)
    window.delegate = self

    setupUI(text: text)
  }

  required init?(coder: NSCoder) {
    nil
  }

  private func setupUI(text: String) {
    guard let contentView = window?.contentView else { return }

    textView.isRichText = false
    textView.isEditable = false
    textView.isSelectable = true
    textView.string = text
    textView.font = NSFont.systemFont(ofSize: 13)
    textView.textContainerInset = NSSize(width: 10, height: 10)
    textView.drawsBackground = true
    textView.backgroundColor = .textBackgroundColor
    textView.textColor = .labelColor

    scrollView.documentView = textView
    scrollView.hasVerticalScroller = true
    scrollView.borderType = .bezelBorder
    scrollView.drawsBackground = true
    scrollView.backgroundColor = .textBackgroundColor
    scrollView.translatesAutoresizingMaskIntoConstraints = false

    copyButton.target = self
    copyButton.action = #selector(copyText)

    closeButton.target = self
    closeButton.action = #selector(closeWindow)
    closeButton.keyEquivalent = "\u{1b}" // Esc

    let buttonStack = NSStackView(views: [closeButton, copyButton])
    buttonStack.orientation = .horizontal
    buttonStack.spacing = 8
    buttonStack.alignment = .centerY
    buttonStack.distribution = .gravityAreas
    buttonStack.translatesAutoresizingMaskIntoConstraints = false

    let stack = NSStackView(views: [scrollView, buttonStack])
    stack.orientation = .vertical
    stack.spacing = 10
    stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
    stack.translatesAutoresizingMaskIntoConstraints = false

    contentView.addSubview(stack)

    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
      stack.topAnchor.constraint(equalTo: contentView.topAnchor),
      stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
      scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 220),
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

