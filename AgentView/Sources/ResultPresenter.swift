import AppKit

enum ResultPresenter {
  static func presentResult(text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)

    // NSAlert truncates long text and isn't scrollable; use a proper window instead.
    ResultWindowController.present(title: "OpenAI result (copied to clipboard)", text: text)
  }

  static func presentMessage(title: String, message: String) {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    alert.alertStyle = .informational
    alert.addButton(withTitle: "OK")
    alert.runModal()
  }

  static func presentError(title: String, error: Error) {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = String(describing: error)
    alert.alertStyle = .critical
    alert.addButton(withTitle: "OK")
    alert.runModal()
  }
}



