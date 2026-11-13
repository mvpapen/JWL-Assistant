# JWL Assistant v7.0.10

Upgrade from v7.0.6c, v7.0.8 or v7.0.9. Download **JWL-Assistant-Setup-7.0.10.exe** below and run it (your settings are kept).
This version includes everything from v7.0.9 (see RELEASE-NOTES-v7.0.9.md) and v7.0.8 (see RELEASE-NOTES-v7.0.8.md).

## New

### Start menu (red power button)
- A new red **power button** sits in the first row of the new UI, right of the JW button (room is kept for two more buttons). It starts your meeting programs one after another.
- It is **off by default**. Switch it on under **Settings > Start menu** with **Enable Start menu**; the button only shows when this is ticked. No program is ticked by default.
- Tick which programs it starts:
  1. **OBS** + start the Virtual Camera
  2. **OnlyT**
  3. **OnlyM**
  4. **Zoom** - joins with all the automatic settings chosen under Zoom Settings
  5. **JW Library** (always started last) - with its own checkbox **go to "Meetings"**, so that part can be switched off if it ever acts up. If JW Library crashes while starting, it is tried again after 15 s (up to 3 tries).
- Each program is waited for until it has opened, then the next one starts after a short pause (0.5 s by default, adjustable).
- A "please wait until all programs are loaded" window shows the progress with a Cancel button, and the status bar shows the progress too.
- Tip: arrange all app windows so they do not overlap before you press the button (a reminder is shown in Settings).

### Close all also closes OnlyM
- **Close all** now closes OnlyT, OnlyM, JW Library and OBS. Zoom is still left open, so the after-meeting chat is never interrupted.

### OnlyT update notice
- If OnlyT is showing its **update icon**, the OnlyT window is **not auto-hidden**, so you can see it and update (the update brings the new meeting schedule for the next weeks). Hide the window yourself with the eye button to ignore it.

### Settings
- A red warning in the Live Camera Preview box: **WINDOWS 11 CAMERA SHARING MUST BE ENABLED!**

## Improved
- The clock, brightness, size (S/M/L) and settings buttons over the preview, and the title strip, are kept on top and can no longer end up hidden behind the video.

## Notes
- The Start menu settings are not carried over from earlier versions: the menu starts switched off, so tick **Enable Start menu** once to get the red button.
- If the OBS virtual camera ever fails to start, check that Zoom is not using "OBS Virtual Camera" as its camera.
- Optional diagnostics: create an empty file `%APPDATA%\JWL-OBS-Assistant\profile.on` to log slow background jobs. Delete it to switch it off.
