# WPF-Migration Planning Audit (Non-Mixer UI)

**Target:** `JWL+OBS Assistant v7.0.0 new UI.ps1` (21,805 lines)
**Scope:** All WinForms UI and UI-coupled logic outside the X-Air mixer subsystem (mixer already audited separately — see [XR-Mixer-Audit-Report.md](./XR-Mixer-Audit-Report.md) — and intentionally deferred to a later phase). Read-only audit; no files were modified.
**Date:** 2026-10-25

---

## 1. Executive summary

The application is a large, hand-built WinForms UI with a single main form, ~14 secondary WinForms forms/dialogs plus the main form and the (separately-audited) mixer form, extensive absolute positioning, custom GDI+ painting, runtime theme mutation, manual UI scaling, WinForms timers, `IMessageFilter`-based hotkeys and mouse-wheel routing, and several modal/modeless popup patterns. The highest migration risks are the main-window layout, the camera/LibVLC host, DPI and custom scaling, custom-painted controls, asynchronous UI updates, and global hotkey/message-filter behavior. A WPF migration should begin with a replacement shell, resource-based theme system, and dispatcher abstraction while leaving the X-Air mixer panel for a later phase.

---

## 2. Main window inventory

Main form construction begins ~line 4706:
```powershell
$script:form = New-Object System.Windows.Forms.Form
$script:form.AutoScaleMode = 'Dpi'
$script:form.ClientSize = Sz 600 680
$script:form.FormBorderStyle = 'FixedSingle'
$script:form.MaximizeBox = $false
$script:form.SizeGripStyle = 'Hide'
```
Position is restored from persisted coordinates, falling back to the primary working area (lines 4715–4721).

| Approx. lines | Region | Notes |
|---:|---|---|
| 4706–4770 | Window/status header | Main `Form`, `StatusStrip`, status label, XR status label w/ generated dot bitmaps |
| 4770–4830 | Clock/meeting header | Clock button, next-meeting label, hidden Meeting Mode checkbox, 1s clock + meeting timers |
| 4830–4860 | UI scale control | Resize button + `ContextMenuStrip` (Standard/Medium/Large) |
| 4860–4935 | Theme control | Theme button, resize anchoring, dark/light toggle |
| ~5000–5700 | Main controls/service panels | Zoom, attendance/waiting-room, OBS/meeting-state indicators, camera/automation controls |
| ~7600–8178 | OBS scene controls | Program label, Blank/Speaker, Cut, ScenePicker/Camera, Media buttons, scene context menus |
| ~7800–8830 | Preview/camera area | Preview panel, camera scene controls, device picker, auto-frame/PTZ controls |
| ~8300–8800 | Zoom controls | Join, leave/status, mic/camera/focus, hand-alert, participant/waiting-room controls |
| ~9000–10400 | Zoom toggle/ROI UI | Monitor selection, warning prompts, ROI controls/helpers |
| ~10400–13000 | Settings dialog construction | Tightly coupled to config/settings state |
| ~14800–15028 | Reminder/auxiliary UI | Reminder forms, Zoom admission UI, status/notification interactions |

Rough estimate: 1 main form, 1 status strip, 20–30 primary buttons, 10–20 labels/status indicators, several panels/group boxes, multiple timers/context menus, a camera/preview host. Exact counts are dynamic since some controls are created only when a feature/dialog opens.

Layout relies on pixel-based helpers (`Pt`, `Sz`) and a hand-calculated required form width (~7690–7800); top-right buttons are manually repositioned on `Resize` (4880–4890). **This should become `Grid`/`DockPanel`-based WPF layout rather than coordinate translation.**

---

## 3. Dialog/popup inventory

| Approx. line | Form/function | Purpose |
|---:|---|---|
| 2073 | `Show-ConfigImportDialog` | Import settings from previous versions |
| 3412 | `Show-CameraPickerDialog` | Select DirectShow capture device |
| 4461 | `Show-MusicPlayerPopup` | Borderless topmost music-player popup |
| 4706 | `$script:form` | Main application window |
| 5706 | `Show-PTZSetupHelp` | PTZ/Auto-Frame setup guide (RichTextBox) |
| 8835 | `Show-BugReport` | Bug report entry form |
| 9030 | Zoom toggle warning dialog | Prompt to stop Auto Toggle |
| 9122 | `New-FlashingReminderForm` | Topmost flashing meeting/reminder notification |
| 9656 | Zoom/ROI prompt | Conditionally created by Zoom/ROI path |
| 10268 | `Show-SettingsDialog` | Large scrollable settings window (OCR/ROI/Zoom/OBS/camera/reminders) |
| 10425 | ROI preview popup | Shows captured ROI bitmap |
| 14864 | Zoom auto-admit prompt | Ask whether to add participant to list |
| 17755 | Zoom auto-admit manager | ListView manager for known participants |
| 18934 | Zoom auto-admit add-to-list prompt | Manual admission confirmation |
| 18996 | Zoom auto-admit manager dialog | ListView w/ Remove Selected + Save |
| 19939 | `$frmM` XR Mixer Panel | **Out of scope** (separately audited) |

Also: `ContextMenuStrip`s (UI scale ~4834–4844, scene picker ~10200+, Zoom toggle ~10400+), `ToolTip` components, `MessageBox.Show` calls throughout, and several borderless/topmost "notification surface" forms.

---

## 4. Theming system

Theme hashtables (`$DarkTheme`/`$LightTheme`) + `$script:_mixerDark` flag; entry point `Enable-DarkMode` (~1620–1640). Mechanism: recursive mutation of every existing control —

```powershell
Set-ThemeRecursive $Form $theme $Enable
# -> Set-ControlTheme per control, branching by type (TabControl, DataGridView, LinkLabel, generic BackColor/ForeColor, ...)
```

New controls are themed via `Register-ThemeForNewControls` attaching `ControlAdded` handlers recursively (~1575–1615), tracked in `$script:_themeControlAddedHandlers` with a monotonic `$script:ThemeVersion` to gate stale handlers. Settings dialog explicitly forces Light theme regardless of app theme (`Set-ThemeRecursive $dlg $LightTheme $false`, ~10280–10290).

**WPF implication:** replace with `ResourceDictionary`/`DynamicResource`-based styles and a single theme-resource swap — do not reproduce the tree-walk + `ControlAdded` mutation model.

---

## 5. DPI/scale handling

Two separate systems:

1. **WinForms automatic DPI**: `$script:form.AutoScaleMode = 'Dpi'` (4713); Settings dialog and the embedded `RoiPickerForm` C# class both explicitly set `AutoScaleMode = None` because their layout is manual.
2. **Custom app UI scale** (100/125/150%, `Set-UIScale`, ~4944–5005): computes a ratio and calls `$script:form.Scale(...)`, then separately re-applies font size, min width/height, button anchors, screen position, mixer-panel lifecycle, and rounded corners. Restored at startup from `$script:Cfg.UI.ScaleLevel` (~21778–21783).

Additionally, compiled C# helpers (`DpiHelper`, `RoiScreen`, `RoiPickerForm`, ~10052–10250) use `SetThreadDpiAwarenessContext`/`EnumDisplayMonitors`/`GetDpiForMonitor` and store ROI in **physical pixels**. The Hand Alert WPF overlay converts physical pixels to WPF DIPs manually (`$window.Left = $bounds.Left / $dpi`, ~360–380).

**High migration risk**: five different DPI representations coexist today (WinForms auto-scale, manual `Form.Scale`, physical-pixel ROI, per-monitor Win32 queries, WPF DIPs). The WPF shell should standardize on DIPs + per-monitor WPF awareness, converting to physical pixels only at OS/screen-capture boundaries.

---

## 6. Custom/owner-drawn controls (outside mixer)

- `Set-RoundedCorners` (~908, GDI+ `GraphicsPath`) applied to clock/resize/theme/Blank/Cut/Camera/Media buttons.
- Bitmap generators: `New-ClapperboardBitmap` (~925), `New-RecordDotBitmap` (~993), `New-TvMonitorBitmap` (~1006), `New-DotBitmap` (~4730–4745).
- Custom `Paint` handlers for Zoom toggle/button rendering (~10400–10450), status/connection indicator graphics, custom arrow/icon drawing (`DrawLines`, `DrawString`).
- `RoiPickerForm` (compiled C# class): full-screen translucent overlay, `ControlStyles.AllPaintingInWmPaint | UserPaint | OptimizedDoubleBuffer`, mouse-drag selection + custom drawing → should become a WPF transparent overlay `Window` with `Canvas`/adorner-style selection.

---

## 7. Async/UI-update patterns

- **Central UI marshal helper** `Invoke-OnUI` (~228): checks `$script:form.InvokeRequired`, calls `BeginInvoke` or runs inline. **Must become a `Dispatcher.Invoke/BeginInvoke` abstraction in WPF.**
- **Runspaces**: tracked for attendance/UI-Automation reads, poll-start, Focus Mode, Waiting Room, OCR-related work (e.g. `$script:_attendanceRunspace`, `$script:_pollsRunspace`, ~168–175), combined with a UI-thread polling timer for completion (`$script:_attendanceAsyncResult`).
- **WinForms Timers** — many found, representative subset: flash/visual (~492), join animation (~8559, ~19785), Zoom status (~19646), startup sync (~19767), auto-join polls (~19808), periodic Zoom refresh (~19845), flash (~20148), XR broadcast retry (~21215), snapshot hold (~21496), mixer panel timer (~21577), repaint (~21719), XR title init (~21733), startup/status (~21765). Clock + Meeting Mode timers (~4760–4815).
- **Manual message pumping**: `[System.Windows.Forms.Application]::DoEvents()` used in Bug Report and Settings flows, including a `while ($frm.Visible) { DoEvents(); Start-Sleep -Milliseconds 30 }` loop — a clear migration smell; WPF should use normal `ShowDialog()`/event-driven lifecycle instead.
- **UI Automation / external app control**: Zoom subsystem uses UI Automation + `SendKeys::SendWait` (e.g. `%a`) for mute/unmute, tied today to WinForms timers/invoke for feedback.

---

## 8. WinForms-specific APIs with no direct WPF equivalent

| API/usage | Approx. location | Migration strategy |
|---|---:|---|
| `Form` (×16 instances) | listed in §3 | WPF `Window`, `ShowDialog`/modeless `Show` |
| `Control.InvokeRequired`/`BeginInvoke` | 228–236 | `Dispatcher.CheckAccess` + `Dispatcher.BeginInvoke` |
| `Application.DoEvents()` | Bug report/settings modal flows | Remove; normal WPF event lifecycle |
| `Forms.Timer` | many (§7) | `DispatcherTimer` (UI) / `Task` or background timer (non-UI) |
| `StatusStrip`/`ToolStripStatusLabel` | 4725+ | WPF `StatusBar`/`StatusBarItem` |
| `ContextMenuStrip`/`ToolStripMenuItem` | 4834, 10200+, 10400+ | WPF `ContextMenu`/`MenuItem` |
| `ToolTip` | ~4461 (PTZ info) | WPF `ToolTip` property/style |
| `MessageBox.Show` | throughout | WPF `MessageBox` or custom themed dialog |
| `OpenFileDialog` | Settings ~10300+ | `Microsoft.Win32.OpenFileDialog` |
| `ListView` | Auto-admit manager ~18996 | WPF `ListView`/`DataGrid` w/ binding |
| `RichTextBox` | PTZ guide ~5706 | WPF `RichTextBox`/`FlowDocument` |
| `Panel`/`GroupBox`/`TabControl`/`DataGridView` | main window/settings | `Grid`/`Border`/`GroupBox`/`TabControl`/`DataGrid` |
| `Screen` / `Screen.FromControl`/`FromHandle` | Hand Alert fallback, camera/dialog positioning, mixer callers | `SystemParameters` + Win32 per-monitor enumeration where physical pixels are required |
| `Application.AddMessageFilter` / `IMessageFilter` | wheel routing (~10070–10110), hotkeys (~120–140) | WPF `ComponentDispatcher`/`InputManager`/window hooks or routed input |
| `ControlStyles`/`Paint` | rounded/custom controls, ROI picker | WPF templates/`Path`/`Canvas`/`DrawingVisual` |
| `SetWindowPos`, `SetThreadDpiAwarenessContext` | ROI/monitor helpers | Retain as P/Invoke only at screen/interop boundary |
| `SendKeys` | Zoom mute/unmute | Retain, isolate from UI layer |
| `Cursor`/`Control.MousePosition` | ROI picker | WPF mouse/input APIs; Win32 cursor APIs only for physical screen capture |
| `NotifyIcon` | **not confirmed** — only `$script:UpdateNotifyIcon = $null` found at line 209, no actual construction located in this file | Investigate further if tray behavior exists; else lower priority |

---

## 9. Global hotkey handling

P/Invoke `RegisterHotKey`/`UnregisterHotKey` (~107–110); custom `IMessageFilter` intercepting `WM_HOTKEY` (0x0312) (~120–140); state in `$script:_hotKeyFilter`/`$script:_hotKeyPollTimer` (~155–156). Flow: register native hotkey → `WM_HOTKEY` via WinForms message filter → store/signal state → polling timer updates UI. **This depends entirely on the WinForms application message loop** and must be replaced with `HwndSource.AddHook`, `ComponentDispatcher.ThreadPreprocessMessage`, or a dedicated native message window under WPF.

---

## 10. Camera/video preview hosting

Camera subsystem begins ~3239–3275 (LibVLC + DirectShow capture, replacing older screenshot polling): `$script:_camLibVLC`, `$script:_camMediaPlayer`. Device picker enumerates DirectShow devices via registry (~2040–2070) into a WinForms `ListBox`. The exact video-surface handle assignment wasn't pinned down in this pass — needs verification around lines 3239–3400 and 7600–8830 before implementation. Shutdown explicitly disposes the camera LibVLC engine (~17871–17873; this matches the `Add_FormClosing` disposal work from the reliability audit).

**WPF strategies**: (1) temporary — host existing LibVLC video surface inside `WindowsFormsHost`; (2) preferred long-term — WPF-native LibVLC video surface/control; (3) alternative — native child HWND + interop wrapper. Recommend isolating behind an `ICameraPreviewHost` abstraction regardless, since LibVLC lifecycle/DirectShow discovery/native handle ownership are independent of the rest of the UI.

---

## 11. Existing WinForms+WPF coexistence precedent: Hand Alert

`Initialize-HandAlertWpf` loads `PresentationFramework/PresentationCore/WindowsBase` (~246–260); `New-HandAlertWindow` builds a WPF `Window` via `XamlReader.Load` from an inline XAML string (~338–355) with `WindowStyle="None" AllowsTransparency="True" ShowInTaskbar="False" Topmost="True"`.

This is a **separate, independent WPF window** — not embedded via `WindowsFormsHost`, no shared visual tree with the WinForms main form. It explicitly handles cross-framework screen coordinates (physical pixels → WPF DIPs via `/ $dpi`), using the custom `RoiScreen` Win32 monitor enumerator (not WinForms `Screen`) for mixed-DPI correctness.

**Implication:** proves independent WPF windows can coexist beside the WinForms shell today — a viable first hybrid-integration step — but does **not** demonstrate embedded WPF-in-WinForms content, shared data binding, or shared dispatcher ownership. Don't treat it as proof the main form can be migrated control-by-control without further interop design.

---

## 12. Risk ranking (highest → lowest)

1. **Main window layout/behavior** — absolute pixel coords, hand-calculated widths, manual anchoring, hidden controls, dynamic scene buttons, many closures.
2. **DPI and custom UI scale** — five coexisting DPI representations (see §5); incorrect conversion risks misplaced dialogs, ROI errors, off-screen windows.
3. **Camera/LibVLC hosting** — native video handles are hard to move between UI frameworks; likely needs a temporary `WindowsFormsHost`.
4. **Custom drawing/owner-drawn controls** — rounded buttons, bitmap generation, Paint handlers, ROI overlay all need explicit WPF equivalents.
5. **Async/UI-thread coordination** — many timers, runspaces, `BeginInvoke`, `DoEvents` patterns; needs one consistent Dispatcher strategy.
6. **Theme system** — broad but conceptually straightforward to replace with resources/styles if done before migrating individual dialogs.
7. **Dialogs/popups** — mostly self-contained; Settings dialog is the outlier (size, scrolling, DPI handling, wheel-routing filter).
8. **Global hotkeys/message filters** — native registration can stay; routing must move off `IMessageFilter`.
9. **Monitor/screen/ROI utilities** — isolable as interop services, but need careful mixed-DPI testing.
10. **Tray/notification behavior** — no confirmed active `NotifyIcon` in this file; likely lower priority, but worth confirming.

---

## 13. Recommended phased migration plan

**Phase 1 — Extract services / define shell boundary.** Keep the WinForms main form running; isolate config access, theme state, monitor/DPI services, hotkey registration, camera/LibVLC lifecycle, dispatcher/UI invocation, and Zoom/OBS service calls behind small abstractions (e.g., a dispatcher abstraction modeled on `Invoke-OnUI`).

**Phase 2 — Build the WPF shell + theme system.** New WPF main `Window`; dark/light themes via `ResourceDictionary`/`DynamicResource`; reproduce status bar, clock, top-right theme/scale controls, window positioning. Do **not** reproduce the recursive `ControlAdded` mutation model. Use the existing Hand Alert window as the first hybrid-integration test.

**Phase 3 — Convert static/low-risk dialogs.** Bug Report (8835), PTZ Setup Help (5706), Config Import (2073), Camera Picker (3412), Zoom Auto-Admit prompt/manager. These are comparatively self-contained and establish WPF dialog conventions.

**Phase 4 — Convert popups/notification surfaces.** Music player popup, meeting/reminder forms, Zoom warning prompt, scene-picker/scale context menus → WPF `Window`/`Popup`/`ContextMenu`/`Adorner` equivalents.

**Phase 5 — Convert Settings + ROI workflows.** Rebuild Settings as scrollable WPF layout; remove `PanelWheelRouter` in favor of WPF scrolling/routed input; preserve the existing physical-pixel ROI contract; reimplement `RoiPickerForm` as a transparent WPF `Canvas` overlay; keep `RoiScreen`/Win32 monitor enumeration as an interop service.

**Phase 6 — Migrate the main OBS/Zoom control surface.** Scene-selection row, Zoom controls, meeting controls, status indicators, camera buttons → `Grid`/`DockPanel`/`StackPanel`/`UniformGrid` + bindings; move state from script-scoped control refs to view models/state adapters.

**Phase 7 — Integrate camera preview.** Initially via `WindowsFormsHost` if needed; validate DirectShow plugin discovery, LibVLC disposal, multi-monitor behavior, preview resizing; replace with a native WPF video host only once the rest of the shell is stable.

**Phase 8 — Replace timer/message-loop infrastructure.** Convert UI timers to `DispatcherTimer`; move non-UI polling to background tasks/runspaces with explicit dispatcher marshaling; remove `Application.DoEvents()` loops; replace `IMessageFilter` hotkey handling with WPF `HwndSource`/`ComponentDispatcher` integration.

**Phase 9 — Mixer migration (later, explicitly deferred).** Keep the XR/X-Air mixer panel, custom painting, meter drawing, faders, scaling, and theme behavior unchanged through Phases 1–8. Integrate it through a separate window/interop boundary only after the main WPF shell, dispatcher, theme, and DPI services are stable — per the earlier mixer audit's explicit recommendation.
