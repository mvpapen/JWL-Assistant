# X-Air Mixer Subsystem — Read-Only Architecture Audit

**Purpose:** Baseline documentation of the existing X-Air/OSC mixer subsystem, produced *before* any WPF UI migration work, per the "Do not migrate the mixer with the main UI" requirement. No mixer code was modified to produce this report.

**Target file audited:** `JWL+OBS Assistant v7.0.0 new UI.ps1` (fresh copy of the main app that will host the WPF migration; mixer code is currently identical to the production script). Line numbers below refer to that file.

**Date:** 2026-10-25

---

## Executive summary

- Mixer communication uses UDP/OSC through `System.Net.Sockets.UdpClient`.
- Meter reception is a **polling model**: a WinForms `Timer` runs every 50 ms and drains up to 30 UDP packets per tick — on the UI thread.
- Meter packets are OSC `/meters/N` blob messages. Blob samples are signed little-endian `Int16`; the code converts them to dBFS with `raw / 256.0`, clamps to `[-90, 0]`, then adds a **+15 dB calibration offset** before storage.
- Meter bars are displayed as calibrated dB values, not linear amplitude. The vertical mapping is piecewise linear: `+10..0 dB` occupies the top 25%; `0..-50 dB` occupies the bottom 75%.
- The meter panel is owner-drawn WinForms UI, with an instantaneous bar, RMS EMA line, and peak-hold line.
- Mixer fader values are normalized `0.0..1.0` OSC floats, using a piecewise-linear empirical taper with unity at `0.75`.
- OSC sends have **no acknowledgment processing**. Fader replies are cached when received, but ordinary sends only report UDP send success.
- Ducking and Auto Mode are implemented with WinForms timers and synchronously issue OSC writes from timer callbacks.
- Snapshot restores are triggered by several OBS/scene-related paths and use delayed WinForms timers for post-load synchronization.

---

## 1. OSC reception and processing

**Socket type and binding** — `Start-XrMeterReceiver`, lines 15486–15560:

```powershell
$script:XrMeterUdp = New-Object System.Net.Sockets.UdpClient(0)
$script:XrMeterUdp.Client.ReceiveTimeout = 10
```

Binds to an ephemeral local port (not 10024) because the mixer replies to the *source port* that sent the `/meters` subscription (comment at lines 15503–15508: "XR12 replies to the SOURCE PORT that sent /meters — UdpClient(0) lets OS choose a free port").

**No background thread/runspace.** `Receive-XrMeterPackets` is invoked by a WinForms timer:

```powershell
$script:XrMeterTimer = New-Object System.Windows.Forms.Timer
$script:XrMeterTimer.Interval = 50
$script:XrMeterTimer.Add_Tick({ Receive-XrMeterPackets; ... })
```
(lines 16510–16518)

**Packet processing** — `Receive-XrMeterPackets` (line 15762+) drains up to 30 packets per tick (`$maxReads = 30`), exiting via the 10 ms receive timeout when nothing more is pending.

OSC address parsing (lines 15783–15802): scan for the null terminator, decode ASCII, advance to the next 4-byte boundary, then inspect the type tag.

Non-`/meters` packets are also checked for fader float replies (`,f` type tag, big-endian float reversed on little-endian hosts, lines 15825–15845).

**No dedicated receive thread/runspace exists** — all receive + parse work runs inside the UI-thread WinForms timer callback.

---

## 2. Meter encoding and conversion

**OSC envelope** — `ConvertFrom-XAirMeters` (lines 15685–15727) expects: 4-byte-padded OSC address, type tag `,b`, 4-byte big-endian blob length, then blob contents.

**Blob format** — `ConvertFrom-XAirMeterBlob` (lines 15734–15760):
- Bytes 0–3: little-endian `Int32` channel count.
- Bytes 4+: signed little-endian `Int16` samples.

```powershell
$count = [BitConverter]::ToInt32($Blob, 0)
$raw   = [BitConverter]::ToInt16($Blob, $off)
$dB    = [Math]::Max(-90.0, [Math]::Min(0.0, [double]$raw / 256.0))
```

Formula: `dB_raw = clamp(raw / 256, -90, 0)`. Both `Peak` and `RMS` fields are set to the same value — **there is no separate raw RMS sample in the incoming blob**.

**Storage calibration** — `Receive-XrMeterPackets` (lines 15801–15818) adds a further fixed offset:

```powershell
$script:XrMeterLevels[$ch + 1] = $channels[$ch].Peak + 15.0
```

**Final stored value:** `dB_stored = clamp(raw/256, -90, 0) + 15`. Code comments describe this `+15 dB` as a calibration because raw pre-fader values run ~15 dB below the desired display.

---

## 3. Meaning of displayed values

Displayed values are **calibrated dBFS-style logarithmic levels** — confirmed by comment ("Decode X-Air meter blob into per-channel dBFS values", lines 15729–15733) and usage (`$dBFS2 = ... Get-XrMeterLevel ...`, line 20316; dBFS label description near line 20091).

They are **not** normalized 0–1 amplitude, linear amplitude, or raw integer samples. (Normalized 0–1 fader values are a separate, unrelated representation — see §8.)

---

## 4. Meter scale calculation and drawing

Owner-drawn `Paint` handler, lines 20258–20380. Comment claims "+10 dB at top, -70 dB at bottom (80 dB span)" (line 20279), **but the actual formula only covers +10 to -50 dB** — values below -50 produce zero fill. This is a direct **inconsistency between comment and implementation**.

```powershell
$pct =
    if ($dB -ge 10.0) { 1.0 }
    elseif ($dB -gt 0.0) { 0.75 + ($dB / 10.0) * 0.25 }
    elseif ($dB -gt -50.0) { 0.75 * (1.0 + $dB / 50.0) }
    else { 0.0 }
$fillH = [int]($pct * $barH)
$fillY = $barH - $fillH
```
(lines 20281–20289)

Piecewise linear mapping (not logarithmic at draw time — the dB values themselves are already logarithmic):

```
p(dB) = 1                      if dB >= 10
      = 0.75 + 0.025*dB        if 0 < dB < 10
      = 0.75*(1 + dB/50)       if -50 < dB <= 0
      = 0                      if dB <= -50
```

---

## 5. Scale markings and thresholds

Fixed pixel-fraction background zones (lines 20266–20272):

```powershell
$_bgBlkY = [int]($_bgH * 0.05)   # +8 dB boundary
$_bgRedY = [int]($_bgH * 0.355)  # -7 dB boundary
$_bgYelY = [int]($_bgH * 0.52)   # -18 dB boundary
```

| Zone | Range | Approx. dB |
|---|---|---|
| Near-black | top 0–5% | above ~+8 dB |
| Red | 5–35.5% | ~+8 to -7 dB |
| Yellow | 35.5–52% | ~-7 to -18 dB |
| Green | 52–100% | below ~-18 dB |

Same thresholds split the filled bar into color segments (lines 20290–20310).

**Ruler**: drawn at lines 20942–20989 using the same two-segment mapping and labeled down to `-50`, but **the ruler control is currently commented out / not added to the form** (line 20989: `# $frmM.Controls.Add($pRuler)   # ruler hidden: does not align with fader strips`).

---

## 6. Update frequency

- **Mixer subscription keepalive**: every 5000 ms (`$script:XrKeepaliveTimer.Interval = 5000`, lines 15536–15556). Comments state X-Air subscriptions expire after ~10 s.
- **Meter poll/drain timer**: every 50 ms (line 16511), draining up to 30 packets per tick, **and re-registering the meter subscription on every single tick** (lines 16513–16518) — far more often than the ~10 s expiry requires.
- **Paint/redraw**: comment estimates ~100 ms repaint cadence (lines 19973–19975). Painting reads from the shared `$script:XrMeterLevels` state rather than the socket directly — reception and rendering are decoupled, reception being the faster of the two.

---

## 7. Peak, peak-hold, RMS/decay behavior

**Peak hold** (lines 19968, 20317–20319): initialized to `-90.0` per strip; updated to the max of itself and current value; reset to `-90.0` only when the current reading falls to `-50 dB` or below.
- **No time-based decay** — peak persists indefinitely at its maximum until the signal drops to ≤ -50 dB, then snaps back to -90 immediately (not a conventional timed peak-hold/decay).

**RMS EMA** (lines 19969, 20321, 20324):

```powershell
$rms   = 0.93 * $previousRms + 0.07 * [Math]::Pow(10.0, $dBFS2 / 10.0)
$rmsDB = 10.0 * [Math]::Log10([Math]::Max(1e-12, $rms))
```

Comment estimates a time constant of ~1.4 s at 100 ms paint ticks.

**Master meter** does **not** use the real `/meters/2` (LR) value for drawing — it takes the max of channels 1–9 instead (lines 20347–20354), even though `/meters/2` data is separately stored under keys 17/18 (lines 15810–15814). Likely an inconsistency/bug.

---

## 8. Fader position ↔ OSC value mapping

**dB → normalized (0–1)**, `ConvertTo-LinearFader` (lines 16209–16234):

```
L(dB) = 0                         if dB <= -90
      = 0.75 + 0.75*(dB/40)       if -90 < dB <= 0
      = 0.75 + 0.25*(dB/10)       if 0 < dB < 10
      = 1                         if dB >= 10
```

**Normalized (0–1) → dB**, `ConvertTo-Decibels` (lines 16237–16259):

```
dB = ((L - 0.75) / 0.75) * 40     if L <= 0.75
dB = ((L - 0.75) / 0.25) * 10     if L > 0.75
```

⚠️ **These two functions are not true inverses at the low end**: `ConvertTo-LinearFader(-40) = 0` (pre-floor), but `ConvertTo-Decibels(0) = -90`. Round-tripping a fader value through both functions near the bottom of the range does not return the original value.

**Read/write**: `Read-XrFaderPosition` (lines 16255–16272) does **not** query the mixer — it returns a cached value or defaults to `0.75` if nothing cached yet. `Write-XrFaderPosition` (lines 16274–16302) clamps to 0–1, updates the cache, and sends an OSC float.

---

## 9. OSC command sending

`Send-XrOsc` (lines 15416–15505) opens a **new UDP client per call**, builds: null-terminated/4-byte-padded ASCII address, type tag (`,i` for int, `,f` for float), big-endian payload. Returns `true` purely on local `UdpClient.Send()` success — **no delivery/ack confirmation, no retry, no command correlation**.

Snapshot loads use `Send-XrOsc $XR_SNAPSHOT_PATH $n` where `$XR_SNAPSHOT_PATH = "/-snap/load"` (line 15045).

---

## 10. Connection loss, timeout, reconnection

**Reachability check** — `Test-MixerPing` (lines 15274–15322) is **not ICMP**; it sends an OSC `/info` query and waits up to 300 ms for any reply.

**Offline handling** — `Update-XrStatus` (lines 15323–15415): marks `_xrOfflineSince`, and after 10 s offline triggers `Start-AutoScanAsync` once per offline period (lines 15367–15382).

**Reconnection** — transition detected via `_xrWasOnline` flag; on reconnect: `Log "Mixer reconnected ✓ — syncing faders"` then `Sync-XrMixerFaders` (lines 15385–15400). Also stops a broadcast retry timer.

**No exponential backoff** anywhere observed. Retry behavior consists of: 3 broadcast attempts in `Find-XrMixer` (lines 15103–15121), a flat 10 s offline delay before background scan, and a separate retry timer in `Update-XrStatus`. The meter-receive timer itself has no explicit socket-recreate logic on failure.

---

## 11. Audio-level monitoring driving automation

**Ducking** explicitly uses XR meter data, not OBS audio (comment: "Uses XR12 meter data directly via OSC (not OBS audio)", ~lines 16530–16535).

- `Test-MediaAudioActive` compares a configured meter channel against a threshold (lines 16170–16175).
- `DuckingTimer` runs every 200 ms (lines 16522–16525).
- Trigger requires: `Cfg.XR.DuckingEnabled` on, music not already playing, media audio active, and an onset delay elapsed (default 500 ms from `Cfg.XR.OnsetMS`, lines 16620–16625).
- When active: computes `duckedDB = currentDB + Cfg.XR.DuckAmountDB`, converts back to linear, and writes the fader (lines 16640–16655) — either one podium channel or all input channels except the media channel. Original values are restored when the condition ends.

**Auto Mode** (lines 16046–16180) is a separate 100 ms timer (line 16098) that raises channels to 0 dB above a `-35.0 dB` threshold (line 16110), otherwise applies an idle wave between ~-30 and -23 dB.

---

## 12. Mixer snapshots ↔ OBS scene changes

`Restore-XrSnapshot` (lines 16017–16039) sends `/-snap/load`, then schedules a 600 ms one-shot timer that calls `Sync-XrMixerFaders` afterward (and, for the Auto Mode path, an additional 850 ms timer before Auto Mode starts).

Observed callers of `Restore-XrSnapshot`: lines 3921, 6679, 8090, 8140, 11876, 17571, 21567 — **no single universal "OBS scene changed" event handler**; snapshot restoration is distributed across several configured scene/PTZ/autostart code paths.

The auto-start path (lines 3910–3930) is notably **blocking**:

```powershell
Set-ObsScene $cfg.Scene
Start-Sleep -Milliseconds 500
Restore-XrSnapshot $cfg.Snapshot
```

The OSC send itself is non-blocking UDP; the surrounding orchestration uses blocking sleeps and deferred WinForms timers.

---

## 13. WinForms/UI coupling (migration-relevant)

### UI-coupled (would need adaptation for WPF)
- `Show-MixerPanel` and all WinForms control creation (line 19878+).
- Meter `Panel.Add_Paint` rendering (lines 20258–20380), ruler painting (20942–20989), fader panel paint/mouse handlers (~20400+).
- All `System.Windows.Forms.Timer` instances: `XrMeterTimer` (16510), `XrKeepaliveTimer` (15536), `DuckingTimer` (16522), Auto Mode timer (~16098), snapshot delay timers (16027–16036).
- Direct control mutation (`.Text`, `.Invalidate()`, `.Visible`, `.Image`, `.BackColor`, `.BringToFront()`), e.g. lines 16052–16059.
- `Update-XrStatus` UI updates (15346–15414).
- `[System.Windows.Forms.Application]::DoEvents()` inside `Find-XAirByBroadcast` discovery (15055–15073) — a reentrancy risk regardless of UI framework.

### Comparatively pure/data-oriented (safe to keep behind a new shell)
- OSC padding (`Format-XrPad4Bytes`, 15267–15272).
- OSC serialization (`Send-XrOsc` core, 15416–15505).
- OSC envelope + blob parsing (`ConvertFrom-XAirMeters`/`ConvertFrom-XAirMeterBlob`, 15685–15760).
- Fader conversion formulas (`ConvertTo-LinearFader`/`ConvertTo-Decibels`, 16209–16259).
- Discovery/reachability logic (subject to its current synchronous/blocking behavior).

None of these are *fully* isolated today — they all reach into `$script:Cfg`, shared global meter/fader caches, and `Log`.

---

## 14. Directly observed limitations / code smells (evidence-based, not speculative)

1. **Meter subscription re-registered every 50 ms** (16513–16518) despite a 5 s keepalive already covering the ~10 s expiry — unnecessary network chatter.
2. **UDP receive + OSC parsing runs on the WinForms UI thread** inside a `Timer.Tick`, not a background thread/runspace (16510–16518, 15762+).
3. **Scale documentation/implementation mismatch**: comments say -70 dB floor (20279), code implements -50 dB floor (20283–20287); ruler comment also says -50 (20956).
4. **`ConvertTo-LinearFader`/`ConvertTo-Decibels` are not true inverses** at the low end (see §8).
5. **`Read-XrFaderPosition` never actually queries the mixer** — returns cache or a hardcoded `0.75` default (16255–16272); automation can act on stale/fabricated values.
6. **No OSC send acknowledgment/retry/correlation** anywhere in `Send-XrOsc` (15488–15491).
7. **Peak-hold has no time decay** — resets immediately and only when signal drops to ≤ -50 dB (20317–20319).
8. **Master meter uses max(ch1–9) instead of actual `/meters/2` LR data** (20347–20354 vs 15810–15814).
9. **Magic numbers throughout**, not named constants: `+15.0` calibration, `-50/-18/-7/+8` zone thresholds, Auto Mode `-35` threshold, default `500 ms` duck onset, etc.
10. **Blocking `Start-Sleep -Milliseconds 500`** in the scene/snapshot auto-start path (3921–3924).
11. **Allocation-heavy painting**: brushes are cached, but new `Pen` objects are created/disposed every paint tick for RMS/peak lines (20324–20340, 20363–20378).

---

## Data flow diagrams

**UDP meter packet → painted pixel:**
```
XR mixer
  | UDP OSC /meters/N, ,b, blob
  v
XrMeterUdp (ephemeral local port)
  | XrMeterTimer tick, every 50 ms
  v
Receive-XrMeterPackets
  +--> OSC address/type/blob parsing
  +--> ConvertFrom-XAirMeterBlob (signed LE Int16, raw/256, clamp [-90,0])
  +--> +15 dB calibration
          v
      $script:XrMeterLevels[channel]
          v
      Meter Panel Paint handler
          +--> instantaneous dB bar
          +--> RMS EMA line
          +--> peak-hold line
          +--> piecewise dB-to-pixel mapping
          v
      Graphics.FillRectangle / DrawLine
```

**UI fader drag → UDP packet out:**
```
WinForms fader Panel mouse event
  v
normalized UI value 0..1000 -> linear = value/1000
  v
Write-XrFaderPosition
  +--> clamp 0..1, cache, path /ch/NN/mix/fader
  v
Send-XrOsc (address padded, type tag ,f, big-endian float)
  v
UdpClient.Send() -> XR mixer
```

---

## Recommended migration boundary

**Keep as pure/core logic** (behind a WPF-facing service, with global state eventually wrapped, not rewritten):
OSC serialization/padding, OSC envelope + blob parsing, meter calibration math, fader conversion formulas, fader cache management, discovery/reachability logic.

**Adapt for WPF:**
All WinForms `Timer`s, `Receive-XrMeterPackets`'s current UI-thread invocation, `Show-MixerPanel` and all control creation, meter/ruler/fader paint handlers, direct control mutation calls, `Application.DoEvents()` usage in discovery.

**Key recommendation:** before any WPF work touches the mixer, separate the packet-receive/parse/calibrate logic from the UI-thread timer (e.g., move it to a background thread or timer-driven-but-UI-agnostic service that the WPF layer only reads from) — this is the single biggest structural change needed regardless of which UI framework is used.

---

## Proposed regression validation cases

**Meter blob conversion** (`raw Int16 → stored dB after +15 calibration`):

| Raw Int16 | Raw dB (raw/256, clamped) | Stored (+15) |
|---:|---:|---:|
| 0 | 0 | +15 |
| -256 | -1 | +14 |
| -2560 | -10 | +5 |
| -3840 | -15 | 0 |
| -7680 | -30 | -15 |
| -12800 | -50 | -35 |
| -32768 | -90 (clamped from -128) | -75 |
| 32767 | 0 (clamped from +128) | +15 |

**Bar fill fraction** (bar height H=1000 px):

| Display dB | Fill fraction | Fill px |
|---:|---:|---:|
| +10 | 1.00 | 1000 |
| 0 | 0.75 | 750 |
| -5 | 0.625 | 625 |
| -18 | 0.48 | 480 |
| -30 | 0.30 | 300 |
| -50 | 0.00 | 0 |
| -60 | 0.00 | 0 |

**Fader conversion** (`ConvertTo-LinearFader`):

| dB in | Normalized out |
|---:|---:|
| -90 | 0.0 |
| -40 | 0.0 (post-clamp) |
| -30 | 0.1875 |
| -20 | 0.375 |
| 0 | 0.75 |
| +5 | 0.875 |
| +10 | 1.0 |

**OSC serialization:**
- `Send-XrOsc "/ch/01/mix/fader" ([single]0.75)` → address padded to 4 bytes, type tag `,f`, big-endian IEEE-754 float `0.75`.
- `Send-XrOsc "/ch/01/mix/on" ([int]1)` → type tag `,i`, big-endian int `1`.
- `Send-XrOsc` returns `true` on local UDP send success alone — no mixer response required under current behavior (this itself should be preserved or deliberately changed with sign-off, not silently "fixed").

**Peak/RMS:**
- Reading sequence `-20, -30 dB` → peak stays at `-20` (not reset by the lower second reading).
- Reading `-50 dB` or lower → peak resets to `-90`.
- RMS update from 0 baseline with `-20 dB` input: `0.93*0 + 0.07*10^(-20/10) = 0.0007` (linear), converted back via `10*log10(...)`.
- Ducking should not engage until the meter stays above threshold for the full onset delay (default 500 ms when `Cfg.XR.OnsetMS` is unset).

---

## Why the mixer should remain unchanged during the initial WPF migration

1. The subsystem is functionally load-bearing for live production (real-time levels, automation, snapshots) — any regression is immediately visible/audible during an actual meeting, with no safe "undo."
2. Several of the behaviors documented above (non-inverse fader conversion, -50 vs -70 dB scale mismatch, master-meter max-of-9 substitution, no peak decay) are **de facto current behavior that operators have presumably gotten used to** — changing them incidentally while "just" porting to WPF would silently alter sound/level behavior without anyone deciding to do so.
3. The UI-thread-coupled network polling (§6, §13) is a real structural issue, but fixing it is a separate, independently testable unit of work from a visual framework swap — mixing the two increases risk and makes any regression harder to attribute to one cause or the other.
4. This report's test cases give a concrete, numeric baseline to diff against once a mixer migration is eventually undertaken — that baseline only has value if the mixer isn't touched until the rest of the WPF shell is stable.
