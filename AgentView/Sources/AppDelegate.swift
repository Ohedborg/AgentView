import AppKit
import Carbon
import Foundation
import Security

final class AppDelegate: NSObject, NSApplicationDelegate {
  private var statusItem: NSStatusItem!
  private let hotKeyManager = HotKeyManager()
  private let selectionCoordinator = SelectionOverlayCoordinator()
  private let apiKeyStore = APIKeyStore.shared
  private let appSettings = AppSettings.shared
  private var contextPromptWCs: [ContextPromptWindowController] = []
  private var apiKeyStatusMenuItem: NSMenuItem?
  private var autoClearItems: [NSMenuItem] = []
  private var clipboardClearTask: DispatchWorkItem?
  private var mainGrabMenuItem: NSMenuItem?
  private var mainQuickMenuItem: NSMenuItem?
  private var mainThreadsMenuItem: NSMenuItem?
  private var hotKeyGrabMenuItem: NSMenuItem?
  private var hotKeyQuickMenuItem: NSMenuItem?
  private var hotKeyThreadsMenuItem: NSMenuItem?
  private var quickChatPanel: QuickChatPanelController?

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
    NSWindow.allowsAutomaticWindowTabbing = true
    setupStatusItem()

    quickChatPanel = QuickChatPanelController(apiKeyProvider: { [weak self] in
      self?.apiKeyStore.loadAPIKey()
    })

    ContextPromptWindowController.configureDefaultHandlers(
      onSend: { [weak self] wc, request in
        guard let self else { return }
        Task { @MainActor in
          await self.performSend(wc: wc, request: request)
        }
      },
      onComplete: { [weak self] wc, _ in
        self?.contextPromptWCs.removeAll(where: { $0 === wc })
      }
    )

    applyHotkeys(preferred: nil)

    updateAPIKeyMenuState()
    updateAutoClearMenuState()
    if apiKeyStore.loadAPIKey() == nil {
      promptForAPIKey(required: true)
    }
  }

  private func setupStatusItem() {
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    if let button = statusItem.button {
      if let img = NSImage(named: NSImage.applicationIconName) {
        img.size = NSSize(width: 18, height: 18)
        // Menubar items look best as monochrome templates.
        img.isTemplate = true
        button.image = img
      } else {
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        button.image = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: "AgentView")?
          .withSymbolConfiguration(config)
      }
      button.imagePosition = .imageOnly
      button.toolTip = "AgentView"
    }

    let menu = NSMenu()
    let version = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "?"
    let build = (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "?"
    let header = NSMenuItem(title: "AgentView — Threaded UI (v\(version) • \(build))", action: nil, keyEquivalent: "")
    header.isEnabled = false
    menu.addItem(header)
    menu.addItem(.separator())
    let grabItem = NSMenuItem(title: "Grab (\(appSettings.grabHotKeyDisplay))", action: #selector(grabFromMenu), keyEquivalent: "")
    grabItem.image = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: nil)
    menu.addItem(grabItem)
    mainGrabMenuItem = grabItem

    let quickItem = NSMenuItem(title: "Quick chat (\(appSettings.quickChatHotKeyDisplay))", action: #selector(openQuickChatFromMenu), keyEquivalent: "")
    quickItem.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
    menu.addItem(quickItem)
    mainQuickMenuItem = quickItem
    let threadsItem = NSMenuItem(title: "Threads (\(appSettings.threadsHotKeyDisplay))", action: #selector(openThreadsFromMenu), keyEquivalent: "")
    threadsItem.image = NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: nil)
    menu.addItem(threadsItem)
    mainThreadsMenuItem = threadsItem
    menu.addItem(.separator())

    let keyStatus = NSMenuItem(title: "API Key: Not set", action: nil, keyEquivalent: "")
    keyStatus.isEnabled = false
    apiKeyStatusMenuItem = keyStatus
    menu.addItem(keyStatus)
    let setKeyItem = NSMenuItem(title: "Set API Key…", action: #selector(configureAPIKey), keyEquivalent: "k")
    setKeyItem.image = NSImage(systemSymbolName: "key.fill", accessibilityDescription: nil)
    menu.addItem(setKeyItem)

    let testKeyItem = NSMenuItem(title: "Test API Key", action: #selector(testAPIKey), keyEquivalent: "t")
    testKeyItem.image = NSImage(systemSymbolName: "checkmark.seal", accessibilityDescription: nil)
    menu.addItem(testKeyItem)

    let removeKeyItem = NSMenuItem(title: "Remove API Key", action: #selector(removeAPIKey), keyEquivalent: "")
    removeKeyItem.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
    menu.addItem(removeKeyItem)

    menu.addItem(.separator())

    let confirmItem = NSMenuItem(
      title: "Confirm before sending capture",
      action: #selector(toggleSendConfirmation(_:)),
      keyEquivalent: ""
    )
    confirmItem.state = appSettings.requireConfirmationBeforeSend ? .on : .off
    confirmItem.image = NSImage(systemSymbolName: "hand.raised", accessibilityDescription: nil)
    menu.addItem(confirmItem)

    let hotkeysParent = NSMenuItem(title: "Hotkeys", action: nil, keyEquivalent: "")
    hotkeysParent.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: nil)
    let hotkeysMenu = NSMenu()

    let setGrab = NSMenuItem(title: "Set Grab hotkey…", action: #selector(setGrabHotkey), keyEquivalent: "")
    setGrab.image = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: nil)
    hotkeysMenu.addItem(setGrab)

    let setQuick = NSMenuItem(title: "Set Quick chat hotkey…", action: #selector(setQuickChatHotkey), keyEquivalent: "")
    setQuick.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
    hotkeysMenu.addItem(setQuick)
    let setThreads = NSMenuItem(title: "Set Threads hotkey…", action: #selector(setThreadsHotkey), keyEquivalent: "")
    setThreads.image = NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: nil)
    hotkeysMenu.addItem(setThreads)

    hotkeysMenu.addItem(.separator())
    let showGrab = NSMenuItem(title: "Grab: \(appSettings.grabHotKeyDisplay)", action: nil, keyEquivalent: "")
    showGrab.isEnabled = false
    hotKeyGrabMenuItem = showGrab
    hotkeysMenu.addItem(showGrab)

    let showQuick = NSMenuItem(title: "Quick chat: \(appSettings.quickChatHotKeyDisplay)", action: nil, keyEquivalent: "")
    showQuick.isEnabled = false
    hotKeyQuickMenuItem = showQuick
    hotkeysMenu.addItem(showQuick)
    let showThreads = NSMenuItem(title: "Threads: \(appSettings.threadsHotKeyDisplay)", action: nil, keyEquivalent: "")
    showThreads.isEnabled = false
    hotKeyThreadsMenuItem = showThreads
    hotkeysMenu.addItem(showThreads)

    menu.setSubmenu(hotkeysMenu, for: hotkeysParent)
    menu.addItem(hotkeysParent)

    let autoClearParent = NSMenuItem(title: "Auto-clear clipboard", action: nil, keyEquivalent: "")
    autoClearParent.image = NSImage(systemSymbolName: "clipboard", accessibilityDescription: nil)
    let autoClearSubmenu = NSMenu()
    let options: [(String, Int)] = [("Off", 0), ("30 seconds", 30), ("60 seconds", 60), ("5 minutes", 300)]
    autoClearItems = options.map { title, seconds in
      let item = NSMenuItem(title: title, action: #selector(setAutoClearClipboard(_:)), keyEquivalent: "")
      item.representedObject = seconds
      return item
    }
    for item in autoClearItems {
      autoClearSubmenu.addItem(item)
    }
    menu.setSubmenu(autoClearSubmenu, for: autoClearParent)
    menu.addItem(autoClearParent)

    menu.addItem(.separator())
    let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
    quitItem.image = NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: nil)
    menu.addItem(quitItem)
    statusItem.menu = menu
  }

  @objc private func grabFromMenu() {
    startGrabFlow()
  }

  @MainActor
  @objc private func openQuickChatFromMenu() {
    quickChatPanel?.showNearCursor()
  }

  @MainActor
  @objc private func openThreadsFromMenu() {
    ThreadBrowserWindowController.shared.show()
  }

  @objc private func quit() {
    NSApp.terminate(nil)
  }

  @MainActor
  @objc private func setGrabHotkey() {
    HotKeyRecorderPanel.present(title: "Set Grab hotkey") { [weak self] spec in
      guard let self else { return }
      self.appSettings.grabHotKeySpec = spec
      self.applyHotkeys(preferred: .grab)
    }
  }

  @MainActor
  @objc private func setQuickChatHotkey() {
    HotKeyRecorderPanel.present(title: "Set Quick chat hotkey") { [weak self] spec in
      guard let self else { return }
      self.appSettings.quickChatHotKeySpec = spec
      self.applyHotkeys(preferred: .quickChat)
    }
  }

  @MainActor
  @objc private func setThreadsHotkey() {
    HotKeyRecorderPanel.present(title: "Set Threads hotkey") { [weak self] spec in
      guard let self else { return }
      self.appSettings.threadsHotKeySpec = spec
      self.applyHotkeys(preferred: .threads)
    }
  }

  private func updateHotkeyMenuTitles() {
    mainGrabMenuItem?.title = "Grab (\(appSettings.grabHotKeyDisplay))"
    mainQuickMenuItem?.title = "Quick chat (\(appSettings.quickChatHotKeyDisplay))"
    mainThreadsMenuItem?.title = "Threads (\(appSettings.threadsHotKeyDisplay))"
    hotKeyGrabMenuItem?.title = "Grab: \(appSettings.grabHotKeyDisplay)"
    hotKeyQuickMenuItem?.title = "Quick chat: \(appSettings.quickChatHotKeyDisplay)"
    hotKeyThreadsMenuItem?.title = "Threads: \(appSettings.threadsHotKeyDisplay)"
  }

  private struct HotKeyKey: Hashable {
    let keyCode: UInt32
    let modifiers: UInt32
  }

  @MainActor
  private func applyHotkeys(preferred: HotKeyManager.Kind?) {
    normalizeHotkeyConflicts(preferred: preferred)

    hotKeyManager.register(kind: .grab, spec: appSettings.grabHotKeySpec) { [weak self] in
      self?.startGrabFlow()
    }
    hotKeyManager.register(kind: .quickChat, spec: appSettings.quickChatHotKeySpec) { [weak self] in
      Task { @MainActor in
        self?.quickChatPanel?.showNearCursor()
      }
    }
    hotKeyManager.register(kind: .threads, spec: appSettings.threadsHotKeySpec) {
      Task { @MainActor in
        ThreadBrowserWindowController.shared.show()
      }
    }

    updateHotkeyMenuTitles()
  }

  @MainActor
  private func normalizeHotkeyConflicts(preferred: HotKeyManager.Kind?) {
    var specs: [HotKeyManager.Kind: HotKeyManager.Spec] = [
      .grab: appSettings.grabHotKeySpec,
      .quickChat: appSettings.quickChatHotKeySpec,
      .threads: appSettings.threadsHotKeySpec
    ]

    func key(_ s: HotKeyManager.Spec) -> HotKeyKey { .init(keyCode: s.keyCode, modifiers: s.modifiers) }

    // First pass: pick a winner for each duplicated binding.
    var byKey: [HotKeyKey: [HotKeyManager.Kind]] = [:]
    for (k, s) in specs {
      byKey[key(s), default: []].append(k)
    }

    let priority: [HotKeyManager.Kind] = [preferred, .grab, .quickChat, .threads].compactMap { $0 }

    func winner(for kinds: [HotKeyManager.Kind]) -> HotKeyManager.Kind {
      for p in priority where kinds.contains(p) { return p }
      return kinds.first!
    }

    // Decide winners for each duplicated key up front.
    var winnerByKey: [HotKeyKey: HotKeyManager.Kind] = [:]
    for (hk, kinds) in byKey where kinds.count > 1 {
      winnerByKey[hk] = winner(for: kinds)
    }

    // Seed the used set with winners and already-unique keys to make fallback selection deterministic.
    var used = Set<HotKeyKey>()
    for (hk, kinds) in byKey {
      if kinds.count == 1 {
        used.insert(hk)
      } else if let w = winnerByKey[hk], kinds.contains(w) {
        used.insert(hk)
      }
    }

    // Assign unique bindings for the losers.
    for (hk, kinds) in byKey where kinds.count > 1 {
      guard let w = winnerByKey[hk] else { continue }
      let losers = kinds.filter { $0 != w }
      for loser in losers {
        let fallback = nextAvailableFallback(for: loser, used: used)
        specs[loser] = fallback
        used.insert(key(fallback))
      }
    }

    appSettings.grabHotKeySpec = specs[.grab] ?? appSettings.grabHotKeySpec
    appSettings.quickChatHotKeySpec = specs[.quickChat] ?? appSettings.quickChatHotKeySpec
    appSettings.threadsHotKeySpec = specs[.threads] ?? appSettings.threadsHotKeySpec
  }

  private func nextAvailableFallback(for kind: HotKeyManager.Kind, used: Set<HotKeyKey>) -> HotKeyManager.Spec {
    let candidates: [HotKeyManager.Spec] = {
      switch kind {
      case .grab:
        return [
          .init(keyCode: UInt32(kVK_ANSI_G), modifiers: UInt32(cmdKey)),
          .init(keyCode: UInt32(kVK_ANSI_G), modifiers: UInt32(cmdKey | shiftKey)),
          .init(keyCode: UInt32(kVK_ANSI_G), modifiers: UInt32(cmdKey | optionKey)),
          .init(keyCode: UInt32(kVK_ANSI_G), modifiers: UInt32(cmdKey | controlKey)),
        ]
      case .quickChat:
        return [
          .init(keyCode: UInt32(kVK_ANSI_G), modifiers: UInt32(cmdKey | shiftKey)),
          .init(keyCode: UInt32(kVK_ANSI_G), modifiers: UInt32(cmdKey | optionKey)),
          .init(keyCode: UInt32(kVK_ANSI_G), modifiers: UInt32(cmdKey | controlKey)),
          .init(keyCode: UInt32(kVK_ANSI_Q), modifiers: UInt32(cmdKey | shiftKey)),
        ]
      case .threads:
        return [
          .init(keyCode: UInt32(kVK_ANSI_T), modifiers: UInt32(cmdKey | shiftKey)),
          .init(keyCode: UInt32(kVK_ANSI_T), modifiers: UInt32(cmdKey | optionKey)),
          .init(keyCode: UInt32(kVK_ANSI_T), modifiers: UInt32(cmdKey | controlKey)),
          .init(keyCode: UInt32(kVK_ANSI_B), modifiers: UInt32(cmdKey | shiftKey)),
        ]
      @unknown default:
        return [.init(keyCode: UInt32(kVK_ANSI_G), modifiers: UInt32(cmdKey | shiftKey))]
      }
    }()

    for c in candidates {
      let hk = HotKeyKey(keyCode: c.keyCode, modifiers: c.modifiers)
      if !used.contains(hk) { return c }
    }

    // As a last resort, add option to the default.
    let d = candidates.first ?? .init(keyCode: UInt32(kVK_ANSI_G), modifiers: UInt32(cmdKey | shiftKey))
    return .init(keyCode: d.keyCode, modifiers: d.modifiers | UInt32(optionKey))
  }

  @objc private func configureAPIKey() {
    promptForAPIKey(required: false)
  }

  @objc private func testAPIKey() {
    guard let apiKey = apiKeyStore.loadAPIKey() else {
      promptForAPIKey(required: true)
      return
    }

    Task { @MainActor in
      do {
        _ = try await OpenAIClient(apiKey: apiKey).validateCredentials()
        ResultPresenter.presentMessage(title: "API key looks good", message: "Successfully authenticated with OpenAI.")
      } catch {
        ResultPresenter.presentError(title: "API key test failed", error: error)
      }
    }
  }

  @objc private func removeAPIKey() {
    let alert = NSAlert()
    alert.messageText = "Remove stored API key?"
    alert.informativeText = "This deletes your key from macOS Keychain. You can add it again later."
    alert.alertStyle = .warning
    alert.addButton(withTitle: "Remove")
    alert.addButton(withTitle: "Cancel")
    if alert.runModal() == .alertFirstButtonReturn {
      do {
        try apiKeyStore.deleteAPIKey()
        updateAPIKeyMenuState()
      } catch {
        ResultPresenter.presentError(title: "Could not remove key", error: error)
      }
    }
  }

  @objc private func toggleSendConfirmation(_ sender: NSMenuItem) {
    appSettings.requireConfirmationBeforeSend.toggle()
    sender.state = appSettings.requireConfirmationBeforeSend ? .on : .off
  }

  @objc private func setAutoClearClipboard(_ sender: NSMenuItem) {
    guard let seconds = sender.representedObject as? Int else { return }
    appSettings.autoClearClipboardSeconds = seconds
    updateAutoClearMenuState()
  }

  private func promptForAPIKey(required: Bool) {
    let alert = NSAlert()
    alert.messageText = required ? "Set your OpenAI API key" : "Update OpenAI API key"
    alert.informativeText = "Your key is stored in macOS Keychain and never written to logs or plist files."
    alert.alertStyle = .informational
    alert.addButton(withTitle: "Save")
    alert.addButton(withTitle: "Cancel")

    let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
    field.placeholderString = "sk-..."
    alert.accessoryView = field

    let response = alert.runModal()
    guard response == .alertFirstButtonReturn else { return }

    let key = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !key.isEmpty else {
      ResultPresenter.presentMessage(title: "No key saved", message: "Please enter a non-empty API key.")
      return
    }

    do {
      try apiKeyStore.saveAPIKey(key)
      updateAPIKeyMenuState()
    } catch {
      ResultPresenter.presentError(title: "Could not store API key", error: error)
    }
  }

  private func updateAPIKeyMenuState() {
    if let key = apiKeyStore.loadAPIKey() {
      apiKeyStatusMenuItem?.title = "API Key: \(maskedKey(key))"
    } else {
      apiKeyStatusMenuItem?.title = "API Key: Not set"
    }
  }

  private func maskedKey(_ key: String) -> String {
    let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count > 8 else { return "••••••••" }
    return "\(trimmed.prefix(4))••••\(trimmed.suffix(4))"
  }

  private func updateAutoClearMenuState() {
    let selected = appSettings.autoClearClipboardSeconds
    for item in autoClearItems {
      let seconds = (item.representedObject as? Int) ?? 0
      item.state = (seconds == selected) ? .on : .off
    }
  }

  private func confirmOutgoingData(contextText: String, imageBytes: Int) -> Bool {
    let alert = NSAlert()
    alert.messageText = "Send capture to OpenAI?"
    alert.informativeText =
      "The selected image region (\(imageBytes) bytes) and your optional context (\(contextText.count) chars) will be sent over HTTPS."
    alert.alertStyle = .informational
    alert.addButton(withTitle: "Send")
    alert.addButton(withTitle: "Cancel")
    return alert.runModal() == .alertFirstButtonReturn
  }

  private func copyToClipboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)

    clipboardClearTask?.cancel()
    let seconds = appSettings.autoClearClipboardSeconds
    guard seconds > 0 else { return }

    let task = DispatchWorkItem {
      NSPasteboard.general.clearContents()
    }
    clipboardClearTask = task
    DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(seconds), execute: task)
  }

  private func startGrabFlow() {
    // Prevent re-entrancy.
    if selectionCoordinator.isActive { return }

    selectionCoordinator.beginSelection { [weak self] rect in
      guard let self else { return }
      guard let rect else { return }

      Task { @MainActor in
        do {
          let pngData = try await Screenshotter.capturePNG(cocoaGlobalRect: rect)
          let existingThreads = self.captureThreadControllers()
          switch self.pickThreadTarget(threads: existingThreads) {
          case .existing(let target):
            target.setPendingScreenshot(pngData)
            return
          case .cancel:
            return
          case .newThread:
            break
          }

          let wc = ContextPromptWindowController.present(
            previewPNGData: pngData,
            initialText: "",
            onSend: { [weak self] wc, request in
              guard let self else { return }
              Task { @MainActor in
                await self.performSend(wc: wc, request: request)
              }
            },
            onComplete: { [weak self] wc, _ in
              // Release the controller when the window closes/cancels.
              self?.contextPromptWCs.removeAll(where: { $0 === wc })
            }
          )

          // Retain the window controller; otherwise it can be deallocated while the window is still visible.
          self.contextPromptWCs.append(wc)
        } catch {
          ResultPresenter.presentError(title: "Screenshot failed", error: error)
        }
      }
    }
  }

  private enum ThreadPickResult {
    case newThread
    case existing(ContextPromptWindowController)
    case cancel
  }

  @MainActor
  private func captureThreadControllers() -> [ContextPromptWindowController] {
    // Prefer our retained controllers, but also scan windows to be robust.
    var all = contextPromptWCs
    for win in NSApp.windows {
      if let wc = win.windowController as? ContextPromptWindowController, !all.contains(where: { $0 === wc }) {
        all.append(wc)
      }
    }
    return all.filter { $0.window?.isVisible == true }
  }

  @MainActor
  private func pickThreadTarget(threads: [ContextPromptWindowController]) -> ThreadPickResult {
    guard !threads.isEmpty else { return .newThread }

    let alert = NSAlert()
    alert.messageText = "Send screenshot to…"
    alert.informativeText = "Choose a new thread or attach this screenshot to an existing thread."
    alert.alertStyle = .informational
    alert.addButton(withTitle: "Continue")
    alert.addButton(withTitle: "Cancel")

    let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 360, height: 26))
    popup.addItem(withTitle: "New thread")
    for t in threads {
      popup.addItem(withTitle: t.window?.title ?? "Thread")
    }
    alert.accessoryView = popup

    let resp = alert.runModal()
    guard resp == .alertFirstButtonReturn else { return .cancel }
    let idx = popup.indexOfSelectedItem
    if idx == 0 { return .newThread }
    return .existing(threads[idx - 1])
  }

  @MainActor
  private func performSend(wc: ContextPromptWindowController, request: ContextPromptWindowController.OutgoingRequest) async {
    guard let apiKey = apiKeyStore.loadAPIKey() else {
      wc.setStatus("Missing API key", isLoading: false)
      wc.setResponseText("Error: Missing API key.\n\nUse the menubar menu to set your API key.")
      promptForAPIKey(required: true)
      return
    }

    if let imagePNG = request.imagePNG,
       appSettings.requireConfirmationBeforeSend &&
        !confirmOutgoingData(contextText: request.userText, imageBytes: imagePNG.count) {
      wc.setStatus("Send cancelled", isLoading: false)
      return
    }

    wc.setStatus("Sending to OpenAI…", isLoading: true)
    wc.clearDebug()
    wc.appendDebug("Send clicked (imageBytes=\(request.imagePNG?.count ?? 0), textChars=\(request.userText.count), previous=\(request.previousResponseId ?? "<nil>"))")

    do {
      let streamingClient = OpenAIClient(apiKey: apiKey)
      let result = try await streamingClient.captureThreadStreaming(
        imagePNG: request.imagePNG,
        userText: request.userText,
        previousResponseId: request.previousResponseId,
        onDelta: { delta in
          wc.appendResponseDelta(delta)
        },
        onDebug: { line in
          wc.appendDebug(line)
        }
      )

      wc.setResponseText(result.text)
      wc.setPreviousResponseId(result.responseId)
      if request.imagePNG != nil {
        wc.clearPendingScreenshot()
      }
      copyToClipboard(result.text)
      wc.setStatus("Done (copied to clipboard)", isLoading: false)
      wc.appendDebug("Done (chars=\(result.text.count), responseId=\(result.responseId ?? "<nil>"))")
    } catch {
      wc.setStatus("OpenAI request failed", isLoading: false)
      wc.setResponseText("Error:\n\(String(describing: error))")
      wc.appendDebug("Error: \(String(describing: error))")
    }
  }

  @MainActor
  private func sendToOpenAI(pngData: Data, context: String) async {
    do {
      guard let apiKey = apiKeyStore.loadAPIKey() else {
        ResultPresenter.presentMessage(
          title: "Missing API key",
          message: "Set your API key from the menubar menu."
        )
        return
      }

      let client = OpenAIClient(apiKey: apiKey)
      let text = try await client.describe(imagePNG: pngData, userContext: context)
      ResultPresenter.presentResult(text: text)
    } catch {
      ResultPresenter.presentError(title: "OpenAI request failed", error: error)
    }
  }
}

final class AppSettings {
  static let shared = AppSettings()

  private enum Keys {
    static let requireConfirmationBeforeSend = "requireConfirmationBeforeSend"
    static let autoClearClipboardSeconds = "autoClearClipboardSeconds"
    static let grabHotKeySpec = "grabHotKeySpec.v1"
    static let quickChatHotKeySpec = "quickChatHotKeySpec.v1"
    static let threadsHotKeySpec = "threadsHotKeySpec.v1"
    static let quickChatThreadMode = "quickChatThreadMode.v1"
    static let quickChatThreadId = "quickChatThreadId.v1"
  }

  private let defaults = UserDefaults.standard

  var requireConfirmationBeforeSend: Bool {
    get {
      if defaults.object(forKey: Keys.requireConfirmationBeforeSend) == nil {
        return true
      }
      return defaults.bool(forKey: Keys.requireConfirmationBeforeSend)
    }
    set { defaults.set(newValue, forKey: Keys.requireConfirmationBeforeSend) }
  }

  var autoClearClipboardSeconds: Int {
    get { defaults.integer(forKey: Keys.autoClearClipboardSeconds) }
    set { defaults.set(max(0, newValue), forKey: Keys.autoClearClipboardSeconds) }
  }

  var grabHotKeySpec: HotKeyManager.Spec {
    get { loadHotKeySpec(key: Keys.grabHotKeySpec) ?? .init(keyCode: UInt32(kVK_ANSI_G), modifiers: UInt32(cmdKey)) }
    set { saveHotKeySpec(newValue, key: Keys.grabHotKeySpec) }
  }

  var quickChatHotKeySpec: HotKeyManager.Spec {
    get { loadHotKeySpec(key: Keys.quickChatHotKeySpec) ?? .init(keyCode: UInt32(kVK_ANSI_G), modifiers: UInt32(cmdKey | shiftKey)) }
    set { saveHotKeySpec(newValue, key: Keys.quickChatHotKeySpec) }
  }

  var threadsHotKeySpec: HotKeyManager.Spec {
    get { loadHotKeySpec(key: Keys.threadsHotKeySpec) ?? .init(keyCode: UInt32(kVK_ANSI_T), modifiers: UInt32(cmdKey | shiftKey)) }
    set { saveHotKeySpec(newValue, key: Keys.threadsHotKeySpec) }
  }

  enum QuickChatThreadMode: String {
    case newThreadEveryTime
    case existingThread
  }

  var quickChatThreadMode: QuickChatThreadMode {
    get {
      let raw = defaults.string(forKey: Keys.quickChatThreadMode) ?? QuickChatThreadMode.newThreadEveryTime.rawValue
      return QuickChatThreadMode(rawValue: raw) ?? .newThreadEveryTime
    }
    set { defaults.set(newValue.rawValue, forKey: Keys.quickChatThreadMode) }
  }

  var quickChatThreadId: UUID? {
    get {
      guard let s = defaults.string(forKey: Keys.quickChatThreadId) else { return nil }
      return UUID(uuidString: s)
    }
    set {
      if let newValue {
        defaults.set(newValue.uuidString, forKey: Keys.quickChatThreadId)
      } else {
        defaults.removeObject(forKey: Keys.quickChatThreadId)
      }
    }
  }

  var grabHotKeyDisplay: String { hotKeyDisplay(spec: grabHotKeySpec) }
  var quickChatHotKeyDisplay: String { hotKeyDisplay(spec: quickChatHotKeySpec) }
  var threadsHotKeyDisplay: String { hotKeyDisplay(spec: threadsHotKeySpec) }

  private func loadHotKeySpec(key: String) -> HotKeyManager.Spec? {
    guard let data = defaults.data(forKey: key) else { return nil }
    do {
      return try JSONDecoder().decode(HotKeyManager.Spec.self, from: data)
    } catch {
      return nil
    }
  }

  private func saveHotKeySpec(_ spec: HotKeyManager.Spec, key: String) {
    do {
      let data = try JSONEncoder().encode(spec)
      defaults.set(data, forKey: key)
    } catch {
      // Ignore persistence failures.
    }
  }

  private func hotKeyDisplay(spec: HotKeyManager.Spec) -> String {
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

final class APIKeyStore {
  enum KeychainError: Error, CustomStringConvertible {
    case unexpectedStatus(OSStatus)
    case badData

    var description: String {
      switch self {
      case .unexpectedStatus(let status):
        return "Keychain operation failed (\(status))."
      case .badData:
        return "Stored key data is invalid."
      }
    }
  }

  static let shared = APIKeyStore()

  private let service = "com.agentview.openai"
  private let account = "user_api_key"

  // In-memory cache to avoid repeated keychain prompts during one app session.
  private var cachedKey: String?

  func saveAPIKey(_ key: String) throws {
    let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let data = trimmed.data(using: .utf8) else { throw KeychainError.badData }

    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account
    ]

    let update: [String: Any] = [
      kSecValueData as String: data,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    ]

    let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
    if status == errSecItemNotFound {
      var add = query
      add[kSecValueData as String] = data
      add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      let addStatus = SecItemAdd(add as CFDictionary, nil)
      guard addStatus == errSecSuccess else { throw KeychainError.unexpectedStatus(addStatus) }
      cachedKey = trimmed
      return
    }

    guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
    cachedKey = trimmed
  }

  func loadAPIKey() -> String? {
    if let cachedKey, !cachedKey.isEmpty { return cachedKey }

    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne
    ]

    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    guard status != errSecItemNotFound else { return nil }
    guard status == errSecSuccess,
          let data = item as? Data,
          let key = String(data: data, encoding: .utf8)?
          .trimmingCharacters(in: .whitespacesAndNewlines),
          !key.isEmpty else {
      return nil
    }
    cachedKey = key
    return key
  }

  func deleteAPIKey() throws {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account
    ]
    let status = SecItemDelete(query as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw KeychainError.unexpectedStatus(status)
    }
    cachedKey = nil
  }
}


