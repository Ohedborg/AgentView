## AgentView
<img width="600" height="600" alt="ChatGPT Image Feb 24, 2026, 04_06_52 PM" src="https://github.com/user-attachments/assets/8fce158c-0411-48a5-bce6-4ecaa002aede" />


A macOS **menu bar** app for “grab → chat” workflows.

- **Grab** a region of your screen
- Send the screenshot + your prompt to OpenAI (streaming)
- Keep a **persistent conversation thread** per capture (history + reopen)
- Use a **cursor-attached Quick Chat HUD** for fast follow-ups without a screenshot

### Features

- **Threaded capture UI**: chat normally after a screenshot, attach additional screenshots to an existing thread, reopen old threads from history
- **Quick Chat HUD**: pops up near your cursor, streams responses, can target a new or existing thread, and can open the full “Capture thread” window
- **Thread browser**: search/open threads and clear history
- **Hotkey rebinding**: rebind Grab / Quick Chat / Threads, with collision avoidance
- **Voice notes**: record → transcribe → insert into the composer
- **Safety + hygiene**: optional “confirm before sending”, optional auto-clear clipboard

### Requirements

- **macOS 15.5+**
- **Xcode** (to build/run)
- An **OpenAI API key** (stored in macOS Keychain)

### Build & run

1. Open `AgentView.xcodeproj` in Xcode
2. Select the `AgentView` scheme and run
3. From the menu bar icon, choose **Set API Key…**

### Permissions

macOS will prompt for:

- **Screen Recording**: System Settings → Privacy & Security → Screen Recording → enable `AgentView`, then quit/relaunch
- **Microphone** (only for voice notes): System Settings → Privacy & Security → Microphone → enable `AgentView`

### Usage

From the menu bar:

- **Grab**: select a region, then chat in the “Capture thread” window
- **Quick chat**: open the cursor HUD for fast questions (no screenshot)
- **Threads**: browse/search saved threads

### Default hotkeys (configurable)

Defaults may vary if macOS shortcuts collide, but the app ships with:

- **Grab**: `⌘G`

<img width="1736" height="880" alt="image" src="https://github.com/user-attachments/assets/ace8107d-43e1-40cb-9a2d-ee8039ba9a00" />


- **Quick chat**: `⌘⇧G`

<img width="1728" height="885" alt="image" src="https://github.com/user-attachments/assets/ba6f81a5-3dd0-403b-aee9-ca6c9a7e5e4f" />


Rebind via menu bar → **Hotkeys** → “Set … hotkey…”.

### Security & privacy notes

- Your OpenAI API key is stored in **Keychain**, not in `UserDefaults`/plist.
- Captures are only taken from the region you explicitly select.
- If “Confirm before sending capture” is enabled, you’ll be prompted before uploading a screenshot.

### Repo layout

- `AgentView/Sources/`: app code (Swift / SwiftUI + small AppKit panels)
- `AgentView.xcodeproj/`: Xcode project

