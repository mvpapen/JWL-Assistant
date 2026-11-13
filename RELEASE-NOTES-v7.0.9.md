# JWL Assistant v7.0.9

Upgrade from v7.0.6c or v7.0.8. Download **JWL-Assistant-Setup-7.0.9.exe** below and run it (your settings are kept).
This version includes everything from v7.0.8 (see RELEASE-NOTES-v7.0.8.md).

## Improved
- **Smoother window.** The XR mixer meter polling no longer piles up packets: only the newest meter packet is decoded, so the meter timer no longer gets slower the longer the app runs (it used about 20 ms of every 50 ms tick before; now about 7 ms or less).
- **Lighter new UI.** The Zoom row and the other button rows of the new UI refresh with about a tenth of the work (the Zoom row every 300 ms, and the buttons it mirrors are looked up once and remembered). The Cut flash, the dancing music notes and the other animations keep their speed.
- In a test meeting session the window froze 4 times in 2 minutes (all while starting or closing), compared with about 35 times a minute in v7.0.7.

## Included from v7.0.8
- OnlyT: countdown in the new UI, auto-hide, **auto-start before the meeting**, read in the background.
- OBS button starts OBS; new JW Library button; virtual camera button follows OBS.
- Auto Toggle warns when OBS or JW Library is not open.
- Closing menu: **Close JWL Assistant only** (brings OBS back into view) or **Close all** (OnlyT, JW Library and OBS, closed gracefully; Zoom is left open).

## Notes
- If the OBS virtual camera ever fails to start, check that Zoom is not using "OBS Virtual Camera" as its camera.
- Optional diagnostics: create an empty file `%APPDATA%\JWL-OBS-Assistant\profile.on` to log slow background jobs. Delete it to switch it off.
