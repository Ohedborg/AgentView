## AgentView (macOS menubar app)

Background app that:
- Press **CMD+G** to start a drag-selection overlay (rectangle outline only)
- Captures a screenshot of the selected region
- Lets you add optional context text before sending
- Sends image + text to OpenAI and copies the result to clipboard
- Uses user-provided API keys stored in macOS Keychain

### How to run

1. Open Xcode → **File → New → Project… → App** (macOS)
2. Name it `AgentView`, Interface **SwiftUI**, Language **Swift**
3. Copy the Swift files from `AgentView/Sources/` into your Xcode project (add to target)
4. In your app’s `Info.plist`, add:
   - **Application is agent (UIElement)** = `YES` (key: `LSUIElement`)
5. Launch the app and set your API key from the menubar:
   - **Set API Key...** stores the key in macOS Keychain
   - **Test API Key** validates credentials before sending captures
   - **Remove API Key** deletes it from Keychain

### Permissions (required)

macOS will block screen capture until you allow it:
- System Settings → Privacy & Security → **Screen Recording** → enable `AgentView`
- Quit and relaunch the app after granting permission

### Usage

- **CMD+G**: start selection
- Drag to select region
- Release mouse to confirm (or press **Esc** to cancel)
- Enter context text (optional) and press **Send**
- Optional safety controls (menubar):
  - Require confirmation before sending each capture
  - Auto-clear clipboard after a selected delay

### Notes

- Hotkey uses Carbon `RegisterEventHotKey`. If CMD+G conflicts with another app, change it in `HotKeyManager.swift`.
- Screenshot uses `CGWindowListCreateImage` (works across multiple displays).

### App Store production checklist

- Keep API keys in Keychain only (`APIKeyStore`), never in plist, defaults, or logs.
- App Sandbox should stay enabled with minimal entitlements.
- Include a clear screen-capture usage description in app metadata.
- Fill out App Privacy details for screenshot/context transmission to your model provider.


