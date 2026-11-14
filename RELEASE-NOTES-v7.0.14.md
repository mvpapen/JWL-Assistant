# JWL Assistant v7.0.14

Upgrade from v7.0.6c, v7.0.8, v7.0.9, v7.0.10, v7.0.11 or v7.0.13. Download **JWL-Assistant-Setup-7.0.14.exe** below and run it (your settings are kept).
This version includes everything from v7.0.13 (see RELEASE-NOTES-v7.0.13.md) and earlier.

## Fixed

### XR mixer: no more freezes without a mixer
- **Opening the Mixer Panel with no mixer set up froze the app for good.** The "set the Mixer IP" message opened invisibly behind the hidden classic window. Now a visible warning appears (once per session) and the panel opens **for show only** - the faders do nothing until an IP is set, and the panel starts working by itself as soon as the mixer is found.
- **Unplugging the mixer while live made the app sluggish** (closing the panel could take 15 s). The online check, the automatic scan, the broadcast retry and both **Scan** buttons now all run **in the background** - the window never waits for the network.
- **Opening Settings** with no mixer IP no longer blocks the dialog for about 9 s with a mixer scan. It only scans when the XR mixer is enabled, and in the background.
- The **online / offline status** now updates live in the Mixer Panel (green IP or red "offline") and in Settings ("XR: Online ✓" / "XR: Offline ✗").

### Hand Alert went to the wrong monitor
- The monitor chosen in Settings now **sticks**. The app also remembered the last monitor by its Windows name, and that old name kept pulling the alert back to the previous monitor.
- **New:** the yellow hand in front of "Hand Alert Monitor" in Settings is a **test button** - it shows the alert on the selected monitor for 3 seconds, so you can try monitors until you have the right one.

### Polls / attendance
- **The attendance poll did not launch** ("Unsupported Pattern" in the log) when another window with "poll" in its title was open, for example an editor or a browser tab. The app now only looks at **Zoom's own windows** for the Polls panel and the attendance count.
- The app always launches the **first poll** in Zoom's list (the title does not matter). The Polls setup guide now says to title it **"01 Attendance Poll"** so it stays at the top.

### Settings and windows
- **Info (i) windows** stay in front of Settings (they used to vanish behind it while still open), close together with Settings, the **mouse wheel** scrolls the info text instead of Settings, and the **last lines** are no longer cut off.
- **OnlyT:** the meeting-part dropdown in the title bar **stays open** (it closed after about a second).
- **Close all:** OBS hidden in the **system tray** is brought back first, so it really exits (before, "OBS is still active" came up).

## Changed
- **XR settings:** "Enable XR Family Mixer" now sits right **above the XR Family Mixer control box**, and "Open Mixer Panel" sits **inside the box, under the Mixer IP**, so the IP is set first. Showing or hiding the box no longer leaves an empty gap.
- **Start menu (red power button):** a second click after a successful start asks **Retry / Cancel** instead of checking everything again (JW Library takes a while).
- **Focus Mode** is **off by default** on a new install, and Focus Mode never starts automatically while it is disabled. (Existing settings are kept.)

## Notes
- The XR mixer auto-scan always runs while "Enable XR Family Mixer" is ticked. Without a mixer, untick it and nothing runs at all.
- If OBS is started with your own shortcut in a *minimized-to-tray* state, Close all may still not be able to close it - start OBS normally (or minimized to the taskbar) instead.
- Optional diagnostics: create an empty file `%APPDATA%\JWL-OBS-Assistant\profile.on` to log slow background jobs. Delete it to switch it off.
