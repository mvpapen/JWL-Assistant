# JWL Assistant v7.0.8

Upgrade from v7.0.6c. Download **JWL-Assistant-Setup-7.0.8.exe** below and run it (your settings are kept).

## New

### OnlyT timer
- **OnlyT control** (Settings): an OnlyT button between Cut and ScenePicker. Grey = not open (click to open), blue = open (click to start the timer), orange = running (click to stop).
- **Show Countdown in UI**: the OnlyT countdown appears in the new UI preview, with -, + and start/stop buttons on hover, plus Pause, Circuit visit and the talk (part) picker in the header.
- **Auto-hide the OnlyT window** a set number of seconds after it is detected. The eye button in the header overrides it.
- **Auto-start OnlyT** a set number of seconds before the meeting starts (opens OnlyT if it is not running).
- OnlyT is now read in the background, so it never slows the window down.

### OBS and JW Library buttons
- The **OBS button starts OBS** when it is not running (it flashes blue until OBS is open, then connects automatically).
- New **JW button** (purple JW logo) right of the AF button: starts JW Library, or brings it forward. Blue and flashing = not open, green = running.
- The **virtual camera button** now follows OBS: blue when OBS is closed, flashing red when OBS is up but the camera is not started, green when active.

### Auto Toggle safety check
- Starting Auto Toggle by hand now warns, in bold on yellow, when **OBS is not running / not connected** or **JW Library is not open**. Press OK to start anyway, or Cancel to start them first. Automatic starts are not interrupted.

### Closing the app
- A new closing menu replaces the old "remember to close OBS" message and lists only what is actually open:
  - **Close JWL Assistant only** - OBS is brought back out of the tray / minimized state so it is not forgotten.
  - **Close all** - closes OnlyT, JW Library and OBS. OBS is stopped properly (stream, recording, replay buffer and virtual camera first, then a normal exit, never a forced kill), so OBS no longer reports that it did not shut down properly. Zoom is left open.
- Closing never hangs: anything that will not close is skipped after a few seconds.

## Improved
- Much smoother window: the OnlyT checks, the JW display (OCR) check while Auto Toggle is off, the XR mixer meter polling and the OBS auto-connect no longer hold up the window. Typical short freezes dropped from about 35 a minute to a few per meeting.
- The Settings page for OnlyT is tidied up (nothing overlaps at larger display scales).
- The log now shows each step of the closing sequence with timings, to make any problem easy to find.

## Notes
- Tip: if the OBS virtual camera ever fails to start, check that Zoom is not using "OBS Virtual Camera" as its camera (turn Zoom video off or pick another camera).
- Optional diagnostics: create an empty file `%APPDATA%\JWL-OBS-Assistant\profile.on` to log slow background jobs. Delete it to switch it off.
