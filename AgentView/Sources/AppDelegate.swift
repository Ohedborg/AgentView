import AppKit
import Foundation
import Security

final class AppDelegate: NSObject, NSApplicationDelegate {
  private var statusItem: NSStatusItem!
  private let hotKeyManager = HotKeyManager()
  private let selectionCoordinator = SelectionOverlayCoordinator()
  private let apiKeyStore = APIKeyStore.shared
  private let appSettings = AppSettings.shared
  private var contextPromptWC: ContextPromptWindowController?
  private var apiKeyStatusMenuItem: NSMenuItem?
  private var autoClearItems: [NSMenuItem] = []
  private var clipboardClearTask: DispatchWorkItem?

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
    setupStatusItem()

    hotKeyManager.onHotKey = { [weak self] in
      self?.startGrabFlow()
    }
    hotKeyManager.registerCmdG()

    updateAPIKeyMenuState()
    updateAutoClearMenuState()
    if apiKeyStore.loadAPIKey() == nil {
      promptForAPIKey(required: true)
    }
  }

  private func setupStatusItem() {
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    if let button = statusItem.button {
      button.title = "G"
      button.toolTip = "AgentView"
    }

    let menu = NSMenu()
    menu.addItem(NSMenuItem(title: "Grab (⌘G)", action: #selector(grabFromMenu), keyEquivalent: "g"))
    menu.addItem(.separator())

    let keyStatus = NSMenuItem(title: "API Key: Not set", action: nil, keyEquivalent: "")
    keyStatus.isEnabled = false
    apiKeyStatusMenuItem = keyStatus
    menu.addItem(keyStatus)
    menu.addItem(NSMenuItem(title: "Set API Key…", action: #selector(configureAPIKey), keyEquivalent: "k"))
    menu.addItem(NSMenuItem(title: "Test API Key", action: #selector(testAPIKey), keyEquivalent: "t"))
    menu.addItem(NSMenuItem(title: "Remove API Key", action: #selector(removeAPIKey), keyEquivalent: ""))

    menu.addItem(.separator())

    let confirmItem = NSMenuItem(
      title: "Confirm before sending capture",
      action: #selector(toggleSendConfirmation(_:)),
      keyEquivalent: ""
    )
    confirmItem.state = appSettings.requireConfirmationBeforeSend ? .on : .off
    menu.addItem(confirmItem)

    let autoClearParent = NSMenuItem(title: "Auto-clear clipboard", action: nil, keyEquivalent: "")
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
    menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
    statusItem.menu = menu
  }

  @objc private func grabFromMenu() {
    startGrabFlow()
  }

  @objc private func quit() {
    NSApp.terminate(nil)
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
          let wc = ContextPromptWindowController.present(
            previewPNGData: pngData,
            initialText: "",
            onSend: { [weak self] wc, contextText in
              guard let self else { return }

              Task { @MainActor in
                guard let apiKey = self.apiKeyStore.loadAPIKey() else {
                  wc.setStatus("Missing API key", isLoading: false)
                  wc.setResponseText("Error: Missing API key.\n\nUse the menubar menu to set your API key.")
                  self.promptForAPIKey(required: true)
                  return
                }

                if self.appSettings.requireConfirmationBeforeSend &&
                    !self.confirmOutgoingData(contextText: contextText, imageBytes: pngData.count) {
                  wc.setStatus("Send cancelled", isLoading: false)
                  return
                }

                wc.setResponseText("")
                wc.setStatus("Sending to OpenAI…", isLoading: true)
                wc.clearDebug()
                wc.appendDebug("Send clicked (pngBytes=\(pngData.count), contextChars=\(contextText.count))")
#if DEBUG
                print("[AgentView][UI] Send clicked (pngBytes=\(pngData.count), contextChars=\(contextText.count))")
#endif
                do {
                  let streamingClient = OpenAIClient(apiKey: apiKey)
                  let final = try await streamingClient.describeStreaming(
                    imagePNG: pngData,
                    userContext: contextText,
                    onDelta: { delta in
                      wc.appendResponseDelta(delta)
                    },
                    onDebug: { line in
                      wc.appendDebug(line)
                    }
                  )
                  // Ensure the response box shows the final text even if no incremental deltas were emitted.
                  wc.setResponseText(final)
                  // Keep the response in-place; also copy to clipboard.
                  self.copyToClipboard(final)
                  wc.setStatus("Done (copied to clipboard)", isLoading: false)
                  wc.appendDebug("Done (chars=\(final.count))")
#if DEBUG
                  print("[AgentView][UI] OpenAI done (chars=\(final.count))")
#endif
                } catch {
                  wc.setStatus("OpenAI request failed", isLoading: false)
                  wc.setResponseText("Error:\n\(String(describing: error))")
                  wc.appendDebug("Error: \(String(describing: error))")
#if DEBUG
                  print("[AgentView][UI] OpenAI failed: \(String(describing: error))")
#endif
                }
              }
            },
            onComplete: { [weak self] _ in
              // Release the controller when the window closes/cancels.
              self?.contextPromptWC = nil
            }
          )

          // Retain the window controller; otherwise it can be deallocated while the window is still visible,
          // and then Send/Cancel actions won't fire.
          self.contextPromptWC = wc
        } catch {
          ResultPresenter.presentError(title: "Screenshot failed", error: error)
        }
      }
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
      return
    }

    guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
  }

  func loadAPIKey() -> String? {
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
  }
}


