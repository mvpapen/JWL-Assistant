# JWL Assistant v7.0.11

Upgrade from v7.0.6c, v7.0.8, v7.0.9 or v7.0.10. Download **JWL-Assistant-Setup-7.0.11.exe** below and run it (your settings are kept).
This version includes everything from v7.0.10 (see RELEASE-NOTES-v7.0.10.md), v7.0.9 and v7.0.8.

## New

### Auto <Cut with the OnlyT timer
- New checkbox **Auto <Cut with the OnlyT timer** in Settings > OnlyT (off by default).
- When it is on, a small **red A** shows on the **<Cut** button, like the one on the Hand alert button.
- When a scene is selected (the <Cut button is flashing) and you **start the OnlyT timer**, the cut is done **at the same time**, so the timer starts and the camera moves together. The normal <Cut behavior (fade to black, mixer snapshot) is used.
- Without a selected scene the timer simply starts. Stopping the timer never cuts. Pressing <Cut yourself just cuts.

## Improved

### Start menu (red power button)
- **JW Library is no longer started twice while it is still loading.** On a busy PC JW Library can take longer than 15 s to open; starting it again made its window resize and sometimes go full screen. Now it is only started again if it really crashed (its process is gone), and the app waits up to 60 s while it is still starting.
- The **Meetings** click always uses the **main JW Library window**. JW Library also has a second-display window with the same name, which could be picked by mistake and made the Meetings tab seem "not found".
- New separate checkbox **go to "Meetings"** under JW Library (greyed out unless JW Library is ticked), so that part can be switched off if it ever acts up.
- **Nothing is ticked by default**, and the red power button is only shown after **Enable Start menu** is ticked in Settings.
- A red reminder in Settings: **Arrange all app windows so they don't overlap!**
- The log now lists every JW Library window (position and state) around the Meetings step, to make any problem easy to find.

### Main window
- The clock, brightness, size (S/M/L) and settings buttons over the camera preview, and the title strip, are kept on top and can no longer end up hidden behind the video (for example after JW Library was brought to the front).

## Notes
- If JW Library crashes while it starts, that is JW Library itself; the Start menu starts it again (up to 3 tries).
- The Start menu settings start switched off: tick **Enable Start menu** once to get the red power button.
- If the OBS virtual camera ever fails to start, check that Zoom is not using "OBS Virtual Camera" as its camera.
- Optional diagnostics: create an empty file `%APPDATA%\JWL-OBS-Assistant\profile.on` to log slow background jobs. Delete it to switch it off.
