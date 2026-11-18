# JWL Assistant v7.0.19

Upgrade from any earlier version. Download **JWL-Assistant-Setup-7.0.19.exe** below and run it (your settings are kept).
This version includes everything from v7.0.18 and earlier.

## Fixed

### The app froze for about 2 minutes right after it started
- Now and then (about every second start) the window stopped reacting for about 2 minutes, and the Zoom status stayed dark. The startup splash screen's background thread was shut down in a way that could block the main window while a Zoom scan was reading the list of windows on the desktop. The splash is now closed in the background, so the window never waits for it.
- Start-up stalls are shorter too (the 2-3 second pauses right after the window appears are gone).

### Zoom: "Zoom responding slowly" warning stayed on, Polls attendance was slow
- Every Zoom status scan walked Zoom's whole window tree to find your video tile (6-10 seconds, more while Zoom was busy), so scans piled up and the warning stayed on. The scan now **remembers your tile** and only searches again when it is gone (rejoin, layout change).
- The **Polls attendance read** remembers the poll panel in the same way. The pause between two reads now grows while Zoom answers slowly (1.5 times the last read, 5 to 60 seconds), so the reads never keep Zoom busy all the time. Expect the attendance button to flash about every 30-40 seconds.
- Right after the app starts, **Auto Hand Alert** (45 s) and the **Attendance** read (40 s) wait for the first status scan instead of all searching Zoom at the same moment.

### Zoom did not join after a cold start
- When Zoom was not running, it was started and the meeting link was sent too early, while Zoom was still signing in, so Zoom stayed on its home screen. Zoom now gets 5 seconds to finish starting, and if no Join dialog shows within 20 seconds the link is sent again (at most twice).

### OBS came back blank after closing the app
- When you close with **"Close JWL Assistant only"**, OBS is brought back into view. A window restored from the tray (or hidden by Auto-hide) stayed blank until you minimized and restored it by hand. OBS is now restored fully painted (a short flicker is normal), and a small hidden helper checks the OBS window for 15 seconds after the app has closed and repairs it if it goes blank again.

### Settings
- The OBS Control box now ends cleanly above PiP Media (nothing hidden behind it).
- Settings opens in about **1.2-1.4 seconds** after the first open (the first open is the slowest).

## New

### OBS: Auto-minimize and Auto-hide (Settings > OBS Control, both off by default)
- **Auto-minimize OBS after N seconds:** minimizes the OBS window once per OBS start, N seconds after the app first sees OBS running - also after an app restart while OBS is open. A window the Start menu already minimized, or one hidden in the system tray, is left alone.
- **Auto-hide OBS after N seconds:** hides the OBS window completely (no taskbar button), but only when OBS is **already open as the app starts** (restart). OBS started later is not touched. OBS keeps running and the Virtual Camera is not affected.

### Status bar: "OnlyT update available!"
- A green message shows in the status bar while OnlyT's update notice is up and its window is left open (the OnlyT window is not auto-hidden while an update notice shows, so you can see the green update button).

### Bug report now contains your settings
- The report saved to your Desktop now also contains a **snapshot of all settings** (passwords, secrets and tokens are replaced by `***`), the **monitor layout** and which of Zoom, OBS, OnlyT, OnlyM and JW Library are running.

### Better diagnostics in the log
- A slow Zoom status scan or Attendance read now names the step it is in and when each step started, for example `previous scan still running ... now in step 'pane-search'`.

## Notes
- If **Settings** feels slow, check that `%APPDATA%\JWL-OBS-Assistant\profile.on` does **not** exist. That optional diagnostics file makes building the Settings window clearly slower. Delete it (or rename it to `profile.off`) to switch it off.
- Minimizing the **Zoom** window works with the app: the Zoom status keeps updating while Zoom is minimized, but the scan may be slower then.
- OBS set to *minimize to the system tray*: "Auto-minimize" then sends OBS to the tray.
