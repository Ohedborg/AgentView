import AppKit
import SwiftUI

@MainActor
final class QuickChatPanelController: NSWindowController, NSWindowDelegate {
  private let apiKeyProvider: () -> String?
  private let appSettings = AppSettings.shared
  private let model: Model

  private var isShowing = false
  private var followTimer: Timer?
  private var lastMousePoint: CGPoint = .zero
  private var anchorOffset = CGPoint(x: 0, y: -32)
  private var activityMonitor: Any?
  private var lastAppliedContentSize: CGSize?

  init(apiKeyProvider: @escaping () -> String?) {
    self.apiKeyProvider = apiKeyProvider
    self.model = Model()

    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 560, height: 360),
      styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    panel.title = "Quick Chat"
    panel.titleVisibility = .hidden
    panel.titlebarAppearsTransparent = true
    panel.isMovableByWindowBackground = true
    panel.level = .floating
    panel.isFloatingPanel = true
    panel.collectionBehavior = [.moveToActiveSpace, .transient, .ignoresCycle, .fullScreenAuxiliary]
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.hasShadow = true
    panel.minSize = NSSize(width: 520, height: 280)

    super.init(window: panel)
    panel.delegate = self

    model.onRequestDismiss = { [weak self] in
      self?.dismissAnimated()
    }

    let root = QuickChatView(
      model: model,
      onClose: { [weak self] in self?.dismissAnimated() },
      onSend: { [weak self] text, target in
        guard let self else { return }
        Task { @MainActor in
          await self.send(text: text, target: target)
        }
      },
      onPreferredContentSize: { [weak self] size in
        guard let self else { return }
        self.applyPreferredContentSize(size)
      }
    )
    window?.contentViewController = NSHostingController(rootView: root)
  }

  required init?(coder: NSCoder) { nil }

  func showNearCursor() {
    guard let window else { return }
    window.alphaValue = 1

    // Restore the last-selected target.
    model.setInitialTargetFromSettings()
    model.touch()

    lastMousePoint = NSEvent.mouseLocation
    moveWindowToFollowCursor(animated: false)

    if !isShowing {
      showWindow(nil)
      isShowing = true
    }
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)

    startActivityMonitor()
    startFollowingCursor()
  }

  func windowWillClose(_ notification: Notification) {
    isShowing = false
    stopFollowingCursor()
    stopActivityMonitor()
    model.resetForNextShow()
  }

  private func dismissAnimated() {
    guard let window, isShowing else { return }
    stopFollowingCursor()
    stopActivityMonitor()
    NSAnimationContext.runAnimationGroup { ctx in
      ctx.duration = 0.18
      window.animator().alphaValue = 0
    } completionHandler: { [weak self] in
      self?.close()
    }
  }

  private func applyPreferredContentSize(_ size: CGSize) {
    guard let window else { return }
    guard isShowing else { return }

    // Avoid resize loops / tiny oscillations.
    if let lastAppliedContentSize,
       abs(lastAppliedContentSize.width - size.width) < 2,
       abs(lastAppliedContentSize.height - size.height) < 2 {
      return
    }

    var target = size
    target.width = max(window.minSize.width, target.width)
    target.height = max(window.minSize.height, target.height)

    let screen: NSScreen? = {
      if let s = window.screen { return s }
      // Fall back to the screen under the cursor.
      let p = NSPoint(x: lastMousePoint.x, y: lastMousePoint.y)
      return NSScreen.screens.first(where: { $0.frame.contains(p) }) ?? NSScreen.main
    }()
    if let screen {
      let pad: CGFloat = 20
      target.width = min(target.width, screen.visibleFrame.width - pad * 2)
      target.height = min(target.height, screen.visibleFrame.height - pad * 2)
    }

    lastAppliedContentSize = target
    window.setContentSize(target)
    moveWindowToFollowCursor(animated: false)
  }

  private func startFollowingCursor() {
    stopFollowingCursor()
    followTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
      Task { @MainActor in
        self?.tickFollow()
      }
    }
    if let followTimer {
      RunLoop.main.add(followTimer, forMode: .common)
    }
  }

  private func stopFollowingCursor() {
    followTimer?.invalidate()
    followTimer = nil
  }

  private func tickFollow() {
    guard isShowing else { return }
    let p = NSEvent.mouseLocation
    // If the user is interacting with the HUD, stop moving it so clicks work.
    if let window, window.frame.insetBy(dx: -2, dy: -2).contains(p) {
      lastMousePoint = p
      model.touch()
      return
    }
    if hypot(p.x - lastMousePoint.x, p.y - lastMousePoint.y) < 2 { return }
    lastMousePoint = p
    moveWindowToFollowCursor(animated: false)
    model.touch()
  }

  private func moveWindowToFollowCursor(animated: Bool) {
    guard let window else { return }
    let mouse = lastMousePoint
    let size = window.frame.size
    var origin = CGPoint(x: mouse.x - size.width / 2 + anchorOffset.x, y: mouse.y + anchorOffset.y)

    if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) {
      let pad: CGFloat = 10
      origin.x = max(screen.visibleFrame.minX + pad, min(origin.x, screen.visibleFrame.maxX - size.width - pad))
      origin.y = max(screen.visibleFrame.minY + pad, min(origin.y, screen.visibleFrame.maxY - size.height - pad))
    }

    let frame = NSRect(origin: NSPoint(x: origin.x, y: origin.y), size: size)
    if animated {
      window.animator().setFrame(frame, display: false)
    } else {
      window.setFrame(frame, display: false)
    }
  }

  private func send(text: String, target: Model.Target) async {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }

    guard let apiKey = apiKeyProvider() else {
      model.setError("Missing API key. Set it from the menubar.")
      return
    }

    model.isLoading = true
    model.status = "Sending…"
    model.responseText = ""
    model.touch()

    let registry = ThreadRegistry.shared
    let resolvedTarget = model.resolveTarget(target)
    let previousResponseId: String? = {
      switch resolvedTarget {
      case .newThreadEveryTime:
        return nil
      case .existing(let id):
        return registry.snapshot(id: id)?.previousResponseId
      }
    }()

    do {
      let client = OpenAIClient(apiKey: apiKey)
      let result = try await client.captureThreadStreaming(
        imagePNG: nil,
        userText: trimmed,
        previousResponseId: previousResponseId,
        onDelta: { [weak self] delta in
          guard let self else { return }
          self.model.responseText += delta
          self.model.touch()
          self.model.requestScrollToBottom(throttled: true)
        },
        onDebug: nil
      )

      model.isLoading = false
      model.status = "Done"
      model.touch()

      let userMsg = ThreadRegistry.PersistedMessage(role: "user", text: trimmed, createdAt: Date())
      let assistantMsg = ThreadRegistry.PersistedMessage(role: "assistant", text: result.text, createdAt: Date())

      switch resolvedTarget {
      case .newThreadEveryTime:
        let title = model.suggestedTitle(from: trimmed)
        let id = registry.createDetachedThread(
          title: title,
          previousResponseId: result.responseId,
          messages: [userMsg, assistantMsg]
        )
        model.lastCreatedThreadId = id
      case .existing(let id):
        registry.appendMessages(
          to: id,
          previousResponseId: result.responseId,
          messages: [userMsg, assistantMsg]
        )
        model.lastCreatedThreadId = id
      }
    } catch {
      model.isLoading = false
      model.setError("Request failed: \(String(describing: error))")
    }
  }

  private func startActivityMonitor() {
    stopActivityMonitor()
    activityMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]) { [weak self] event in
      guard let self else { return event }
      guard self.isShowing else { return event }
      // If the quick chat window is key, treat any interaction as activity.
      if self.window?.isKeyWindow == true {
        self.model.touch()
      } else if event.window === self.window {
        self.model.touch()
      }
      return event
    }
  }

  private func stopActivityMonitor() {
    if let activityMonitor {
      NSEvent.removeMonitor(activityMonitor)
    }
    activityMonitor = nil
  }
}

extension QuickChatPanelController {
  @MainActor
  final class Model: ObservableObject {
    enum Target: Hashable {
      case newThreadEveryTime
      case existing(UUID)
    }

    @Published var draftText: String = ""
    @Published var responseText: String = ""
    @Published var isLoading: Bool = false
    @Published var status: String = "Ready"
    @Published var target: Target = .newThreadEveryTime
    @Published var lastCreatedThreadId: UUID?
    @Published var scrollBump: Int = 0

    var onRequestDismiss: (() -> Void)?

    private var idleWorkItem: DispatchWorkItem?
    private let appSettings = AppSettings.shared
    private var pendingScrollWorkItem: DispatchWorkItem?

    func setInitialTargetFromSettings() {
      switch appSettings.quickChatThreadMode {
      case .newThreadEveryTime:
        target = .newThreadEveryTime
      case .existingThread:
        if let id = appSettings.quickChatThreadId {
          target = .existing(id)
        } else {
          target = .newThreadEveryTime
        }
      }
    }

    func resolveTarget(_ t: Target) -> Target {
      // Persist selection semantics.
      switch t {
      case .newThreadEveryTime:
        appSettings.quickChatThreadMode = .newThreadEveryTime
        appSettings.quickChatThreadId = nil
        return .newThreadEveryTime
      case .existing(let id):
        appSettings.quickChatThreadMode = .existingThread
        appSettings.quickChatThreadId = id
        return .existing(id)
      }
    }

    func touch() {
      armIdleTimer()
    }

    func requestScrollToBottom(throttled: Bool) {
      pendingScrollWorkItem?.cancel()
      if throttled {
        let work = DispatchWorkItem { [weak self] in
          self?.scrollBump &+= 1
        }
        pendingScrollWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
      } else {
        scrollBump &+= 1
      }
    }

    func resetForNextShow() {
      draftText = ""
      responseText = ""
      status = "Ready"
      isLoading = false
      lastCreatedThreadId = nil
      pendingScrollWorkItem?.cancel()
      pendingScrollWorkItem = nil
      scrollBump = 0
      idleWorkItem?.cancel()
      idleWorkItem = nil
    }

    func setError(_ message: String) {
      status = message
      touch()
    }

    private func armIdleTimer() {
      idleWorkItem?.cancel()
      guard !isLoading else { return }
      let work = DispatchWorkItem { [weak self] in
        guard let self else { return }
        self.onRequestDismiss?()
      }
      idleWorkItem = work
      DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: work)
    }

    func suggestedTitle(from userText: String) -> String {
      var s = userText
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: "\n", with: " ")
      while s.contains("  ") { s = s.replacingOccurrences(of: "  ", with: " ") }
      if let cut = s.firstIndex(where: { ".?!".contains($0) }) {
        let prefix = s[..<cut]
        if prefix.count >= 12 {
          s = String(prefix)
        }
      }
      if s.count > 44 {
        let idx = s.index(s.startIndex, offsetBy: 44)
        s = String(s[..<idx]).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
      }
      return s.isEmpty ? "Untitled" : s
    }
  }
}

private struct QuickChatView: View {
  @ObservedObject var model: QuickChatPanelController.Model
  let onClose: () -> Void
  let onSend: (String, QuickChatPanelController.Model.Target) -> Void
  let onPreferredContentSize: (CGSize) -> Void

  @ObservedObject private var registry = ThreadRegistry.shared

  @State private var responseMaxHeight: CGFloat = 220
  @State private var responseContentHeight: CGFloat = 0
  @State private var headerHeight: CGFloat = 0
  @State private var composerHeight: CGFloat = 0

  private struct ThreadOption: Identifiable {
    let id: String
    let label: String
    let target: QuickChatPanelController.Model.Target
  }

  private var threadOptions: [ThreadOption] {
    var opts: [ThreadOption] = [
      .init(id: "new", label: "New thread each time", target: .newThreadEveryTime)
    ]
    for e in registry.entries {
      opts.append(.init(id: "existing-\(e.id.uuidString)", label: e.title, target: .existing(e.id)))
    }
    return opts
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      header
      composer
      response
    }
    .padding(14)
    .background(.regularMaterial)
    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .strokeBorder(.separator.opacity(0.7), lineWidth: 1)
    )
    .onChange(of: model.draftText) { _, _ in model.touch() }
    .onChange(of: model.target) { _, _ in model.touch() }
    .onChange(of: responseMaxHeight) { _, _ in pushPreferredSize() }
    .onChange(of: headerHeight) { _, _ in pushPreferredSize() }
    .onChange(of: composerHeight) { _, _ in pushPreferredSize() }
    .onAppear {
      model.touch()
      pushPreferredSize()
    }
  }

  private var header: some View {
    HStack(spacing: 10) {
      Image(systemName: "sparkles")
        .foregroundStyle(.tint)

      Picker("", selection: $model.target) {
        ForEach(threadOptions) { opt in
          Text(opt.label).tag(opt.target)
        }
      }
      .labelsHidden()
      .pickerStyle(.menu)

      Spacer()

      Text(model.status)
        .font(.caption)
        .foregroundStyle(.secondary)

      Button {
        switch model.target {
        case .existing(let id):
          Task { @MainActor in
            ThreadRegistry.shared.focusOrOpen(id: id)
          }
          onClose()
        case .newThreadEveryTime:
          if let id = model.lastCreatedThreadId {
            Task { @MainActor in
              ThreadRegistry.shared.focusOrOpen(id: id)
            }
            onClose()
          } else {
            let draft = model.draftText.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = draft.isEmpty ? "New thread" : model.suggestedTitle(from: draft)
            let id = ThreadRegistry.shared.createDetachedThread(title: title, previousResponseId: nil, messages: [])
            model.lastCreatedThreadId = id
            Task { @MainActor in
              ThreadRegistry.shared.focusOrOpen(id: id)
            }
            onClose()
          }
        }
      } label: {
        Image(systemName: "arrow.up.right.square")
      }
      .buttonStyle(.plain)

      Button {
        onClose()
      } label: {
        Image(systemName: "xmark")
      }
      .buttonStyle(.plain)
    }
    .background(
      GeometryReader { p in
        Color.clear
          .preference(key: HeaderHeightPreferenceKey.self, value: p.size.height)
      }
    )
    .onPreferenceChange(HeaderHeightPreferenceKey.self) { headerHeight = $0 }
  }

  private var composer: some View {
    VStack(alignment: .leading, spacing: 8) {
      AutoGrowingTextEditor(text: $model.draftText, minHeight: 44, maxHeight: 220)
        .font(.system(size: 13))
        .foregroundStyle(Color.black)
        .scrollContentBackground(.hidden)
        .padding(10)
        .background(
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.white)
        )
        .overlay(
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(.separator, lineWidth: 1)
        )

      HStack {
        Spacer()
        Button {
          onSend(model.draftText, model.target)
          model.draftText = ""
        } label: {
          Label("Send", systemImage: "arrow.up.circle.fill")
        }
        .buttonStyle(.borderedProminent)
        .disabled(model.isLoading || model.draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
    .background(
      GeometryReader { p in
        Color.clear
          .preference(key: ComposerHeightPreferenceKey.self, value: p.size.height)
      }
    )
    .onPreferenceChange(ComposerHeightPreferenceKey.self) { composerHeight = $0 }
  }

  private var response: some View {
    ScrollViewReader { proxy in
      ScrollView {
        let baseText: String = {
          if model.responseText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return model.isLoading ? "…" : "Reply will appear here."
          }
          return model.responseText
        }()

        // Add a block cursor while streaming to mimic “typing”.
        let displayText = model.isLoading ? (baseText + " ▍") : baseText

        Text(displayText)
          .font(.system(size: 13, design: .monospaced))
          .foregroundStyle(Color.black)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(10)
          .background(
            GeometryReader { p in
              Color.clear
                .preference(key: ResponseContentHeightPreferenceKey.self, value: p.size.height)
            }
          )

        Color.clear
          .frame(height: 1)
          .id("BOTTOM")
      }
      .onChange(of: model.scrollBump) { _, _ in
        proxy.scrollTo("BOTTOM", anchor: .bottom)
      }
      .onPreferenceChange(ResponseContentHeightPreferenceKey.self) { h in
        responseContentHeight = h
        // Grow to fit response up to a sensible max; then ScrollView takes over.
        let desired = min(max(96, h + 20), 2000)
        if abs(responseMaxHeight - desired) > 1 {
          responseMaxHeight = desired
        }
      }
    }
    .frame(minHeight: 96, maxHeight: responseMaxHeight)
    .background(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .fill(Color.white)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .strokeBorder(.separator, lineWidth: 1)
    )
  }

  private func pushPreferredSize() {
    // Total height = sections + spacing + padding.
    let spacingTotal: CGFloat = 10 * 2
    let paddingTotal: CGFloat = 14 * 2
    let totalHeight = headerHeight + composerHeight + max(96, responseMaxHeight) + spacingTotal + paddingTotal
    // Keep width stable; the controller clamps anyway.
    onPreferredContentSize(CGSize(width: 560, height: totalHeight))
  }
}

private struct ResponseContentHeightPreferenceKey: PreferenceKey {
  static var defaultValue: CGFloat = 0
  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
    value = max(value, nextValue())
  }
}

private struct HeaderHeightPreferenceKey: PreferenceKey {
  static var defaultValue: CGFloat = 0
  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
    value = max(value, nextValue())
  }
}

private struct ComposerHeightPreferenceKey: PreferenceKey {
  static var defaultValue: CGFloat = 0
  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
    value = max(value, nextValue())
  }
}

private struct AutoGrowingTextEditor: View {
  @Binding var text: String
  let minHeight: CGFloat
  let maxHeight: CGFloat

  @State private var measuredHeight: CGFloat = 44

  var body: some View {
    ZStack(alignment: .topLeading) {
      Text(measureText)
        .font(.system(size: 13))
        .foregroundStyle(Color.clear)
        .padding(4) // small inner padding to match TextEditor insets
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
          GeometryReader { proxy in
            Color.clear
              .preference(key: HeightPreferenceKey.self, value: proxy.size.height)
          }
        )

      TextEditor(text: $text)
        .font(.system(size: 13))
        .foregroundStyle(Color.black)
        .scrollContentBackground(.hidden)
    }
    .onPreferenceChange(HeightPreferenceKey.self) { h in
      let clamped = min(max(minHeight, h), maxHeight)
      if abs(measuredHeight - clamped) > 0.5 {
        measuredHeight = clamped
      }
    }
    .frame(minHeight: minHeight, maxHeight: measuredHeight)
  }

  private var measureText: String {
    // Ensure there's always at least one line and account for the insertion point.
    let s = text.isEmpty ? " " : text
    return s + "\n"
  }
}

private struct HeightPreferenceKey: PreferenceKey {
  static var defaultValue: CGFloat = 44
  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
    value = max(value, nextValue())
  }
}

