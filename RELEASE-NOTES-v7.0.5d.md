# JWL Assistant v7.0.5d

Bug-fix and reliability release. If you are on v7.0.5, v7.0.5b or v7.0.5c, install this one.

## Important fixes
- **App kept restarting when closed** (v7.0.5 / v7.0.5b installed EXE): the close-time safety watchdog launched the app itself instead of PowerShell. Fixed.
- **Start Auto Toggle without a usable ROI** no longer looks like a freeze: the warning is always shown on top, and it also catches a saved ROI that lies outside every connected monitor.
- **V-Cam button** no longer flashes red when OBS was started with the Virtual Camera already on.
- **XR Mixer panel** now matches the height and position of the app window.

## Zoom start-up (new in 7.0.5d)
- **Participants panel first, then Polls**, in one ordered sequence. Each step is checked and retried on a slow PC instead of being skipped silently.
- **Progress in the status bar** of the new UI: `Zoom: ✓ Joined  ✓ Participants  ✓ Polls launched`. A failed step shows in red with a hint (`✗ Polls (click Polls)`, `✗ Participants (open manually)`), then the normal status bar returns.
- **Works for every meeting**, not only the first one after the app starts: closing and restarting Zoom opens the panels again.
- **Polls** waits for the panel instead of a fixed delay, reloads it once if no poll shows up, and never clicks unrelated "Start..." buttons.
- **Settings**: a green reminder next to "Polls Setup": *Add Polls Button to the Zoom tool bar!* (Polls must be in the Zoom toolbar, not under "More".)

## Auto-Admit
- People from the saved list are admitted reliably again: the Space key now goes to the real Zoom meeting window (brought to the front first), the result is verified and retried once. It works even if you are in another app while someone is admitted.

## Diagnostics
- The log now writes `UI stall: ...` when the app was frozen for half a second or more, and lists which buttons / windows it saw when a Polls or admit step fails.

## Files in this release
- `JWL-Assistant-Setup-7.0.5d.exe` - installer (installs per user, no admin rights needed). Close any running JWL Assistant before installing.
