# JWL-Assistant
A lightweight yet powerful tool to auto-toggle your Zoom camera and control OBS functions and an OSC-based sound mixer.
JWL-Assistant works only when used with JW Library, published by the Watch Tower Bible and Tract Society of Pennsylvania. It is an independent project and is not affiliated with or endorsed by them.
<img width="632" height="738" alt="image" src="https://github.com/user-attachments/assets/b4cbb42e-ff53-4181-953c-d0f46ee94dba" />

JWL Assistant is a Windows tool that helps automate live meeting production with JW Library, OBS and Zoom. It combines scene control, OCR-based switching, Zoom meeting helpers, audio utilities, and quick operator actions in one interface to reduce manual steps during meetings. The goal is simple: make transitions smoother, setup faster, and operation more reliable for congregation AV workflows.

JWL Assistant - First Run Guide
Version: v6.1.8b7 x

What you need installed
- OBS Studio (with WebSocket enabled)
- Zoom desktop client
- Tesseract OCR
- JWLibrary
Before first launch
1. Start OBS Studio.
2. In OBS, verify WebSocket server is enabled.
3. Verify OBS connection settings in app Settings:
   - Host: 127.0.0.1
   - Port: 4456 (or match OBS entry)
   - Password: match OBS (or leave empty in both places)
4. Verify Tesseract path in app Settings.
   Typical path: C:\Program Files\Tesseract-OCR\tesseract.exe
5. Set Zoom Join Meeting ID and Display Name in app Settings.

First-run quick test
1. Launch JWL+OBS Assistant.
2. Confirm OBS status changes from waiting to online.
3. Test scene switch buttons.
4. Test Join Zoom button.
5. Confirm OCR status toggles ON/OFF when content is visible.
6. Enable HotKeys in Zoom for Canera , Mic and Mute all

If something does not work
- OBS connect failed:
  - Ensure OBS is open
  - Ensure WebSocket is enabled
  - Ensure port/password match Settings
- Zoom join failed:
  - Confirm Zoom desktop app is installed
  - Confirm meeting ID is valid
- OCR not working:
  - Recheck Tesseract path
  - Re-select OCR ROI in Settings
OSC Mixer UI for  Behringer XAir 18
  - <img width="995" height="704" alt="image" src="https://github.com/user-attachments/assets/3535700d-5023-4c4d-966d-728e389039e5" />
  Main features:
- When selecting PTZ location it will automaticaly select the right snapshots.
- 8 Snapshot presets.(Snapshot is a copy of a customised Mixer Layout)
- Auto Duck function when Music plays , and when Reader reads . Build in Limiter  


Windows security note
- Unsigned EXE files can show SmartScreen warnings on some PCs.
- If prompted, use More info -> Run anyway only if you trust this file source.

Support info to include in bug reports
- App version
- Windows version
- OBS version
- Zoom version
- Screenshot or copied log lines around the failure
