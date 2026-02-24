import AppKit

final class ContextPromptWindowController: NSWindowController, NSWindowDelegate, NSTextViewDelegate {
  private var onComplete: ((String?) -> Void)?
  private var onSend: ((ContextPromptWindowController, String) -> Void)?

  private let textView = NSTextView()
  private let scrollView = NSScrollView()
  private let previewImageView = NSImageView()
  private let sendButton = NSButton(title: "Send", target: nil, action: nil)
  private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
  private let responseTitle = NSTextField(labelWithString: "OpenAI response")
  private let responseView = NSTextView()
  private let responseScroll = NSScrollView()
  private let contextMetaLabel = NSTextField(labelWithString: "0 characters")
  private let statusLabel = NSTextField(labelWithString: "Ready")
  private let spinner = NSProgressIndicator()
  private let debugToggle = NSButton(checkboxWithTitle: "Show debug details", target: nil, action: nil)
  private let debugView = NSTextView()
  private let debugScroll = NSScrollView()
  private var debugContainer: NSStackView?
  private let responseInk = NSColor.black.withAlphaComponent(1)

  @discardableResult
  static func present(
    previewPNGData: Data,
    initialText: String,
    onSend: @escaping (ContextPromptWindowController, String) -> Void,
    onComplete: @escaping (String?) -> Void
  ) -> ContextPromptWindowController {
    let wc = ContextPromptWindowController(previewPNGData: previewPNGData, initialText: initialText)
    wc.onSend = onSend
    wc.onComplete = onComplete
    wc.showWindow(nil)
    wc.window?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    return wc
  }

  init(previewPNGData: Data, initialText: String) {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 640, height: 440),
      styleMask: [.titled, .closable, .resizable],
      backing: .buffered,
      defer: false
    )
    window.title = "Add context (optional)"
    window.center()

    super.init(window: window)
    window.delegate = self

    setupUI(previewPNGData: previewPNGData, initialText: initialText)
  }

  required init?(coder: NSCoder) {
    nil
  }

  private func setupUI(previewPNGData: Data, initialText: String) {
    guard let contentView = window?.contentView else { return }

    // Vercel-ish: clear title + subtle subtitle + a small thumbnail preview.
    let title = NSTextField(labelWithString: "Add context (optional)")
    title.font = NSFont.systemFont(ofSize: 16, weight: .semibold)

    let subtitle = NSTextField(labelWithString: "This will be sent along with the screenshot.")
    subtitle.font = NSFont.systemFont(ofSize: 12, weight: .regular)
    subtitle.textColor = .secondaryLabelColor

    statusLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
    statusLabel.textColor = .tertiaryLabelColor

    spinner.style = .spinning
    spinner.controlSize = .small
    spinner.isDisplayedWhenStopped = false

    textView.isRichText = false
    textView.string = initialText
    let bodyFont = NSFont.systemFont(ofSize: 13)
    textView.font = bodyFont
    textView.alignment = .left
    textView.textContainerInset = NSSize(width: 8, height: 8)
    textView.isEditable = true
    textView.isSelectable = true
    textView.drawsBackground = true
    // Force a high-contrast "always readable" editor (requested).
    let ink = NSColor.black.withAlphaComponent(1)
    textView.backgroundColor = .white
    textView.textColor = ink
    textView.insertionPointColor = ink
    textView.textContainer?.widthTracksTextView = true
    textView.delegate = self
    // Some setups don't reliably call the delegate; observe the notification too.
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(contextTextDidChange(_:)),
      name: NSText.didChangeNotification,
      object: textView
    )

    // Canonical NSTextView-in-NSScrollView configuration (prevents weird layout/RTL behavior).
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.autoresizingMask = [.width]
    textView.minSize = NSSize(width: 0, height: 0)
    textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
    textView.textContainer?.widthTracksTextView = true

    let para = NSMutableParagraphStyle()
    para.alignment = .left
    para.baseWritingDirection = .leftToRight
    textView.defaultParagraphStyle = para

    // Ensure newly typed text is always visible (some appearance combos can otherwise end up with invisible typing attributes).
    textView.typingAttributes = [
      .font: bodyFont,
      .foregroundColor: ink,
      .paragraphStyle: para
    ]
    textView.textStorage?.setAttributes(
      [.font: bodyFont, .foregroundColor: ink, .paragraphStyle: para],
      range: NSRange(location: 0, length: (textView.string as NSString).length)
    )

    scrollView.documentView = textView
    scrollView.hasVerticalScroller = true
    scrollView.borderType = .lineBorder
    scrollView.drawsBackground = true
    scrollView.backgroundColor = .white
    scrollView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.hasHorizontalScroller = false

    previewImageView.image = NSImage(data: previewPNGData)
    previewImageView.imageScaling = .scaleProportionallyUpOrDown
    previewImageView.wantsLayer = true
    previewImageView.layer?.cornerRadius = 10
    previewImageView.layer?.masksToBounds = true
    previewImageView.layer?.borderWidth = 1
    previewImageView.layer?.borderColor = NSColor.separatorColor.cgColor

    sendButton.target = self
    sendButton.action = #selector(send)
    sendButton.keyEquivalent = "\r"
    sendButton.bezelStyle = .rounded

    cancelButton.target = self
    cancelButton.action = #selector(cancel)
    cancelButton.keyEquivalent = "\u{1b}" // Esc
    cancelButton.bezelStyle = .rounded

    let buttonStack = NSStackView(views: [cancelButton, sendButton])
    buttonStack.orientation = .horizontal
    buttonStack.spacing = 8
    buttonStack.alignment = .centerY
    buttonStack.distribution = .gravityAreas

    let previewRow = NSStackView()
    previewRow.orientation = .horizontal
    previewRow.spacing = 12
    previewRow.alignment = .top
    previewRow.distribution = .fill
    previewRow.translatesAutoresizingMaskIntoConstraints = false

    let previewLabel = NSTextField(labelWithString: "Preview")
    previewLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
    previewLabel.textColor = .secondaryLabelColor

    let previewStack = NSStackView(views: [previewLabel, previewImageView])
    previewStack.orientation = .vertical
    previewStack.spacing = 6
    previewStack.alignment = .leading
    previewStack.setHuggingPriority(.required, for: .horizontal)
    previewStack.setContentCompressionResistancePriority(.required, for: .horizontal)

    previewImageView.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      previewImageView.widthAnchor.constraint(equalToConstant: 180),
      previewImageView.heightAnchor.constraint(equalToConstant: 110),
    ])

    let contextLabel = NSTextField(labelWithString: "Context")
    contextLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
    contextLabel.textColor = .secondaryLabelColor

    contextMetaLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
    contextMetaLabel.textColor = .tertiaryLabelColor

    let contextHeader = NSStackView(views: [contextLabel, contextMetaLabel])
    contextHeader.orientation = .horizontal
    contextHeader.distribution = .fill
    contextHeader.alignment = .centerY
    contextHeader.spacing = 8
    contextHeader.setHuggingPriority(.defaultHigh, for: .horizontal)

    let contextStack = NSStackView(views: [contextHeader, scrollView])
    contextStack.orientation = .vertical
    contextStack.spacing = 6
    contextStack.alignment = .leading
    contextStack.setHuggingPriority(.defaultLow, for: .horizontal)
    contextStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    previewRow.addArrangedSubview(previewStack)
    previewRow.addArrangedSubview(contextStack)

    responseTitle.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
    responseTitle.textColor = .secondaryLabelColor

    responseView.isRichText = false
    responseView.isEditable = false
    responseView.isSelectable = true
    responseView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    responseView.alignment = .left
    responseView.drawsBackground = true
    // Force readable response colors (avoid "invisible text" issues).
    responseView.backgroundColor = .white
    responseView.textColor = responseInk
    responseView.textContainerInset = NSSize(width: 10, height: 10)
    // Canonical sizing (same class of issues as the context editor).
    responseView.isVerticallyResizable = true
    responseView.isHorizontallyResizable = false
    responseView.autoresizingMask = [.width]
    responseView.minSize = NSSize(width: 0, height: 0)
    responseView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    responseView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
    responseView.textContainer?.widthTracksTextView = true

    responseScroll.documentView = responseView
    responseScroll.hasVerticalScroller = true
    responseScroll.borderType = .lineBorder
    responseScroll.drawsBackground = true
    responseScroll.backgroundColor = .white
    responseScroll.translatesAutoresizingMaskIntoConstraints = false

    let responseStack = NSStackView(views: [responseTitle, responseScroll])
    responseStack.orientation = .vertical
    responseStack.spacing = 6
    responseStack.alignment = .leading

    // Debug panel (hidden by default, shown on demand or on error).
    debugToggle.target = self
    debugToggle.action = #selector(toggleDebug)
    debugToggle.font = NSFont.systemFont(ofSize: 11, weight: .regular)
    debugToggle.state = .off

    debugView.isRichText = false
    debugView.isEditable = false
    debugView.isSelectable = true
    debugView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    debugView.alignment = .left
    debugView.drawsBackground = true
    debugView.backgroundColor = .white
    debugView.textColor = responseInk
    debugView.textContainerInset = NSSize(width: 10, height: 10)
    debugView.isVerticallyResizable = true
    debugView.isHorizontallyResizable = false
    debugView.autoresizingMask = [.width]
    debugView.minSize = NSSize(width: 0, height: 0)
    debugView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    debugView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
    debugView.textContainer?.widthTracksTextView = true

    debugScroll.documentView = debugView
    debugScroll.hasVerticalScroller = true
    debugScroll.borderType = .lineBorder
    debugScroll.drawsBackground = true
    debugScroll.backgroundColor = .white
    debugScroll.translatesAutoresizingMaskIntoConstraints = false

    let statusRow = NSStackView(views: [spinner, statusLabel])
    statusRow.orientation = .horizontal
    statusRow.spacing = 8
    statusRow.alignment = .centerY

    let headerStack = NSStackView(views: [title, subtitle, statusRow])
    headerStack.orientation = .vertical
    headerStack.spacing = 6

    let debugStack = NSStackView(views: [debugToggle, debugScroll])
    debugStack.orientation = .vertical
    debugStack.spacing = 6
    debugStack.alignment = .leading
    debugStack.isHidden = true
    debugContainer = debugStack

    let stack = NSStackView(views: [headerStack, previewRow, responseStack, debugStack, buttonStack])
    stack.orientation = .vertical
    stack.spacing = 12
    stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
    stack.translatesAutoresizingMaskIntoConstraints = false
    // Fill horizontally (prevents "black empty area" where scroll views don't expand).
    stack.alignment = .leading

    contentView.addSubview(stack)

    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
      stack.topAnchor.constraint(equalTo: contentView.topAnchor),
      stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
      scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 140),
      previewRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
      responseScroll.heightAnchor.constraint(equalToConstant: 140),
      responseStack.widthAnchor.constraint(equalTo: stack.widthAnchor),
      debugScroll.heightAnchor.constraint(equalToConstant: 120),
      debugStack.widthAnchor.constraint(equalTo: stack.widthAnchor),
      // Give the editor a sane minimum width so typing never feels "invisible" due to a collapsed view.
      scrollView.widthAnchor.constraint(greaterThanOrEqualToConstant: 320),
      // Ensure the scroll views actually expand to full width inside their stacks.
      responseScroll.widthAnchor.constraint(equalTo: responseStack.widthAnchor),
      debugScroll.widthAnchor.constraint(equalTo: debugStack.widthAnchor),
    ])

    // Put the caret in the text view so typing is immediately visible.
    window?.makeFirstResponder(textView)

    // Initialize meta + enforce styling for initial state.
    enforceContextTextStyleAndMeta()
  }

  func windowWillClose(_ notification: Notification) {
    complete(value: nil)
  }

  @objc private func send() {
    // Keep the window open so we can show streaming output.
    let text = textView.string
    onSend?(self, text)
  }

  @objc private func cancel() {
    complete(value: nil)
    window?.close()
  }

  private func complete(value: String?) {
    guard let cb = onComplete else { return }
    onComplete = nil
    cb(value)
    close()
  }

  @MainActor
  func appendResponseDelta(_ delta: String) {
    appendToResponseText(delta)
    responseView.scrollToEndOfDocument(nil)
  }

  @MainActor
  func setResponseText(_ text: String) {
    setResponseTextStorage(text)
    responseView.scrollToEndOfDocument(nil)
  }

  @MainActor
  func setStatus(_ text: String, isLoading: Bool) {
    statusLabel.stringValue = text
    if isLoading {
      spinner.startAnimation(nil)
      sendButton.isEnabled = false
    } else {
      spinner.stopAnimation(nil)
      sendButton.isEnabled = true
    }
  }

  @MainActor
  func appendDebug(_ line: String) {
    // Lazily show the debug panel once we have something useful.
    if debugContainer?.isHidden == true {
      debugContainer?.isHidden = false
    }
    appendToDebugText((debugView.string.isEmpty ? "" : "\n") + line)
    debugView.scrollToEndOfDocument(nil)
  }

  @MainActor
  func clearDebug() {
    setDebugTextStorage("")
  }

  @MainActor
  private func responseAttributes() -> [NSAttributedString.Key: Any] {
    let para = NSMutableParagraphStyle()
    para.alignment = .left
    para.baseWritingDirection = .leftToRight
    let font = responseView.font ?? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    return [.font: font, .foregroundColor: responseInk, .paragraphStyle: para]
  }

  @MainActor
  private func debugAttributes() -> [NSAttributedString.Key: Any] {
    let para = NSMutableParagraphStyle()
    para.alignment = .left
    para.baseWritingDirection = .leftToRight
    let font = debugView.font ?? NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    return [.font: font, .foregroundColor: responseInk, .paragraphStyle: para]
  }

  @MainActor
  private func setResponseTextStorage(_ text: String) {
    let attr = NSAttributedString(string: text, attributes: responseAttributes())
    responseView.textStorage?.setAttributedString(attr)
  }

  @MainActor
  private func appendToResponseText(_ text: String) {
    guard let ts = responseView.textStorage else {
      setResponseTextStorage(text)
      return
    }
    let start = ts.length
    ts.mutableString.append(text)
    ts.addAttributes(responseAttributes(), range: NSRange(location: start, length: ts.length - start))
  }

  @MainActor
  private func setDebugTextStorage(_ text: String) {
    let attr = NSAttributedString(string: text, attributes: debugAttributes())
    debugView.textStorage?.setAttributedString(attr)
  }

  @MainActor
  private func appendToDebugText(_ text: String) {
    guard let ts = debugView.textStorage else {
      setDebugTextStorage(text)
      return
    }
    let start = ts.length
    ts.mutableString.append(text)
    ts.addAttributes(debugAttributes(), range: NSRange(location: start, length: ts.length - start))
  }

  // MARK: - NSTextViewDelegate

  func textDidChange(_ notification: Notification) {
    // Keep behavior consistent whether updates come via delegate or notification.
    enforceContextTextStyleAndMeta()
  }

  @objc private func contextTextDidChange(_ notification: Notification) {
    enforceContextTextStyleAndMeta()
  }

  private func enforceContextTextStyleAndMeta() {
    // Defensive: some macOS configurations can reset typing attributes; force black foreground + base font.
    let fullRange = NSRange(location: 0, length: (textView.string as NSString).length)
    let bodyFont = (textView.font ?? NSFont.systemFont(ofSize: 13))
    let ink = NSColor.black.withAlphaComponent(1)
    let para = (textView.defaultParagraphStyle ?? {
      let p = NSMutableParagraphStyle()
      p.alignment = .left
      p.baseWritingDirection = .leftToRight
      return p
    }())

    textView.textStorage?.addAttributes(
      [.font: bodyFont, .foregroundColor: ink, .paragraphStyle: para],
      range: fullRange
    )
    textView.typingAttributes = [
      .font: bodyFont,
      .foregroundColor: ink,
      .paragraphStyle: para
    ]

    contextMetaLabel.stringValue = "\(fullRange.length) characters"
  }

  @objc private func toggleDebug() {
    let shouldShow = (debugToggle.state == .on)
    debugContainer?.isHidden = !shouldShow
  }
}


