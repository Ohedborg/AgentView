import AppKit
import AVFoundation
import SwiftUI

@MainActor
final class ThreadRegistry: ObservableObject {
  static let shared = ThreadRegistry()

  struct PersistedMessage: Codable, Equatable {
    let role: String
    var text: String
    let createdAt: Date
  }

  struct Snapshot: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var updatedAt: Date
    var previousResponseId: String?
    var messages: [PersistedMessage]
  }

  struct Entry: Identifiable, Equatable {
    let id: UUID
    var title: String
    var updatedAt: Date
    var isOpen: Bool
  }

  @Published private(set) var entries: [Entry] = []

  private let defaults = UserDefaults.standard
  private let defaultsKey = "AgentView.savedThreads.v1"

  private var snapshots: [Snapshot] = []
  private var controllers: [UUID: ContextPromptWindowController] = [:]
  private var saveWorkItem: DispatchWorkItem?

  private init() {
    load()
    rebuildEntries()
  }

  func allSnapshots() -> [Snapshot] {
    snapshots.sorted { $0.updatedAt > $1.updatedAt }
  }

  func snapshot(id: UUID) -> Snapshot? {
    snapshots.first(where: { $0.id == id })
  }

  func register(
    id: UUID,
    title: String,
    controller: ContextPromptWindowController,
    previousResponseId: String?,
    messages: [PersistedMessage]
  ) {
    controllers[id] = controller
    upsertSnapshot(id: id, title: title, previousResponseId: previousResponseId, messages: messages)
    rebuildEntries()
    scheduleSave()
  }

  func unregister(id: UUID) {
    controllers[id] = nil
    rebuildEntries()
    scheduleSave()
  }

  func update(id: UUID, title: String? = nil, previousResponseId: String? = nil, messages: [PersistedMessage]? = nil) {
    guard let idx = snapshots.firstIndex(where: { $0.id == id }) else { return }
    snapshots[idx].updatedAt = Date()
    if let title { snapshots[idx].title = title }
    if let previousResponseId { snapshots[idx].previousResponseId = previousResponseId }
    if let messages { snapshots[idx].messages = messages }
    rebuildEntries()
    scheduleSave()
  }

  func focusOrOpen(id: UUID) {
    update(id: id)
    if let wc = controllers[id] {
      wc.window?.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
      return
    }

    guard let snap = snapshot(id: id) else { return }
    ContextPromptWindowController.presentSavedThread(snapshot: snap)
  }

  func clearHistoryKeepingOpenThreads() {
    let openIds = Set(controllers.keys)
    snapshots = snapshots.filter { openIds.contains($0.id) }
    if snapshots.isEmpty {
      defaults.removeObject(forKey: defaultsKey)
    }
    rebuildEntries()
    scheduleSave()
  }

  func createDetachedThread(
    title: String,
    previousResponseId: String?,
    messages: [PersistedMessage]
  ) -> UUID {
    let id = UUID()
    upsertSnapshot(id: id, title: title, previousResponseId: previousResponseId, messages: messages)
    rebuildEntries()
    scheduleSave()
    return id
  }

  func appendMessages(
    to id: UUID,
    title: String? = nil,
    previousResponseId: String? = nil,
    messages newMessages: [PersistedMessage]
  ) {
    if snapshot(id: id) == nil {
      let fallbackTitle = title ?? "Untitled"
      upsertSnapshot(id: id, title: fallbackTitle, previousResponseId: previousResponseId, messages: newMessages)
      rebuildEntries()
      scheduleSave()
      return
    }

    let existing = snapshot(id: id)?.messages ?? []
    let combined = Array((existing + newMessages).suffix(200))
    update(id: id, title: title, previousResponseId: previousResponseId, messages: combined)
  }

  private func upsertSnapshot(id: UUID, title: String, previousResponseId: String?, messages: [PersistedMessage]) {
    let cappedMessages = Array(messages.suffix(200))
    if let idx = snapshots.firstIndex(where: { $0.id == id }) {
      snapshots[idx].title = title
      snapshots[idx].updatedAt = Date()
      if let previousResponseId { snapshots[idx].previousResponseId = previousResponseId }
      if !cappedMessages.isEmpty { snapshots[idx].messages = cappedMessages }
    } else {
      snapshots.append(.init(id: id, title: title, updatedAt: Date(), previousResponseId: previousResponseId, messages: cappedMessages))
      // Keep the list bounded.
      snapshots.sort { $0.updatedAt > $1.updatedAt }
      if snapshots.count > 50 {
        snapshots = Array(snapshots.prefix(50))
      }
    }
  }

  private func rebuildEntries() {
    let openIds = Set(controllers.keys)
    entries = snapshots
      .sorted { $0.updatedAt > $1.updatedAt }
      .map { s in
        Entry(id: s.id, title: s.title, updatedAt: s.updatedAt, isOpen: openIds.contains(s.id))
      }
  }

  private func load() {
    guard let data = defaults.data(forKey: defaultsKey) else {
      snapshots = []
      return
    }
    do {
      let dec = JSONDecoder()
      dec.dateDecodingStrategy = .iso8601
      snapshots = try dec.decode([Snapshot].self, from: data)
      // Best-effort: upgrade old generic titles ("Thread 1") into meaningful names from the first messages.
      var didChange = false
      for i in snapshots.indices {
        if autoTitleIfNeeded(&snapshots[i]) {
          didChange = true
        }
      }
      if didChange {
        scheduleSave()
      }
    } catch {
      snapshots = []
    }
  }

  @discardableResult
  private func autoTitleIfNeeded(_ snap: inout Snapshot) -> Bool {
    guard snap.title.hasPrefix("Thread ") else { return false }
    let firstUser = snap.messages.first(where: { $0.role == "user" && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })?.text
    let firstAssistant = snap.messages.first(where: { $0.role == "assistant" && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })?.text
    let base = (firstUser?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) ? firstUser! : (firstAssistant ?? "")
    let suggestion = suggestedTitle(from: base)
    guard !suggestion.isEmpty else { return false }
    snap.title = suggestion
    return true
  }

  private func suggestedTitle(from text: String) -> String {
    var s = text
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
    return s
  }

  private func scheduleSave() {
    saveWorkItem?.cancel()
    let work = DispatchWorkItem { [weak self] in
      self?.saveNow()
    }
    saveWorkItem = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
  }

  private func saveNow() {
    let enc = JSONEncoder()
    enc.outputFormatting = [.sortedKeys]
    enc.dateEncodingStrategy = .iso8601
    do {
      let data = try enc.encode(snapshots.sorted { $0.updatedAt > $1.updatedAt })
      defaults.set(data, forKey: defaultsKey)
    } catch {
      // Ignore persistence failures.
    }
  }
}

@MainActor
final class ContextPromptWindowController: NSWindowController, NSWindowDelegate {
  private var onComplete: ((ContextPromptWindowController, String?) -> Void)?
  private var onSend: ((ContextPromptWindowController, OutgoingRequest) -> Void)?

  private let model: Model
  private var activeAssistantMessageID: UUID?
  private static weak var tabGroupWindow: NSWindow?
  private static var nextThreadNumber: Int = 1
  private static var defaultOnSend: ((ContextPromptWindowController, OutgoingRequest) -> Void)?
  private static var defaultOnComplete: ((ContextPromptWindowController, String?) -> Void)?

  static func configureDefaultHandlers(
    onSend: @escaping (ContextPromptWindowController, OutgoingRequest) -> Void,
    onComplete: @escaping (ContextPromptWindowController, String?) -> Void
  ) {
    Self.defaultOnSend = onSend
    Self.defaultOnComplete = onComplete
  }

  struct OutgoingRequest: Equatable {
    let imagePNG: Data?
    let userText: String
    let previousResponseId: String?
  }

  private var pendingScreenshotPNG: Data?
  private var lastScreenshotPNG: Data?
  private let threadId: UUID
  private var threadTitle: String
  private var hasCustomTitle: Bool

  @discardableResult
  static func present(
    previewPNGData: Data,
    initialText: String,
    onSend: @escaping (ContextPromptWindowController, OutgoingRequest) -> Void,
    onComplete: @escaping (ContextPromptWindowController, String?) -> Void
  ) -> ContextPromptWindowController {
    Self.defaultOnSend = onSend
    Self.defaultOnComplete = onComplete

    let threadNumber = Self.nextThreadNumber
    Self.nextThreadNumber += 1
    let threadId = UUID()
    let threadTitle = "Thread \(threadNumber)"

    let previewImage = NSImage(data: previewPNGData) ?? NSImage()
    let model = Model(previewImage: previewImage, draftText: initialText)
    let wc = ContextPromptWindowController(
      model: model,
      pendingScreenshotPNG: previewPNGData,
      threadId: threadId,
      threadTitle: threadTitle
    )
    wc.onSend = onSend
    wc.onComplete = onComplete
    if let existing = Self.tabGroupWindow, let newWindow = wc.window, existing.isVisible {
      existing.addTabbedWindow(newWindow, ordered: .above)
      newWindow.makeKeyAndOrderFront(nil)
    } else {
      Self.tabGroupWindow = wc.window
      wc.showWindow(nil)
      wc.window?.makeKeyAndOrderFront(nil)
    }
    NSApp.activate(ignoringOtherApps: true)
    return wc
  }

  @discardableResult
  static func presentSavedThread(snapshot: ThreadRegistry.Snapshot) -> ContextPromptWindowController? {
    guard let onSend = Self.defaultOnSend, let onComplete = Self.defaultOnComplete else {
      return nil
    }

    let placeholder = NSImage(systemSymbolName: "bubble.left.and.bubble.right", accessibilityDescription: "Thread") ?? NSImage()
    let model = Model(previewImage: placeholder, draftText: "")
    model.previousResponseId = snapshot.previousResponseId
    model.messages = snapshot.messages.map { pm in
      let role = Model.ChatRole(rawValue: pm.role) ?? .user
      return Model.ChatMessage(id: UUID(), role: role, text: pm.text, createdAt: pm.createdAt)
    }
    model.responseText = model.messages.last(where: { $0.role == .assistant })?.text ?? ""
    model.hasPendingScreenshot = false

    let wc = ContextPromptWindowController(
      model: model,
      pendingScreenshotPNG: nil,
      threadId: snapshot.id,
      threadTitle: snapshot.title
    )
    wc.onSend = onSend
    wc.onComplete = onComplete
    if let existing = Self.tabGroupWindow, let newWindow = wc.window, existing.isVisible {
      existing.addTabbedWindow(newWindow, ordered: .above)
      newWindow.makeKeyAndOrderFront(nil)
    } else {
      Self.tabGroupWindow = wc.window
      wc.showWindow(nil)
      wc.window?.makeKeyAndOrderFront(nil)
    }
    NSApp.activate(ignoringOtherApps: true)
    return wc
  }

  init(model: Model, pendingScreenshotPNG: Data?, threadId: UUID, threadTitle: String) {
    self.model = model
    self.pendingScreenshotPNG = pendingScreenshotPNG
    self.lastScreenshotPNG = pendingScreenshotPNG
    self.threadId = threadId
    self.threadTitle = threadTitle
    self.hasCustomTitle = !threadTitle.hasPrefix("Thread ")
    self.model.hasPendingScreenshot = (pendingScreenshotPNG != nil)

    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 860, height: 620),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false
    )

    window.title = threadTitle
    window.center()
    window.isMovableByWindowBackground = true
    window.titlebarAppearsTransparent = true
    window.toolbarStyle = .unifiedCompact
    window.tabbingMode = .preferred
    window.tabbingIdentifier = "AgentViewCapture"

    super.init(window: window)
    window.delegate = self
    ThreadRegistry.shared.register(
      id: threadId,
      title: window.title,
      controller: self,
      previousResponseId: model.previousResponseId,
      messages: Self.persistedMessages(from: model.messages)
    )

    let root = ContextPromptView(
      model: model,
      registry: ThreadRegistry.shared,
      currentThreadId: threadId,
      onSend: { [weak self] in
        guard let self else { return }
        let trimmed = self.model.draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasPendingScreenshot = (self.pendingScreenshotPNG != nil)
        if !hasPendingScreenshot && trimmed.isEmpty { return }

        self.maybeUpdateThreadTitleFromFirstUserMessage(trimmed)

        let userBubbleText: String = {
          if !trimmed.isEmpty { return trimmed }
          if hasPendingScreenshot { return "Sent screenshot." }
          return ""
        }()

        if !userBubbleText.isEmpty {
          self.beginTurn(role: .user, text: userBubbleText)
        }

        self.beginAssistantPlaceholder()

        let fallbackImagePNG: Data? = {
          // If we failed to capture a usable `previous_response_id` in earlier turns,
          // keep including the latest screenshot so the conversation stays coherent.
          if self.model.previousResponseId == nil, !self.model.messages.isEmpty {
            return self.lastScreenshotPNG
          }
          return nil
        }()

        let req = OutgoingRequest(
          imagePNG: self.pendingScreenshotPNG ?? fallbackImagePNG,
          userText: trimmed,
          previousResponseId: self.model.previousResponseId
        )

        self.onSend?(self, req)
        self.model.draftText = ""
      },
      onVoiceNoteFile: { [weak self] url in
        guard let self else { return }
        Task { @MainActor in
          await self.handleVoiceNote(url: url)
        }
      },
      onCancel: { [weak self] in
        guard let self else { return }
        self.complete(value: nil)
        self.window?.close()
      }
    )

    let hosting = NSHostingController(rootView: root)
    hosting.view.frame = window.contentView?.bounds ?? .zero
    hosting.view.autoresizingMask = [.width, .height]
    window.contentViewController = hosting
  }

  required init?(coder: NSCoder) {
    nil
  }

  func windowWillClose(_ notification: Notification) {
    if Self.tabGroupWindow === window {
      Self.tabGroupWindow = window?.tabbedWindows?.first
    }
    ThreadRegistry.shared.unregister(id: threadId)
    complete(value: nil)
  }

  private static func persistedMessages(from messages: [Model.ChatMessage]) -> [ThreadRegistry.PersistedMessage] {
    messages.map { m in
      ThreadRegistry.PersistedMessage(role: m.role.rawValue, text: m.text, createdAt: m.createdAt)
    }
  }

  private func complete(value: String?) {
    guard let cb = onComplete else { return }
    onComplete = nil
    cb(self, value)
    close()
  }

  var previousResponseId: String? { model.previousResponseId }

  func setPreviousResponseId(_ id: String?) {
    model.previousResponseId = id
    ThreadRegistry.shared.update(
      id: threadId,
      previousResponseId: id,
      messages: Self.persistedMessages(from: model.messages)
    )
  }

  var hasPendingScreenshot: Bool { pendingScreenshotPNG != nil }

  func clearPendingScreenshot() {
    pendingScreenshotPNG = nil
    model.hasPendingScreenshot = false
  }

  func setPendingScreenshot(_ pngData: Data) {
    pendingScreenshotPNG = pngData
    model.hasPendingScreenshot = true
    lastScreenshotPNG = pngData
    model.previewImage = NSImage(data: pngData) ?? NSImage()
    window?.makeKeyAndOrderFront(nil)
  }

  var hasAnyMessages: Bool { !model.messages.isEmpty }

  func appendResponseDelta(_ delta: String) {
    guard let activeAssistantMessageID else {
      model.responseText += delta
      return
    }
    model.appendDelta(toMessageID: activeAssistantMessageID, delta: delta)
    model.responseText = model.messages.last(where: { $0.role == .assistant })?.text ?? model.responseText
    model.requestScrollToBottom(throttled: true)
    ThreadRegistry.shared.update(id: threadId)
  }

  func setResponseText(_ text: String) {
    if let activeAssistantMessageID {
      model.setText(forMessageID: activeAssistantMessageID, text: text)
    }
    model.responseText = text
    model.requestScrollToBottom(throttled: true)
    ThreadRegistry.shared.update(id: threadId, messages: Self.persistedMessages(from: model.messages))
  }

  func setStatus(_ text: String, isLoading: Bool) {
    model.statusText = text
    model.isLoading = isLoading
  }

  private func maybeUpdateThreadTitleFromFirstUserMessage(_ trimmedUserText: String) {
    guard !hasCustomTitle else { return }
    guard !trimmedUserText.isEmpty else { return }
    guard threadTitle.hasPrefix("Thread ") else { return }

    let suggestion = Self.suggestedTitle(from: trimmedUserText)
    guard !suggestion.isEmpty else { return }

    hasCustomTitle = true
    threadTitle = suggestion
    window?.title = suggestion
    ThreadRegistry.shared.update(
      id: threadId,
      title: suggestion,
      messages: Self.persistedMessages(from: model.messages)
    )
  }

  private static func suggestedTitle(from userText: String) -> String {
    var s = userText
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "\n", with: " ")
    while s.contains("  ") { s = s.replacingOccurrences(of: "  ", with: " ") }
    // Grab the first sentence-ish chunk.
    if let cut = s.firstIndex(where: { ".?!".contains($0) }) {
      let prefix = s[..<cut]
      if prefix.count >= 12 {
        s = String(prefix)
      }
    }
    // Cap to a reasonable window title length.
    if s.count > 44 {
      let idx = s.index(s.startIndex, offsetBy: 44)
      s = String(s[..<idx]).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }
    return s
  }

  func appendDebug(_ line: String) {
    if model.debugText.isEmpty {
      model.debugText = line
      model.showDebug = true
      return
    }
    model.debugText += "\n" + line
  }

  func clearDebug() {
    model.debugText = ""
  }

  private func beginAssistantPlaceholder() {
    let id = UUID()
    activeAssistantMessageID = id
    model.messages.append(.init(id: id, role: .assistant, text: "", createdAt: Date()))
    model.requestScrollToBottom(throttled: false)
    ThreadRegistry.shared.update(id: threadId, messages: Self.persistedMessages(from: model.messages))
  }

  private func beginTurn(role: Model.ChatRole, text: String) {
    model.messages.append(.init(id: UUID(), role: role, text: text, createdAt: Date()))
    model.requestScrollToBottom(throttled: false)
    ThreadRegistry.shared.update(id: threadId, messages: Self.persistedMessages(from: model.messages))
  }

  private func handleVoiceNote(url: URL) async {
    guard let apiKey = APIKeyStore.shared.loadAPIKey() else {
      setStatus("Missing API key", isLoading: false)
      appendDebug("Voice note transcription skipped (missing API key).")
      return
    }

    setStatus("Transcribing voice note…", isLoading: true)
    do {
      let text = try await OpenAIClient(apiKey: apiKey).transcribeAudio(fileURL: url)
      if model.draftText.isEmpty {
        model.draftText = text
      } else {
        model.draftText += "\n" + text
      }
      setStatus("Voice note transcribed", isLoading: false)
      appendDebug("Voice note transcribed (chars=\(text.count)).")
    } catch {
      setStatus("Voice note transcription failed", isLoading: false)
      appendDebug("Voice note transcription failed: \(String(describing: error))")
    }
  }
}

@MainActor
final class VoiceNoteRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate {
  enum VoiceNoteError: Error, CustomStringConvertible {
    case microphonePermissionDenied
    case couldNotCreateRecorder
    case notRecording
    case missingFileURL

    var description: String {
      switch self {
      case .microphonePermissionDenied:
        return "Microphone access is denied. Enable it in System Settings → Privacy & Security → Microphone."
      case .couldNotCreateRecorder:
        return "Could not start audio recording."
      case .notRecording:
        return "Not recording."
      case .missingFileURL:
        return "Missing recorded audio file."
      }
    }
  }

  @Published private(set) var isRecording: Bool = false
  @Published private(set) var isPreparing: Bool = false

  private var recorder: AVAudioRecorder?
  private var outputURL: URL?

  func start() async throws {
    if isRecording || isPreparing { return }
    isPreparing = true
    defer { isPreparing = false }

    let granted = await Self.requestMicrophoneAccessIfNeeded()
    guard granted else { throw VoiceNoteError.microphonePermissionDenied }

    let url = Self.makeTempRecordingURL()
    let settings: [String: Any] = [
      AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
      AVSampleRateKey: 44_100,
      AVNumberOfChannelsKey: 1,
      AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
    ]

    let rec = try AVAudioRecorder(url: url, settings: settings)
    rec.delegate = self
    rec.isMeteringEnabled = false
    rec.prepareToRecord()
    guard rec.record() else { throw VoiceNoteError.couldNotCreateRecorder }

    recorder = rec
    outputURL = url
    isRecording = true
  }

  func stop() throws -> URL {
    guard let recorder, isRecording else { throw VoiceNoteError.notRecording }
    recorder.stop()
    self.recorder = nil
    isRecording = false
    guard let url = outputURL else { throw VoiceNoteError.missingFileURL }
    return url
  }

  nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: (any Error)?) {
    Task { @MainActor [weak self] in
      self?.isRecording = false
    }
  }

  private static func makeTempRecordingURL() -> URL {
    let dir = FileManager.default.temporaryDirectory
    let name = "agentview-voicenote-\(UUID().uuidString).m4a"
    return dir.appendingPathComponent(name)
  }

  private static func requestMicrophoneAccessIfNeeded() async -> Bool {
    let status = AVCaptureDevice.authorizationStatus(for: .audio)
    switch status {
    case .authorized:
      return true
    case .notDetermined:
      return await AVCaptureDevice.requestAccess(for: .audio)
    case .denied, .restricted:
      return false
    @unknown default:
      return false
    }
  }
}

extension ContextPromptWindowController {
  final class Model: ObservableObject {
    @Published var previewImage: NSImage

    enum ChatRole: String {
      case user
      case assistant
    }

    struct ChatMessage: Identifiable, Equatable {
      let id: UUID
      let role: ChatRole
      var text: String
      let createdAt: Date
    }

    @Published var draftText: String
    @Published var responseText: String
    @Published var statusText: String
    @Published var isLoading: Bool
    @Published var hasPendingScreenshot: Bool
    @Published var showDebug: Bool
    @Published var debugText: String
    @Published var previousResponseId: String?
    @Published var messages: [ChatMessage]
    @Published var scrollBump: Int

    init(previewImage: NSImage, draftText: String) {
      self.previewImage = previewImage
      self.draftText = draftText
      self.responseText = ""
      self.statusText = "Ready"
      self.isLoading = false
      self.hasPendingScreenshot = true
      self.showDebug = false
      self.debugText = ""
      self.previousResponseId = nil
      self.messages = []
      self.scrollBump = 0
    }

    private var pendingScrollWorkItem: DispatchWorkItem?

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

    func appendDelta(toMessageID id: UUID, delta: String) {
      guard let idx = messages.firstIndex(where: { $0.id == id }) else { return }
      messages[idx].text += delta
    }

    func setText(forMessageID id: UUID, text: String) {
      guard let idx = messages.firstIndex(where: { $0.id == id }) else { return }
      messages[idx].text = text
    }
  }

  struct ContextPromptView: View {
    @ObservedObject var model: Model
    @ObservedObject var registry: ThreadRegistry
    let currentThreadId: UUID
    var onSend: () -> Void
    var onVoiceNoteFile: (URL) -> Void
    var onCancel: () -> Void

    @StateObject private var voiceRecorder = VoiceNoteRecorder()

    var body: some View {
      VStack(spacing: 16) {
        accentHeader
        header
        content
        footer
      }
      .padding(18)
      .background(.regularMaterial)
      .tint(.accentColor)
    }

    private var accentHeader: some View {
      RoundedRectangle(cornerRadius: 999, style: .continuous)
        .fill(.tint)
        .frame(height: 4)
        .opacity(0.85)
        .padding(.bottom, 2)
    }

    private var header: some View {
      VStack(alignment: .leading, spacing: 6) {
        HStack(alignment: .firstTextBaseline) {
          Text("Capture thread")
            .font(.system(size: 18, weight: .semibold))
          Spacer()

          HStack(spacing: 8) {
            if model.isLoading {
              ProgressView()
                .controlSize(.small)
            }
            Text(model.statusText)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }

        Text("Chat normally. You can also attach another screenshot to an existing thread from the grab flow.")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
    }

    private var content: some View {
      HStack(alignment: .top, spacing: 16) {
        sidebar

        VStack(spacing: 16) {
          GroupBox {
            VStack(alignment: .leading, spacing: 10) {
              threadView
              composerView

              HStack(spacing: 10) {
                Button {
                  NSPasteboard.general.clearContents()
                  NSPasteboard.general.setString(model.responseText, forType: .string)
                } label: {
                  Label("Copy response", systemImage: "doc.on.doc")
                }
                .disabled(model.responseText.isEmpty)

                Spacer()

                if !model.debugText.isEmpty {
                  Toggle(isOn: $model.showDebug) {
                    Text("Debug")
                  }
                  .toggleStyle(.switch)
                  .controlSize(.small)
                }
              }
            }
            .padding(.top, 2)
          } label: {
            Label("Thread", systemImage: "bubble.left.and.bubble.right")
          }

          if model.showDebug && !model.debugText.isEmpty {
            GroupBox {
              ScrollView {
                Text(model.debugText)
                  .font(.system(size: 11, design: .monospaced))
                  .textSelection(.enabled)
                  .frame(maxWidth: .infinity, alignment: .leading)
                  .padding(10)
              }
              .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                  .fill(.background)
              )
              .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                  .strokeBorder(.separator, lineWidth: 1)
              )
              .frame(minHeight: 120, maxHeight: 160)
              .padding(.top, 2)
            } label: {
              Label("Debug details", systemImage: "ladybug")
            }
          }
        }
        .frame(maxWidth: .infinity)
      }
    }

    private var threadView: some View {
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 10) {
            if model.messages.isEmpty {
              Text("Send to start the thread. After the first response, you can ask follow-up questions here.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
            } else {
              ForEach(model.messages) { msg in
                messageBubble(msg)
                  .id(msg.id)
              }
            }

            Color.clear
              .frame(height: 1)
              .id("BOTTOM")
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(10)
        }
        .background(
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(.background)
        )
        .overlay(
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(.separator, lineWidth: 1)
        )
        .frame(minHeight: 220)
        .onChange(of: model.scrollBump) { _, _ in
          DispatchQueue.main.async {
            proxy.scrollTo("BOTTOM", anchor: .bottom)
          }
        }
      }
    }

    private var sidebar: some View {
      VStack(spacing: 12) {
        previewCard
        ThreadsPanel(
          entries: registry.entries,
          currentThreadId: currentThreadId,
          onSelect: { id in
            registry.focusOrOpen(id: id)
          }
        )
      }
      .frame(width: 280)
    }

    private var previewCard: some View {
      GroupBox {
        VStack(alignment: .leading, spacing: 10) {
          Image(nsImage: model.previewImage)
            .resizable()
            .scaledToFit()
            .frame(minWidth: 220, maxWidth: 260, minHeight: 140, maxHeight: 180)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
              RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.separator, lineWidth: 1)
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 2)
      } label: {
        Label("Preview", systemImage: "photo")
      }
    }

private struct ThreadsPanel: View {
  let entries: [ThreadRegistry.Entry]
  let currentThreadId: UUID
  let onSelect: (UUID) -> Void
  @State private var showingClearConfirm = false

  private var threads: [ThreadRegistry.Entry] {
    var sorted = entries.sorted { $0.updatedAt > $1.updatedAt }
    if let idx = sorted.firstIndex(where: { $0.id == currentThreadId }) {
      let current = sorted.remove(at: idx)
      sorted.insert(current, at: 0)
    }
    return sorted
  }

  var body: some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 8) {
        ScrollView {
          VStack(alignment: .leading, spacing: 6) {
            if threads.isEmpty {
              Text("No other threads yet.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
            } else {
              ForEach(threads) { t in
                threadRow(t)
              }
            }
          }
          .padding(8)
        }
        .frame(maxHeight: 220)
        .background(
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(.background)
        )
        .overlay(
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(.separator, lineWidth: 1)
        )

        HStack {
          Spacer()
          Button("Clear history…") {
            showingClearConfirm = true
          }
          .buttonStyle(.bordered)
          .controlSize(.small)
        }
      }
      .padding(.top, 2)
    } label: {
      Label("Threads", systemImage: "clock.arrow.circlepath")
    }
    .alert("Clear thread history?", isPresented: $showingClearConfirm) {
      Button("Clear", role: .destructive) {
        ThreadRegistry.shared.clearHistoryKeepingOpenThreads()
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("This removes saved (closed) threads. Open threads stay available.")
    }
  }

  @ViewBuilder
  private func threadRow(_ t: ThreadRegistry.Entry) -> some View {
    Button {
      onSelect(t.id)
    } label: {
      HStack(spacing: 8) {
        Image(systemName: t.id == currentThreadId ? "bubble.left.and.bubble.right.fill" : "bubble.left.and.bubble.right")
          .foregroundStyle(t.id == currentThreadId ? Color.accentColor : Color.secondary)
        VStack(alignment: .leading, spacing: 2) {
          Text(t.title)
            .font(.system(size: 12, weight: t.id == currentThreadId ? .semibold : .regular))
            .foregroundStyle(.primary)
            .lineLimit(1)
        }
        Spacer(minLength: 0)
      }
      .padding(.vertical, 6)
      .padding(.horizontal, 8)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .fill(t.id == currentThreadId ? Color.accentColor.opacity(0.12) : Color.clear)
      )
    }
    .buttonStyle(.plain)
  }
}

    private func messageBubble(_ msg: Model.ChatMessage) -> some View {
      HStack {
        if msg.role == .assistant {
          bubble(text: msg.text.isEmpty ? "…" : msg.text, isUser: false)
          Spacer(minLength: 24)
        } else {
          Spacer(minLength: 24)
          bubble(text: msg.text, isUser: true)
        }
      }
    }

    private func bubble(text: String, isUser: Bool) -> some View {
      Text(text)
        .font(.system(size: 12, design: isUser ? .default : .monospaced))
        .foregroundStyle(isUser ? Color.white : Color.primary)
        .textSelection(.enabled)
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(isUser ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.primary.opacity(0.06)))
        )
        .overlay(
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(isUser ? Color.clear : Color.primary.opacity(0.08), lineWidth: 1)
        )
        .frame(maxWidth: 560, alignment: isUser ? .trailing : .leading)
    }

    private var composerView: some View {
      VStack(alignment: .leading, spacing: 8) {
        TextEditor(text: $model.draftText)
          .font(.system(size: 13))
          .scrollContentBackground(.hidden)
          .padding(10)
          .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
              .fill(.background)
          )
          .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
              .strokeBorder(.separator, lineWidth: 1)
          )
          .frame(minHeight: 84, maxHeight: 140)

        HStack {
          Text("\(model.draftText.count) characters")
            .font(.caption)
            .foregroundStyle(.secondary)
          Spacer()

          Button {
            Task { @MainActor in
              do {
                if voiceRecorder.isRecording {
                  let url = try voiceRecorder.stop()
                  onVoiceNoteFile(url)
                } else {
                  try await voiceRecorder.start()
                }
              } catch {
                // Surface as status text; avoid modal alerts.
                model.statusText = String(describing: error)
              }
            }
          } label: {
            Label(voiceRecorder.isRecording ? "Stop" : "Voice", systemImage: voiceRecorder.isRecording ? "stop.circle.fill" : "mic.circle.fill")
          }
          .buttonStyle(.bordered)
          .disabled(model.isLoading || voiceRecorder.isPreparing)

          Button("Clear") { model.draftText = "" }
            .buttonStyle(.link)
            .disabled(model.isLoading || model.draftText.isEmpty)

          Button {
            onSend()
          } label: {
            Label(model.hasPendingScreenshot ? "Send screenshot" : "Send", systemImage: "arrow.up.circle.fill")
          }
          .buttonStyle(.borderedProminent)
          .disabled(model.isLoading || (!model.hasPendingScreenshot && model.draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
        }
      }
    }

    private var footer: some View {
      HStack {
        Button("Cancel", action: onCancel)
          .keyboardShortcut(.cancelAction)
          .disabled(model.isLoading)

        Spacer()
      }
      .controlSize(.large)
    }
  }
}
