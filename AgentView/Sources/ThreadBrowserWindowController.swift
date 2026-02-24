import AppKit
import SwiftUI

@MainActor
final class ThreadBrowserWindowController: NSWindowController, NSWindowDelegate {
  static let shared = ThreadBrowserWindowController()

  private let model = Model()

  private init() {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 520, height: 560),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false
    )
    window.title = "Threads"
    window.center()
    window.isMovableByWindowBackground = true
    window.titlebarAppearsTransparent = true
    window.toolbarStyle = .unifiedCompact
    window.tabbingMode = .preferred
    window.tabbingIdentifier = "AgentViewThreads"

    super.init(window: window)
    window.delegate = self

    let root = ThreadBrowserView(
      model: model,
      registry: ThreadRegistry.shared,
      onOpen: { id in
        ThreadRegistry.shared.focusOrOpen(id: id)
      },
      onClear: {
        ThreadRegistry.shared.clearHistoryKeepingOpenThreads()
      },
      onClose: { [weak self] in
        self?.close()
      }
    )
    window.contentViewController = NSHostingController(rootView: root)
  }

  required init?(coder: NSCoder) { nil }

  func show() {
    showWindow(nil)
    window?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  func windowWillClose(_ notification: Notification) {
    model.query = ""
  }
}

extension ThreadBrowserWindowController {
  @MainActor
  final class Model: ObservableObject {
    @Published var query: String = ""
    @Published var showingClearConfirm = false
  }
}

private struct ThreadBrowserView: View {
  @ObservedObject var model: ThreadBrowserWindowController.Model
  @ObservedObject var registry: ThreadRegistry
  let onOpen: (UUID) -> Void
  let onClear: () -> Void
  let onClose: () -> Void

  private var filtered: [ThreadRegistry.Entry] {
    let q = model.query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !q.isEmpty else { return registry.entries }
    return registry.entries.filter { $0.title.lowercased().contains(q) }
  }

  var body: some View {
    VStack(spacing: 12) {
      header
      list
    }
    .padding(14)
    .background(.regularMaterial)
    .alert("Clear thread history?", isPresented: $model.showingClearConfirm) {
      Button("Clear", role: .destructive) { onClear() }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("This removes saved (closed) threads. Open threads stay available.")
    }
  }

  private var header: some View {
    HStack(spacing: 10) {
      Image(systemName: "clock.arrow.circlepath")
        .foregroundStyle(.tint)
      Text("Threads")
        .font(.system(size: 16, weight: .semibold))
      Spacer()

      TextField("Search", text: $model.query)
        .textFieldStyle(.roundedBorder)
        .frame(width: 200)

      Button("Clear history…") { model.showingClearConfirm = true }
        .buttonStyle(.bordered)

      Button {
        onClose()
      } label: {
        Image(systemName: "xmark")
      }
      .buttonStyle(.plain)
    }
  }

  private var list: some View {
    List {
      if filtered.isEmpty {
        Text("No threads.")
          .foregroundStyle(.secondary)
      } else {
        ForEach(filtered) { t in
          HStack(spacing: 10) {
            Image(systemName: t.isOpen ? "bubble.left.and.bubble.right.fill" : "bubble.left.and.bubble.right")
              .foregroundStyle(t.isOpen ? Color.accentColor : Color.secondary)
            Text(t.title)
              .lineLimit(1)
            Spacer()
            Button("Open") { onOpen(t.id) }
              .buttonStyle(.bordered)
          }
        }
      }
    }
    .listStyle(.inset)
  }
}

