# JWL Assistant v7.0.6b

Reliability release. If you are on v7.0.5d or older, install this one.

## Auto-Admit
- **Much faster admitting.** The Waiting Room scan now remembers the participant list instead of searching the whole Zoom window every time (about 0.3 s instead of up to 10 s), so people from your saved list are admitted almost as soon as they appear.
- The Space key is sent after the participant list has keyboard focus and the person's row is selected; the result is verified and retried once.

## Auto Toggle
- **Starts right away** after you answer Yes to the "Zoom mic / camera are off" question. Before, it could wait 30-40 seconds for Zoom to acknowledge the keys.
- The app then checks what Zoom really reports and sends Alt+A / Alt+V once more if the mic or camera is still off (the log says `Mic confirmed on after Alt+A` or `... sending it again`). It stops checking as soon as you click the mic/camera button yourself.
- Background Zoom scans pause for a few seconds while these keys are sent, so Zoom reacts at once.

## Preview
- **PTZ buttons and the AF / ROI overlay are always available** in the new UI: also in OBS screenshot mode and while the live-camera engine is still loading (slow PCs). While the camera starts, the frame says "Starting camera preview...".

## Since v7.0.5 (in case you skipped versions)
- App no longer restarts itself when closed; ROI warning is always visible; V-Cam state is read on connect; XR Mixer matches the app height.
- Zoom start-up: Participants first, then Polls, with progress in the status bar (`Zoom: ✓ Joined  ✓ Participants  ✓ Polls launched`), working for every meeting.
- A `UI stall` log line is written when the app is frozen for half a second or more.

## Files in this release
- `JWL-Assistant-Setup-7.0.6b.exe` - installer (installs per user, no admin rights needed). Close any running JWL Assistant before installing.
