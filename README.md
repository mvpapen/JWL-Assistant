# JWL-Assistant
A lightweight yet powerful tool that automatically toggles your Zoom camera and controls OBS functions and OSC-based audio mixers.
JWL-Assistant works only when used with JW Library, published by the Watch Tower Bible and Tract Society of Pennsylvania. It is an independent project and is not affiliated with or endorsed by them.

<img width="474" alt="image" src="https://github.com/user-attachments/assets/b4cbb42e-ff53-4181-953c-d0f46ee94dba" />

JWL Assistant is a Windows tool that helps automate live meeting production with JW Library, OBS and Zoom. It combines scene control, OCR-based switching, Zoom meeting helpers, audio utilities, and quick operator actions in one interface to reduce manual steps during meetings. The goal is simple: make transitions smoother, setup faster, and operation more reliable for congregation AV workflows.

JWL Assistant - First Run Guide
Version: v6.1.8 and later

For Download : https://github.com/mvpapen/JWL-Assistant/releases/latest

For Video tutorials click this link : Video-tutorials.md

What you need installed
- OBS Studio (with WebSocket enabled)
-Zoom Desktop Client
-Tesseract OCR (installed automatically if not already present)
-JW Library with "Play Video on Second Display" enabled (required)
Before first launch
1. Start OBS Studio.
2. In OBS, verify WebSocket server is enabled.
3. Verify OBS connection settings in app Settings:
   - Host: 127.0.0.1
   - Port: 4456 (or match OBS entry)
   - Password: match OBS (or leave empty in both places)
   - Add a video source (a PTZ camera is recommended). USB cameras are easiest to set up. For PTZ control, install the           latest OBS PTZ plugin with UVC support.
   - add minmun 2 scenes; 1.Speaker + 2. Media (PTZ add Table , Demo, Speaker and Reader and so on.
   - for Media Scene use : Display capture or use capture card as Video source
4. Verify Tesseract path in App Settings.
   Typical path: C:\Program Files\Tesseract-OCR\tesseract.exe
5. Set Zoom Join Meeting ID and Display Name in App Settings.

First-run quick test (watch how it work video 4 min) https://go.screenpal.com/watch/cO1irDnuFHt
1. Launch JWL+OBS Assistant.
2. Confirm OBS status changes from .... Waiting to Online.
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
  - Confirm meeting ID and Name is valid
- OCR not working:
  - Recheck Tesseract path
  - Re-select the OCR region in Settings (best results are achieved with monitor scaling set to 100%).
  - 
OSC Mixer UI for  Behringer XAir 18 with USB, or 16 no USB connection to PC= Analog only

 <img width="497"  alt="image" src="https://github.com/user-attachments/assets/3535700d-5023-4c4d-966d-728e389039e5" />
  
Main features
- Simplified mixer layout customized for meeting use.
- (The original X Air Edit application is still required for mixer configuration.)
- Auto scan for Mixer IP
- Link any mixer snapshot to any saved PTZ camera preset.
- 8 Snapshot presets.(Snapshot is a copy of a customised Mixer Layout)
- Automatic audio ducking when music plays or when the reader speaks.
- Includes a built-in limiter that can be enabled or disabled.
- While many automatic mixing functions are available, you can manually override them at any time.  


Windows security note
- Unsigned EXE files can show SmartScreen warnings on some PCs.
- If prompted, use More info -> Run anyway only if you trust this file source.

Support info to include in bug reports
- App version
- Windows version
- OBS version
- Zoom version
- Screenshot and/or copied log entries related to the issue.

License and third-party software
- This repository is licensed under the custom JWL-Assistant license in LICENSE.
- The app is provided as-is, without warranty, and the author is not liable for damages arising from its use, to the extent allowed by law.
- If someone redistributes a modified version, they must clearly mark the changes, provide the modified source to recipients, and send a copy of those changes back through the official project repository.
- Tesseract OCR is a separate upstream project and remains licensed under the Apache License 2.0.
- The installer may download Tesseract with permission if it is not already installed. Credit for Tesseract belongs to its original authors and maintainers.
- See LICENSE for the project license and THIRD-PARTY-NOTICES.txt for third-party software details.
