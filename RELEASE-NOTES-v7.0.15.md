# JWL Assistant v7.0.15

Upgrade from v7.0.6c or any later version. Download **JWL-Assistant-Setup-7.0.15.exe** below and run it (your settings are kept).
This version includes everything from v7.0.14 (see RELEASE-NOTES-v7.0.14.md) and earlier.

## Fixed

### Polls: the attendance count stopped updating
- While a poll is running, the count is refreshed every 15 s. If Zoom missed a single status check at that moment (Zoom is busy now and then), the refresh **stopped for good** and only pressing the Polls button started it again. A single miss now just skips that one refresh; the refresh only stops when the meeting has really ended.

### Zoom buttons and Polls stopped updating after Zoom reconnected
- After a reconnect, Zoom can leave an **old, empty "Zoom Meeting" window** behind next to the real one. The app always took the first window with that name - when that was the empty one, the mic/camera buttons, Participants, Polls and the attendance count no longer updated (restarting the app did not help).
- Every Zoom check now uses the **real meeting window** (the visible one with the toolbar). With only one meeting window nothing changes.

### Zoom button stuck at "already in progress"
- When the Start menu (or the Zoom button) was used while Zoom was **already in the meeting**, the button stayed locked, so after closing Zoom it could not join again until the app was restarted. The lock is now released straight away in that case (and any lock older than 2 minutes is released automatically).

### Zoom did not go into the meeting after "Join"
- Zoom sometimes **ignores the click** on its Join dialog while it is still busy, so the dialog stayed open. The app now checks that the dialog is gone and clicks again if needed (from the 3rd try with a real mouse click, the pointer is put back right away; at most 5 tries). Repeat clicks only ever go to the Join dialog, never into the meeting window.

### Start menu: JW Library crashed on the automatic start
- JW Library started fine by hand but often closed again about 8 seconds after an automatic start. It is now started **after Zoom has finished joining**, and **nothing touches it while it starts**: no reading of its window, the progress window no longer pushes itself on top of everything during that time, and the "sticky" mouse pointer is released. Both come back once JW Library is open.

## Notes
- If JW Library's **main window** suddenly fills the whole screen (not the second-display output), check whether **JwlMediaWin** ("JWL Media Fix") is running: it manages JW Library's windows and can mistake the main window for the media window. That program is not part of JWL Assistant.
- Renamed a scene in OBS after setting up the ScenePicker? Update the name in **Settings > ScenePicker + Snapshots** too - the mixer snapshot is matched by the exact scene name.
- Optional diagnostics: create an empty file `%APPDATA%\JWL-OBS-Assistant\profile.on` to log slow background jobs. Delete it to switch it off.
