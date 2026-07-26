# Master Prompt: JWL + OBS Assistant

---

## Project Overview

Build a **single-file, compiled Windows desktop utility** written in **PowerShell 7 (pwsh)**, targeting the **.NET Windows Forms (WinForms) GUI framework**, that acts as a **meeting production assistant** for AV technicians running JW Library (JWL), OBS Studio, and Zoom simultaneously. The app must compile into a standalone `.exe` via **ps2exe** and run without installation.

---

## Architecture & Runtime Requirements

- **Entry point**: A single `.ps1` file that self-bootstraps into an **STA (Single-Thread Apartment) thread** — required by WinForms. If not already on STA, relaunch itself via `Start-Process pwsh -STA`.
- **Target runtime**: PowerShell 7 (`pwsh.exe`). Must also be PS 5.1-safe for the bootstrap only.
- **GUI framework**: `System.Windows.Forms` + `System.Drawing`, loaded via `Add-Type -AssemblyName`.
- **Optional assemblies**: `UIAutomationClient` / `UIAutomationTypes` (for Zoom UI introspection), `PresentationFramework` / `PresentationCore` / `WindowsBase` (for WPF overlay windows). Degrade gracefully if unavailable.
- **Inline C# via `Add-Type -TypeDefinition`**: Use `Add-Type` to embed P/Invoke declarations (`DllImport`) for Win32 APIs (`user32.dll`, `gdi32.dll`, `dwmapi.dll`, `kernel32.dll`). Guard each with a type-existence check to avoid "type already defined" errors across hot-reloads.
- **Persistence**: A JSON config file (`config.json`) stored alongside the script/exe, loaded at startup and written back on change. Use `ConvertTo-Json` / `ConvertFrom-Json`.

---

## Core Feature Modules

### 1. OBS Studio Integration (WebSocket)
- Connect to **OBS WebSocket v5** (`obs-websocket`) using a `System.Net.WebSockets.ClientWebSocket` on a **background runspace**.
- Implement **request/response correlation** using a `requestId` GUID dictionary.
- Support actions: **Scene switching**, **source mute/unmute**, **recording start/stop**, **virtual camera toggle**, **transition override**.
- Display a **connection status indicator** (colored dot/label) in the UI. Auto-reconnect on disconnect.
- Provide a **scene picker** — a panel of dynamically generated buttons, one per OBS scene, that highlight the currently active scene.

### 2. JW Library (JWL) Media Player Control
- Detect the JWL process and its window via **`EnumWindows` + `GetWindowText`** (Win32 P/Invoke).
- Send **keyboard input** to JWL's window using `SendKeys` or `PostMessage` P/Invoke to control playback (play, pause, stop, next track).
- Implement a **media cooldown** — a configurable timer (e.g., 3–5 seconds) that prevents rapid re-triggering of media commands. Display a countdown indicator on the relevant button.
- Implement **fade-out logic**: before stopping media, gradually reduce OBS source volume over a configurable duration (e.g., 500ms steps), then send stop. This prevents audible "pop" or noise artifacts when cutting media abruptly.

### 3. Zoom Meeting Control
- **Window detection**: Enumerate windows for `ConfMultiTabContentWndClass` class containing "Zoom Meeting" in the title (Win32 `EnumWindows` + `GetClassName`).
- **Monitor switching / Projector mode**: Use `SetWindowPos`, `ShowWindowAsync`, `DwmSetWindowAttribute` (disable transitions, cloaking) + alpha fade (`SetLayeredWindowAttributes`) to silently move the Zoom window to a secondary monitor and back. Animate the transition with a fade-in/out loop.
- **UI Automation (UIA)**: Use `UIAutomationClient` to locate Zoom's mic button, camera button, participants panel, and polls panel by **AutomationId or ControlType**. Run UIA scans on a **persistent STA background runspace** to avoid blocking the UI thread.
- **Mic / Camera toggle**: Read current state via UIA, toggle, and reflect state in the button color (green = on, red = off). Implement a **lock guard** (`_lastManualToggleTime`) to prevent a background polling timer from overwriting a manual toggle for ~2 seconds.
- **Auto Toggle mode**: A timer that automatically mutes mic/camera when no meeting participant activity is detected. Flash the mic/cam buttons as a visual warning when active.
- **Join Zoom**: Focus the Zoom Meeting window, auto-open the Participants panel (once per session), and optionally auto-start the first Poll after a configurable delay.
- **Focus Mode**: Toggle Zoom's "Focus Mode" (hides participant video) via UIA. Enforce a **60-second cooldown** after deactivation before allowing re-enable (Zoom limitation). Track toggle state internally.
- **Attendance counter**: Read participant count from the Participants panel via UIA on a background runspace. Refresh every 5 minutes. Show count in a tooltip on the Attendance button.
- **Hand Alert overlay**: Show a full-screen semi-transparent WPF window (XAML `TextBlock` with ✋ emoji, `FontSize=650`) on a configurable monitor. Fade in (400ms), then blink (pulse 100%↔30% opacity, 800ms cycle). Auto-dismiss after 30 seconds. Make the window **click-through** using `WS_EX_TRANSPARENT | WS_EX_LAYERED` extended window style. Flash the Hand Alert button in sync.

### 4. Global Hotkey
- Register a **global hotkey** (configurable F-key: F1, F2, F8, F9, F12) via `RegisterHotKey` P/Invoke on the main window's HWND.
- Intercept `WM_HOTKEY` (0x0312) messages using a **`IMessageFilter`** implementation (inline C# class `JwlHotKeyFilter`) attached to the WinForms application message pump via `Application.AddMessageFilter`.
- Poll the static flag set by the message filter using a **100ms WinForms `Timer`** on the UI thread to trigger the cut action.

---

## UI Design

- **WinForms `Form`** with a **dark theme**: background `#1e1e1e`, button faces `#404040`, accent colors per section.
- **Rounded buttons**: Use `gdi32.dll CreateRoundRectRgn` + `Control.Region` to clip each button to a rounded rectangle. Re-apply after any resize or DPI change.
- **Layout**: Use `Control.Location` and `Control.Size` (absolute pixel positioning) — no layout panels. Define helper functions `Pt(x,y)` → `System.Drawing.Point` and `Sz(w,h)` → `System.Drawing.Size`.
- **Anchor flags**: Apply `AnchorStyles` flags to controls so the UI scales correctly when the window is resized.
- **DPI awareness**: Divide physical screen coordinates by a **DPI scale factor** (obtained via `Graphics.GetDpiForWindow` or `DeviceDpi`) before positioning WPF overlay windows.
- **WM_SETREDRAW**: Suspend/resume drawing via `SendMessage(hwnd, 11, ...)` when doing batch UI updates to prevent flicker.
- **Tooltip**: Use `System.Windows.Forms.ToolTip` for hover hints on all buttons.
- **Color feedback on buttons**:
  - OBS Connected: green; Disconnected: red
  - Recording active: red; Idle: default
  - Mic on: green; Muted: red; Unknown: gray
  - Camera on: green; Off: red
  - Hand Alert active: yellow (flashing)

---

## Threading Model

- **UI thread**: All WinForms controls must only be accessed from the UI thread. Wrap all cross-thread calls in `form.BeginInvoke(scriptblock)` (abstracted as `Invoke-OnUI`).
- **Background runspaces**: Long-running or blocking operations (UIA scans, OBS WebSocket I/O, attendance reads, polls automation) run on `[RunspaceFactory]::CreateRunspace()` + `PowerShell` instances with `BeginInvoke`. A **200ms WinForms Timer** polls `$asyncResult.IsCompleted` on the UI thread to retrieve results without blocking.
- **Persistent STA runspace**: The Zoom UIA scanner uses a single long-lived STA runspace (created once, reused across calls) to avoid the overhead of runspace creation per scan.

---

## Configuration Schema (`config.json`)

```json
{
  "OBS": {
    "Host": "localhost",
    "Port": 4455,
    "Password": "",
    "AutoConnect": true
  },
  "Zoom": {
    "HandAlertMonitor": 0,
    "HandAlertDuration": 30,
    "FadeDuration": 500,
    "AutoPollsDelay": 5
  },
  "Media": {
    "CooldownSeconds": 4,
    "FadeOutMs": 600
  },
  "Hotkey": {
    "FKey": "F8"
  },
  "UI": {
    "WindowSizes": [[800,600],[1024,768],[1280,720]]
  }
}
```

---

## Update Check

- On startup, spawn a background runspace that calls `Invoke-RestMethod` against the **GitHub Releases API** (`https://api.github.com/repos/{owner}/{repo}/releases/latest`).
- Compare `tag_name` to the hardcoded `$AppVersion`. If newer, set `$script:UpdateAvailable = $true` and show a **notify icon** balloon tip or a highlighted button in the UI with a link to the release page.

---

## Build / Packaging

- Use **`ps2exe`** (`Invoke-ps2exe`) to compile the `.ps1` into a `.exe`:
  - `-noConsole` (hides the console window)
  - `-STA` flag (ensures STA apartment on launch)
  - `-iconFile` (embed a `.ico` resource)
  - `-title`, `-version`, `-company` metadata
- The resulting `.exe` is fully self-contained and runs on any Windows machine with .NET 6+ runtime.

---

## Key Terminology Reference

| Term | Meaning in this project |
|---|---|
| **STA thread** | Single-Thread Apartment — required by WinForms/COM |
| **P/Invoke** | Platform Invocation — calling Win32 DLL functions from .NET |
| **`Add-Type`** | PowerShell cmdlet to compile inline C# or load .NET assemblies at runtime |
| **Runspace** | An isolated PowerShell execution environment for background work |
| **`BeginInvoke`** | Non-blocking async execution on a runspace |
| **`IMessageFilter`** | .NET interface to intercept Windows messages before they reach controls |
| **`WM_HOTKEY`** | Windows message sent when a registered global hotkey is pressed |
| **WinForms Timer** | UI-thread timer (`System.Windows.Forms.Timer`) — safe for UI access |
| **UIA (UI Automation)** | Windows accessibility API for programmatic UI inspection/control |
| **DPI scale factor** | Ratio of physical pixels to logical DIPs for multi-monitor scaling |
| **`WS_EX_TRANSPARENT`** | Extended window style making a window pass mouse clicks through |
| **`DWMWA_CLOAK`** | DWM attribute that hides a window from screen without destroying it |
| **`BeginAnimation`** | WPF method to start a property animation (opacity, size, etc.) |
| **ps2exe** | Tool that compiles a `.ps1` PowerShell script into a Windows `.exe` |
| **OBS WebSocket v5** | OBS's built-in JSON-RPC-over-WebSocket API for remote control |
