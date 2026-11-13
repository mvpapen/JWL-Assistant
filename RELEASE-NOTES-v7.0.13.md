# JWL Assistant v7.0.13

Upgrade from v7.0.6c, v7.0.8, v7.0.9, v7.0.10 or v7.0.11. Download **JWL-Assistant-Setup-7.0.13.exe** below and run it (your settings are kept).
This version includes everything from v7.0.11 (see RELEASE-NOTES-v7.0.11.md), v7.0.10, v7.0.9 and v7.0.8. (There was no public v7.0.12.)

## Fixed

### Zoom: Join Zoom sometimes stopped halfway
- **The Zoom "Join" dialog stayed open and was not clicked, so Participants and Polls never opened** - until the app was restarted. This happened when another app (for example **OnlyT**, parked off-screen) was open: the search for the Join button looked through every window on the PC and came back empty. It now looks only in **Zoom's own windows**, so other apps can no longer get in the way.
- The app now keeps looking for the Join button for up to **75 s** (was about 30 s), so a slow first start of Zoom is handled too. It stops as soon as you are in the meeting.
- The "Auto Polls" step now waits up to about 75 s for the meeting (was 10 s).
- If the Join button is ever not found, the log now lists the Zoom windows that were open, to make the problem easy to find.

### Zoom start-up progress in the status bar
- The **Zoom: Joining / Participants / Polls** line no longer disappears about 2 s after **Join Zoom** is clicked (and then comes back later). It now stays on until the whole procedure is done, and then the update status comes back.

### Start menu: JW Library crashing at the first start
- On some PCs JW Library shows its window and then **crashes a few seconds later**. This was counted as "open", so it was **not started again**. JW Library now has to **stay open for 15 s** before it counts as started; if it closes in that time, the next try starts (up to 3 tries in total).

## Improved

### Start menu (red power button)
- **OBS is minimized** to the taskbar once it has been opened by the Start menu and the Virtual Camera is on (it keeps running, the camera is not affected). An OBS that was already open is left as it is.
- The **"Starting programs" window stays on top**, even when another always-on-top app such as **OnlyM** opens over it.
- A **flashing red warning: "Don't move the mouse during the start-up procedure!"** (the Meetings tab in JW Library is clicked with the real mouse pointer).
- **Sticky mouse pointer:** when the start-up begins, the mouse pointer is placed on a **crosshair** next to the warning and held there - small moves put it straight back. It works from the very first second, even while the PC is busy starting OBS.
  - To take the pointer away anyway (for example to press **Cancel**): **flick the mouse hard**, **keep pushing it away for a moment**, or **hold a mouse button** down. Moving it back onto the crosshair makes it sticky again.
  - The app's own clicks (JW Library Meetings tab, Zoom Focus mode) are not affected.

## Notes
- The version number is now shown as **v7.0.13** everywhere (title bar, log, update check).
- If JW Library crashes while it starts, that is JW Library itself; the Start menu now notices it and starts it again (up to 3 tries). The log shows `JW Library did not open (try 1/3)` or `JW Library closed right after opening - crashed? (try 1/3)` when this happens.
- On a small monitor the programs will overlap during the start-up; the "Starting programs" window always comes back to the front.
