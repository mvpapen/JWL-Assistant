# --- STA bootstrap (PS5.1-safe) ---
$scriptPath = $PSCommandPath
if (-not $scriptPath -and $MyInvocation.MyCommand.Path) { $scriptPath = $MyInvocation.MyCommand.Path }
# When running as ps2exe compiled EXE, use the EXE location
if (-not $scriptPath) {
    try {
        $exePath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        if ($exePath -and (Test-Path $exePath)) { $scriptPath = $exePath }
    }
    catch {}
}
try { if ($scriptPath) { Unblock-File -Path $scriptPath -ErrorAction SilentlyContinue } } catch {}
if ($scriptPath -and [Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    $ps = 'pwsh.exe'
    $wd = Split-Path -Path $scriptPath
    $psArgs = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', "`"$scriptPath`"")
    Start-Process -FilePath $ps -ArgumentList $psArgs -WorkingDirectory $wd -WindowStyle Normal
    return
}

# =============================
# == JWL Assistant v6.1.8e ==
# =============================
# Fixed in v4.0.8:
# - REMOVED WASAPI Loopback and VB-cables completly, fixed Tooltips
# - Added color to Program and Scenepicker button and added Scene auto start.
# - Changed Button size and text to 10 pt Segoe UI for better readability
# - Removed JWL-Audio monitoring via OBS events
# - Added new "OBS Studio" button that toggles OBS visibility, with auto-detection of OBS window and graceful degradation if not found
# - Added New Mixer UI with separate volume sliders for Mic and System audio, with real-time VU meter feedback (requires UI Automation, will degrade gracefully if not available)
# - Added new "OBS Record" button that toggles OBS recording state, with auto-detection of OBS window and graceful degradation if not found
# - Added new "Toggle Zoom" button that auto-detects Zoom Meeting window and toggles it between main monitor and projector, with smooth animation
# - Added new "Projector Switch" button that toggles the Zoom window between main monitor and projector, with auto-detection of Zoom Meeting window and smooth animation
# - Added new "Join Zoom" button that detects and focuses the Zoom Meeting window, with auto-start of Polls panel (configurable)
# - Added new "Size" Button that cycles through predefined window sizes (configurable) for the Zoom Meeting window, with auto-detection and graceful degradation if not found
# - Added new "Polls" button that opens the Zoom Polls panel and starts the first poll, with auto-detection of Zoom Meeting window and graceful degradation if not found
# - Added new "Attendance" button that shows current Zoom Meeting attendance (answered vs total) in a tooltip, with auto-refresh every 5 minutes (requires UI Automation, will degrade gracefully if not available)
# - Added new "Focus Mode" button that toggles Zoom Focus Mode (hides participant videos) with auto-detection of Zoom Meeting window and graceful degradation if not found
# - Added new "Hand Alert" button that shows a full-screen hand overlay on a selected monitor for 30s (configurable) when clicked, with flashing button while active
# - Added new "Zoom Status" button that shows current mic/cam status in Zoom and allows toggling (requires UI Automation, will degrade gracefully if not available)
# =============================
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName Microsoft.VisualBasic

# Try to load UI Automation assemblies - if they fail, disable Zoom status monitoring
$script:UIAutomationAvailable = $false
try {
    Add-Type -AssemblyName UIAutomationClient
    Add-Type -AssemblyName UIAutomationTypes
    $script:UIAutomationAvailable = $true
}
catch {
    Write-Host "UI Automation assemblies not available - Zoom status monitoring will be disabled" -ForegroundColor Yellow
}

$script:VirtualCameraStatus = $false  # Track virtual camera status

# Zoom status tracking
$script:ZoomMicStatus = $null    # null=unknown, $true=on, $false=off
$script:ZoomCameraStatus = $null # null=unknown, $true=on, $false=off
$script:_lastManualToggleTime = $null  # Timestamp of last manual mic/cam click (guards UIA poll overwrites)
$script:ZoomStatusTimer = $null  # Timer for checking Zoom status
$script:ZoomParticipantFound = $false
$script:ZoomMicLocked = $false       # True while Auto Toggle is active and mic button is locked
$script:ZoomCamLocked = $false       # True while Auto Toggle is active and camera button is locked
$script:UIAutomationTested = $false
$script:UIAutomationWorking = $false
$script:_participantsAutoOpened = $false  # Guard: open Participants panel only once per meeting
$script:ZoomInMeeting = $false   # Track whether a Zoom Meeting window/participant is active
$script:ZoomFocusModeOn = $false # Track Focus Mode state (our best guess)
$script:ZoomFocusStatusTimer = $null # Timer for polling Focus Mode state after manual toggle
$script:ZoomFocusModeStoppedAt = $null # Timestamp of last Focus Mode stop (Zoom needs ~60s before re-enabling)
$script:_autoJoinPollsTimer = $null   # Timer: auto-start polls after joining Zoom
$script:_zoomStatusRS = $null        # Persistent STA runspace for Zoom UIA scans (created once, reused)
$script:_autoJoinPollsAttempts = 0    # Attempt counter for auto-polls timer
$script:_pollsStartTimer = $null      # One-shot timer that fires Zoom-StartFirstPoll off the join-timer tick
$script:_pollsActivated = $false      # True once Polls have been started (manually or auto)
$script:_zoomNotFoundStreak = 0       # Consecutive not-found cycles; resets _pollsActivated only after 2+
$script:_joinAnimTimer = $null        # WinForms timer for Join button pulsing animation while status is checking
$script:_joinAnimFrame = 0            # Animation frame counter
$script:ZoomAttendanceCount = $null   # Last read attendance: [pscustomobject]@{Answered=N; Total=M}
$script:_attendanceRefreshTimer = $null  # Repeating timer: re-reads attendance every 5 min
$script:_attendanceOneShotTimer = $null  # One-shot timer for initial attendance read
$script:_attendanceRunspace = $null  # Background runspace for non-blocking UI-Automation read
$script:_attendancePS = $null  # PowerShell instance running inside the runspace
$script:_attendanceAsyncResult = $null  # BeginInvoke handle
$script:_attendancePollTimer = $null  # 200ms UI-thread timer that checks runspace completion
$script:_pollsRunspace = $null  # Background runspace for open-panel + start-poll sequence
$script:_pollsPS = $null
$script:_pollsAsyncResult = $null
$script:_pollsPollTimer = $null  # 200ms completion-check timer for polls runspace
$script:_focusRunspace = $null  # Background runspace for Zoom-ToggleFocusMode
$script:_focusPS = $null
$script:_focusAsyncResult = $null
$script:_focusPollTimer = $null  # 200ms completion-check timer for focus runspace
$script:_focusModeFromAutoTimer = $false  # True when triggered from countdown timer

# OBS Recording state
$script:OBSRecording = $false   # Track OBS recording state (start/stop)

# Update-check state
$script:UpdateLatestTag = $null
$script:UpdateLatestUrl = $null
$script:UpdateAvailable = $false
$script:UpdateNotifyIcon = $null

# Hand Alert overlay state
$script:HandOverlayWindow = $null
$script:HandOverlayTimer = $null
$script:HandOverlayVisible = $false
$script:HandAlertWpfLoaded = $false
$script:HandAlertButtonTimer = $null

[System.Windows.Forms.Application]::EnableVisualStyles()
# --- script-scope flags/state ---
$script:ShuttingDown = $false   # <— add this here
$script:_connectInProgress = $false

# Initialize Join Zoom button tooltip/visual once the form is constructed
if ($btnZoomJoin) {
    try { Update-ZoomJoinButtonVisual } catch {}
}

# ========== THREAD-SAFE UI HELPER ==========
function Invoke-OnUI([scriptblock]$action) {
    try {
        if ($script:form -and -not $script:form.IsDisposed) {
            if ($script:form.InvokeRequired) {
                $script:form.BeginInvoke($action) | Out-Null
            }
            else {
                & $action
            }
        }
    }
    catch {}
}

function Ensure-HandAlertWpf {
    if ($script:HandAlertWpfLoaded) { return }
    try {
        Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
        $script:HandAlertWpfLoaded = $true
    }
    catch {
        try { Log "Hand Alert: failed to load WPF assemblies: $_" } catch {}
    }
}

function Get-HandAlertScreen {
    try {
        # Force log the config value first
        $configVal = "NOT_FOUND"
        if ($script:Cfg -and $script:Cfg.Zoom -and $script:Cfg.Zoom.Contains('HandAlertMonitor')) {
            $configVal = $script:Cfg.Zoom.HandAlertMonitor
        }
        Log "HAND ALERT DEBUG: Config HandAlertMonitor = $configVal"
        
        $screens = [System.Windows.Forms.Screen]::AllScreens
        Log "HAND ALERT DEBUG: Found $($screens.Count) screens total"
        
        # Ensure primary monitor is always index 0, others after
        $screens = $screens | Sort-Object @{ Expression = { -not $_.Primary } }, DeviceName
        
        # Log all screens BEFORE selection
        for ($i = 0; $i -lt $screens.Count; $i++) {
            $s = $screens[$i]
            Log "HAND ALERT DEBUG: Screen[$i]: $($s.DeviceName) $($s.Bounds.Width)x$($s.Bounds.Height) at $($s.Bounds.Left),$($s.Bounds.Top) Primary=$($s.Primary)"
        }
        
        if (-not $screens -or $screens.Count -eq 0) { 
            Log "HAND ALERT DEBUG: No screens found, using primary"
            return [System.Windows.Forms.Screen]::PrimaryScreen 
        }

        $index = 0
        if ($script:Cfg -and $script:Cfg.Zoom -and $script:Cfg.Zoom.Contains('HandAlertMonitor')) {
            $index = [int]$script:Cfg.Zoom.HandAlertMonitor
        }
        Log "HAND ALERT DEBUG: Using index $index (before bounds check)"
        
        if ($index -lt 0 -or $index -ge $screens.Count) { 
            Log "HAND ALERT DEBUG: Index $index out of bounds, resetting to 0"
            $index = 0 
        }
        
        $scr = $screens[$index]
        Log "HAND ALERT DEBUG: Selected screen: $($scr.DeviceName) bounds=$($scr.Bounds.Left),$($scr.Bounds.Top),$($scr.Bounds.Width),$($scr.Bounds.Height)"
        
        return $scr
    }
    catch {
        Log "HAND ALERT DEBUG: Exception in Get-HandAlertScreen: $($_.Exception.Message)"
        return [System.Windows.Forms.Screen]::PrimaryScreen
    }
}

function New-HandAlertWindow([System.Windows.Forms.Screen]$screen) {
    Ensure-HandAlertWpf
    if (-not $script:HandAlertWpfLoaded) { return $null }

    $xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        WindowStyle="None"
        ResizeMode="NoResize"
        AllowsTransparency="True"
        Background="Transparent"
        ShowInTaskbar="False"
        Topmost="True"
        WindowStartupLocation="Manual">
    <Grid Background="Transparent" IsHitTestVisible="False">
        <TextBlock Text="✋" FontSize="650" Foreground="Yellow"
                   HorizontalAlignment="Center" VerticalAlignment="Center"/>
    </Grid>
</Window>
"@

    $xml = [xml]$xaml
    $reader = New-Object System.Xml.XmlNodeReader $xml
    $window = [System.Windows.Markup.XamlReader]::Load($reader)

    $bounds = $screen.Bounds
    # WPF window coordinates are logical DIPs; Screen.Bounds returns physical pixels on a
    # DPI-aware process (pwsh.exe). Divide by the DPI scale so the overlay fills the screen
    # correctly at any Windows display scaling (100%, 125%, 150%, etc.).
    $dpi = Get-DpiScaleFactor
    $window.Left = $bounds.Left / $dpi
    $window.Top = $bounds.Top / $dpi
    $window.Width = $bounds.Width / $dpi
    $window.Height = $bounds.Height / $dpi
    
    try {
        Log "HAND ALERT DEBUG: New-HandAlertWindow physical bounds=$($bounds.Left),$($bounds.Top) $($bounds.Width)x$($bounds.Height) dpi=$dpi  WPF logical=$($window.Left),$($window.Top) $($window.Width)x$($window.Height)"
    }
    catch {}

    return $window
}

function Show-HandAlertOverlay {
    if ($script:HandOverlayVisible) { return }

    $screen = Get-HandAlertScreen
    $window = New-HandAlertWindow -screen $screen
    if (-not $window) { return }

    $script:HandOverlayWindow = $window
    $script:HandOverlayVisible = $true

    # Start transparent and fade in
    $window.Opacity = 0.0
    $window.Show()
    
    # Double-check window actually ended up on the right screen
    try {
        $actualLeft = $window.Left
        $actualTop = $window.Top
        $_dpi2 = Get-DpiScaleFactor
        $expectedLeft = $screen.Bounds.Left / $_dpi2
        $expectedTop = $screen.Bounds.Top / $_dpi2
        if ([Math]::Abs($actualLeft - $expectedLeft) -gt 10 -or [Math]::Abs($actualTop - $expectedTop) -gt 10) {
            Log ("Hand Alert: Window positioned wrong! Expected {0},{1} but got {2},{3} - forcing reposition" -f $expectedLeft, $expectedTop, $actualLeft, $actualTop)
            $window.Left = $expectedLeft
            $window.Top = $expectedTop
        }
        else {
            Log ("Hand Alert: Window positioned correctly at {0},{1}" -f $actualLeft, $actualTop)
        }
    }
    catch {
        Log ("Hand Alert: Could not verify window position")
    }

    # Make the window click-through at OS level
    try {
        $helper = New-Object System.Windows.Interop.WindowInteropHelper $window
        $hwnd = $helper.Handle
        if ($hwnd -ne [IntPtr]::Zero) {
            $style = [Win32]::GetWindowLong($hwnd, [Win32]::GWL_EXSTYLE)
            $style = $style -bor [Win32]::WS_EX_TRANSPARENT -bor [Win32]::WS_EX_LAYERED
            [void][Win32]::SetWindowLong($hwnd, [Win32]::GWL_EXSTYLE, $style)
        }
    }
    catch {
        try { Log "Hand Alert: failed to set click-through style: $_" } catch {}
    }

    $fadeIn = New-Object System.Windows.Media.Animation.DoubleAnimation
    $fadeIn.From = 0.0
    $fadeIn.To = 1.0
    $fadeIn.Duration = [System.Windows.Duration]::op_Implicit([TimeSpan]::FromMilliseconds(400))
    
    # Add completion handler to start blinking after fade-in
    $fadeIn.Add_Completed({
            # Start blinking animation - pulse between full and 30% opacity
            $blink = New-Object System.Windows.Media.Animation.DoubleAnimation
            $blink.From = 1.0
            $blink.To = 0.3
            $blink.Duration = [System.Windows.Duration]::op_Implicit([TimeSpan]::FromMilliseconds(800))
            $blink.AutoReverse = $true
            $blink.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
            $script:HandOverlayWindow.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $blink)
        })
    
    $window.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $fadeIn)

    # Auto-timeout after 30 seconds
    if ($script:HandOverlayTimer) { $script:HandOverlayTimer.Stop(); $script:HandOverlayTimer = $null }
    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromSeconds(30)
    $timer.Add_Tick({ param($src, $e)
            try { $src.Stop() } catch {}
            Hide-HandAlertOverlay
        })
    $script:HandOverlayTimer = $timer
    $timer.Start()

    # Start flashing the Hand Alert button
    try {
        if ($script:HandAlertButtonTimer) { $script:HandAlertButtonTimer.Stop(); $script:HandAlertButtonTimer = $null }
        $flashTimer = New-Object System.Windows.Forms.Timer
        $flashTimer.Interval = 400
        $state = $false
        $flashTimer.Add_Tick({
                if (-not $btnHandAlert) { return }
                $script:HandOverlayVisible = $true
                $global:__dummy = $null  # keep closure
                $script:__lastHandFlash = $state
                if ($state) {
                    $btnHandAlert.BackColor = [Drawing.Color]::FromArgb(64, 64, 64)
                }
                else {
                    $btnHandAlert.BackColor = [Drawing.Color]::FromArgb(255, 255, 0)
                }
                $state = -not $state
            })
        $script:HandAlertButtonTimer = $flashTimer
        $flashTimer.Start()
    }
    catch {}
}

function Hide-HandAlertOverlay {
    if (-not $script:HandOverlayVisible -or -not $script:HandOverlayWindow) { return }

    if ($script:HandOverlayTimer) { $script:HandOverlayTimer.Stop(); $script:HandOverlayTimer = $null }

    if ($script:HandAlertButtonTimer) {
        try { $script:HandAlertButtonTimer.Stop() } catch {}
        $script:HandAlertButtonTimer = $null
    }

    if ($btnHandAlert) {
        try {
            $btnHandAlert.BackColor = [Drawing.Color]::FromArgb(64, 64, 64)
        }
        catch {}
    }

    $window = $script:HandOverlayWindow

    $fadeOut = New-Object System.Windows.Media.Animation.DoubleAnimation
    $fadeOut.From = $window.Opacity
    $fadeOut.To = 0.0
    $fadeOut.Duration = [System.Windows.Duration]::op_Implicit([TimeSpan]::FromMilliseconds(400))
    $fadeOut.Add_Completed({
            try { $script:HandOverlayWindow.Close() } catch {}
            $script:HandOverlayWindow = $null
            $script:HandOverlayVisible = $false
        })
    $window.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $fadeOut)
}

function Toggle-HandAlertOverlay {
    try {
        $idx = 0
        if ($script:Cfg -and $script:Cfg.Zoom -and $script:Cfg.Zoom.Contains('HandAlertMonitor')) {
            $idx = [int]$script:Cfg.Zoom.HandAlertMonitor
        }
        $scrCount = [System.Windows.Forms.Screen]::AllScreens.Count
        Log ("Hand Alert: toggle requested (selected index={0}, screens={1})" -f $idx, $scrCount)
    }
    catch {}

    if ($script:HandOverlayVisible) { Hide-HandAlertOverlay }
    else { Show-HandAlertOverlay }
}
function Set-Anchor($ctrl, [string]$sides) {
    try {
        if (-not $ctrl) { return }
        if (-not ($ctrl.PSObject.Properties.Name -contains 'Anchor')) { return }
        $flags = [System.Windows.Forms.AnchorStyles]::None
        foreach ($s in $sides.Split(',')) {
            switch ($s.Trim()) {
                'Left' { $flags = $flags -bor [System.Windows.Forms.AnchorStyles]::Left }
                'Right' { $flags = $flags -bor [System.Windows.Forms.AnchorStyles]::Right }
                'Top' { $flags = $flags -bor [System.Windows.Forms.AnchorStyles]::Top }
                'Bottom' { $flags = $flags -bor [System.Windows.Forms.AnchorStyles]::Bottom }
            }
        }
        $ctrl.Anchor = $flags
    }
    catch {}
}

function Pt([int]$x, [int]$y) { New-Object System.Drawing.Point $x, $y }
function Sz([int]$w, [int]$h) { New-Object System.Drawing.Size  $w, $h }

# ===== ROUNDED CORNERS FOR MODERN UI =====
$script:RoundedButtonHelperAvailable = $false
$script:_roundedControls = New-Object System.Collections.ArrayList  # tracks (control, radius) for re-apply after scale
$roundedRefAssemblies = @("System.Windows.Forms.dll", "System.Drawing.dll")
try {
    $drawingAsm = [System.Drawing.Region].Assembly
    if ($drawingAsm -and $drawingAsm.Location) {
        $roundedRefAssemblies += $drawingAsm.Location
    }
}
catch {}

try {
    Add-Type -TypeDefinition @"
using System;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public static class RoundedButton {
    [DllImport("gdi32.dll")]
    public static extern IntPtr CreateRoundRectRgn(int nLeftRect, int nTopRect, int nRightRect, int nBottomRect, int nWidthEllipse, int nHeightEllipse);
    
    [DllImport("gdi32.dll")]
    public static extern bool DeleteObject(IntPtr hObject);
    
    public static void MakeRounded(Control control, int radius = 15) {
        try {
            IntPtr ptr = CreateRoundRectRgn(0, 0, control.Width, control.Height, radius, radius);
            if (ptr != IntPtr.Zero) {
                control.Region = Region.FromHrgn(ptr);
                DeleteObject(ptr);
            }
        }
        catch { }
    }
}
"@ -ReferencedAssemblies $roundedRefAssemblies
    $script:RoundedButtonHelperAvailable = $true
}
catch {
    try { Log ("RoundedButton helper disabled: {0}" -f $_.Exception.Message) } catch {}
    $script:RoundedButtonHelperAvailable = $false
}

# WM_SETREDRAW helper — suspends/resumes drawing on a control to batch visual updates without flicker
$script:_winMsgAvail = $false
try {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class WinMsg {
    [DllImport("user32.dll")]
    private static extern bool SendMessage(IntPtr hWnd, int msg, IntPtr wParam, IntPtr lParam);
    public static void SuspendDraw(IntPtr hwnd) {
        try { SendMessage(hwnd, 11, IntPtr.Zero, IntPtr.Zero); } catch { }
    }
    public static void ResumeDraw(IntPtr hwnd) {
        try { SendMessage(hwnd, 11, new IntPtr(1), IntPtr.Zero); } catch { }
    }
}
"@ -ReferencedAssemblies "System.Runtime.InteropServices.dll"
    $script:_winMsgAvail = $true
}
catch {
    $script:_winMsgAvail = $false
}

# ── PSw34: Zoom window finder + positioning (used by Toggle Zoom button) ─────
$script:PSw34Loaded = $false
$script:PSw34Error = $null
try {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class PSw34 {
    public const int SW_RESTORE  = 9;
    public const int SW_MINIMIZE = 6;
    public const int SW_SHOW     = 5;
    public const int SW_HIDE     = 0;
    public const uint SWP_NOSIZE         = 0x0001;
    public const uint SWP_NOMOVE         = 0x0002;
    public const uint SWP_NOACTIVATE     = 0x0010;
    public const uint SWP_SHOWWINDOW     = 0x0040;
    public const uint SWP_NOCOPYBITS    = 0x0100;
    public const uint SWP_NOSENDCHANGING = 0x0400;
    public const uint SWP_NOOWNERZORDER  = 0x0200;
    public static readonly IntPtr HWND_TOPMOST   = new IntPtr(-1);
    public static readonly IntPtr HWND_NOTOPMOST = new IntPtr(-2);
    public const uint LWA_ALPHA     = 0x00000002;
    public const uint WS_EX_LAYERED = 0x00080000;
    public const int  GWL_EXSTYLE   = -20;
    public const uint DWMWA_TRANSITIONS_FORCEDISABLED = 3;
    public const uint DWMWA_CLOAK                     = 13;
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }
    public delegate bool EnumWndProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hAfter, int X, int Y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT r);
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr hWnd, out RECT r);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool ShowWindowAsync(IntPtr hWnd, int cmd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int cmd);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern uint  GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
    [DllImport("kernel32.dll")] public static extern uint  GetCurrentThreadId();
    [DllImport("user32.dll")] public static extern bool  AttachThreadInput(uint a, uint b, bool attach);
    [DllImport("user32.dll")] public static extern bool  BringWindowToTop(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool  SetLayeredWindowAttributes(IntPtr hw, uint crKey, byte bAlpha, uint dwFlags);
    [DllImport("user32.dll")] public static extern IntPtr SetWindowLongPtr(IntPtr hw, int idx, IntPtr val);
    [DllImport("user32.dll")] public static extern IntPtr GetWindowLongPtr(IntPtr hw, int idx);
    [DllImport("user32.dll")] public static extern bool  RedrawWindow(IntPtr hWnd, IntPtr r, IntPtr rgn, uint flags);
    [DllImport("dwmapi.dll")]  public static extern int   DwmSetWindowAttribute(IntPtr hw, uint attr, ref int pv, int cb);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWndProc cb, IntPtr lParam);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr hWnd, StringBuilder sb, int n);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr hWnd, StringBuilder sb, int n);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr hWnd, EnumWndProc cb, IntPtr lParam);
    public static bool EqualRect(RECT a, RECT b) {
        return a.Left==b.Left && a.Top==b.Top && a.Right==b.Right && a.Bottom==b.Bottom;
    }
    public static IntPtr FindZoomMediaWindow() {
        var candidates = new System.Collections.Generic.List<System.Tuple<IntPtr,int>>();
        EnumWindows(delegate(IntPtr hWnd, IntPtr lp) {
            if (!IsWindowVisible(hWnd)) return true;
            var cls = new StringBuilder(256);
            GetClassName(hWnd, cls, 256);
            if (cls.ToString() != "ConfMultiTabContentWndClass") return true;
            var title = new StringBuilder(256);
            GetWindowText(hWnd, title, 256);
            if (!title.ToString().Contains("Zoom Meeting")) return true;
            int kids = 0;
            EnumChildWindows(hWnd, delegate(IntPtr ch, IntPtr lp2) { kids++; return true; }, IntPtr.Zero);
            candidates.Add(System.Tuple.Create(hWnd, kids));
            return true;
        }, IntPtr.Zero);
        if (candidates.Count == 0) return IntPtr.Zero;
        candidates.Sort((a, b) => a.Item2.CompareTo(b.Item2));
        return candidates[0].Item1;
    }
    public static IntPtr FindZoomMainWindow() {
        var candidates = new System.Collections.Generic.List<System.Tuple<IntPtr,int>>();
        EnumWindows(delegate(IntPtr hWnd, IntPtr lp) {
            if (!IsWindowVisible(hWnd)) return true;
            var cls = new StringBuilder(256);
            GetClassName(hWnd, cls, 256);
            if (cls.ToString() != "ConfMultiTabContentWndClass") return true;
            var title = new StringBuilder(256);
            GetWindowText(hWnd, title, 256);
            if (!title.ToString().Contains("Zoom Meeting")) return true;
            int kids = 0;
            EnumChildWindows(hWnd, delegate(IntPtr ch, IntPtr lp2) { kids++; return true; }, IntPtr.Zero);
            candidates.Add(System.Tuple.Create(hWnd, kids));
            return true;
        }, IntPtr.Zero);
        if (candidates.Count == 0) return IntPtr.Zero;
        candidates.Sort((a, b) => b.Item2.CompareTo(a.Item2));
        return candidates[0].Item1;
    }
    public static void ForceSetForeground(IntPtr hwnd) {
        IntPtr fg = GetForegroundWindow();
        uint me = GetCurrentThreadId();
        uint fgT=0, tgt=0;
        if (fg != IntPtr.Zero) { uint _d; GetWindowThreadProcessId(fg, out _d); fgT = _d; }
        GetWindowThreadProcessId(hwnd, out tgt);
        if (fgT!=0 && fgT!=me) AttachThreadInput(me, fgT, true);
        if (tgt!=0 && tgt!=me) AttachThreadInput(me, tgt, true);
        BringWindowToTop(hwnd);
        SetForegroundWindow(hwnd);
        SetWindowPos(hwnd, HWND_TOPMOST, 0,0,0,0, SWP_NOMOVE|SWP_NOSIZE|SWP_NOOWNERZORDER|SWP_NOSENDCHANGING);
        if (fgT!=0 && fgT!=me) AttachThreadInput(me, fgT, false);
        if (tgt!=0 && tgt!=me) AttachThreadInput(me, tgt, false);
    }
}
'@ -ErrorAction Stop
}
catch { $script:PSw34Error = $_ }
# Always verify by actually accessing the type (works whether Add-Type just ran or type was already defined)
try { [void][PSw34]; $script:PSw34Loaded = $true } catch {}

# ── Projector-Switch state vars ───────────────────────────────────────────────
$script:PS_origRect = $null
$script:PS_wasMin = $false
$script:PS_projected = $false
$script:PS_jwlToggleEl = $null
$script:PS_settingsOpenedByUs = $false
$script:PS_tabNavigatedFrom = $null

# ── Projector-Switch helper functions ─────────────────────────────────────────
function PS-GetTargetRect([IntPtr]$hw, [System.Windows.Forms.Screen]$scr) {
    $m = [PSw34+RECT]@{ Left = $scr.Bounds.Left; Top = $scr.Bounds.Top; Right = $scr.Bounds.Right; Bottom = $scr.Bounds.Bottom }
    $cr = New-Object PSw34+RECT; $wr = New-Object PSw34+RECT
    [PSw34]::GetClientRect($hw, [ref]$cr) | Out-Null
    [PSw34]::GetWindowRect($hw, [ref]$wr) | Out-Null
    $xB = [int](($wr.Right - $wr.Left - ($cr.Right - $cr.Left)) / 2)
    $yB = [int](($wr.Bottom - $wr.Top - ($cr.Bottom - $cr.Top)) / 2)
    return [PSw34+RECT]@{ Left = $m.Left - $xB; Top = $m.Top - $yB; Right = $m.Right + $xB * 2; Bottom = $m.Bottom + $yB * 2 }
}
function PS-ShowZoomOnMonitor([IntPtr]$hw, [PSw34+RECT]$tr) {
    $w = $tr.Right - $tr.Left; $h = $tr.Bottom - $tr.Top
    $v = 1; [PSw34]::DwmSetWindowAttribute($hw, [PSw34]::DWMWA_TRANSITIONS_FORCEDISABLED, [ref]$v, 4) | Out-Null
    if ([PSw34]::IsIconic($hw)) {
        [PSw34]::ShowWindowAsync($hw, [PSw34]::SW_RESTORE) | Out-Null
        $t = 0; while ([PSw34]::IsIconic($hw) -and $t -lt 500) { Start-Sleep -Milliseconds 10; $t += 10 }
    }
    $v = 1; [PSw34]::DwmSetWindowAttribute($hw, [PSw34]::DWMWA_CLOAK, [ref]$v, 4) | Out-Null
    [PSw34]::SetWindowPos($hw, [PSw34]::HWND_TOPMOST, $tr.Left, $tr.Top, $w, $h,
        ([PSw34]::SWP_NOCOPYBITS -bor [PSw34]::SWP_NOSENDCHANGING -bor [PSw34]::SWP_NOACTIVATE)) | Out-Null
    $exStyle = [PSw34]::GetWindowLongPtr($hw, [PSw34]::GWL_EXSTYLE).ToInt64()
    $hadLayered = ($exStyle -band [PSw34]::WS_EX_LAYERED) -ne 0
    if (-not $hadLayered) { [PSw34]::SetWindowLongPtr($hw, [PSw34]::GWL_EXSTYLE, [IntPtr]($exStyle -bor [PSw34]::WS_EX_LAYERED)) | Out-Null }
    [PSw34]::SetLayeredWindowAttributes($hw, 0, 0, [PSw34]::LWA_ALPHA) | Out-Null
    $v = 0; [PSw34]::DwmSetWindowAttribute($hw, [PSw34]::DWMWA_CLOAK, [ref]$v, 4) | Out-Null
    [PSw34]::ShowWindow($hw, [PSw34]::SW_SHOW) | Out-Null
    [PSw34]::ForceSetForeground($hw)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    do {
        $alpha = [byte][Math]::Min(255, [long](($sw.ElapsedMilliseconds * 255) / 300))
        [PSw34]::SetLayeredWindowAttributes($hw, 0, $alpha, [PSw34]::LWA_ALPHA) | Out-Null
        if ($alpha -lt 255) { Start-Sleep -Milliseconds 10 }
    } while ($alpha -lt 255)
    if (-not $hadLayered) {
        [PSw34]::SetLayeredWindowAttributes($hw, 0, 255, [PSw34]::LWA_ALPHA) | Out-Null
        [PSw34]::SetWindowLongPtr($hw, [PSw34]::GWL_EXSTYLE, [IntPtr]$exStyle) | Out-Null
    }
    [PSw34]::RedrawWindow($hw, [IntPtr]::Zero, [IntPtr]::Zero, 0x0185) | Out-Null
    $v = 0; [PSw34]::DwmSetWindowAttribute($hw, [PSw34]::DWMWA_TRANSITIONS_FORCEDISABLED, [ref]$v, 4) | Out-Null
}
function PS-HideZoomFromMonitor([IntPtr]$hw) {
    if ($script:PS_wasMin) {
        $p = [System.Windows.Forms.Screen]::PrimaryScreen
        [PSw34]::SetWindowPos($hw, [PSw34]::HWND_NOTOPMOST, $p.Bounds.Left + 10, $p.Bounds.Top + 10, 450, 300,
            ([PSw34]::SWP_NOCOPYBITS -bor [PSw34]::SWP_NOSENDCHANGING)) | Out-Null
        [PSw34]::ShowWindowAsync($hw, [PSw34]::SW_MINIMIZE) | Out-Null
        $script:PS_wasMin = $false
    }
    else {
        $r = if ($script:PS_origRect) { $script:PS_origRect } else {
            $p = [System.Windows.Forms.Screen]::PrimaryScreen
            [PSw34+RECT]@{ Left = $p.Bounds.Left + 10; Top = $p.Bounds.Top + 10; Right = $p.Bounds.Left + 460; Bottom = $p.Bounds.Top + 310 }
        }
        [PSw34]::SetWindowPos($hw, [IntPtr]1, $r.Left, $r.Top, ($r.Right - $r.Left), ($r.Bottom - $r.Top),
            ([PSw34]::SWP_NOCOPYBITS -bor [PSw34]::SWP_NOSENDCHANGING -bor [PSw34]::SWP_SHOWWINDOW)) | Out-Null
    }
    $mainHw = [PSw34]::FindZoomMainWindow()
    if ($mainHw -ne [IntPtr]::Zero) {
        [PSw34]::SetWindowPos($mainHw, [PSw34]::HWND_NOTOPMOST, 0, 0, 0, 0,
            ([PSw34]::SWP_NOMOVE -bor [PSw34]::SWP_NOSIZE -bor [PSw34]::SWP_SHOWWINDOW)) | Out-Null
        [PSw34]::SetForegroundWindow($mainHw) | Out-Null
    }
}
function PS-GetScreen {
    $idx = 0
    if ($script:Cfg.Zoom.Contains('ZoomProjectorMonitor')) { $idx = [int]$script:Cfg.Zoom.ZoomProjectorMonitor }
    $screens = [System.Windows.Forms.Screen]::AllScreens | Sort-Object { if ($_.Primary) { 1 } else { 0 } }
    if ($idx -ge 0 -and $idx -lt $screens.Count) { return $screens[$idx] }
    return $screens[0]
}
function PS-JwlGetSecondDisplayToggle {
    # Reuse the existing JWL functions already present in this script
    return Get-JwlSecondDisplayToggle
}
function PS-PhaseOff {
    $el = Get-JwlSecondDisplayToggle
    $script:PS_jwlToggleEl = $null
    if (-not $el) { return $false }
    try {
        $tp = $el.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)
        if ($tp.Current.ToggleState -ne [System.Windows.Automation.ToggleState]::On) {
            $script:PS_jwlToggleEl = $el; return $true
        }
        $tp.Toggle()
        $script:PS_jwlToggleEl = $el
        return $true
    }
    catch { Close-JwlSettingsIfWeOpened; return $false }
}
function PS-PhaseOn {
    $el = $script:PS_jwlToggleEl
    if (-not $el) { $el = Find-JwlToggleFromRoot }
    if ($el) {
        try {
            $tp = $el.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)
            if ($tp.Current.ToggleState -ne [System.Windows.Automation.ToggleState]::On) { $tp.Toggle() }
            Start-Sleep -Milliseconds 100
        }
        catch {
            $el2 = Find-JwlToggleFromRoot
            if ($el2) {
                try {
                    $tp2 = $el2.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)
                    if ($tp2.Current.ToggleState -ne [System.Windows.Automation.ToggleState]::On) { $tp2.Toggle() }
                    Start-Sleep -Milliseconds 100
                }
                catch {}
            }
        }
    }
    Close-JwlSettingsIfWeOpened
    $script:PS_jwlToggleEl = $null
}

# Enables flicker-free owner-draw double buffering on a Panel via reflection
function Enable-OwnerDrawDoubleBuffer($ctrl) {
    try {
        $setStyle = [System.Windows.Forms.Control].GetMethod('SetStyle', [System.Reflection.BindingFlags]'NonPublic,Instance')
        $styles = [System.Windows.Forms.ControlStyles]'UserPaint,OptimizedDoubleBuffer,AllPaintingInWmPaint'
        $setStyle.Invoke($ctrl, @($styles, $true))
    }
    catch {}
}

# Function to apply rounded corners to a button
function Set-RoundedCorners($button, $radius = 15) {
    if (-not $script:RoundedButtonHelperAvailable) { return }
    try {
        [RoundedButton]::MakeRounded($button, $radius)
        # Track for explicit re-apply after Apply-UIScale (closure-based Resize is unreliable)
        $entry = [PSCustomObject]@{ Control = $button; Radius = $radius }
        [void]$script:_roundedControls.Add($entry)
        # Re-apply on resize (belt-and-suspenders)
        $r = $radius
        $button.Add_Resize({
                try { [RoundedButton]::MakeRounded($this, $r) } catch {}
            }.GetNewClosure())
    }
    catch {}
}

# Draws a mini clapperboard icon using GDI+ in lavender/white/black.
function New-ClapperboardBitmap {
    $sz = 30  # slightly taller to fit raised arm
    $bmp = New-Object System.Drawing.Bitmap($sz, $sz, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)

    # -- Slate body (lavender/purple) -- sits in lower portion
    $bodyRect = [System.Drawing.RectangleF]::new(2, 13, $sz - 4, $sz - 15)
    $bodyBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(150, 105, 200))
    $g.FillRectangle($bodyBrush, $bodyRect)
    $linePen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(180, 255, 255, 255), 1)
    $g.DrawLine($linePen, 4.0, 18.0, [float]($sz - 4), 18.0)
    $g.DrawLine($linePen, 4.0, 22.0, [float]($sz - 4), 22.0)
    $slatePen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(80, 45, 130), 1.5)
    $g.DrawRectangle($slatePen, $bodyRect.X, $bodyRect.Y, $bodyRect.Width, $bodyRect.Height)

    # -- Hinge pin on left edge of body top --
    $hingeX = 4.0; $hingeY = 13.0
    $hingeBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(210, 210, 220))
    $g.FillEllipse($hingeBrush, $hingeX - 2, $hingeY - 2, 5.0, 5.0)

    # -- Raised clapper arm: pivots from hinge, angled ~35 degrees up-right --
    # The arm is a parallelogram. Pivot bottom-left = hinge point.
    # armLen = width of body; armH = 6px thick
    $armLen = [float]($sz - 6)
    $armH = 6.0
    $angle = 35.0 * [math]::PI / 180.0   # 35 degrees
    $cosA = [float][math]::Cos($angle)
    $sinA = [float][math]::Sin($angle)
    # Four corners of the arm in local coords (pivot at origin), then translate to hinge
    $px = $hingeX; $py = $hingeY
    # bottom-left, bottom-right, top-right, top-left
    $armPts = [System.Drawing.PointF[]]@(
        [System.Drawing.PointF]::new($px, $py),
        [System.Drawing.PointF]::new($px + $armLen * $cosA, $py - $armLen * $sinA),
        [System.Drawing.PointF]::new($px + $armLen * $cosA - $armH * $sinA, $py - $armLen * $sinA - $armH * $cosA),
        [System.Drawing.PointF]::new($px - $armH * $sinA, $py - $armH * $cosA)
    )
    # Clip to arm parallelogram for stripes
    $armPath = New-Object System.Drawing.Drawing2D.GraphicsPath
    $armPath.AddPolygon($armPts)
    $g.SetClip($armPath)
    $whiteBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)
    $g.FillPolygon($whiteBrush, $armPts)
    # Black diagonal stripes along the arm
    $blackBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::Black)
    for ($i = -2; $i -lt 8; $i++) {
        $ox = $i * 7.0
        $sp = [System.Drawing.PointF[]]@(
            [System.Drawing.PointF]::new($px + $ox * $cosA, $py - $ox * $sinA),
            [System.Drawing.PointF]::new($px + ($ox + 4) * $cosA, $py - ($ox + 4) * $sinA),
            [System.Drawing.PointF]::new($px + ($ox + 4) * $cosA - $armH * $sinA, $py - ($ox + 4) * $sinA - $armH * $cosA),
            [System.Drawing.PointF]::new($px + $ox * $cosA - $armH * $sinA, $py - $ox * $sinA - $armH * $cosA)
        )
        $g.FillPolygon($blackBrush, $sp)
    }
    $g.ResetClip()
    # Arm outline
    $armPen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(40, 40, 40), 1.2)
    $g.DrawPolygon($armPen, $armPts)

    $g.Dispose()
    foreach ($d in @($bodyBrush, $linePen, $slatePen, $hingeBrush, $armPath, $whiteBrush, $blackBrush, $armPen)) { try { $d.Dispose() }catch {} }
    return $bmp
}

# Draws a red record-dot icon using GDI+.
function New-RecordDotBitmap {
    $sz = 22
    $bmp = New-Object System.Drawing.Bitmap($sz, $sz, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)
    $br = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(230, 55, 55))
    $g.FillEllipse($br, 2, 2, $sz - 4, $sz - 4)
    $br.Dispose(); $g.Dispose()
    return $bmp
}

# Draws a color TV/monitor icon using GDI+.
function New-TvMonitorBitmap {
    $sz = 26
    $bmp = New-Object System.Drawing.Bitmap($sz, $sz, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)
    # Monitor bezel (dark gray)
    $bezelBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(80, 82, 90))
    $g.FillRectangle($bezelBrush, 0.0, 0.0, 24.0, 18.0)
    # Screen (blue)
    $screenBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(30, 130, 220))
    $g.FillRectangle($screenBrush, 2.0, 2.0, 20.0, 13.0)
    # Screen shine (top-left highlight)
    $shineBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(70, 255, 255, 255))
    $g.FillRectangle($shineBrush, 2.0, 2.0, 9.0, 4.0)
    # Stand neck
    $standBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(100, 102, 110))
    $g.FillRectangle($standBrush, 10.0, 18.0, 4.0, 3.0)
    # Base
    $g.FillRectangle($standBrush, 5.0, 21.0, 14.0, 3.0)
    # Bezel outline
    $outlinePen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(50, 52, 60), 1.0)
    $g.DrawRectangle($outlinePen, 0.0, 0.0, 23.0, 17.0)
    $g.Dispose()
    foreach ($d in @($bezelBrush, $screenBrush, $shineBrush, $standBrush, $outlinePen)) { try { $d.Dispose() } catch {} }
    return $bmp
}

# DWM P/Invoke (PS 5.1-safe) — members only, fully-qualified types
if (-not ('Win32.Dwm' -as [type])) {
    try {
        Add-Type -Namespace Win32 -Name Dwm -MemberDefinition @"
[System.Runtime.InteropServices.DllImport("dwmapi.dll", PreserveSig=true)]
public static extern int DwmSetWindowAttribute(
    System.IntPtr hwnd, int attr, ref int attrValue, int attrSize);
"@
    }
    catch { $script:__NoDwm = $true }
}

# Basic Win32 helper (SetForegroundWindow) for focusing Zoom before sending hotkeys
if (-not ('Win32' -as [type])) {
    try {
        Add-Type @"
using System;
using System.Runtime.InteropServices;

public static class Win32 {
    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    // Simple mouse click helper for UI Automation fallbacks
    public const uint MOUSEEVENTF_LEFTDOWN = 0x0002;
    public const uint MOUSEEVENTF_LEFTUP   = 0x0004;

    [DllImport("user32.dll")]
    public static extern void mouse_event(uint dwFlags, uint dx, uint dy, uint dwData, UIntPtr dwExtraInfo);

    // Window style helpers for click-through overlays
    public const int GWL_EXSTYLE = -20;
    public const int WS_EX_TRANSPARENT = 0x00000020;
    public const int WS_EX_LAYERED = 0x00080000;

    [DllImport("user32.dll", SetLastError = true)]
    public static extern int GetWindowLong(IntPtr hWnd, int nIndex);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);
}
"@
    }
    catch {
        # Logging not yet initialized here; fall back to console output
        Write-Host "Win32 SetForegroundWindow helper not available: $_" -ForegroundColor Yellow
    }
}

# ── Win32JWL helpers — mouse, keyboard and window focus for JWL second display control ──
if (-not ('Win32JWL' -as [type])) {
    try {
        Add-Type @"
using System;
using System.Runtime.InteropServices;
public class Win32JWL {
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);
    [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr hWnd, System.Text.StringBuilder text, int count);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);
    [DllImport("user32.dll")] public static extern void SwitchToThisWindow(IntPtr hWnd, bool fAltTab);
    [DllImport("user32.dll")] public static extern IntPtr SetFocus(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool AllowSetForegroundWindow(uint dwProcessId);
    [DllImport("user32.dll")] public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, IntPtr dwExtraInfo);
    [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT pt);
    [DllImport("user32.dll")] public static extern bool ScreenToClient(IntPtr hWnd, ref POINT pt);
    [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT pt);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int X, int Y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint dwFlags, int dx, int dy, uint dwData, IntPtr dwExtraInfo);
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
    public struct RECT { public int Left, Top, Right, Bottom; }
    public struct POINT { public int X, Y; }
    // Click at screen coordinates WITHOUT moving the physical cursor.
    // WindowFromPoint finds the exact child HWND (incl. WebView2 surfaces);
    // PostMessage delivers WM_LBUTTONDOWN/UP directly to its message queue.
    public static void PostClickAtPoint(int screenX, int screenY) {
        POINT pt = new POINT { X = screenX, Y = screenY };
        IntPtr target = WindowFromPoint(pt);
        if (target == IntPtr.Zero) return;
        POINT cl = new POINT { X = screenX, Y = screenY };
        ScreenToClient(target, ref cl);
        IntPtr lParam = new IntPtr((cl.Y << 16) | (cl.X & 0xFFFF));
        PostMessage(target, 0x0201, IntPtr.Zero, lParam); // WM_LBUTTONDOWN
        PostMessage(target, 0x0202, IntPtr.Zero, lParam); // WM_LBUTTONUP
    }
    // Click using real synthesized input, then restore cursor to its original position.
    // Required for WinAppSDK/XAML controls that ignore PostMessage (e.g. JWL nav tabs).
    public static void ClickAtAndRestore(int screenX, int screenY) {
        POINT saved;
        GetCursorPos(out saved);
        SetCursorPos(screenX, screenY);
        mouse_event(0x0002, 0, 0, 0, IntPtr.Zero); // MOUSEEVENTF_LEFTDOWN
        mouse_event(0x0004, 0, 0, 0, IntPtr.Zero); // MOUSEEVENTF_LEFTUP
        SetCursorPos(saved.X, saved.Y);
    }
    public static void ForceSetForeground(IntPtr hWnd) {
        uint dummy;
        IntPtr fg = GetForegroundWindow();
        uint fgThread     = GetWindowThreadProcessId(fg,   out dummy);
        uint myThread     = GetCurrentThreadId();
        uint targetThread = GetWindowThreadProcessId(hWnd, out dummy);
        if (fgThread     != myThread) AttachThreadInput(fgThread,     myThread, true);
        if (targetThread != myThread) AttachThreadInput(targetThread, myThread, true);
        BringWindowToTop(hWnd); ShowWindow(hWnd, 9); SetForegroundWindow(hWnd); SetFocus(hWnd);
        SetWindowPos(hWnd, new IntPtr(-1), 0, 0, 0, 0, 0x0043);
        SetWindowPos(hWnd, new IntPtr(-2), 0, 0, 0, 0, 0x0043);
        if (fgThread     != myThread) AttachThreadInput(fgThread,     myThread, false);
        if (targetThread != myThread) AttachThreadInput(targetThread, myThread, false);
    }
}
"@
    }
    catch { Write-Host "Win32JWL not available: $_" -ForegroundColor Yellow }
}

# ── JWL Second Display — state variables ──────────────────────────────────
$script:jwlOutOn = $null   # $true=ON  $false=OFF  $null=unknown
$script:settingsOpenedByUs = $false
$script:tabNavigatedFrom = $null
$script:JwlMediaFixActive = $false  # True when JwlMediaWin process is detected running

function Test-JwlMediaFix {
    # Returns $true if JWL Media Fix (JwlMediaWin) is running in the background
    $p = Get-Process 'JwlMediaWin' -ErrorAction SilentlyContinue
    $script:JwlMediaFixActive = ($null -ne $p)
    return $script:JwlMediaFixActive
}

# ── JWL Second Display — UIA helper functions ─────────────────────────────

function Get-JwlMainWindow {
    $root = [System.Windows.Automation.AutomationElement]::RootElement
    $cond = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::NameProperty, "JW Library")
    $jwl = $root.FindFirst([System.Windows.Automation.TreeScope]::Children, $cond)
    if (-not $jwl) {
        $all = $root.FindAll([System.Windows.Automation.TreeScope]::Children,
            [System.Windows.Automation.Condition]::TrueCondition)
        foreach ($w in $all) {
            try { if ($w.Current.Name -like "*JW Library*") { $jwl = $w; break } } catch {}
        }
    }
    return $jwl
}

function Find-JwlToggleByName {
    param([System.Windows.Automation.AutomationElement]$parent, [string]$name)
    $cond = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::NameProperty, $name)
    return $parent.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $cond)
}

function Invoke-JwlUiaElement {
    param([System.Windows.Automation.AutomationElement]$el)
    if (-not $el) { return $false }
    try { $ip = $el.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern); $ip.Invoke(); return $true } catch {}
    try { $tp = $el.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern); $tp.Toggle(); return $true } catch {}
    try {
        $r = $el.Current.BoundingRectangle
        if (-not $r.IsEmpty) { [Win32JWL]::ClickAtAndRestore([int]($r.X + $r.Width / 2), [int]($r.Y + $r.Height / 2)); return $true }
    }
    catch {}
    return $false
}

function Find-JwlToggleFromRoot {
    param([int]$processId = 0)
    $root = [System.Windows.Automation.AutomationElement]::RootElement
    $nameCond = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::NameProperty, "Play video on second display")
    if ($processId -gt 0) {
        $pidCond = New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::ProcessIdProperty, $processId)
        $wins = $root.FindAll([System.Windows.Automation.TreeScope]::Children, $pidCond)
        foreach ($w in $wins) {
            $el = $w.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $nameCond)
            if ($el) { return $el }
        }
        return $null
    }
    return $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $nameCond)
}

function Wait-ForJwlToggle {
    param([int]$timeoutMs = 3000, [int]$processId = 0)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $timeoutMs) {
        $el = Find-JwlToggleFromRoot -processId $processId
        if ($el) { return $el }
        Start-Sleep -Milliseconds 100
    }
    return $null
}

function Get-JwlActiveTab {
    param([System.Windows.Automation.AutomationElement]$jwl)
    $tabs = $jwl.FindAll(
        [System.Windows.Automation.TreeScope]::Descendants,
        (New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
            [System.Windows.Automation.ControlType]::ListItem)))
    foreach ($t in $tabs) {
        try {
            $sp = $t.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)
            if ($sp.Current.IsSelected) { return $t.Current.Name }
        }
        catch {}
    }
    return $null
}

function Click-JwlNavTab {
    param([System.Windows.Automation.AutomationElement]$jwl, [string]$tabName)
    $tab = Find-JwlToggleByName $jwl $tabName
    if (-not $tab) { return $false }
    try {
        $r = $tab.Current.BoundingRectangle
        if (-not $r.IsEmpty) {
            # JWL WinAppSDK tabs ignore PostMessage — use real input but restore cursor immediately
            [Win32JWL]::ClickAtAndRestore([int]($r.X + $r.Width / 2), [int]($r.Y + $r.Height / 2))
            Start-Sleep -Milliseconds 200
            return $true
        }
    }
    catch {}
    return $false
}

function Get-JwlSecondDisplayToggle {
    $jwl = Get-JwlMainWindow
    if (-not $jwl) { $script:settingsOpenedByUs = $false; $script:tabNavigatedFrom = $null; return $null }
    $jwlPid = $jwl.Current.ProcessId
    # Settings already open?
    $el = Find-JwlToggleFromRoot -processId $jwlPid
    if ($el) { $script:settingsOpenedByUs = $false; $script:tabNavigatedFrom = $null; return $el }
    # Navigate to Home first so Settings button is visible
    $script:tabNavigatedFrom = Get-JwlActiveTab $jwl
    $homeTab = Find-JwlToggleByName $jwl "Home"
    if ($homeTab) { Invoke-JwlUiaElement $homeTab | Out-Null; Start-Sleep -Milliseconds 150; $jwl = Get-JwlMainWindow }
    # Find Settings button scoped to JWL process only
    $root = [System.Windows.Automation.AutomationElement]::RootElement
    $pidCond = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ProcessIdProperty, $jwlPid)
    $andCond = New-Object System.Windows.Automation.AndCondition(
        (New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::NameProperty, "Settings")),
        (New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
            [System.Windows.Automation.ControlType]::Button)))
    $nameCond2 = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::NameProperty, "Settings")
    $jwlWins = $root.FindAll([System.Windows.Automation.TreeScope]::Children, $pidCond)
    $settingsBtn = $null
    foreach ($w in $jwlWins) {
        $b = $w.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $andCond)
        if ($b) { $settingsBtn = $b; break }
    }
    if (-not $settingsBtn) {
        foreach ($w in $jwlWins) {
            $b = $w.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $nameCond2)
            if ($b) { $settingsBtn = $b; break }
        }
    }
    if ($settingsBtn) {
        Invoke-JwlUiaElement $settingsBtn | Out-Null
        $el = Wait-ForJwlToggle 2000 -processId $jwlPid
        if ($el) { $script:settingsOpenedByUs = $true; return $el }
    }
    # Fallback: click settings gear at the bottom of JWL sidebar (WebView — not in UIA tree)
    $jwl = Get-JwlMainWindow
    if ($jwl) {
        $wr = $jwl.Current.BoundingRectangle
        $sx = [int]($wr.Left + 32)
        foreach ($offset in @(40, 60, 80, 55, 45, 100, 120)) {
            [Win32JWL]::ClickAtAndRestore($sx, [int]($wr.Bottom - $offset))
            $el = Wait-ForJwlToggle 1500 -processId $jwlPid
            if ($el) { $script:settingsOpenedByUs = $true; return $el }
        }
    }
    return $null
}

function Close-JwlSettingsIfWeOpened {
    if (-not $script:settingsOpenedByUs) {
        if ($script:tabNavigatedFrom -and $script:tabNavigatedFrom -ne "Home") {
            $jwl = Get-JwlMainWindow
            if ($jwl) { Click-JwlNavTab $jwl $script:tabNavigatedFrom | Out-Null }
            $script:tabNavigatedFrom = $null
        }
        return
    }
    $jwl = Get-JwlMainWindow
    if ($jwl) {
        $root = [System.Windows.Automation.AutomationElement]::RootElement
        $pc = New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::ProcessIdProperty, $jwl.Current.ProcessId)
        $cc = New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::NameProperty, "Close")
        foreach ($w in $root.FindAll([System.Windows.Automation.TreeScope]::Children, $pc)) {
            $b = $w.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $cc)
            if ($b) {
                try { $ip = $b.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern); $ip.Invoke(); break } catch {}
            }
        }
        Start-Sleep -Milliseconds 150
    }
    $script:settingsOpenedByUs = $false
    if ($script:tabNavigatedFrom -and $script:tabNavigatedFrom -ne "Home") {
        $jwl2 = Get-JwlMainWindow
        if ($jwl2) { Click-JwlNavTab $jwl2 $script:tabNavigatedFrom | Out-Null }
        $script:tabNavigatedFrom = $null
    }
}

function Get-JwlToggleState {
    param([System.Windows.Automation.AutomationElement]$el)
    try {
        $tp = $el.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)
        return $tp.Current.ToggleState
    }
    catch { return $null }
}

function Invoke-JwlToggle {
    param([System.Windows.Automation.AutomationElement]$el)
    try { $tp = $el.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern); $tp.Toggle(); return $true } catch {}
    try { $ip = $el.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern); $ip.Invoke(); return $true } catch {}
    return $false
}

function Focus-JwlOutput {
    # Cycle second display OFF→ON to force JWL to recreate / re-render the output window
    $el = Get-JwlSecondDisplayToggle
    if (-not $el) { Log "[JWL] Could not find second-display toggle."; return $false }
    $state = Get-JwlToggleState $el
    $isOn = ($state -eq [System.Windows.Automation.ToggleState]::On)
    if (-not $isOn) {
        Invoke-JwlToggle $el | Out-Null
        Start-Sleep -Milliseconds 700
        Close-JwlSettingsIfWeOpened
        return $true
    }
    Invoke-JwlToggle $el | Out-Null
    Start-Sleep -Milliseconds 500
    $el2 = Wait-ForJwlToggle 3000
    if (-not $el2) { $el2 = Find-JwlToggleFromRoot }
    if ($el2) {
        $st2 = Get-JwlToggleState $el2
        if ($st2 -ne [System.Windows.Automation.ToggleState]::On) {
            Invoke-JwlToggle $el2 | Out-Null
            Start-Sleep -Milliseconds 800
        }
    }
    Close-JwlSettingsIfWeOpened
    return $true
}

function Update-JwlMonitorButton {
    # Updates button color to reflect second display state; call on UI thread
    try {
        $b = $script:btnJwlMonitor
        if (-not $b -or $b.IsDisposed) {
            # Fallback: search by name
            $b = $script:form.Controls['btnJwlMonitor']
        }
        if (-not $b) { return }
        if ($script:jwlOutOn -eq $true) {
            $b.BackColor = [Drawing.Color]::FromArgb(35, 100, 35)
            $b.FlatAppearance.BorderColor = [Drawing.Color]::FromArgb(80, 180, 80)
        }
        elseif ($script:jwlOutOn -eq $false) {
            $b.BackColor = [Drawing.Color]::FromArgb(110, 35, 35)
            $b.FlatAppearance.BorderColor = [Drawing.Color]::FromArgb(200, 70, 70)
        }
        else {
            $b.BackColor = [Drawing.Color]::FromArgb(60, 60, 60)
            $b.FlatAppearance.BorderColor = [Drawing.Color]::FromArgb(110, 110, 110)
        }
        $b.Invalidate()
    }
    catch {}
}

function Set-OcrHealth([bool]$working) {
    # Track consecutive structural OCR failures (ROI/Tesseract config broken).
    # $working=$true  → OCR pipeline functional (Tesseract ran to completion).
    # $working=$false → structural failure (ROI not set, bmp null, Tesseract missing).
    if ($working) {
        $script:_ocrBroken = $false
        $script:_ocrBrokenCount = 0
    }
    else {
        $script:_ocrBrokenCount++
        if ($script:_ocrBrokenCount -ge 5 -and $script:_ocrBroken -ne $true) {
            $script:_ocrBroken = $true
            # Option D: one-time session alert via ToolTip balloon near JWL button
            if (-not $script:_ocrBrokenAlerted) {
                $script:_ocrBrokenAlerted = $true
                Log '[JWL] OCR config alert: ROI or Tesseract not set correctly — check Settings.'
                try {
                    $script:_ocrAlertTip.ToolTipTitle = 'JWL OCR Problem'
                    $script:_ocrAlertTip.Show(
                        "OCR not working.`nROI or Tesseract path may be wrong.`nCheck Settings.",
                        $script:btnJwlMonitor, 0, -52, 7000)
                }
                catch {}
            }
        }
    }
    try { $script:btnJwlMonitor.Invalidate() } catch {}
}

function Update-JwlOcrTooltip {
    # Option B: show last OCR reading as hover tooltip on JWL button
    try {
        $txt = $script:_lastOcrText
        $kw = [string]$script:Cfg.Keyword
        $line1 = if ($null -eq $txt) { 'OCR: not yet run' }
        elseif ($txt -eq '') { 'OCR: (empty — ROI may be wrong or display off)' }
        else { 'OCR: "' + $txt.Substring(0, [math]::Min(60, $txt.Length)) + '"' }
        $line2 = if ($kw) { "Keyword: `"$kw`"" } else { 'Keyword: (not set)' }
        $script:_ocrAlertTip.SetToolTip($script:btnJwlMonitor, "$line1`n$line2")
    }
    catch {}
}

# ===== Theme kit (PS 5.1 safe) =====
$DarkTheme = @{
    Back     = [Drawing.Color]::FromArgb(0x12, 0x12, 0x12)
    Panel    = [Drawing.Color]::FromArgb(0x18, 0x18, 0x18)
    Control  = [Drawing.Color]::FromArgb(0x20, 0x20, 0x20)
    Border   = [Drawing.Color]::FromArgb(0x33, 0x33, 0x33)
    Text     = [Drawing.Color]::FromArgb(0xE6, 0xE6, 0xE6)
    TextDim  = [Drawing.Color]::FromArgb(0xB0, 0xB0, 0xB0)
    Accent   = [Drawing.Color]::FromArgb(0x72, 0x76, 0xFF)
    GridBack = [Drawing.Color]::FromArgb(0x16, 0x16, 0x16)
    GridAlt  = [Drawing.Color]::FromArgb(0x1C, 0x1C, 0x1C)
    GridLine = [Drawing.Color]::FromArgb(0x30, 0x30, 0x30)
    Link     = [Drawing.Color]::FromArgb(0x9D, 0x9C, 0xFF)
}
$LightTheme = @{
    Back     = [Drawing.SystemColors]::Control
    Panel    = [Drawing.SystemColors]::Control
    Control  = [Drawing.SystemColors]::Window
    Border   = [Drawing.SystemColors]::ActiveBorder
    Text     = [Drawing.SystemColors]::ControlText
    TextDim  = [Drawing.SystemColors]::GrayText
    Accent   = [Drawing.Color]::FromArgb(0x00, 0x78, 0xD7)
    GridBack = [Drawing.SystemColors]::Window
    GridAlt  = [Drawing.Color]::FromArgb(0xF7, 0xF7, 0xF7)
    GridLine = [Drawing.Color]::FromArgb(0xDD, 0xDD, 0xDD)
    Link     = [Drawing.Color]::Blue
}


function Set-DarkTitleBar([Windows.Forms.Form]$Form, [bool]$Enable) {
    try {
        if ($script:__NoDwm -or -not ('Win32.Dwm' -as [type])) { return }
        $v = if ($Enable) { 1 } else { 0 }
        [void][Win32.Dwm]::DwmSetWindowAttribute($Form.Handle, 20, [ref]$v, 4)
        [void][Win32.Dwm]::DwmSetWindowAttribute($Form.Handle, 19, [ref]$v, 4)


    }
    catch { $script:__NoDwm = $true }
}

function Set-ControlTheme([Windows.Forms.Control]$c, [hashtable]$theme, [bool]$dark) {
    if ($c -is [Windows.Forms.Form]) {
        $c.BackColor = $theme.Back; $c.ForeColor = $theme.Text
    }
    elseif ($c -is [Windows.Forms.Panel] -or $c -is [Windows.Forms.GroupBox] -or $c -is [Windows.Forms.TabPage]) {
        $c.BackColor = $theme.Panel; $c.ForeColor = $theme.Text
    }
    elseif ($c -is [Windows.Forms.Button]) {
        $c.FlatStyle = 'Flat'
        $c.FlatAppearance.BorderSize = 1
        $c.FlatAppearance.BorderColor = $theme.Border
        # Only paint if the button hasn't opted-out
        if ($c.UseVisualStyleBackColor) {
            $c.BackColor = $theme.Control
            $c.ForeColor = $theme.Text
        }
    }
    elseif ($c -is [Windows.Forms.Label]) {
        $c.ForeColor = $theme.Text; $c.BackColor = [Drawing.Color]::Transparent
    }
    elseif ($c -is [Windows.Forms.CheckBox] -or $c -is [Windows.Forms.RadioButton]) {
        $c.ForeColor = $theme.Text; $c.BackColor = $theme.Panel
    }
    elseif ($c -is [Windows.Forms.TextBox] -or $c -is [Windows.Forms.MaskedTextBox] -or $c -is [Windows.Forms.RichTextBox]) {
        $c.BackColor = $theme.Control; $c.ForeColor = $theme.Text; $c.BorderStyle = 'FixedSingle'
    }
    elseif ($c -is [Windows.Forms.ComboBox]) {
        $c.FlatStyle = 'Flat'; $c.BackColor = $theme.Control; $c.ForeColor = $theme.Text
    }
    elseif ($c -is [Windows.Forms.ListBox]) {
        $c.BackColor = $theme.Control; $c.ForeColor = $theme.Text; $c.BorderStyle = 'FixedSingle'
    }
    elseif ($c -is [Windows.Forms.TabControl]) {
        $c.BackColor = $theme.Panel; $c.ForeColor = $theme.Text
    }
    elseif ($c -is [Windows.Forms.DataGridView]) {
        $dgv = [Windows.Forms.DataGridView]$c; $dgv.EnableHeadersVisualStyles = $false
        $dgv.BackgroundColor = $theme.GridBack; $dgv.GridColor = $theme.GridLine
        $dgv.ColumnHeadersDefaultCellStyle.BackColor = $theme.Control; $dgv.ColumnHeadersDefaultCellStyle.ForeColor = $theme.Text
        $dgv.RowHeadersDefaultCellStyle.BackColor = $theme.Control; $dgv.RowHeadersDefaultCellStyle.ForeColor = $theme.Text
        $dgv.RowsDefaultCellStyle.BackColor = $theme.GridBack; $dgv.RowsDefaultCellStyle.ForeColor = $theme.Text
        $dgv.AlternatingRowsDefaultCellStyle.BackColor = $theme.GridAlt
        $dgv.DefaultCellStyle.SelectionBackColor = $theme.Accent; $dgv.DefaultCellStyle.SelectionForeColor = $theme.Control
    }
    elseif ($c -is [Windows.Forms.LinkLabel]) {
        $c.LinkColor = $theme.Link; $c.ActiveLinkColor = $theme.Accent; $c.VisitedLinkColor = $theme.Link
        $c.BackColor = [Drawing.Color]::Transparent; $c.ForeColor = $theme.Text
    }
    else {
        try { $c.BackColor = $theme.Control; $c.ForeColor = $theme.Text } catch {}
    }
}
function Apply-ThemeRecursive([Windows.Forms.Control]$root, [hashtable]$theme, [bool]$dark) {
    Set-ControlTheme $root $theme $dark
    foreach ($child in $root.Controls) { Apply-ThemeRecursive $child $theme $dark }
}
function Hook-ThemeForNewControls(
    [Windows.Forms.Control]$root,
    [hashtable]$theme,
    [bool]$dark,
    [int]$version
) {
    # Capture stable copies for the handler’s closure + version guard
    $t = $theme
    $d = [bool]$dark
    $v = [int]$version

    $root.add_ControlAdded({
            param($s, $e)
            try {
                # Only theme if this handler matches the current theme version
                if ($v -ne $script:ThemeVersion) { return }
                Apply-ThemeRecursive $e.Control $t $d
                Hook-ThemeForNewControls $e.Control $t $d $v
            }
            catch {}
        })

    foreach ($child in $root.Controls) {
        Hook-ThemeForNewControls $child $t $d $v
    }
}
# Monotonic theme version so old handlers no-op
if (-not (Get-Variable -Scope Script -Name ThemeVersion -ErrorAction SilentlyContinue)) {
    $script:ThemeVersion = 0
}

function Enable-DarkMode([Windows.Forms.Form]$Form, [bool]$Enable) {
    try {
        $script:ThemeVersion++
        $ver = [int]$script:ThemeVersion
        $theme = if ($Enable) { $DarkTheme } else { $LightTheme }

        # Apply to everything that exists now
        Apply-ThemeRecursive $Form $theme $Enable

        # Hook future controls, but only for this version
        Hook-ThemeForNewControls $Form $theme $Enable $ver

        # Dark title bar (supported on Win10+)
        Set-DarkTitleBar $Form $Enable
    }
    catch {}
}


# --------- logging (pipeline-safe) ----------
$script:LogBuffer = New-Object System.Collections.ArrayList
$script:sbLeft = $null
# Noise pattern: XR/OSC/meter messages suppressed unless XrDebugLog is enabled
$script:_xrNoiseRx = '(?i)(^OSC |^XR[: ]|^XR12|^Sent /|^Mixer Panel|^METER |^RAW#|/meters/|/xremote|keepalive|meter sub|blob|XR recv|OSC Fader|OSC Debug|Auto-scan|^Auto Mode: (Wave|Tick))'

function Log([string]$msg) {
    # Suppress verbose XR/OSC/meter noise unless debug logging is enabled
    if ($script:Cfg -and $script:Cfg.XR -and (-not $script:Cfg.XR.XrDebugLog)) {
        if ($msg -match $script:_xrNoiseRx) { return }
    }
    $stamp = (Get-Date).ToString("HH:mm:ss")
    $line = "[$stamp] $msg"

    try { [void]$script:LogBuffer.Add($line) } catch {}

    # Update status label if present
    try { if ($script:sbLeft -and -not $script:sbLeft.IsDisposed) { $script:sbLeft.Text = $msg } } catch {}

    # Write-Host -> swallow if pipeline is gone
    try {
        # Only write if runspace is really open
        if ($Host -and $Host.Runspace -and $Host.Runspace.RunspaceStateInfo.State -eq 'Opened') {
            Write-Host $line
        }
    }
    catch [System.Management.Automation.PipelineStoppedException] {
        # ignore — host pipeline was stopped
    }
    catch {
        # ignore any other host write issue
    }
}

function Convert-TagToVersion([string]$tag) {
    try {
        if ([string]::IsNullOrWhiteSpace($tag)) { return $null }
        $m = [regex]::Matches($tag, '\d+')
        if (-not $m -or $m.Count -eq 0) { return $null }
        $nums = @()
        foreach ($hit in $m) { $nums += [int]$hit.Value }
        while ($nums.Count -lt 4) { $nums += 0 }
        return [version]("{0}.{1}.{2}.{3}" -f $nums[0], $nums[1], $nums[2], $nums[3])
    }
    catch {
        return $null
    }
}

function Test-IsNewerTag([string]$currentTag, [string]$latestTag) {
    if ([string]::IsNullOrWhiteSpace($latestTag)) { return $false }
    if ($latestTag -eq $currentTag) { return $false }

    $curV = Convert-TagToVersion $currentTag
    $latV = Convert-TagToVersion $latestTag
    if ($curV -and $latV) {
        if ($latV -gt $curV) { return $true }
        if ($latV -lt $curV) { return $false }
    }

    # Same numeric base but different suffix/tag (e.g. b7 -> b8)
    return ($latestTag -ne $currentTag)
}

function Show-UpdateBalloon([string]$title, [string]$text) {
    try {
        if (-not $script:Cfg.Update.ShowWindowsNotification) { return }

        if (-not $script:UpdateNotifyIcon) {
            $ni = New-Object System.Windows.Forms.NotifyIcon
            $ni.Visible = $true
            try {
                $exe = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
                $ni.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon($exe)
            }
            catch {
                $ni.Icon = [System.Drawing.SystemIcons]::Information
            }
            $ni.Text = 'JWL+OBS Assistant'
            $ni.Add_BalloonTipClicked({
                    try {
                        if (-not [string]::IsNullOrWhiteSpace($script:UpdateLatestUrl)) {
                            Start-Process $script:UpdateLatestUrl
                        }
                    }
                    catch {}
                })
            $script:UpdateNotifyIcon = $ni
        }

        $script:UpdateNotifyIcon.BalloonTipTitle = $title
        $script:UpdateNotifyIcon.BalloonTipText = $text
        $script:UpdateNotifyIcon.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Info
        $script:UpdateNotifyIcon.ShowBalloonTip(8000)
    }
    catch {}
}

function Set-UpdateStatusLabel([string]$text, [System.Drawing.Color]$color, [bool]$isLink = $false) {
    try {
        if (-not $script:lblUpdateStatus -or $script:lblUpdateStatus.IsDisposed) { return }
        $script:lblUpdateStatus.Text = $text
        $script:lblUpdateStatus.ForeColor = $color
        $script:lblUpdateStatus.Cursor = if ($isLink) { [System.Windows.Forms.Cursors]::Hand } else { [System.Windows.Forms.Cursors]::Default }
    }
    catch {}
}

function Check-ForAppUpdate([switch]$Startup) {
    try {
        if (-not $script:Cfg.Update.Enabled) { return }

        $owner = [string]$script:Cfg.Update.RepoOwner
        $repo = [string]$script:Cfg.Update.RepoName
        $currentTag = [string]$script:Cfg.Update.CurrentTag

        if ([string]::IsNullOrWhiteSpace($owner) -or [string]::IsNullOrWhiteSpace($repo)) {
            Set-UpdateStatusLabel 'Update: repo not set' ([System.Drawing.Color]::Gray) $false
            return
        }

        Set-UpdateStatusLabel 'Update: checking...' ([System.Drawing.Color]::LightGray) $false

        $url = "https://api.github.com/repos/$owner/$repo/releases/latest"
        $headers = @{ 'User-Agent' = 'JWL-OBS-Assistant-Updater' }
        $rel = Invoke-RestMethod -Uri $url -Headers $headers -Method Get -TimeoutSec 12

        $latestTag = [string]$rel.tag_name
        $latestUrl = [string]$rel.html_url
        $script:UpdateLatestTag = $latestTag
        $script:UpdateLatestUrl = $latestUrl

        if (Test-IsNewerTag $currentTag $latestTag) {
            $script:UpdateAvailable = $true
            Set-UpdateStatusLabel ("Update: {0}" -f $latestTag) ([System.Drawing.Color]::Gold) $true
            Log "Update available: current='$currentTag' latest='$latestTag'"
            if ($Startup) {
                Show-UpdateBalloon 'JWL+OBS Assistant update available' ("New version {0} is available." -f $latestTag)
            }
        }
        else {
            $script:UpdateAvailable = $false
            Set-UpdateStatusLabel ("Up to date: {0}" -f $currentTag) ([System.Drawing.Color]::LimeGreen) $false
            Log "Update check: up to date ($currentTag)"
        }
    }
    catch {
        $script:UpdateAvailable = $false
        Set-UpdateStatusLabel 'Update check failed' ([System.Drawing.Color]::Gray) $false
        Log "Update check failed: $_"
    }
}

# --------- settings ----------
# Always use the Documents path (prevents dual files when "Run with PowerShell")

function Get-ConfigPath {
    # Use %APPDATA% for consistent config location regardless of script/EXE mode
    $appDataFolder = [Environment]::GetFolderPath('ApplicationData')
    $configDir = Join-Path $appDataFolder 'JWL-OBS-Assistant'
    
    # Create config directory if it doesn't exist
    if (-not (Test-Path $configDir)) { 
        try { New-Item -ItemType Directory -Path $configDir -Force | Out-Null } 
        catch { Log "Failed to create config directory: $_" }
    }
    
    return Join-Path $configDir 'settings.json'
}

function Get-LegacyConfigPaths {
    # Return list of possible legacy config locations for migration
    $paths = @()
    
    try {
        # Current script/EXE folder locations
        $base = Split-Path -Path $scriptPath
        $paths += Join-Path $base 'JWL+OBS Assistant.json'
        
        # EXE subfolder locations
        $exeFolder = Join-Path $base 'EXE'
        if (Test-Path $exeFolder) {
            $paths += Join-Path $exeFolder 'JWL+OBS Assistant.json'
            $exeSubFolder = Join-Path $exeFolder 'EXE' 
            if (Test-Path $exeSubFolder) {
                $paths += Join-Path $exeSubFolder 'JWL+OBS Assistant.json'
            }
        }
        
        # Legacy settings file
        $paths += Join-Path $base 'JWLAssistant.settings.json'
        
        # Documents folder (old location)
        $docsFolder = [Environment]::GetFolderPath('MyDocuments')
        $paths += Join-Path $docsFolder 'JWLAssistant.settings.json'
        $paths += Join-Path $docsFolder 'JWL+OBS Assistant.json'
    }
    catch {}
    
    # Return only existing files, sorted by newest first
    return ($paths | Where-Object { Test-Path $_ } | Get-Item | Sort-Object LastWriteTime -Descending)
}

function Migrate-ConfigToAppData {
    $newConfigPath = Get-ConfigPath
    
    # Skip if config already exists in new location
    if (Test-Path $newConfigPath) { 
        Log "Config already exists in %APPDATA% location" 
        return $true 
    }
    
    # Find the most recent legacy config file
    $legacyConfigs = Get-LegacyConfigPaths
    
    if ($legacyConfigs.Count -eq 0) {
        Log "No legacy config files found for migration"
        return $false
    }
    
    $source = $legacyConfigs[0].FullName
    try {
        Copy-Item -Path $source -Destination $newConfigPath -Force
        Log "Config migrated from: $source"
        Log "Config migrated to: $newConfigPath"
        return $true
    }
    catch {
        Log "Failed to migrate config: $_"
        return $false
    }
}

function Find-ExistingConfigs {
    # Look for config files from other versions in the same parent directory
    $currentBase = Split-Path -Path $scriptPath
    $parentDir = Split-Path -Path $currentBase
    $currentConfigPath = Get-ConfigPath
    
    $existingConfigs = @()
    
    # Search for other script folders with config files
    try {
        $scriptFolders = Get-ChildItem -Path $parentDir -Directory -ErrorAction SilentlyContinue | Where-Object { 
            $_.Name -like "*JWL*Assistant*" -or $_.Name -like "*v4.*" -or $_.Name -like "*v3.*"
        }
        
        foreach ($folder in $scriptFolders) {
            $configPath = Join-Path $folder.FullName 'JWL+OBS Assistant.json'
            if ((Test-Path $configPath) -and $configPath -ne $currentConfigPath) {
                $configInfo = Get-Item $configPath
                $existingConfigs += @{
                    Path         = $configPath
                    FolderName   = $folder.Name
                    LastModified = $configInfo.LastWriteTime
                    Size         = $configInfo.Length
                }
            }
        }
    }
    catch {}
    
    # Sort by last modified (most recent first)
    return $existingConfigs | Sort-Object LastModified -Descending
}

function Show-ConfigImportDialog($existingConfigs) {
    if ($existingConfigs.Count -eq 0) { return $false }
    
    Add-Type -AssemblyName System.Windows.Forms
    
    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = "Import Existing Settings?"
    $dialog.Size = [System.Drawing.Size]::new(500, 350)
    $dialog.StartPosition = "CenterScreen"
    $dialog.FormBorderStyle = "FixedDialog"
    $dialog.MaximizeBox = $false
    $dialog.MinimizeBox = $false
    $dialog.TopMost = $true
    
    $lblTitle = New-Object System.Windows.Forms.Label
    $lblTitle.Text = "Existing configuration files found from previous versions:"
    $lblTitle.Location = [System.Drawing.Point]::new(10, 10)
    $lblTitle.Size = [System.Drawing.Size]::new(460, 20)
    $dialog.Controls.Add($lblTitle)
    
    # List of found configs
    $listBox = New-Object System.Windows.Forms.ListBox
    $listBox.Location = [System.Drawing.Point]::new(10, 35)
    $listBox.Size = [System.Drawing.Size]::new(460, 120)
    
    foreach ($config in $existingConfigs) {
        $item = "$($config.FolderName) - Modified: $($config.LastModified.ToString('yyyy-MM-dd HH:mm'))"
        $listBox.Items.Add($item) | Out-Null
    }
    $listBox.SelectedIndex = 0  # Select most recent by default
    $dialog.Controls.Add($listBox)
    
    $lblQuestion = New-Object System.Windows.Forms.Label
    $lblQuestion.Text = "Would you like to import settings from the selected version?"
    $lblQuestion.Location = [System.Drawing.Point]::new(10, 170)
    $lblQuestion.Size = [System.Drawing.Size]::new(460, 20)
    $dialog.Controls.Add($lblQuestion)
    
    $lblDetails = New-Object System.Windows.Forms.Label
    $lblDetails.Text = "• Import: Copy all settings (scenes, reminders, XR config, etc.)`n• Start Fresh: Use defaults for new version"
    $lblDetails.Location = [System.Drawing.Point]::new(10, 200)
    $lblDetails.Size = [System.Drawing.Size]::new(460, 40)
    $lblDetails.Font = New-Object System.Drawing.Font("Segoe UI", 8, [System.Drawing.FontStyle]::Italic)
    $lblDetails.ForeColor = [System.Drawing.Color]::DarkBlue
    $dialog.Controls.Add($lblDetails)
    
    # Buttons
    $btnImport = New-Object System.Windows.Forms.Button
    $btnImport.Text = "Import Settings"
    $btnImport.Location = [System.Drawing.Point]::new(175, 260)
    $btnImport.Size = [System.Drawing.Size]::new(130, 30)
    $btnImport.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $dialog.Controls.Add($btnImport)

    $btnBrowse = New-Object System.Windows.Forms.Button
    $btnBrowse.Text = "Open Backups Folder"
    $btnBrowse.Location = [System.Drawing.Point]::new(10, 260)
    $btnBrowse.Size = [System.Drawing.Size]::new(155, 30)
    $btnBrowse.Add_Click({
            $backupsPath = Join-Path (Split-Path (Get-ConfigPath)) 'backups'
            if (Test-Path $backupsPath) {
                Start-Process explorer.exe $backupsPath
            }
            else {
                [System.Windows.Forms.MessageBox]::Show("No backups folder found at:`n$backupsPath", "Not Found", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
            }
        })
    $dialog.Controls.Add($btnBrowse)

    $btnFresh = New-Object System.Windows.Forms.Button
    $btnFresh.Text = "Start Fresh"
    $btnFresh.Location = [System.Drawing.Point]::new(315, 260)
    $btnFresh.Size = [System.Drawing.Size]::new(120, 30)
    $btnFresh.DialogResult = [System.Windows.Forms.DialogResult]::No
    $dialog.Controls.Add($btnFresh)

    $dialog.AcceptButton = $btnImport
    $result = $dialog.ShowDialog()
    
    if ($result -eq [System.Windows.Forms.DialogResult]::OK) {
        $selectedIndex = $listBox.SelectedIndex
        if ($selectedIndex -ge 0) {
            return $existingConfigs[$selectedIndex]
        }
    }
    
    return $false
}

function Import-ConfigFromPath($configPath) {
    try {
        $importedConfig = Get-Content $configPath -Encoding UTF8 | ConvertFrom-Json
        Log "Config Import: Loading settings from $configPath"
        
        # Import all major sections
        if ($importedConfig.Keyword) { $script:Cfg.Keyword = $importedConfig.Keyword }
        if ($importedConfig.Tesseract) { $script:Cfg.Tesseract = $importedConfig.Tesseract }
        
        if ($importedConfig.ROI) {
            $script:Cfg.ROI.TL = if ($importedConfig.ROI.TL) { [System.Drawing.Point]::new($importedConfig.ROI.TL.X, $importedConfig.ROI.TL.Y) } else { $null }
            $script:Cfg.ROI.BR = if ($importedConfig.ROI.BR) { [System.Drawing.Point]::new($importedConfig.ROI.BR.X, $importedConfig.ROI.BR.Y) } else { $null }
        }
        
        # Import all settings sections
        foreach ($section in @('UI', 'OBS', 'OBSControl', 'Music', 'Meeting', 'Zoom', 'Reminders', 'Update', 'XR', 'Audio')) {
            if ($importedConfig.$section) {
                foreach ($prop in ($importedConfig.$section | Get-Member -MemberType NoteProperty)) {
                    $key = $prop.Name
                    $script:Cfg.$section[$key] = $importedConfig.$section.$key
                }
            }
        }
        
        # Import ScenePTZ separately due to its complex structure
        if ($importedConfig.ScenePTZ) {
            $arr = @()
            foreach ($row in $importedConfig.ScenePTZ) {
                $arr += @{
                    Scene            = [string]$row.Scene
                    PTZRecall        = $(if ($null -ne $row.PTZRecall) { [int]$row.PTZRecall } else { $null })
                    Snapshot         = $(if ($null -ne $row.Snapshot) { [int]$row.Snapshot } else { $null })
                    AutoStartSeconds = $(if ($null -ne $row.AutoStartSeconds) { [int]$row.AutoStartSeconds } else { 0 })
                    AutoStart        = [bool]$row.AutoStart
                }
            }
            $script:Cfg.ScenePTZ = $arr
        }
        
        Log "Config Import: Successfully imported settings from previous version"
        return $true
    }
    catch {
        Log "Config Import: Failed to import - $_"
        return $false
    }
}

function Show-ManualConfigImportDialog {
    # Enhanced search patterns to find more config files
    $existingConfigs = Find-ExistingConfigs-Enhanced
    
    if ($existingConfigs.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show(
            "No previous configuration files found.`n`nSearched for config files in neighboring folders and Documents folder.", 
            "Import Settings", 
            [System.Windows.Forms.MessageBoxButtons]::OK, 
            [System.Windows.Forms.MessageBoxIcon]::Information
        ) | Out-Null
        return $false
    }
    
    $selectedConfig = Show-ConfigImportDialog $existingConfigs
    
    if ($selectedConfig) {
        $success = Import-ConfigFromPath $selectedConfig.Path
        if ($success) {
            Save-Settings | Out-Null
            [System.Windows.Forms.MessageBox]::Show(
                "Settings successfully imported from:`n$($selectedConfig.FolderName)`n`nPlease restart the application to see all imported settings.", 
                "Import Complete", 
                [System.Windows.Forms.MessageBoxButtons]::OK, 
                [System.Windows.Forms.MessageBoxIcon]::Information
            ) | Out-Null
            return $true
        }
        else {
            [System.Windows.Forms.MessageBox]::Show(
                "Failed to import settings. See log for details.", 
                "Import Failed", 
                [System.Windows.Forms.MessageBoxButtons]::OK, 
                [System.Windows.Forms.MessageBoxIcon]::Error
            ) | Out-Null
        }
    }
    
    return $false
}

function Find-ExistingConfigs-Enhanced {
    # Enhanced version with better search patterns including %APPDATA%
    $currentBase = Split-Path -Path $scriptPath
    $parentDir = Split-Path -Path $currentBase
    $currentConfigPath = Get-ConfigPath
    
    $existingConfigs = @()
    
    # Search patterns - more comprehensive
    $searchFolders = @()
    
    try {
        # Search in parent directory for any JWL-related folders
        $scriptFolders = Get-ChildItem -Path $parentDir -Directory -ErrorAction SilentlyContinue | Where-Object { 
            $_.Name -like "*JWL*" -or 
            $_.Name -like "*OBS*" -or 
            $_.Name -like "*Assistant*" -or 
            $_.Name -like "*v4.*" -or 
            $_.Name -like "*v3.*" -or
            $_.Name -like "*v5.*" -or
            $_.Name -like "*Assistand*"  # Include common misspelling
        }
        $searchFolders += $scriptFolders
        
        # Search in Documents folder for legacy configs
        $docsPath = [Environment]::GetFolderPath('MyDocuments')
        if (Test-Path $docsPath) {
            $searchFolders += Get-ChildItem -Path $docsPath -Directory -ErrorAction SilentlyContinue | Where-Object { 
                $_.Name -like "*JWL*" -or $_.Name -like "*OBS*" -or $_.Name -like "*Assistant*"
            }
        }
        
        # Search in %APPDATA% for other JWL Assistant installations
        $appDataPath = [Environment]::GetFolderPath('ApplicationData')
        if (Test-Path $appDataPath) {
            $searchFolders += Get-ChildItem -Path $appDataPath -Directory -ErrorAction SilentlyContinue | Where-Object { 
                $_.Name -like "*JWL*" -or $_.Name -like "*OBS*" -or $_.Name -like "*Assistant*"
            }
        }
        
        foreach ($folder in $searchFolders) {
            # Look for both current and legacy config file names
            $configPaths = @(
                (Join-Path $folder.FullName 'JWL+OBS Assistant.json'),
                (Join-Path $folder.FullName 'JWLAssistant.settings.json'),
                (Join-Path $folder.FullName 'settings.json')  # New %APPDATA% format
            )
            
            foreach ($configPath in $configPaths) {
                if ((Test-Path $configPath) -and $configPath -ne $currentConfigPath) {
                    $configInfo = Get-Item $configPath
                    $locationDesc = if ($folder.FullName.Contains([Environment]::GetFolderPath('ApplicationData'))) { 
                        "%APPDATA%\$($folder.Name)" 
                    }
                    else { 
                        $folder.Name 
                    }
                    $existingConfigs += @{
                        Path         = $configPath
                        FolderName   = "$locationDesc [$($configInfo.Name)]"
                        LastModified = $configInfo.LastWriteTime
                        Size         = $configInfo.Length
                    }
                }
            }
        }
        
        # Also check for legacy configs in current folder and subfolders
        $legacyPaths = Get-LegacyConfigPaths
        foreach ($legacy in $legacyPaths) {
            if ($legacy.FullName -ne $currentConfigPath) {
                $existingConfigs += @{
                    Path         = $legacy.FullName
                    FolderName   = "Legacy [$($legacy.Name)]"
                    LastModified = $legacy.LastWriteTime
                    Size         = $legacy.Length
                }
            }
        }
    }
    catch {}
    
    # Remove duplicates and sort by last modified (most recent first)
    $uniqueConfigs = @()
    $seenPaths = @{}
    foreach ($config in $existingConfigs) {
        if (-not $seenPaths.Contains($config.Path)) {
            $seenPaths[$config.Path] = $true
            $uniqueConfigs += $config
        }
    }

    # Add auto-backup files from the backups\ subfolder so they appear in the import dialog
    try {
        $backupSearchDir = Join-Path (Split-Path $currentConfigPath) 'backups'
        if (Test-Path $backupSearchDir) {
            Get-ChildItem $backupSearchDir -Filter 'settings_*.json' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            ForEach-Object {
                if (-not $seenPaths.Contains($_.FullName)) {
                    $seenPaths[$_.FullName] = $true
                    $uniqueConfigs += @{
                        Path         = $_.FullName
                        FolderName   = "AUTO-BACKUP [$($_.Name)]"
                        LastModified = $_.LastWriteTime
                        Size         = $_.Length
                    }
                }
            }
        }
    }
    catch {}

    return $uniqueConfigs | Sort-Object LastModified -Descending
}

function Get-TesseractPath {
    param([switch]$InstalledOnly)

    $fallback = "C:\Program Files\Tesseract-OCR\tesseract.exe"
    $candidates = @()

    try {
        $cmd = Get-Command tesseract -ErrorAction SilentlyContinue
        if ($cmd -and $cmd.Source) { $candidates += [string]$cmd.Source }
    }
    catch {}

    foreach ($root in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA)) {
        if (-not [string]::IsNullOrWhiteSpace($root)) {
            $candidates += (Join-Path $root 'Tesseract-OCR\tesseract.exe')
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        $candidates += (Join-Path $env:LOCALAPPDATA 'Programs\Tesseract-OCR\tesseract.exe')
    }

    foreach ($path in ($candidates | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)) {
        try {
            if (Test-Path $path) { return $path }
        }
        catch {}
    }

    if ($InstalledOnly) { return $null }
    return $fallback
}

$script:Cfg = [ordered]@{
    Keyword = "Jehovah"
    Tesseract = (Get-TesseractPath)
    ROI = [ordered]@{ TL = $null; BR = $null }
    WindowX = 120; WindowY = 120

    UI = [ordered]@{
        Theme      = 'Light'   # 'Light' or 'Dark'
        ScaleLevel = 0          # 0=Standard(100%) 1=Medium(125%) 2=Large(150%)
    }

    OBS = [ordered]@{
        Host            = "127.0.0.1"
        Port            = 4456
        Password        = ""
        UseTLS          = $false
        AllowInsecure   = $true
        SceneCam        = "Speaker"
        SceneMed        = "Media"
        MediaInputName  = "JWL-Audio"           # OBS Audio Input Capture source name for JWL-Audio monitoring
        FadeBlackScene  = ""                    # Scene name for fade-to-black on Cut (leave empty to disable)
        FadeBlackMs     = 500                   # Duration (ms) of each fade leg (out + in)
        FadeBlackHoldMs = 2500                 # ms to hold on black while PTZ moves to new position
    }

    Audio = [ordered]@{
        MonitoringEnabled = $true                       # Enable/disable OBS audio monitoring
        DeviceId          = "DEFAULT"                   # "DEFAULT" or partial device ID (legacy WASAPI, not used)
        Threshold         = 0.0056                        # Sensitivity above 1.0 baseline: -45dB = 10^(-45/20) = 0.0056 (good for typical speech)
        SilenceSeconds    = 4                           # Seconds of silence before triggering off
    }

    ScenePTZ = @(
        @{ Scene = "Speaker"; PTZRecall = $null; Snapshot = 2; AutoStartSeconds = 5; AutoStart = $true },
        @{ Scene = "All Stage"; PTZRecall = $null; Snapshot = 1; AutoStartSeconds = 0; AutoStart = $false },
        @{ Scene = "Speaker Wide"; PTZRecall = $null; Snapshot = 2; AutoStartSeconds = 0; AutoStart = $false },
        @{ Scene = "Demo"; PTZRecall = $null; Snapshot = 4; AutoStartSeconds = 0; AutoStart = $false },
        @{ Scene = "Table"; PTZRecall = $null; Snapshot = 7; AutoStartSeconds = 0; AutoStart = $false },
        @{ Scene = "Speaker+Rover"; PTZRecall = $null; Snapshot = 2; AutoStartSeconds = 0; AutoStart = $false },
        @{ Scene = "Speaker+Rover+Reader"; PTZRecall = $null; Snapshot = 2; AutoStartSeconds = 0; AutoStart = $false },
        @{ Scene = ""; PTZRecall = $null; Snapshot = $null; AutoStartSeconds = 0; AutoStart = $false }
    )

    OBSControl = [ordered]@{ AutoStartAutoToggle = $false; AutoToggleLeadSeconds = 10; AutoVirtualCamera = $false; AutoVirtualCameraSeconds = 20; RecordingConfigured = $false }

    PiP = [ordered]@{
        Enabled    = $true
        SourceName = "PIP Video Capture"
    }

    Music = [ordered]@{
        Folder                        = ""; 
        Volume                        = 40; 
        Shuffle                       = $true; 
        AutoStart                     = $false;
        AutoStopBeforeMeeting         = $true; 
        PreStopSeconds                = 15; 
        FadeOutSeconds                = 3;
        RequireConfirmAlways          = $false;           # optional global confirm
        DisableAutostartDuringMeeting = $true    # future-proof autostart guard
    }
    
    Meeting = [ordered]@{
        Lines               = @(); 
        FlashClockRedLast15 = $true;
        GuardMinutes        = 95
        AutoGuard           = $true                      # <— NEW: enable automatic guard
        GuardLeadMinutes    = 5                   # <— NEW: start guard this many minutes before start
    }

    Zoom = [ordered]@{ 
        AutoMuteAll = $false; AutoMuteSeconds = 50;
        AutoCameraOn = $false; AutoCameraSeconds = 40;
        AutoUnmuteHost = $false; AutoUnmuteSeconds = 10;
        AutoFocusMode = $false; AutoFocusSeconds = 30;
        AutoPollsAfterJoin = $false;   # Auto-start Poll 1 after joining Zoom
        ShowFocusModeButton = $true;   # Show/hide Focus Mode button in main UI
        PollsConfigured = $false;      # User has set up Attendance Poll in Zoom
        AutoZoomAudio = $false; ZoomInLine = 1; AudioLevelDb = 0.0; HoldTimeMs = 2000;
        HandAlertMonitor = 0;
        
        # Auto Join Meeting Settings
        JoinMeetingID = "";
        JoinDisplayName = "";
        JoinDontConnectAudio = $false;
        JoinTurnOffVideo = $false;
        JoinMeetingPassword = ""
        ZoomProjectorMonitor = 0    # Index into non-primary-first sorted screen list
    }
    
    Reminders = [ordered]@{ 
        ZoomEnabled = $false; Seconds = 55; 
        Message = "Reminder To:`r`n`r`n1) SPOTLIGHT Congregation window.`r`n2) Assign Co-Host.`r`n3) Mute All.`r`n4) Set Participants mute privileges.`r`n5) Start `"Focus`" mode if desired."
        Reminder2Enabled = $false; Reminder2Seconds = 30;
        Message2 = "Reminder #2: Meeting starts soon!"
    }

    Update = [ordered]@{
        Enabled                 = $true
        CheckOnStartup          = $true
        ShowWindowsNotification = $true
        RepoOwner               = "mvpapen"
        RepoName                = "JWL-Assistant"
        CurrentTag              = "v6.1.8e"
    }
    
    XR = [ordered]@{
        XRMixerEnabled = $false;  # Master switch: show XR Mixer + Scene Picker sections in Settings
        MixerIP = ""; OscPort = 10024;  # Empty IP by default - user must set actual XR mixer IP
        AutoScan = $false;   # Auto-scan for XR mixer when connection fails
        SnapshotNumber = 1;
        DuckingEnabled = $false;
        MediaChannel = 5;
        PodiumChannel = 1;
        DuckAmountDB = -15;
        ThresholdDB = -45;
        HoldTimeMS = 2000;   # Hold ducking for 2 seconds after audio drops below threshold
        RoverDuckingEnabled = $false;
        RoverChannel1 = 2;
        RoverChannel2 = 3;
        RoverDuckAmountDB = -15;
        RoverHoldTimeMS = 2000;
        RoverThresholdDB = -45;
        RoverMonitorChannel = 8;
        RoverMonitorChannel2 = 8;
        RoverActiveSnapshot = 4;
        RoverScene = "Speaker+Rover+Reader";  # legacy, kept for compatibility
        MixerPanelEnabled = $false;
        MixerPanelBaseH = 0;         # Saved mixer panel height at scale 1.0 (0 = auto)
        XrDebugLog = $false;
        AutoModeEnabled = $false;
        AutoModeHoldTimeMS = 2000;
        LimiterEnabled = $false;
        LimiterThresholdDB = 0;
        LimiterSnapBackSec = 5;
        ShowLevelLabels = $true;
        MixerChannelLabels = @("Ch 1", "Ch 2", "Ch 3", "Ch 4", "Ch 5", "Ch 6", "Ch 7", "Ch 8", "Ch 9");
        MixerMasterLabel = "Master";
        MixerSnapLabels = @("", "", "", "", "", "", "", "Auto Mode");
        MixerSnapNumbers = @(1, 2, 3, 4, 5, 6, 7, 8);
        MixerSnapColors = @("", "", "", "", "", "", "", "");
        MixerRoleLabels = @("", "", "", "", "", "", "", "", "", "");   # 10 per-strip role labels (index 9 = master)
        MixerRoleColors = @("", "", "", "", "", "", "", "", "", "");   # 10 per-strip role colors
    }

    InfoTexts = [ordered]@{}   # User-edited info popup texts (keyed by popup name)
}

function Save-Settings {
    try {
        if ($script:form -and -not $script:form.IsDisposed) {
            $script:Cfg.WindowX = [int]$script:form.Left
            $script:Cfg.WindowY = [int]$script:form.Top

        }

        $obj = [ordered]@{
            Keyword      = $script:Cfg.Keyword
            Tesseract    = $script:Cfg.Tesseract
            ROI          = @{
                TL = if ($script:Cfg.ROI.TL) { @{X = $script:Cfg.ROI.TL.X; Y = $script:Cfg.ROI.TL.Y } } else { $null }
                BR = if ($script:Cfg.ROI.BR) { @{X = $script:Cfg.ROI.BR.X; Y = $script:Cfg.ROI.BR.Y } } else { $null }
            }
            WindowX      = $script:Cfg.WindowX
            WindowY      = $script:Cfg.WindowY
            UI           = $script:Cfg.UI         # <-- add this
            OBS          = $script:Cfg.OBS
            OBSControl   = $script:Cfg.OBSControl
            Music        = $script:Cfg.Music
            Meeting      = $script:Cfg.Meeting
            Zoom         = $script:Cfg.Zoom   # includes ZoomProjectorMonitor
            Reminders    = $script:Cfg.Reminders
            Update       = $script:Cfg.Update
            XR           = $script:Cfg.XR
            ScenePTZ     = $script:Cfg.ScenePTZ
            InfoTexts    = $script:Cfg.InfoTexts
            PiP          = $script:Cfg.PiP
            AfRoi        = $(
                if ($script:afRoi -and $script:afRoi.Width -gt 40 -and $script:afRoi.Height -gt 40) {
                    @{ X = $script:afRoi.X; Y = $script:afRoi.Y; W = $script:afRoi.Width; H = $script:afRoi.Height }
                }
                elseif ($script:_pendingAfRoi) {
                    $script:_pendingAfRoi   # not yet applied — preserve what was loaded
                }
                else { $null }
            )
            AfSpeed      = if ($null -ne $script:afSpeed) { [int]$script:afSpeed } elseif ($script:_pendingAfSpeed) { [int]$script:_pendingAfSpeed } else { 80 }
            AfEnabled    = if ($null -ne $script:afEnabled) { [bool]$script:afEnabled } elseif ($null -ne $script:_pendingAfEnabled) { [bool]$script:_pendingAfEnabled } else { $false }
            AfRoiVisible = if ($null -ne $script:afRoiVisible) { [bool]$script:afRoiVisible } elseif ($null -ne $script:_pendingAfRoiVisible) { [bool]$script:_pendingAfRoiVisible } else { $false }
        }


        $configPath = Get-ConfigPath
        $obj | ConvertTo-Json -Depth 8 | Set-Content $configPath -Encoding UTF8
        Log "Settings saved to: $configPath"
        Log "Zoom join settings in saved config: ID='$($obj.Zoom.JoinMeetingID)', Name='$($obj.Zoom.JoinDisplayName)'"

        # Auto-backup: keep the last 5 timestamped copies so an old script version
        # can't permanently destroy settings by saving on close.
        try {
            $backupDir = Join-Path (Split-Path $configPath) 'backups'
            if (-not (Test-Path $backupDir)) { New-Item -ItemType Directory -Path $backupDir -Force | Out-Null }
            $stamp = (Get-Date).ToString('yyyyMMdd_HHmmss')
            $backupFile = Join-Path $backupDir "settings_$stamp.json"
            Copy-Item -Path $configPath -Destination $backupFile -Force
            # Prune: remove all but the 5 most recent backups
            Get-ChildItem $backupDir -Filter 'settings_*.json' |
            Sort-Object LastWriteTime -Descending |
            Select-Object -Skip 5 |
            Remove-Item -Force
        }
        catch {}
    }
    catch { Log "Save failed: $_" }
}
# Migrate any prior settings file to "JWL+OBS Assistant.json" next to the script
try {
    $oldDoc = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'JWLAssistant.settings.json'    # old name in Documents
    $oldDocNewName = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'JWL+OBS Assistant.json' # if you used the new name in Documents
    $newPath = Get-ConfigPath

    foreach ($old in @($oldDoc, $oldDocNewName)) {
        if ((Test-Path $old) -and -not (Test-Path $newPath)) {
            Copy-Item -Path $old -Destination $newPath -Force
            Remove-Item -Path $old -Force
            Log "Migrated settings to: $newPath"
        }
    }
}
catch { Log "Settings migration skipped: $_" }

function Load-Settings {
    $p = Get-ConfigPath
    
    # First, attempt to migrate from legacy locations if needed
    if (-not (Test-Path $p)) {
        Log "Config not found in %APPDATA%, attempting migration from legacy locations..."
        Migrate-ConfigToAppData | Out-Null
    }
    
    # Check if this is a first run (no config file exists)
    $isFirstRun = -not (Test-Path $p)

    # Before showing the legacy-version import dialog, check our own backups folder.
    # If a recent auto-backup exists, restore it silently — always better than importing
    # a months-old file from a previous version.
    if ($isFirstRun) {
        try {
            $backupDir = Join-Path (Split-Path $p) 'backups'
            $latestBackup = Get-ChildItem $backupDir -Filter 'settings_*.json' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1
            if ($latestBackup) {
                Log "Settings: main file missing — auto-restoring from backup: $($latestBackup.Name)"
                Copy-Item $latestBackup.FullName $p -Force
                $isFirstRun = $false
            }
        }
        catch {}
    }

    if ($isFirstRun) {
        Log "No config file found, this appears to be a first run"
        # Look for existing config files from other versions
        $existingConfigs = Find-ExistingConfigs-Enhanced
        
        if ($existingConfigs.Count -gt 0) {
            # Show import dialog
            $selectedConfig = Show-ConfigImportDialog $existingConfigs
            
            if ($selectedConfig) {
                # User chose to import
                $success = Import-ConfigFromPath $selectedConfig.Path
                if ($success) {
                    # Save imported config to current location
                    Save-Settings | Out-Null
                    Log "Config: Successfully imported and saved settings from $($selectedConfig.FolderName)"
                    return
                }
                else {
                    Log "Config: Import failed, using defaults"
                }
            }
            else {
                Log "Config: User chose to start fresh with defaults"
                return
            }
        }
        else {
            Log "Config: No existing config files found, using defaults"
            return
        }
    }
    if (-not (Test-Path $p)) { return }

    $c = $null
    try {
        $c = Get-Content -Raw -Path $p | ConvertFrom-Json

        foreach ($k in 'Keyword', 'Tesseract') {
            if ($c.PSObject.Properties.Name -contains $k) { $script:Cfg[$k] = [string]$c.$k }
        }

        if ($c.ROI) {
            $script:Cfg.ROI = [ordered]@{
                TL = if ($c.ROI.TL) { New-Object System.Drawing.Point ([int]$c.ROI.TL.X), ([int]$c.ROI.TL.Y) } else { $null }
                BR = if ($c.ROI.BR) { New-Object System.Drawing.Point ([int]$c.ROI.BR.X), ([int]$c.ROI.BR.Y) } else { $null }
            }
        }

        if ($c.UI) {
            foreach ($k in 'Theme', 'ScaleLevel') {
                if ($c.UI.PSObject.Properties.Name -contains $k) { $script:Cfg.UI[$k] = $c.UI.$k }
            }
        }

        foreach ($k in 'WindowX', 'WindowY') {
            if ($c.PSObject.Properties.Name -contains $k) { $script:Cfg[$k] = [int]$c.$k }
        }

        if ($c.OBS) {
            foreach ($k in 'Host', 'Port', 'Password', 'UseTLS', 'AllowInsecure', 'SceneCam', 'SceneMed', 'FadeBlackScene', 'FadeBlackMs', 'FadeBlackHoldMs') {
                if ($c.OBS.PSObject.Properties.Name -contains $k) { $script:Cfg.OBS[$k] = $c.OBS.$k }
            }
        }

        if ($c.OBSControl) {
            foreach ($k in 'AutoStartAutoToggle', 'AutoToggleLeadSeconds', 'AutoVirtualCamera', 'AutoVirtualCameraSeconds') {
                if ($c.OBSControl.PSObject.Properties.Name -contains $k) { $script:Cfg.OBSControl[$k] = $c.OBSControl.$k }
            }
        }
        
        # Update old default value of 5 seconds to new default of 10 seconds
        if ([int]$script:Cfg.OBSControl.AutoToggleLeadSeconds -eq 5) {
            $script:Cfg.OBSControl.AutoToggleLeadSeconds = 10
        }

        if ($c.PiP) {
            foreach ($k in 'Enabled', 'SourceName') {
                if ($c.PiP.PSObject.Properties.Name -contains $k) { $script:Cfg.PiP[$k] = $c.PiP.$k }
            }
        }

        if ($c.Music) {
            foreach ($k in @(
                    'Folder', 'Volume', 'Shuffle', 'AutoStart',
                    'AutoStopBeforeMeeting', 'PreStopSeconds', 'FadeOutSeconds',
                    'RequireConfirmAlways', 'DisableAutostartDuringMeeting'   # <-- new keys
                )) {
                if ($c.Music.PSObject.Properties.Name -contains $k) { $script:Cfg.Music[$k] = $c.Music.$k }
            }
        }

        if ($c.Meeting) {
            if ($c.Meeting.PSObject.Properties.Name -contains 'Lines') { $script:Cfg.Meeting.Lines = @($c.Meeting.Lines) }
            if ($c.Meeting.PSObject.Properties.Name -contains 'FlashClockRedLast15') { $script:Cfg.Meeting.FlashClockRedLast15 = [bool]$c.Meeting.FlashClockRedLast15 }
            if ($c.Meeting.PSObject.Properties.Name -contains 'GuardMinutes') { $script:Cfg.Meeting.GuardMinutes = [int]$c.Meeting.GuardMinutes }  # <-- new key
        }
        if ($c.Meeting) {
            if ($c.Meeting.PSObject.Properties.Name -contains 'Lines') { $script:Cfg.Meeting.Lines = @($c.Meeting.Lines) }
            if ($c.Meeting.PSObject.Properties.Name -contains 'FlashClockRedLast15') { $script:Cfg.Meeting.FlashClockRedLast15 = [bool]$c.Meeting.FlashClockRedLast15 }
            if ($c.Meeting.PSObject.Properties.Name -contains 'GuardMinutes') { $script:Cfg.Meeting.GuardMinutes = [int]$c.Meeting.GuardMinutes }
            if ($c.Meeting.PSObject.Properties.Name -contains 'AutoGuard') { $script:Cfg.Meeting.AutoGuard = [bool]$c.Meeting.AutoGuard }          # NEW
            if ($c.Meeting.PSObject.Properties.Name -contains 'GuardLeadMinutes') { $script:Cfg.Meeting.GuardLeadMinutes = [int]$c.Meeting.GuardLeadMinutes }   # NEW
        }

        if ($c.Zoom) {
            foreach ($k in 'AutoMuteAll', 'AutoMuteSeconds', 'AutoCameraOn', 'AutoCameraSeconds', 'AutoUnmuteHost', 'AutoUnmuteSeconds', 'AutoFocusMode', 'AutoFocusSeconds', 'AutoPollsAfterJoin', 'ShowFocusModeButton', 'PollsConfigured', 'AutoZoomAudio', 'ZoomInLine', 'AudioLevelDb', 'HoldTimeMs', 'HandAlertMonitor', 'JoinMeetingID', 'JoinDisplayName', 'JoinDontConnectAudio', 'JoinTurnOffVideo', 'JoinMeetingPassword', 'ZoomProjectorMonitor') {
                if ($c.Zoom.PSObject.Properties.Name -contains $k) { $script:Cfg.Zoom[$k] = $c.Zoom.$k }
            }
            
            # Migrate old timing defaults (15,15,15,15) to new optimized sequence (50,40,30,10)
            if ([int]$script:Cfg.Zoom.AutoMuteSeconds -eq 15 -and 
                [int]$script:Cfg.Zoom.AutoCameraSeconds -eq 15 -and 
                [int]$script:Cfg.Zoom.AutoUnmuteSeconds -eq 15 -and 
                [int]$script:Cfg.Zoom.AutoFocusSeconds -eq 15) {
                $script:Cfg.Zoom.AutoMuteSeconds = 50    # Mute All (first)
                $script:Cfg.Zoom.AutoCameraSeconds = 40  # Camera On (second) 
                $script:Cfg.Zoom.AutoFocusSeconds = 30   # Focus Mode (third)
                $script:Cfg.Zoom.AutoUnmuteSeconds = 10  # Unmute Host (fourth)
                Log "Auto timing migrated from old defaults (15s) to optimized sequence (50,40,30,10)"
                Save-Settings | Out-Null  # Save the migrated values
            }
            
            # Debug: Log what we loaded
            Log "Settings Load Debug: JoinMeetingID='$($script:Cfg.Zoom.JoinMeetingID)'"
            Log "Settings Load Debug: JoinDisplayName='$($script:Cfg.Zoom.JoinDisplayName)'"
        }

        if ($c.Reminders) {
            foreach ($k in 'ZoomEnabled', 'Seconds', 'Message', 'Reminder2Enabled', 'Reminder2Seconds', 'Message2') {
                if ($c.Reminders.PSObject.Properties.Name -contains $k) { $script:Cfg.Reminders[$k] = $c.Reminders.$k }
            }
        }

        if ($c.Update) {
            foreach ($k in 'Enabled', 'CheckOnStartup', 'ShowWindowsNotification', 'RepoOwner', 'RepoName', 'CurrentTag') {
                if ($c.Update.PSObject.Properties.Name -contains $k) { $script:Cfg.Update[$k] = $c.Update.$k }
            }
        }

        # Fill missing update repo defaults and bump old tags up to this script baseline.
        if ([string]::IsNullOrWhiteSpace([string]$script:Cfg.Update.RepoOwner)) { $script:Cfg.Update.RepoOwner = 'mvpapen' }
        if ([string]::IsNullOrWhiteSpace([string]$script:Cfg.Update.RepoName)) { $script:Cfg.Update.RepoName = 'JWL-Assistant' }
        $scriptBaselineTag = 'v6.1.8e'
        if ([string]::IsNullOrWhiteSpace([string]$script:Cfg.Update.CurrentTag) -or (Test-IsNewerTag ([string]$script:Cfg.Update.CurrentTag) $scriptBaselineTag)) {
            $script:Cfg.Update.CurrentTag = $scriptBaselineTag
        }

        if ($c.XR) {
            foreach ($k in 'XRMixerEnabled', 'MixerIP', 'OscPort', 'AutoScan', 'AutoSnapshot', 'SnapshotNumber', 'DuckingEnabled', 'MediaChannel', 'PodiumChannel', 'DuckAmountDB', 'ThresholdDB', 'HoldTimeMS', 'RoverDuckingEnabled', 'RoverChannel1', 'RoverChannel2', 'RoverDuckAmountDB', 'RoverHoldTimeMS', 'RoverThresholdDB', 'RoverMonitorChannel', 'RoverMonitorChannel2', 'RoverActiveSnapshot', 'MixerPanelEnabled', 'MixerPanelBaseH', 'XrDebugLog', 'MixerMasterLabel', 'AutoModeEnabled', 'AutoModeHoldTimeMS', 'LimiterEnabled', 'LimiterThresholdDB', 'LimiterSnapBackSec', 'ShowLevelLabels') {
                if ($c.XR.PSObject.Properties.Name -contains $k) { 
                    $script:Cfg.XR[$k] = $c.XR.$k 
                }
            }
            # Array keys — loaded separately to preserve type
            foreach ($ak in 'MixerChannelLabels', 'MixerSnapLabels', 'MixerSnapNumbers', 'MixerSnapColors', 'MixerRoleLabels', 'MixerRoleColors') {
                if ($c.XR.PSObject.Properties.Name -contains $ak -and $null -ne $c.XR.$ak) {
                    $script:Cfg.XR[$ak] = @($c.XR.$ak)
                }
            }
        }

        if ([string]::IsNullOrWhiteSpace($script:Cfg.Tesseract) -or -not (Test-Path $script:Cfg.Tesseract)) {
            $detectedTesseract = Get-TesseractPath -InstalledOnly
            if (-not [string]::IsNullOrWhiteSpace($detectedTesseract)) {
                $script:Cfg.Tesseract = $detectedTesseract
                Log "Tesseract path auto-detected: $detectedTesseract"
            }
        }

        Log "Settings loaded."
        if ($script:PSw34Loaded) {
            Log "PSw34 helper: OK"
        }
        else {
            Log "PSw34 helper: NOT loaded — $script:PSw34Error"
        }
    }
    catch {
        Log "Load failed: $_"
    }

    # AfRoi — store pending values; applied AFTER _AFRect is defined (line ~2440)
    try {
        if ($c -and $c.AfRoi) {
            $rx = [int]$c.AfRoi.X; $ry = [int]$c.AfRoi.Y
            $rw = [int]$c.AfRoi.W; $rh = [int]$c.AfRoi.H
            if ($rw -gt 40 -and $rh -gt 40) {
                $script:_pendingAfRoi = @{ X = $rx; Y = $ry; W = $rw; H = $rh }
            }
        }
        if ($c -and $c.AfSpeed -and [int]$c.AfSpeed -gt 0) {
            $script:_pendingAfSpeed = [int]$c.AfSpeed
        }
        if ($c -and $c.PSObject.Properties.Name -contains 'AfEnabled') {
            $script:_pendingAfEnabled = [bool]$c.AfEnabled
        }
        if ($c -and $c.PSObject.Properties.Name -contains 'AfRoiVisible') {
            $script:_pendingAfRoiVisible = [bool]$c.AfRoiVisible
        }
    }
    catch {}

    # ScenePTZ (outside the try, but guarded if $c is null)
    try {
        if ($c -and $c.ScenePTZ) {
            $arr = @()
            foreach ($row in $c.ScenePTZ) {
                $arr += @{
                    Scene            = [string]$row.Scene
                    PTZRecall        = $(if ($null -ne $row.PTZRecall) { [int]$row.PTZRecall } else { $null })
                    Snapshot         = $(if ($null -ne $row.Snapshot) { [int]$row.Snapshot } else { $null })
                    AutoStartSeconds = $(if ($null -ne $row.AutoStartSeconds) { [int]$row.AutoStartSeconds } else { 0 })
                    AutoStart        = [bool]$row.AutoStart
                }
            }
            while ($arr.Count -lt 8) { $arr += @{ Scene = ""; PTZRecall = $null; Snapshot = $null; AutoStartSeconds = 0; AutoStart = $false } }
            if ($arr.Count -gt 8) { $arr = $arr[0..7] }
            $script:Cfg.ScenePTZ = $arr
        }
    }
    catch {}

    # InfoTexts (user-edited popup texts)
    try {
        if ($c -and $c.InfoTexts) {
            foreach ($k in $c.InfoTexts.PSObject.Properties.Name) {
                $script:Cfg.InfoTexts[$k] = [string]$c.InfoTexts.$k
            }
        }
    }
    catch {}
}
Load-Settings | Out-Null

# --- Keep preview WS host/port in sync with JSON settings ---
try {
    $script:ObsWsHost = [string]$script:Cfg.OBS.Host
    $script:ObsWsPort = [int]$script:Cfg.OBS.Port
}
catch {
    $script:ObsWsHost = '127.0.0.1'
    $script:ObsWsPort = 4456
}

# If SceneCam missing, prefer Speaker; do NOT overwrite if already set in JSON
if ([string]::IsNullOrWhiteSpace($script:Cfg.OBS.SceneCam)) {
    $script:Cfg.OBS.SceneCam = "Speaker"
}

# Keep a point on-screen
function Ensure-OnScreen([int]$x, [int]$y) {
    $rects = [System.Windows.Forms.Screen]::AllScreens | ForEach-Object { $_.WorkingArea }
    foreach ($r in $rects) {
        if (($x -ge $r.Left) -and ($x -le $r.Right - 50) -and ($y -ge $r.Top) -and ($y -le $r.Bottom - 50)) {
            return (New-Object System.Drawing.Point $x, $y)
        }
    }
    $p = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    return (New-Object System.Drawing.Point ($p.Left + 100), ($p.Top + 100))
}
# ---- lightweight throttled logger for repetitive events ----
if (-not $script:__lastLogAt) { $script:__lastLogAt = @{} }
function Log-Throttled([string]$key, [string]$msg, [int]$everySec = 10) {
    try {
        # Suppress all xr- keyed entries when XR debug logging is disabled
        if ($key -like 'xr-*' -and $script:Cfg -and $script:Cfg.XR -and (-not $script:Cfg.XR.XrDebugLog)) { return }
        $now = Get-Date
        if (-not $script:__lastLogAt.Contains($key) -or ($now - $script:__lastLogAt[$key]).TotalSeconds -ge $everySec) {
            Log $msg
            $script:__lastLogAt[$key] = $now
        }
    }
    catch {}
}

# ---- auto-connect backoff state ----
if (-not $script:autoBaseMs) { $script:autoBaseMs = 1200 }   # normal retry cadence
if (-not $script:autoMaxMs) { $script:autoMaxMs = 8000 }   # max while OBS is closed
if (-not $script:autoCurMs) { $script:autoCurMs = $script:autoBaseMs }

# --------- OBS WebSocket (manual connect only) ----------
Add-Type -AssemblyName System.Net.Http
$script:ObsWs = $null; $script:ObsConnected = $false; $script:_reqId = 0
$script:_audioMeterLevels = @{}  # Cache for audio meter levels from InputVolumeMeters events

# --------- XR12 OSC Meter Receiver ----------
$script:XrMeterUdp = $null  # UDP client for receiving XR12 meters
$script:XrMeterLevels = @{}  # Cache: channel# => dB value
$script:XrMeterTimer = $null  # Timer to poll for meter packets

# ------- XR Mixer Panel state -------
$script:_mixerPanel = $null   # Form reference (null when closed)
$script:_mixerPanelTimer = $null   # 100ms UI refresh timer
$script:_mixerReopeningForScale = $false   # True while close+reopen cycle for scale change
$script:_mixerUpdating = $false  # Anti-feedback guard for fader sync
$script:_mixerMeterPanels = @()     # Per-channel meter Panel controls (10 entries)
$script:_mixerFaderBars = @()     # Per-channel TrackBar controls (10 entries)
$script:_mixerLevelLabels = @()     # Per-channel meter dB Label controls (10 entries)
$script:_mixerFaderLabels = @()     # Per-channel fader-position dB Label controls (10 entries)

# ------- Auto Mode state -------
$script:_autoModeActive = $false         # true when Auto Mode is running
$script:_autoModeChHoldUntil = @{}       # ch# → [DateTime] hold expiry per channel
$script:_autoModeWavePhase = 0.0         # sine-wave phase for idle animation
$script:_autoModeWaveTick = 0            # counter to throttle wave writes (update every 2 timer ticks)
$script:_autoModeLastDB = @{}            # ch# → last dB sent (to skip redundant OSC writes)
$script:_autoModeTimer = $null           # System.Windows.Forms.Timer for Auto Mode logic
$script:_autoMusicWasPlaying = $false    # tracks previous music-playing state for edge detection
$script:_limiterChCoolUntil = @{}        # ch# → [DateTime] limiter cooldown expiry per channel
$script:_limiterPreValue = @{}        # ch# → linear fader value before limiter reduced it
$script:_limiterBelowSince = @{}        # ch# → [DateTime] when level first dropped below threshold

function New-ReqId { $script:_reqId++; "req$($script:_reqId)" }
function Get-RootErrorMessage($ex) { try { $e = $ex; while ($e.InnerException) { $e = $e.InnerException }; return [string]$e.Message }catch { return [string]$ex } }

function Obs-ComputeAuth($pwdText, $saltB64, $chB64) {
    $sha = [System.Security.Cryptography.SHA256]::Create(); $hmac = New-Object System.Security.Cryptography.HMACSHA256
    $salt = [Convert]::FromBase64String($saltB64); $pw = [Text.Encoding]::UTF8.GetBytes($pwdText)
    $mix = New-Object byte[] ($pw.Length + $salt.Length); [Array]::Copy($pw, 0, $mix, 0, $pw.Length); [Array]::Copy($salt, 0, $mix, $pw.Length, $salt.Length)
    $hmac.Key = $sha.ComputeHash($mix); $auth = $hmac.ComputeHash([Convert]::FromBase64String($chB64)); [Convert]::ToBase64String($auth)
}
function Obs-IsOpen {
    try { return ($script:ObsWs -and $script:ObsWs.State -eq 'Open') } catch { return $false }
}
function Obs-MarkClosed {
    try { if ($script:ObsWs) { $script:ObsWs.Dispose() } }catch {}
    $script:ObsWs = $null; $script:ObsConnected = $false
    Update-ObsButton $false
}
function Obs-ReadJson($ws, [int]$timeoutMs = 5000) {
    $ms = $null; $cts = $null
    try {
        if (-not $ws) { Log "Obs-ReadJson: no websocket"; return $null }
        $buffer = New-Object byte[] 8192
        $ms = New-Object System.IO.MemoryStream
        $cts = New-Object System.Threading.CancellationTokenSource
        $cts.CancelAfter([Math]::Max(100, [int]$timeoutMs))

        while ($true) {
            $seg = [System.ArraySegment[byte]]::new($buffer)
            $task = $ws.ReceiveAsync($seg, $cts.Token)
            $completed = $task.Wait($timeoutMs)
            if (-not $completed) {
                Log "Obs-ReadJson: receive timed out after $timeoutMs ms"
                return $null
            }
            $res = $task.Result
            if ($res.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) {
                Log "OBS closed socket: $($ws.CloseStatus) $($ws.CloseStatusDescription)"
                return $null
            }
            if ($res.Count -gt 0) { $ms.Write($buffer, 0, $res.Count) }
            if ($res.EndOfMessage) { break }
        }

        return [Text.Encoding]::UTF8.GetString($ms.ToArray())
    }
    catch {
        Log "OBS read error: $(Get-RootErrorMessage $_.Exception)"
        return $null
    }
    finally {
        try { if ($ms) { $ms.Dispose() } } catch {}
        try { if ($cts) { $cts.Dispose() } } catch {}
    }
}
function Obs-SendJson($ws, $obj, [int]$timeoutMs = 3000) {
    try {
        if (-not $ws) { Log "Obs-SendJson: no websocket instance"; return $false }
        $json = if ($obj -is [string]) { $obj } else { $obj | ConvertTo-Json -Depth 10 -Compress }
        $bytes = [Text.Encoding]::UTF8.GetBytes($json)
        $seg = [System.ArraySegment[byte]]::new($bytes)

        $cts = New-Object System.Threading.CancellationTokenSource
        $cts.CancelAfter([Math]::Max(100, [int]$timeoutMs))

        $task = $ws.SendAsync($seg, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $cts.Token)
        $ok = $task.Wait($timeoutMs)
        if (-not $ok -or $task.IsFaulted) {
            Log "Obs-SendJson: send failed or timed out after $timeoutMs ms"
            return $false
        }
        return $true
    }
    catch {
        Log "OBS send error: $(Get-RootErrorMessage $_.Exception)"
        return $false
    }
    finally {
        try { if ($cts) { $cts.Dispose() } } catch {}
    }
}
  


function Obs-Connect {
    try {
        if (Obs-IsOpen) { $script:ObsConnected = $true; Update-ObsButton $true; return $true }
        if ($script:ObsWs) { try { $script:ObsWs.Dispose() }catch {} }
        $script:ObsWs = New-Object System.Net.WebSockets.ClientWebSocket
        $scheme = $(if ($script:Cfg.OBS.UseTLS) { "wss" }else { "ws" })
        $uri = "{0}://{1}:{2}" -f $scheme, $script:Cfg.OBS.Host, $script:Cfg.OBS.Port
        $prev = [System.Net.ServicePointManager]::ServerCertificateValidationCallback
        if ($script:Cfg.OBS.UseTLS -and $script:Cfg.OBS.AllowInsecure) { [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true } }
        try {
            Log "OBS: Connecting $uri …"
            $cts = New-Object System.Threading.CancellationTokenSource; $cts.CancelAfter(4000)
            $script:ObsWs.ConnectAsync([Uri]$uri, $cts.Token).Wait(); $cts.Dispose()
        }
        catch { Log "OBS connect error: $(Get-RootErrorMessage $_.Exception)"; $script:ObsConnected = $false; Update-ObsButton $false; return $false }
        finally { [System.Net.ServicePointManager]::ServerCertificateValidationCallback = $prev }

        $helloJson = Obs-ReadJson $script:ObsWs 5000; if (-not $helloJson) { throw "No hello from OBS." }
        $hello = $helloJson | ConvertFrom-Json; if ($hello.op -ne 0) { throw "Unexpected hello opcode." }
        # Subscribe to Inputs (bit 3 = 8) + InputVolumeMeters (bit 16 = 65536) = 65544
        $identify = @{op = 1; d = @{rpcVersion = 1; eventSubscriptions = 65544 } }
        if ($hello.d.authentication) { $identify.d.authentication = Obs-ComputeAuth $script:Cfg.OBS.Password $hello.d.authentication.salt $hello.d.authentication.challenge }
        Obs-SendJson $script:ObsWs $identify
        $identifiedJson = Obs-ReadJson $script:ObsWs 5000; if (-not $identifiedJson) { throw "No identified from OBS." }
        $identified = $identifiedJson | ConvertFrom-Json; if ($identified.op -ne 2) { throw "Identification failed." }
        Log "OBS: Connected with event subscriptions: 65544 (Inputs + VolumeMeters)"
        $script:ObsConnected = $true; Update-ObsButton $true

        # Check for Auto Start scenes after successful connection
        Trigger-AutoStartScenes

        return $true
    }
    catch { Log "OBS connect error: $(Get-RootErrorMessage $_.Exception)"; Obs-MarkClosed; return $false }
}

function Obs-Request([string]$type, [hashtable]$data = @{}) {
    if (-not (Obs-IsOpen)) { Log "OBS: not connected. Click 'Start OBS WS'."; return $false }
    $rid = New-ReqId; $payload = @{op = 6; d = @{requestType = $type; requestId = $rid; requestData = $data } }
    try {
        Obs-SendJson $script:ObsWs $payload
        $resp = Obs-ReadJson $script:ObsWs 5000
        if (-not $resp) { Log "OBS: request timeout ($type)"; return $false }
        $obj = $resp | ConvertFrom-Json
        if ($obj.op -ne 7 -or $obj.d.requestId -ne $rid) { Log "OBS: bad response ($type)"; return $false }
        $ok = [bool]$obj.d.requestStatus.result
        if (-not $ok -and $obj.d.requestStatus.comment) { Log ("OBS: " + $obj.d.requestStatus.comment) }
        return $obj
    }
    catch { Log "OBS request error ($type): $(Get-RootErrorMessage $_.Exception)"; return $false }
}

function Set-ObsScene([string]$scene) {
    if ([string]::IsNullOrWhiteSpace($scene)) { return $false }
    
    # Get actual current scene from OBS to prevent redundant switches
    $currentScene = Get-CurrentProgramSceneName
    if ([string]::Equals($currentScene, $scene, [StringComparison]::InvariantCultureIgnoreCase)) {
        # Already on target scene - no need to switch or log
        return $true
    }
    
    try {
        [void](Invoke-ObsRequest "SetCurrentProgramScene" @{ sceneName = $scene })
        Log "OBS: Scene -> '$scene' (was: '$currentScene')"
        return $true
    }
    catch {
        Log "OBS: Scene change FAILED '$scene' : $($_.Exception.Message)"
        return $false
    }
}

function Obs-GetSceneNames {
    try {
        $r = Invoke-ObsRequest "GetSceneList" @{}
        if (-not $r -or -not $r.scenes) { return @() }
        return @($r.scenes | ForEach-Object { $_.sceneName })
    }
    catch { return @() }
}

# =========================
# === BACKGROUND MUSIC  ===
# =========================
$script:Music = [ordered]@{
    Player = $null; Playlist = $null; Folder = $script:Cfg.Music.Folder
    Files = @(); CurrentIndex = -1; _IsPlaying = $false
    Volume = [int]$script:Cfg.Music.Volume; Shuffle = [bool]$script:Cfg.Music.Shuffle
    AutoStart = [bool]$script:Cfg.Music.AutoStart
    AutoStopBeforeMeeting = [bool]$script:Cfg.Music.AutoStopBeforeMeeting
    PreStopSeconds = [int]$script:Cfg.Music.PreStopSeconds
    FadeOutSeconds = [int]$script:Cfg.Music.FadeOutSeconds
    _LastStartIndex = $null
}
$script:MusicTimer = New-Object System.Windows.Forms.Timer
$script:MusicTimer.Interval = 1000

$script:MusicFadeTimer = New-Object System.Windows.Forms.Timer
$script:MusicFadeTimer.Interval = 60
$script:_fadeActive = $false
$script:_fadeStartTime = $null
$script:_fadeEndTime = $null
$script:_fadeStartVol = 0
$script:_fadeRestoreVol = 0
$script:_fadeStopAfter = $true

$script:MusicFadeTimer.Add_Tick({
        try {
            if (-not $script:_fadeActive -or -not $script:Music.Player) { $script:MusicFadeTimer.Stop(); return }
            try { $script:Music.Player.IsMuted = $false }catch {}
            $now = Get-Date
            $curVol = 0; try { $curVol = [int]($script:Music.Player.Volume * 100) }catch {}
            if ($now -ge $script:_fadeEndTime) {
                try { $script:Music.Player.Volume = 0.0 }catch {}
                if ($script:_fadeStopAfter) { try { $script:Music.Player.Stop(); $script:Music._IsPlaying = $false }catch {} }
                try { $script:Music.Player.Volume = [double]$script:_fadeRestoreVol / 100.0 }catch {}
                $script:_fadeActive = $false; $script:MusicFadeTimer.Stop()
                Update-MusicButtonVisual; Update-MusicToggleButton
                return
            }
            $total = ($script:_fadeEndTime - $script:_fadeStartTime).TotalMilliseconds
            $elapsed = [math]::Min($total, ($now - $script:_fadeStartTime).TotalMilliseconds)
            $linearRatio = 1.0 - ($elapsed / $total)
            $target = [int][math]::Floor($script:_fadeStartVol * $linearRatio)
            if ($target -ge $curVol) { $target = [math]::Max(0, $curVol - 1) }
            try { $script:Music.Player.Volume = [double]$target / 100.0 }catch {}
        }
        catch {}
    })
# ---- Auto Start Scene Functions ----
$script:_autoStartTriggered = $false  # Prevent multiple triggers
$script:_suppressAutoStart = $false   # Skip auto-start when reconnecting for settings changes
$script:_preservedScene = $null       # Scene to restore after settings reconnection
$script:_settingsReconnecting = $false # Block ALL scene changes during settings reconnection

function Trigger-AutoStartScenes {
    # Skip if suppressing auto-start (settings save in progress)
    if ($script:_autoStartTriggered -or $script:_suppressAutoStart) { 
        if ($script:_suppressAutoStart) {
            Log "Auto Start skipped (settings reconnection)"
        }
        return  # Only run once per session or when suppressed
    }
    $script:_autoStartTriggered = $true
    
    try {
        Log "Checking for Auto Start scenes..."
        foreach ($cfg in @($script:Cfg.ScenePTZ)) {
            if ($cfg.AutoStart -and $cfg.Scene) {
                Log "Auto Start triggered: Setting scene '$($cfg.Scene)'"
                try {
                    Set-ObsScene $cfg.Scene
                    if ($cfg.Snapshot) {
                        Start-Sleep -Milliseconds 500  # Allow scene switch to complete
                        if (-not $script:_autoModeActive) {
                            XR-LoadSnapshot $cfg.Snapshot
                        }
                        else {
                            Log "Auto Start: Snapshot auto-load skipped — Auto Mode is active"
                        }
                    }
                    return  # Only trigger first AutoStart=true scene found
                }
                catch {
                    Log "Auto Start scene error: $_"
                }
            }
        }
        Log "No Auto Start scenes found or configured."
    }
    catch {
        Log "Auto Start check error: $_"
    }
}

# ---- Cut Button Flash Timer ----
$script:CutFlashTimer = New-Object System.Windows.Forms.Timer
$script:CutFlashTimer.Interval = 500  # Flash every 500ms
$script:_cutFlashOn = $false
$script:_cutDefaultBackColor = [Drawing.Color]::FromArgb(45, 158, 73)
$script:_cutFlashColor1 = [Drawing.Color]::FromArgb(80, 220, 100)  # Green
$script:_cutFlashColor2 = [Drawing.Color]::FromArgb(220, 80, 80)   # Red

$script:CutFlashTimer.Add_Tick({
        try {
            if ($script:btnCut -and -not $script:btnCut.IsDisposed) {
                $script:_cutFlashOn = -not $script:_cutFlashOn
                $script:btnCut.BackColor = if ($script:_cutFlashOn) {
                    $script:_cutFlashColor1  # Green
                }
                else {
                    $script:_cutFlashColor2  # Red
                }
            }
        }
        catch {}
    })

# ---- V-Cam Flash Timer (for when virtual camera is off) ----
$script:VCamFlashTimer = New-Object System.Windows.Forms.Timer
$script:VCamFlashTimer.Interval = 600  # Flash every 600ms
$script:VCamFlashTimer.Add_Tick({
        try {
            if ($script:btnVCamStatus -and -not $script:btnVCamStatus.IsDisposed) {
                # Toggle between red and dark red for flashing effect
                if ($script:btnVCamStatus.BackColor.R -eq 200) {
                    # Currently red -> make it darker red
                    $script:btnVCamStatus.BackColor = [System.Drawing.Color]::FromArgb(120, 0, 0)
                }
                else {
                    # Currently dark red -> make it bright red
                    $script:btnVCamStatus.BackColor = [System.Drawing.Color]::FromArgb(200, 0, 0)
                }
            }
        }
        catch {}
    })

# ---- OBS Audio Monitor Timer ----
$script:AudioMonitorTimer = New-Object System.Windows.Forms.Timer
$script:AudioMonitorTimer.Interval = 500  # Check twice per second (OBS events update the values)
$script:_audioActive = $false
$script:_lastAudioPeak = 0.0
$script:_lastAudioTime = Get-Date
$script:_audioTickCount = 0

$script:AudioMonitorTimer.Add_Tick({
        if ($script:ShuttingDown) { return }
        try {
            if (-not $script:Cfg.Audio.MonitoringEnabled) { return }
            if (-not $script:ObsConnected) { return }
            
            # OBS events update _audioActive and _lastAudioTime
            # Ducking logic handles hold time - this timer just updates UI
            
            # Debug: Log XR monitor channel level periodically (every 8 seconds)
            if ($script:_audioTickCount % 16 -eq 0 -and $script:running) {
                $monCh = [int]$script:Cfg.XR.MediaChannel
                $threshDB = [double]$script:Cfg.XR.ThresholdDB
                $levelDB = if ($script:XrMeterLevels.Contains($monCh)) { [double]$script:XrMeterLevels[$monCh] } else { -90.0 }
                Log-Throttled "audio-peak" "XR Monitor CH${monCh}: $($levelDB.ToString('F1'))dB  threshold: ${threshDB}dB" 30
            }
            $script:_audioTickCount++
            
            # Don't clear _audioActive here - let the ducking logic handle hold time
            # The ducking timer will release based on XR.HoldTimeMS setting
            
            # Update UI indicator if it exists
            try { Update-AudioIndicator } catch {}
        }
        catch {
            # Silently catch all errors to prevent timer crashes
        }
    })

# ---- Meeting Mode guard state/timer ----
$script:MeetingGuardUntil = $null

# Is the guard active right now?
function Is-MeetingGuardActive {
    try { return ($script:MeetingGuardUntil -and (Get-Date) -lt $script:MeetingGuardUntil) } catch { $false }
}

# Start/stop the guard
function Start-MeetingGuard([int]$minutes) {
    if ($minutes -le 0) { $minutes = 95 }
    $script:MeetingGuardUntil = (Get-Date).AddMinutes($minutes)
    try { $meetingTickTimer.Start() } catch {}
}
function Stop-MeetingGuard {
    $script:MeetingGuardUntil = $null
    try { if ($meetingTickTimer) { $meetingTickTimer.Stop() } } catch {}
    # Checkbox is hidden/unused — no Checked/Text changes here.
}

# ---- Cut Button Flash Functions ----
function Start-CutButtonFlash {
    try {
        if ($script:btnCut -and -not $script:btnCut.IsDisposed) {
            $script:_cutFlashOn = $false
            $script:CutFlashTimer.Start()
        }
    }
    catch {}
}

function Stop-CutButtonFlash {
    try {
        if ($script:CutFlashTimer) {
            $script:CutFlashTimer.Stop()
        }
        if ($script:btnCut -and -not $script:btnCut.IsDisposed) {
            $script:btnCut.BackColor = $script:_cutDefaultBackColor
        }
    }
    catch {}
}


# Confirmation logic used before *any* music start (manual or auto)

function Maybe-ConfirmMusicStart {
    # Hard block during the meeting window (no prompt)
    if (Is-MeetingGuardActive) {
        try {
            [System.Windows.Forms.MessageBox]::Show(
                "Background music is blocked during the meeting window.",
                "Meeting Mode", 'OK', 'Information'
            ) | Out-Null
        }
        catch {}
        return $false
    }

    # Optional global “always confirm”
    if ($script:Cfg.Music.RequireConfirmAlways) {
        $r = [System.Windows.Forms.MessageBox]::Show(
            "Play Background Music?", "Confirm", 'YesNo', 'Question'
        )
        return ($r -eq [System.Windows.Forms.DialogResult]::Yes)
    }

    return $true
}

function Music-NewEngine {
    if ($script:Music.Player) { return }
    # Use WPF MediaPlayer (System.Windows.Media.MediaPlayer) — no WMP COM required.
    # Ensure PresentationCore / WindowsBase are loaded before creating the MediaPlayer.
    try { Add-Type -AssemblyName PresentationCore, WindowsBase -ErrorAction Stop } catch {}
    try {
        $script:Music.Player = New-Object System.Windows.Media.MediaPlayer
        $script:Music.Player.Volume = [double]$script:Music.Volume / 100.0
        $script:Music.Player.IsMuted = $false
        # Auto-advance to the next track when the current one ends.
        $script:Music.Player.Add_MediaEnded({
                try { if ($script:Music._IsPlaying) { Music-Advance } } catch {}
            })
        Log "Music engine initialised using WPF MediaPlayer (no WMP required)"
    }
    catch {
        Log "Music init failed: $_"
        $script:Music.Player = $null
    }
}
function Music-Dispose {
    try { if ($script:MusicTimer) { $script:MusicTimer.Stop() } } catch {}
    try { if ($script:MusicFadeTimer) { $script:MusicFadeTimer.Stop() } } catch {}
    try { if ($script:AudioMonitorTimer) { $script:AudioMonitorTimer.Stop() } } catch {}
    try { if ($script:Music.Player) { $script:Music.Player.Stop(); $script:Music.Player.Close() } } catch {}
    $script:Music.Player = $null; $script:Music.Playlist = $null
    $script:Music.Files = @(); $script:Music.CurrentIndex = -1; $script:Music._IsPlaying = $false
    $script:_fadeActive = $false
}
function Music-Advance {
    # Called when a track ends — advance to the next (or random) track.
    if (-not $script:Music._IsPlaying -or -not $script:Music.Player) { return }
    $files = $script:Music.Files
    $count = $files.Count
    if ($count -eq 0) { $script:Music._IsPlaying = $false; return }
    if ($script:Music.Shuffle) {
        $next = Get-Random -Minimum 0 -Maximum $count
        $tries = 0
        while ($next -eq $script:Music.CurrentIndex -and $count -gt 1 -and $tries -lt 6) {
            $next = Get-Random -Minimum 0 -Maximum $count; $tries++
        }
    }
    else {
        $next = ($script:Music.CurrentIndex + 1) % $count
    }
    $script:Music.CurrentIndex = $next
    $script:Music._LastStartIndex = $next
    try {
        $uri = [System.Uri]::new($files[$next])
        $script:Music.Player.Open($uri)
        $script:Music.Player.Volume = [double]$script:Music.Volume / 100.0
        $script:Music.Player.Play()
    }
    catch { $script:Music._IsPlaying = $false }
    Update-MusicButtonVisual
    Update-MusicToggleButton
}
function Music-LoadFolder([string]$Folder) {
    if (-not (Test-Path $Folder -PathType Container)) { throw "Music: Folder not found: $Folder" }
    Music-NewEngine
    if (-not $script:Music.Player) { throw "Music: MediaPlayer failed to initialize" }
    $exts = @(".mp3", ".wma", ".wav", ".m4a", ".aac", ".flac")
    $files = Get-ChildItem -Path $Folder -File -Recurse | Where-Object { $exts -contains ([IO.Path]::GetExtension($_.FullName).ToLower()) }
    if (-not $files) { throw "Music: No audio files in $Folder" }
    $script:Music.Files = @($files | ForEach-Object { $_.FullName })
    $script:Music.Playlist = $script:Music.Files  # keep .Playlist alias for compatibility
    $script:Music.CurrentIndex = -1
    $script:Music.Folder = $Folder
}
function Music-SaveState {
    # Persist the currently playing filename so the next session can avoid repeating it
    try {
        $stateFile = Join-Path (Split-Path (Get-ConfigPath)) 'music_state.json'
        @{ LastPlayedFile = $script:Music.Files[$script:Music.CurrentIndex] } |
        ConvertTo-Json | Set-Content $stateFile -Encoding UTF8 -ErrorAction Stop
    }
    catch {}
}
function Music-LoadLastPlayed {
    try {
        $stateFile = Join-Path (Split-Path (Get-ConfigPath)) 'music_state.json'
        if (Test-Path $stateFile) {
            $s = Get-Content $stateFile -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json
            return $s.LastPlayedFile
        }
    }
    catch {}
    return $null
}

function Music-Start {
    Music-NewEngine
    if (-not $script:Music.Player) { throw "Music: MediaPlayer failed to initialize" }
    try { if ($script:MusicFadeTimer.Enabled) { $script:MusicFadeTimer.Stop(); $script:_fadeActive = $false } }catch {}
    if (-not $script:Music.Files -or $script:Music.Files.Count -eq 0) {
        if (-not $script:Music.Folder) { throw "Music: No playlist. Choose a folder first." }
        Music-LoadFolder $script:Music.Folder
    }
    $count = $script:Music.Files.Count
    if ($count -eq 0) { throw "Music: No audio files found" }
    # On first start of this session, seed _LastStartIndex from the persisted last-played file
    # so we never repeat the same opening song across restarts.
    if ($null -eq $script:Music._LastStartIndex) {
        $lastFile = Music-LoadLastPlayed
        if ($lastFile) {
            $idx = [Array]::IndexOf([array]$script:Music.Files, $lastFile)
            if ($idx -ge 0) { $script:Music._LastStartIndex = $idx }
        }
    }
    $rand = Get-Random -Minimum 0 -Maximum $count
    if ($count -gt 1 -and $null -ne $script:Music._LastStartIndex) {
        $tries = 0; while ($rand -eq $script:Music._LastStartIndex -and $tries -lt 6) { $rand = Get-Random -Minimum 0 -Maximum $count; $tries++ }
    }
    $script:Music.CurrentIndex = $rand
    $script:Music._LastStartIndex = $rand
    Music-SaveState   # persist choice so next session starts on a different song
    $uri = [System.Uri]::new($script:Music.Files[$rand])
    $script:Music.Player.Open($uri)
    $script:Music.Player.Volume = [double]$script:Music.Volume / 100.0
    $script:Music.Player.IsMuted = $false
    $script:Music.Player.Play()
    $script:Music._IsPlaying = $true
}
function Music-Stop {
    if ($script:Music.Player) { $script:Music.Player.Stop(); $script:Music._IsPlaying = $false }
}
function Music-SetVolume([int]$Volume) { if ($Volume -lt 0 -or $Volume -gt 100) { throw "Volume 0..100" }; $script:Music.Volume = $Volume; if ($script:Music.Player) { $script:Music.Player.Volume = [double]$Volume / 100.0 } }
function Music-SetShuffle([bool]$Enabled) { $script:Music.Shuffle = $Enabled }
function Music-IsPlaying { return ($null -ne $script:Music.Player -and $script:Music._IsPlaying) }
function Music-FadeOut([int]$ms = 3000, [bool]$StopAfter = $true) {
    try {
        if (-not $script:Music.Player) { return }
        if (-not (Music-IsPlaying)) { if ($StopAfter) { Music-Stop }; return }
        try { $script:Music.Player.IsMuted = $false }catch {}
        $curVol = 0; try { $curVol = [int]($script:Music.Player.Volume * 100) }catch {}
        if ($curVol -le 0) { $curVol = [int]$script:Music.Volume }
        $script:_fadeStartVol = $curVol
        $script:_fadeRestoreVol = [int]$script:Music.Volume
        $script:_fadeStopAfter = $StopAfter
        $script:_fadeStartTime = Get-Date
        $script:_fadeEndTime = $script:_fadeStartTime.AddMilliseconds([math]::Max(200, $ms))
        $script:_fadeActive = $true
        $script:MusicFadeTimer.Start()
    }
    catch { Log "Fade error: $_" }
}

# visuals for toggle
function Update-MusicButtonVisual {
    try {
        if (Music-IsPlaying) {
            $btnMusicToggle.BackColor = [System.Drawing.Color]::FromArgb(0, 192, 0); $btnMusicToggle.ForeColor = [System.Drawing.Color]::Black
        }
        else {
            $btnMusicToggle.UseVisualStyleBackColor = $true; $btnMusicToggle.ForeColor = [System.Drawing.Color]::Black
        }
    }
    catch {}
}
function Update-MusicToggleButton {
    try {
        if (Music-IsPlaying) { $btnMusicToggle.Text = "⏹ Stop Music" }
        else { $btnMusicToggle.Text = "♪ Play Music" }
    }
    catch {}
}

function Update-AudioIndicator {
    try {
        if (-not $script:lblAudioStatus) { return }
        if (-not $script:Cfg.XR.DuckingEnabled) {
            $script:lblAudioStatus.Text = "XR Audio: Disabled"
            $script:lblAudioStatus.ForeColor = [System.Drawing.Color]::Gray
            return
        }
        $monCh = [int]$script:Cfg.XR.MediaChannel
        $threshDB = [double]$script:Cfg.XR.ThresholdDB
        $levelDB = -90.0
        if ($script:XrMeterLevels.Contains($monCh)) {
            $levelDB = [double]$script:XrMeterLevels[$monCh]
        }
        $levelText = $levelDB.ToString('F1')
        if ($levelDB -gt $threshDB) {
            $script:lblAudioStatus.Text = "XR Audio CH${monCh}: ACTIVE ($levelText dB  thr: $($threshDB)dB)"
            $script:lblAudioStatus.ForeColor = [System.Drawing.Color]::LimeGreen
        }
        else {
            $script:lblAudioStatus.Text = "XR Audio CH${monCh}: Silent ($levelText dB  thr: $($threshDB)dB)"
            $script:lblAudioStatus.ForeColor = [System.Drawing.Color]::DarkGray
        }
    }
    catch {}
}

$script:MusicTimer.Add_Tick({ 
        if ($script:ShuttingDown) { return }
        try {
            Update-MusicButtonVisual
            Update-MusicToggleButton
        }
        catch {}
    })

# --------- UI ----------
# UI scale state
$script:_uiScaleLevel = 0
$script:_currentUIScale = 1.0
$script:_mixerOpenScale = 1.0    # Scale at which the mixer panel was last opened
$script:_baseFontSizePt = 10.0
$script:_baseMinW = 600
$script:_baseMinH = 520
$script:_btnResize = $null

$script:form = New-Object System.Windows.Forms.Form
$script:form.Text = "JWL Assistant v6.1.8e "
$script:form.FormBorderStyle = 'FixedSingle'
$script:form.MaximizeBox = $false
$script:form.MinimizeBox = $false
$script:form.SizeGripStyle = 'Hide'   # no drag-resize grip
$script:form.MinimumSize = Sz 600 520
$script:form.AutoScaleMode = 'Dpi'       # nicer on HiDPI screens
$script:form.Font = New-Object System.Drawing.Font("Segoe UI", 10)
$script:form.ClientSize = Sz 600 680
$script:form.StartPosition = "Manual"
try { $script:form.Location = (Ensure-OnScreen $script:Cfg.WindowX $script:Cfg.WindowY) } catch {
    $p = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $script:form.Location = New-Object System.Drawing.Point ($p.Left + 100), ($p.Top + 100)
}

# Status bar
$status = New-Object System.Windows.Forms.StatusStrip
$script:statusStrip = $status
$script:sbLeft = New-Object System.Windows.Forms.ToolStripStatusLabel; $script:sbLeft.Text = "Idle"; $script:sbLeft.Spring = $true
[void]$status.Items.Add($script:sbLeft)

# Small green/red dot bitmaps for XR status
function New-DotBitmap([System.Drawing.Color]$color) {
    $bmp = New-Object System.Drawing.Bitmap 10, 10
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.Clear([System.Drawing.Color]::Transparent)
    $b = New-Object System.Drawing.SolidBrush($color)
    $g.FillEllipse($b, 0, 0, 9, 9)
    $b.Dispose(); $g.Dispose()
    return $bmp
}
$bmpGreen = New-DotBitmap ([System.Drawing.Color]::LimeGreen)
$bmpRed = New-DotBitmap ([System.Drawing.Color]::Tomato)
$bmpOrange = New-DotBitmap ([System.Drawing.Color]::Gold)


$sbXR = New-Object System.Windows.Forms.ToolStripStatusLabel
$sbXR.Text = "XR: Offline"; $sbXR.Image = $bmpRed
$sbXR.Visible = [bool]$script:Cfg.XR.XRMixerEnabled
[void]$status.Items.Add($sbXR)

$script:form.Controls.Add($status)

# Clock
$btnClock = New-Object System.Windows.Forms.Button
$btnClock.Enabled = $false
$btnClock.Font = New-Object System.Drawing.Font("Segoe UI", 18, [System.Drawing.FontStyle]::Bold)
$btnClock.Size = Sz 250 40
$btnClock.Location = Pt 14 12
$btnClock.Text = (Get-Date).ToString("hh:mm:ss tt")
$btnClock.UseVisualStyleBackColor = $false
$btnClock.FlatStyle = 'Flat'
$btnClock.FlatAppearance.BorderSize = 1
$btnClock.BackColor = [Drawing.Color]::FromArgb(128, 128, 128)          # Same grey as Zoom control buttons
$btnClock.ForeColor = [Drawing.Color]::White
$btnClock.FlatAppearance.BorderColor = [Drawing.Color]::FromArgb(96, 96, 96)
$script:_clockDefaultBackColor = $btnClock.BackColor
# Apply slight rounded corners to clock for modern look
Set-RoundedCorners $btnClock 8
$script:form.Controls.Add($btnClock)
$script:_btnClock = $btnClock   # expose for Apply-UIScale
$clockTimer = New-Object System.Windows.Forms.Timer
$clockTimer.Interval = 1000
$clockTimer.Add_Tick({ 
        if ($script:ShuttingDown) { return }
        # Skip text update when meetingTimer is driving a countdown display
        if (-not $script:_clockCountdownMode) {
            try { $btnClock.Text = (Get-Date).ToString("hh:mm:ss tt") } catch {}
        }
    })
$clockTimer.Start()

# Next meeting readout
$lblNext = New-Object System.Windows.Forms.Label
$lblNext.AutoSize = $false
$lblNext.Font = New-Object Drawing.Font('Microsoft Sans Serif', 10)
$lblNext.Size = Sz 220 20
$lblNext.Location = Pt ($btnClock.Right + 8) ([int]($btnClock.Top + ($btnClock.Height - $lblNext.Height) / 2))
$lblNext.AutoEllipsis = $true

$lblNext.Text = "Next: —"
$script:form.Controls.Add($lblNext)
# Meeting Mode toggle (starts a 95-min guard by default)
$chkMeetingMode = New-Object System.Windows.Forms.CheckBox
$chkMeetingMode.AutoSize = $true
$chkMeetingMode.Text = 'Meeting Mode'
$chkMeetingMode.Location = Pt ($btnClock.Right + 8) ($lblNext.Bottom + 6)
$script:form.Controls.Add($chkMeetingMode)
$chkMeetingMode.Visible = $false


# Tick timer updates the label with remaining time and auto-stops when done
$meetingTickTimer = New-Object System.Windows.Forms.Timer
$meetingTickTimer.Interval = 1000
$meetingTickTimer.Add_Tick({
        if ($script:ShuttingDown) { return }
        try {
            if (-not (Is-MeetingGuardActive)) { Stop-MeetingGuard; return }
            $left = $script:MeetingGuardUntil - (Get-Date)
            $mm = [int][math]::Floor($left.TotalMinutes)
            $ss = [int]($left.Seconds)
            if ($mm -lt 0) { Stop-MeetingGuard; return }
            if ($chkMeetingMode) { $chkMeetingMode.Text = ("Meeting Mode ({0:00}:{1:00})" -f $mm, $ss) }
        }
        catch {}
    })

$chkMeetingMode.Add_CheckedChanged({
        try {
            if ($chkMeetingMode.Checked) { Start-MeetingGuard $script:Cfg.Meeting.GuardMinutes }
            else { Stop-MeetingGuard }
        }
        catch {}
    })


# --- UI Resize button (left of theme button) ---
$script:_btnResize = New-Object System.Windows.Forms.Button
$script:_btnResize.Size = Sz 36 36
$script:_btnResize.FlatStyle = 'Flat'
$script:_btnResize.FlatAppearance.BorderSize = 1
$script:_btnResize.UseVisualStyleBackColor = $false
$script:_btnResize.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$script:_btnResize.Text = 'S'
$script:_btnResize.Location = Pt ([int]($script:form.ClientSize.Width - 36 - 14 - 36 - 4)) ([int]($btnClock.Top - 2))
# Resize context menu
$_ctxScale = New-Object System.Windows.Forms.ContextMenuStrip
$_miS = New-Object System.Windows.Forms.ToolStripMenuItem; $_miS.Text = 'Standard (100%)'
$_miM = New-Object System.Windows.Forms.ToolStripMenuItem; $_miM.Text = 'Medium  (125%)'
$_miL = New-Object System.Windows.Forms.ToolStripMenuItem; $_miL.Text = 'Large   (150%)'
[void]$_ctxScale.Items.Add($_miS)
[void]$_ctxScale.Items.Add($_miM)
[void]$_ctxScale.Items.Add($_miL)
$_miS.Add_Click({ Apply-UIScale 0; $script:Cfg.UI.ScaleLevel = 0; Save-Settings | Out-Null })
$_miM.Add_Click({ Apply-UIScale 1; $script:Cfg.UI.ScaleLevel = 1; Save-Settings | Out-Null })
$_miL.Add_Click({ Apply-UIScale 2; $script:Cfg.UI.ScaleLevel = 2; Save-Settings | Out-Null })
$script:_btnResize.Add_Click({ $_ctxScale.Show($script:_btnResize, 0, $script:_btnResize.Height) })
Set-RoundedCorners $script:_btnResize 18
$script:form.Controls.Add($script:_btnResize)

# --- Manual theme toggle button (top-right) ---
$btnTheme = New-Object System.Windows.Forms.Button
$btnTheme.Size = Sz 36 36
$btnTheme.FlatStyle = 'Flat'
$btnTheme.FlatAppearance.BorderSize = 1
$btnTheme.UseVisualStyleBackColor = $false
$btnTheme.Font = New-Object System.Drawing.Font("Segoe UI Emoji", 14)
# place at far right; keep it there on resize
$btnTheme.Location = Pt ([int]($script:form.ClientSize.Width - $btnTheme.Width - 14)) ([int]($btnClock.Top - 2))
$script:form.Add_Resize({
        try {
            $btnTheme.Location = Pt ([int]($script:form.ClientSize.Width - $btnTheme.Width - 14)) ([int]($btnClock.Top - 2))
            $script:_btnResize.Location = Pt ([int]($script:form.ClientSize.Width - $btnTheme.Width - 14 - $script:_btnResize.Width - 4)) ([int]($btnClock.Top - 2))
        }
        catch {}
    })
# Apply rounded corners to theme button
Set-RoundedCorners $btnTheme 18  # Make it round
$script:form.Controls.Add($btnTheme)
$script:_btnTheme = $btnTheme   # expose for Apply-UIScale


# 1) $btnTheme is already created above this block

# 2) Define it (keep as-is)

function Apply-Theme-FromCfg {
    $dark = ([string]$script:Cfg.UI.Theme -eq 'Dark')
    Enable-DarkMode $script:form $dark
    try { Sync-ObsPreviewTheme } catch {}
    if ($btnTheme) {
        $btnTheme.Text = $(if ($dark) { '☀' }else { '🌙' })
        $btnTheme.ForeColor = [Drawing.Color]::Goldenrod
    }
}

function Sync-ObsPreviewTheme {
    $dark = ([string]$script:Cfg.UI.Theme -eq 'Dark')
    $previewBack = if ($dark) { [Drawing.Color]::FromArgb(0x18, 0x18, 0x18) } else { [Drawing.Color]::FromArgb(245, 245, 245) }
    $hintFore = if ($dark) { [Drawing.Color]::FromArgb(0xB0, 0xB0, 0xB0) } else { [Drawing.SystemColors]::GrayText }

    try { if ($script:pPreview) { $script:pPreview.BackColor = $previewBack } } catch {}
    try { if ($script:pbObs) { $script:pbObs.BackColor = $previewBack } } catch {}
    try {
        if ($script:lblHint) {
            $script:lblHint.BackColor = [Drawing.Color]::Transparent
            $script:lblHint.ForeColor = $hintFore
        }
    }
    catch {}
}

# 3) Click handler (keep as-is)
$btnTheme.Add_Click({
        try {
            $script:Cfg.UI.Theme = $(if ([string]$script:Cfg.UI.Theme -eq 'Dark') { 'Light' }else { 'Dark' })
            Apply-Theme-FromCfg
            Save-Settings | Out-Null
        }
        catch {}
    })

# 4) Apply once at startup (AFTER the function exists)
try { Apply-Theme-FromCfg } catch {}

# ---- UI Scale function ----
function Apply-UIScale([int]$level) {
    $scales = @(1.0, 1.25, 1.5)
    $labels = @('S', 'M', 'L')
    if ($level -lt 0 -or $level -gt 2) { $level = 0 }
    $newScale = [double]$scales[$level]
    $curScale = [double]$script:_currentUIScale
    # Always update button label
    if ($script:_btnResize -and -not $script:_btnResize.IsDisposed) {
        $script:_btnResize.Text = $labels[$level]
    }
    if ([Math]::Abs($newScale - $curScale) -lt 0.001) { return }
    $ratio = [float]($newScale / $curScale)
    try { $script:form.SuspendLayout() } catch {}
    # Scale all controls and the form ClientSize proportionally
    $script:form.Scale([System.Drawing.SizeF]::new($ratio, $ratio))
    # Update base font so inherited-font controls resize their text
    $newFontSize = [float]($script:_baseFontSizePt * $newScale)
    $script:form.Font = New-Object System.Drawing.Font('Segoe UI', $newFontSize)
    # Update MinimumSize
    $newMinW = [int]([Math]::Ceiling($script:_baseMinW * $newScale))
    $newMinH = [int]([Math]::Ceiling($script:_baseMinH * $newScale))
    $script:form.MinimumSize = New-Object System.Drawing.Size($newMinW, $newMinH)
    try { $script:form.ResumeLayout($true) } catch {}
    $script:_currentUIScale = $newScale
    $script:_uiScaleLevel = $level
    # Re-anchor the top-right buttons — Form.Scale() can mis-position them
    try {
        $bCk = $script:_btnClock; $bTh = $script:_btnTheme; $bRz = $script:_btnResize
        if ($bCk -and -not $bCk.IsDisposed -and $bTh -and -not $bTh.IsDisposed) {
            $bTh.Location = Pt ([int]($script:form.ClientSize.Width - $bTh.Width - 14)) ([int]($bCk.Top - 2))
        }
        if ($bCk -and -not $bCk.IsDisposed -and $bRz -and -not $bRz.IsDisposed -and $bTh -and -not $bTh.IsDisposed) {
            $bRz.Location = Pt ([int]($script:form.ClientSize.Width - $bTh.Width - 14 - $bRz.Width - 4)) ([int]($bCk.Top - 2))
        }
    }
    catch {}
    # Re-anchor gear button (bottom-right)
    try { Place-Gear } catch {}
    # Scale the mixer panel if it is open — close and reopen so it rebuilds at correct size
    if ($script:_mixerPanel -and -not $script:_mixerPanel.IsDisposed) {
        try {
            $script:_mixerReopeningForScale = $true
            Hide-MixerPanel
            $script:_mixerReopenTimer = New-Object System.Windows.Forms.Timer
            $script:_mixerReopenTimer.Interval = 150
            $script:_mixerReopenTimer.Add_Tick({
                    $script:_mixerReopenTimer.Stop()
                    $script:_mixerReopenTimer.Dispose()
                    $script:_mixerReopeningForScale = $false
                    try { Show-MixerPanel } catch {}
                })
            $script:_mixerReopenTimer.Start()
        }
        catch {}
    }
    # Re-apply rounded corners — Form.Scale() does not reliably re-fire Resize on all controls
    try {
        foreach ($entry in $script:_roundedControls) {
            try {
                if ($entry.Control -and -not $entry.Control.IsDisposed) {
                    [RoundedButton]::MakeRounded($entry.Control, $entry.Radius)
                }
            }
            catch {}
        }
    }
    catch {}
}


function Style-StatusChip {
    try {
        if ($script:chip) {
            $script:chip.UseVisualStyleBackColor = $false
            $script:chip.BackColor = [Drawing.Color]::FromArgb(128, 128, 128)
            $script:chip.ForeColor = [Drawing.Color]::White
            $script:chip.FlatAppearance.BorderColor = [Drawing.Color]::FromArgb(96, 96, 96)
        }
    }
    catch {}
}
Style-StatusChip

# ===================== TOOLTIPS =====================
# Create tooltip component for hover help text
$script:tooltip = New-Object System.Windows.Forms.ToolTip
$script:tooltip.AutoPopDelay = 5000  # Show for 5 seconds
$script:tooltip.InitialDelay = 800   # Wait 0.8 seconds before showing
$script:tooltip.ReshowDelay = 500    # Wait 0.5 seconds before showing again
$script:tooltip.ShowAlways = $true   # Show even when form does not have focus

# Set tooltips for all buttons (will be configured after buttons are created)
function Set-AllTooltips {
    $tt = $script:tooltip
    # Each SetToolTip is individually guarded so one null/missing control
    # cannot cascade and silence every subsequent tooltip.
    try { $tt.SetToolTip($btnClock, "Current time. 5 min before meeting: shows countdown (green→yellow→red flash)") } catch {}
    try { $tt.SetToolTip($lblNext, "Countdown to next scheduled meeting") } catch {}
    try { $tt.SetToolTip($btnTheme, "Switch between Dark and Light themes") } catch {}

    try { $tt.SetToolTip($btnAuto, "Enable automatic scene switching based on keyword detection (requires Tesseract OCR and ROI setup)") } catch {}
    try { $tt.SetToolTip($script:chip, "OCR detection status: Present (keyword found) or Absent (keyword not found)") } catch {}
    try { $tt.SetToolTip($script:btnObsWS, "Connect to OBS WebSocket (auto-reconnects every 2 seconds if disconnected)") } catch {}

    try { $tt.SetToolTip($lblProgram, "Currently active scene in OBS Program output") } catch {}
    try { $tt.SetToolTip($btnBlank, "Quick switch to currently selected scene") } catch {}
    try { $tt.SetToolTip($btnCut, "Switch selected scene to Program (live output)") } catch {}
    try { $tt.SetToolTip($lblPicker, "ScenePicker: Shows available scenes for switching (right-click Camera for scene picker)") } catch {}
    try { $tt.SetToolTip($script:btnCam, "Left-click: Switch to Speaker scene | Right-click: Open scene picker") } catch {}
    try { $tt.SetToolTip($script:btnMed, "Switch to Media scene for video playback") } catch {}

    try { $tt.SetToolTip($btnMusicToggle, "Start/Stop background music (auto-stops before meetings in Meeting Mode)") } catch {}
    try { $tt.SetToolTip($btnOBSRecord, "Start/Stop OBS Recording — click to start (turns red), click again to confirm stop and save") } catch {}
    try { $tt.SetToolTip($btnZoomJoin, "Launch Zoom and automatically join meeting with configured settings") } catch {}
    try { $tt.SetToolTip($script:lblUpdateStatus, "App update status. Click to check now, or open release page when an update is available") } catch {}
    try { $tt.SetToolTip($script:btnZoomToggle, "Toggle Zoom media window to second monitor | Click to open menu (choose monitor, project/restore)") } catch {}

    # NOTE: $btnJwlMonitor tooltip is owned exclusively by $script:_ocrAlertTip
    # (via Update-JwlOcrTooltip). Do NOT register it here — two ToolTip objects
    # on the same control fight each other and break both tooltips.

    try { $tt.SetToolTip($btnHandAlert, "Raised Hand Alert: click to show a full-screen hand emoji on the selected monitor for 30 seconds (flashes until dismissed or timed out)") } catch {}
    try { $tt.SetToolTip($script:btnSettingsGear, "Configure OBS connection, OCR settings, meeting times, XR mixer, and more") } catch {}

    try { Update-ZoomStatusTooltips } catch {}
}

# ===================== OBS PREVIEW -> INSIDE pPreview (AUTO) =====================
# Renders OBS Preview/Program into $script:pPreview using obs-websocket v5 screenshots.
# Auto-connects & retries; no Start/Stop buttons needed.
# Works on Windows PowerShell 5.1 (no external modules)

# ---- Panel (keeps your original size/position/colors) ----
$script:pPreview = New-Object System.Windows.Forms.Panel
$script:pPreview.Location = Pt 14 68
$script:pPreview.Size = Sz 570 350
$script:pPreview.BorderStyle = 'FixedSingle'
$script:pPreview.BackColor = [System.Drawing.Color]::FromArgb(245, 245, 245)
# Apply slight rounded corners to preview panel for modern Windows-like appearance
Set-RoundedCorners $script:pPreview 8
$script:form.Controls.Add($script:pPreview)

# --- Clean shutdown to avoid JIT/runspace errors on close (UNIFIED) ---
if ($script:form) {
    $cleanup = {
        try { $script:ShuttingDown = $true } catch {}

        # Small helper to stop & dispose timers safely
        function _StopDisposeTimer([object]$t) {
            try { if ($t) { $t.Stop(); $t.Dispose() } } catch {}
        }

        # Timers
        try { _StopDisposeTimer $script:obsTimer } catch {}
        try { _StopDisposeTimer $script:obsAutoTimer } catch {}
        try { _StopDisposeTimer $script:obsPingTimer } catch {}
        try { _StopDisposeTimer $autoGuardTimer } catch {}
        try { _StopDisposeTimer $meetingTickTimer } catch {}
        try { _StopDisposeTimer $clockTimer } catch {}
        try { _StopDisposeTimer $script:MusicTimer } catch {}
        try { _StopDisposeTimer $script:MusicFadeTimer } catch {}
        try { _StopDisposeTimer $script:xrTimer } catch {}
        try { _StopDisposeTimer $scanTimer } catch {}
        try { _StopDisposeTimer $script:meetingTimer } catch {}
        try { _StopDisposeTimer $script:_ptzRepeatTimer } catch {}
        try { _StopDisposeTimer $script:_ptzHoverTimer } catch {}
        try { _StopDisposeTimer $script:_afTimer } catch {}
        try { _StopDisposeTimer $script:_jwlOcrTimer } catch {}
        try { if ($script:afRoiPen) { $script:afRoiPen.Dispose() } } catch {}

        # Preview image/picturebox
        try {
            if ($script:pbObs) {
                $script:pbObs.Image = $null
                $script:pbObs.Dispose()
                $script:pbObs = $null
            }
        }
        catch {}

        # Close OBS socket & mark offline (use unified Close-Obs if present)
        try { Close-Obs } catch {}
        try { $script:ObsWS = $null } catch {}
        try { $script:ObsConnected = $false } catch {}

        # Close any reminder popups
        try { Dismiss-AllReminders } catch {}

        # Dispose music engine/COM cleanly
        try { Music-Dispose } catch {}

        # Dispose update tray icon (if used for Windows notifications)
        try {
            if ($script:UpdateNotifyIcon) {
                $script:UpdateNotifyIcon.Visible = $false
                $script:UpdateNotifyIcon.Dispose()
                $script:UpdateNotifyIcon = $null
            }
        }
        catch {}

        # Ensure the WinForms message loop exits
        try { [System.Windows.Forms.Application]::Exit() } catch {}
    }

    if (-not $script:__obsCleanupBound) {
        # $script:form.Add_FormClosing($cleanup)  # Let explicit handler run first
        $script:form.Add_Disposed($cleanup)
        $script:__obsCleanupBound = $true
    }
}


# Status / hint label (visible until first image arrives)
if ($script:lblHint -and $script:lblHint -is [System.Windows.Forms.Label]) { try { $script:lblHint.Dispose() } catch {} }
$script:lblHint = New-Object System.Windows.Forms.Label
$script:lblHint.AutoSize = $true
$script:lblHint.Text = "Waiting for OBS..."
$script:lblHint.Location = Pt 110 150
$script:pPreview.Controls.Add($script:lblHint)

# PictureBox target that fills the panel
if ($script:pbObs -and $script:pbObs -is [System.Windows.Forms.PictureBox]) { try { $script:pbObs.Dispose() } catch {} }
$script:pbObs = New-Object System.Windows.Forms.PictureBox
$script:pbObs.Dock = 'Fill'
$script:pbObs.SizeMode = 'Zoom'
$script:pbObs.BackColor = [System.Drawing.Color]::FromArgb(245, 245, 245)
$script:pPreview.Controls.Add($script:pbObs)
$script:pbObs.BringToFront()

try { Sync-ObsPreviewTheme } catch {}

# after you add the PictureBox & BringToFront the PB, add:
# (we want label on top while offline, so bring label front last)
try { $script:lblHint.BringToFront() } catch {}

# ==================== PTZ Overlay Controls ====================
# Subtle directional arrow controls overlaid on the preview panel.
# Invisible at rest → appear when the mouse enters the preview.
# Hold any arrow/zoom button to move continuously.
# Uses OBS WebSocket TriggerHotkeyByKeySequence — goes through OBS's own
# hotkey engine, no focus stealing, no window message injection needed.

function Send-OBSHotkeyKey([string]$obsKeyId) {
    # Fire-and-forget: do NOT use Invoke-ObsRequest (blocks UI thread waiting for response).
    # TriggerHotkeyByKeySequence has no meaningful response we need to act on.
    $script:reqCounter++
    $payload = @{
        op = 6
        d  = @{
            requestType = 'TriggerHotkeyByKeySequence'
            requestId   = "ptz-$($script:reqCounter)"
            requestData = @{
                keyId        = $obsKeyId
                keyModifiers = @{ shift = $false; control = $false; alt = $false; command = $false }
            }
        }
    }
    try { Send-ObsJson $payload | Out-Null } catch { Log "PTZ key error: $_" }
}

# Repeat timer – keeps triggering the hotkey while a button is held
$script:_ptzRepeatTimer = New-Object System.Windows.Forms.Timer
$script:_ptzRepeatTimer.Interval = 30
$script:_ptzActiveKey = ''
$script:_ptzRepeatTimer.Add_Tick({
        if ($script:_ptzActiveKey -ne '') { Send-OBSHotkeyKey $script:_ptzActiveKey }
    })

function Start-PTZRepeat([string]$keyId) {
    $script:_ptzActiveKey = $keyId
    Log "PTZ: $keyId"
    Send-OBSHotkeyKey $keyId      # fire once immediately, then repeat via timer
    $script:_ptzRepeatTimer.Start()
}

function Stop-PTZRepeat {
    $script:_ptzRepeatTimer.Stop()
    $script:_ptzActiveKey = ''
}

# Shared style objects at script scope so event handlers can access them
$script:_ptzColorDim = [System.Drawing.Color]::FromArgb(150, 150, 150)
$script:_ptzColorBright = [System.Drawing.Color]::White
$script:_ptzBackDim = [System.Drawing.Color]::FromArgb(40, 40, 40)
$script:_ptzBackBright = [System.Drawing.Color]::FromArgb(75, 75, 75)
$script:_ptzFontNorm = New-Object System.Drawing.Font('Segoe UI Symbol', 13, [System.Drawing.FontStyle]::Regular)
$script:_ptzFontBold = New-Object System.Drawing.Font('Segoe UI Symbol', 15, [System.Drawing.FontStyle]::Bold)

# List of all PTZ overlay buttons (used by hover tracker)
$script:_ptzButtons = New-Object System.Collections.Generic.List[System.Windows.Forms.Button]

function New-PTZButton([string]$symbol, [int]$x, [int]$y, [int]$w, [int]$h, [string]$keyId) {
    $btn = New-Object System.Windows.Forms.Button
    $btn.Text = $symbol
    $btn.Font = $script:_ptzFontNorm
    $btn.Size = [System.Drawing.Size]::new($w, $h)
    $btn.Location = [System.Drawing.Point]::new($x, $y)
    $btn.FlatStyle = 'Flat'
    $btn.FlatAppearance.BorderSize = 0
    $btn.FlatAppearance.MouseOverBackColor = $script:_ptzBackBright
    $btn.FlatAppearance.MouseDownBackColor = [System.Drawing.Color]::FromArgb(100, 100, 100)
    $btn.BackColor = $script:_ptzBackDim
    $btn.ForeColor = $script:_ptzColorDim
    $btn.Cursor = [System.Windows.Forms.Cursors]::Hand
    $btn.TabStop = $false
    $btn.Visible = $false
    # OBS key ID stored in Tag – avoids PS closure-variable capture issues
    $btn.Tag = $keyId

    $btn.Add_MouseDown({
            Start-PTZRepeat ([string]$args[0].Tag)
        })
    $btn.Add_MouseUp({ Stop-PTZRepeat })
    $btn.Add_MouseEnter({
            $b = $args[0]
            $b.ForeColor = $script:_ptzColorBright
            $b.BackColor = $script:_ptzBackBright
            $b.Font = $script:_ptzFontBold
        })
    $btn.Add_MouseLeave({
            Stop-PTZRepeat
            $b = $args[0]
            $b.ForeColor = $script:_ptzColorDim
            $b.BackColor = $script:_ptzBackDim
            $b.Font = $script:_ptzFontNorm
        })

    $script:pPreview.Controls.Add($btn)
    $btn.BringToFront()
    $script:_ptzButtons.Add($btn)
    return $btn
}

# D-pad layout – lower-right quadrant of the 570×350 preview panel
# OBS key IDs match the hotkeys configured in OBS Settings → Hotkeys → PTZ
New-PTZButton '▲' 448 248 44 33  'OBS_KEY_UP'       | Out-Null   # Tilt Up
New-PTZButton '▼' 448 289 44 33  'OBS_KEY_DOWN'     | Out-Null   # Tilt Down
New-PTZButton '◄' 402 268 44 33  'OBS_KEY_LEFT'     | Out-Null   # Pan Left
New-PTZButton '►' 492 268 44 33  'OBS_KEY_RIGHT'    | Out-Null   # Pan Right
New-PTZButton '+' 539 255 26 26  'OBS_KEY_NUMPLUS'  | Out-Null   # Zoom In  (Num +)
New-PTZButton '−' 539 283 26 26  'OBS_KEY_NUMMINUS' | Out-Null   # Zoom Out (Num -)

# Hover tracker: polls mouse position every 100 ms and shows/hides the
# overlay buttons whenever the cursor is inside the preview panel
$script:_ptzHoverTimer = New-Object System.Windows.Forms.Timer
$script:_ptzHoverTimer.Interval = 100
$script:_ptzHoverTimer.Add_Tick({
        try {
            if ($script:pPreview -and $script:pPreview.IsHandleCreated) {
                $sr = $script:pPreview.RectangleToScreen($script:pPreview.ClientRectangle)
                $inside = $sr.Contains([System.Windows.Forms.Control]::MousePosition)
                foreach ($b in $script:_ptzButtons) {
                    if (-not $b.IsDisposed) { $b.Visible = $inside }
                }
            }
        }
        catch {}
    })
$script:_ptzHoverTimer.Start()

# ==================== AUTO-FRAME ENGINE v2 ====================
# Scans green ROI for a person. On detection → zoom+tilt to frame face.
# After 3 s stable → LOCKED (completely stops moving).
# Face gone 2 s → reverses all zoom/tilt pulses → back to IDLE.
# No left/right pan. No continuous tracking once locked.
# ROI set separately from AF activation (Set ROI button).

# ---- Helper: Rectangle constructor ----
function _AFRect([int]$x, [int]$y, [int]$w, [int]$h) { New-Object System.Drawing.Rectangle $x, $y, $w, $h }


# ---- AF state variables ----
$script:afEnabled = $false    # user on/off
$script:afWasEnabled = $false # remembered state across non-Speaker scenes
$script:afRoiVisible = $false  # whether ROI box shows while AF is off (init here, before pending restore below)
$script:afSceneActive = $false    # OBS scene matches AF_SCENE_NAME
$script:AF_SCENE_NAME = 'Speaker'
# Click-to-center state
$script:afClickPt = $null   # last clicked point (Point) shown as red crosshair
$script:afPanPulses = 0       # remaining horizontal pulses (+ve = RIGHT, -ve = LEFT)
$script:afTiltPulses = 0       # remaining vertical pulses   (+ve = DOWN,  -ve = UP)
$script:afSpeed = 80         # max pulses when clicking at ROI edge (tune with +/- buttons)

# ROI (initially covers most of the 570×350 preview)
$script:afRoi = (_AFRect 70 20 430 305)
# Apply saved ROI from Load-Settings (couldn't be applied earlier — _AFRect wasn't defined yet)
if ($script:_pendingAfRoi) {
    $script:afRoi = (_AFRect $script:_pendingAfRoi.X $script:_pendingAfRoi.Y $script:_pendingAfRoi.W $script:_pendingAfRoi.H)
    Log "Auto Frame: ROI restored X=$($script:_pendingAfRoi.X) Y=$($script:_pendingAfRoi.Y) W=$($script:_pendingAfRoi.W) H=$($script:_pendingAfRoi.H)"
    $script:_pendingAfRoi = $null
}
if ($script:_pendingAfSpeed -and [int]$script:_pendingAfSpeed -gt 0) {
    $script:afSpeed = [int]$script:_pendingAfSpeed
    $script:_pendingAfSpeed = $null
}
if ($null -ne $script:_pendingAfEnabled) {
    $script:afEnabled = [bool]$script:_pendingAfEnabled
    $script:_pendingAfEnabled = $null
}
if ($null -ne $script:_pendingAfRoiVisible) {
    $script:afRoiVisible = [bool]$script:_pendingAfRoiVisible
    $script:_pendingAfRoiVisible = $null
}
$script:afRoiPen = New-Object System.Drawing.Pen([System.Drawing.Color]::LimeGreen, 2)
$script:afHandleSz = 9
$script:afDragging = $false
$script:afResizing = -1
$script:afDragOff = $null
$script:afResizeOrig = $null

function Get-AfHandles {
    $r = $script:afRoi; $h = $script:afHandleSz; $half = [int]($h / 2)
    return @(
        (_AFRect ($r.Left - $half) ($r.Top - $half) $h $h),  # 0 TL
        (_AFRect ($r.Right - $half) ($r.Top - $half) $h $h),  # 1 TR
        (_AFRect ($r.Left - $half) ($r.Bottom - $half) $h $h),  # 2 BL
        (_AFRect ($r.Right - $half) ($r.Bottom - $half) $h $h)   # 3 BR
    )
}

function Reset-AfState {
    $script:afClickPt = $null
    $script:afPanPulses = 0
    $script:afTiltPulses = 0
}

# ---- Paint: green ROI + yellow face + state label ----
$script:pbObs.Add_Paint({
        param($s, $e)
        # Show ROI box whenever afEnabled OR when just setting ROI (afRoiVisible)
        if (-not $script:afEnabled -and -not $script:afRoiVisible) { return }
        try {
            $g = $e.Graphics
            $g.DrawRectangle($script:afRoiPen, $script:afRoi)
            # Drag handles
            foreach ($hRect in (Get-AfHandles)) {
                $g.FillRectangle([System.Drawing.Brushes]::LimeGreen, $hRect)
            }
            if (-not $script:afEnabled) { return }   # crosshair + label only when active
            # ROI centre guide lines (dim green)
            $rcx2 = $script:afRoi.X + [int]($script:afRoi.Width / 2)
            $rcy2 = $script:afRoi.Y + [int]($script:afRoi.Height / 2)
            $dc = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(60, 0, 220, 0), 1)
            try {
                $g.DrawLine($dc, $script:afRoi.X, $rcy2, $script:afRoi.Right, $rcy2)
                $g.DrawLine($dc, $rcx2, $script:afRoi.Y, $rcx2, $script:afRoi.Bottom)
            }
            finally { $dc.Dispose() }
            # Last clicked point — red crosshair
            if ($script:afClickPt) {
                $cp2 = New-Object System.Drawing.Pen([System.Drawing.Color]::Red, 1)
                try {
                    $cx3 = $script:afClickPt.X; $cy3 = $script:afClickPt.Y
                    $g.DrawLine($cp2, ($cx3 - 8), $cy3, ($cx3 + 8), $cy3)
                    $g.DrawLine($cp2, $cx3, ($cy3 - 8), $cx3, ($cy3 + 8))
                }
                finally { $cp2.Dispose() }
            }
            # Status label
            $moving = ($script:afPanPulses -ne 0 -or $script:afTiltPulses -ne 0)
            $lColor = if ($moving) { [System.Drawing.Brushes]::Yellow } else { [System.Drawing.Brushes]::LimeGreen }
            $lText = if ($moving) { 'AF: MOVING' } else { 'AF: READY' }
            $g.DrawString($lText, $script:_ptzFontNorm, $lColor, ($script:afRoi.X + 4), ($script:afRoi.Y + 4))
        }
        catch {}
    })

# ---- Mouse: drag / resize ROI (active when enabled OR roi-visible) ----
$script:pbObs.Add_MouseDown({
        param($s, $e)
        if (-not $script:afEnabled -and -not $script:afRoiVisible) { return }
        if ($e.Button -ne [System.Windows.Forms.MouseButtons]::Left) { return }
        # Use PointToClient(MousePosition) — more reliable than $e.Location in PS5.1 scriptblock handlers
        $pt = $script:pbObs.PointToClient([System.Windows.Forms.Control]::MousePosition)
        if ($script:afRoiVisible) {
            # ROI edit mode: check resize handles first, then drag
            $handles = Get-AfHandles
            for ($i = 0; $i -lt $handles.Count; $i++) {
                if ($handles[$i].Contains($pt)) {
                    $script:afResizing = $i
                    $script:afResizeOrig = $script:afRoi
                    return
                }
            }
            if ($script:afRoi.Contains($pt)) {
                $script:afDragging = $true
                $script:afDragOff = New-Object System.Drawing.Point ($pt.X - $script:afRoi.X), ($pt.Y - $script:afRoi.Y)
            }
        }
        elseif ($script:afEnabled -and $script:afRoi.Contains($pt)) {
            # AF active: tilt only — up/down based on vertical distance from ROI centre
            $rcy3 = $script:afRoi.Y + $script:afRoi.Height / 2.0
            $ndy = ($pt.Y - $rcy3) / ($script:afRoi.Height / 2.0)
            $script:afPanPulses = 0   # pan disabled
            $script:afTiltPulses = [int][Math]::Round($ndy * $script:afSpeed)
            # Crosshair snaps to ROI horizontal centre so it shows only vertical offset
            $rcx3 = $script:afRoi.X + [int]($script:afRoi.Width / 2)
            $script:afClickPt = New-Object System.Drawing.Point $rcx3, $pt.Y
            Log "AF: centering — tilt=$($script:afTiltPulses)"
            try { $script:pbObs.Invalidate() } catch {}
        }
    })

$script:pbObs.Add_MouseMove({
        param($s, $e)
        if (-not $script:afEnabled -and -not $script:afRoiVisible) { return }
        $pt = $e.Location
        $pw = $script:pbObs.Width; $ph = $script:pbObs.Height
        if ($script:afResizing -ge 0 -and $script:afResizeOrig) {
            $r = $script:afResizeOrig
            $nx = $r.X; $ny = $r.Y; $nw = $r.Width; $nh = $r.Height
            if ($script:afResizing -eq 0) { $nx = $pt.X; $ny = $pt.Y; $nw = $r.Right - $pt.X; $nh = $r.Bottom - $pt.Y }
            if ($script:afResizing -eq 1) { $ny = $pt.Y; $nw = $pt.X - $r.Left; $nh = $r.Bottom - $pt.Y }
            if ($script:afResizing -eq 2) { $nx = $pt.X; $nw = $r.Right - $pt.X; $nh = $pt.Y - $r.Top }
            if ($script:afResizing -eq 3) { $nw = $pt.X - $r.Left; $nh = $pt.Y - $r.Top }
            if ($nw -gt 40 -and $nh -gt 40) { $script:afRoi = (_AFRect $nx $ny $nw $nh) }
            try { $script:pbObs.Invalidate() } catch {}; return
        }
        if ($script:afDragging -and $script:afDragOff) {
            $nx = [Math]::Max(0, [Math]::Min($pt.X - $script:afDragOff.X, $pw - $script:afRoi.Width))
            $ny = [Math]::Max(0, [Math]::Min($pt.Y - $script:afDragOff.Y, $ph - $script:afRoi.Height))
            $script:afRoi = (_AFRect $nx $ny $script:afRoi.Width $script:afRoi.Height)
            try { $script:pbObs.Invalidate() } catch {}; return
        }
        $onHandle = $false
        if ($script:afRoiVisible) {
            foreach ($hRect in (Get-AfHandles)) { if ($hRect.Contains($pt)) { $onHandle = $true; break } }
        }
        if ($script:afEnabled -and -not $onHandle -and $script:afRoi.Contains($pt)) {
            $script:pbObs.Cursor = [System.Windows.Forms.Cursors]::Cross
        }
        elseif ($onHandle -or ($script:afRoiVisible -and $script:afRoi.Contains($pt))) {
            $script:pbObs.Cursor = [System.Windows.Forms.Cursors]::SizeAll
        }
        else {
            $script:pbObs.Cursor = [System.Windows.Forms.Cursors]::Default
        }
    })

$script:pbObs.Add_MouseUp({
        $script:afDragging = $false
        $script:afResizing = -1
        $script:afDragOff = $null
        $script:afResizeOrig = $null
        $script:pbObs.Cursor = [System.Windows.Forms.Cursors]::Default
    })

# ---- "AF: OFF/ON" toggle button ----
$script:btnAfToggle = New-Object System.Windows.Forms.Button
$script:btnAfToggle.Text = 'AF: OFF'
$script:btnAfToggle.Size = Sz 70 22
$script:btnAfToggle.Location = Pt 4 4
$script:btnAfToggle.FlatStyle = 'Flat'
$script:btnAfToggle.FlatAppearance.BorderSize = 1
$script:btnAfToggle.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(90, 90, 90)
$script:btnAfToggle.BackColor = [System.Drawing.Color]::FromArgb(50, 50, 50)
$script:btnAfToggle.ForeColor = [System.Drawing.Color]::FromArgb(150, 150, 150)
$script:btnAfToggle.Font = New-Object System.Drawing.Font('Segoe UI', 7, [System.Drawing.FontStyle]::Bold)
$script:btnAfToggle.Cursor = [System.Windows.Forms.Cursors]::Hand
$script:btnAfToggle.TabStop = $false
$script:pPreview.Controls.Add($script:btnAfToggle)
$script:btnAfToggle.BringToFront()
$script:btnAfToggle.Visible = $false  # hidden until Speaker scene is active (right next to AF toggle) ----
# afRoiVisible already initialised (and restored from saved settings) above — do NOT reset it here
$script:btnAfSetRoi = New-Object System.Windows.Forms.Button
$script:btnAfSetRoi.Text = 'Set ROI'
$script:btnAfSetRoi.Size = Sz 55 22
$script:btnAfSetRoi.Location = Pt 78 4
$script:btnAfSetRoi.FlatStyle = 'Flat'
$script:btnAfSetRoi.FlatAppearance.BorderSize = 1
$script:btnAfSetRoi.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(0, 140, 180)
$script:btnAfSetRoi.BackColor = [System.Drawing.Color]::FromArgb(0, 70, 110)
$script:btnAfSetRoi.ForeColor = [System.Drawing.Color]::FromArgb(180, 230, 255)
$script:btnAfSetRoi.Font = New-Object System.Drawing.Font('Segoe UI', 7, [System.Drawing.FontStyle]::Bold)
$script:btnAfSetRoi.Cursor = [System.Windows.Forms.Cursors]::Hand
$script:btnAfSetRoi.TabStop = $false
$script:pPreview.Controls.Add($script:btnAfSetRoi)
$script:btnAfSetRoi.BringToFront()
$script:btnAfSetRoi.Visible = $false

# ---- Speed −/label/+ controls ----
$script:btnAfSpeedDown = New-Object System.Windows.Forms.Button
$script:btnAfSpeedDown.Text = '-'
$script:btnAfSpeedDown.Size = Sz 18 22
$script:btnAfSpeedDown.Location = Pt 137 4
$script:btnAfSpeedDown.FlatStyle = 'Flat'
$script:btnAfSpeedDown.FlatAppearance.BorderSize = 1
$script:btnAfSpeedDown.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(90, 90, 90)
$script:btnAfSpeedDown.BackColor = [System.Drawing.Color]::FromArgb(50, 50, 50)
$script:btnAfSpeedDown.ForeColor = [System.Drawing.Color]::FromArgb(200, 200, 200)
$script:btnAfSpeedDown.Font = New-Object System.Drawing.Font('Segoe UI', 8, [System.Drawing.FontStyle]::Bold)
$script:btnAfSpeedDown.Cursor = [System.Windows.Forms.Cursors]::Hand
$script:btnAfSpeedDown.TabStop = $false
$script:pPreview.Controls.Add($script:btnAfSpeedDown)
$script:btnAfSpeedDown.BringToFront()
$script:btnAfSpeedDown.Visible = $false

$script:lblAfSpeed = New-Object System.Windows.Forms.Label
$script:lblAfSpeed.Text = "S:$($script:afSpeed)"
$script:lblAfSpeed.Size = Sz 38 22
$script:lblAfSpeed.Location = Pt 157 4
$script:lblAfSpeed.TextAlign = 'MiddleCenter'
$script:lblAfSpeed.Font = New-Object System.Drawing.Font('Segoe UI', 7, [System.Drawing.FontStyle]::Bold)
$script:lblAfSpeed.ForeColor = [System.Drawing.Color]::FromArgb(180, 230, 180)
$script:lblAfSpeed.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
$script:pPreview.Controls.Add($script:lblAfSpeed)
$script:lblAfSpeed.BringToFront()
$script:lblAfSpeed.Visible = $false

$script:btnAfSpeedUp = New-Object System.Windows.Forms.Button
$script:btnAfSpeedUp.Text = '+'
$script:btnAfSpeedUp.Size = Sz 18 22
$script:btnAfSpeedUp.Location = Pt 197 4
$script:btnAfSpeedUp.FlatStyle = 'Flat'
$script:btnAfSpeedUp.FlatAppearance.BorderSize = 1
$script:btnAfSpeedUp.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(90, 90, 90)
$script:btnAfSpeedUp.BackColor = [System.Drawing.Color]::FromArgb(50, 50, 50)
$script:btnAfSpeedUp.ForeColor = [System.Drawing.Color]::FromArgb(200, 200, 200)
$script:btnAfSpeedUp.Font = New-Object System.Drawing.Font('Segoe UI', 8, [System.Drawing.FontStyle]::Bold)
$script:btnAfSpeedUp.Cursor = [System.Windows.Forms.Cursors]::Hand
$script:btnAfSpeedUp.TabStop = $false
$script:pPreview.Controls.Add($script:btnAfSpeedUp)
$script:btnAfSpeedUp.BringToFront()
$script:btnAfSpeedUp.Visible = $false

$script:btnAfSpeedDown.Add_Click({
        $script:afSpeed = [Math]::Max(10, $script:afSpeed - 10)
        $script:lblAfSpeed.Text = "S:$($script:afSpeed)"
        Log "AF speed: $($script:afSpeed) pulses"
    })
$script:btnAfSpeedUp.Add_Click({
        $script:afSpeed = [Math]::Min(200, $script:afSpeed + 10)
        $script:lblAfSpeed.Text = "S:$($script:afSpeed)"
        Log "AF speed: $($script:afSpeed) pulses"
    })

function Update-AfToggleUI {
    if ($script:afEnabled) {
        $script:btnAfToggle.Text = 'AF: ON'
        $script:btnAfToggle.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 0)
        $script:btnAfToggle.ForeColor = [System.Drawing.Color]::White
    }
    else {
        $script:btnAfToggle.Text = 'AF: OFF'
        $script:btnAfToggle.BackColor = [System.Drawing.Color]::FromArgb(50, 50, 50)
        $script:btnAfToggle.ForeColor = [System.Drawing.Color]::FromArgb(150, 150, 150)
    }
    try { $script:pbObs.Invalidate() } catch {}
}

$script:btnAfToggle.Add_Click({
        if ($script:afEnabled) {
            # Turning OFF: stop any active movement
            $script:afEnabled = $false
            $script:afRoiVisible = $false
            Reset-AfState
            Log 'Auto Frame: DISABLED'
        }
        else {
            $script:afEnabled = $true
            $script:afRoiVisible = $false
            Reset-AfState
            Log 'Auto Frame: ENABLED — click inside green ROI to centre camera'
        }
        Update-AfToggleUI
    })

$script:btnAfSetRoi.Add_Click({
        # Toggle ROI visibility for repositioning (works even when AF is off)
        $script:afRoiVisible = -not $script:afRoiVisible
        if ($script:afRoiVisible) {
            $script:btnAfSetRoi.BackColor = [System.Drawing.Color]::FromArgb(0, 130, 0)
            $script:btnAfSetRoi.ForeColor = [System.Drawing.Color]::White
            $script:btnAfSetRoi.Text = 'ROI: ON'
            Log 'Auto Frame: ROI visible — drag/resize green box, click Set ROI again to confirm'
        }
        else {
            $script:btnAfSetRoi.BackColor = [System.Drawing.Color]::FromArgb(0, 70, 110)
            $script:btnAfSetRoi.ForeColor = [System.Drawing.Color]::FromArgb(180, 230, 255)
            $script:btnAfSetRoi.Text = 'Set ROI'
            Log "Auto Frame: ROI confirmed at X=$($script:afRoi.X) Y=$($script:afRoi.Y) W=$($script:afRoi.Width) H=$($script:afRoi.Height)"
        }
        try { $script:pbObs.Invalidate() } catch {}
    })

# ---- Scene monitoring ----
$script:afSceneCheckCtr = 0

function Update-AfButtonsVisibility([bool]$show) {
    foreach ($ctl in @($script:btnAfToggle, $script:btnAfSetRoi, $script:btnAfSpeedDown, $script:lblAfSpeed, $script:btnAfSpeedUp)) {
        try { if ($ctl -and -not $ctl.IsDisposed) { $ctl.Visible = $show } } catch {}
    }
    try { $script:pbObs.Invalidate() } catch {}
}

function Update-AfScene {
    try {
        $sn = Get-CurrentProgramSceneName
        $was = $script:afSceneActive
        $script:afSceneActive = ($sn -eq $script:AF_SCENE_NAME)
        if ($was -ne $script:afSceneActive) {
            if ($script:afSceneActive) {
                # Speaker scene just went live — restore AF state the user had before leaving
                if ($script:afWasEnabled) {
                    $script:afEnabled = $true
                    $script:afRoiVisible = $true
                }
                Reset-AfState
                Invoke-OnUI {
                    Update-AfButtonsVisibility $true
                    Update-AfToggleUI
                    # Restore Set ROI button appearance
                    if ($script:afRoiVisible) {
                        $script:btnAfSetRoi.BackColor = [System.Drawing.Color]::FromArgb(0, 130, 0)
                        $script:btnAfSetRoi.ForeColor = [System.Drawing.Color]::White
                        $script:btnAfSetRoi.Text = 'ROI: ON'
                    }
                    # Restore speed label
                    try { $script:lblAfSpeed.Text = "S:$($script:afSpeed)" } catch {}
                }
                Log "Auto Frame: '$($script:AF_SCENE_NAME)' live — controls shown (AF=$($script:afEnabled) Speed=$($script:afSpeed))"
            }
            else {
                # Left Speaker scene — remember AF state, disable AF, hide controls
                $script:afWasEnabled = $script:afEnabled
                $script:afEnabled = $false
                $script:afRoiVisible = $false
                Reset-AfState
                Invoke-OnUI {
                    Update-AfButtonsVisibility $false
                    Update-AfToggleUI
                }
                Log "Auto Frame: scene '$sn' — controls hidden (AF was $($script:afWasEnabled), will restore on return)"
            }
        }
    }
    catch {}
}

# ---- AF: click-to-center pulse delivery (30 ms / pulse) ----
$script:_afTimer = New-Object System.Windows.Forms.Timer
$script:_afTimer.Interval = 30
$script:_afTimer.Add_Tick({
        # Scene monitoring every ~2 s (67 × 30 ms)
        $script:afSceneCheckCtr++
        if ($script:afSceneCheckCtr -ge 67) { $script:afSceneCheckCtr = 0; Update-AfScene }
        if (-not $script:afEnabled -or -not $script:ObsConnected) { return }
        # Send one PTZ pulse per tick — tilt only (pan disabled)
        if ($script:afTiltPulses -gt 0) { Send-OBSHotkeyKey 'OBS_KEY_DOWN'; $script:afTiltPulses-- }
        elseif ($script:afTiltPulses -lt 0) { Send-OBSHotkeyKey 'OBS_KEY_UP'; $script:afTiltPulses++ }
        try { $script:pbObs.Invalidate() } catch {}
    })
$script:_afTimer.Start()

# ========= BEGIN OBS CONNECTIVITY CORE (PS 5.1 safe; timeouts + ping) =========


# ========= BEGIN OBS CONNECTIVITY CORE (PS 5.1 safe; timeouts + ping) =========

function _SetObsLight([bool]$up, [string]$why = "") {
    try { if (Get-Command Set-ObsStatusIndicator -ErrorAction SilentlyContinue) { Set-ObsStatusIndicator $up $why } } catch {}
}

# ---- PS 5.1-safe defaults (no '??' and no mashed params) ----
if (-not (Get-Variable -Scope Script -Name ObsWsHost          -ErrorAction SilentlyContinue) -or -not $script:ObsWsHost) { $script:ObsWsHost = '127.0.0.1' }
if (-not (Get-Variable -Scope Script -Name ObsWsPort          -ErrorAction SilentlyContinue) -or -not $script:ObsWsPort) { $script:ObsWsPort = 4456 }
if (-not (Get-Variable -Scope Script -Name ObsImgW            -ErrorAction SilentlyContinue) -or -not $script:ObsImgW) { $script:ObsImgW = 960 }
if (-not (Get-Variable -Scope Script -Name ObsImgH            -ErrorAction SilentlyContinue) -or -not $script:ObsImgH) { $script:ObsImgH = 540 }
if (-not (Get-Variable -Scope Script -Name ObsImgFormat       -ErrorAction SilentlyContinue) -or -not $script:ObsImgFormat) { $script:ObsImgFormat = 'jpeg' }
if (-not (Get-Variable -Scope Script -Name ObsJpegQuality     -ErrorAction SilentlyContinue) -or -not $script:ObsJpegQuality) { $script:ObsJpegQuality = 70 }
if (-not (Get-Variable -Scope Script -Name ObsBaseInterval    -ErrorAction SilentlyContinue) -or -not $script:ObsBaseInterval) { $script:ObsBaseInterval = 150 }

if (-not (Get-Variable -Scope Script -Name obsTimer     -ErrorAction SilentlyContinue)) { $script:obsTimer = $null }
if (-not (Get-Variable -Scope Script -Name obsAutoTimer -ErrorAction SilentlyContinue)) { $script:obsAutoTimer = $null }
if (-not (Get-Variable -Scope Script -Name obsPingTimer -ErrorAction SilentlyContinue)) { $script:obsPingTimer = $null }
if (-not (Get-Variable -Scope Script -Name obsStopwatch -ErrorAction SilentlyContinue) -or -not $script:obsStopwatch) {
    $script:obsStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
}

# ---- Timeouts ----
$script:wsSendTimeoutMs = 500
$script:wsRecvTimeoutMs = 1200
$script:obsPingEveryMs = 3000

# ---- Runtime state ----
$script:ObsWS = $null
$script:ObsConnected = $false
$script:reqCounter = 0
$script:obsInFlight = $false
$script:obsShared = $null   # [hashtable]::Synchronized — cross-runspace frame data
$script:obsWorkerPS = $null   # [powershell] worker instance
$script:obsWorkerRS = $null   # dedicated Runspace for worker
$script:obsWorkerAsync = $null   # IAsyncResult from BeginInvoke

# ---- Helpers ----
function New-ObsClient {
    $ws = New-Object System.Net.WebSockets.ClientWebSocket
    $ws.Options.AddSubProtocol("obswebsocket.json")
    $ws.Options.KeepAliveInterval = [TimeSpan]::FromSeconds(30)
    return $ws
}
function New-Cts([int]$ms) {
    $cts = New-Object System.Threading.CancellationTokenSource
    $cts.CancelAfter([Math]::Max(100, $ms)); return $cts
}
function Set-LabelTextSafe([object]$lbl, [string]$text) {
    try {
        if (-not $lbl -or ($lbl -is [System.Windows.Forms.Control] -and $lbl.IsDisposed)) { return }
    
        if ($lbl -is [System.Windows.Forms.Control] -and $lbl.InvokeRequired) {
            Invoke-OnUI { Set-LabelTextSafe $lbl $text }
            return
        }
    
        $lbl.Text = $text
    }
    catch {}
}


# ---- Socket I/O with timeouts (PS 5.1-safe, quiet under shutdown/close) ----

function Is-ObsSocketOpen {
    try {
        return ($script:ObsWS -and $script:ObsWS.State -eq [System.Net.WebSockets.WebSocketState]::Open)
    }
    catch { return $false }
}

function Send-ObsJson([object]$obj) {
    $cts = $null
    try {
        if ($script:ShuttingDown) { return $false }
        if (-not (Is-ObsSocketOpen)) {
            # Expected transient window while OBS is intentionally reconnecting.
            if ($script:_connectInProgress -or -not $script:ObsConnected) { return $false }
            Log-Throttled "send-noopen" "Send-ObsJson: socket not open" 10
            return $false
        }

        $json = if ($obj -is [string]) { $obj } else { $obj | ConvertTo-Json -Depth 8 -Compress }
        $bytes = [Text.Encoding]::UTF8.GetBytes($json)
        $seg = New-Object System.ArraySegment[byte] (, $bytes)

        # explicit integer timeout (ms)
        $timeoutMs = 3000
        try { if ($script:wsSendTimeoutMs) { $timeoutMs = [int]$script:wsSendTimeoutMs } } catch {}

        $cts = New-Object System.Threading.CancellationTokenSource
        $cts.CancelAfter([int]$timeoutMs)

        $task = $script:ObsWS.SendAsync($seg, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $cts.Token)
        $ok = $task.Wait([int]$timeoutMs)
        if (-not $ok -or $task.IsFaulted) {
            Log-Throttled "send-timeout" "Send-ObsJson: send failed or timeout ($timeoutMs ms)" 8
            return $false
        }
        return $true
    }
    catch [System.Management.Automation.PipelineStoppedException] {
        # Happens when the WinForms timer fires during teardown (e.g., OBS closed).
        # Be quiet to avoid crash/JIT dialog.
        return $false
    }
    catch [System.ObjectDisposedException] {
        Log-Throttled "send-disposed" "Send-ObsJson: socket disposed" 10
        return $false
    }
    catch [System.InvalidOperationException] {
        # Common when state is CloseReceived/CloseSent
        Log-Throttled "send-invalidstate" ("Send-ObsJson: " + (Get-RootErrorMessage $_.Exception)) 10
        return $false
    }
    catch {
        Log-Throttled "send-unknown" ("Send-ObsJson error: " + (Get-RootErrorMessage $_.Exception)) 10
        return $false
    }
    finally {
        try { if ($cts) { $cts.Dispose() } } catch {}
    }
}

# ---- Receive-Text with strict null/closed guards ----
function Receive-Text {
    if ($script:ShuttingDown) { return $null }

    # Fast guard: no socket or not open → bail quietly
    try {
        if (-not $script:ObsWS) { return $null }
        $state = $script:ObsWS.State
    }
    catch { return $null }

    # Only proceed if Open or CloseReceived (we’ll detect close and clean up)
    if (($state -ne [System.Net.WebSockets.WebSocketState]::Open) -and
        ($state -ne [System.Net.WebSockets.WebSocketState]::CloseReceived)) {
        return $null
    }

    $buf = New-Object byte[] 32768
    $ms = New-Object System.IO.MemoryStream
    $cts = $null

    try {
        while ($true) {
            # Re-check socket each loop in case Close-Obs ran mid-iteration
            try {
                if (-not $script:ObsWS) { return $null }
                $state = $script:ObsWS.State
            }
            catch { return $null }

            if (($state -ne [System.Net.WebSockets.WebSocketState]::Open) -and
                ($state -ne [System.Net.WebSockets.WebSocketState]::CloseReceived)) {
                return $null
            }

            $seg = New-Object System.ArraySegment[byte] (, $buf)

            $timeoutMs = 4000
            try { if ($script:wsRecvTimeoutMs) { $timeoutMs = [int]$script:wsRecvTimeoutMs } } catch {}

            $cts = New-Object System.Threading.CancellationTokenSource
            $cts.CancelAfter([int]$timeoutMs)

            $task = $null
            try {
                $task = $script:ObsWS.ReceiveAsync($seg, $cts.Token)
            }
            catch [System.ObjectDisposedException] {
                # Socket torn down → exit quietly
                return $null
            }
            catch {
                $root = Get-RootErrorMessage $_.Exception
                if (-not $script:_connectInProgress -and $script:ObsConnected -and -not $script:ShuttingDown) {
                    Log-Throttled "recv-begin" ("Receive-Text: " + $root) 8
                }
                return $null
            }

            $completed = $false
            try {
                $completed = $task.Wait([int]$timeoutMs)
            }
            catch [System.AggregateException] {
                $root = Get-RootErrorMessage $_.Exception
                if (-not $script:_connectInProgress -and $script:ObsConnected -and -not $script:ShuttingDown) {
                    Log-Throttled "recv-wait-agg" ("Receive-Text: " + $root) 5
                }
                return $null
            }
            catch {
                $root = Get-RootErrorMessage $_.Exception
                if (-not $script:_connectInProgress -and $script:ObsConnected -and -not $script:ShuttingDown) {
                    Log-Throttled "recv-wait" ("Receive-Text: " + $root) 5
                }
                return $null
            }

            if (-not $completed) {
                return $null  # benign timeout
            }

            $res = $task.Result
            if ($res.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) {
                if (-not $script:_connectInProgress -and $script:ObsConnected -and -not $script:ShuttingDown) {
                    Log-Throttled "recv-close" "Receive-Text: websocket closed" 8
                }
                try {
                    Close-Obs
                    if ($script:lblHint) {
                        Set-LabelTextSafe $script:lblHint "Waiting for OBS..."
                        $script:lblHint.Visible = $true
                        try { $script:lblHint.BringToFront() } catch {}
                    }
                }
                catch {}
                return $null
            }

            if ($res.Count -gt 0) { $ms.Write($buf, 0, $res.Count) }
            if ($res.EndOfMessage) { break }
        }

        return [Text.Encoding]::UTF8.GetString($ms.ToArray())
    }
    catch [System.ObjectDisposedException] {
        if (-not $script:_connectInProgress -and $script:ObsConnected -and -not $script:ShuttingDown) {
            Log-Throttled "recv-disposed" "Receive-Text: socket disposed" 10
        }
        return $null
    }
    catch {
        $root = Get-RootErrorMessage $_.Exception
        if (-not $script:_connectInProgress -and $script:ObsConnected -and -not $script:ShuttingDown) {
            Log-Throttled "recv-unknown" ("Receive-Text error: " + $root) 10
        }
        return $null
    }
    finally {
        try { if ($ms) { $ms.Dispose() } } catch {}
        try { if ($cts) { $cts.Dispose() } } catch {}
    }
}

# ---- Replace existing Receive-ObsJson with this (also quiet) ----
function Receive-ObsJson {
    try {
        $txt = Receive-Text
        if (-not $txt) { return $null }
        try {
            return $txt | ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            # Non-JSON messages aren’t fatal; just ignore without noise
            return $txt
        }
    }
    catch {
        if (-not $script:_connectInProgress -and $script:ObsConnected -and -not $script:ShuttingDown) {
            Log-Throttled "recv-json" ("Receive-ObsJson error: " + (Get-RootErrorMessage $_.Exception)) 10
        }
        return $null
    }
}


# ---- Request/response wrapper ----
function Invoke-ObsRequest([string]$RequestType, [hashtable]$RequestData) {
    $script:reqCounter++; $rid = "ps51-$($script:reqCounter)-$([guid]::NewGuid())"
    $payload = @{ op = 6; d = @{ requestType = $RequestType; requestId = $rid; requestData = $RequestData } }
    if (-not (Send-ObsJson $payload)) { throw "Send failed ($RequestType)" }

    $deadline = (Get-Date).AddSeconds(5)
    while ((Get-Date) -lt $deadline) {
        $msg = Receive-ObsJson
        if (-not $msg) { continue }          # benign timeout; keep polling until deadline
        if ($msg -is [string]) { continue }  # junk; keep polling
        switch ($msg.op) {
            5 {
                # Process OBS events
                if ($msg.d.eventType -eq 'VirtualcamStateChanged') {
                    # Handle virtual camera status change
                    try {
                        $script:VirtualCameraStatus = [bool]$msg.d.eventData.outputActive
                        $statusText = if ($script:VirtualCameraStatus) { 'ON' } else { 'OFF' }
                        Log "Virtual Camera: $statusText"
                        Invoke-OnUI { Update-VCamStatusVisual }
                    }
                    catch { Log "Error processing VirtualcamStateChanged event: $_" }
                }
                elseif ($msg.d.eventType -eq 'InputVolumeMeters') {
                    # Process audio meter events for XR ducking
                    $inputs = $msg.d.eventData.inputs
                    if ($inputs -and $script:Cfg.OBS.MediaInputName) {
                        $mediaInput = $inputs | Where-Object { $_.inputName -eq $script:Cfg.OBS.MediaInputName } | Select-Object -First 1
                        if ($mediaInput -and $mediaInput.inputLevelsMul -and $mediaInput.inputLevelsMul.Count -gt 0) {
                            # Get dB value from first channel (multichannel sources use array of arrays)
                            $channelArray = $mediaInput.inputLevelsMul[0]
                            if ($channelArray -and $channelArray.Count -gt 0) {
                                $dB = [double]$channelArray[0]
                                # Convert dB to linear (0.0 to 1.0): linear = 10^(dB/20)
                                # OBS sends -infinity as very low dB (e.g. -60). Clamp to -60 minimum.
                                if ($dB -lt -60) { $dB = -60 }
                                $linear = [Math]::Pow(10, ($dB / 20.0))

                                # Update audio activity based on threshold (values > 1.0 + sensitivity = audio above silence baseline)
                                $script:_lastAudioPeak = $linear
                                $threshold = 1.0 + $script:Cfg.Audio.Threshold  # Silence baseline (1.0) + sensitivity threshold

                                # Only log state changes, not every meter update
                                if ($linear -gt $threshold) {
                                    if (-not $script:_audioActive) {
                                        $sensitivityDB = if ($script:Cfg.Audio.Threshold -gt 0) { 20 * [Math]::Log10($script:Cfg.Audio.Threshold) } else { -35 }
                                        Log "OBS Audio: ACTIVE (Peak: $($linear.ToString('F4')) > Baseline+Sensitivity: $($threshold.ToString('F4')) [1.0 + $($sensitivityDB.ToString('F0'))dB])"
                                    }
                                    $script:_audioActive = $true
                                    $script:_lastAudioTime = Get-Date
                                }
                                # Don't set to FALSE here - let the hold time mechanism in the ducking timer handle release
                            }
                        }
                    }

                    # Process Zoom audio for auto-raising
                    if ($script:Cfg.Zoom.AutoZoomAudio -and $script:Cfg.OBSControl.AutoStartAutoToggle) {
                        $zoomInput = $inputs | Where-Object { $_.inputName -eq 'Zoom_Audio' } | Select-Object -First 1

                        # Reset state if Zoom_Audio source doesn't exist
                        if (-not $zoomInput) {
                            if ($script:_zoomAudioActive) {
                                Log "Zoom Audio: Source 'Zoom_Audio' not found - setting inactive"
                                $script:_zoomAudioActive = $false
                            }
                        }
                        elseif ($zoomInput -and $zoomInput.inputLevelsMul -and $zoomInput.inputLevelsMul.Count -gt 0) {
                            $channelArray = $zoomInput.inputLevelsMul[0]
                            if ($channelArray -and $channelArray.Count -gt 0) {
                                $dB = [double]$channelArray[0]

                                # Fix audio level interpretation:
                                # OBS sends 0.0 dB when there's NO audio (silence)
                                # Real audio shows as negative dB values (e.g., -20dB, -30dB, etc.)
                                if ($dB -eq 0.0) {
                                    # 0.0 dB = silence, set to very low value
                                    $linear = 0.0
                                }
                                else {
                                    # Convert actual dB readings to linear
                                    if ($dB -lt -60) { $dB = -60 }
                                    $linear = [Math]::Pow(10, ($dB / 20.0))
                                }

                                # Update Zoom audio activity (threshold: -50dB ~ 0.0032 linear)
                                $script:_lastZoomAudioPeak = $linear
                                $zoomThreshold = 0.0032  # Equivalent to -50dB

                                if ($linear -gt $zoomThreshold) {
                                    if (-not $script:_zoomAudioActive) {
                                        Log "Zoom Audio: DETECTED (Peak: $($linear.ToString('F6')) > Threshold: $($zoomThreshold.ToString('F4')))"
                                    }
                                    $script:_zoomAudioActive = $true
                                    $script:_lastZoomAudioTime = Get-Date
                                }
                                else {
                                    # Audio dropped below threshold - set inactive immediately
                                    # (ZoomRaiseTimer will handle the hold time for fader release)
                                    if ($script:_zoomAudioActive) {
                                        Log "Zoom Audio: SILENT (Peak: $($linear.ToString('F6')) < Threshold: $($zoomThreshold.ToString('F4')))"
                                    }
                                    $script:_zoomAudioActive = $false
                                }
                            }
                            else {
                                # No audio data in channel array
                                if ($script:_zoomAudioActive) {
                                    Log "Zoom Audio: No channel data - setting inactive"
                                    $script:_zoomAudioActive = $false
                                }
                            }
                        }
                        else {
                            # Source exists but no audio level data
                            if ($script:_zoomAudioActive) {
                                Log "Zoom Audio: No audio level data - setting inactive"
                                $script:_zoomAudioActive = $false
                            }
                        }
                    }
                    # Reset Zoom audio state if Start Auto Toggle is disabled
                    elseif ($script:Cfg.Zoom.AutoZoomAudio -and -not $script:Cfg.OBSControl.AutoStartAutoToggle) {
                        if ($script:_zoomAudioActive) {
                            Log "Zoom Audio: Start Auto Toggle disabled - setting inactive"
                            $script:_zoomAudioActive = $false
                        }
                    }
                }
                continue
            }
            7 {
                if ($msg.d.requestId -eq $rid) {
                    if (-not $msg.d.requestStatus.result) {
                        $code = $msg.d.requestStatus.code; $comment = $msg.d.requestStatus.comment
                        throw "OBS '$RequestType' failed: $code $comment"
                    }
                    return $msg.d.responseData
                }
            }
        }
    }
    throw "OBS request timed out: $RequestType"
}

# ---- Check if audio monitoring should be active (only needs ducking enabled) ----
function Should-MonitorAudio {
    # Monitor audio when: ducking enabled (XR doesn't need to be online since we use OBS audio)
    # Audio data is collected continuously but only used for ducking when Auto Toggle is running
    return $script:Cfg.XR.DuckingEnabled
}

# ---- Small API helpers ----
function Get-StudioModeEnabled { try { (Invoke-ObsRequest 'GetStudioModeEnabled' @{}).studioModeEnabled }catch { $false } }
function Get-CurrentProgramSceneName { try { (Invoke-ObsRequest 'GetCurrentProgramScene' @{}).currentProgramSceneName }catch { $null } }
function Get-CurrentPreviewSceneName { try { (Invoke-ObsRequest 'GetCurrentPreviewScene' @{}).currentPreviewSceneName }catch { $null } }
function Get-InputList { try { (Invoke-ObsRequest 'GetInputList' @{}).inputs }catch { @() } }
function Get-SourceScreenshotBase64([string]$Name, [int]$W, [int]$H, [string]$Fmt, [int]$JpgQ = 70) {
    $req = @{ sourceName = $Name; imageFormat = $Fmt; imageWidth = $W; imageHeight = $H }
    if ($Fmt -eq 'jpeg') { $req.imageCompressionQuality = [Math]::Max(1, [Math]::Min(100, $JpgQ)) }
    (Invoke-ObsRequest 'GetSourceScreenshot' $req).imageData
}
function Get-TrackedSceneName {
    $studio = Get-StudioModeEnabled
    if ($script:TrackProgramAlways -or -not $studio) { Get-CurrentProgramSceneName } else { Get-CurrentPreviewSceneName }
}

# ---- Connect / Close ----
function Connect-Obs {
    if ($script:ShuttingDown) { return $false }

    try {
        Set-LabelTextSafe $script:lblHint "OBS: connecting to ws://$($script:ObsWsHost):$($script:ObsWsPort) …"

        # Fresh socket
        if ($script:ObsWS) { try { $script:ObsWS.Dispose() } catch {} ; $script:ObsWS = $null }
        $script:ObsWS = New-ObsClient
        $uri = [Uri]::new(("ws://{0}:{1}" -f $script:ObsWsHost, $script:ObsWsPort))

        # Connect with timeout - use short timeout (500ms) for faster shutdown response
        $connectCts = New-Object System.Threading.CancellationTokenSource
        $timeoutMs = 500  # Fast failure if OBS not responding
        $connectCts.CancelAfter($timeoutMs)
        $task = $script:ObsWS.ConnectAsync($uri, $connectCts.Token)
    
        # Wait with shutdown checks every 50ms
        $waited = 0
        while (-not $task.IsCompleted -and $waited -lt $timeoutMs) {
            if ($script:ShuttingDown) {
                $connectCts.Cancel()
                throw "Connect aborted: shutting down"
            }
            Start-Sleep -Milliseconds 50
            $waited += 50
        }
    
        if (-not $task.IsCompleted -or $task.IsFaulted -or
            $script:ObsWS.State -ne [System.Net.WebSockets.WebSocketState]::Open) {
            throw "Connect timed out or failed to $uri"
        }

        # Handshake
        $hello = Receive-ObsJson
        if (-not $hello -or $hello.op -ne 0) { throw "OBS Hello not received" }

        # Check if we need audio monitoring (ducking enabled + XR online)
        $needAudioMonitoring = Should-MonitorAudio
        # Event subscription bits: 1=General, 2=Config, 4=Scenes, 8=Inputs, 16=Transitions, 32=Filters, 64=Outputs, 128=SceneItems, 256=MediaInputs, 512=VendorSpecific, 1024=UI, (1<<16)=InputVolumeMeters, (1<<17)=InputActiveStateChanged, (1<<18)=InputShowStateChanged, (1<<19)=SceneItemTransformChanged
        $baseEvents = 8 + 64  # Inputs + Outputs (for virtual camera)
        $eventSubs = if ($needAudioMonitoring) { $baseEvents + 65536 } else { $baseEvents }  # Add VolumeMeters if needed
        $subsDescription = if ($needAudioMonitoring) { "Inputs + Outputs + VolumeMeters" } else { "Inputs + Outputs" }
        
        $identify = @{ op = 1; d = @{ rpcVersion = 1; eventSubscriptions = $eventSubs } }
        if ($hello.d -and $hello.d.authentication) {
            $identify.d.authentication = Obs-ComputeAuth $script:Cfg.OBS.Password $hello.d.authentication.salt $hello.d.authentication.challenge
        }
        if (-not (Send-ObsJson $identify)) { throw "Failed to send IDENTIFY" }

        $identified = Receive-ObsJson
        if (-not $identified -or $identified.op -ne 2) { throw "OBS Identified not received" }
        
        Log "OBS: Connected with event subscriptions: $eventSubs ($subsDescription)"

        # Query initial virtual camera status
        try {
            $vcamStatus = Invoke-ObsRequest "GetVirtualCamStatus" @{}
            if ($vcamStatus -and $vcamStatus.PSObject.Properties.Name -contains 'outputActive') {
                $script:VirtualCameraStatus = [bool]$vcamStatus.outputActive
                $statusText = if ($script:VirtualCameraStatus) { 'ON' } else { 'OFF' }
                Log "Virtual Camera initial status: $statusText"
                Invoke-OnUI { Update-VCamStatusVisual }
            }
        }
        catch { 
            Log "Failed to query initial virtual camera status: $_"
            $script:VirtualCameraStatus = $false
        }

        # Success
        $script:ObsConnected = $true
        try { Set-ObsStatusIndicator $true "online" } catch {}
        _SetObsLight $true "online"
        Set-LabelTextSafe $script:lblHint "OBS: connected. Rendering …"
        # START HEARTBEAT
        try { if ($script:obsPingTimer) { $script:obsPingTimer.Start() } } catch {}
        # Start/ensure preview timer
        Ensure-ObsTimer
        try { if ($script:obsTimer -and -not $script:obsTimer.Enabled) { $script:obsTimer.Start() } } catch {}
        # Start background preview worker (own WS connection, dedicated runspace)
        Start-ObsPreviewWorker

        # Auto-switch to Speaker after connect
        try {
            # Priority: 1) Preserved scene (from settings save), 2) Default Speaker
            $targetScene = $null
            
            if ($script:_preservedScene) {
                $targetScene = $script:_preservedScene
                Log "Using preserved scene: '$targetScene'"
                # Clear preserved scene after use
                $script:_preservedScene = $null
            }
            else {
                $targetScene = "Speaker"
                if ($script:Cfg.OBS.SceneCam) { $targetScene = $script:Cfg.OBS.SceneCam }
                Log "Using default SceneCam: '$targetScene'"
            }
            
            [void](Invoke-ObsRequest "SetCurrentProgramScene" @{ sceneName = $targetScene })
            Log "OBS: Auto-switched to '$targetScene'"
      
            # Update UI to reflect the switch
            Invoke-OnUI {
                $script:_lastProgramScene = $targetScene
                if ($btnBlank) { $btnBlank.Text = $targetScene }
                $script:SelectedScene = $targetScene
                if ($btnCam) { $btnCam.Text = $targetScene }
            }
        }
        catch {
            Log "OBS: Auto-switch failed: $($_.Exception.Message)"
        }

  
        return $true
    }
    catch {
        # Failure path — clean up & surface a single, non-spammy log
        $msg = try { Get-RootErrorMessage $_.Exception } catch { "$($_.Exception)" }
        Log ("Connect-Obs error: " + $msg)

        try { if ($script:ObsWS) { $script:ObsWS.Dispose() } } catch {}
        $script:ObsWS = $null
        $script:ObsConnected = $false
        $script:obsInFlight = $false

        try { Set-ObsStatusIndicator $false "connect failed" } catch {}
        _SetObsLight $false "waiting…"
        Set-LabelTextSafe $script:lblHint "Waiting for OBS..."

        return $false
    }
}

   
function Close-Obs {
    try { if ($script:obsPingTimer) { $script:obsPingTimer.Stop() } } catch {}
    try { if ($script:obsTimer) { $script:obsTimer.Stop() } } catch {}
    try { Stop-ObsPreviewWorker } catch {}

    try {
        if ($script:ObsWS) { $script:ObsWS.Dispose() }
    }
    catch {}

    $script:ObsWS = $null
    $script:ObsConnected = $false
    $script:obsInFlight = $false

    # Clear preview
    try {
        if ($script:pbObs -and -not $script:pbObs.IsDisposed) {
            if ($script:pbObs.Image) { try { $script:pbObs.Image.Dispose() } catch {} }
            $script:pbObs.Image = $null
        }
    }
    catch {}

    # Show/bring hint
    try {
        if ($script:lblHint) {
            Set-LabelTextSafe $script:lblHint "Waiting for OBS..."
            $script:lblHint.Visible = $true
            try { $script:lblHint.BringToFront() } catch {}
        }
    }
    catch {}

    # Flip status button to red
    try { Set-ObsStatusIndicator $false "waiting…" } catch {}
    try { _SetObsLight $false "waiting…" } catch {}
}

# ========== BACKGROUND PREVIEW WORKER (dedicated runspace + own OBS connection) ==========
# Uses [powershell]::Create() + Runspace + [hashtable]::Synchronized — the only safe PS5.1
# cross-thread model. The worker opens its OWN ClientWebSocket to OBS (eventSubscriptions=0),
# fetches GetCurrentProgramScene + GetSourceScreenshot in a tight loop, and stores raw JPEG
# bytes in the shared table. The UI timer reads bytes -> creates Bitmap -> swaps into pbObs.
# Result: zero OBS network I/O on the UI thread -> no freeze when Settings dialog is open.

function Stop-ObsPreviewWorker {
    # Signal worker to exit its loop cleanly
    if ($script:obsShared) { $script:obsShared.StopRequested = $true }

    if ($script:obsWorkerPS) {
        try {
            $deadline = (Get-Date).AddMilliseconds(2500)
            while (-not $script:obsWorkerAsync.IsCompleted -and (Get-Date) -lt $deadline) {
                Start-Sleep -Milliseconds 50
            }
        }
        catch {}
        try { $script:obsWorkerPS.Stop() } catch {}
        try { $script:obsWorkerPS.Dispose() } catch {}
    }
    if ($script:obsWorkerRS) {
        try { $script:obsWorkerRS.Close() } catch {}
        try { $script:obsWorkerRS.Dispose() } catch {}
    }

    $script:obsWorkerPS = $null
    $script:obsWorkerRS = $null
    $script:obsWorkerAsync = $null

    if ($script:obsShared) {
        $script:obsShared.LatestBytes = $null
        $script:obsShared.StopRequested = $false   # reset so next Start works
    }
}

function Start-ObsPreviewWorker {
    Stop-ObsPreviewWorker   # clean up any previous instance

    # Build / refresh the shared table (both runspaces see the same .NET object)
    if (-not $script:obsShared) {
        $script:obsShared = [hashtable]::Synchronized(@{
                Host          = [string]$script:ObsWsHost
                Port          = [int]$script:ObsWsPort
                Password      = [string]$script:Cfg.OBS.Password
                ImgW          = [int]$script:ObsImgW
                ImgH          = [int]$script:ObsImgH
                ImgFormat     = [string]$script:ObsImgFormat
                JpgQ          = [int]$script:ObsJpegQuality
                SceneName     = ''
                LatestBytes   = $null
                StopRequested = $false
            })
    }
    else {
        $script:obsShared.Host = [string]$script:ObsWsHost
        $script:obsShared.Port = [int]$script:ObsWsPort
        $script:obsShared.Password = [string]$script:Cfg.OBS.Password
        $script:obsShared.ImgW = [int]$script:ObsImgW
        $script:obsShared.ImgH = [int]$script:ObsImgH
        $script:obsShared.ImgFormat = [string]$script:ObsImgFormat
        $script:obsShared.JpgQ = [int]$script:ObsJpegQuality
        $script:obsShared.LatestBytes = $null
        $script:obsShared.StopRequested = $false
    }

    # ----- Self-contained worker script (no $script: references from parent runspace) -----
    $workerCode = {
        param([hashtable]$shared)

        function WS-Send($ws, $obj) {
            try {
                $json = $obj | ConvertTo-Json -Depth 8 -Compress
                $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
                $seg = New-Object System.ArraySegment[byte] (, $bytes)
                $cts = New-Object System.Threading.CancellationTokenSource
                $cts.CancelAfter(2000)
                $t = $ws.SendAsync($seg, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $cts.Token)
                return ($t.Wait(2000) -and -not $t.IsFaulted)
            }
            catch { return $false }
        }

        function WS-Recv($ws, [int]$ms = 2000) {
            try {
                $buf = New-Object byte[] 65536
                $mem = New-Object System.IO.MemoryStream
                $cts = New-Object System.Threading.CancellationTokenSource
                $cts.CancelAfter($ms)
                while ($true) {
                    $seg = New-Object System.ArraySegment[byte] (, $buf)
                    $t = $ws.ReceiveAsync($seg, $cts.Token)
                    if (-not $t.Wait($ms) -or $t.IsFaulted) { return $null }
                    $r = $t.Result
                    if ($r.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) { return $null }
                    if ($r.Count -gt 0) { $mem.Write($buf, 0, $r.Count) }
                    if ($r.EndOfMessage) { return [System.Text.Encoding]::UTF8.GetString($mem.ToArray()) }
                }
            }
            catch { return $null }
        }

        function WS-Auth($pwdText, $saltB64, $chB64) {
            $sha = [System.Security.Cryptography.SHA256]::Create()
            $salt = [Convert]::FromBase64String($saltB64)
            $pw = [System.Text.Encoding]::UTF8.GetBytes($pwdText)
            $mix = New-Object byte[] ($pw.Length + $salt.Length)
            [Array]::Copy($pw, 0, $mix, 0, $pw.Length)
            [Array]::Copy($salt, 0, $mix, $pw.Length, $salt.Length)
            $hmac = New-Object System.Security.Cryptography.HMACSHA256
            $hmac.Key = $sha.ComputeHash($mix)
            [Convert]::ToBase64String($hmac.ComputeHash([Convert]::FromBase64String($chB64)))
        }

        $rid = 0

        # Outer reconnect loop — worker keeps trying if OBS drops
        while (-not $shared.StopRequested) {
            $ws = $null
            try {
                # ------ Connect ------
                $ws = New-Object System.Net.WebSockets.ClientWebSocket
                $ws.Options.AddSubProtocol('obswebsocket.json')
                $ws.Options.KeepAliveInterval = [TimeSpan]::FromSeconds(30)
                $uri = [Uri]::new("ws://$($shared.Host):$($shared.Port)")
                $cts = New-Object System.Threading.CancellationTokenSource
                $cts.CancelAfter(3000)
                $t = $ws.ConnectAsync($uri, $cts.Token)
                if (-not $t.Wait(3000) -or $t.IsFaulted -or
                    $ws.State -ne [System.Net.WebSockets.WebSocketState]::Open) {
                    Start-Sleep -Milliseconds 2000
                    continue
                }

                # ------ Handshake ------
                $helloTxt = WS-Recv $ws 5000
                if (-not $helloTxt) { Start-Sleep -Milliseconds 2000; continue }
                $hello = $helloTxt | ConvertFrom-Json
                if ($hello.op -ne 0) { Start-Sleep -Milliseconds 2000; continue }

                $ident = @{ op = 1; d = @{ rpcVersion = 1; eventSubscriptions = 0 } }
                if ($hello.d.authentication) {
                    $ident.d.authentication = WS-Auth $shared.Password `
                        $hello.d.authentication.salt $hello.d.authentication.challenge
                }
                if (-not (WS-Send $ws $ident)) { Start-Sleep -Milliseconds 2000; continue }

                $idTxt = WS-Recv $ws 5000
                if (-not $idTxt) { Start-Sleep -Milliseconds 2000; continue }
                $identified = $idTxt | ConvertFrom-Json
                if ($identified.op -ne 2) { Start-Sleep -Milliseconds 2000; continue }

                # ------ Screenshot loop ------
                while (-not $shared.StopRequested -and
                    $ws.State -eq [System.Net.WebSockets.WebSocketState]::Open) {

                    $sw = [System.Diagnostics.Stopwatch]::StartNew()

                    # 1. Get current program scene
                    $rid++
                    $sceneReq = @{
                        op = 6
                        d  = @{
                            requestType = 'GetCurrentProgramScene'
                            requestId   = "pw-s$rid"
                            requestData = @{}
                        }
                    }
                    if (-not (WS-Send $ws $sceneReq)) { break }

                    $sceneTxt = WS-Recv $ws 2000
                    if ($shared.StopRequested) { break }
                    $scene = $null
                    if ($sceneTxt) {
                        try {
                            $sm = $sceneTxt | ConvertFrom-Json
                            if ($sm.op -eq 7 -and $sm.d.requestStatus.result) {
                                $scene = [string]$sm.d.responseData.currentProgramSceneName
                                $shared.SceneName = $scene
                            }
                        }
                        catch {}
                    }
                    if (-not $scene) { Start-Sleep -Milliseconds 100; continue }

                    # 2. GetSourceScreenshot
                    $rid++
                    $ssReq = @{
                        op = 6
                        d  = @{
                            requestType = 'GetSourceScreenshot'
                            requestId   = "pw-i$rid"
                            requestData = @{
                                sourceName              = $scene
                                imageFormat             = $shared.ImgFormat
                                imageWidth              = $shared.ImgW
                                imageHeight             = $shared.ImgH
                                imageCompressionQuality = $shared.JpgQ
                            }
                        }
                    }
                    if (-not (WS-Send $ws $ssReq)) { break }

                    $ssTxt = WS-Recv $ws 3000
                    if ($shared.StopRequested) { break }
                    if ($ssTxt) {
                        try {
                            $sm = $ssTxt | ConvertFrom-Json
                            if ($sm.op -eq 7 -and $sm.d.requestStatus.result) {
                                $b64 = [string]$sm.d.responseData.imageData
                                if ($b64 -match 'base64,') {
                                    $b64 = $b64.Substring($b64.IndexOf('base64,') + 7)
                                }
                                $shared.LatestBytes = [Convert]::FromBase64String($b64)
                            }
                        }
                        catch {}
                    }

                    $sw.Stop()
                    $delay = [Math]::Max(40, [int]([Math]::Round($sw.ElapsedMilliseconds * 0.85)))
                    if (-not $shared.StopRequested) { Start-Sleep -Milliseconds $delay }
                } # screenshot loop
            }
            catch {}
            finally {
                try { if ($ws) { $ws.Dispose() } } catch {}
                $ws = $null
            }

            if (-not $shared.StopRequested) { Start-Sleep -Milliseconds 2000 }
        } # reconnect loop
    } # end $workerCode

    # Spin up via dedicated Runspace + [powershell]::Create() — works in PS5.1 and PS7,
    # no module imports required. The shared synchronized hashtable is passed as an argument
    # so the worker thread can safely read/write it without touching $script: vars.
    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = [System.Threading.ApartmentState]::MTA
    $rs.ThreadOptions = [System.Management.Automation.Runspaces.PSThreadOptions]::ReuseThread
    $rs.Open()

    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($workerCode.ToString())
    [void]$ps.AddArgument($script:obsShared)

    $script:obsWorkerPS = $ps
    $script:obsWorkerRS = $rs
    $script:obsWorkerAsync = $ps.BeginInvoke()
}

# ---- Timers (frames, auto-connect, ping) ----
function Ensure-ObsTimer {
    if ($script:ShuttingDown) { return }
    if ($script:obsTimer) { return }

    $script:obsTimer = New-Object System.Windows.Forms.Timer
    $script:obsTimer.Interval = 80           # fast poll — tick is purely in-memory, no network
    $script:_previewSceneTick = 0

    $script:obsTimer.Add_Tick({
            if ($script:ShuttingDown) { return }
            if (-not $script:ObsConnected) { return }
            if (-not $script:pbObs -or $script:pbObs.IsDisposed) { return }
            if (-not $script:obsShared) { return }

            # --- Swap latest frame if worker produced one ---
            $bytes = $script:obsShared.LatestBytes
            if ($bytes) {
                $script:obsShared.LatestBytes = $null   # consume
                $ms = $null; $img = $null
                try {
                    $ms = New-Object System.IO.MemoryStream (, $bytes)
                    $img = [System.Drawing.Image]::FromStream($ms)
                    $old = $script:pbObs.Image
                    $script:pbObs.Image = $img
                    if ($old) { try { $old.Dispose() } catch {} }
                    if ($script:lblHint -and $script:lblHint.Visible) { $script:lblHint.Visible = $false }
                }
                catch {
                    try { if ($img) { $img.Dispose() } } catch {}
                }
                finally {
                    try { if ($ms) { $ms.Dispose() } } catch {}
                }
            }
        }) # end Add_Tick
} # end Ensure-ObsTimer

# ========== AUTO-RECONNECT TIMER ==========
function Ensure-AutoTimer {
    if ($script:obsAutoTimer) { return }
  
    $script:obsAutoTimer = New-Object System.Windows.Forms.Timer
    $script:obsAutoTimer.Interval = 2000
  
    Log "Auto-connect timer started (checks every 2 seconds)"
  
    $script:obsAutoTimer.Add_Tick({
            try {
                if ($script:ShuttingDown) { 
                    # Stop timer immediately on shutdown
                    try { $script:obsAutoTimer.Stop() } catch {}
                    return 
                }
                if ($script:ObsConnected) { return }
                if ($script:_connectInProgress) { return }
      
                Log-Throttled "auto-connect" "Auto-connect: attempting connection..." 10
      
                $script:_connectInProgress = $true
      
                # Try connecting DIRECTLY on UI thread instead of background thread
                try {
                    # Double-check shutdown before expensive connect operation
                    if ($script:ShuttingDown) { return }
        
                    $result = Connect-Obs
        
                    if ($result) {
                        Set-ObsStatusIndicator $true "auto-connected"
                        if ($script:lblHint) { $script:lblHint.Visible = $false }
                        Log "Auto-connect: SUCCESS!"
                        
                        # Check for Auto Start scenes after successful auto-connection
                        Trigger-AutoStartScenes
                    }
                    else {
                        Log "Auto-connect: Connect-Obs returned false"
                    }
                }
                catch {
                    $errMsg = try { Get-RootErrorMessage $_.Exception } catch { "$_" }
                    Log ("Auto-connect failed: " + $errMsg)
                }
                finally {
                    $script:_connectInProgress = $false
                }
      
            }
            catch {
                $script:_connectInProgress = $false
                Log "Auto-connect: outer catch - $_"
            }
        })
  
    $script:obsAutoTimer.Start()
}

# --- OBS heartbeat timer: verifies socket state every 2s ---
if (-not (Get-Variable -Scope Script -Name obsPingTimer -ErrorAction SilentlyContinue)) {
    $script:obsPingTimer = New-Object System.Windows.Forms.Timer
    $script:obsPingTimer.Interval = 2000
    $script:obsPingTimer.Add_Tick({
            try {
                if ($script:ShuttingDown) { return }

                $isUp = $false
                try {
                    $isUp = ($script:ObsWS -and $script:ObsWS.State -eq [System.Net.WebSockets.WebSocketState]::Open)
                }
                catch { $isUp = $false }

                if (-not $isUp) {
                    # If we thought we were connected, mark cleanly offline
                    if ($script:ObsConnected) {
                        Close-Obs
                    }
                    else {
                        # Keep the hint visible/on-top while offline
                        if ($script:lblHint) {
                            Set-LabelTextSafe $script:lblHint "Waiting for OBS..."
                            $script:lblHint.Visible = $true
                            try { $script:lblHint.BringToFront() } catch {}
                        }
                        try { Set-ObsStatusIndicator $false "waiting…" } catch {}
                    }
                }
                else {
                    # still online: keep visuals green
                    try { Set-ObsStatusIndicator $true "online" } catch {}
                }
            }
            catch {}
        })
}



# 3D gradient helper — call once per button after its BackColor/ForeColor are set.
# Reads BackColor dynamically on each repaint so color changes (enable/disable, state)
# are reflected automatically without extra code.
function Apply-Btn3D {
    param([System.Windows.Forms.Button]$b)
    if (-not $b -or $b.IsDisposed) { return }
    $b.FlatAppearance.BorderSize = 0
    $b.Add_Paint({
            param($bSr, $pe)
            $g = $pe.Graphics
            $rc = $bSr.ClientRectangle
            if ($rc.Width -le 0 -or $rc.Height -le 0) { return }
            $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
            $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit
            $base = $bSr.BackColor
            $topC = [System.Drawing.Color]::FromArgb([Math]::Min(255, $base.R + 70), [Math]::Min(255, $base.G + 70), [Math]::Min(255, $base.B + 70))
            $botC = [System.Drawing.Color]::FromArgb([Math]::Max(0, $base.R - 35), [Math]::Max(0, $base.G - 35), [Math]::Max(0, $base.B - 35))
            $lgb = New-Object System.Drawing.Drawing2D.LinearGradientBrush($rc, $topC, $botC, [System.Drawing.Drawing2D.LinearGradientMode]::Vertical)
            $g.FillRectangle($lgb, $rc); $lgb.Dispose()
            $sH = [Math]::Max(1, [Math]::Min($rc.Height - 1, [int]($rc.Height * 0.42)))
            $sR = [System.Drawing.Rectangle]::new(0, 0, $rc.Width, $sH)
            $shin = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
                $sR,
                [System.Drawing.Color]::FromArgb(80, 255, 255, 255),
                [System.Drawing.Color]::FromArgb(0, 255, 255, 255),
                [System.Drawing.Drawing2D.LinearGradientMode]::Vertical)
            $g.FillRectangle($shin, $sR); $shin.Dispose()
            $pen2 = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(50, 50, 50), 1)
            $g.DrawRectangle($pen2, 0, 0, $rc.Width - 1, $rc.Height - 1); $pen2.Dispose()
            if (-not [string]::IsNullOrEmpty($bSr.Text)) {
                $sf2 = New-Object System.Drawing.StringFormat
                $sf2.Alignment = [System.Drawing.StringAlignment]::Center
                $sf2.LineAlignment = [System.Drawing.StringAlignment]::Center
                $sf2.FormatFlags = [System.Drawing.StringFormatFlags]::NoWrap
                $sb3 = New-Object System.Drawing.SolidBrush($bSr.ForeColor)
                $g.DrawString($bSr.Text, $bSr.Font, $sb3,
                    [System.Drawing.RectangleF]::new(0, 0, $rc.Width, $rc.Height), $sf2)
                $sb3.Dispose(); $sf2.Dispose()
            }
        })
}

# Row 1
$btnAuto = New-Object System.Windows.Forms.Button
$btnAuto.Text = "Start Auto Toggle"; $btnAuto.Size = Sz 180 35; $btnAuto.Location = Pt 14 430
$btnAuto.UseVisualStyleBackColor = $false
$btnAuto.FlatStyle = 'Flat'
$btnAuto.FlatAppearance.BorderSize = 1
$btnAuto.BackColor = [System.Drawing.Color]::FromArgb(192, 0, 0)
$btnAuto.ForeColor = [System.Drawing.Color]::White
$btnAuto.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(140, 0, 0)
# Apply rounded corners to auto toggle button
Set-RoundedCorners $btnAuto 12
$script:form.Controls.Add($btnAuto)

# Status chip (non-interactive, always light blue)
$script:chip = New-Object System.Windows.Forms.Button
$script:chip.Name = 'chip'
$script:chip.Text = 'Inactive'
$script:chip.Size = Sz 130 35
$script:chip.Location = Pt ($btnAuto.Left + $btnAuto.Width + 6) 430
$script:chip.FlatStyle = 'Flat'
$script:chip.FlatAppearance.BorderSize = 1

# IMPORTANT: keep it enabled so colors apply; make it non-focusable & no-op
$script:chip.Enabled = $true
$script:chip.TabStop = $false
$script:chip.UseVisualStyleBackColor = $false
$script:chip.Add_Click({})   # no action

# Light-blue style
$script:chip.BackColor = [Drawing.Color]::FromArgb(128, 128, 128)          # grey matching Zoom control buttons
$script:chip.ForeColor = [Drawing.Color]::White
$script:chip.FlatAppearance.BorderColor = [Drawing.Color]::FromArgb(96, 96, 96)

# Apply rounded corners to status chip for pill shape
Set-RoundedCorners $script:chip 18
$script:form.Controls.Add($script:chip)

# --- OBS status indicator button (unified, auto-connect friendly) ---
# Creates the button in the same spot/size, acts as a live status light.
if ($btnObsConnect -and -not $btnObsConnect.IsDisposed) {
    try { $btnObsConnect.Dispose() } catch {}
}
$btnObsConnect = New-Object System.Windows.Forms.Button
$btnObsConnect.Text = "Start OBS WS"
$btnObsConnect.Size = Sz 140 35
$btnObsConnect.Location = Pt ($script:chip.Left + $script:chip.Width + 6) 430
$btnObsConnect.FlatStyle = 'Flat'
$btnObsConnect.FlatAppearance.BorderSize = 1
$btnObsConnect.UseVisualStyleBackColor = $false
# Apply rounded corners to OBS button
Set-RoundedCorners $btnObsConnect 12
$script:form.Controls.Add($btnObsConnect)

# Keep it pinned to bottom-left like your other bottom row items
Set-Anchor $btnObsConnect 'Bottom, Left'

# Let preview/other code reference the same indicator
$script:btnObsWS = $btnObsConnect

# --- V-Cam Status Window (positioned to the right of OBS WS button) ---
if ($script:btnVCamStatus -and -not $script:btnVCamStatus.IsDisposed) {
    try { $script:btnVCamStatus.Dispose() } catch {}
}
$script:btnVCamStatus = New-Object System.Windows.Forms.Button
# Try different emoji/symbol approaches for better compatibility
try {
    # Method 1: Direct Unicode escape
    $script:btnVCamStatus.Text = [char]0x1F3A5  # 🎥
    # Set font that's more likely to support emoji - increased size
    $script:btnVCamStatus.Font = New-Object System.Drawing.Font("Segoe UI Emoji", 16, [System.Drawing.FontStyle]::Regular)
}
catch {
    try {
        # Method 2: Try a different camera-like symbol
        $script:btnVCamStatus.Text = "📷"  # Camera emoji
        $script:btnVCamStatus.Font = New-Object System.Drawing.Font("Segoe UI Symbol", 24, [System.Drawing.FontStyle]::Regular)
    }
    catch {
        # Method 3: Fallback to simple symbols that work everywhere
        $script:btnVCamStatus.Text = "⬤REC"  # Record symbol + text
        $script:btnVCamStatus.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    }
}
$script:btnVCamStatus.Size = Sz 80 35
$script:btnVCamStatus.Location = Pt ($btnObsConnect.Left + $btnObsConnect.Width + 6) 430
$script:btnVCamStatus.FlatStyle = 'Flat'
$script:btnVCamStatus.FlatAppearance.BorderSize = 1
$script:btnVCamStatus.UseVisualStyleBackColor = $false
$script:btnVCamStatus.Enabled = $true  # Enable click functionality
# Apply rounded corners to Virtual Camera button
Set-RoundedCorners $script:btnVCamStatus 12
$script:form.Controls.Add($script:btnVCamStatus)

# Add click event to toggle virtual camera
$script:btnVCamStatus.Add_Click({
        try {
            if (-not $script:ObsConnected) {
                Log "Virtual Camera: OBS not connected"
                return
            }
        
            if ($script:VirtualCameraStatus) {
                # Virtual camera is ON -> turn it OFF
                Log "Virtual Camera: Stopping virtual camera..."
                [void](Invoke-ObsRequest "StopVirtualCam" @{})
                Log "Virtual Camera: Stop command sent"
            }
            else {
                # Virtual camera is OFF -> turn it ON
                Log "Virtual Camera: Starting virtual camera..."
                [void](Invoke-ObsRequest "StartVirtualCam" @{})
                Log "Virtual Camera: Start command sent"
            }
        }
        catch {
            Log "Virtual Camera: Error toggling virtual camera: $_"
        }
    })

# Keep it pinned to bottom-left like other bottom row items
Set-Anchor $script:btnVCamStatus 'Bottom, Left'

# Add tooltip for V-Cam button
if ($script:tooltip) {
    $script:tooltip.SetToolTip($script:btnVCamStatus, "Virtual Camera: Click to toggle OBS Virtual Camera on/off. Grey=OBS disconnected, Flashing Red=Camera off, Blue=Camera on")
}

# --- V-Cam status visual update function ---
function Update-VCamStatusVisual {
    try {
        if (-not $script:btnVCamStatus -or $script:btnVCamStatus.IsDisposed) { return }
        
        # Stop flashing timer first
        if ($script:VCamFlashTimer) {
            $script:VCamFlashTimer.Stop()
        }
        
        if (-not $script:ObsConnected) {
            # OBS not connected -> Grey
            $script:btnVCamStatus.BackColor = [System.Drawing.Color]::LightGray
            $script:btnVCamStatus.ForeColor = [System.Drawing.Color]::Black
        }
        elseif ($script:VirtualCameraStatus) {
            # Virtual camera ON -> Blue
            $script:btnVCamStatus.BackColor = [System.Drawing.Color]::FromArgb(0, 100, 200)
            $script:btnVCamStatus.ForeColor = [System.Drawing.Color]::White
        }
        else {
            # OBS connected but virtual camera OFF -> Flashing Red
            $script:btnVCamStatus.BackColor = [System.Drawing.Color]::FromArgb(200, 0, 0)
            $script:btnVCamStatus.ForeColor = [System.Drawing.Color]::White
            # Start flashing to get user attention
            if ($script:VCamFlashTimer) {
                $script:VCamFlashTimer.Start()
            }
        }
    }
    catch {}
}

# Initialize V-Cam status (Grey when OBS not connected)
Update-VCamStatusVisual

# --- Visuals for the connect button ---
function Update-ObsButtonVisual {
    try {
        if (-not $btnObsConnect -or $btnObsConnect.IsDisposed) { return }
        if ($script:ObsConnected) {
            # ONLINE -> green, black text with OBS logo-like icon
            $btnObsConnect.BackColor = [System.Drawing.Color]::FromArgb(0, 192, 0)
            $btnObsConnect.ForeColor = [System.Drawing.Color]::Black
            $btnObsConnect.Text = "⬤ OBS Online"  # Using record/circle symbol as OBS-like logo
        }
        else {
            # OFFLINE -> red, white text
            $btnObsConnect.BackColor = [System.Drawing.Color]::FromArgb(192, 0, 0)
            $btnObsConnect.ForeColor = [System.Drawing.Color]::White
            $btnObsConnect.Text = "Start OBS WS"
        }
    }
    catch {}
}

# --- Central status setter (used by Connect-Obs/Close-Obs paths) ---
function Set-ObsStatusIndicator([bool]$up, [string]$why = "") {
    try {
        $script:ObsConnected = [bool]$up
        if ($why) { Log "OBS status: $why" }
        Update-ObsButtonVisual
        Update-VCamStatusVisual  # Update V-Cam status when OBS status changes
    }
    catch {}
}

# Initialize (assume offline at startup -> red)
Set-ObsStatusIndicator $false "waiting…"

# --- Click behavior: manual nudge + (dis)connect ---
$btnObsConnect.Add_Click({
        try {
            if (-not $script:ObsConnected) {
                # Try an immediate manual connect
                $ok = $false
                try { $ok = Connect-Obs } catch {}
                if ($ok) {
                    Set-ObsStatusIndicator $true "online"
                    try { if ($script:lblHint) { $script:lblHint.Visible = $false } } catch {}
                }
                else {
                    Set-ObsStatusIndicator $false "connect failed"
                    try {
                        if ($script:lblHint) {
                            $script:lblHint.Text = "Waiting for OBS..."
                            $script:lblHint.Visible = $true
                        }
                    }
                    catch {}
                }
            }
            else {
                # Manual disconnect
                try { Close-Obs } catch {}
                Set-ObsStatusIndicator $false "disconnected"
                try {
                    if ($script:lblHint) {
                        $script:lblHint.Text = "Waiting for OBS..."
                        $script:lblHint.Visible = $true
                    }
                }
                catch {}
            }
        }
        catch {}
    })

# --- Compatibility shim for older callers expecting Update-ObsButton($bool) ---
function Update-ObsButton([bool]$ok, [string]$why = "") {
    try { Set-ObsStatusIndicator -up $ok -why $why } catch {}
}

# --- Lightweight heartbeat to keep visuals in sync with state changes elsewhere ---
if ($script:obsBtnPulseTimer -and -not $script:obsBtnPulseTimer.IsDisposed) {
    try { $script:obsBtnPulseTimer.Stop(); $script:obsBtnPulseTimer.Dispose() } catch {}
}
$script:obsBtnPulseTimer = New-Object System.Windows.Forms.Timer
$script:obsBtnPulseTimer.Interval = 800
$script:obsBtnPulseTimer.Add_Tick({
        try {
            # Ensure auto-timer is alive (harmless if already created)
            try { Ensure-AutoTimer } catch {}
            # Just refresh the button look from current $script:ObsConnected
            Update-ObsButtonVisual
        }
        catch {}
    })
$script:obsBtnPulseTimer.Start()
# =========================
# Row 2 – Blank / <Cut / Camera / Media
# Behavior per v3.4dark:
#   - Startup: Blank & Camera show "Speaker".
#   - Left-click Camera: select "Speaker" (no cycling).
#   - Right-click Camera: dropdown (Speaker first).
#   - <Cut: switch to selected; then Camera resets to "Speaker".
# =========================

# text width helper
if (-not (Get-Command Get-ButtonWidthForText -ErrorAction SilentlyContinue)) {
    function Get-ButtonWidthForText([string]$text, [System.Drawing.Font]$font, [int]$padding = 26) {
        $sz = [System.Windows.Forms.TextRenderer]::MeasureText($text, $font)
        return [int]([math]::Ceiling($sz.Width + $padding))
    }
}

# scene selection state
$DEFAULT_SPEAKER = "Speaker"
$script:SelectedScene = $DEFAULT_SPEAKER
$script:_AllScenes = @()

function Refresh-ObsSceneList {
    try {
        $list = Obs-GetSceneNames
        if ($list -and $list.Count -gt 0) {
            # Filter out Media scene first, then reorder with Speaker on top and reverse the rest
            $mediaName = [string]$script:Cfg.OBS.SceneMed
            $filteredScenes = @()
            foreach ($sceneName in $list) {
                # Skip Media scene if configured
                if (-not [string]::IsNullOrWhiteSpace($mediaName) -and
                    [string]::Equals($sceneName, $mediaName, [System.StringComparison]::InvariantCultureIgnoreCase)) {
                    continue
                }
                $filteredScenes += $sceneName
            }
            
            # Put Speaker first, then reverse order of remaining scenes
            $speaker = $filteredScenes | Where-Object { $_ -ieq $DEFAULT_SPEAKER }
            $rest = $filteredScenes | Where-Object { $_ -ine $DEFAULT_SPEAKER }
            # Reverse the order of non-Speaker scenes
            [array]::Reverse($rest)
            
            if ($speaker) { 
                $script:_AllScenes = @($DEFAULT_SPEAKER) + @($rest) 
            }
            else { 
                # If no Speaker scene, just reverse the filtered list
                [array]::Reverse($filteredScenes)
                $script:_AllScenes = @($filteredScenes) 
            }
        }
        else {
            $script:_AllScenes = @()
        }
    }
    catch { $script:_AllScenes = @() }
    if (-not $script:_AllScenes -or $script:_AllScenes.Count -eq 0) {
        # fallback list if OBS not connected yet (keeping Speaker first, omitting Media)
        $script:_AllScenes = @("Speaker", "Camera")
    }
}

function Show-ScenePickerForCamera([System.Windows.Forms.Control]$anchor, [System.Drawing.Point]$pt) {
    Refresh-ObsSceneList

    # Use the scene list as-is (Media scene already filtered in Refresh-ObsSceneList)
    $list = $script:_AllScenes

    $cm = New-Object System.Windows.Forms.ContextMenuStrip
    foreach ($n in $list) {
        $item = New-Object System.Windows.Forms.ToolStripMenuItem $n
        if ([string]::Equals($n, $script:SelectedScene, [System.StringComparison]::InvariantCultureIgnoreCase)) {
            $item.Checked = $true
        }
        $item.Tag = $n
        $item.Add_Click({
                $sel = [string]$this.Tag
                $script:SelectedScene = $sel
                try { $btnCam.Text = $script:SelectedScene } catch {}
                # Start Cut button flashing when scene is selected
                Start-CutButtonFlash
            })
        [void]$cm.Items.Add($item)
    }

    try { $cm.Show($anchor, $pt) } catch { $cm.Show($anchor, 0, $anchor.Height) }
}

# layout sizing
$__btnRowY = 492
$__gap = 8
$__fitCommon = 150
try { $__fitCommon = Get-ButtonWidthForText "Speaker+Rovers+Reader" $script:form.Font } catch {}
$__cutWidth = 0
try { $__cutWidth = Get-ButtonWidthForText "<Cut" $script:form.Font } catch { $__cutWidth = 70 }
$__mediaWidth = 80
try { $__mediaWidth = Get-ButtonWidthForText "Media" $script:form.Font } catch { $__mediaWidth = 80 }

# Calculate the minimum form width required to fit all button-row controls without overlap:
# left_margin + Blank + gap + Cut + gap + gap + Cam + gap + Media + right_margin + padding
$__requiredFormWidth = 14 + $__fitCommon + $__gap + $__cutWidth + $__gap + $__gap + $__fitCommon + $__gap + $__mediaWidth + 14 + 20
if ($__requiredFormWidth -lt 600) { $__requiredFormWidth = 600 }
$script:_baseMinW = $__requiredFormWidth   # store for Apply-UIScale
# Set only the MINIMUM width — prevents overlap. No MaximumSize so DPI scaling works freely.
$script:form.MinimumSize = New-Object System.Drawing.Size($__requiredFormWidth, $script:form.MinimumSize.Height)
if ($script:form.ClientSize.Width -lt $__requiredFormWidth) {
    $script:form.ClientSize = New-Object System.Drawing.Size($__requiredFormWidth, $script:form.ClientSize.Height)
}

# --- Row 2: create / place controls (with labels) ---

# Static labels to clarify functions - Program label will be positioned over Camera button later
$lblProgram = New-Object System.Windows.Forms.Label
$lblProgram.AutoSize = $true
$lblProgram.Text = 'Program:'
$script:form.Controls.Add($lblProgram)

# Leftmost "Blank" (startup: Speaker)
$btnBlank = New-Object System.Windows.Forms.Button
$btnBlank.Name = 'btnBlank'
$btnBlank.Text = $DEFAULT_SPEAKER
$btnBlank.Size = Sz $__fitCommon 35
$btnBlank.Location = Pt 14 $__btnRowY
$btnBlank.UseVisualStyleBackColor = $false
$btnBlank.FlatStyle = 'Flat'
$btnBlank.FlatAppearance.BorderSize = 1
$btnBlank.BackColor = [Drawing.Color]::FromArgb(45, 158, 73)
$btnBlank.ForeColor = [Drawing.Color]::White
$btnBlank.FlatAppearance.BorderColor = [Drawing.Color]::FromArgb(34, 115, 53)
# Apply rounded corners to blank button
Set-RoundedCorners $btnBlank 12
$script:form.Controls.Add($btnBlank)

# "<Cut" button (width fits its text)
$btnCut = New-Object System.Windows.Forms.Button
$btnCut.Name = 'btnCut'
$btnCut.Text = '<Cut'
$btnCut.Size = Sz $__cutWidth 35
$btnCut.Location = Pt ($btnBlank.Left + $btnBlank.Width + $__gap) $__btnRowY
$script:form.Controls.Add($btnCut)
$script:btnCut = $btnCut  # Store reference for timer access
$btnCut.UseVisualStyleBackColor = $false
$btnCut.FlatStyle = 'Flat'
$btnCut.FlatAppearance.BorderSize = 1
$btnCut.BackColor = [Drawing.Color]::FromArgb(45, 158, 73)
$btnCut.ForeColor = [Drawing.Color]::White
$btnCut.FlatAppearance.BorderColor = [Drawing.Color]::FromArgb(34, 115, 53)
# Apply rounded corners to cut button
Set-RoundedCorners $btnCut 12

# ScenePicker label will be positioned over the Camera button area later
$lblPicker = New-Object System.Windows.Forms.Label
$lblPicker.AutoSize = $true
$lblPicker.Text = 'ScenePicker:'
$script:form.Controls.Add($lblPicker)
$pickerRight = [int]($btnCut.Left + $btnCut.Width + $__gap)

# Camera (startup: Speaker) — selection only
$btnCam = New-Object System.Windows.Forms.Button
$btnCam.Name = 'btnCam'
$btnCam.Text = $DEFAULT_SPEAKER
$btnCam.Size = Sz $__fitCommon 35
$btnCam.Location = Pt ($pickerRight + $__gap) $__btnRowY
$btnCam.UseVisualStyleBackColor = $false
$btnCam.FlatStyle = 'Flat'
$btnCam.FlatAppearance.BorderSize = 1
$btnCam.BackColor = [Drawing.Color]::FromArgb(45, 73, 158)
$btnCam.ForeColor = [Drawing.Color]::White
$btnCam.FlatAppearance.BorderColor = [Drawing.Color]::FromArgb(34, 53, 115)
# Apply rounded corners to camera button
Set-RoundedCorners $btnCam 12
$script:form.Controls.Add($btnCam)
$script:btnCam = $btnCam  # Store reference for tooltips

# -- camera scene helper (use current selection; fallback to Speaker)
function Get-CameraScene {
    if ([string]::IsNullOrWhiteSpace($script:SelectedScene)) { return $DEFAULT_SPEAKER }
    return $script:SelectedScene
}

# Media (instant switch to configured Media)
$btnMed = New-Object System.Windows.Forms.Button
$btnMed.Name = 'btnMed'
$btnMed.Text = 'Media'
$btnMed.Size = Sz $__mediaWidth 35
$btnMed.Location = Pt ([int]($__requiredFormWidth - $__mediaWidth - 14)) $__btnRowY
$btnMed.UseVisualStyleBackColor = $false
$btnMed.FlatStyle = 'Flat'
$btnMed.FlatAppearance.BorderSize = 1
$btnMed.BackColor = [Drawing.Color]::FromArgb(45, 73, 158)
$btnMed.ForeColor = [Drawing.Color]::White
$btnMed.FlatAppearance.BorderColor = [Drawing.Color]::FromArgb(34, 53, 115)
# Apply rounded corners to media button
Set-RoundedCorners $btnMed 12
$script:form.Controls.Add($btnMed)
$script:btnMed = $btnMed  # Store reference for tooltips
$btnMed.Add_Click({
        try {
            # If we’re manually going to Media, remember where we came from (if not already Media)
            if ($script:_lastProgramScene -and -not [string]::Equals($script:_lastProgramScene, $script:Cfg.OBS.SceneMed, 'InvariantCultureIgnoreCase')) {
                $script:_preMediaScene = $script:_lastProgramScene
            }
            [void](Program-Switch $script:Cfg.OBS.SceneMed)
        }
        catch {}
    })

# Position labels over their respective buttons
$lblProgram.Location = Pt ([int]($btnBlank.Left + ($btnBlank.Width - $lblProgram.PreferredSize.Width) / 2)) ($__btnRowY - 20)
$lblPicker.Location = Pt ([int]($btnCam.Left + ($btnCam.Width - $lblPicker.PreferredSize.Width) / 2)) ($__btnRowY - 20)


# StatusStrip already docks to Bottom (good)
$status.Dock = 'Bottom'
# Size preview panel to the actual (DPI-adjusted) form width before anchoring,
# so the anchor records the correct right margin (not the stale 570px hardcoded value)
$script:pPreview.Width = $__requiredFormWidth - 28   # 14px left + 14px right
# Preview panel should grow with the window
$script:pPreview.Anchor = 'Top, Left, Right, Bottom'

# Bottom “row 2” items should stick to the bottom-left
$lblProgram.Anchor = 'Bottom, Left'
$btnBlank.Anchor = 'Bottom, Left'
$btnCut.Anchor = 'Bottom, Left'
$lblPicker.Anchor = 'Bottom, Left'
$btnCam.Anchor = 'Bottom, Left'
$btnMed.Anchor = 'Bottom, Right'

# PiP toggle blip button — sits above top-right corner of Media button (same coord space as badges)
$btnPip = New-Object System.Windows.Forms.Button
$btnPip.Text = [char]::ConvertFromUtf32(0x1F501)   # 🔁
$btnPip.Font = New-Object System.Drawing.Font('Segoe UI Emoji', 7, [System.Drawing.FontStyle]::Regular)
$btnPip.Size = [System.Drawing.Size]::new(32, 18)
$btnPip.Location = [System.Drawing.Point]::new($btnMed.Right - 32, $btnMed.Top - 14)
$btnPip.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnPip.FlatAppearance.BorderSize = 0
$btnPip.BackColor = [System.Drawing.Color]::FromArgb(210, 90, 0)   # orange = PiP OFF
$btnPip.ForeColor = [System.Drawing.Color]::White
$btnPip.UseVisualStyleBackColor = $false
$btnPip.Cursor = [System.Windows.Forms.Cursors]::Hand
$btnPip.Anchor = 'Bottom, Right'
$btnPip.Visible = [bool]$script:Cfg.PiP.Enabled
$btnPip.Add_Click({ Toggle-MediaPip })
$script:form.Controls.Add($btnPip)
$btnPip.BringToFront()
$script:btnPip = $btnPip
# Rounded corners
try {
    $pip_path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $pip_r = 7; $pip_w = $btnPip.Width; $pip_h = $btnPip.Height
    $pip_path.AddArc(0, 0, $pip_r, $pip_r, 180, 90)
    $pip_path.AddArc($pip_w - $pip_r, 0, $pip_r, $pip_r, 270, 90)
    $pip_path.AddArc($pip_w - $pip_r, $pip_h - $pip_r, $pip_r, $pip_r, 0, 90)
    $pip_path.AddArc(0, $pip_h - $pip_r, $pip_r, $pip_r, 90, 90)
    $pip_path.CloseFigure()
    $btnPip.Region = New-Object System.Drawing.Region($pip_path)
}
catch {}

# Rows below the main scene-picker row — REC, JWL, Zoom controls, Hand Alert


# Music toggle sits under the row — also bottom-left
Set-Anchor $btnMusicToggle 'Bottom, Left'


# Status “chip” and OBS button on the same row – bottom-left
$script:chip.Anchor = 'Bottom, Left'
$btnObsConnect.Anchor = 'Bottom, Left'

# Keep the theme button pinned to top-right (you already have this)
# (leave your existing $script:form.Add_Resize handler for $btnTheme in place)

# --- Track current & pre-media scene ---
if (-not $DEFAULT_SPEAKER) { $DEFAULT_SPEAKER = 'Speaker' }

# Last scene we successfully put on Program (kept in sync everywhere we switch)
$script:_lastProgramScene = if ([string]::IsNullOrWhiteSpace($btnBlank.Text)) { $script:SelectedScene } else { $btnBlank.Text }
if ([string]::IsNullOrWhiteSpace($script:_lastProgramScene)) { $script:_lastProgramScene = $DEFAULT_SPEAKER }

# If we auto-switch to Media, remember what we were on so we can come back
$script:_preMediaScene = $null

# PiP (Picture-in-Picture) state
$script:_pipOn = $false
$script:_pipItemId = $null   # cached SceneItemId ($null = not tried, >0 = found)
$script:_pipItemNotFound = $false  # true = source not in OBS; stops retrying until scene re-entered
$script:btnPip = $null   # reference to the PiP blip button

function Get-PipItemId {
    if ($script:_pipItemNotFound) { return $null }   # already tried & failed — don't spam OBS
    if ($null -ne $script:_pipItemId) { return $script:_pipItemId }
    # Use GetSceneItemList + trimmed name match — avoids GetSceneItemId failing on trailing spaces
    try {
        $r = Invoke-ObsRequest "GetSceneItemList" @{ sceneName = [string]$script:Cfg.OBS.SceneMed }
        $target = ([string]$script:Cfg.PiP.SourceName).Trim()
        $item = $r.sceneItems | Where-Object { $_.sourceName -and $_.sourceName.Trim() -eq $target } | Select-Object -First 1
        if ($item -and ($item.PSObject.Properties.Name -contains 'sceneItemId')) {
            $script:_pipItemId = [int]$item.sceneItemId
            Log "PiP: cached id=$($script:_pipItemId) for '$($item.sourceName.Trim())'"
            return $script:_pipItemId
        }
        $names = ($r.sceneItems | ForEach-Object { "'$($_.sourceName)'" }) -join ', '
        Log "PiP: '$target' not found in '$($script:Cfg.OBS.SceneMed)'. Available: $names"
        $script:_pipItemNotFound = $true
    }
    catch {
        Log "PiP: GetSceneItemList error: $_"
        $script:_pipItemNotFound = $true
    }
    return $null
}

function Set-PipVisible([bool]$visible) {
    try {
        $id = Get-PipItemId
        if ($null -eq $id) { Log "PiP: source '$($script:Cfg.PiP.SourceName)' not found in Media scene"; return }
        Invoke-ObsRequest "SetSceneItemEnabled" @{
            sceneName        = [string]$script:Cfg.OBS.SceneMed
            sceneItemId      = $id
            sceneItemEnabled = $visible
        } | Out-Null
        $script:_pipOn = $visible
    }
    catch { Log "PiP: SetSceneItemEnabled error: $_" }
}

function Update-PipButton {
    try {
        if (-not $script:btnPip -or $script:btnPip.IsDisposed) { return }
        if ($script:_pipOn) {
            $script:btnPip.BackColor = [System.Drawing.Color]::FromArgb(0, 180, 60)   # green = ON
            $script:btnPip.ForeColor = [System.Drawing.Color]::White
        }
        else {
            $script:btnPip.BackColor = [System.Drawing.Color]::FromArgb(210, 90, 0)   # orange = OFF
            $script:btnPip.ForeColor = [System.Drawing.Color]::White
        }
    }
    catch {}
}

function Toggle-MediaPip {
    # Always reset the "not found" sentinel so each click retries the OBS lookup
    $script:_pipItemNotFound = $false
    $script:_pipItemId = $null

    # Check live OBS scene (don't rely solely on cached _lastProgramScene)
    $mediaScene = [string]$script:Cfg.OBS.SceneMed
    $liveScene = try { Get-CurrentProgramSceneName } catch { [string]$script:_lastProgramScene }
    if (-not $liveScene) { $liveScene = [string]$script:_lastProgramScene }

    if (-not [string]::Equals($liveScene, $mediaScene, [StringComparison]::InvariantCultureIgnoreCase)) {
        Log "PiP: toggle ignored — OBS is on '$liveScene', not '$mediaScene'"
        return
    }

    $newState = -not $script:_pipOn
    Set-PipVisible $newState
    Update-PipButton
    Log "PiP: toggled $(if ($script:_pipOn) { 'ON' } else { 'OFF' }) (source='$($script:Cfg.PiP.SourceName)')"
}

# Centralized scene switch that also updates "Blank" label + tracker
function Program-Switch([string]$scene) {
    if ([string]::IsNullOrWhiteSpace($scene)) { return $false }

    # PiP: determine state before switching
    $mediaScene = [string]$script:Cfg.OBS.SceneMed
    $goingToMedia = [string]::Equals($scene, $mediaScene, [StringComparison]::InvariantCultureIgnoreCase)
    $wasOnMedia = [string]::Equals($script:_lastProgramScene, $mediaScene, [StringComparison]::InvariantCultureIgnoreCase)
    $isEnteringMedia = $goingToMedia -and -not $wasOnMedia   # true only on actual transition TO Media
    $isLeavingMedia = $wasOnMedia -and -not $goingToMedia   # true only on actual transition FROM Media

    # PiP: force off in OBS before leaving Media so source stays hidden
    if ($isLeavingMedia -and $script:_pipOn) {
        try { Set-PipVisible $false } catch {}
    }

    $ok = Set-ObsScene $scene
    if ($ok) {
        $script:_lastProgramScene = $scene

        # Track when Media scene is switched to (for ducking delay)
        if ($isEnteringMedia) {
            $script:_lastMediaSceneSwitch = Get-Date
        }

        # PiP: reset state only on actual scene transitions, not on same-scene re-calls
        if ($isEnteringMedia) {
            # Clear failure cache so a newly added OBS source is detected on next toggle
            $script:_pipItemId = $null
            $script:_pipItemNotFound = $false
            $script:_pipOn = $false   # always start with PiP off when entering Media
        }
        elseif ($isLeavingMedia) {
            # Leaving Media: hide PiP if active, clear state
            if ($script:_pipOn) { try { Set-PipVisible $false } catch {} }
            $script:_pipOn = $false
            $script:_pipItemId = $null
        }
        if ($isEnteringMedia -or $isLeavingMedia) { try { Update-PipButton } catch {} }

        try { if ($btnBlank) { $btnBlank.Text = $scene } } catch {}
    }
    return $ok
}

# If you don’t already have it from earlier patch:
if (-not (Get-Command Get-CameraScene -ErrorAction SilentlyContinue)) {
    function Get-CameraScene {
        if ([string]::IsNullOrWhiteSpace($script:SelectedScene)) { return $DEFAULT_SPEAKER }
        return $script:SelectedScene
    }
}


# wire behavior
# Camera: right-click = picker; left-click = select Speaker
$btnCam.Add_MouseUp({
        param($src, $e)
        try {
            if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Right) {
                Show-ScenePickerForCamera -anchor $btnCam -pt ([System.Drawing.Point]::new(0, $btnCam.Height))
                return
            }
            if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
                $script:SelectedScene = $DEFAULT_SPEAKER
                $btnCam.Text = $DEFAULT_SPEAKER   # selection label only
                # Start Cut button flashing when scene is selected via left click
                Start-CutButtonFlash
                return
            }
        }
        catch {}
    })

# <Cut: switch to the selected scene; update Blank, then reset Camera selection to Speaker
$script:_ftbActive = $false   # re-entry guard: only one fade sequence at a time
$btnCut.Add_Click({
        try {
            $sel = [string]$script:SelectedScene
            if ([string]::IsNullOrWhiteSpace($sel)) { return }

            # Stop Cut button flashing
            Stop-CutButtonFlash

            $fadeScene = [string]$script:Cfg.OBS.FadeBlackScene
            $fadeMs = [int]$script:Cfg.OBS.FadeBlackMs
            $holdMs = [int]$script:Cfg.OBS.FadeBlackHoldMs
            $useFade = (-not [string]::IsNullOrWhiteSpace($fadeScene) -and $script:ObsConnected -and $fadeMs -gt 0)

            # Only use black-hold sequence when the PTZ preset actually changes.
            # - Target has no PTZ (PTZ#=-1) → no camera move needed → skip black
            # - Target PTZ# == current scene PTZ# → camera already in position → skip black
            # - Target PTZ# differs from current PTZ# → camera must move → use black
            if ($useFade) {
                $selMatch = $null
                foreach ($row in @($script:Cfg.ScenePTZ)) {
                    if ($row -and $row.Scene -and [string]::Equals([string]$row.Scene, $sel, 'InvariantCultureIgnoreCase')) { $selMatch = $row; break }
                }
                $targetPtz = if ($selMatch -and $null -ne $selMatch.PTZRecall) { [int]$selMatch.PTZRecall } else { -1 }

                # No PTZ on target → skip black
                if ($targetPtz -lt 1) {
                    $useFade = $false
                }
                else {
                    # Look up current scene's PTZ#
                    $curMatch = $null
                    $curScene = [string]$script:_lastProgramScene
                    foreach ($row in @($script:Cfg.ScenePTZ)) {
                        if ($row -and $row.Scene -and [string]::Equals([string]$row.Scene, $curScene, 'InvariantCultureIgnoreCase')) { $curMatch = $row; break }
                    }
                    $currentPtz = if ($curMatch -and $null -ne $curMatch.PTZRecall) { [int]$curMatch.PTZRecall } else { -1 }

                    # Same PTZ preset → camera already in position → skip black
                    if ($currentPtz -eq $targetPtz) {
                        $useFade = $false
                    }
                }
            }

            # If a fade is already running, fall through to direct cut so the
            # user is never locked out
            if ($useFade -and $script:_ftbActive) { $useFade = $false }

            if ($useFade) {
                $script:_ftbActive = $true
                $btnCut.Enabled = $false   # prevent double-click during fade
                # ── Cut-to-black + slow fade-in sequence ────────────────────────────
                # Timing:
                #   t=0          : INSTANT CUT to Black scene; PTZ command fired immediately
                #                  Camera starts moving while output is solid black
                #   t=holdMs     : Set OBS transition → Fade at fadeMs duration
                #                  Program-Switch to target → OBS fades IN slowly over fadeMs
                #   t=holdMs+fadeMs+100 : restore original OBS transition
                #
                # Settings meaning in this mode:
                #   FadeBlackMs    = fade-IN duration (e.g. 2500 ms for a slow reveal)
                #   FadeBlackHoldMs = time to hold on solid black before fade-in begins
                #                     (set small, e.g. 300, if camera is fast;
                #                      set larger, e.g. 1500, if camera needs more time)
                $script:_ftbTargetScene = $sel
                $script:_ftbFadeMs = $fadeMs
                $script:_ftbHoldMs = $holdMs

                # Save current OBS transition
                $script:_ftbOrigTrans = $null
                try {
                    $tr = Invoke-ObsRequest "GetCurrentSceneTransition" @{}
                    $script:_ftbOrigTrans = @{ name = [string]$tr.transitionName; duration = [int]$tr.transitionDuration }
                }
                catch { $script:_ftbOrigTrans = $null }

                # Phase 1: instant CUT to black scene
                try { Invoke-ObsRequest "SetCurrentSceneTransition" @{ transitionName = "Cut" } | Out-Null } catch {}
                try { Invoke-ObsRequest "SetCurrentProgramScene" @{ sceneName = $fadeScene } | Out-Null } catch {}

                # Fire PTZ immediately — camera moves while output is solid black
                try {
                    $match = $null
                    foreach ($row in @($script:Cfg.ScenePTZ)) {
                        if ($row -and $row.Scene -and [string]::Equals([string]$row.Scene, $sel, 'InvariantCultureIgnoreCase')) { $match = $row; break }
                    }
                    if ($match -and $null -ne $match.Snapshot -and -not $script:_autoModeActive) {
                        XR-LoadSnapshot ([int]$match.Snapshot)
                    }
                    # Pre-fire OBS PTZ preset via WebSocket hotkey so camera arrives before scene activates
                    if ($match -and $null -ne $match.PTZRecall -and [int]$match.PTZRecall -ge 0) {
                        try { Invoke-ObsRequest 'TriggerHotkeyByName' @{ hotkeyName = "PTZ.Recall$([int]$match.PTZRecall)" } | Out-Null } catch {}
                    }
                }
                catch {}

                # Phase 2: after holdMs, restore original transition and switch to target
                $t1 = New-Object System.Windows.Forms.Timer
                $t1.Interval = [Math]::Max(50, $holdMs)
                $t1.Add_Tick({
                        param($snd, $ev)
                        $snd.Stop(); $snd.Dispose()
                        # Restore original OBS transition so target scene uses it
                        if ($script:_ftbOrigTrans) {
                            try {
                                Invoke-ObsRequest "SetCurrentSceneTransition" @{ transitionName = $script:_ftbOrigTrans.name } | Out-Null
                                Invoke-ObsRequest "SetCurrentSceneTransitionDuration" @{ transitionDuration = $script:_ftbOrigTrans.duration } | Out-Null
                            }
                            catch {}
                        }
                        [void](Program-Switch $script:_ftbTargetScene)

                        # Phase 3: after original transition completes, release guard
                        $restoreMs = if ($script:_ftbOrigTrans -and $script:_ftbOrigTrans.duration -gt 0) { $script:_ftbOrigTrans.duration + 100 } else { 600 }
                        $t2 = New-Object System.Windows.Forms.Timer
                        $t2.Interval = [Math]::Max(100, $restoreMs)
                        $t2.Add_Tick({
                                param($snd2, $ev2)
                                $snd2.Stop(); $snd2.Dispose()
                                $script:_ftbOrigTrans = $null
                                # Release guard and re-enable Cut button
                                $script:_ftbActive = $false
                                try { $btnCut.Enabled = $true } catch {}
                            })
                        $t2.Start()
                    })
                $t1.Start()
            }
            else {
                # ── Original direct cut (fade disabled or OBS not connected) ───────────
                [void](Program-Switch $sel)
                try {
                    if (-not [string]::IsNullOrWhiteSpace($sel)) {
                        $match = $null
                        foreach ($row in @($script:Cfg.ScenePTZ)) {
                            if ($row -and $row.Scene -and [string]::Equals([string]$row.Scene, $sel, 'InvariantCultureIgnoreCase')) { $match = $row; break }
                        }
                        if ($match -and $null -ne $match.Snapshot) {
                            if (-not $script:_autoModeActive) {
                                XR-LoadSnapshot ([int]$match.Snapshot)
                            }
                            else {
                                Log "ScenePicker: Snapshot auto-load skipped — Auto Mode is active"
                            }
                        }
                    }
                }
                catch {}
            }
        }
        catch {}
    })

# Music toggle
$btnMusicToggle = New-Object System.Windows.Forms.Button
# Modern music button with music note icon
$btnMusicToggle.Text = "♪ Play Music"  # Modern music note icon
$btnMusicToggle.Size = Sz 130 35
$btnMusicToggle.Font = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Regular)
$btnMusicToggle.Location = Pt 14 ($btnCam.Bottom + 15)
$btnMusicToggle.FlatStyle = 'Flat'
$btnMusicToggle.UseVisualStyleBackColor = $false
# Apply rounded corners to music button
Set-RoundedCorners $btnMusicToggle 12

# OBS Record button — icon drawn via GDI+ for guaranteed color
$script:_obsRecIdleImage = New-ClapperboardBitmap   # lavender/white/black clapperboard
$script:_obsRecActiveImage = New-RecordDotBitmap       # red record dot

$btnOBSRecord = New-Object System.Windows.Forms.Button
$btnOBSRecord.Name = 'btnOBSRecord'
$btnOBSRecord.Text = ''          # everything drawn in Paint handler
$btnOBSRecord.Size = Sz 110 35
$btnOBSRecord.Location = Pt ($btnMusicToggle.Right + 8) ($btnCam.Bottom + 15)
$btnOBSRecord.FlatStyle = 'Flat'
$btnOBSRecord.UseVisualStyleBackColor = $false
$btnOBSRecord.BackColor = [Drawing.Color]::FromArgb(60, 60, 60)
$btnOBSRecord.FlatAppearance.BorderSize = 1
$btnOBSRecord.FlatAppearance.BorderColor = [Drawing.Color]::FromArgb(110, 110, 110)
Set-RoundedCorners $btnOBSRecord 12
# Paint handler: draws icon + 'REC' text perfectly centered
$btnOBSRecord.Add_Paint({
        param($s, $pe)
        $g = $pe.Graphics
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $r = $s.ClientRectangle
        $img = if ($script:OBSRecording) { $script:_obsRecActiveImage } else { $script:_obsRecIdleImage }
        $recStr = 'REC'
        $recFont = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
        $recCol = if ($script:OBSRecording) { [System.Drawing.Color]::White } else { [System.Drawing.Color]::FromArgb(230, 70, 70) }
        $recBrush = New-Object System.Drawing.SolidBrush($recCol)
        $recSz = $g.MeasureString($recStr, $recFont)
        $imgW = if ($img) { $img.Width }  else { 0 }
        $imgH = if ($img) { $img.Height } else { 0 }
        $gap = 5
        $totalW = $imgW + $gap + [int]$recSz.Width
        $startX = [int](($r.Width - $totalW) / 2.0)
        $imgY = [int](($r.Height - $imgH) / 2.0)
        $recY = [int](($r.Height - $recSz.Height) / 2.0)
        if ($img) { $g.DrawImage($img, $startX, $imgY, $imgW, $imgH) }
        $g.DrawString($recStr, $recFont, $recBrush, [float]($startX + $imgW + $gap), [float]$recY)
        $recFont.Dispose(); $recBrush.Dispose()
    })

# Zoom Join Meeting button 
$btnZoomJoin = New-Object System.Windows.Forms.Button
$btnZoomJoin.Text = "Join Zoom"
$btnZoomJoin.Size = Sz 110 35
$btnZoomJoin.Font = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Regular)
$btnZoomJoin.Location = Pt 14 ($btnMusicToggle.Bottom + 10)  # Below music button
$btnZoomJoin.UseVisualStyleBackColor = $false
$btnZoomJoin.FlatStyle = 'Flat'
$btnZoomJoin.FlatAppearance.BorderSize = 1
$btnZoomJoin.BackColor = [Drawing.Color]::FromArgb(0, 120, 215)  # Blue color for Zoom
$btnZoomJoin.ForeColor = [Drawing.Color]::White
$btnZoomJoin.FlatAppearance.BorderColor = [Drawing.Color]::FromArgb(0, 90, 180)
Set-RoundedCorners $btnZoomJoin 12

$script:lblUpdateStatus = New-Object System.Windows.Forms.Label
$script:lblUpdateStatus.AutoSize = $false
$script:lblUpdateStatus.Size = [System.Drawing.Size]::new($btnZoomJoin.Width, 14)
$script:lblUpdateStatus.Location = [System.Drawing.Point]::new($btnZoomJoin.Left, $btnZoomJoin.Bottom + 2)
$script:lblUpdateStatus.Font = New-Object System.Drawing.Font("Segoe UI", 7, [System.Drawing.FontStyle]::Bold)
$script:lblUpdateStatus.ForeColor = [System.Drawing.Color]::LightGray
$script:lblUpdateStatus.BackColor = [System.Drawing.Color]::Transparent
$script:lblUpdateStatus.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
$script:lblUpdateStatus.Text = "Update: --"
$script:lblUpdateStatus.Cursor = [System.Windows.Forms.Cursors]::Default
$script:lblUpdateStatus.Add_Click({
        try {
            if ($script:UpdateAvailable -and -not [string]::IsNullOrWhiteSpace($script:UpdateLatestUrl)) {
                Start-Process $script:UpdateLatestUrl
            }
            else {
                Check-ForAppUpdate
            }
        }
        catch {}
    })

# Zoom Mute All button (same row as Join Zoom)
$btnZoomMuteAll = New-Object System.Windows.Forms.Button
$btnZoomMuteAll.Text = "Mute all"
$btnZoomMuteAll.Size = Sz 85 35
$btnZoomMuteAll.Font = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Regular)
$btnZoomMuteAll.Location = Pt ($btnZoomJoin.Location.X + $btnZoomJoin.Width + 8) ($btnMusicToggle.Bottom + 10)
$btnZoomMuteAll.UseVisualStyleBackColor = $false
$btnZoomMuteAll.FlatStyle = 'Flat'
$btnZoomMuteAll.FlatAppearance.BorderSize = 1
$btnZoomMuteAll.BackColor = [Drawing.Color]::FromArgb(200, 80, 80)
$btnZoomMuteAll.ForeColor = [Drawing.Color]::White
$btnZoomMuteAll.FlatAppearance.BorderColor = [Drawing.Color]::FromArgb(160, 40, 40)
Set-RoundedCorners $btnZoomMuteAll 12

# Microphone Status Icon Button (Segoe MDL2 Assets glyph)
$btnZoomMic = New-Object System.Windows.Forms.Button
$btnZoomMic.Text = [char]0xE720  # Microphone icon
$btnZoomMic.Size = Sz 35 35
$btnZoomMic.Font = New-Object System.Drawing.Font("Segoe MDL2 Assets", 14, [System.Drawing.FontStyle]::Regular)
$btnZoomMic.Location = Pt ($btnZoomMuteAll.Location.X + $btnZoomMuteAll.Width + 8) ($btnMusicToggle.Bottom + 10)
$btnZoomMic.UseVisualStyleBackColor = $false
$btnZoomMic.FlatStyle = 'Flat'
$btnZoomMic.FlatAppearance.BorderSize = 1
$btnZoomMic.BackColor = [Drawing.Color]::FromArgb(128, 128, 128)  # Grey initially
$btnZoomMic.ForeColor = [Drawing.Color]::White
$btnZoomMic.FlatAppearance.BorderColor = [Drawing.Color]::FromArgb(96, 96, 96)
Set-RoundedCorners $btnZoomMic 8
$btnZoomMic.Enabled = $false  # Disabled until Zoom is detected
# Paint handler: draws a red diagonal slash when mic button is locked by Auto Toggle
$btnZoomMic.Add_Paint({
        param($s, $pe)
        if ($script:ZoomMicLocked) {
            $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(220, 255, 70, 70), 2)
            $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
            $pen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
            $r = $s.ClientRectangle
            $pe.Graphics.DrawLine($pen, $r.X + 3, $r.Y + 3, $r.Right - 3, $r.Bottom - 3)
            $pen.Dispose()
        }
    })

# Camera Status Icon Button (Segoe MDL2 Assets glyph)
$btnZoomCamera = New-Object System.Windows.Forms.Button
$btnZoomCamera.Text = [char]0xE714  # Camera icon
$btnZoomCamera.Size = Sz 35 35
$btnZoomCamera.Font = New-Object System.Drawing.Font("Segoe MDL2 Assets", 14, [System.Drawing.FontStyle]::Regular)
$btnZoomCamera.Location = Pt ($btnZoomMic.Location.X + $btnZoomMic.Width + 8) ($btnMusicToggle.Bottom + 10)
$btnZoomCamera.UseVisualStyleBackColor = $false
$btnZoomCamera.FlatStyle = 'Flat'
$btnZoomCamera.FlatAppearance.BorderSize = 1
$btnZoomCamera.BackColor = [Drawing.Color]::FromArgb(128, 128, 128)  # Grey initially
$btnZoomCamera.ForeColor = [Drawing.Color]::White
$btnZoomCamera.FlatAppearance.BorderColor = [Drawing.Color]::FromArgb(96, 96, 96)
Set-RoundedCorners $btnZoomCamera 8
# Paint handler: draws a red diagonal slash when camera button is locked by Auto Toggle
$btnZoomCamera.Add_Paint({
        param($s, $pe)
        if ($script:ZoomCamLocked) {
            $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(220, 255, 70, 70), 2)
            $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
            $pen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
            $r = $s.ClientRectangle
            $pe.Graphics.DrawLine($pen, $r.X + 3, $r.Y + 3, $r.Right - 3, $r.Bottom - 3)
            $pen.Dispose()
        }
    })

# Zoom Polls/Quizzes button (same row as Join Zoom)
$btnZoomPolls = New-Object System.Windows.Forms.Button
$btnZoomPolls.Text = "Polls"
$btnZoomPolls.Size = Sz 60 35
$btnZoomPolls.Font = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Regular)
$btnZoomPolls.Location = Pt ($btnZoomCamera.Location.X + $btnZoomCamera.Width + 8) ($btnMusicToggle.Bottom + 10)
$btnZoomPolls.UseVisualStyleBackColor = $false
$btnZoomPolls.FlatStyle = 'Flat'
$btnZoomPolls.FlatAppearance.BorderSize = 1
$btnZoomPolls.BackColor = [Drawing.Color]::FromArgb(120, 60, 180)
$btnZoomPolls.ForeColor = [Drawing.Color]::White
$btnZoomPolls.FlatAppearance.BorderColor = [Drawing.Color]::FromArgb(90, 40, 140)
Set-RoundedCorners $btnZoomPolls 12
$btnZoomMuteAll.Enabled = $false   # Disabled until Zoom meeting is active
$btnZoomMic.Enabled = $false
$btnZoomCamera.Enabled = $false
$btnZoomPolls.Enabled = $false
$btnZoomMuteAll.BackColor = [Drawing.Color]::FromArgb(128, 128, 128)
$btnZoomPolls.BackColor = [Drawing.Color]::FromArgb(128, 128, 128)

# Zoom Focus Mode toggle button (next to Polls)
$btnZoomFocus = New-Object System.Windows.Forms.Button
$btnZoomFocus.Text = "Focus"
$btnZoomFocus.Size = Sz 60 35
$btnZoomFocus.Font = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Regular)
$btnZoomFocus.Location = Pt ($btnZoomPolls.Location.X + $btnZoomPolls.Width + 8) ($btnMusicToggle.Bottom + 10)
$btnZoomFocus.UseVisualStyleBackColor = $false
$btnZoomFocus.FlatStyle = 'Flat'
$btnZoomFocus.FlatAppearance.BorderSize = 1
$btnZoomFocus.BackColor = [Drawing.Color]::FromArgb(128, 128, 128)
$btnZoomFocus.ForeColor = [Drawing.Color]::White
$btnZoomFocus.FlatAppearance.BorderColor = [Drawing.Color]::FromArgb(96, 96, 96)
Set-RoundedCorners $btnZoomFocus 12
$btnZoomFocus.Enabled = $false   # Enabled when a Zoom meeting/participant is detected
$btnZoomFocus.Visible = [bool]$script:Cfg.Zoom.ShowFocusModeButton

# Hand Alert toggle button (next to Focus)
$btnHandAlert = New-Object System.Windows.Forms.Button
$btnHandAlert.Text = "✋"
$btnHandAlert.Size = Sz 60 35
$btnHandAlert.Font = New-Object System.Drawing.Font("Segoe UI Emoji", 20, [System.Drawing.FontStyle]::Regular)
$btnHandAlert.Location = Pt ($btnZoomFocus.Location.X + $btnZoomFocus.Width + 8) ($btnMusicToggle.Bottom + 10)
$btnHandAlert.UseVisualStyleBackColor = $false
$btnHandAlert.FlatStyle = 'Flat'
$btnHandAlert.FlatAppearance.BorderSize = 1
$btnHandAlert.BackColor = [Drawing.Color]::FromArgb(64, 64, 64)
$btnHandAlert.ForeColor = [Drawing.Color]::Yellow
$btnHandAlert.FlatAppearance.BorderColor = [Drawing.Color]::FromArgb(96, 96, 96)
Set-RoundedCorners $btnHandAlert 12
$btnHandAlert.Enabled = $true
$btnHandAlert.Add_Click({ Toggle-HandAlertOverlay })

# ---- Apply 3D gradient look to all main UI buttons ----
foreach ($b3d in @(
        $btnAuto, $script:chip, $btnObsConnect, $script:btnVCamStatus,
        $btnBlank, $btnCut, $btnCam, $btnMed,
        $btnMusicToggle,
        $btnZoomJoin, $btnZoomMuteAll, $btnZoomPolls, $btnZoomFocus, $btnHandAlert,
        $btnClock, $btnTheme,
        $script:btnAfToggle, $script:btnAfSetRoi, $script:btnAfSpeedDown, $script:btnAfSpeedUp
    )) {
    try { Apply-Btn3D $b3d } catch {}
}

# Focus Mode status label under the button
$lblZoomFocusStatus = New-Object System.Windows.Forms.Label
$lblZoomFocusStatus.AutoSize = $true
$lblZoomFocusStatus.Font = New-Object System.Drawing.Font("Segoe UI", 8, [System.Drawing.FontStyle]::Regular)
$lblZoomFocusStatus.Location = Pt ($btnZoomFocus.Location.X + 4) ($btnZoomFocus.Bottom + 4)
$lblZoomFocusStatus.ForeColor = [System.Drawing.Color]::LightGray

# Initialize Focus Mode visuals (Off) without calling helper (ensures load-order safety)
$lblZoomFocusStatus.Text = "Focus Mode Off"
$lblZoomFocusStatus.Visible = $false  # replaced by pill badge on Focus button
$btnZoomFocus.BackColor = [Drawing.Color]::FromArgb(128, 128, 128)
$btnZoomFocus.ForeColor = [Drawing.Color]::White
$btnMusicToggle.Add_Click({
        try {
            if (Music-IsPlaying) {
                $ms = [int]([math]::Max(200, $script:Music.FadeOutSeconds * 1000))
                Music-FadeOut -ms $ms -StopAfter $true
                Log "Background music: fading out..."
            }
            else {
                # --- meeting/confirm guard ---
                if (-not (Maybe-ConfirmMusicStart)) {
                    Log "Background music: start canceled."
                    return
                }
                # -----------------------------

                if (-not $script:Music.Folder -or -not (Test-Path $script:Music.Folder -PathType Container)) {
                    Log "Music: choose a valid folder in Settings."
                    [System.Windows.Forms.MessageBox]::Show($script:form, "Choose a valid music folder in Settings.", "Background Music") | Out-Null
                    return
                }
                
                # Only load folder if playlist doesn't exist or is empty
                try {
                    $needsLoad = (-not $script:Music.Playlist) -or ($script:Music.Playlist.count -eq 0)
                    if ($needsLoad) {
                        Log "Background music: Loading playlist from folder..."
                        Music-LoadFolder $script:Music.Folder
                    }
                }
                catch {
                    Log "Background music: Reloading playlist due to error: $_"
                    Music-LoadFolder $script:Music.Folder
                }
                
                Music-Start
                Log "Background music: playing."
            }

            Update-MusicButtonVisual
            Update-MusicToggleButton
        }
        catch {
            $errMsg = "$_"
            Log "Music toggle error: $errMsg"
            # Show a visible error so the user knows why music didn't start
            $hint = ''
            if ($errMsg -match 'codec|format|unsupported') {
                $hint = "`n`nThe audio file format may not be supported. Try MP3 or WAV files."
            }
            try {
                [System.Windows.Forms.MessageBox]::Show(
                    $script:form,
                    "Music error: $errMsg$hint",
                    'Background Music',
                    [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Warning
                ) | Out-Null
            }
            catch {}
        }
    })

# OBS Record button click handler
$btnOBSRecord.Add_Click({
        # Guard: require recording settings to be configured first
        if (-not $script:OBSRecording -and -not $script:Cfg.OBSControl.RecordingConfigured) {
            [System.Windows.Forms.MessageBox]::Show(
                $script:form,
                "Please configure OBS Recording Settings first!`n`nOpen Settings and click the (i) button in the OBS Control section for setup instructions.",
                "OBS Recording Setup Required",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            )
            return
        }
        try {
            if (-not $script:OBSRecording) {
                # Start recording
                $result = Invoke-ObsRequest 'StartRecord' @{}
                if ($result -ne $false) {
                    $script:OBSRecording = $true
                    $btnOBSRecord.BackColor = [Drawing.Color]::FromArgb(160, 30, 30)
                    $btnOBSRecord.FlatAppearance.BorderColor = [Drawing.Color]::FromArgb(220, 50, 50)
                    $btnOBSRecord.Invalidate()
                    Log "OBS: Recording started."
                }
                else {
                    Log "OBS: Failed to start recording. Is OBS connected?"
                }
            }
            else {
                # Confirm stop recording
                $ans = [System.Windows.Forms.MessageBox]::Show(
                    $script:form,
                    "Stop OBS recording and save the file?",
                    "Stop Recording",
                    [System.Windows.Forms.MessageBoxButtons]::YesNo,
                    [System.Windows.Forms.MessageBoxIcon]::Question
                )
                if ($ans -eq [System.Windows.Forms.DialogResult]::Yes) {
                    $result = Invoke-ObsRequest 'StopRecord' @{}
                    if ($result -ne $false) {
                        $script:OBSRecording = $false
                        $btnOBSRecord.BackColor = [Drawing.Color]::FromArgb(60, 60, 60)
                        $btnOBSRecord.FlatAppearance.BorderColor = [Drawing.Color]::FromArgb(110, 110, 110)
                        $btnOBSRecord.Invalidate()
                        Log "OBS: Recording stopped and saved."
                    }
                    else {
                        Log "OBS: Failed to stop recording."
                    }
                }
            }
        }
        catch {
            Log "OBS Record button error: $_"
        }
    })

# Zoom Join button click handler
$btnZoomJoin.Add_Click({
        try {
            # IMMEDIATE visual feedback - show processing state
            $originalColor = $btnZoomJoin.BackColor
            $btnZoomJoin.Text = "Joining..."
            $btnZoomJoin.BackColor = [System.Drawing.Color]::FromArgb(255, 165, 0) # Orange
            $btnZoomJoin.Enabled = $false
            $script:form.Refresh() # Force immediate UI update

            # Run join process in background to avoid UI freeze
            $script:joinTimerOriginalColor = $originalColor
            $script:joinTimer = New-Object System.Windows.Forms.Timer
            $script:joinTimer.Interval = 100 # Start almost immediately
            $script:joinTimer.Add_Tick({
                    try {
                        $script:joinTimer.Stop()
                        $script:joinTimer.Dispose()
                    
                        # Do the join work now (off the initial UI thread)
                        Start-ZoomJoinOrRefresh

                        # Auto start Polls after join (if enabled)
                        if ($script:Cfg.Zoom.AutoPollsAfterJoin) {
                            if ($script:_autoJoinPollsTimer -and -not $script:_autoJoinPollsTimer.IsDisposed) {
                                $script:_autoJoinPollsTimer.Stop()
                                $script:_autoJoinPollsTimer.Dispose()
                            }
                            $script:_autoJoinPollsAttempts = 0
                            $script:_autoJoinPollsTimer = New-Object System.Windows.Forms.Timer
                            $script:_autoJoinPollsTimer.Interval = 3500  # check every 3.5s
                            $script:_autoJoinPollsTimer.Add_Tick({
                                    try {
                                        $script:_autoJoinPollsAttempts++
                                        # Check if Zoom Meeting window is live
                                        $zoomMeeting = Get-Process 'Zoom' -ErrorAction SilentlyContinue |
                                        Where-Object { $_.MainWindowTitle -like '*Zoom Meeting*' } |
                                        Select-Object -First 1
                                        if ($zoomMeeting -or $script:_autoJoinPollsAttempts -ge 3) {
                                            $script:_autoJoinPollsTimer.Stop()
                                            if ($zoomMeeting) {
                                                Log "Auto Polls: Zoom meeting active after $($script:_autoJoinPollsAttempts * 3.5)s - launching polls"
                                                # Activate the Polls button; run open+launch entirely in background
                                                $script:_pollsActivated = $true
                                                if ($btnZoomPolls) { $btnZoomPolls.BackColor = [Drawing.Color]::FromArgb(120, 60, 180) }
                                                [void](Focus-ZoomWindow)
                                                Start-PollsRunspace -DelayMs 0
                                            }
                                            else {
                                                Log "Auto Polls: Zoom meeting not detected after ~10s - skipping"
                                            }
                                        }
                                    }
                                    catch {
                                        Log "Auto Polls timer error: $_"
                                        try { $script:_autoJoinPollsTimer.Stop() } catch {}
                                    }
                                })
                            $script:_autoJoinPollsTimer.Start()
                        }

                        # Show pulsing animation while waiting for status poll to confirm meeting state
                        if ($script:_joinAnimTimer -and -not $script:_joinAnimTimer.IsDisposed) {
                            $script:_joinAnimTimer.Stop(); $script:_joinAnimTimer.Dispose()
                        }
                        $script:_joinAnimFrame = 0
                        $script:_joinAnimTimer = New-Object System.Windows.Forms.Timer
                        $script:_joinAnimTimer.Interval = 600
                        $script:_joinAnimTimer.Add_Tick({
                                try {
                                    $f = @('Checking.  ', 'Checking.. ', 'Checking...')
                                    $btnZoomJoin.Text = $f[$script:_joinAnimFrame % 3]
                                    $script:_joinAnimFrame++
                                }
                                catch {}
                            })
                        $btnZoomJoin.Text = 'Checking.  '
                        $btnZoomJoin.BackColor = [System.Drawing.Color]::FromArgb(255, 140, 0)
                        $btnZoomJoin.Enabled = $true
                        $script:_joinAnimTimer.Start()
                        # Trigger immediate status check (no-op if scan already in flight — animation stops when it finishes)
                        try { Start-ZoomStatusRunspace } catch {}
                    }
                    catch {
                        Log "Zoom Join background error: $_"
                        # Restore button on error
                        $btnZoomJoin.Text = if ($script:ZoomInMeeting) { "In Meeting" } else { "Join Zoom" }
                        $btnZoomJoin.BackColor = if ($script:ZoomInMeeting) {
                            [System.Drawing.Color]::FromArgb(255, 165, 0)
                        }
                        else {
                            [System.Drawing.Color]::FromArgb(0, 120, 215)
                        }
                        $btnZoomJoin.Enabled = $true
                    }
                })
            $script:joinTimer.Start()
        }
        catch {
            Log "Zoom Join error: $_"
            # Ensure button is restored on any error
            if ($btnZoomJoin) {
                $btnZoomJoin.Enabled = $true
                $btnZoomJoin.Text = "Join Zoom"
            }
        }
    })

# Zoom Mute All button click handler
$btnZoomMuteAll.Add_Click({
        try {
            if (-not (Zoom-MuteAll)) {
                Log "Zoom Mute All: command did not complete successfully."
            }
        }
        catch {
            Log "Zoom Mute All button error: $_"
        }
    })

$btnZoomMic.Add_Click({
        try {
            Log "Toggling Zoom microphone..."
            $script:_lastManualToggleTime = Get-Date  # guard UIA poll from overwriting this click
            $sent = $false
            if (Focus-ZoomWindow) {
                Start-Sleep -Milliseconds 120
                [System.Windows.Forms.SendKeys]::SendWait("%a")  # Alt+A to toggle mute
                $sent = $true
            }
            if (-not $sent) {
                Log "Zoom microphone toggle failed: could not activate Zoom window."
                return
            }

            # Locally track mic state and update icon colour immediately
            $desiredMicOn = $true
            if ($script:ZoomMicStatus -eq $true) { $desiredMicOn = $false }
            $script:ZoomMicStatus = $desiredMicOn
            $status = @{ MicOn = $script:ZoomMicStatus; CameraOn = $script:ZoomCameraStatus; Found = $true }
            Update-ZoomStatusIcons $status
        }
        catch {
            Log "Zoom microphone toggle error: $_"
        }
    })

$btnZoomCamera.Add_Click({
        try {
            Log "Toggling Zoom camera..."
            $script:_lastManualToggleTime = Get-Date  # guard UIA poll from overwriting this click
            $sent = $false
            if (Focus-ZoomWindow) {
                Start-Sleep -Milliseconds 120
                [System.Windows.Forms.SendKeys]::SendWait("%v")  # Alt+V to toggle video
                $sent = $true
            }
            if (-not $sent) {
                Log "Zoom camera toggle failed: could not activate Zoom window."
                return
            }

            # Locally track camera state and update icon colour immediately
            $desiredCamOn = $true
            if ($script:ZoomCameraStatus -eq $true) { $desiredCamOn = $false }
            $script:ZoomCameraStatus = $desiredCamOn
            $status = @{ MicOn = $script:ZoomMicStatus; CameraOn = $script:ZoomCameraStatus; Found = $true }
            Update-ZoomStatusIcons $status
        }
        catch {
            Log "Zoom camera toggle error: $_"
        }
    })

$btnZoomPolls.Add_Click({
        # Guard: require Polls to be set up first
        if (-not $script:Cfg.Zoom.PollsConfigured) {
            [System.Windows.Forms.MessageBox]::Show(
                $script:form,
                "Please set up Attendance Poll first!`n`nOpen Settings, go to Zoom Settings and click the (i) button next to 'Polls Setup' for instructions.",
                "Polls Not Configured",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            ) | Out-Null
            return
        }
        try {
            Log "Zoom Polls button clicked - opening Polls/Quizzes panel..."
            $script:_pollsActivated = $true
            Start-PollsRunspace -DelayMs 0
        }
        catch {
            Log "Zoom Polls button error: $_"
        }
    })

$btnZoomFocus.Add_Click({
        try {
            Log "Zoom Focus Mode button clicked..."
            
            # Quick validation first (no heavy UI automation)
            $zoomProc = Get-Process "Zoom" -ErrorAction SilentlyContinue
            if (-not $zoomProc) {
                [System.Windows.Forms.MessageBox]::Show($script:form, "Zoom meeting not detected.", "Focus Mode") | Out-Null
                return
            }

            # IMMEDIATE visual feedback - show processing state
            $originalColor = $btnZoomFocus.BackColor
            if (-not $originalColor -or $originalColor -eq [System.Drawing.Color]::Empty) {
                $originalColor = [System.Drawing.Color]::FromArgb(80, 40, 120)
            }
            $script:focusTimerOriginalColor = $originalColor  # store in script scope for timer closure
            $btnZoomFocus.Text = "Working..."
            $btnZoomFocus.BackColor = [System.Drawing.Color]::FromArgb(255, 165, 0) # Orange
            $btnZoomFocus.Enabled = $false
            
            # Update status label immediately
            if ($lblZoomFocusStatus) {
                $lblZoomFocusStatus.Text = "Processing Focus Mode..."
                $lblZoomFocusStatus.ForeColor = [System.Drawing.Color]::FromArgb(255, 165, 0)
            }
            
            $script:form.Refresh() # Force immediate UI update

            # Run heavy automation in background using PowerShell Timer
            $script:focusTimer = New-Object System.Windows.Forms.Timer
            $script:focusTimer.Interval = 100 # Start almost immediately
            $script:focusTimer.Add_Tick({
                    try {
                        $script:focusTimer.Stop()
                        $script:focusTimer.Dispose()
                    
                        # Hand off to background runspace (avoids UI-thread freeze)
                        Start-FocusModeRunspace
                    }
                    catch {
                        Log "Focus Mode background error: $_"
                        # Restore button on error
                        $btnZoomFocus.Text = "Focus"
                        if ($script:focusTimerOriginalColor) { $btnZoomFocus.BackColor = $script:focusTimerOriginalColor }
                        $btnZoomFocus.Enabled = $true
                    }
                })
            $script:focusTimer.Start()
        }
        catch {
            Log "Zoom Focus Mode button error: $_"
            # Ensure button is restored on any error
            if ($btnZoomFocus) {
                $btnZoomFocus.Enabled = $true
                $btnZoomFocus.Text = "Focus"
            }
        }
    })

function Zoom-UnmuteIfMuted {
    # Only unmute if our local state says mic is currently muted (red)
    if ($script:ZoomMicStatus -ne $false) {
        Log "Zoom Unmute: Mic is not known as muted (state=$($script:ZoomMicStatus)); skipping auto-unmute."
        return $false
    }

    if (-not (Focus-ZoomWindow)) {
        Log "Zoom Unmute: could not activate Zoom window."
        return $false
    }

    try {
        [System.Windows.Forms.SendKeys]::SendWait('%a')  # Alt+A to toggle mute
        Log "Zoom Unmute: ALT+A sent to unmute mic."

        # Update local state and icons to show unmuted (green)
        $script:ZoomMicStatus = $true
        $script:_lastManualToggleTime = Get-Date  # block UIA poll from overwriting for 3s
        $status = @{ MicOn = $true; CameraOn = $script:ZoomCameraStatus; Found = $true }
        try { Update-ZoomStatusIcons $status } catch {}
        return $true
    }
    catch {
        Log "Zoom Unmute sendkeys error: $_"
        return $false
    }
}

function Show-BugReport {
    param([System.Windows.Forms.Form]$OwnerForm)

    $frm = New-Object System.Windows.Forms.Form
    $frm.Text = "Bug Report"
    $frm.Size = [System.Drawing.Size]::new(680, 520)
    $frm.MinimumSize = [System.Drawing.Size]::new(500, 420)
    $frm.StartPosition = 'CenterParent'
    $frm.FormBorderStyle = 'Sizable'
    $frm.MaximizeBox = $false

    $y = 12

    # --- Problem description ---
    $lbl1 = New-Object System.Windows.Forms.Label
    $lbl1.Text = "1.  Describe the problem or crash you encountered:"
    $lbl1.AutoSize = $true
    $lbl1.Location = [System.Drawing.Point]::new(12, $y)
    $frm.Controls.Add($lbl1)
    $y += 22

    $txtDesc = New-Object System.Windows.Forms.TextBox
    $txtDesc.Multiline = $true
    $txtDesc.ScrollBars = 'Vertical'
    $txtDesc.AcceptsReturn = $true
    $txtDesc.Font = New-Object System.Drawing.Font('Segoe UI', 10)
    $txtDesc.Size = [System.Drawing.Size]::new(644, 120)
    $txtDesc.Location = [System.Drawing.Point]::new(12, $y)
    $txtDesc.Anchor = 'Left, Right, Top'
    $frm.Controls.Add($txtDesc)
    $y += 130

    # --- Hardware info ---
    $lbl2 = New-Object System.Windows.Forms.Label
    $lbl2.Text = "2.  Describe your hardware setup (PC, mixer model, camera, network, etc.):"
    $lbl2.AutoSize = $true
    $lbl2.Location = [System.Drawing.Point]::new(12, $y)
    $frm.Controls.Add($lbl2)
    $y += 22

    $txtHW = New-Object System.Windows.Forms.TextBox
    $txtHW.Multiline = $true
    $txtHW.ScrollBars = 'Vertical'
    $txtHW.AcceptsReturn = $true
    $txtHW.Font = New-Object System.Drawing.Font('Segoe UI', 10)
    $txtHW.Size = [System.Drawing.Size]::new(644, 100)
    $txtHW.Location = [System.Drawing.Point]::new(12, $y)
    $txtHW.Anchor = 'Left, Right, Top'
    $frm.Controls.Add($txtHW)
    $y += 110

    # --- Bottom button panel ---
    $bp = New-Object System.Windows.Forms.Panel
    $bp.Dock = 'Bottom'
    $bp.Height = 46
    $frm.Controls.Add($bp)

    $lblNote = New-Object System.Windows.Forms.Label
    $lblNote.Text = "The report will be saved to your Desktop."
    $lblNote.AutoSize = $true
    $lblNote.ForeColor = [System.Drawing.Color]::DimGray
    $lblNote.Location = [System.Drawing.Point]::new(12, 14)
    $bp.Controls.Add($lblNote)

    $btnOK = New-Object System.Windows.Forms.Button
    $btnOK.Text = "Save Report"
    $btnOK.Size = [System.Drawing.Size]::new(120, 28)
    $btnOK.Location = [System.Drawing.Point]::new(430, 9)
    $btnOK.BackColor = [System.Drawing.Color]::FromArgb(180, 40, 40)
    $btnOK.ForeColor = [System.Drawing.Color]::White
    $btnOK.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $btnOK.FlatAppearance.BorderSize = 0
    $btnOK.Add_Click({
            if ([string]::IsNullOrWhiteSpace($txtDesc.Text)) {
                [System.Windows.Forms.MessageBox]::Show($frm, "Please describe the problem before saving.", "Missing Info", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::None) | Out-Null
                return
            }

            # Collect system info
            $osInfo = try { (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop | Select-Object -First 1).Caption } catch { "Unknown OS" }
            $psVer = $PSVersionTable.PSVersion.ToString()
            $appVer = try { [string]$script:APP_VERSION } catch { "N/A" }
            $stamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            $logSnap = try { ($script:LogBuffer | Select-Object -Last 300) -join "`r`n" } catch { "(no log available)" }

            $report = @"
JWL+OBS ASSISTANT — BUG REPORT
================================
Date/Time : $stamp
App Version: $appVer
OS         : $osInfo
PowerShell : $psVer

--- PROBLEM DESCRIPTION ---
$($txtDesc.Text.Trim())

--- HARDWARE SETUP ---
$($txtHW.Text.Trim())

--- APPLICATION LOG (last 300 lines) ---
$logSnap
"@

            $desktop = [System.Environment]::GetFolderPath('Desktop')
            $fileName = "JWL-OBS-BugReport_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"
            $filePath = Join-Path $desktop $fileName

            try {
                [System.IO.File]::WriteAllText($filePath, $report, [System.Text.Encoding]::UTF8)
            }
            catch {
                [System.Windows.Forms.MessageBox]::Show($frm, "Could not save report file:`n$_", "Save Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::None) | Out-Null
                return
            }

            $instrMsg = @"
Your bug report has been saved to your Desktop:

  $fileName

Please send it by email to:

  mvpapen@gmail.com

Steps:
  1. Open your email client.
  2. Create a new email to  mvpapen@gmail.com
  3. Attach the file from your Desktop.
  4. Optionally add a short subject line, e.g. 'JWL+OBS Bug Report'.
  5. Send!

Thank you for helping improve the app.
"@
            [System.Windows.Forms.MessageBox]::Show($frm, $instrMsg, "Report Saved", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::None) | Out-Null
            $frm.Close()
        })
    $bp.Controls.Add($btnOK)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = "Cancel"
    $btnCancel.Size = [System.Drawing.Size]::new(90, 28)
    $btnCancel.Location = [System.Drawing.Point]::new(562, 9)
    $btnCancel.Add_Click({ $frm.Close() })
    $frm.CancelButton = $btnCancel
    $bp.Controls.Add($btnCancel)

    $frm.Show($OwnerForm)
    while ($frm.Visible) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 30
    }
    $frm.Dispose()
}

function Show-InfoPopup {
    param([string]$Title, [string]$Key, [string]$DefaultText)

    $popup = New-Object System.Windows.Forms.Form
    $popup.Text = $Title
    $popup.Size = [System.Drawing.Size]::new(650, 720)
    $popup.StartPosition = 'CenterParent'
    $popup.MinimumSize = [System.Drawing.Size]::new(500, 400)
    $popup.MinimizeBox = $false
    $popup.MaximizeBox = $true
    $popup.FormBorderStyle = 'Sizable'

    $btnPanel = New-Object System.Windows.Forms.Panel
    $btnPanel.Dock = 'Bottom'
    $btnPanel.Height = 40
    $popup.Controls.Add($btnPanel)

    $tb = New-Object System.Windows.Forms.TextBox
    $tb.Multiline = $true
    $tb.ScrollBars = 'Vertical'
    $tb.ReadOnly = $true
    $tb.Font = New-Object System.Drawing.Font('Segoe UI', 10)
    $tb.Text = $DefaultText
    $tb.Dock = 'Fill'
    $tb.BackColor = [System.Drawing.Color]::White
    $tb.BorderStyle = [System.Windows.Forms.BorderStyle]::None
    $popup.Controls.Add($tb)

    $btnClose = New-Object System.Windows.Forms.Button
    $btnClose.Text = 'Close'
    $btnClose.Size = [System.Drawing.Size]::new(100, 28)
    $btnClose.Location = [System.Drawing.Point]::new(270, 6)
    $btnClose.Add_Click({ $popup.Close() })
    $popup.AcceptButton = $btnClose
    $popup.CancelButton = $btnClose
    $btnPanel.Controls.Add($btnClose)

    # Use Show() instead of ShowDialog() to avoid deadlocking inside the modal settings dialog
    $popup.Show()
    while ($popup.Visible) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 30
    }
    $popup.Dispose()
}

function Show-ZoomAutoToggleWarning {
    param([switch]$Silent)  # When $Silent, fix state quietly without showing a dialog
    try {
        # Guard FIRST — set before any early returns so re-entrancy is impossible
        if ($script:_zoomWarningShownThisToggle) { return }
        $script:_zoomWarningShownThisToggle = $true

        # Only act if we have a Zoom participant and know current mic/camera state
        if (-not $script:ZoomParticipantFound) { return }

        $micOff = ($script:ZoomMicStatus -eq $false)
        $camOff = ($script:ZoomCameraStatus -eq $false)

        if (-not ($micOff -or $camOff)) { return }

        if ($Silent) {
            # Auto-start path: fix state silently, no dialog blocking the countdown
            Log "Auto Toggle: Zoom mic muted=$micOff, camera off=$camOff — correcting silently"
            if ($micOff) {
                try {
                    [void](Zoom-UnmuteIfMuted)
                    $script:ZoomMicStatus = $true
                    $status = @{ MicOn = $true; CameraOn = $script:ZoomCameraStatus; Found = $true }
                    try { Update-ZoomStatusIcons $status } catch {}
                }
                catch {}
            }
            if ($camOff) {
                try {
                    if (Zoom-CameraOn) {
                        $script:ZoomCameraStatus = $true
                        $status = @{ MicOn = $script:ZoomMicStatus; CameraOn = $true; Found = $true }
                        try { Update-ZoomStatusIcons $status } catch {}
                    }
                }
                catch {}
            }
            return
        }

        $msg = "Check Zoom Mic and Zoom Camera!`r`n`r`n" +
        "Zoom Mic is currently " + ($(if ($micOff) { 'MUTED' } else { 'ON' })) +
        " and Zoom Camera is " + ($(if ($camOff) { 'OFF' } else { 'ON' })) + ".`r`n`r`n" +
        "Auto mode will still run. Do you want to unmute mic and turn camera on now?`r`n`r`n" +
        "Yes = Unmute/turn camera on now`r`n" +
        "No  = Keep current Zoom state (for pre-meeting checks)."

        $res = [System.Windows.Forms.MessageBox]::Show(
            $script:form,
            $msg,
            "Zoom Auto Toggle",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )

        if ($res -eq [System.Windows.Forms.DialogResult]::Yes) {
            if ($micOff) {
                try {
                    [void](Zoom-UnmuteIfMuted)
                    $script:ZoomMicStatus = $true
                    $status = @{ MicOn = $true; CameraOn = $script:ZoomCameraStatus; Found = $true }
                    try { Update-ZoomStatusIcons $status } catch {}
                }
                catch {}
            }
            if ($camOff) {
                try {
                    if (Zoom-CameraOn) {
                        $script:ZoomCameraStatus = $true
                        $status = @{ MicOn = $script:ZoomMicStatus; CameraOn = $true; Found = $true }
                        try { Update-ZoomStatusIcons $status } catch {}
                    }
                }
                catch {}
            }
        }
    }
    catch {
        Log "Zoom Auto Toggle warning error: $_"
    }
}

# Parse entries like: "Thu 19:00", "Sun 10:00", case-insensitive, optional seconds "19:00:00"
function Get-WeeklyMeetingStartTimes {
    $out = @()
    foreach ($line in @($script:Cfg.Meeting.Lines)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        # Expected: Ddd HH:mm[:ss]
        if ($line -match '^(Mon|Tue|Wed|Thu|Fri|Sat|Sun)\s+(\d{1,2}:\d{2}(:\d{2})?)$') {
            $dow = $matches[1]
            $tod = $matches[2]
            # Compute next occurrence this week (today or future), in local time
            $now = Get-Date
            # Map Ddd -> 0..6
            $map = @{Sun = 0; Mon = 1; Tue = 2; Wed = 3; Thu = 4; Fri = 5; Sat = 6 }
            $target = $map[$dow]
            $delta = ($target - [int]$now.DayOfWeek + 7) % 7
            $date = $now.Date.AddDays($delta)
            $ts = [TimeSpan]::Parse($tod)
            $start = $date + $ts
            # If it's today but time already passed, bump 7 days
            if ($delta -eq 0 -and $start -lt $now) { $start = $start.AddDays(7) }
            $out += $start
        }
    }
    # Return sorted upcoming starts (this week/next)
    $out | Sort-Object
}

# Compute the next meeting window and update $lblNext
function Update-NextMeetingLabelAndWindow {
    try {
        $starts = Get-WeeklyMeetingStartTimes
        if (-not $starts -or $starts.Count -eq 0) {
            $lblNext.Text = "Next: —"
            return $null
        }
        # Next start is the soonest in the future
        $nextStart = $starts | Select-Object -First 1
        $lblNext.Text = "Next: " + $nextStart.ToString("ddd HH:mm:ss")

        $leadMin = [int]$script:Cfg.Meeting.GuardLeadMinutes
        $durMin = [int]$script:Cfg.Meeting.GuardMinutes
        if ($leadMin -lt 0) { $leadMin = 0 }
        if ($durMin -le 0) { $durMin = 95 }

        $guardStart = $nextStart.AddMinutes(-$leadMin)
        $guardEnd = $nextStart.AddMinutes($durMin)

        return [pscustomobject]@{
            Start = $guardStart
            End   = $guardEnd
        }
    }
    catch {
        return $null
    }
}

# Start the guard if we're within a computed window; otherwise stop it.
function Check-And-ApplyAutoMeetingGuard {
    try {
        if (-not $script:Cfg.Meeting.AutoGuard) { return }

        $win = Update-NextMeetingLabelAndWindow
        if (-not $win) { Stop-MeetingGuard; return }

        $now = Get-Date
        if ($now -ge $win.Start -and $now -lt $win.End) {
            # Inside window → guard until End
            $script:MeetingGuardUntil = $win.End
            try { $meetingTickTimer.Start() } catch {}
            # If music is playing, fade/stop it now
            try {
                if (Music-IsPlaying) {
                    $ms = [int]([math]::Max(200, $script:Music.FadeOutSeconds * 1000))
                    Music-FadeOut -ms $ms -StopAfter $true
                    Log "Background music auto-stopped for Meeting Mode."
                }
            }
            catch {}
        }
        else {
            # Outside window → no guard
            Stop-MeetingGuard
        }
    }
    catch {}
}

# Run auto-guard check every 30s (plus once at startup)
$autoGuardTimer = New-Object System.Windows.Forms.Timer
$autoGuardTimer.Interval = 30000
$autoGuardTimer.Add_Tick({ 
        if ($script:ShuttingDown) { return }
        try { Check-And-ApplyAutoMeetingGuard } catch {}
    })
$autoGuardTimer.Start()
Check-And-ApplyAutoMeetingGuard

$script:form.Controls.Add($btnMusicToggle)
$script:form.Controls.Add($btnOBSRecord)

# JWL Monitor control button — GDI+ color TV icon + JWL label
$btnJwlMonitor = New-Object System.Windows.Forms.Button
$script:btnJwlMonitor = $btnJwlMonitor   # expose to script scope for Update-JwlMonitorButton
$btnJwlMonitor.Name = 'btnJwlMonitor'
$btnJwlMonitor.Text = ''          # everything drawn in Paint handler
$btnJwlMonitor.Size = Sz 80 35
$btnJwlMonitor.Location = Pt ($btnOBSRecord.Right + 8) ($btnOBSRecord.Top)
$btnJwlMonitor.FlatStyle = 'Flat'
$btnJwlMonitor.UseVisualStyleBackColor = $false
$btnJwlMonitor.BackColor = [Drawing.Color]::FromArgb(60, 60, 60)
$btnJwlMonitor.FlatAppearance.BorderSize = 1
$btnJwlMonitor.FlatAppearance.BorderColor = [Drawing.Color]::FromArgb(110, 110, 110)
$btnJwlMonitor.ForeColor = [Drawing.Color]::White
Set-RoundedCorners $btnJwlMonitor 12
$script:_tvMonitorImage = New-TvMonitorBitmap
$btnJwlMonitor.Add_Paint({
        param($s, $pe)
        $g = $pe.Graphics
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $r = $s.ClientRectangle
        $img = $script:_tvMonitorImage
        $lbl = 'JWL'
        $lblFont = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
        $lblBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)
        $lblSz = $g.MeasureString($lbl, $lblFont)
        $imgW = if ($img) { $img.Width }  else { 0 }
        $imgH = if ($img) { $img.Height } else { 0 }
        $startX = 4
        $imgY = [int](($r.Height - $imgH) / 2.0)
        $lblY = [int](($r.Height - $lblSz.Height) / 2.0)
        if ($img) { $g.DrawImage($img, $startX, $imgY, $imgW, $imgH) }
        $g.DrawString($lbl, $lblFont, $lblBrush, [float]($startX + $imgW + 4), [float]$lblY)
        $lblFont.Dispose(); $lblBrush.Dispose()
        # Option C: amber '!' badge in top-right corner when OCR config is broken
        if ($script:_ocrBroken -eq $true) {
            $bFont = New-Object System.Drawing.Font('Segoe UI', 8, [System.Drawing.FontStyle]::Bold)
            $bBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 185, 0))
            $g.DrawString('!', $bFont, $bBrush, [float]($r.Width - 11), [float]1)
            $bFont.Dispose(); $bBrush.Dispose()
        }
    })

# Single-click context menu: reminder + Toggle + Turn ON / Turn OFF / Re-Sync Display
$cmsJwl = New-Object System.Windows.Forms.ContextMenuStrip
$cmsJwl.BackColor = [Drawing.Color]::FromArgb(40, 40, 40)
$cmsJwl.ForeColor = [Drawing.Color]::White
$cmsJwl.RenderMode = [System.Windows.Forms.ToolStripRenderMode]::System

$miJwlOff = New-Object System.Windows.Forms.ToolStripMenuItem("Turn OFF")
$miJwlOff.ForeColor = [Drawing.Color]::FromArgb(230, 100, 100)
$miJwlOff.Add_Click({
        # Same proven formula as Re-Sync (PS-Phase): direct $tp.Toggle(), close settings unconditionally at end
        try {
            $el = Get-JwlSecondDisplayToggle
            if ($el) {
                try {
                    $tp = $el.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)
                    if ($tp.Current.ToggleState -ne [System.Windows.Automation.ToggleState]::Off) {
                        $tp.Toggle()
                        Start-Sleep -Milliseconds 300
                        $script:jwlOutOn = $false
                        $script:_lastHit = $false
                        Log "[JWL] Second display turned OFF."
                    }
                    else { Log "[JWL] Already OFF." }
                }
                catch { Log "[JWL] Turn OFF toggle error: $_" }
            }
            else { Log "[JWL] Turn OFF: Toggle element not found." }
        }
        catch { Log "[JWL] Turn OFF error: $_" }
        finally { Close-JwlSettingsIfWeOpened; Update-JwlMonitorButton }
    })

$cmsJwl.Items.Add($miJwlOff) | Out-Null
$cmsJwl.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

$miJwlResync = New-Object System.Windows.Forms.ToolStripMenuItem("Re-Sync Display (OFF→ON)")
$miJwlResync.Add_Click({
        try {
            Log "[JWL] Re-syncing second display..."
            PS-PhaseOff | Out-Null
            PS-PhaseOn
            $script:jwlOutOn = $true
            $script:_lastHit = $true
            Update-JwlMonitorButton
            Log "[JWL] Re-sync done."
        }
        catch { Log "[JWL] Re-sync error: $_" }
    })
$cmsJwl.Items.Add($miJwlResync) | Out-Null

$cmsJwl.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

$miJwlCheckStatus = New-Object System.Windows.Forms.ToolStripMenuItem("Check Status (OCR)")
$miJwlCheckStatus.ForeColor = [Drawing.Color]::FromArgb(160, 200, 255)
$miJwlCheckStatus.Add_Click({
        try {
            $bmp = Grab-ROI
            if (-not $bmp) {
                Log "[JWL] Check Status: ROI not set."
                [System.Windows.Forms.MessageBox]::Show($script:form, "ROI is not set. Please configure it in Settings.", "JWL Check Status", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
                return
            }
            try {
                $processed = Preprocess-Binary $bmp
                $txt = OCR-Text $processed
                $processed.Dispose()
            }
            catch { $txt = OCR-Text $bmp }
            finally { $bmp.Dispose() }
            $kw = [string]$script:Cfg.Keyword
            $hit = ($txt -and -not [string]::IsNullOrWhiteSpace($kw) -and $txt.ToLower().Contains($kw.ToLower()))
            $script:jwlOutOn = [bool]$hit
            $script:_lastHit = $hit   # always sync so _jwlOcrTimer doesn't revert on next tick
            $script:_lastOcrText = $txt
            Set-OcrHealth $true
            Update-JwlOcrTooltip
            Update-JwlMonitorButton
            $stateStr = if ($hit) { "ON (keyword found)" } else { "OFF (keyword not found)" }
            $txtPreview = if ($txt) { $txt.Substring(0, [math]::Min(120, $txt.Length)) } else { "(empty)" }
            Log "[JWL] Manual Check Status: $stateStr | keyword='$kw' | OCR='$txtPreview'"
        }
        catch { Log "[JWL] Check Status error: $_" }
    })
$cmsJwl.Items.Add($miJwlCheckStatus) | Out-Null

# Open menu on single left-click (no right-click needed)
$btnJwlMonitor.Add_Click({
        # Refresh detection each click
        Test-JwlMediaFix | Out-Null
        if ($script:JwlMediaFixActive) {
            # JWL fix active: show status info + OCR status (still useful even when fix is running)
            $cmsBlocked = New-Object System.Windows.Forms.ContextMenuStrip
            $cmsBlocked.BackColor = [Drawing.Color]::FromArgb(40, 40, 40)
            $cmsBlocked.ForeColor = [Drawing.Color]::White
            $cmsBlocked.RenderMode = [System.Windows.Forms.ToolStripRenderMode]::System
            # JWL fix status header
            $miInfo = New-Object System.Windows.Forms.ToolStripMenuItem("🛡  JWL Media Fix is active — display controls disabled")
            $miInfo.ForeColor = [Drawing.Color]::FromArgb(255, 200, 50)
            $miInfo.Enabled = $false
            $cmsBlocked.Items.Add($miInfo) | Out-Null
            # OCR status line — always readable regardless of fix mode
            $ocrTxt = $script:_lastOcrText
            $kw = [string]$script:Cfg.Keyword
            $ocrLine = if ($null -eq $ocrTxt) { 'OCR: not yet run' }
            elseif ($ocrTxt -eq '') { 'OCR: (empty — ROI may be wrong or display off)' }
            else { 'OCR: "' + $ocrTxt.Substring(0, [math]::Min(60, $ocrTxt.Length)) + '"' }
            $kwLine = if ($kw) { "Keyword: `"$kw`"" } else { 'Keyword: (not set)' }
            $cmsBlocked.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null
            $miOcr = New-Object System.Windows.Forms.ToolStripMenuItem($ocrLine)
            $miOcr.ForeColor = [Drawing.Color]::FromArgb(160, 220, 160)
            $miOcr.Enabled = $false
            $cmsBlocked.Items.Add($miOcr) | Out-Null
            $miKw = New-Object System.Windows.Forms.ToolStripMenuItem($kwLine)
            $miKw.ForeColor = [Drawing.Color]::FromArgb(160, 200, 255)
            $miKw.Enabled = $false
            $cmsBlocked.Items.Add($miKw) | Out-Null
            # Check Status still works even with JWL fix active
            $cmsBlocked.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null
            $miCheckOcr = New-Object System.Windows.Forms.ToolStripMenuItem("Check Status (OCR)")
            $miCheckOcr.ForeColor = [Drawing.Color]::FromArgb(160, 200, 255)
            $miCheckOcr.Add_Click({
                    try {
                        $bmp = Grab-ROI
                        if (-not $bmp) {
                            [System.Windows.Forms.MessageBox]::Show($script:form, "ROI is not set. Please configure it in Settings.", "JWL Check Status", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
                            return
                        }
                        try { $processed = Preprocess-Binary $bmp; $txt = OCR-Text $processed; $processed.Dispose() }
                        catch { $txt = OCR-Text $bmp }
                        finally { $bmp.Dispose() }
                        $kw2 = [string]$script:Cfg.Keyword
                        $hit = ($txt -and -not [string]::IsNullOrWhiteSpace($kw2) -and $txt.ToLower().Contains($kw2.ToLower()))
                        $script:_lastOcrText = $txt
                        $script:jwlOutOn = [bool]$hit
                        $script:_lastHit = $hit
                        Set-OcrHealth $true
                        Update-JwlOcrTooltip
                        Update-JwlMonitorButton
                        $stateStr = if ($hit) { 'keyword FOUND' } else { 'keyword NOT found' }
                        $txtPreview = if ($txt) { $txt.Substring(0, [math]::Min(120, $txt.Length)) } else { '(empty)' }
                        $msgBody = "OCR result: $stateStr`n`nOCR text:`n" + '"' + $txtPreview + '"' + "`n`nKeyword: " + '"' + $kw2 + '"'
                        [System.Windows.Forms.MessageBox]::Show($script:form,
                            $msgBody,
                            'JWL Check Status', [System.Windows.Forms.MessageBoxButtons]::OK,
                            [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
                        Log "[JWL] Fix-mode Check Status: $stateStr | keyword='$kw2' | OCR='$txtPreview'"
                    }
                    catch { Log "[JWL] Fix-mode Check Status error: $_" }
                })
            $cmsBlocked.Items.Add($miCheckOcr) | Out-Null
            $cmsBlocked.Show($btnJwlMonitor, 0, $btnJwlMonitor.Height)
            return
        }
        $cmsJwl.Show($btnJwlMonitor, 0, $btnJwlMonitor.Height)
    })
$script:form.Controls.Add($btnJwlMonitor)

# ToolTip used by Set-OcrHealth (Option D alert)
$script:_ocrAlertTip = New-Object System.Windows.Forms.ToolTip
$script:_ocrAlertTip.IsBalloon = $true
$script:_ocrAlertTip.ToolTipIcon = [System.Windows.Forms.ToolTipIcon]::Warning
$script:_ocrAlertTip.AutoPopDelay = 7000
$script:_ocrAlertTip.InitialDelay = 0

# ── Toggle Zoom button (between JWL button and Polls label) ───────────────────
$script:btnZoomToggle = New-Object System.Windows.Forms.Button
$script:btnZoomToggle.Name = 'btnZoomToggle'
$script:btnZoomToggle.Text = ''
$script:btnZoomToggle.Size = Sz 70 35
$script:btnZoomToggle.Location = Pt ($btnJwlMonitor.Right + 6) ($btnJwlMonitor.Top)
$script:btnZoomToggle.FlatStyle = 'Flat'
$script:btnZoomToggle.UseVisualStyleBackColor = $false
$script:btnZoomToggle.BackColor = [Drawing.Color]::FromArgb(30, 100, 30)
$script:btnZoomToggle.FlatAppearance.BorderSize = 1
$script:btnZoomToggle.FlatAppearance.BorderColor = [Drawing.Color]::FromArgb(60, 160, 60)
$script:btnZoomToggle.ForeColor = [Drawing.Color]::White
Set-RoundedCorners $script:btnZoomToggle 10

# Paint double-arrow icon + small text
$script:btnZoomToggle.Add_Paint({
        param($s, $e)
        $g = $e.Graphics
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $r = $s.ClientRectangle
        # Arrow color depends on projected state
        $arrowClr = if ($script:PS_projected) {
            [Drawing.Color]::FromArgb(255, 140, 60)
        }
        else {
            [Drawing.Color]::FromArgb(80, 220, 80)
        }
        $pen = New-Object System.Drawing.Pen($arrowClr, 2.5)
        $brush = New-Object System.Drawing.SolidBrush($arrowClr)
        $cx = $r.Width / 2
        $cy = $r.Height / 2 - 4
        # Left arrow  ←
        $pts1 = [System.Drawing.PointF[]]@(
            [System.Drawing.PointF]::new($cx - 2, $cy - 5),
            [System.Drawing.PointF]::new($cx - 9, $cy),
            [System.Drawing.PointF]::new($cx - 2, $cy + 5)
        )
        $g.DrawLines($pen, $pts1)
        $g.DrawLine($pen, [System.Drawing.PointF]::new($cx - 9, $cy), [System.Drawing.PointF]::new($cx + 4, $cy))
        # Right arrow →
        $pts2 = [System.Drawing.PointF[]]@(
            [System.Drawing.PointF]::new($cx + 2, $cy - 5),
            [System.Drawing.PointF]::new($cx + 9, $cy),
            [System.Drawing.PointF]::new($cx + 2, $cy + 5)
        )
        $g.DrawLines($pen, $pts2)
        $g.DrawLine($pen, [System.Drawing.PointF]::new($cx + 9, $cy), [System.Drawing.PointF]::new($cx - 4, $cy))
        $pen.Dispose(); $brush.Dispose()
        # Label below arrows
        $lbl = if ($script:PS_projected) { 'Restore' } else { 'Toggle Zoom' }
        $font = New-Object System.Drawing.Font('Segoe UI', 6.5, [System.Drawing.FontStyle]::Regular)
        $fmt = New-Object System.Drawing.StringFormat
        $fmt.Alignment = [System.Drawing.StringAlignment]::Center
        $lblRect = [System.Drawing.RectangleF]::new(0, $r.Height - 16, $r.Width, 14)
        $g.DrawString($lbl, $font, [System.Drawing.Brushes]::White, $lblRect, $fmt)
        $font.Dispose(); $fmt.Dispose()
    })

# ── Single-click: open menu (reminder + toggle + monitor selection) ───────────
$script:btnZoomToggle.Add_Click({
        # Block when Auto Toggle is running — ask to stop first
        if ($script:running) {
            $dlg = New-Object System.Windows.Forms.Form
            $dlg.Text = 'Toggle Zoom'
            $dlg.Size = [System.Drawing.Size]::new(360, 155)
            $dlg.StartPosition = 'Manual'
            $dlg.Location = [System.Drawing.Point]::new(
                $script:form.Left + [int](($script:form.Width - 360) / 2),
                $script:form.Bottom + 5)
            $dlg.FormBorderStyle = 'FixedDialog'
            $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false
            $dlg.TopMost = $true
            $dlg.BackColor = [Drawing.Color]::FromArgb(45, 45, 45)
            $dlg.ForeColor = [Drawing.Color]::White

            $lblWarn = New-Object System.Windows.Forms.Label
            $lblWarn.Text = '⚠  First Stop Auto Toggle!'
            $lblWarn.ForeColor = [Drawing.Color]::FromArgb(255, 80, 80)
            $lblWarn.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
            $lblWarn.AutoSize = $false
            $lblWarn.Size = [System.Drawing.Size]::new(336, 26)
            $lblWarn.Location = [System.Drawing.Point]::new(10, 10)
            $lblWarn.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter

            $lblQ = New-Object System.Windows.Forms.Label
            $lblQ.Text = 'Do you want to stop Auto Toggle now?'
            $lblQ.ForeColor = [Drawing.Color]::FromArgb(220, 220, 220)
            $lblQ.Font = New-Object System.Drawing.Font('Segoe UI', 9)
            $lblQ.AutoSize = $false
            $lblQ.Size = [System.Drawing.Size]::new(336, 22)
            $lblQ.Location = [System.Drawing.Point]::new(10, 42)
            $lblQ.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter

            $btnOK = New-Object System.Windows.Forms.Button
            $btnOK.Text = 'OK'
            $btnOK.Size = [System.Drawing.Size]::new(90, 28)
            $btnOK.Location = [System.Drawing.Point]::new(80, 78)
            $btnOK.FlatStyle = 'Flat'
            $btnOK.BackColor = [Drawing.Color]::FromArgb(0, 130, 0)
            $btnOK.ForeColor = [Drawing.Color]::White
            $btnOK.Add_Click({ $dlg.Tag = 'OK'; $dlg.Close() })

            $btnCancel = New-Object System.Windows.Forms.Button
            $btnCancel.Text = 'Cancel'
            $btnCancel.Size = [System.Drawing.Size]::new(90, 28)
            $btnCancel.Location = [System.Drawing.Point]::new(190, 78)
            $btnCancel.FlatStyle = 'Flat'
            $btnCancel.BackColor = [Drawing.Color]::FromArgb(100, 30, 30)
            $btnCancel.ForeColor = [Drawing.Color]::White
            $btnCancel.Add_Click({ $dlg.Close() })

            $dlg.Controls.AddRange(@($lblWarn, $lblQ, $btnOK, $btnCancel))
            $dlg.AcceptButton = $btnOK
            $dlg.CancelButton = $btnCancel
            $dlg.ShowDialog() | Out-Null
            $stopped = ($dlg.Tag -eq 'OK')
            $dlg.Dispose()

            if ($stopped) { Stop-AutoToggle }
            else { return }
        }
        $cms = New-Object System.Windows.Forms.ContextMenuStrip
        $cms.BackColor = [Drawing.Color]::FromArgb(45, 45, 45)
        $cms.ForeColor = [Drawing.Color]::White
        $cms.RenderMode = [System.Windows.Forms.ToolStripRenderMode]::System

        # JWL Media Fix status line
        Test-JwlMediaFix | Out-Null
        $jwlMfText = if ($script:JwlMediaFixActive) { "🛡  JWL Media Fix: ACTIVE (managing 2nd display)" } else { "○  JWL Media Fix: not detected" }
        $miJwlMfStatus = New-Object System.Windows.Forms.ToolStripMenuItem($jwlMfText)
        $miJwlMfStatus.ForeColor = if ($script:JwlMediaFixActive) { [Drawing.Color]::FromArgb(255, 200, 50) } else { [Drawing.Color]::FromArgb(130, 130, 130) }
        $miJwlMfStatus.Enabled = $false
        $cms.Items.Add($miJwlMfStatus) | Out-Null
        $cms.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

        # Reminders (enabled so ForeColor is visible, click closes menu)
        $miReminder1 = New-Object System.Windows.Forms.ToolStripMenuItem("⚠  You need to Spotlight one or more Attendees!")
        $miReminder1.ForeColor = [Drawing.Color]::FromArgb(255, 40, 40)
        $miReminder1.Add_Click({ $cms.Close() })
        $cms.Items.Add($miReminder1) | Out-Null
        $miReminder2 = New-Object System.Windows.Forms.ToolStripMenuItem("⚠  Stop AutoToggle first!")
        $miReminder2.ForeColor = [Drawing.Color]::FromArgb(255, 40, 40)
        $miReminder2.Add_Click({ $cms.Close() })
        $cms.Items.Add($miReminder2) | Out-Null
        $cms.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

        # Toggle action
        $toggleLabel = if ($script:PS_projected) { "▶  Restore Zoom (un-project)" } else { "▶  Toggle Zoom to Monitor" }
        $miToggle = New-Object System.Windows.Forms.ToolStripMenuItem($toggleLabel)
        $miToggle.ForeColor = [Drawing.Color]::FromArgb(100, 200, 255)
        $miToggle.Add_Click({
                if (-not $script:PSw34Loaded) {
                    [System.Windows.Forms.MessageBox]::Show('PSw34 helper failed to load at startup. Check the log for Add-Type errors.', 'Toggle Zoom', 'OK', 'Warning') | Out-Null
                    return
                }
                $script:btnZoomToggle.Enabled = $false
                $script:form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
                try {
                    if ($script:PS_projected) {
                        $script:btnZoomToggle.BackColor = [Drawing.Color]::FromArgb(30, 100, 30)
                        $script:btnZoomToggle.FlatAppearance.BorderColor = [Drawing.Color]::FromArgb(60, 160, 60)
                        $script:btnZoomToggle.Invalidate()
                        if (-not $script:JwlMediaFixActive) {
                            # Normal path: Re-Sync JWL display (PhaseOff → wait → PhaseOn)
                            PS-PhaseOff | Out-Null
                            # Wait 1900ms for JWL to process the display-off, but pump the message queue
                            # so timers and repaints can still fire during the wait (avoids hourglass freeze).
                            # Flash the button orange so the user sees something is happening.
                            $script:_psWaitSw = [System.Diagnostics.Stopwatch]::StartNew()
                            $script:_psFlashState = $false
                            $script:_psLastFlash = -400  # force immediate first flash
                            while ($script:_psWaitSw.ElapsedMilliseconds -lt 1900) {
                                if (($script:_psWaitSw.ElapsedMilliseconds - $script:_psLastFlash) -ge 300) {
                                    $script:_psFlashState = -not $script:_psFlashState
                                    $script:_psLastFlash = $script:_psWaitSw.ElapsedMilliseconds
                                    $script:btnZoomToggle.BackColor = if ($script:_psFlashState) {
                                        [Drawing.Color]::FromArgb(200, 100, 0)   # orange ON
                                    }
                                    else {
                                        [Drawing.Color]::FromArgb(60, 60, 60)    # dim OFF
                                    }
                                    $script:btnZoomToggle.Refresh()
                                }
                                [System.Windows.Forms.Application]::DoEvents()
                                Start-Sleep -Milliseconds 30
                            }
                            # Restore button to green (un-projected) before finishing
                            $script:btnZoomToggle.BackColor = [Drawing.Color]::FromArgb(30, 100, 30)
                            $script:btnZoomToggle.FlatAppearance.BorderColor = [Drawing.Color]::FromArgb(60, 160, 60)
                        }
                        # Always move the Zoom window back regardless of JWL Media Fix state
                        $zoomHw = [PSw34]::FindZoomMediaWindow()
                        if ($zoomHw -ne [IntPtr]::Zero) { PS-HideZoomFromMonitor $zoomHw }
                        if (-not $script:JwlMediaFixActive) {
                            # JWL Media Fix is not active — re-sync JWL display back ON
                            PS-PhaseOn
                        }
                        $mainHw = [PSw34]::FindZoomMainWindow()
                        if ($mainHw -ne [IntPtr]::Zero) { [PSw34]::ForceSetForeground($mainHw) }
                        $script:PS_projected = $false
                    }
                    else {
                        $scr = PS-GetScreen
                        $hw = [PSw34]::FindZoomMediaWindow()
                        if ($hw -eq [IntPtr]::Zero) {
                            [System.Windows.Forms.MessageBox]::Show(
                                "Zoom meeting window not found.`nJoin a Zoom meeting first.",
                                'Toggle Zoom', 'OK', 'Warning') | Out-Null
                            return
                        }
                        $tr = PS-GetTargetRect $hw $scr
                        $cr = New-Object PSw34+RECT
                        [PSw34]::GetWindowRect($hw, [ref]$cr) | Out-Null
                        if ([PSw34]::EqualRect($tr, $cr)) {
                            PS-HideZoomFromMonitor $hw
                            $script:PS_projected = $false
                        }
                        else {
                            $script:PS_wasMin = [PSw34]::IsIconic($hw)
                            $script:PS_origRect = $cr
                            PS-ShowZoomOnMonitor $hw $tr
                            $script:PS_projected = $true
                            $script:btnZoomToggle.BackColor = [Drawing.Color]::FromArgb(140, 60, 10)
                            $script:btnZoomToggle.FlatAppearance.BorderColor = [Drawing.Color]::FromArgb(220, 100, 40)
                        }
                    }
                    $script:btnZoomToggle.Invalidate()
                }
                catch {
                    [System.Windows.Forms.MessageBox]::Show("Toggle Zoom error:`n$_", 'Toggle Zoom', 'OK', 'Error') | Out-Null
                }
                finally {
                    $script:btnZoomToggle.Enabled = $true
                    $script:form.Cursor = [System.Windows.Forms.Cursors]::Default
                }
            })
        $cms.Items.Add($miToggle) | Out-Null
        $cms.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

        # Monitor selection
        $screens = [System.Windows.Forms.Screen]::AllScreens | Sort-Object { if ($_.Primary) { 1 } else { 0 } }
        $savedIdx = 0
        if ($script:Cfg.Zoom.Contains('ZoomProjectorMonitor')) { $savedIdx = [int]$script:Cfg.Zoom.ZoomProjectorMonitor }
        # Capture for GetNewClosure() — $script: scope is not accessible inside closures (resolves to dynamic module scope)
        $captCfg = $script:Cfg
        $captSaveFn = ${function:Save-Settings}
        for ($i = 0; $i -lt $screens.Count; $i++) {
            $sc = $screens[$i]
            $tag = if ($sc.Primary) { ' [Primary]' } else { '' }
            $baseLabel = "Monitor $($i+1)$tag  $($sc.Bounds.Width)×$($sc.Bounds.Height)  @ ($($sc.Bounds.Left),$($sc.Bounds.Top))"
            $isSelected = ($i -eq $savedIdx)
            $mi = New-Object System.Windows.Forms.ToolStripMenuItem($(if ($isSelected) { "✓  $baseLabel" } else { "    $baseLabel" }))
            # No native checkmark — we use the ✓ prefix so it honours ForeColor
            $mi.CheckOnClick = $false
            $mi.ForeColor = if ($isSelected) { [Drawing.Color]::FromArgb(80, 220, 80) } else { [Drawing.Color]::White }
            $mi.Tag = $baseLabel
            $captIdx = $i
            $mi.Add_Click({
                    $captCfg.Zoom['ZoomProjectorMonitor'] = $captIdx
                    & $captSaveFn | Out-Null
                    foreach ($item in $cms.Items) {
                        if ($item -is [System.Windows.Forms.ToolStripMenuItem] -and $item.Tag) {
                            $item.Text = "    $($item.Tag)"
                            $item.ForeColor = [Drawing.Color]::White
                        }
                    }
                    $this.Text = "✓  $($this.Tag)"
                    $this.ForeColor = [Drawing.Color]::FromArgb(80, 220, 80)
                }.GetNewClosure())
            $cms.Items.Add($mi) | Out-Null
        }

        $cms.Show($script:btnZoomToggle, 0, $script:btnZoomToggle.Height)
    })

$script:form.Controls.Add($script:btnZoomToggle)

$script:form.Controls.Add($btnZoomJoin)
$script:form.Controls.Add($script:lblUpdateStatus)
$script:form.Controls.Add($btnZoomMuteAll)
$script:form.Controls.Add($btnZoomMic)
$script:form.Controls.Add($btnZoomCamera)

# Small countdown labels below Mute All, mic, camera and Focus buttons
$script:lblZoomMuteBadge = New-Object System.Windows.Forms.Label
$script:lblZoomMuteBadge.AutoSize = $false
$script:lblZoomMuteBadge.Size = [System.Drawing.Size]::new($btnZoomMuteAll.Width, 14)
$script:lblZoomMuteBadge.Location = [System.Drawing.Point]::new($btnZoomMuteAll.Left, $btnZoomMuteAll.Bottom + 2)
$script:lblZoomMuteBadge.Font = New-Object System.Drawing.Font("Segoe UI", 7, [System.Drawing.FontStyle]::Bold)
$script:lblZoomMuteBadge.ForeColor = [System.Drawing.Color]::Green
$script:lblZoomMuteBadge.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
$script:lblZoomMuteBadge.BackColor = [System.Drawing.Color]::Transparent
$script:lblZoomMuteBadge.Visible = $false
$script:form.Controls.Add($script:lblZoomMuteBadge)
$script:lblZoomMicBadge = New-Object System.Windows.Forms.Label
$script:lblZoomMicBadge.AutoSize = $false
$script:lblZoomMicBadge.Size = [System.Drawing.Size]::new($btnZoomMic.Width, 14)
$script:lblZoomMicBadge.Location = [System.Drawing.Point]::new($btnZoomMic.Left, $btnZoomMic.Bottom + 2)
$script:lblZoomMicBadge.Font = New-Object System.Drawing.Font("Segoe UI", 7, [System.Drawing.FontStyle]::Bold)
$script:lblZoomMicBadge.ForeColor = [System.Drawing.Color]::Green
$script:lblZoomMicBadge.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
$script:lblZoomMicBadge.BackColor = [System.Drawing.Color]::Transparent
$script:lblZoomMicBadge.Visible = $false
$script:form.Controls.Add($script:lblZoomMicBadge)

$script:lblZoomCamBadge = New-Object System.Windows.Forms.Label
$script:lblZoomCamBadge.AutoSize = $false
$script:lblZoomCamBadge.Size = [System.Drawing.Size]::new($btnZoomCamera.Width, 14)
$script:lblZoomCamBadge.Location = [System.Drawing.Point]::new($btnZoomCamera.Left, $btnZoomCamera.Bottom + 2)
$script:lblZoomCamBadge.Font = New-Object System.Drawing.Font("Segoe UI", 7, [System.Drawing.FontStyle]::Bold)
$script:lblZoomCamBadge.ForeColor = [System.Drawing.Color]::Green
$script:lblZoomCamBadge.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
$script:lblZoomCamBadge.BackColor = [System.Drawing.Color]::Transparent
$script:lblZoomCamBadge.Visible = $false
$script:form.Controls.Add($script:lblZoomCamBadge)

# Countdown label below Focus button (disabled buttons don't fire Paint events)
$script:lblZoomFocusBadge = New-Object System.Windows.Forms.Label
$script:lblZoomFocusBadge.AutoSize = $false
$script:lblZoomFocusBadge.Size = [System.Drawing.Size]::new($btnZoomFocus.Width, 14)
$script:lblZoomFocusBadge.Location = [System.Drawing.Point]::new($btnZoomFocus.Left, $btnZoomFocus.Bottom + 2)
$script:lblZoomFocusBadge.Font = New-Object System.Drawing.Font("Segoe UI", 7, [System.Drawing.FontStyle]::Bold)
$script:lblZoomFocusBadge.ForeColor = [System.Drawing.Color]::Green
$script:lblZoomFocusBadge.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
$script:lblZoomFocusBadge.BackColor = [System.Drawing.Color]::Transparent
$script:lblZoomFocusBadge.Visible = $false
$script:form.Controls.Add($script:lblZoomFocusBadge)

# Attendance status panel — placed to the right of the music button, same row
$script:lblAttendance = New-Object System.Windows.Forms.Label
$script:lblAttendance.AutoSize = $false
$script:lblAttendance.Size = [System.Drawing.Size]::new(130, $btnMusicToggle.Height)
$script:lblAttendance.Location = [System.Drawing.Point]::new(
    $btnMed.Right - 130,
    $btnMusicToggle.Top)
$script:lblAttendance.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$script:lblAttendance.ForeColor = [System.Drawing.Color]::FromArgb(0, 230, 110)
$script:lblAttendance.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
$script:lblAttendance.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$script:lblAttendance.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
$script:lblAttendance.Cursor = [System.Windows.Forms.Cursors]::Hand
$script:lblAttendance.Text = "Polls: --"
$script:lblAttendance.Visible = $true
$script:lblAttendance.Add_Click({
        Invoke-ZoomAttendanceReadDelayed -DelayMs 500
    })
$script:form.Controls.Add($script:lblAttendance)

$script:form.Controls.Add($btnZoomPolls)
$script:form.Controls.Add($btnZoomFocus)
$script:form.Controls.Add($btnHandAlert)
$script:form.Controls.Add($lblZoomFocusStatus)

# Make the bottom-row buttons stick to the bottom-left on resize
Set-Anchor $btnAuto        'Bottom, Left'
Set-Anchor $btnMusicToggle 'Bottom, Left'
Set-Anchor $btnZoomJoin    'Bottom, Left'
Set-Anchor $script:lblUpdateStatus 'Bottom, Left'
Set-Anchor $btnZoomMuteAll 'Bottom, Left'
Set-Anchor $btnZoomMic     'Bottom, Left'
Set-Anchor $btnZoomCamera  'Bottom, Left'
Set-Anchor $btnZoomPolls   'Bottom, Left'
Set-Anchor $btnZoomFocus   'Bottom, Left'
Set-Anchor $btnHandAlert   'Bottom, Left'
Set-Anchor $lblZoomFocusStatus 'Bottom, Left'
Set-Anchor $script:btnZoomToggle  'Bottom, Left'
Set-Anchor $btnOBSRecord   'Bottom, Left'
Set-Anchor $btnJwlMonitor  'Bottom, Left'
Set-Anchor $script:lblAttendance  'Bottom, Right'
function Update-MusicButtonVisual {
    try {
        if (Music-IsPlaying) {
            # Playing: green pill, black text
            $btnMusicToggle.BackColor = [System.Drawing.Color]::FromArgb(0, 192, 0)
            $btnMusicToggle.ForeColor = [System.Drawing.Color]::Black
            $btnMusicToggle.UseVisualStyleBackColor = $false
        }
        else {
            # Not playing: revert to neutral background per theme + readable text
            $dark = ([string]$script:Cfg.UI.Theme -eq 'Dark')
            if ($dark) {
                # match your dark Control color
                $btnMusicToggle.BackColor = [System.Drawing.Color]::FromArgb(0x20, 0x20, 0x20)
                $btnMusicToggle.ForeColor = [System.Drawing.Color]::White
            }
            else {
                # default system button color
                $btnMusicToggle.BackColor = [System.Drawing.SystemColors]::Control
                $btnMusicToggle.ForeColor = [System.Drawing.Color]::Black
            }
            $btnMusicToggle.UseVisualStyleBackColor = $false   # keep our explicit BackColor
        }
    }
    catch {}
}

#---- Part 2/2 for pasting and editing

# ---------- Gear Settings button (bottom-right, sticky) ----------
# Pre-compile Add-Type helpers at script load time so Show-SettingsDialog opens without delay.
# PanelWheelRouter — routes WM_MOUSEWHEEL to the scrollable settings panel
if (-not ([System.Management.Automation.PSTypeName]'PanelWheelRouter').Type) {
    $__wfAssemblies = @('System.Windows.Forms', 'System.Drawing')
    foreach ($__asm in @('System.Windows.Forms.Primitives', 'System.Drawing.Primitives', 'System.ComponentModel.Primitives')) {
        try { [void][System.Reflection.Assembly]::Load($__asm); $__wfAssemblies += $__asm } catch {}
    }
    Add-Type -ReferencedAssemblies $__wfAssemblies -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;
using System.Drawing;
public class PanelWheelRouter : IMessageFilter {
    private Panel _panel;
    private const int WM_MOUSEWHEEL = 0x020A;
    [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr h, int msg, IntPtr w, IntPtr l);
    public PanelWheelRouter(Panel p) { _panel = p; }
    public bool PreFilterMessage(ref Message m) {
        if (m.Msg != WM_MOUSEWHEEL) return false;
        Point cur = Control.MousePosition;
        Point panelScreen = _panel.PointToScreen(Point.Empty);
        Rectangle r = new Rectangle(panelScreen, _panel.ClientSize);
        if (!r.Contains(cur)) return false;
        SendMessage(_panel.Handle, WM_MOUSEWHEEL, m.WParam, m.LParam);
        return true;
    }
}
"@
}
# DpiHelper — optional helper for thread DPI context switches
if (-not ([System.Management.Automation.PSTypeName]'DpiHelper').Type) {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class DpiHelper {
    [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr ctx);
}
"@
}
$script:_settingsDialogBusy = $false   # Guard: prevents opening multiple settings dialogs

function Show-SettingsDialog {
    # Helper: Disable mouse wheel on NumericUpDown controls
    function Disable-NumericMouseWheel($control) {
        $control.Add_MouseWheel({ param($s, $e); $e.Handled = $true })
    }

    # Keep settings dialog in the same DPI context as the main UI.
    # Forcing DPI-unaware here can cause a visible size jump after opening.
    $script:_prevDpiCtx = [IntPtr]::Zero

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "Settings"; $dlg.StartPosition = "CenterParent"; $dlg.FormBorderStyle = "Sizable"
    $dlg.MaximizeBox = $true; $dlg.MinimizeBox = $false; $dlg.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $dlg.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
    $dlg.SizeGripStyle = 'Show'
    $dlg.ClientSize = Sz 840 860; $dlg.TopMost = $true

    # Bottom button panel — docked first so WinForms reserves that space
    $btnPanel = New-Object System.Windows.Forms.Panel
    $btnPanel.Dock = 'Bottom'
    $btnPanel.Height = 50
    $dlg.Controls.Add($btnPanel)

    # Scrollable content panel — fills everything above the button strip
    $panel = New-Object System.Windows.Forms.Panel
    $panel.Dock = 'Fill'
    $panel.AutoScroll = $true
    $dlg.Controls.Add($panel)

    # Mouse-enter focus: when mouse enters the panel area, give it focus
    # so keyboard PgUp/PgDn/arrows also scroll
    $panel.Add_MouseEnter({ $panel.Focus() })

    # Attach message filter — routes wheel events to the panel handle
    $script:_wheelRouter = New-Object PanelWheelRouter($panel)
    [System.Windows.Forms.Application]::AddMessageFilter($script:_wheelRouter)
    $dlg.Add_FormClosed({ [System.Windows.Forms.Application]::RemoveMessageFilter($script:_wheelRouter) })

    # Block wheel only on value-changing controls (NumericUpDown, ComboBox, TrackBar)
    function Disable-AllMouseWheels($parent) {
        foreach ($ctrl in $parent.Controls) {
            try {
                if ($ctrl -is [System.Windows.Forms.NumericUpDown] -or
                    $ctrl -is [System.Windows.Forms.ComboBox] -or
                    $ctrl -is [System.Windows.Forms.TrackBar]) {
                    $ctrl.Add_MouseWheel({ param($s, $e); $e.Handled = $true })
                }
                if ($ctrl.Controls.Count -gt 0) { Disable-AllMouseWheels $ctrl }
            }
            catch {}
        }
    }
    # Force Settings dialog to always use Light theme
    try {
        Apply-ThemeRecursive $dlg $LightTheme $false
        Set-DarkTitleBar $dlg $false
    }
    catch {}

    $y = 14

    # ── XR Mixer master-enable checkbox (TOP) ────────────────────────────────
    $chkXREnabled = New-Object System.Windows.Forms.CheckBox
    $chkXREnabled.Text = "Enable XR Family Mixer (uncheck if no mixer is connected)"
    $chkXREnabled.AutoSize = $true
    $chkXREnabled.Location = Pt 14 $y
    $chkXREnabled.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $chkXREnabled.Checked = [bool]$script:Cfg.XR.XRMixerEnabled
    $panel.Controls.Add($chkXREnabled)
    $y += 34
    # ─────────────────────────────────────────────────────────────────────────

    $lblKey = New-Object System.Windows.Forms.Label; $lblKey.Text = "Keyword:"; $lblKey.AutoSize = $true; $lblKey.Location = Pt 14 $y; $panel.Controls.Add($lblKey)
    $tbKey = New-Object System.Windows.Forms.TextBox; $tbKey.Text = $script:Cfg.Keyword; $tbKey.Location = Pt 110 ($y - 3); $tbKey.Size = Sz 74 24; $panel.Controls.Add($tbKey)
    $tbKey.HideSelection = $true
    $tbKey.Add_Enter({ try { $this.SelectionStart = $this.TextLength; $this.SelectionLength = 0 }catch {} })
    
    # Add instruction text in green cursive
    $lblKeyInstruction = New-Object System.Windows.Forms.Label
    $lblKeyInstruction.Text = "Best to use numbers only if more than 1 Yeartext Language !"
    $lblKeyInstruction.Location = Pt 190 $y
    $lblKeyInstruction.MaximumSize = [System.Drawing.Size]::new(480, 0)
    $lblKeyInstruction.AutoSize = $true
    $lblKeyInstruction.ForeColor = [System.Drawing.Color]::Green
    $lblKeyInstruction.Font = New-Object System.Drawing.Font("Microsoft Sans Serif", 8.25, [System.Drawing.FontStyle]::Italic)
    $panel.Controls.Add($lblKeyInstruction)
    
    # Add second instruction line in green cursive
    $lblKeyInstruction2 = New-Object System.Windows.Forms.Label
    $lblKeyInstruction2.Text = "If foreign text is preferred, than you need to download corresponding Tesserac language package per User Login!"
    $lblKeyInstruction2.Location = Pt 190 ($y + 32)
    $lblKeyInstruction2.MaximumSize = [System.Drawing.Size]::new(480, 0)
    $lblKeyInstruction2.AutoSize = $true
    $lblKeyInstruction2.ForeColor = [System.Drawing.Color]::Green
    $lblKeyInstruction2.Font = New-Object System.Drawing.Font("Microsoft Sans Serif", 8.25, [System.Drawing.FontStyle]::Italic)
    $panel.Controls.Add($lblKeyInstruction2)
    
    $y += 80

    $lblT = New-Object System.Windows.Forms.Label; $lblT.Text = "Tesseract:"; $lblT.AutoSize = $true; $lblT.Location = Pt 14 $y; $panel.Controls.Add($lblT)
    $tbT = New-Object System.Windows.Forms.TextBox; $tbT.Text = $script:Cfg.Tesseract; $tbT.Location = Pt 110 ($y - 3); $tbT.Size = Sz 470 24; $panel.Controls.Add($tbT)
    $btnBT = New-Object System.Windows.Forms.Button; $btnBT.Text = "Browse…"; $btnBT.Size = Sz 74 24; $btnBT.Location = Pt 590 ($y - 4); $panel.Controls.Add($btnBT)
    $ofdT = New-Object System.Windows.Forms.OpenFileDialog; $ofdT.Filter = "Executables|*.exe|All Files|*.*"; $ofdT.FileName = "tesseract.exe"
    $btnBT.Add_Click({ if ($ofdT.ShowDialog() -eq 'OK') { $tbT.Text = $ofdT.FileName } })
    $y += 38
    [System.Windows.Forms.Application]::DoEvents()  # keep preview alive during dialog build

    $grpROI = New-Object System.Windows.Forms.GroupBox; $grpROI.Text = "OCR Region of Interest (screen coords)"; $grpROI.Location = Pt 14 $y; $grpROI.Size = Sz 792 146; $panel.Controls.Add($grpROI)
    $lblROIHint = New-Object System.Windows.Forms.Label; $lblROIHint.Text = "1) Click 'Set Top-Left', move mouse to keyword area on any monitor, press SPACE.  2) Click 'Set Bottom-Right', move mouse, press SPACE.  NOTE: Re-set ROI if you change Display Scale."; $lblROIHint.AutoSize = $false; $lblROIHint.Size = Sz 700 40; $lblROIHint.Anchor = 'Left, Right'; $lblROIHint.Location = Pt 10 20; $grpROI.Controls.Add($lblROIHint)
    $btnROIInfo = New-Object System.Windows.Forms.Button
    $btnROIInfo.Text = "i"
    $btnROIInfo.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $btnROIInfo.Size = Sz 26 22
    $btnROIInfo.Location = Pt 716 20
    $btnROIInfo.Anchor = 'Right'
    $btnROIInfo.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $btnROIInfo.FlatAppearance.BorderSize = 0
    $btnROIInfo.BackColor = [System.Drawing.Color]::FromArgb(70, 130, 220)
    $btnROIInfo.ForeColor = [System.Drawing.Color]::White
    $btnROIInfo.Add_Click({
            $infoMsg = @"
HOW TESSERACT OCR WORKS
═══════════════════════════════════════════
Tesseract is a free, open-source OCR (Optical Character Recognition) engine.
This assistant uses it to read text directly from your screen — specifically from
the Region of Interest (ROI) you define — to detect the current song/keyword
and switch OBS scenes automatically.

HOW TO INSTALL TESSERACT
═══════════════════════════════════════════
1. Download the Windows installer from the official GitHub release:
   https://github.com/UB-Mannheim/tesseract/wiki

2. Run the installer (tesseract-ocr-w64-setup-*.exe for 64-bit).

3. During install, note the path (default: C:\Program Files\Tesseract-OCR\tesseract.exe).

4. In the Settings dialog, paste that path into the "Tesseract:" field,
   or use the Browse button to locate tesseract.exe.

5. (Optional) To support non-English text (e.g. Spanish, French),
   install the extra language packs during setup or download .traineddata
   files from: https://github.com/tesseract-ocr/tessdata

HOW TO SET THE ROI
═══════════════════════════════════════════
1. Open JWL (JW Library) and navigate to the screen showing the song/keyword.
2. Click "Set Top-Left" — the button turns orange and waits.
3. Move your mouse to the TOP-LEFT corner of the keyword area on the media monitor
   (any monitor — your mouse does NOT need to stay on this dialog).
   TIP: If you choose a region that contains only numeric characters — such as
   a scripture number — you can avoid installing non-English language packs entirely.
4. Press SPACE to capture the position. The button returns to normal.
5. Click "Set Bottom-Right" — move mouse to the BOTTOM-RIGHT of the keyword area.
6. Press SPACE again to capture.
7. Click "Preview ROI" to verify the captured region looks correct.

Press ESCAPE at any time to cancel a pending capture.
NOTE: Re-set ROI if you change your Display Scale.
"@
            Show-InfoPopup -Title "Tesseract OCR Info" -Key "TesseractOCR" -DefaultText $infoMsg
            # Also offer to open the download page in browser (no icon = no sound)
            $openLink = [System.Windows.Forms.MessageBox]::Show($dlg, "Open the Tesseract download page in your browser?", "Open Download Link", [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::None)
            if ($openLink -eq [System.Windows.Forms.DialogResult]::Yes) {
                Start-Process "https://github.com/UB-Mannheim/tesseract/wiki"
            }
        })
    $grpROI.Controls.Add($btnROIInfo)
    $btnTL = New-Object System.Windows.Forms.Button; $btnTL.Text = "Set Top-Left"; $btnTL.Size = Sz 110 26; $btnTL.Location = Pt 10 66; $grpROI.Controls.Add($btnTL)
    $btnBR = New-Object System.Windows.Forms.Button; $btnBR.Text = "Set Bottom-Right"; $btnBR.Size = Sz 140 26; $btnBR.Location = Pt 128 66; $grpROI.Controls.Add($btnBR)
    $btnPrev = New-Object System.Windows.Forms.Button; $btnPrev.Text = "Preview ROI"; $btnPrev.Size = Sz 110 26; $btnPrev.Location = Pt 10 98; $grpROI.Controls.Add($btnPrev)
    $btnPrev.Add_Click({
            $bmp = $null; try {
                $bmp = Grab-ROI
                if ($null -eq $bmp) { [System.Windows.Forms.MessageBox]::Show($dlg, "ROI not set or invalid.", "ROI Preview", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null; return }
                $pv = New-Object System.Windows.Forms.Form; $pv.Text = "ROI Preview"; $pv.StartPosition = "CenterParent"; $pv.TopMost = $dlg.TopMost; $pv.Size = Sz ([math]::Min($bmp.Width + 28, 900)) ([math]::Min($bmp.Height + 70, 700))
                $panelPv = New-Object System.Windows.Forms.Panel; $panelPv.Dock = 'Fill'; $panelPv.AutoScroll = $true; $pv.Controls.Add($panelPv)
                $pic = New-Object System.Windows.Forms.PictureBox; $pic.SizeMode = 'AutoSize'; $pic.Image = $bmp; $panelPv.Controls.Add($pic)
                $btnClose = New-Object System.Windows.Forms.Button; $btnClose.Text = "Close"; $btnClose.Dock = 'Bottom'; $btnClose.Height = 32; $btnClose.Add_Click({ $pv.Close() }); $pv.Controls.Add($btnClose)
                [void]$pv.ShowDialog($dlg)
            }
            finally { try { if ($bmp) { $bmp.Dispose() } }catch {} }
        })
    $lblROI = New-Object System.Windows.Forms.Label; $lblROI.AutoSize = $true; $lblROI.Location = Pt 290 100; $lblROI.Text = (Get-ROIText); $grpROI.Controls.Add($lblROI)
    # ROI capture: click button → enter waiting mode → move mouse to target on any monitor → press SPACE
    $script:_roiWaiting = $null
    $dlg.KeyPreview = $true

    $btnTL.Add_Click({
            $script:_roiWaiting = 'TL'
            $btnTL.Text = '→ Press SPACE'
            $btnTL.BackColor = [System.Drawing.Color]::OrangeRed
            $btnTL.ForeColor = [System.Drawing.Color]::White
            $btnBR.Enabled = $false
            Log 'ROI: Move mouse to Top-Left of keyword area on any monitor, then press SPACE'
        })
    $btnBR.Add_Click({
            $script:_roiWaiting = 'BR'
            $btnBR.Text = '→ Press SPACE'
            $btnBR.BackColor = [System.Drawing.Color]::OrangeRed
            $btnBR.ForeColor = [System.Drawing.Color]::White
            $btnTL.Enabled = $false
            Log 'ROI: Move mouse to Bottom-Right of keyword area on any monitor, then press SPACE'
        })
    $dlg.Add_KeyDown({
            param($s, $e)
            if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Space -and $null -ne $script:_roiWaiting) {
                $e.Handled = $true; $e.SuppressKeyPress = $true
                $p = [System.Windows.Forms.Cursor]::Position
                if ($script:_roiWaiting -eq 'TL') {
                    $script:Cfg.ROI.TL = [System.Drawing.Point]::new($p.X, $p.Y)
                    $btnTL.Text = 'Set Top-Left'
                    $btnTL.BackColor = [System.Drawing.Color]::Empty
                    $btnTL.ForeColor = [System.Drawing.Color]::Empty
                    $btnBR.Enabled = $true
                    Log "ROI TL captured: ($($p.X),$($p.Y))"
                }
                else {
                    $script:Cfg.ROI.BR = [System.Drawing.Point]::new($p.X, $p.Y)
                    $btnBR.Text = 'Set Bottom-Right'
                    $btnBR.BackColor = [System.Drawing.Color]::Empty
                    $btnBR.ForeColor = [System.Drawing.Color]::Empty
                    $btnTL.Enabled = $true
                    Log "ROI BR captured: ($($p.X),$($p.Y))"
                }
                $script:_roiWaiting = $null
                $lblROI.Text = (Get-ROIText)
            }
            elseif ($e.KeyCode -eq [System.Windows.Forms.Keys]::Escape -and $null -ne $script:_roiWaiting) {
                $e.Handled = $true
                if ($script:_roiWaiting -eq 'TL') {
                    $btnTL.Text = 'Set Top-Left'; $btnTL.BackColor = [System.Drawing.Color]::Empty
                    $btnTL.ForeColor = [System.Drawing.Color]::Empty; $btnBR.Enabled = $true
                }
                else {
                    $btnBR.Text = 'Set Bottom-Right'; $btnBR.BackColor = [System.Drawing.Color]::Empty
                    $btnBR.ForeColor = [System.Drawing.Color]::Empty; $btnTL.Enabled = $true
                }
                $script:_roiWaiting = $null
                Log 'ROI capture cancelled (Escape)'
            }
        })
    $y += ($grpROI.Height + 10)

    # Meeting Times
    [System.Windows.Forms.Application]::DoEvents()  # spinner tick
    $grpMeet = New-Object System.Windows.Forms.GroupBox
    $grpMeet.Text = "Meeting Times"; $grpMeet.Location = Pt 14 $y; $grpMeet.Size = Sz 792 260; $panel.Controls.Add($grpMeet)
    $lblTimes = New-Object System.Windows.Forms.Label; $lblTimes.Text = "Meeting start times (1 per line) - Add Meeting start time for CO visit!"; $lblTimes.AutoSize = $true; $lblTimes.Location = Pt 14 26; $grpMeet.Controls.Add($lblTimes)
    $txtMeeting = New-Object System.Windows.Forms.TextBox
    $txtMeeting.Location = Pt 14 46; $txtMeeting.Size = Sz 762 150; $txtMeeting.Anchor = 'Left, Right'
    $txtMeeting.Multiline = $true; $txtMeeting.ScrollBars = 'Vertical'; $txtMeeting.AcceptsReturn = $true
    if ($script:Cfg.Meeting.Lines -and $script:Cfg.Meeting.Lines.Count -gt 0) { $txtMeeting.Lines = $script:Cfg.Meeting.Lines } else { $txtMeeting.Lines = @('Thu 7:00 pm', 'Sun 11:00 am') }
    $grpMeet.Controls.Add($txtMeeting)
    $chkFlashClock = New-Object System.Windows.Forms.CheckBox
    $chkFlashClock.Text = "Flash clock red for last 15 seconds before meeting start"
    $chkFlashClock.AutoSize = $true; $chkFlashClock.Location = Pt 14 ($txtMeeting.Bottom + 10)
    $chkFlashClock.Checked = [bool]$script:Cfg.Meeting.FlashClockRedLast15
    $grpMeet.Controls.Add($chkFlashClock)
    $y += 260 + 10

    # Background Music
    [System.Windows.Forms.Application]::DoEvents()  # spinner tick
    $grpMusic = New-Object System.Windows.Forms.GroupBox
    $grpMusic.Text = "Background Music"; $grpMusic.Location = Pt 14 $y; $grpMusic.Size = Sz 792 186; $panel.Controls.Add($grpMusic)

    $lblFolder = New-Object System.Windows.Forms.Label; $lblFolder.Text = "Folder:"; $lblFolder.AutoSize = $true; $lblFolder.Location = Pt 10 26; $grpMusic.Controls.Add($lblFolder)
    $tbFolder = New-Object System.Windows.Forms.TextBox; $tbFolder.Text = $script:Cfg.Music.Folder; $tbFolder.Location = Pt 68 22; $tbFolder.Size = Sz 640 24; $tbFolder.Anchor = 'Left, Right'; $grpMusic.Controls.Add($tbFolder)
    $btnBrowse = New-Object System.Windows.Forms.Button; $btnBrowse.Text = "Browse…"; $btnBrowse.Size = Sz 74 24; $btnBrowse.Location = Pt 716 21; $btnBrowse.Anchor = 'Right'; $grpMusic.Controls.Add($btnBrowse)
    $fbd = New-Object System.Windows.Forms.FolderBrowserDialog
    $btnBrowse.Add_Click({ if ($fbd.ShowDialog() -eq 'OK') { $tbFolder.Text = $fbd.SelectedPath } })
    # --- Shuffle / Volume row with inline 0 .. [Trackbar] .. 100 ---

    # --- Shuffle / Volume row with inline 0 .. [Trackbar] .. 100 (shorter fader, extra spacing) ---

    # Shuffle
    $chkShuffle = New-Object System.Windows.Forms.CheckBox
    $chkShuffle.Text = "Shuffle"
    $chkShuffle.AutoSize = $true
    $chkShuffle.Location = Pt 10 66
    $chkShuffle.Checked = [bool]$script:Cfg.Music.Shuffle
    $grpMusic.Controls.Add($chkShuffle)

    # "Volume:" label
    $lblVol = New-Object System.Windows.Forms.Label
    $lblVol.Text = "Volume:"
    $lblVol.AutoSize = $true
    $lblVol.Location = Pt 86 68
    $grpMusic.Controls.Add($lblVol)

    # Inline "0" label (left of fader)
    $lblVol0 = New-Object System.Windows.Forms.Label
    $lblVol0.Text = "0"
    $lblVol0.AutoSize = $true
    $grpMusic.Controls.Add($lblVol0)

    # Inline "100" label (right of fader)
    $lblVol100 = New-Object System.Windows.Forms.Label
    $lblVol100.Text = "100"
    $lblVol100.AutoSize = $true
    $grpMusic.Controls.Add($lblVol100)

    # Trackbar
    $trkVol = New-Object System.Windows.Forms.TrackBar
    $trkVol.Minimum = 0
    $trkVol.Maximum = 100
    $trkVol.TickFrequency = 10
    $trkVol.AutoSize = $false
    $trkVol.Height = 26
    $trkVol.Value = [int]$script:Cfg.Music.Volume

    # ---- Layout (single line) ----
    $rowY = 64
    $gapSmall = 8                       # gaps between items
    $rightPad = 12

    # Place "0" with extra spacing after "Volume:"
    $leftMargin = $lblVol.Left + $lblVol.PreferredSize.Width + 24
    $lblVol0.Location = Pt $leftMargin 68

    # Trackbar left & width
    $trkLeft = $lblVol0.Left + $lblVol0.PreferredSize.Width + $gapSmall

    # Available width before "100"
    $grpW = [int]$grpMusic.ClientSize.Width
    $reserve = $gapSmall + $lblVol100.PreferredSize.Width + $rightPad
    $availW = [math]::Max(120, $grpW - $trkLeft - $reserve)

    # Make the fader shorter (cap to 260px)
    $trkW = [math]::Min(260, $availW)

    $trkVol.Size = Sz $trkW 26
    $trkVol.Location = Pt $trkLeft $rowY
    $grpMusic.Controls.Add($trkVol)

    # Place "100" after the fader
    $lblVol100.Location = Pt ($trkVol.Left + $trkVol.Width + $gapSmall) 68


    $chkAutoStart = New-Object System.Windows.Forms.CheckBox; $chkAutoStart.Text = "Automatically start background music"; $chkAutoStart.AutoSize = $true; $chkAutoStart.Location = Pt 10 102; $chkAutoStart.Checked = [bool]$script:Cfg.Music.AutoStart; $grpMusic.Controls.Add($chkAutoStart)

    $chkAutoStop = New-Object System.Windows.Forms.CheckBox; $chkAutoStop.Text = "Auto stop music before meeting"; $chkAutoStop.AutoSize = $true; $chkAutoStop.Location = Pt 10 134; $chkAutoStop.Checked = [bool]$script:Cfg.Music.AutoStopBeforeMeeting; $grpMusic.Controls.Add($chkAutoStop)

    $baseX = [int]($chkAutoStop.Left + $chkAutoStop.PreferredSize.Width + 12)
    $lblSecs = New-Object System.Windows.Forms.Label; $lblSecs.Text = "Seconds:"; $lblSecs.AutoSize = $true; $lblSecs.Location = Pt $baseX 136; $grpMusic.Controls.Add($lblSecs)
    $numSecs = New-Object System.Windows.Forms.NumericUpDown; $numSecs.Minimum = 1; $numSecs.Maximum = 120; $numSecs.Value = [decimal][int]$script:Cfg.Music.PreStopSeconds
    $numSecs.Size = Sz 60 24; $numSecs.Location = Pt ($baseX + $lblSecs.PreferredSize.Width + 6) 132; $grpMusic.Controls.Add($numSecs)
    # Helper: Disable mouse wheel on NumericUpDown controls
    function Disable-NumericMouseWheel($control) {
        $control.Add_MouseWheel({ param($s, $e); $e.Handled = $true })
    }
    $fadeX = [int]($numSecs.Left + $numSecs.Width + 24)
    $lblFade = New-Object System.Windows.Forms.Label; $lblFade.Text = "Fade-out (s):"; $lblFade.AutoSize = $true; $lblFade.Location = Pt $fadeX 136; $grpMusic.Controls.Add($lblFade)
    $numFade = New-Object System.Windows.Forms.NumericUpDown; $numFade.Minimum = 1; $numFade.Maximum = 10; $numFade.Value = [decimal][int]$script:Cfg.Music.FadeOutSeconds
    $numFade.Size = Sz 60 24; $numFade.Location = Pt ($fadeX + $lblFade.PreferredSize.Width + 6) 132; $grpMusic.Controls.Add($numFade)
    # Helper: Disable mouse wheel on NumericUpDown controls
    function Disable-NumericMouseWheel($control) {
        $control.Add_MouseWheel({ param($s, $e); $e.Handled = $true })
    }
    $y += 186 + 10

    # Dock status bar at the very end (safe anytime)
    $status.Dock = 'Bottom'

    # Preview panel should stretch with window
    $script:pPreview.Anchor = 'Top, Left, Right, Bottom'

    # Bottom row sticks to bottom-left (use safe helper; no errors if null/not yet added)
    foreach ($ctrl in @(
            $lblProgram, $btnBlank, $btnCut, $lblPicker, $btnCam, $btnMed,
            $btnMusicToggle, $script:chip, $btnObsConnect
        )) {
        Set-Anchor $ctrl 'Bottom, Left'
    }
    $status.Dock = 'Bottom'
    $script:pPreview.Anchor = 'Top, Left, Right, Bottom'

    foreach ($ctrl in @(
            $btnAuto,
            $lblProgram, $btnBlank, $btnCut, $lblPicker, $btnCam, $btnMed,
            $btnMusicToggle,
            $script:chip, $btnObsConnect
        )) {
        Set-Anchor $ctrl 'Bottom, Left'
    }

    # ======== OBS Control ========
    [System.Windows.Forms.Application]::DoEvents()  # keep preview alive during dialog build
    $grpObsCtl = New-Object System.Windows.Forms.GroupBox
    $grpObsCtl.Text = "OBS Control"
    $grpObsCtl.Location = Pt 14 $y
    $grpObsCtl.Size = Sz 792 270
    $panel.Controls.Add($grpObsCtl)

    # Auto-start Auto Toggle
    $chkAutoToggle = New-Object System.Windows.Forms.CheckBox
    $chkAutoToggle.Text = "Auto start Auto Toggle (" + [int]$script:Cfg.OBSControl.AutoToggleLeadSeconds + " seconds before start of meeting)"
    $chkAutoToggle.AutoSize = $true
    $chkAutoToggle.Location = Pt 10 26
    $chkAutoToggle.Checked = [bool]$script:Cfg.OBSControl.AutoStartAutoToggle
    $grpObsCtl.Controls.Add($chkAutoToggle)

    # Auto Virtual Camera checkbox
    $chkAutoVirtualCamera = New-Object System.Windows.Forms.CheckBox
    $chkAutoVirtualCamera.Text = "Auto start Virtual Camera (" + [int]$script:Cfg.OBSControl.AutoVirtualCameraSeconds + " seconds before start of meeting)"
    $chkAutoVirtualCamera.AutoSize = $true
    $chkAutoVirtualCamera.Location = Pt 10 58
    $chkAutoVirtualCamera.Checked = [bool]$script:Cfg.OBSControl.AutoVirtualCamera
    $grpObsCtl.Controls.Add($chkAutoVirtualCamera)

    # Row with Host / Port / Password / Show
    # Host
    $lblObsHost = New-Object System.Windows.Forms.Label
    $lblObsHost.Text = "WS Server:"
    $lblObsHost.AutoSize = $true
    $lblObsHost.Location = Pt 10 94
    $grpObsCtl.Controls.Add($lblObsHost)
    
    # Add helpful localhost guidance text
    $lblLocalhostTip = New-Object System.Windows.Forms.Label
    $lblLocalhostTip.Text = "Best IP for local server: 127.0.0.1"
    $lblLocalhostTip.AutoSize = $true
    $lblLocalhostTip.Location = Pt 10 118
    $lblLocalhostTip.ForeColor = [System.Drawing.Color]::DarkGreen
    $lblLocalhostTip.Font = New-Object System.Drawing.Font($lblLocalhostTip.Font.FontFamily, 8, [System.Drawing.FontStyle]::Italic)
    $grpObsCtl.Controls.Add($lblLocalhostTip)

    $tbObsHost = New-Object System.Windows.Forms.TextBox
    $tbObsHost.Text = [string]$script:Cfg.OBS.Host
    $tbObsHost.Size = Sz 125 24
    $tbObsHost.Location = Pt ([int]($lblObsHost.Left + $lblObsHost.PreferredSize.Width + 6)) 90
    $grpObsCtl.Controls.Add($tbObsHost)

    # Port
    $lblObsPort = New-Object System.Windows.Forms.Label
    $lblObsPort.Text = "WS Port:"
    $lblObsPort.AutoSize = $true
    $lblObsPort.Location = Pt ([int]($tbObsHost.Right + 12)) 94
    $grpObsCtl.Controls.Add($lblObsPort)

    $numObsPort = New-Object System.Windows.Forms.NumericUpDown
    $numObsPort.Minimum = 1; $numObsPort.Maximum = 65535
    $numObsPort.Value = [decimal][int]$script:Cfg.OBS.Port
    $numObsPort.Size = Sz 80 24
    $numObsPort.Location = Pt ([int]($lblObsPort.Left + $lblObsPort.PreferredSize.Width + 6)) 90
    $grpObsCtl.Controls.Add($numObsPort)

    # Password + Show/Hide
    $lblObsPwd = New-Object System.Windows.Forms.Label
    $lblObsPwd.Text = "Password:"
    $lblObsPwd.AutoSize = $true
    $lblObsPwd.Location = Pt ([int]($numObsPort.Right + 12)) 94
    $grpObsCtl.Controls.Add($lblObsPwd)

    $tbObsPwd = New-Object System.Windows.Forms.TextBox
    $tbObsPwd.Size = Sz 140 24
    $tbObsPwd.UseSystemPasswordChar = $true
    $tbObsPwd.Text = [string]$script:Cfg.OBS.Password
    $tbObsPwd.Location = Pt ([int]($lblObsPwd.Left + $lblObsPwd.PreferredSize.Width + 6)) 90
    $grpObsCtl.Controls.Add($tbObsPwd)

    $btnShowPwd = New-Object System.Windows.Forms.Button
    $btnShowPwd.Text = "Show"
    $btnShowPwd.Size = Sz 58 24
    $btnShowPwd.Location = Pt ([int]($tbObsPwd.Right + 6)) 90
    $btnShowPwd.Add_Click({
            $tbObsPwd.UseSystemPasswordChar = -not $tbObsPwd.UseSystemPasswordChar
            $btnShowPwd.Text = if ($tbObsPwd.UseSystemPasswordChar) { "Show" } else { "Hide" }
        })
    $grpObsCtl.Controls.Add($btnShowPwd)

    # OBS Recording Settings row
    $chkRecordingConfigured = New-Object System.Windows.Forms.CheckBox
    $chkRecordingConfigured.Text = "OBS Recording Settings configured"
    $chkRecordingConfigured.AutoSize = $true
    $chkRecordingConfigured.Location = Pt 10 168
    $chkRecordingConfigured.Checked = [bool]$script:Cfg.OBSControl.RecordingConfigured
    $grpObsCtl.Controls.Add($chkRecordingConfigured)

    # Blue info button
    $btnRecordingInfo = New-Object System.Windows.Forms.Button
    $btnRecordingInfo.Text = "i"
    $btnRecordingInfo.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $btnRecordingInfo.Size = Sz 26 22
    $btnRecordingInfo.Location = Pt ([int]($chkRecordingConfigured.Left + $chkRecordingConfigured.PreferredSize.Width + 8)) 168
    $btnRecordingInfo.BackColor = [System.Drawing.Color]::FromArgb(70, 130, 220)
    $btnRecordingInfo.ForeColor = [System.Drawing.Color]::White
    $btnRecordingInfo.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $btnRecordingInfo.FlatAppearance.BorderSize = 0
    $btnRecordingInfo.Add_Click({
            $msg = @"
OBS Recording Setup Instructions

1. RECORDING PATH AND FORMAT:
   - In OBS, go to File > Settings > Output
   - Under 'Recording', set your desired Recording Path
   - Set Recording Format to 'MKV'
     (MKV protects your recording if OBS crashes)

2. AUTO-REMUX TO MP4:
   - Still in Settings, go to Advanced
   - Scroll to the 'Recording' section
   - Enable 'Automatically remux to MP4 after recording'
     (OBS will auto-convert MKV to MP4 after stopping)

3. AUDIO SOURCES (add 3 Audio Input Captures in OBS Sources panel):
   - Source 1: your Mixer/microphone input (e.g. 'Mixer Audio')
   - Source 2: your Media/playback audio input (e.g. 'Media Audio')
   - Source 3: your Zoom audio input (e.g. 'Zoom Audio')
   Tip: Name each source clearly so you can tell them apart.

Once set up, tick 'OBS Recording Settings configured' so this
reminder no longer appears when you press the REC button.
"@
            Show-InfoPopup -Title "OBS Recording Setup" -Key "OBSRecording" -DefaultText $msg
        })
    $grpObsCtl.Controls.Add($btnRecordingInfo)

    # Fade-to-black on Cut settings
    $lblFadeScene = New-Object System.Windows.Forms.Label
    $lblFadeScene.Text = "Fade-to-black scene:"
    $lblFadeScene.AutoSize = $true
    $lblFadeScene.Location = Pt 10 196
    $grpObsCtl.Controls.Add($lblFadeScene)

    $tbFadeScene = New-Object System.Windows.Forms.TextBox
    $tbFadeScene.Text = [string]$script:Cfg.OBS.FadeBlackScene
    $tbFadeScene.Size = Sz 130 24
    $tbFadeScene.Location = Pt ([int]($lblFadeScene.Left + $lblFadeScene.PreferredSize.Width + 6)) 193
    $script:tooltip.SetToolTip($tbFadeScene, "Name of a plain-black scene in OBS used for fade-to-black on Cut. Leave empty to disable.")
    $grpObsCtl.Controls.Add($tbFadeScene)

    $lblFadeMs = New-Object System.Windows.Forms.Label
    $lblFadeMs.Text = "Fade (ms):"
    $lblFadeMs.AutoSize = $true
    $lblFadeMs.Location = Pt ([int]($tbFadeScene.Right + 12)) 196
    $grpObsCtl.Controls.Add($lblFadeMs)

    $numFadeMs = New-Object System.Windows.Forms.NumericUpDown
    $numFadeMs.Minimum = 100; $numFadeMs.Maximum = 2000; $numFadeMs.Increment = 50
    $numFadeMs.Value = [decimal][int]$script:Cfg.OBS.FadeBlackMs
    $numFadeMs.Size = Sz 70 24
    $numFadeMs.Location = Pt ([int]($lblFadeMs.Left + $lblFadeMs.PreferredSize.Width + 6)) 193
    $script:tooltip.SetToolTip($numFadeMs, "Duration in milliseconds of each fade leg (fade out + fade in). Default 500 ms.")
    $grpObsCtl.Controls.Add($numFadeMs)

    $lblFadeHold = New-Object System.Windows.Forms.Label
    $lblFadeHold.Text = "Hold black (ms):"
    $lblFadeHold.AutoSize = $true
    $lblFadeHold.Location = Pt ([int]($numFadeMs.Right + 20)) 196
    $grpObsCtl.Controls.Add($lblFadeHold)

    $numFadeHold = New-Object System.Windows.Forms.NumericUpDown
    $numFadeHold.Minimum = 500; $numFadeHold.Maximum = 10000; $numFadeHold.Increment = 250
    $numFadeHold.Value = [decimal][int]$script:Cfg.OBS.FadeBlackHoldMs
    $numFadeHold.Size = Sz 75 24
    $numFadeHold.Location = Pt ([int]($lblFadeHold.Left + $lblFadeHold.PreferredSize.Width + 6)) 193
    $script:tooltip.SetToolTip($numFadeHold, "How long (ms) to hold on black while the PTZ camera moves. Increase if camera hasn't reached position before fade-in. Default 2500 ms.")
    $grpObsCtl.Controls.Add($numFadeHold)

    $lblFadeTip = New-Object System.Windows.Forms.Label
    $lblFadeTip.Text = "Tip: create a scene in OBS named 'Black' with a single black Color Source"
    $lblFadeTip.AutoSize = $true
    $lblFadeTip.Location = Pt 10 224
    $lblFadeTip.ForeColor = [System.Drawing.Color]::DarkGreen
    $lblFadeTip.Font = New-Object System.Drawing.Font($lblFadeTip.Font.FontFamily, 8, [System.Drawing.FontStyle]::Italic)
    $grpObsCtl.Controls.Add($lblFadeTip)

    $y += 270 + 10

    # ======== PiP (Picture-in-Picture) Media ========
    [System.Windows.Forms.Application]::DoEvents()
    $grpPiP = New-Object System.Windows.Forms.GroupBox
    $grpPiP.Text = "PiP Media (Picture-in-Picture)"
    $grpPiP.Location = Pt 14 $y
    $grpPiP.Size = Sz 792 90
    $panel.Controls.Add($grpPiP)

    $chkPiPEnabled = New-Object System.Windows.Forms.CheckBox
    $chkPiPEnabled.Text = "Enable PiP Media toggle button (🔁 above Media button)"
    $chkPiPEnabled.AutoSize = $true
    $chkPiPEnabled.Location = Pt 10 24
    $chkPiPEnabled.Checked = [bool]$script:Cfg.PiP.Enabled
    $grpPiP.Controls.Add($chkPiPEnabled)

    $lblPipSource = New-Object System.Windows.Forms.Label
    $lblPipSource.Text = "OBS Source Name:"
    $lblPipSource.AutoSize = $true
    $lblPipSource.Location = Pt 10 56
    $grpPiP.Controls.Add($lblPipSource)

    $tbPipSourceName = New-Object System.Windows.Forms.TextBox
    $tbPipSourceName.Text = [string]$script:Cfg.PiP.SourceName
    $tbPipSourceName.Size = Sz 220 24
    $tbPipSourceName.Location = Pt ([int]($lblPipSource.Left + $lblPipSource.PreferredSize.Width + 8)) 52
    $grpPiP.Controls.Add($tbPipSourceName)

    $btnPiPInfo = New-Object System.Windows.Forms.Button
    $btnPiPInfo.Text = "i"
    $btnPiPInfo.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $btnPiPInfo.Size = Sz 26 22
    $btnPiPInfo.Location = Pt ([int]($tbPipSourceName.Right + 8)) 52
    $btnPiPInfo.BackColor = [System.Drawing.Color]::FromArgb(70, 130, 220)
    $btnPiPInfo.ForeColor = [System.Drawing.Color]::White
    $btnPiPInfo.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $btnPiPInfo.FlatAppearance.BorderSize = 0
    $btnPiPInfo.Add_Click({
            $msg = @"
PiP MEDIA — Picture-in-Picture Setup Guide
═══════════════════════════════════════════
The PiP button (🔁 orange/green blip above the Media button) lets you
toggle a video-capture source ON/OFF inside your Media OBS scene,
creating a picture-in-picture overlay (e.g. live camera over a video).

HOW TO SET UP IN OBS
═══════════════════════════════════════════
1. Open OBS and switch to your Media scene.

2. In the Sources panel, click '+' → 'Video Capture Device'
   (or 'Window Capture' / 'Display Capture' for screen-based PiP).

3. Name the source EXACTLY as entered in the 'OBS Source Name' field
   above (default: 'PIP Video Capture').
   IMPORTANT: The name must match exactly, including capitalisation.

4. Position and resize the source to the desired PiP location
   (e.g. bottom-right corner, approximately 25% of screen width).

5. Right-click the source in OBS → 'Hide' so it starts hidden.
   The 🔁 button will show/hide it on demand.

6. Tick 'Enable PiP Media toggle button' above so the 🔁 blip
   appears in the main panel whenever OBS is connected.

HOW TO USE
═══════════════════════════════════════════
• Switch OBS to your Media scene first (use the Media button).
• Click the 🔁 button (above Media button) to toggle PiP ON (green)
  or OFF (orange).
• PiP is automatically turned OFF when you leave the Media scene.

TIPS
═══════════════════════════════════════════
• Use a 'Video Capture Device' source pointing to a camera for a
  live speaker-over-media overlay during video playback.
• The 🔁 button is only active when the Media scene is live on Program.
• If the source name is wrong, check the OBS Sources panel for the
  exact spelling and update 'OBS Source Name' here.
"@
            Show-InfoPopup -Title "PiP Media — Setup Guide" -Key "PiPMedia" -DefaultText $msg
        })
    $grpPiP.Controls.Add($btnPiPInfo)

    $y += 90 + 10

    # Status bar stays at the bottom
    $status.Dock = 'Bottom'

    # Preview panel stretches with the window
    Set-Anchor $script:pPreview 'Top, Left, Right, Bottom'

    # Bottom row sticks to bottom-left
    foreach ($ctrl in @(
            $lblProgram, $btnBlank, $btnCut, $lblPicker, $btnCam, $btnMed,
            $btnMusicToggle, $script:chip, $btnObsConnect
        )) {
        Set-Anchor $ctrl 'Bottom, Left'
    }

    # Zoom auto-mute and auto-raise
    [System.Windows.Forms.Application]::DoEvents()  # spinner tick
    $grpZoom = New-Object System.Windows.Forms.GroupBox
    $grpZoom.Text = "Zoom Settings"; $grpZoom.Location = Pt 14 $y; $grpZoom.Size = Sz 792 330; $panel.Controls.Add($grpZoom)  # height updated below
    
    # Add timing conflict warning at the top of Zoom settings
    $lblTimingWarning = New-Object System.Windows.Forms.Label
    $lblTimingWarning.Text = "To avoid conflicts, ensure a 5-10 sec delay between Auto actions"
    $lblTimingWarning.AutoSize = $true
    $lblTimingWarning.Location = Pt 10 24
    $lblTimingWarning.ForeColor = [System.Drawing.Color]::Green
    $lblTimingWarning.Font = New-Object System.Drawing.Font("Segoe UI", 8, [System.Drawing.FontStyle]::Italic)
    $grpZoom.Controls.Add($lblTimingWarning)

    $btnZoomHotkeysInfo = New-Object System.Windows.Forms.Button
    $btnZoomHotkeysInfo.Text = "i"
    $btnZoomHotkeysInfo.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $btnZoomHotkeysInfo.Size = Sz 26 22
    $btnZoomHotkeysInfo.Location = Pt 754 20
    $btnZoomHotkeysInfo.BackColor = [System.Drawing.Color]::FromArgb(70, 130, 220)
    $btnZoomHotkeysInfo.ForeColor = [System.Drawing.Color]::White
    $btnZoomHotkeysInfo.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $btnZoomHotkeysInfo.FlatAppearance.BorderSize = 0
    $btnZoomHotkeysInfo.Add_Click({
            $msg = @"
ZOOM KEYBOARD SHORTCUTS REQUIRED

These auto actions use Zoom hotkeys:

    • Auto mute All before meeting start  -> Alt+M
    • Auto toggle Zoom Camera ON          -> Alt+V
    • Unmute me (Host) before meeting     -> Alt+A

How to enable/check in Zoom:

    1. Open Zoom Workplace.
    2. Go to Settings.
    3. Open All settings.
    4. Open Keyboard shortcuts.
    5. Ensure Alt+M, Alt+V and Alt+A are enabled.

If these shortcuts are disabled in Zoom, automatic controls may not work.
"@
            Show-InfoPopup -Title "Zoom Hotkeys Setup" -Key "ZoomHotkeys" -DefaultText $msg
        })
    $grpZoom.Controls.Add($btnZoomHotkeysInfo)
    
    # Auto mute section (existing)
    $chkMuteAll = New-Object System.Windows.Forms.CheckBox
    $chkMuteAll.Text = "Auto mute All before meeting start"
    $chkMuteAll.AutoSize = $true; $chkMuteAll.Location = Pt 10 52
    $chkMuteAll.Checked = [bool]$script:Cfg.Zoom.AutoMuteAll
    $grpZoom.Controls.Add($chkMuteAll)
    $lblMuteSecs = New-Object System.Windows.Forms.Label; $lblMuteSecs.Text = "Seconds:"; $lblMuteSecs.AutoSize = $true
    $lblMuteSecs.Location = Pt ([int]($chkMuteAll.Left + $chkMuteAll.PreferredSize.Width + 20)) 54
    $grpZoom.Controls.Add($lblMuteSecs)
    $numMuteSecs = New-Object System.Windows.Forms.NumericUpDown
    $numMuteSecs.Minimum = 1; $numMuteSecs.Maximum = 120
    $numMuteSecs.Value = [decimal][int]$script:Cfg.Zoom.AutoMuteSeconds
    $numMuteSecs.Size = Sz 60 24; $numMuteSecs.Location = Pt ($lblMuteSecs.Left + $lblMuteSecs.PreferredSize.Width + 6) 50
    $grpZoom.Controls.Add($numMuteSecs)
    $lblMuteHotkeyHint = New-Object System.Windows.Forms.Label
    $lblMuteHotkeyHint.Text = "Enable Alt+M in Zoom Keyboard shortcuts"
    $lblMuteHotkeyHint.AutoSize = $true
    $lblMuteHotkeyHint.Location = Pt ($numMuteSecs.Left + $numMuteSecs.Width + 10) 54
    $lblMuteHotkeyHint.ForeColor = [System.Drawing.Color]::FromArgb(30, 90, 180)
    $grpZoom.Controls.Add($lblMuteHotkeyHint)
    
    # Auto Unmute Host section (new)
    $chkUnmuteHost = New-Object System.Windows.Forms.CheckBox
    $chkUnmuteHost.Text = "Unmute me (Host) before meeting start"
    $chkUnmuteHost.AutoSize = $true; $chkUnmuteHost.Location = Pt 10 116
    $chkUnmuteHost.Checked = [bool]$script:Cfg.Zoom.AutoUnmuteHost
    $grpZoom.Controls.Add($chkUnmuteHost)
    $lblUnmuteSecs = New-Object System.Windows.Forms.Label; $lblUnmuteSecs.Text = "Seconds:"; $lblUnmuteSecs.AutoSize = $true
    $lblUnmuteSecs.Location = Pt ([int]($chkUnmuteHost.Left + $chkUnmuteHost.PreferredSize.Width + 20)) 118
    $grpZoom.Controls.Add($lblUnmuteSecs)
    $numUnmuteSecs = New-Object System.Windows.Forms.NumericUpDown
    $numUnmuteSecs.Minimum = 1; $numUnmuteSecs.Maximum = 120
    $numUnmuteSecs.Value = [decimal][int]$script:Cfg.Zoom.AutoUnmuteSeconds
    $numUnmuteSecs.Size = Sz 60 24; $numUnmuteSecs.Location = Pt ($lblUnmuteSecs.Left + $lblUnmuteSecs.PreferredSize.Width + 6) 114
    $grpZoom.Controls.Add($numUnmuteSecs)
    $lblUnmuteHotkeyHint = New-Object System.Windows.Forms.Label
    $lblUnmuteHotkeyHint.Text = "Enable Alt+A in Zoom Keyboard shortcuts"
    $lblUnmuteHotkeyHint.AutoSize = $true
    $lblUnmuteHotkeyHint.Location = Pt ($numUnmuteSecs.Left + $numUnmuteSecs.Width + 10) 118
    $lblUnmuteHotkeyHint.ForeColor = [System.Drawing.Color]::FromArgb(30, 90, 180)
    $grpZoom.Controls.Add($lblUnmuteHotkeyHint)
    
    # Auto Camera Toggle section (new)
    $chkCameraOn = New-Object System.Windows.Forms.CheckBox
    $chkCameraOn.Text = "Auto toggle Zoom Camera ON"
    $chkCameraOn.AutoSize = $true; $chkCameraOn.Location = Pt 10 84
    $chkCameraOn.Checked = [bool]$script:Cfg.Zoom.AutoCameraOn
    $grpZoom.Controls.Add($chkCameraOn)

    # Auto Focus Mode section (new)
    $chkFocusMode = New-Object System.Windows.Forms.CheckBox
    $chkFocusMode.Text = "Auto start Focus mode"
    $chkFocusMode.AutoSize = $true; $chkFocusMode.Location = Pt 10 148
    $chkFocusMode.Checked = [bool]$script:Cfg.Zoom.AutoFocusMode
    $grpZoom.Controls.Add($chkFocusMode)
    $lblFocusSecs = New-Object System.Windows.Forms.Label; $lblFocusSecs.Text = "Seconds:"; $lblFocusSecs.AutoSize = $true
    $lblFocusSecs.Location = Pt ([int]($chkFocusMode.Left + $chkFocusMode.PreferredSize.Width + 20)) 150
    $grpZoom.Controls.Add($lblFocusSecs)
    $numFocusSecs = New-Object System.Windows.Forms.NumericUpDown
    $numFocusSecs.Minimum = 1; $numFocusSecs.Maximum = 120
    $numFocusSecs.Value = [decimal][int]$script:Cfg.Zoom.AutoFocusSeconds
    $numFocusSecs.Size = Sz 60 24; $numFocusSecs.Location = Pt ($lblFocusSecs.Left + $lblFocusSecs.PreferredSize.Width + 6) 146
    $grpZoom.Controls.Add($numFocusSecs)

    # When enabling auto-unmute or auto-camera, warn if Zoom mic/camera are currently off
    $chkUnmuteHost.Add_CheckedChanged({ })
    $chkCameraOn.Add_CheckedChanged({ })
    $lblCameraSecs = New-Object System.Windows.Forms.Label; $lblCameraSecs.Text = "Seconds:"; $lblCameraSecs.AutoSize = $true
    $lblCameraSecs.Location = Pt ([int]($chkMuteAll.Left + $chkMuteAll.PreferredSize.Width + 20)) 86
    $grpZoom.Controls.Add($lblCameraSecs)
    $numCameraSecs = New-Object System.Windows.Forms.NumericUpDown
    $numCameraSecs.Minimum = 1; $numCameraSecs.Maximum = 120
    $numCameraSecs.Value = [decimal][int]$script:Cfg.Zoom.AutoCameraSeconds
    $numCameraSecs.Size = Sz 60 24; $numCameraSecs.Location = Pt ($lblMuteSecs.Left + $lblMuteSecs.PreferredSize.Width + 6) 82
    $grpZoom.Controls.Add($numCameraSecs)
    $lblCameraHotkeyHint = New-Object System.Windows.Forms.Label
    $lblCameraHotkeyHint.Text = "Enable Alt+V in Zoom Keyboard shortcuts"
    $lblCameraHotkeyHint.AutoSize = $true
    $lblCameraHotkeyHint.Location = Pt ($numCameraSecs.Left + $numCameraSecs.Width + 10) 86
    $lblCameraHotkeyHint.ForeColor = [System.Drawing.Color]::FromArgb(30, 90, 180)
    $grpZoom.Controls.Add($lblCameraHotkeyHint)
    
    # Auto Zoom Audio section (after Focus Mode)
    $chkZoomAudio = New-Object System.Windows.Forms.CheckBox
    $chkZoomAudio.Text = "Enable Auto Zoom Audio"
    $chkZoomAudio.AutoSize = $true; $chkZoomAudio.Location = Pt 10 180
    $chkZoomAudio.Checked = [bool]$script:Cfg.Zoom.AutoZoomAudio
    $grpZoom.Controls.Add($chkZoomAudio)
    
    # Zoom In Line selector
    $lblZoomLine = New-Object System.Windows.Forms.Label; $lblZoomLine.Text = "Zoom In Line:"; $lblZoomLine.AutoSize = $true
    $lblZoomLine.Location = Pt ([int]($chkZoomAudio.Left + $chkZoomAudio.PreferredSize.Width + 20)) 182
    $grpZoom.Controls.Add($lblZoomLine)
    $cmbZoomLine = New-Object System.Windows.Forms.ComboBox
    $cmbZoomLine.DropDownStyle = 'DropDownList'
    for ($i = 1; $i -le 10; $i++) { [void]$cmbZoomLine.Items.Add($i) }
    $cmbZoomLine.SelectedIndex = [int]$script:Cfg.Zoom.ZoomInLine - 1
    $cmbZoomLine.Size = Sz 50 24; $cmbZoomLine.Location = Pt ($lblZoomLine.Left + $lblZoomLine.PreferredSize.Width + 6) 178
    $grpZoom.Controls.Add($cmbZoomLine)
    
    # Audio level dB
    $lblAudioDb = New-Object System.Windows.Forms.Label; $lblAudioDb.Text = "Audio level db:"; $lblAudioDb.AutoSize = $true
    $lblAudioDb.Location = Pt ([int]($cmbZoomLine.Left + $cmbZoomLine.Width + 15)) 182
    $grpZoom.Controls.Add($lblAudioDb)
    $txtAudioDb = New-Object System.Windows.Forms.TextBox
    $txtAudioDb.Text = [string]$script:Cfg.Zoom.AudioLevelDb
    $txtAudioDb.Size = Sz 60 24; $txtAudioDb.Location = Pt ($lblAudioDb.Left + $lblAudioDb.PreferredSize.Width + 6) 178
    $grpZoom.Controls.Add($txtAudioDb)
    
    # Hold Time
    $lblHoldTime = New-Object System.Windows.Forms.Label; $lblHoldTime.Text = "Hold Time:"; $lblHoldTime.AutoSize = $true
    $lblHoldTime.Location = Pt 10 212
    $grpZoom.Controls.Add($lblHoldTime)
    $numHoldTime = New-Object System.Windows.Forms.NumericUpDown
    $numHoldTime.Minimum = 500; $numHoldTime.Maximum = 10000; $numHoldTime.Increment = 250
    $numHoldTime.Value = [decimal][int]$script:Cfg.Zoom.HoldTimeMs
    $numHoldTime.Size = Sz 80 24; $numHoldTime.Location = Pt ($lblHoldTime.Left + $lblHoldTime.PreferredSize.Width + 6) 208
    $grpZoom.Controls.Add($numHoldTime)
    $lblHoldMs = New-Object System.Windows.Forms.Label; $lblHoldMs.Text = "ms"; $lblHoldMs.AutoSize = $true
    $lblHoldMs.Location = Pt ($numHoldTime.Left + $numHoldTime.Width + 6) 212
    $grpZoom.Controls.Add($lblHoldMs)

    # Hand Alert Monitor selector (placed under Hold Time)
    $lblHandMonitor = New-Object System.Windows.Forms.Label; $lblHandMonitor.Text = "Hand Alert Monitor:"; $lblHandMonitor.AutoSize = $true
    $lblHandMonitor.Location = Pt 10 244
    $grpZoom.Controls.Add($lblHandMonitor)
    $cmbHandMonitor = New-Object System.Windows.Forms.ComboBox
    $cmbHandMonitor.DropDownStyle = 'DropDownList'
    $screens = [System.Windows.Forms.Screen]::AllScreens
    # Ensure primary monitor is always listed first as "Monitor 1"
    $screens = $screens | Sort-Object @{ Expression = { -not $_.Primary } }, DeviceName
    for ($i = 0; $i -lt $screens.Length; $i++) {
        $scr = $screens[$i]
        $dev = $scr.DeviceName
        $short = ($dev -replace '^.*\\', '')
        $suffix = if ($scr.Primary) { ' (Primary)' } else { '' }
        $label = "Monitor {0} [{1}] {2}x{3}{4}" -f `
        ($i + 1), `
            $short, `
            $scr.Bounds.Width, `
            $scr.Bounds.Height, `
            $suffix
        [void]$cmbHandMonitor.Items.Add($label)
    }
    $sel = [int]$script:Cfg.Zoom.HandAlertMonitor
    if ($sel -lt 0 -or $sel -ge $cmbHandMonitor.Items.Count) { $sel = 0 }
    if ($cmbHandMonitor.Items.Count -gt 0) { $cmbHandMonitor.SelectedIndex = $sel }
    $cmbHandMonitor.Size = Sz 260 24; $cmbHandMonitor.Location = Pt ($lblHandMonitor.Left + $lblHandMonitor.PreferredSize.Width + 6) 240
    $cmbHandMonitor.Add_SelectedIndexChanged({
            try { $script:Cfg.Zoom.HandAlertMonitor = [int]$cmbHandMonitor.SelectedIndex } catch {}
        })
    $grpZoom.Controls.Add($cmbHandMonitor)
    
    # Auto Join Meeting section separator (spaced below Hold Time)
    $lblJoinSeparator = New-Object System.Windows.Forms.Label
    $lblJoinSeparator.Text = "Auto Join Meeting"; $lblJoinSeparator.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $lblJoinSeparator.AutoSize = $true; $lblJoinSeparator.Location = Pt 10 280
    $grpZoom.Controls.Add($lblJoinSeparator)
    
    # Meeting ID
    $lblMeetingID = New-Object System.Windows.Forms.Label
    $lblMeetingID.Text = "Meeting ID:"; $lblMeetingID.AutoSize = $true; $lblMeetingID.Location = Pt 10 308
    $grpZoom.Controls.Add($lblMeetingID)
    $txtMeetingID = New-Object System.Windows.Forms.TextBox
    $txtMeetingID.Text = [string]$script:Cfg.Zoom.JoinMeetingID
    $txtMeetingID.Size = Sz 150 24; $txtMeetingID.Location = Pt ($lblMeetingID.Left + $lblMeetingID.PreferredSize.Width + 6) 304
    $grpZoom.Controls.Add($txtMeetingID)
    
    # Display Name
    $lblDisplayName = New-Object System.Windows.Forms.Label
    $lblDisplayName.Text = "Display Name:"; $lblDisplayName.AutoSize = $true
    $lblDisplayName.Location = Pt ($txtMeetingID.Left + $txtMeetingID.Width + 20) 308
    $grpZoom.Controls.Add($lblDisplayName)
    $txtDisplayName = New-Object System.Windows.Forms.TextBox
    $txtDisplayName.Text = [string]$script:Cfg.Zoom.JoinDisplayName
    $txtDisplayName.Size = Sz 150 24; $txtDisplayName.Location = Pt ($lblDisplayName.Left + $lblDisplayName.PreferredSize.Width + 6) 304
    $grpZoom.Controls.Add($txtDisplayName)
    
    # Checkboxes row
    $chkDontConnectAudio = New-Object System.Windows.Forms.CheckBox
    $chkDontConnectAudio.Text = "Don't connect to audio"
    $chkDontConnectAudio.AutoSize = $true; $chkDontConnectAudio.Location = Pt 10 340
    $chkDontConnectAudio.Checked = [bool]$script:Cfg.Zoom.JoinDontConnectAudio
    $grpZoom.Controls.Add($chkDontConnectAudio)
    
    $chkTurnOffVideo = New-Object System.Windows.Forms.CheckBox
    $chkTurnOffVideo.Text = "Turn off video"
    $chkTurnOffVideo.AutoSize = $true; $chkTurnOffVideo.Location = Pt ($chkDontConnectAudio.Left + $chkDontConnectAudio.PreferredSize.Width + 40) 340
    $chkTurnOffVideo.Checked = [bool]$script:Cfg.Zoom.JoinTurnOffVideo
    $grpZoom.Controls.Add($chkTurnOffVideo)
    
    # Meeting Password
    $lblMeetingPassword = New-Object System.Windows.Forms.Label
    $lblMeetingPassword.Text = "Password:"; $lblMeetingPassword.AutoSize = $true; $lblMeetingPassword.Location = Pt 10 374
    $grpZoom.Controls.Add($lblMeetingPassword)
    $txtMeetingPassword = New-Object System.Windows.Forms.TextBox
    $txtMeetingPassword.Text = [string]$script:Cfg.Zoom.JoinMeetingPassword
    $txtMeetingPassword.PasswordChar = '*'
    $txtMeetingPassword.Size = Sz 150 24; $txtMeetingPassword.Location = Pt ($lblMeetingPassword.Left + $lblMeetingPassword.PreferredSize.Width + 6) 370
    $grpZoom.Controls.Add($txtMeetingPassword)

    # Auto start Polls checkbox (after join settings)
    $chkAutoPolls = New-Object System.Windows.Forms.CheckBox
    $chkAutoPolls.Text = "Auto start Polls after joining Zoom"
    $chkAutoPolls.AutoSize = $true
    $chkAutoPolls.Location = Pt 10 408
    $chkAutoPolls.Checked = [bool]$script:Cfg.Zoom.AutoPollsAfterJoin
    $grpZoom.Controls.Add($chkAutoPolls)

    # Focus Mode button visibility toggle
    $chkShowFocusBtn = New-Object System.Windows.Forms.CheckBox
    $chkShowFocusBtn.Text = "Enable Focus Mode"
    $chkShowFocusBtn.AutoSize = $true
    $chkShowFocusBtn.Location = Pt 10 442
    $chkShowFocusBtn.Checked = [bool]$script:Cfg.Zoom.ShowFocusModeButton
    $grpZoom.Controls.Add($chkShowFocusBtn)

    # Info button for Focus Mode
    $btnFocusModeInfo = New-Object System.Windows.Forms.Button
    $btnFocusModeInfo.Text = "i"
    $btnFocusModeInfo.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $btnFocusModeInfo.Size = Sz 26 22
    $btnFocusModeInfo.Location = Pt ([int]($chkShowFocusBtn.Left + $chkShowFocusBtn.PreferredSize.Width + 8)) 442
    $btnFocusModeInfo.BackColor = [System.Drawing.Color]::FromArgb(70, 130, 220)
    $btnFocusModeInfo.ForeColor = [System.Drawing.Color]::White
    $btnFocusModeInfo.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $btnFocusModeInfo.FlatAppearance.BorderSize = 0
    $btnFocusModeInfo.Add_Click({
            $msg = @"
FOCUS MODE — What it is

Focus mode is designed for the digital learning environment. It allows
students to stay attentive without being distracted by other participants.

  • The host and co-hosts can see ALL participants' videos.
  • Participants can only see their OWN video, not each other's.
  • Screen sharing: host/co-host can view and switch between each
    participant's shared screen; participants see only their own content.
  • The host can share a participant's screen with everyone if needed.

──────────────────────────────────────────────
REQUIREMENT
  Account owner or admin privileges to enable/disable for the account.

HOW TO ENABLE FOCUS MODE IN YOUR ZOOM ACCOUNT

1. Sign in to the Zoom web portal as an admin.
2. Go to Account Management → Account Settings.
3. Click the Meeting tab.
4. Under "In Meeting (Advanced)", toggle Focus Mode ON.
5. If a verification dialog appears, click Enable to confirm.
6. (Optional) Check "Allow host to enable focus mode when scheduling"
   and click Save — this lets meetings start with Focus Mode active.
7. (Optional) Click the lock icon to make this mandatory for all users.

Once enabled in your Zoom account, use the Focus Mode button in this
app to toggle it on/off during a live meeting.
"@
            Show-InfoPopup -Title "Focus Mode — Setup & Info" -Key "FocusMode" -DefaultText $msg
        })
    $grpZoom.Controls.Add($btnFocusModeInfo)

    # Keep Auto-start Focus controls on the same row as Enable Focus Mode + Info
    $chkFocusMode.Location = Pt ([int]($btnFocusModeInfo.Right + 12)) 442
    $lblFocusSecs.Location = Pt ([int]($chkFocusMode.Right + 12)) 444
    $numFocusSecs.Location = Pt ([int]($lblFocusSecs.Right + 6)) 440

    # Auto-start Focus controls are only active when Focus Mode is enabled
    $syncFocusAutoState = {
        $enabled = [bool]$chkShowFocusBtn.Checked
        $chkFocusMode.Enabled = $enabled
        $lblFocusSecs.Enabled = $enabled
        $numFocusSecs.Enabled = $enabled
    }
    $chkShowFocusBtn.Add_CheckedChanged($syncFocusAutoState)
    & $syncFocusAutoState

    # Polls Setup configured checkbox + info button — on the same line as Auto start Polls
    $chkPollsConfigured = New-Object System.Windows.Forms.CheckBox
    $chkPollsConfigured.Text = "Polls Setup"
    $chkPollsConfigured.AutoSize = $true
    $chkPollsConfigured.Location = Pt ([int]($chkAutoPolls.Left + $chkAutoPolls.PreferredSize.Width + 14)) 408
    $chkPollsConfigured.Checked = [bool]$script:Cfg.Zoom.PollsConfigured
    $grpZoom.Controls.Add($chkPollsConfigured)

    $btnPollsInfo = New-Object System.Windows.Forms.Button
    $btnPollsInfo.Text = "i"
    $btnPollsInfo.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $btnPollsInfo.Size = Sz 26 22
    $btnPollsInfo.Location = Pt ([int]($chkPollsConfigured.Left + $chkPollsConfigured.PreferredSize.Width + 8)) 408
    $btnPollsInfo.BackColor = [System.Drawing.Color]::FromArgb(70, 130, 220)
    $btnPollsInfo.ForeColor = [System.Drawing.Color]::White
    $btnPollsInfo.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $btnPollsInfo.FlatAppearance.BorderSize = 0
    $btnPollsInfo.Add_Click({
            $msg = @"
ATTENDANCE POLL — Setup Guide

The Polls button in this app launches your pre-configured Attendance
Poll in Zoom so you can count participants quickly during a meeting.

──────────────────────────────────────────────
STEP 1 — CREATE THE ATTENDANCE POLL IN ZOOM
  1. Sign in to the Zoom web portal (zoom.us).
  2. Go to Meetings and open (or schedule) your recurring meeting.
  3. Scroll down and click 'Polls/Quizzes', then '+ Create'.
  4. Set the poll title to 'Attendance poll'.
  5. Add the question:
       'How many in Attendance 0-6 (cohost = 0)'
       Type: Single choice
       Answers: 0 I am already Counted or Host / 1 / 2 / 3 / 4 / 5 / 6
  6. Click Save.

STEP 2 — ADD THE POLLS ICON TO THE ZOOM TOOLBAR
  So you can quickly access Polls during a live meeting:
  1. Start or join your Zoom meeting.
  2. In the meeting toolbar at the bottom, click the 'More' button (...).
  3. Find 'Polls/Quizzes' in the list.
  4. Drag it from the More menu into the main toolbar.
     (You may need to remove icons you don't use to make room.)
  5. The Polls icon will now always be visible in your toolbar.

STEP 3 — USING THE POLLS BUTTON IN THIS APP
  • Click the 'Polls' button in this app during a meeting.
  • It will automatically open the Polls panel in Zoom and
    launch your Attendance Poll.
  • NOTE: There is a short delay (a few seconds) before the
    attendance count updates after participants answer.
    Wait a moment before reading the result.

Once your poll is set up in Zoom, tick 'Polls Setup' in Settings
so the reminder no longer appears when you press the Polls button.
"@
            Show-InfoPopup -Title "Polls — Setup Guide" -Key "PollsSetup" -DefaultText $msg
        })
    $grpZoom.Controls.Add($btnPollsInfo)

    # Expand group to fit all rows (last row is Focus Mode at y=442)
    $grpZoom.Size = Sz 792 476

    # Move next section down by full Zoom group height
    $y += 476 + 10

    # Pop Up Reminders
    [System.Windows.Forms.Application]::DoEvents()  # spinner tick
    $grpRem = New-Object System.Windows.Forms.GroupBox
    $grpRem.Text = "Pop Up Reminders"; $grpRem.Location = Pt 14 $y; $grpRem.Size = Sz 792 300; $panel.Controls.Add($grpRem)
    
    # Reminder #1
    $chkRem = New-Object System.Windows.Forms.CheckBox
    $chkRem.Text = "Zoom Settings Reminders before start of Meeting"
    $chkRem.AutoSize = $true; $chkRem.Location = Pt 10 28
    $chkRem.Checked = [bool]$script:Cfg.Reminders.ZoomEnabled
    $grpRem.Controls.Add($chkRem)
    $lblRemS = New-Object System.Windows.Forms.Label; $lblRemS.Text = "Seconds:"; $lblRemS.AutoSize = $true
    $lblRemS.Location = Pt ([int]($chkRem.Left + $chkRem.PreferredSize.Width + 20)) 30
    $grpRem.Controls.Add($lblRemS)
    $numRemS = New-Object System.Windows.Forms.NumericUpDown
    $numRemS.Minimum = -300; $numRemS.Maximum = 300
    $numRemS.Value = [decimal][int]$script:Cfg.Reminders.Seconds
    $numRemS.Size = Sz 60 24; $numRemS.Location = Pt ($lblRemS.Left + $lblRemS.PreferredSize.Width + 6) 26
    $grpRem.Controls.Add($numRemS)
    
    # Message Edit box
    $lblRemMsg = New-Object System.Windows.Forms.Label; $lblRemMsg.Text = "Edit Message:"; $lblRemMsg.AutoSize = $true
    $lblRemMsg.Location = Pt 10 64
    $grpRem.Controls.Add($lblRemMsg)
    $txtRemMsg = New-Object System.Windows.Forms.TextBox
    $txtRemMsg.Multiline = $true
    $txtRemMsg.ScrollBars = 'Vertical'
    $txtRemMsg.AcceptsReturn = $true
    $txtRemMsg.Text = [string]$script:Cfg.Reminders.Message
    $txtRemMsg.Size = Sz 560 80
    $txtRemMsg.Location = Pt ([int]($lblRemMsg.Right + 8)) 60
    $grpRem.Controls.Add($txtRemMsg)
    
    # Reminder #2
    $chkRem2 = New-Object System.Windows.Forms.CheckBox
    $chkRem2.Text = "Reminder #2"
    $chkRem2.AutoSize = $true; $chkRem2.Location = Pt 10 154
    $chkRem2.Checked = [bool]$script:Cfg.Reminders.Reminder2Enabled
    $grpRem.Controls.Add($chkRem2)
    $lblRem2S = New-Object System.Windows.Forms.Label; $lblRem2S.Text = "Seconds:"; $lblRem2S.AutoSize = $true
    $lblRem2S.Location = Pt ([int]($chkRem2.Left + $chkRem2.PreferredSize.Width + 20)) 156
    $grpRem.Controls.Add($lblRem2S)
    $numRem2S = New-Object System.Windows.Forms.NumericUpDown
    $numRem2S.Minimum = -300; $numRem2S.Maximum = 300
    $numRem2S.Value = [decimal][int]$script:Cfg.Reminders.Reminder2Seconds
    $numRem2S.Size = Sz 60 24; $numRem2S.Location = Pt ($lblRem2S.Left + $lblRem2S.PreferredSize.Width + 6) 152
    $grpRem.Controls.Add($numRem2S)
    
    # Message #2 Edit box
    $lblRemMsg2 = New-Object System.Windows.Forms.Label; $lblRemMsg2.Text = "Edit Message:"; $lblRemMsg2.AutoSize = $true
    $lblRemMsg2.Location = Pt 10 192
    $grpRem.Controls.Add($lblRemMsg2)
    $txtRemMsg2 = New-Object System.Windows.Forms.TextBox
    $txtRemMsg2.Multiline = $true
    $txtRemMsg2.ScrollBars = 'Vertical'
    $txtRemMsg2.AcceptsReturn = $true
    $txtRemMsg2.Text = [string]$script:Cfg.Reminders.Message2
    $txtRemMsg2.Size = Sz 560 80
    $txtRemMsg2.Location = Pt ([int]($lblRemMsg2.Right + 8)) 188
    $grpRem.Controls.Add($txtRemMsg2)
    
    $y += 300 + 10
    $yAfterCheckbox = $y   # virtual height when XR sections are hidden (captured after Pop Up Reminders)

    # ---------- XR Family Mixer Control ----------
    [System.Windows.Forms.Application]::DoEvents()  # keep preview alive during dialog build
    $grpXR = New-Object System.Windows.Forms.GroupBox
    $grpXR.Text = "XR Family Mixer control"
    $grpXR.Location = Pt 14 $y
    $grpXR.Size = Sz 792 750
    $panel.Controls.Add($grpXR)

    # Mixer IP
    $lblIp = New-Object System.Windows.Forms.Label
    $lblIp.Text = "Mixer IP:"
    $lblIp.AutoSize = $true
    $lblIp.Location = Pt 10 28
    $grpXR.Controls.Add($lblIp)

    $tbIp = New-Object System.Windows.Forms.TextBox
    $tbIp.Text = [string]$script:Cfg.XR.MixerIP
    $tbIp.Size = Sz 150 24
    $tbIp.Location = Pt 90 24
    $grpXR.Controls.Add($tbIp)
    
    # Scan button
    $btnXRScan = New-Object System.Windows.Forms.Button
    $btnXRScan.Text = "Scan"
    $btnXRScan.Size = Sz 60 24
    $btnXRScan.Location = Pt 250 24
    $grpXR.Controls.Add($btnXRScan)

    # Info button for XR Family Mixer
    $btnXRInfo = New-Object System.Windows.Forms.Button
    $btnXRInfo.Text = "i"
    $btnXRInfo.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $btnXRInfo.Size = Sz 26 22
    $btnXRInfo.Location = Pt 636 14
    $btnXRInfo.BackColor = [System.Drawing.Color]::FromArgb(70, 130, 220)
    $btnXRInfo.ForeColor = [System.Drawing.Color]::White
    $btnXRInfo.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $btnXRInfo.FlatAppearance.BorderSize = 0
    $btnXRInfo.Add_Click({
            $msg = @"
XR FAMILY MIXER — Setup Guide

This app controls your Behringer XR12 / XR16 / XR18 (or X Air series)
digital mixer via OSC (UDP network messages).

──────────────────────────────────────────────
STEP 1 — CONNECT THE MIXER TO YOUR NETWORK
  • Power on the XR mixer.
  • Connect it to your Wi-Fi router or switch via Ethernet (recommended)
    or let it broadcast its own Wi-Fi access point.

STEP 2 — FIND THE MIXER'S IP ADDRESS
  • Open the Behringer 'X AIR Edit' app (free download from Behringer).
  • In X AIR Edit, go to Setup (top-right gear icon) → Network.
  • The mixer's IP address is shown there (e.g. 192.168.1.75).
  • Alternatively: in your router's admin page, look under
    Connected Devices for a device named 'XR12' or similar.
  • You can also press 'Scan' in this settings panel — the app will
    automatically search your local network for a compatible mixer.

STEP 3 — ENTER THE IP HERE
  • Paste or type the IP address into the 'Mixer IP' field above.
  • Leave the OSC Port at 10024 (default for all XR/X Air mixers).

STEP 4 — TEST THE CONNECTION
  • Click 'Test' to verify the app can talk to the mixer.
  • A successful test will confirm the connection in the status label.

STEP 5 — SNAPSHOTS
  • The XR mixer can store up to 10 Scene Snapshots (full channel configs).
  • In X AIR Edit: Scenes (top menu) → Save Scene → pick a slot 1-10.
  • In this app, each OBS scene row can recall a specific snapshot number
    so switching an OBS scene also recalls your saved mixer preset.

OPTIONAL — AUTO SCAN
  • Enable 'Auto Scan' to have the app re-try finding the mixer
    automatically if the connection drops (e.g. after a power cycle).
  • Note: scanning takes a few seconds and sends broadcast UDP packets.
"@
            Show-InfoPopup -Title "XR Mixer — Setup Guide" -Key "XRMixer" -DefaultText $msg
        })
    $grpXR.Controls.Add($btnXRInfo)
    
    # Scan status label - below the IP field to not block anything
    $lblXRStatus = New-Object System.Windows.Forms.Label
    $lblXRStatus.Text = ""
    $lblXRStatus.AutoSize = $false
    $lblXRStatus.Size = Sz 300 20
    $lblXRStatus.Location = Pt 90 52
    $grpXR.Controls.Add($lblXRStatus)
    
    # Add cancel capability and scanning state
    $script:ScanCancelToken = [ref]$false
    $script:IsScanning = $false

    $btnXRScan.Add_Click({
            try {
                # Check if we're currently scanning
                if ($script:IsScanning) {
                    # Cancel the current scan
                    $script:ScanCancelToken.Value = $true
                    $lblXRStatus.Text = "Cancelling..."
                    $lblXRStatus.ForeColor = [System.Drawing.Color]::Red
                    $dlg.Refresh()
                    return
                }
                
                # Start new scan
                $script:IsScanning = $true
                $script:ScanCancelToken.Value = $false
                
                # Change button to Cancel during scan
                $btnXRScan.Text = "Cancel"
                $btnXRScan.BackColor = [System.Drawing.Color]::Orange
                $lblXRStatus.Text = "Starting scan..."
                $lblXRStatus.ForeColor = [System.Drawing.Color]::Orange
                $dlg.Refresh()
                
                # Create progress callback
                $progressCallback = {
                    param($currentIP, $percent)
                    $lblXRStatus.Text = "Scanning: $currentIP ($percent%)"
                    $dlg.Refresh()
                    [System.Windows.Forms.Application]::DoEvents()  # Allow UI updates and cancel button clicks
                }
                
                # Run the proper X-Air scan
                $foundIP = XR-ScanForMixer -ProgressCallback $progressCallback -CancelToken $script:ScanCancelToken
                
                # Restore button state
                $script:IsScanning = $false
                $btnXRScan.Text = "Scan"
                $btnXRScan.BackColor = [System.Drawing.SystemColors]::Control
                
                if ($script:ScanCancelToken.Value) {
                    $lblXRStatus.Text = "✗ Scan cancelled"
                    $lblXRStatus.ForeColor = [System.Drawing.Color]::Gray
                }
                elseif ($foundIP) {
                    $tbIp.Text = $foundIP
                    $lblXRStatus.Text = "✓ Found X-Air: $foundIP"
                    $lblXRStatus.ForeColor = [System.Drawing.Color]::Green
                    # Auto-save the found IP
                    $script:Cfg.XR.MixerIP = $foundIP
                    Save-Settings
                }
                else {
                    $lblXRStatus.Text = "✗ No X-Air mixers found"
                    $lblXRStatus.ForeColor = [System.Drawing.Color]::Red
                    
                    # Get current network info for helpful message
                    $myIp = ""
                    try {
                        $adapter = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and $_.InterfaceDescription -notmatch 'Virtual|Loopback|VPN' } | Select-Object -First 1
                        if ($adapter) {
                            $ipConfig = Get-NetIPAddress -InterfaceIndex $adapter.InterfaceIndex -AddressFamily IPv4 | Where-Object { $_.IPAddress -notmatch '^169\.254\.' } | Select-Object -First 1
                            if ($ipConfig) { $myIp = $ipConfig.IPAddress }
                        }
                    }
                    catch {}
                    
                    # Silent scan - no popup dialog, status is shown in the UI label instead
                    Log "No X-Air mixers found on network. Your PC IP: $myIp"
                }
            }
            catch {
                # Restore button on error
                $btnXRScan.Text = "Scan"
                $btnXRScan.BackColor = [System.Drawing.SystemColors]::Control
                $lblXRStatus.Text = "✗ Scan error"
                $lblXRStatus.ForeColor = [System.Drawing.Color]::Red
                Log "Scan error: $_"
            }
        })

    # Port label
    $lblPort = New-Object System.Windows.Forms.Label
    $lblPort.Text = "OSC Port:"
    $lblPort.AutoSize = $true
    $lblPort.Location = Pt 330 28
    $grpXR.Controls.Add($lblPort)

    # FIXED port control (always 10024)
    $numPort = New-Object System.Windows.Forms.NumericUpDown
    $numPort.Minimum = 10024
    $numPort.Maximum = 10024
    $numPort.Value = 10024
    $numPort.Enabled = $false
    $numPort.Size = Sz 80 24
    $numPort.Location = Pt 410 24
    $grpXR.Controls.Add($numPort)

    # Snapshot label
    $lblSnap = New-Object System.Windows.Forms.Label
    $lblSnap.Text = "Snapshot #:"
    $lblSnap.AutoSize = $true
    $lblSnap.Location = Pt 10 83
    $grpXR.Controls.Add($lblSnap)

    # Snapshot number
    $numSnap = New-Object System.Windows.Forms.NumericUpDown
    $numSnap.Minimum = 1
    $numSnap.Maximum = 10
    $numSnap.Value = [int]$script:Cfg.XR.SnapshotNumber
    $numSnap.Size = Sz 52 24
    $numSnap.Location = Pt ([int]($lblSnap.Right + 8)) 79
    $grpXR.Controls.Add($numSnap)

    # Test button (same row as snapshot number)
    $btnXRTest = New-Object System.Windows.Forms.Button
    $btnXRTest.Text = "Test"
    $btnXRTest.Size = Sz 70 24
    $btnXRTest.Location = Pt ([int]($numSnap.Right + 8)) 79
    $grpXR.Controls.Add($btnXRTest)
    $btnXRTest.Add_Click({
            # Use whatever IP is currently in the textbox (works even before saving settings)
            $tipText = $tbIp.Text.Trim()
            if (-not [string]::IsNullOrWhiteSpace($tipText)) { $script:Cfg.XR.MixerIP = $tipText }
            XR-LoadSnapshot ([int]$numSnap.Value)
        })

    # ---------- Audio Ducking Section ----------
    [System.Windows.Forms.Application]::DoEvents()  # keep preview alive during dialog build
    # Enable ducking checkbox
    $chkDuckingEnabled = New-Object System.Windows.Forms.CheckBox
    $chkDuckingEnabled.Text = "Enable Auto-Ducking"
    $chkDuckingEnabled.AutoSize = $true
    $chkDuckingEnabled.Location = Pt 10 135
    $chkDuckingEnabled.Checked = $script:Cfg.XR.DuckingEnabled
    $grpXR.Controls.Add($chkDuckingEnabled)

    # Dynamic row layout to avoid overlap at different DPI/font sizes
    $duckRowY = 137
    $duckX1 = [int]($chkDuckingEnabled.Left + $chkDuckingEnabled.PreferredSize.Width + 22)

    # Info button for Auto-Ducking
    $btnDuckingInfo = New-Object System.Windows.Forms.Button
    $btnDuckingInfo.Text = "i"
    $btnDuckingInfo.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $btnDuckingInfo.Size = Sz 26 22
    $btnDuckingInfo.BackColor = [System.Drawing.Color]::FromArgb(70, 130, 220)
    $btnDuckingInfo.ForeColor = [System.Drawing.Color]::White
    $btnDuckingInfo.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $btnDuckingInfo.FlatAppearance.BorderSize = 0
    $btnDuckingInfo.Add_Click({
            $msg = @"
AUTO-DUCKING — Setup Guide

Auto-Ducking automatically lowers the XR mixer Podium channel
when audio is detected on the Monitor channel via OSC meters,
then restores it afterwards.
This prevents microphone feedback when playing videos or music.

──────────────────────────────────────────────
HOW IT WORKS
  • The app reads the XR mixer input level of the Monitor Channel
    you select, directly via OSC meter packets (every 50 ms).
  • When the level exceeds the Audio Sensitivity threshold, it sends
    an OSC command to lower the XR Podium channel by the Duck Amount.
  • Once the level drops below the threshold (+ Hold Time), the Podium
    channel is restored to its original level.
  • No OBS scene requirement — ducking triggers purely on XR input level.

──────────────────────────────────────────────
STEP 1 — SELECT THE MONITOR CHANNEL
  Set 'Monitor Ch' to the XR mixer channel number that carries your
  media/JW Library audio (e.g. CH 8 for a stereo media feed).
  This is the channel whose input level will trigger ducking.

STEP 2 — CONFIGURE DUCKING SETTINGS HERE
  Monitor Ch        — XR channel (1-9) to watch for audio activity.
  Podium Line       — XR channel number of your podium microphone.
  Duck Amount (dB)  — how many dB to lower the Podium channel
                      when media audio is detected (e.g. -15 dB).
  Audio Sensitivity — the dB threshold above which audio is considered
                      active (e.g. -45 dB). Typical range: -30 to -60.
  Hold Time (ms)    — how long to keep ducking after audio stops
                      (e.g. 2000 ms = 2 seconds).

STEP 3 — ENABLE AND TEST
  1. Tick 'Enable Auto-Ducking' above.
  2. Play audio through your media channel on the XR mixer.
  3. Watch the XR Audio status bar — it should show ACTIVE.
  4. Confirm the Podium channel dips during playback and recovers.
"@
            Show-InfoPopup -Title "Auto-Ducking — Setup Guide" -Key "AutoDucking" -DefaultText $msg
        })
    $grpXR.Controls.Add($btnDuckingInfo)
    
    # Store reference in script scope and add event handler to save setting immediately when changed
    $script:chkDuckingEnabled = $chkDuckingEnabled
    $chkDuckingEnabled.Add_CheckedChanged({
            try {
                $script:Cfg.XR.DuckingEnabled = $script:chkDuckingEnabled.Checked
                Log "Auto-Ducking CheckedChanged: Setting DuckingEnabled to $($script:chkDuckingEnabled.Checked)"
                Save-Settings | Out-Null
                Log "Auto-Ducking CheckedChanged: Settings saved successfully"
            }
            catch {
                Log "Auto-Ducking CheckedChanged error: $_"
            }
        })
    
    # Podium Channel label and selector
    $lblPodiumCh = New-Object System.Windows.Forms.Label
    $lblPodiumCh.Text = "Podium Line:"
    $lblPodiumCh.AutoSize = $true
    $lblPodiumCh.Location = Pt $duckX1 $duckRowY
    $grpXR.Controls.Add($lblPodiumCh)
    
    $numPodiumCh = New-Object System.Windows.Forms.NumericUpDown
    $numPodiumCh.Minimum = 1
    $numPodiumCh.Maximum = 10
    $numPodiumCh.Value = [int]$script:Cfg.XR.PodiumChannel
    $numPodiumCh.Size = Sz 50 24
    $numPodiumCh.Location = Pt ([int]($lblPodiumCh.Right + 6)) 133
    $grpXR.Controls.Add($numPodiumCh)

    # Monitor Channel selector — which XR input channel to watch for ducking trigger
    $lblMonitorCh = New-Object System.Windows.Forms.Label
    $lblMonitorCh.Text = "Monitor Ch:"
    $lblMonitorCh.AutoSize = $true
    $lblMonitorCh.Location = Pt ([int]($numPodiumCh.Right + 18)) $duckRowY
    $grpXR.Controls.Add($lblMonitorCh)

    $numMediaCh = New-Object System.Windows.Forms.NumericUpDown
    $numMediaCh.Minimum = 1
    $numMediaCh.Maximum = 30
    $numMediaCh.Value = [int]$script:Cfg.XR.MediaChannel
    $numMediaCh.Size = Sz 50 24
    $numMediaCh.Location = Pt ([int]($lblMonitorCh.Right + 6)) 133
    $grpXR.Controls.Add($numMediaCh)

    # Keep the info button at the end of the row (after monitor selector)
    $btnDuckingInfo.Location = Pt ([int]($numMediaCh.Right + 12)) 133

    # Second row - Duck Amount, Threshold, Hold Time
    # Duck Amount label and selector
    $lblDuckAmount = New-Object System.Windows.Forms.Label
    $lblDuckAmount.Text = "Duck Amount (dB):"
    $lblDuckAmount.AutoSize = $true
    $lblDuckAmount.Location = Pt 10 168
    $grpXR.Controls.Add($lblDuckAmount)
    
    $numDuckAmount = New-Object System.Windows.Forms.NumericUpDown
    $numDuckAmount.Minimum = -80
    $numDuckAmount.Maximum = 0
    $numDuckAmount.Value = [int]$script:Cfg.XR.DuckAmountDB
    $numDuckAmount.Size = Sz 60 24
    $numDuckAmount.Location = Pt ([int]($lblDuckAmount.Right + 8)) 164
    $grpXR.Controls.Add($numDuckAmount)
    
    # Hold Time label and selector (moved to where Threshold dB was)
    $lblHoldTime = New-Object System.Windows.Forms.Label
    $lblHoldTime.Text = "Hold Time (ms):"
    $lblHoldTime.AutoSize = $true
    $lblHoldTime.Location = Pt ([int]($numDuckAmount.Right + 16)) 168
    $grpXR.Controls.Add($lblHoldTime)
    
    $numHoldTime = New-Object System.Windows.Forms.NumericUpDown
    $numHoldTime.Minimum = 100
    $numHoldTime.Maximum = 5000
    $numHoldTime.Increment = 100
    $numHoldTime.Value = [int]$script:Cfg.XR.HoldTimeMS
    $numHoldTime.Size = Sz 84 24
    $numHoldTime.Location = Pt ([int]($lblHoldTime.Right + 6)) 164
    $grpXR.Controls.Add($numHoldTime)
    
    # Third row - Audio Threshold (OBS linear value)
    $lblAudioThreshold = New-Object System.Windows.Forms.Label
    $lblAudioThreshold.Text = "Audio Sensitivity (dB):"
    $lblAudioThreshold.AutoSize = $true
    $lblAudioThreshold.Location = Pt 10 194
    $grpXR.Controls.Add($lblAudioThreshold)
    
    $numAudioThreshold = New-Object System.Windows.Forms.NumericUpDown
    $numAudioThreshold.Minimum = -90
    $numAudioThreshold.Maximum = 0
    $numAudioThreshold.DecimalPlaces = 0
    $numAudioThreshold.Increment = 1
    # XR meter levels are already in dB — use ThresholdDB directly
    $displayDB = if ($script:Cfg.XR.ThresholdDB) { [double]$script:Cfg.XR.ThresholdDB } else { -45.0 }
    if ($displayDB -gt 0) { $displayDB = 0 }
    if ($displayDB -lt -90) { $displayDB = -90 }
    $numAudioThreshold.Value = [decimal][Math]::Round($displayDB, 0)
    $numAudioThreshold.Size = Sz 80 24
    $numAudioThreshold.Location = Pt 170 194
    $grpXR.Controls.Add($numAudioThreshold)
    
    # Threshold explanation label
    $lblThresholdHelp = New-Object System.Windows.Forms.Label
    $lblThresholdHelp.Text = "Audio threshold: when XR Monitor Ch exceeds this level, ducking triggers"
    $lblThresholdHelp.AutoSize = $true
    $lblThresholdHelp.Location = Pt 260 198
    $lblThresholdHelp.ForeColor = [System.Drawing.Color]::DarkGreen
    $lblThresholdHelp.Font = New-Object System.Drawing.Font("Segoe UI", 8, [System.Drawing.FontStyle]::Italic)
    $grpXR.Controls.Add($lblThresholdHelp)
    
    # Info label for OBS audio source requirement (moved down)
    $lblAudioSource = New-Object System.Windows.Forms.Label
    $lblAudioSource.Text = "Ducking monitors XR mixer Monitor Ch via OSC meters and ducks the Podium channel when input exceeds threshold"
    $lblAudioSource.AutoSize = $true
    $lblAudioSource.Location = Pt 10 225
    $lblAudioSource.ForeColor = [System.Drawing.Color]::DarkBlue
    $lblAudioSource.Font = New-Object System.Drawing.Font("Segoe UI", 8, [System.Drawing.FontStyle]::Italic)
    $grpXR.Controls.Add($lblAudioSource)
    
    # Audio level meter removed - replaced with OBS Audio status box
    $script:pbAudioMeter = $null  # Keep variable to prevent errors
    
    # Ducking status UI removed - logic preserved
    $script:lblDuckingStatus = $null  # Keep variable to prevent errors
    
    # OBS audio monitoring status - placed prominently in the monitor area
    $script:lblAudioStatus = New-Object System.Windows.Forms.Label
    $script:lblAudioStatus.Text = "XR Audio: Silent"
    $script:lblAudioStatus.AutoSize = $false
    $script:lblAudioStatus.Size = Sz 560 22
    $script:lblAudioStatus.Location = Pt 15 250  # Moved up to replace the progress bar
    $script:lblAudioStatus.ForeColor = [System.Drawing.Color]::DarkGreen
    $script:lblAudioStatus.BackColor = [System.Drawing.Color]::FromArgb(245, 245, 245)  # Light gray background
    $script:lblAudioStatus.Font = New-Object System.Drawing.Font("Consolas", 9, [System.Drawing.FontStyle]::Bold)
    $script:lblAudioStatus.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $script:lblAudioStatus.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $grpXR.Controls.Add($script:lblAudioStatus)

    # ---- Rover (Reader) Auto-Ducking Section ----
    $chkRoverDucking = New-Object System.Windows.Forms.CheckBox
    $chkRoverDucking.Text = "Enable Auto Rover Ducking"
    $chkRoverDucking.AutoSize = $true
    $chkRoverDucking.Location = Pt 10 282
    $chkRoverDucking.Checked = $script:Cfg.XR.RoverDuckingEnabled
    $grpXR.Controls.Add($chkRoverDucking)

    # Dynamic Rover row layout to avoid DPI/font overlap
    $roverRowY = 285
    $roverX1 = [int]($chkRoverDucking.Left + $chkRoverDucking.PreferredSize.Width + 16)

    $lblRoverLines = New-Object System.Windows.Forms.Label
    $lblRoverLines.Text = "Rover Lines:"
    $lblRoverLines.AutoSize = $true
    $lblRoverLines.Location = Pt $roverX1 $roverRowY
    $grpXR.Controls.Add($lblRoverLines)

    $numRoverCh1 = New-Object System.Windows.Forms.NumericUpDown
    $numRoverCh1.Minimum = 1
    $numRoverCh1.Maximum = 10
    $numRoverCh1.Value = [int]$script:Cfg.XR.RoverChannel1
    $numRoverCh1.Size = Sz 44 24
    $numRoverCh1.Location = Pt ([int]($lblRoverLines.Right + 6)) 281
    $grpXR.Controls.Add($numRoverCh1)

    $numRoverCh2 = New-Object System.Windows.Forms.NumericUpDown
    $numRoverCh2.Minimum = 1
    $numRoverCh2.Maximum = 10
    $numRoverCh2.Value = [int]$script:Cfg.XR.RoverChannel2
    $numRoverCh2.Size = Sz 44 24
    $numRoverCh2.Location = Pt ([int]($numRoverCh1.Right + 8)) 281
    $grpXR.Controls.Add($numRoverCh2)

    # Rover Monitor Channel — which XR input to watch for triggering rover ducking
    $lblRoverMonitorCh = New-Object System.Windows.Forms.Label
    $lblRoverMonitorCh.Text = "Monitor Ch:"
    $lblRoverMonitorCh.AutoSize = $true
    $lblRoverMonitorCh.Location = Pt ([int]($numRoverCh2.Right + 12)) $roverRowY
    $grpXR.Controls.Add($lblRoverMonitorCh)

    $numRoverMonitorCh = New-Object System.Windows.Forms.NumericUpDown
    $numRoverMonitorCh.Minimum = 1
    $numRoverMonitorCh.Maximum = 9
    $numRoverMonitorCh.Value = [int]$script:Cfg.XR.RoverMonitorChannel
    $numRoverMonitorCh.Size = Sz 44 24
    $numRoverMonitorCh.Location = Pt ([int]($lblRoverMonitorCh.Right + 6)) 281
    $grpXR.Controls.Add($numRoverMonitorCh)

    $lblRoverMonitorCh2 = New-Object System.Windows.Forms.Label
    $lblRoverMonitorCh2.Text = "Ch2:"
    $lblRoverMonitorCh2.AutoSize = $true
    $lblRoverMonitorCh2.Location = Pt ([int]($numRoverMonitorCh.Right + 10)) $roverRowY
    $grpXR.Controls.Add($lblRoverMonitorCh2)

    $numRoverMonitorCh2 = New-Object System.Windows.Forms.NumericUpDown
    $numRoverMonitorCh2.Minimum = 1
    $numRoverMonitorCh2.Maximum = 9
    $numRoverMonitorCh2.Value = [int]$script:Cfg.XR.RoverMonitorChannel2
    $numRoverMonitorCh2.Size = Sz 44 24
    $numRoverMonitorCh2.Location = Pt ([int]($lblRoverMonitorCh2.Right + 6)) 281
    $grpXR.Controls.Add($numRoverMonitorCh2)

    # Rover second row — Duck Amount, Hold Time, Audio Sensitivity
    $lblRoverDuckAmount = New-Object System.Windows.Forms.Label
    $lblRoverDuckAmount.Text = "Duck Amount (dB):"
    $lblRoverDuckAmount.AutoSize = $true
    $lblRoverDuckAmount.Location = Pt 10 316
    $grpXR.Controls.Add($lblRoverDuckAmount)

    $numRoverDuckAmount = New-Object System.Windows.Forms.NumericUpDown
    $numRoverDuckAmount.Minimum = -80
    $numRoverDuckAmount.Maximum = 0
    $numRoverDuckAmount.Value = [int]$script:Cfg.XR.RoverDuckAmountDB
    $numRoverDuckAmount.Size = Sz 60 24
    $numRoverDuckAmount.Location = Pt ([int]($lblRoverDuckAmount.Right + 8)) 312
    $grpXR.Controls.Add($numRoverDuckAmount)

    $lblRoverHoldTime = New-Object System.Windows.Forms.Label
    $lblRoverHoldTime.Text = "Hold Time (ms):"
    $lblRoverHoldTime.AutoSize = $true
    $lblRoverHoldTime.Location = Pt ([int]($numRoverDuckAmount.Right + 16)) 316
    $grpXR.Controls.Add($lblRoverHoldTime)

    $numRoverHoldTime = New-Object System.Windows.Forms.NumericUpDown
    $numRoverHoldTime.Minimum = 100
    $numRoverHoldTime.Maximum = 5000
    $numRoverHoldTime.Increment = 100
    $numRoverHoldTime.Value = [int]$script:Cfg.XR.RoverHoldTimeMS
    $numRoverHoldTime.Size = Sz 84 24
    $numRoverHoldTime.Location = Pt ([int]($lblRoverHoldTime.Right + 6)) 312
    $grpXR.Controls.Add($numRoverHoldTime)

    $lblRoverSensitivity = New-Object System.Windows.Forms.Label
    $lblRoverSensitivity.Text = "Sensitivity (dB):"
    $lblRoverSensitivity.AutoSize = $true
    $lblRoverSensitivity.Location = Pt ([int]($numRoverHoldTime.Right + 16)) 316
    $grpXR.Controls.Add($lblRoverSensitivity)

    $numRoverThreshold = New-Object System.Windows.Forms.NumericUpDown
    $numRoverThreshold.Minimum = -90
    $numRoverThreshold.Maximum = 0
    $numRoverThreshold.DecimalPlaces = 0
    $numRoverThreshold.Increment = 1
    # XR meter levels are already in dB — use RoverThresholdDB directly
    $roverDisplayDB = if ($script:Cfg.XR.RoverThresholdDB) { [double]$script:Cfg.XR.RoverThresholdDB } else { -45.0 }
    if ($roverDisplayDB -gt 0) { $roverDisplayDB = 0 }
    if ($roverDisplayDB -lt -90) { $roverDisplayDB = -90 }
    $numRoverThreshold.Value = [decimal][Math]::Round($roverDisplayDB, 0)
    $numRoverThreshold.Size = Sz 60 24
    $numRoverThreshold.Location = Pt ([int]($lblRoverSensitivity.Right + 6)) 312
    $grpXR.Controls.Add($numRoverThreshold)

    # Rover active snapshot row
    $lblRoverScene = New-Object System.Windows.Forms.Label
    $lblRoverScene.Text = "Active on Snapshot:"
    $lblRoverScene.AutoSize = $true
    $lblRoverScene.Location = Pt 10 349
    $grpXR.Controls.Add($lblRoverScene)

    $cmbRoverSnap = New-Object System.Windows.Forms.ComboBox
    $cmbRoverSnap.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    [void]$cmbRoverSnap.Items.Add("Any (always active)")
    1..10 | ForEach-Object { [void]$cmbRoverSnap.Items.Add("Snapshot $_") }
    $roverSnapVal = [int]$script:Cfg.XR.RoverActiveSnapshot
    if ($roverSnapVal -ge 1 -and $roverSnapVal -le 10) { $cmbRoverSnap.SelectedIndex = $roverSnapVal } else { $cmbRoverSnap.SelectedIndex = 0 }
    $cmbRoverSnap.Size = Sz 170 24
    $cmbRoverSnap.Location = Pt ([int]($lblRoverScene.Right + 8)) 346
    $grpXR.Controls.Add($cmbRoverSnap)
    # Info button for Rover Ducking — placed right of the Active on Snapshot combo
    $btnRoverDuckingInfo = New-Object System.Windows.Forms.Button
    $btnRoverDuckingInfo.Text = "i"
    $btnRoverDuckingInfo.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $btnRoverDuckingInfo.Size = Sz 26 22
    $btnRoverDuckingInfo.Location = Pt ([int]($cmbRoverSnap.Right + 8)) 347
    $btnRoverDuckingInfo.BackColor = [System.Drawing.Color]::FromArgb(70, 130, 220)
    $btnRoverDuckingInfo.ForeColor = [System.Drawing.Color]::White
    $btnRoverDuckingInfo.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $btnRoverDuckingInfo.FlatAppearance.BorderSize = 0
    $btnRoverDuckingInfo.Add_Click({
            $msg = @"
AUTO ROVER DUCKING — Setup Guide

Rover Ducking automatically lowers two XR mixer channels when the
Monitor Channel input on the XR mixer exceeds the threshold, then
restores them. Use this to duck background channels when a Rover
microphone is active.

──────────────────────────────────────────────
HOW IT WORKS
  • The app reads the XR mixer input level of the Monitor Channel
    you select, directly via OSC meter packets (every 50 ms).
  • When the level exceeds the Sensitivity threshold, it sends
    OSC commands to lower BOTH Rover Line channels you select.
  • Once the level drops below the threshold (+ Hold Time), both
    channels are restored to their original levels.
  • Ducking is ONLY active when the XR snapshot selected in
    'Active on Snapshot' is loaded. Select 'Any' to always trigger.
  • If the snapshot changes away while ducking is active, channels are
    restored immediately (no hold-time delay).
  • Trigger is purely XR mixer based — no OBS connection required.

──────────────────────────────────────────────
STEP 1 — SELECT THE MONITOR CHANNEL
  Set 'Monitor Ch' to the XR mixer channel number where your
  Rover/Reader microphone is plugged in.
  The app reads that channel's input level via OSC meter packets.

STEP 2 — CONFIGURE ROVER SETTINGS HERE
  Rover Lines (1st / 2nd) — the two XR mixer channels to duck
                             when Rover audio is detected.
  Monitor Ch           — XR channel (1-9) whose input level to watch.
  Duck Amount (dB)     — how many dB to lower the Rover channels
                         when audio is detected (e.g. -15 dB).
  Hold Time (ms)       — how long to keep channels ducked after audio
                         drops below the threshold (e.g. 2000 ms).
  Sensitivity (dB)     — dB level above which ducking triggers
                         (e.g. -45 dB).
  Active on Snapshot   — the XR snapshot number that enables ducking.
                         Select 'Any (always active)' to trigger on
                         every snapshot, or pick a specific snapshot
                         (e.g. Snapshot 4 for your Rover scene).

STEP 3 — ENABLE AND TEST
  1. Tick 'Enable Auto Rover Ducking' above.
  2. Load the configured XR snapshot on the mixer.
  3. Speak into the Rover microphone — both selected XR channels
     should dip and then recover after the Hold Time expires.
"@
            Show-InfoPopup -Title "Auto Rover Ducking — Setup Guide" -Key "RoverDucking" -DefaultText $msg
        })
    $grpXR.Controls.Add($btnRoverDuckingInfo)

    # Auto-save when checkbox toggled
    $script:chkRoverDucking = $chkRoverDucking
    $chkRoverDucking.Add_CheckedChanged({
            try {
                $script:Cfg.XR.RoverDuckingEnabled = $script:chkRoverDucking.Checked
                Save-Settings | Out-Null
            }
            catch {
                Log "Rover Ducking CheckedChanged error: $_"
            }
        })

    # ---- Mixer Panel ----
    $lblMixerSep = New-Object System.Windows.Forms.Label
    $lblMixerSep.Text = ""
    $lblMixerSep.AutoSize = $false
    $lblMixerSep.Size = Sz 640 1
    $lblMixerSep.Location = Pt 10 382
    $lblMixerSep.BackColor = [System.Drawing.Color]::FromArgb(160, 160, 160)
    $grpXR.Controls.Add($lblMixerSep)

    $chkMixerPanel = New-Object System.Windows.Forms.CheckBox
    $chkMixerPanel.Text = "Open Mixer Panel  (live faders + meters for 9 channels)"
    $chkMixerPanel.AutoSize = $true
    $chkMixerPanel.Location = Pt 10 390
    $chkMixerPanel.Checked = [bool]$script:Cfg.XR.MixerPanelEnabled
    $grpXR.Controls.Add($chkMixerPanel)
    $script:chkMixerPanel = $chkMixerPanel  # expose to script scope so CheckedChanged closure can reach it

    # XR status label — shown inline after the checkbox
    $lblXrStatus = New-Object System.Windows.Forms.Label
    $lblXrStatus.AutoSize = $false
    $lblXrStatus.Size = Sz 180 20
    $lblXrStatus.Location = Pt ([int]($chkMixerPanel.Left + $chkMixerPanel.PreferredSize.Width + 16)) 393
    $lblXrStatus.Text = "XR: checking…"
    $lblXrStatus.ForeColor = [System.Drawing.Color]::Gray
    $lblXrStatus.Font = New-Object System.Drawing.Font("Segoe UI", 8.5, [System.Drawing.FontStyle]::Bold)
    $lblXrStatus.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $grpXR.Controls.Add($lblXrStatus)

    # Async ping so dialog opens instantly
    $xrIpForProbe = [string]$script:Cfg.XR.MixerIP
    $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'; $rs.ThreadOptions = 'ReuseThread'; $rs.Open()
    $ps = [System.Management.Automation.PowerShell]::Create(); $ps.Runspace = $rs
    # Inject Test-MixerPing definition into the runspace so it can run standalone
    [void]$ps.AddScript({
            function Test-MixerPing {
                param([string]$Ip)
                if ([string]::IsNullOrWhiteSpace($Ip)) { return $false }
                $invalidIPs = @("127.0.0.1", "localhost", "192.168.1.1", "192.168.0.1", "192.168.4.1", "10.0.0.1")
                if ($invalidIPs -contains $Ip) { return $false }
                try {
                    $udp = New-Object System.Net.Sockets.UdpClient
                    try {
                        $udp.Connect($Ip, 10024)
                        $msg = @(47, 105, 110, 102, 111, 0, 0, 0)
                        [void]$udp.Send($msg, $msg.Length)
                        $udp.Client.ReceiveTimeout = 600
                        $ep = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
                        try { $r = $udp.Receive([ref]$ep); return ($r -and $r.Length -gt 0) } catch { return $false }
                    }
                    finally { try { $udp.Close() } catch {} }
                }
                catch { return $false }
            }
        })
    [void]$ps.AddScript({ param($ip) Test-MixerPing -Ip $ip }).AddArgument($xrIpForProbe)
    $async = $ps.BeginInvoke()

    # Poll timer — fires on UI thread every 200ms until result is ready
    $xrPingTimer = New-Object System.Windows.Forms.Timer
    $xrPingTimer.Interval = 200
    $xrPingTimer.Add_Tick({
            if (-not $async.IsCompleted) { return }
            $xrPingTimer.Stop(); $xrPingTimer.Dispose()
            try {
                $result = $ps.EndInvoke($async)
                $online = ($result -and $result.Count -gt 0 -and [bool]$result[0])
                if ([string]::IsNullOrWhiteSpace($xrIpForProbe)) {
                    $lblXrStatus.Text = "XR: No IP set"
                    $lblXrStatus.ForeColor = [System.Drawing.Color]::Gray
                }
                elseif ($online) {
                    $lblXrStatus.Text = "XR: Online ✓"
                    $lblXrStatus.ForeColor = [System.Drawing.Color]::FromArgb(0, 200, 80)
                }
                else {
                    $lblXrStatus.Text = "XR: Offline ✗"
                    $lblXrStatus.ForeColor = [System.Drawing.Color]::FromArgb(220, 60, 60)
                }
            }
            catch { $lblXrStatus.Text = "XR: Unknown"; $lblXrStatus.ForeColor = [System.Drawing.Color]::Gray }
            try { $ps.Dispose() } catch {}
            try { $rs.Close(); $rs.Dispose() } catch {}
        })
    $xrPingTimer.Start()

    $chkXrDebugLog = New-Object System.Windows.Forms.CheckBox
    $chkXrDebugLog.Text = "Enable XR debug logging  (shows OSC/meter noise in log)"
    $chkXrDebugLog.AutoSize = $true
    $chkXrDebugLog.Location = Pt 10 415
    $chkXrDebugLog.Checked = [bool]$script:Cfg.XR.XrDebugLog
    $grpXR.Controls.Add($chkXrDebugLog)
    $script:chkXrDebugLog = $chkXrDebugLog
    $chkXrDebugLog.Add_CheckedChanged({
            try {
                $script:Cfg.XR.XrDebugLog = $script:chkXrDebugLog.Checked
                Save-Settings | Out-Null
            }
            catch { Log "XR debug log toggle error: $_" }
        })

    # ---- Auto Mode separator + controls ----
    $chkAutoMode = New-Object System.Windows.Forms.CheckBox
    $chkAutoMode.Text = "Enable Auto Mode  (Snapshot 8 — auto-activates channels 2-9 on input)"
    $chkAutoMode.AutoSize = $true
    $chkAutoMode.Location = Pt 10 449
    $chkAutoMode.Checked = [bool]$script:Cfg.XR.AutoModeEnabled
    $grpXR.Controls.Add($chkAutoMode)
    $script:chkAutoMode = $chkAutoMode
    $chkAutoMode.Add_CheckedChanged({
            try {
                $script:Cfg.XR.AutoModeEnabled = $script:chkAutoMode.Checked
                Save-Settings | Out-Null
                if (-not $script:chkAutoMode.Checked) { Stop-AutoMode }
            }
            catch { Log "Auto Mode checkbox error: $_" }
        })

    $lblAutoModeHold = New-Object System.Windows.Forms.Label
    $lblAutoModeHold.Text = "Hold Time (ms):"
    $lblAutoModeHold.AutoSize = $true
    $lblAutoModeHold.Location = Pt 10 478
    $grpXR.Controls.Add($lblAutoModeHold)

    $numAutoModeHold = New-Object System.Windows.Forms.NumericUpDown
    $numAutoModeHold.Minimum = 100
    $numAutoModeHold.Maximum = 10000
    $numAutoModeHold.Increment = 100
    $numAutoModeHold.Value = [Math]::Max(100, [Math]::Min(10000, [int]$script:Cfg.XR.AutoModeHoldTimeMS))
    $numAutoModeHold.Size = Sz 90 24
    $numAutoModeHold.Location = Pt ([int]($lblAutoModeHold.Right + 8)) 475
    $grpXR.Controls.Add($numAutoModeHold)
    $script:numAutoModeHold = $numAutoModeHold

    $lblAutoModeHoldUnit = New-Object System.Windows.Forms.Label
    $lblAutoModeHoldUnit.Text = "ms  (time to hold fader up after input drops below -35 dB)"
    $lblAutoModeHoldUnit.AutoSize = $true
    $lblAutoModeHoldUnit.Location = Pt ([int]($numAutoModeHold.Right + 8)) 478
    $grpXR.Controls.Add($lblAutoModeHoldUnit)

    # ---- Limiter separator + controls ----
    $lblLimiterSep = New-Object System.Windows.Forms.Label
    $lblLimiterSep.Text = ""
    $lblLimiterSep.AutoSize = $false
    $lblLimiterSep.Size = Sz 640 1
    $lblLimiterSep.Location = Pt 10 500
    $lblLimiterSep.BackColor = [System.Drawing.Color]::FromArgb(160, 160, 160)
    $grpXR.Controls.Add($lblLimiterSep)

    $chkLimiter = New-Object System.Windows.Forms.CheckBox
    $chkLimiter.Text = "Apply Limiter  (if fader at 0 dB and input exceeds threshold → reduce fader by -3 dB)"
    $chkLimiter.AutoSize = $true
    $chkLimiter.Location = Pt 10 509
    $chkLimiter.Checked = [bool]$script:Cfg.XR.LimiterEnabled
    $grpXR.Controls.Add($chkLimiter)
    $script:chkLimiter = $chkLimiter
    $chkLimiter.Add_CheckedChanged({
            try {
                $script:Cfg.XR.LimiterEnabled = $script:chkLimiter.Checked
                Save-Settings | Out-Null
            }
            catch { Log "Limiter checkbox error: $_" }
        })

    $lblLimiterThresh = New-Object System.Windows.Forms.Label
    $lblLimiterThresh.Text = "Threshold:"
    $lblLimiterThresh.AutoSize = $true
    $lblLimiterThresh.Location = Pt 10 545
    $grpXR.Controls.Add($lblLimiterThresh)

    $numLimiterThresh = New-Object System.Windows.Forms.NumericUpDown
    $numLimiterThresh.Minimum = -30
    $numLimiterThresh.Maximum = 0
    $numLimiterThresh.Increment = 1
    $numLimiterThresh.Value = [Math]::Max(-30, [Math]::Min(0, [int]$script:Cfg.XR.LimiterThresholdDB))
    $numLimiterThresh.Size = Sz 72 24
    $numLimiterThresh.Location = Pt ([int]($lblLimiterThresh.Right + 8)) 542
    $grpXR.Controls.Add($numLimiterThresh)
    $script:numLimiterThresh = $numLimiterThresh

    $lblLimiterThreshUnit = New-Object System.Windows.Forms.Label
    $lblLimiterThreshUnit.Text = "dB  — pre-fader level above which limiter fires (fader between -0.5 and +10 dB)"
    $lblLimiterThreshUnit.AutoSize = $true
    $lblLimiterThreshUnit.Location = Pt ([int]($numLimiterThresh.Right + 8)) 545
    $grpXR.Controls.Add($lblLimiterThreshUnit)

    $lblSnapBack = New-Object System.Windows.Forms.Label
    $lblSnapBack.Text = "Snap back after:"
    $lblSnapBack.AutoSize = $true
    $lblSnapBack.Location = Pt 10 575
    $grpXR.Controls.Add($lblSnapBack)

    $numLimiterSnapBack = New-Object System.Windows.Forms.NumericUpDown
    $numLimiterSnapBack.Minimum = 1
    $numLimiterSnapBack.Maximum = 60
    $numLimiterSnapBack.Increment = 1
    $numLimiterSnapBack.Value = [Math]::Max(1, [Math]::Min(60, [int]$script:Cfg.XR.LimiterSnapBackSec))
    $numLimiterSnapBack.Size = Sz 56 24
    $numLimiterSnapBack.Location = Pt ([int]($lblSnapBack.Right + 8)) 572
    $grpXR.Controls.Add($numLimiterSnapBack)
    $script:numLimiterSnapBack = $numLimiterSnapBack

    $lblSnapBackUnit = New-Object System.Windows.Forms.Label
    $lblSnapBackUnit.Text = "sec  (seconds level must stay below threshold before fader snaps back)"
    $lblSnapBackUnit.AutoSize = $true
    $lblSnapBackUnit.Location = Pt ([int]($numLimiterSnapBack.Right + 8)) 575
    $grpXR.Controls.Add($lblSnapBackUnit)

    $chkShowLevels = New-Object System.Windows.Forms.CheckBox
    $chkShowLevels.Text = "Show Fader dB Inputs  (display live input dB below each channel name)"
    $chkShowLevels.AutoSize = $true
    $chkShowLevels.Location = Pt 10 606
    $chkShowLevels.Checked = [bool]$script:Cfg.XR.ShowLevelLabels
    $grpXR.Controls.Add($chkShowLevels)
    $script:chkShowLevels = $chkShowLevels
    $chkShowLevels.Add_CheckedChanged({
            $script:Cfg.XR.ShowLevelLabels = $script:chkShowLevels.Checked
            Save-Settings | Out-Null
            # Apply immediately to open mixer panel
            if ($script:_mixerLevelLabels) {
                foreach ($ll in $script:_mixerLevelLabels) {
                    if ($ll -and -not $ll.IsDisposed) { $ll.Visible = $script:Cfg.XR.ShowLevelLabels }
                }
            }
        })

    # Routing hint boxed section at the very bottom for clarity
    $grpRouteHint = New-Object System.Windows.Forms.GroupBox
    $grpRouteHint.Text = "Routing Tip for Media and Zoom channel."
    $grpRouteHint.Size = Sz 770 92
    $grpRouteHint.Location = Pt 10 632
    $grpXR.Controls.Add($grpRouteHint)

    $lblRouteHint = New-Object System.Windows.Forms.Label
    $lblRouteHint.Text = "If Analog inputs, use Ch 8/9. If USB returns, select the appropriate XR channel in the dropdowns below."
    $lblRouteHint.AutoSize = $false
    $lblRouteHint.Size = Sz 750 22
    $lblRouteHint.Location = Pt 8 22
    $lblRouteHint.ForeColor = [System.Drawing.Color]::DarkSlateGray
    $grpRouteHint.Controls.Add($lblRouteHint)

    $lblRouteMedia = New-Object System.Windows.Forms.Label
    $lblRouteMedia.Text = "Media Ch:"
    $lblRouteMedia.AutoSize = $true
    $routeRowY = 50
    $lblRouteMedia.Location = Pt 8 $routeRowY
    $grpRouteHint.Controls.Add($lblRouteMedia)

    $cmbRouteMedia = New-Object System.Windows.Forms.ComboBox
    $cmbRouteMedia.DropDownStyle = 'DropDownList'
    for ($i = 8; $i -le 30; $i++) { [void]$cmbRouteMedia.Items.Add($i) }
    $mediaSel = [int]$script:Cfg.XR.MediaChannel
    if ($mediaSel -lt 8 -or $mediaSel -gt 30) { $mediaSel = 8 }
    $cmbRouteMedia.SelectedItem = $mediaSel
    $cmbRouteMedia.Size = Sz 52 24
    $cmbRouteMedia.Location = Pt ([int]($lblRouteMedia.Right + 8)) 46
    $cmbRouteMedia.Add_SelectedIndexChanged({
            try {
                $numMediaCh.Value = [decimal]([int]$cmbRouteMedia.SelectedItem)
            }
            catch {}
        })
    $grpRouteHint.Controls.Add($cmbRouteMedia)

    $lblRouteZoom = New-Object System.Windows.Forms.Label
    $lblRouteZoom.Text = "Zoom Ch:"
    $lblRouteZoom.AutoSize = $true
    $lblRouteZoom.Location = Pt ([int]($cmbRouteMedia.Right + 28)) $routeRowY
    $grpRouteHint.Controls.Add($lblRouteZoom)

    $cmbRouteZoom = New-Object System.Windows.Forms.ComboBox
    $cmbRouteZoom.DropDownStyle = 'DropDownList'
    for ($i = 8; $i -le 30; $i++) { [void]$cmbRouteZoom.Items.Add($i) }
    $zoomSel = [int]$script:Cfg.Zoom.ZoomInLine
    if ($zoomSel -lt 8 -or $zoomSel -gt 30) { $zoomSel = 9 }
    $cmbRouteZoom.SelectedItem = $zoomSel
    $cmbRouteZoom.Size = Sz 52 24
    $cmbRouteZoom.Location = Pt ([int]($lblRouteZoom.Right + 8)) 46
    $cmbRouteZoom.Add_SelectedIndexChanged({
            try {
                if ($cmbZoomLine -and $cmbZoomLine.Items.Count -ge [int]$cmbRouteZoom.SelectedItem) {
                    $cmbZoomLine.SelectedIndex = [int]$cmbRouteZoom.SelectedItem - 1
                }
            }
            catch {}
        })
    $grpRouteHint.Controls.Add($cmbRouteZoom)

    $chkMixerPanel.Add_CheckedChanged({
            try {
                $script:Cfg.XR.MixerPanelEnabled = $script:chkMixerPanel.Checked
                # Also sync XRMixerEnabled from the live checkbox (not yet saved via OK)
                $script:Cfg.XR.XRMixerEnabled = $chkXREnabled.Checked
                Save-Settings | Out-Null
                if ($script:chkMixerPanel.Checked -and $chkXREnabled.Checked) { Show-MixerPanel } else { Hide-MixerPanel }
            }
            catch {
                Log "Mixer Panel toggle error: $_"
            }
        })

    $y += ($grpXR.Height + 12)


    # --- Extra space below XR block to prevent overlap (your value) ---
    $y += 18  # was 18

    # --- ScenePicker + Snapshots control (8 rows + header, no PTZ) ---
    [System.Windows.Forms.Application]::DoEvents()  # keep preview alive during dialog build
    $grpSP = New-Object System.Windows.Forms.GroupBox
    $grpSP.Text = "ScenePicker + Snapshots control"
    $grpSP.Location = Pt 14 $y
    $panel.Controls.Add($grpSP)

    # Layout constants
    $rowTop = 48
    $rowH = 28
    $rowGap = 8
    $hdrY = 18

    $lblW = 92
    $sceneW = 160
    $snapW = 64
    $ptzW = 40     # PTZ preset # column
    $secW = 52
    $chkW = 18

    # Column X positions (Scene | Snapshot | PTZ# | Seconds | Auto)
    $colX1 = 8
    $colX2 = $colX1 + $lblW + 4
    $colX3 = $colX2 + $sceneW + 12
    $colX3b = $colX3 + $snapW + 8     # PTZ# column
    $colX4 = $colX3b + $ptzW + 8
    $colX5 = $colX4 + $secW + 8

    # Header labels
    function AddCenteredHeader([string]$text, [int]$x, [int]$w) {
        $hdr = New-Object System.Windows.Forms.Label
        $hdr.AutoSize = $true; $hdr.Text = $text
        $grpSP.Controls.Add($hdr)
        $hdr.Location = Pt ([int]($x + ($w - $hdr.PreferredSize.Width) / 2)) $hdrY
    }
    AddCenteredHeader -text "Scene"    -x $colX2 -w $sceneW
    AddCenteredHeader -text "Snapshot" -x $colX3 -w $snapW
    AddCenteredHeader -text "PTZ#"     -x $colX3b -w $ptzW
    AddCenteredHeader -text "Seconds"  -x $colX4 -w $secW
    $hdrAuto = New-Object System.Windows.Forms.Label
    $hdrAuto.AutoSize = $true; $hdrAuto.Text = "Auto Start"
    $grpSP.Controls.Add($hdrAuto)
    $hdrAuto.Location = Pt $colX5 $hdrY

    # Info button for ScenePicker
    $btnSPInfo = New-Object System.Windows.Forms.Button
    $btnSPInfo.Text = "i"
    $btnSPInfo.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $btnSPInfo.Size = Sz 26 22
    $btnSPInfo.Location = Pt 636 14
    $btnSPInfo.BackColor = [System.Drawing.Color]::FromArgb(70, 130, 220)
    $btnSPInfo.ForeColor = [System.Drawing.Color]::White
    $btnSPInfo.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $btnSPInfo.FlatAppearance.BorderSize = 0
    $btnSPInfo.Add_Click({
            $msg = @"
SCENE PICKER + SNAPSHOTS — Setup Guide

This panel links your OBS scenes to XR mixer snapshots and PTZ camera
presets, so switching a scene with this app does everything at once.

──────────────────────────────────────────────
COLUMN GUIDE
  Scene      — Choose which OBS scene name this row applies to.
  Snapshot   — Which XR mixer snapshot (1-10) to recall when this
               scene is activated. (Requires XR mixer connected.)
  PTZ#       — PTZ preset number to recall when this scene is activated.
               Set -1 to disable PTZ for this row.
               ⚠ See numbering note below — OBS starts at 0, this app
               starts at 1, so always add 1 to the OBS preset number.
  Seconds    — Auto Start delay: how many seconds after meeting start
               before this scene is automatically switched to.
               Set 0 to disable auto-start for this row.
  Auto Start — Tick to allow this row to auto-switch at meeting start.

──────────────────────────────────────────────
HOW TO SET UP OBS SCENES
  1. Open OBS Studio.
  2. In the 'Scenes' panel (bottom-left), click '+' to add scenes.
  3. Name them exactly as you want them to appear here
     (e.g. 'Speaker', 'All Stage', 'Demo').
  4. Save your OBS scene collection.
  5. In this settings panel, click inside a Scene dropdown —
     available OBS scenes load automatically (OBS must be connected).

──────────────────────────────────────────────
HOW TO SET UP PTZ CAMERA CONTROL IN OBS
  PTZ (Pan-Tilt-Zoom) recall is handled via the OBS WebSocket and
  a compatible PTZ plugin or script.

  OPTION A — obs-ptz plugin (recommended):
    1. Download and install 'obs-ptz' from GitHub
       (search: 'obs-ptz release').
    2. In OBS: Tools → PTZ Controls → add your camera.
    3. Configure presets (positions) for each camera angle.
    4. The plugin exposes an OBS WebSocket request that this app
       can call when switching scenes.

  FINDING YOUR PTZ PRESET NUMBERS:
    • In OBS, open the PTZ Controls dock (Tools → PTZ Controls).
      This dock shows all your saved PTZ presets — use it to find
      which preset number matches each camera position.
    • OBS PTZ Controls numbers presets starting from 0
      (first preset = 0, second = 1, third = 2, and so on).

  ⚠ ONE DIGIT OFF — IMPORTANT:
    The PTZ# column in this app is 1-based. Always add 1 to the
    preset number shown in OBS PTZ Controls when entering it here:
      OBS PTZ preset 0  →  enter PTZ# 1 in this app
      OBS PTZ preset 1  →  enter PTZ# 2 in this app
      OBS PTZ preset 2  →  enter PTZ# 3 in this app
      (and so on — OBS 0 = this app 1)

  OPTION B — ONVIF / IP Camera via browser URL:
    1. Some PTZ cameras accept HTTP GET requests to move:
       e.g. http://192.168.1.100/cgi-bin/ptzctrl.cgi?ptzcmd&poscall&1
    2. You can trigger these via OBS browser source auto-refresh
       or a script linked to scene changes.

  LINKING PTZ TO A SCENE:
    • In OBS: right-click a scene → 'Add Scene-Specific Action'
      (if your PTZ plugin supports it).
    • Or use the obs-ptz plugin's 'PTZ Controls' dock — assign
      a preset number to each scene under 'Auto PTZ'.
    • The Snapshot column in this table recalls your XR mixer
      audio preset at the same time, completing the full switch.

──────────────────────────────────────────────
TIPS
  • Scenes must exist in OBS before they appear in the dropdown.
  • Connect OBS (via the chip/connect button) before opening settings
    so scene names load correctly.
  • Auto Start rows fire in order of their Seconds value at meeting start.
  • To check all available PTZ presets: open OBS → Tools → PTZ Controls.
"@
            Show-InfoPopup -Title "Scene Picker — Setup Guide" -Key "ScenePicker" -DefaultText $msg
        })
    $grpSP.Controls.Add($btnSPInfo)

    # Build rows
    $rows = 8
    $spRows = @()
    for ($i = 0; $i -lt $rows; $i++) {
        $ry = $rowTop + ($rowH + $rowGap) * $i

        $lbl = New-Object System.Windows.Forms.Label
        $lbl.Text = "If Scene ="; $lbl.AutoSize = $true
        $lbl.Location = Pt $colX1 ($ry + 4); $grpSP.Controls.Add($lbl)

        $cmbScene = New-Object System.Windows.Forms.ComboBox
        $cmbScene.DropDownStyle = 'DropDownList'
        $cmbScene.Size = Sz $sceneW 24; $cmbScene.Location = Pt $colX2 $ry
        [void]$cmbScene.Items.Add("")    # blank default
        $grpSP.Controls.Add($cmbScene)

        $cmbSnap = New-Object System.Windows.Forms.ComboBox
        $cmbSnap.DropDownStyle = 'DropDownList'
        1..10 | ForEach-Object { [void]$cmbSnap.Items.Add($_.ToString()) }
        $cmbSnap.SelectedIndex = 0
        $cmbSnap.Size = Sz $snapW 24; $cmbSnap.Location = Pt $colX3 $ry
        $grpSP.Controls.Add($cmbSnap)

        $numPtz = New-Object System.Windows.Forms.NumericUpDown
        $numPtz.Minimum = -1; $numPtz.Maximum = 16; $numPtz.Value = -1
        $numPtz.Size = Sz $ptzW 24; $numPtz.Location = Pt $colX3b $ry
        $grpSP.Controls.Add($numPtz)

        $numSec = New-Object System.Windows.Forms.NumericUpDown
        $numSec.Minimum = 0; $numSec.Maximum = 9999
        $numSec.Size = Sz $secW 24; $numSec.Location = Pt $colX4 $ry
        $grpSP.Controls.Add($numSec)

        $chkAuto = New-Object System.Windows.Forms.CheckBox
        $chkAuto.Size = Sz $chkW 24; $chkAuto.Location = Pt $colX5 ($ry + 4)
        $grpSP.Controls.Add($chkAuto)

        $spRows += [pscustomobject]@{
            SceneCmb = $cmbScene; SnapCmb = $cmbSnap; PtzNum = $numPtz; SecNum = $numSec; AutoChk = $chkAuto
        }
    }

    # When Auto Mode is active: grey out snapshot combos and add a notice
    if ($script:_autoModeActive) {
        $lblAutoModeNote = New-Object System.Windows.Forms.Label
        $lblAutoModeNote.Text = "Snapshot auto-loading is DISABLED while Auto Mode is active"
        $lblAutoModeNote.AutoSize = $true
        $lblAutoModeNote.ForeColor = [System.Drawing.Color]::FromArgb(255, 160, 0)
        $lblAutoModeNote.Font = New-Object System.Drawing.Font("Segoe UI", 8, [System.Drawing.FontStyle]::Bold)
        $lblAutoModeNote.Location = Pt $colX3 4
        $grpSP.Controls.Add($lblAutoModeNote)
        foreach ($row in $spRows) {
            $row.SnapCmb.Enabled = $false
            $row.SnapCmb.BackColor = [System.Drawing.Color]::FromArgb(80, 80, 80)
            $row.SnapCmb.ForeColor = [System.Drawing.Color]::FromArgb(140, 140, 140)
        }
    }

    # Size group based on rows and move layout cursor
    $grpSP.Height = $rowTop + ($rowH + $rowGap) * $rows + 12
    $grpSP.Width = 792
    $script:spRows = $spRows

    # Populate scenes once (unique, Speaker first) then prefill from config

    # Step 1 — get live OBS scene list (safe: returns empty if OBS offline)
    $obsScenes = @()
    try { $r2 = Obs-GetSceneNames; if ($r2) { $obsScenes = @($r2) } } catch {}

    # Step 2 — always-available names: saved config + OBS list + hardcoded defaults
    $savedSceneNames = @($script:Cfg.ScenePTZ |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_.Scene) } |
        ForEach-Object { [string]$_.Scene })
    $allScenes = @($obsScenes) + @($savedSceneNames) + @("Speaker", "Media", "Monitor 1")

    # Step 3 — deduplicate case-insensitively, Speaker first
    $unique = @()
    foreach ($s in $allScenes) {
        if (-not [string]::IsNullOrWhiteSpace($s) -and -not ($unique | Where-Object { $_ -ieq $s })) { $unique += $s }
    }
    if ($unique | Where-Object { $_ -ieq 'Speaker' }) {
        $unique = @('Speaker') + @($unique | Where-Object { $_ -ine 'Speaker' })
    }

    # Step 4 — fill every combo with the merged list
    foreach ($r in $spRows) {
        $r.SceneCmb.Items.Clear()
        [void]$r.SceneCmb.Items.Add("")      # blank first
        foreach ($s in $unique) { [void]$r.SceneCmb.Items.Add($s) }
        $r.SceneCmb.SelectedIndex = 0
    }

    # Step 5 — prefill combos from saved config (always works, no OBS needed)
    $cfgRows = @($script:Cfg.ScenePTZ)
    for ($i = 0; $i -lt [math]::Min($spRows.Count, $cfgRows.Count); $i++) {
        $row = $spRows[$i]; $cfg = $cfgRows[$i]
        $sceneVal = [string]$cfg.Scene

        $idx = 0
        if (-not [string]::IsNullOrWhiteSpace($sceneVal)) {
            for ($j = 0; $j -lt $row.SceneCmb.Items.Count; $j++) {
                if ([string]::Equals([string]$row.SceneCmb.Items[$j], $sceneVal, 'InvariantCultureIgnoreCase')) { $idx = $j; break }
            }
        }
        $row.SceneCmb.SelectedIndex = $idx

        if ($null -ne $cfg.Snapshot) { $row.SnapCmb.SelectedItem = ([int]$cfg.Snapshot).ToString() } else { $row.SnapCmb.SelectedIndex = 0 }
        $row.PtzNum.Value = if ($null -ne $cfg.PTZRecall) { [int]$cfg.PTZRecall } else { -1 }
        $row.SecNum.Value = [int]$cfg.AutoStartSeconds
        $row.AutoChk.Checked = [bool]$cfg.AutoStart
    }

    $y += $grpSP.Height + 10
    # --- end ---
    $yFull = $y + 20   # total virtual height when XR sections are visible
    $ySPOnly = $yAfterCheckbox + 10 + $grpSP.Height + 20  # height when only ScenePicker is shown (no XR mixer)
    $grpSP_normalY = $grpSP.Location.Y   # original Y (below grpXR)
    $grpSP_compactY = $yAfterCheckbox + 10  # Y when grpXR is hidden

    # Apply initial visibility based on saved setting
    # ScenePicker is always visible; only XR Mixer hides when unchecked
    $grpXR.Visible = $chkXREnabled.Checked
    $grpSP.Visible = $true
    if (-not $chkXREnabled.Checked) {
        $grpSP.Location = [System.Drawing.Point]::new(14, $grpSP_compactY)
        $panel.AutoScrollMinSize = [System.Drawing.Size]::new(800, $ySPOnly)
    }
    else {
        $grpSP.Location = [System.Drawing.Point]::new(14, $grpSP_normalY)
        $panel.AutoScrollMinSize = [System.Drawing.Size]::new(800, $yFull)
    }

    # Wire toggle: only XR Mixer shows/hides; ScenePicker always stays visible
    $chkXREnabled.Add_CheckedChanged({
            $grpXR.Visible = $chkXREnabled.Checked
            if ($chkXREnabled.Checked) {
                $grpSP.Location = [System.Drawing.Point]::new(14, $grpSP_normalY)
                $panel.AutoScrollMinSize = [System.Drawing.Size]::new(800, $yFull)
            }
            else {
                $grpSP.Location = [System.Drawing.Point]::new(14, $grpSP_compactY)
                $panel.AutoScrollMinSize = [System.Drawing.Size]::new(800, $ySPOnly)
            }
        })

    # Tell WinForms the exact virtual height so the scrollbar always appears
    # (set again here as a safety net; actual value set above in the toggle logic)
    # Bottom buttons (panel already created and docked at dialog open; just add buttons to it)

    # Import Settings button (left side)
    $btnImport = New-Object System.Windows.Forms.Button; $btnImport.Text = "Import Settings..."; $btnImport.Size = Sz 130 28; $btnImport.Location = Pt 14 10; $btnPanel.Controls.Add($btnImport)
    $btnImport.Add_Click({
            try {
                Show-ManualConfigImportDialog | Out-Null
            }
            catch {
                [System.Windows.Forms.MessageBox]::Show(
                    "Error during import: $_", 
                    "Import Error", 
                    [System.Windows.Forms.MessageBoxButtons]::OK, 
                    [System.Windows.Forms.MessageBoxIcon]::Error
                ) | Out-Null
            }
        })

    # Backup/Export Settings button (next to Import)
    $btnExport = New-Object System.Windows.Forms.Button; $btnExport.Text = "Backup Settings..."; $btnExport.Size = Sz 140 28; $btnExport.Location = Pt 154 10; $btnPanel.Controls.Add($btnExport)
    $btnExport.Add_Click({
            try {
                $configPath = Get-ConfigPath
                if (-not (Test-Path $configPath)) {
                    [System.Windows.Forms.MessageBox]::Show(
                        "No settings file found to back up yet. Please save settings once, then try again.",
                        "Backup Settings",
                        [System.Windows.Forms.MessageBoxButtons]::OK,
                        [System.Windows.Forms.MessageBoxIcon]::Information
                    ) | Out-Null
                    return
                }

                $sfd = New-Object System.Windows.Forms.SaveFileDialog
                $sfd.Title = "Backup Settings"
                $sfd.Filter = "JSON Files (*.json)|*.json|All Files (*.*)|*.*"
                $stamp = (Get-Date -Format 'yyyyMMdd_HHmmss')
                $sfd.FileName = "settings_manual_$stamp.json"
                $backupDir = Join-Path (Split-Path $configPath) 'backups'
                if (-not (Test-Path $backupDir)) { New-Item -ItemType Directory -Path $backupDir -Force | Out-Null }
                $sfd.InitialDirectory = $backupDir

                if ($sfd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
                    Copy-Item -Path $configPath -Destination $sfd.FileName -Force
                    [System.Windows.Forms.MessageBox]::Show(
                        "Settings successfully backed up to:`n$($sfd.FileName)",
                        "Backup Complete",
                        [System.Windows.Forms.MessageBoxButtons]::OK,
                        [System.Windows.Forms.MessageBoxIcon]::Information
                    ) | Out-Null
                }
            }
            catch {
                [System.Windows.Forms.MessageBox]::Show(
                    "Failed to back up settings. See log for details.`n`n$_",
                    "Backup Failed",
                    [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Error
                ) | Out-Null
                try { Log "Config Backup: Failed - $_" } catch {}
            }
        })
    
    $btnOK = New-Object System.Windows.Forms.Button; $btnOK.Text = "OK"; $btnOK.Size = Sz 100 28; $btnOK.Location = Pt 486 10; $btnOK.Anchor = 'Bottom, Right'; $btnOK.DialogResult = [System.Windows.Forms.DialogResult]::OK; $btnPanel.Controls.Add($btnOK)
    $btnCancel = New-Object System.Windows.Forms.Button; $btnCancel.Text = "Cancel"; $btnCancel.Size = Sz 100 28; $btnCancel.Location = Pt 602 10; $btnCancel.Anchor = 'Bottom, Right'; $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel; $dlg.CancelButton = $btnCancel; $btnPanel.Controls.Add($btnCancel)

    # Bug Report button
    $btnBugReport = New-Object System.Windows.Forms.Button
    $btnBugReport.Text = "Bug Report"
    $btnBugReport.Size = Sz 110 28
    $btnBugReport.Location = Pt 302 10
    $btnBugReport.BackColor = [System.Drawing.Color]::FromArgb(180, 40, 40)
    $btnBugReport.ForeColor = [System.Drawing.Color]::White
    $btnBugReport.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $btnBugReport.FlatAppearance.BorderSize = 0
    $btnBugReport.Add_Click({ Show-BugReport -OwnerForm $dlg })
    $btnPanel.Controls.Add($btnBugReport)

    $dlg.Add_Shown({
            try {
                $null = $btnOK.Focus()
                foreach ($tb in @($tbKey, $tbT, $txtMeeting)) { try { $tb.SelectionLength = 0 }catch {} }
                
                # Auto-scan X Air IP if empty or default
                if ([string]::IsNullOrWhiteSpace($tbIp.Text) -or $tbIp.Text -eq '127.0.0.1') {
                    $lblXRStatus.Text = "Auto-scanning..."
                    $lblXRStatus.ForeColor = [System.Drawing.Color]::Gray
                    $dlg.Refresh()
                    
                    $foundIp = XR-ScanForMixer
                    if ($foundIp) {
                        $tbIp.Text = $foundIp
                        $lblXRStatus.Text = "✓ Auto-found"
                        $lblXRStatus.ForeColor = [System.Drawing.Color]::Green
                    }
                    else {
                        $lblXRStatus.Text = ""
                    }
                }
            }
            catch {}
        })
    # Apply wheel-block only to value-changing controls (panel scrolling handled by IMessageFilter)
    Disable-AllMouseWheels $dlg

    # No thread DPI context switch was applied for this dialog.

    if ($dlg.ShowDialog($script:form) -eq [System.Windows.Forms.DialogResult]::OK) {
        $script:Cfg.Keyword = $tbKey.Text; $script:Cfg.Tesseract = $tbT.Text
        $script:Cfg.Meeting.Lines = @($txtMeeting.Lines); $script:Cfg.Meeting.FlashClockRedLast15 = $chkFlashClock.Checked
        $script:Cfg.Music.Folder = $tbFolder.Text
        $script:Cfg.Music.Shuffle = $chkShuffle.Checked
        $script:Cfg.Music.Volume = [int]$trkVol.Value
        $script:Cfg.Music.AutoStart = $chkAutoStart.Checked
        $script:Cfg.Music.AutoStopBeforeMeeting = $chkAutoStop.Checked
        $script:Cfg.Music.PreStopSeconds = [int]$numSecs.Value
        $script:Cfg.Music.FadeOutSeconds = [int]$numFade.Value
        $script:Music.Folder = $script:Cfg.Music.Folder
        $script:Music.FadeOutSeconds = [int]$script:Cfg.Music.FadeOutSeconds
        Music-SetShuffle $script:Cfg.Music.Shuffle
        Music-SetVolume  $script:Cfg.Music.Volume
        $script:Cfg.OBSControl.AutoStartAutoToggle = $chkAutoToggle.Checked
        $script:Cfg.OBSControl.AutoVirtualCamera = $chkAutoVirtualCamera.Checked
        $script:Cfg.Zoom.AutoMuteSeconds = [int]$numMuteSecs.Value
        $script:Cfg.Zoom.AutoCameraOn = $chkCameraOn.Checked
        $script:Cfg.Zoom.AutoCameraSeconds = [int]$numCameraSecs.Value
        $script:Cfg.Zoom.AutoUnmuteHost = $chkUnmuteHost.Checked
        $script:Cfg.Zoom.AutoUnmuteSeconds = [int]$numUnmuteSecs.Value
        $script:Cfg.Zoom.AutoFocusMode = $chkFocusMode.Checked
        $script:Cfg.Zoom.AutoFocusSeconds = [int]$numFocusSecs.Value
        $script:Cfg.Zoom.AutoZoomAudio = $chkZoomAudio.Checked
        $script:Cfg.Zoom.ZoomInLine = [int]$cmbRouteZoom.SelectedItem
        $script:Cfg.Zoom.AudioLevelDb = [double]$txtAudioDb.Text
        $script:Cfg.Zoom.HoldTimeMs = [int]$numHoldTime.Value
        $script:Cfg.Zoom.HandAlertMonitor = [int]$cmbHandMonitor.SelectedIndex
        
        # Auto Join Meeting settings
        $script:Cfg.Zoom.JoinMeetingID = $txtMeetingID.Text.Trim()
        $script:Cfg.Zoom.JoinDisplayName = $txtDisplayName.Text.Trim()
        $script:Cfg.Zoom.JoinDontConnectAudio = $chkDontConnectAudio.Checked
        $script:Cfg.Zoom.JoinTurnOffVideo = $chkTurnOffVideo.Checked
        $script:Cfg.Zoom.JoinMeetingPassword = $txtMeetingPassword.Text
        $script:Cfg.Zoom.AutoPollsAfterJoin = $chkAutoPolls.Checked
        $script:Cfg.Zoom.ShowFocusModeButton = $chkShowFocusBtn.Checked
        $script:Cfg.Zoom.PollsConfigured = $chkPollsConfigured.Checked
        $btnZoomFocus.Visible = $chkShowFocusBtn.Checked
        
        # Debug: Log what we're saving
        Log "Settings Save Debug: JoinMeetingID='$($script:Cfg.Zoom.JoinMeetingID)'"
        Log "Settings Save Debug: JoinDisplayName='$($script:Cfg.Zoom.JoinDisplayName)'"
        Log "Settings Save Debug: JoinDontConnectAudio=$($script:Cfg.Zoom.JoinDontConnectAudio)"
        Log "Settings Save Debug: JoinTurnOffVideo=$($script:Cfg.Zoom.JoinTurnOffVideo)"
        $script:Cfg.Reminders.ZoomEnabled = $chkRem.Checked
        $script:Cfg.Reminders.Seconds = [int]$numRemS.Value
        $script:Cfg.Reminders.Message = $txtRemMsg.Text
        $script:Cfg.Reminders.Reminder2Enabled = $chkRem2.Checked
        $script:Cfg.Reminders.Reminder2Seconds = [int]$numRem2S.Value
        $script:Cfg.Reminders.Message2 = $txtRemMsg2.Text
        # XR master enable switch
        $script:Cfg.XR.XRMixerEnabled = $chkXREnabled.Checked
        # XR save – port is fixed to 10024 (values always saved even if XR section hidden)
        $script:Cfg.XR.MixerIP = $tbIp.Text.Trim()
        $script:Cfg.XR.OscPort = 10024
        $script:Cfg.XR.SnapshotNumber = [int]$numSnap.Value
        $script:Cfg.XR.DuckingEnabled = $chkDuckingEnabled.Checked
        Log "Settings OK Button: Setting DuckingEnabled to $($chkDuckingEnabled.Checked)"
        $script:Cfg.XR.PodiumChannel = [int]$numPodiumCh.Value
        $script:Cfg.XR.DuckAmountDB = [int]$numDuckAmount.Value
        $script:Cfg.XR.HoldTimeMS = [int]$numHoldTime.Value
        $script:Cfg.XR.MediaChannel = [int]$cmbRouteMedia.SelectedItem
        # Save threshold directly as dB (XR meter levels are already in dB)
        $script:Cfg.XR.ThresholdDB = [int]$numAudioThreshold.Value
        $script:Cfg.XR.RoverDuckingEnabled = $chkRoverDucking.Checked
        $script:Cfg.XR.RoverChannel1 = [int]$numRoverCh1.Value
        $script:Cfg.XR.RoverChannel2 = [int]$numRoverCh2.Value
        $script:Cfg.XR.RoverMonitorChannel = [int]$numRoverMonitorCh.Value
        $script:Cfg.XR.RoverMonitorChannel2 = [int]$numRoverMonitorCh2.Value
        $script:Cfg.XR.RoverDuckAmountDB = [int]$numRoverDuckAmount.Value
        $script:Cfg.XR.RoverHoldTimeMS = [int]$numRoverHoldTime.Value
        $script:Cfg.XR.RoverThresholdDB = [int]$numRoverThreshold.Value
        # RoverActiveSnapshot: 0 = Any, 1-10 = specific snapshot (combo index maps 1:1 to snapshot number)
        $script:Cfg.XR.RoverActiveSnapshot = $cmbRoverSnap.SelectedIndex  # index 0 = Any, 1-10 = snapshot 1-10
        $script:Cfg.XR.MixerPanelEnabled = $chkMixerPanel.Checked
        $script:Cfg.XR.XrDebugLog = $chkXrDebugLog.Checked
        $script:Cfg.XR.AutoModeEnabled = $script:chkAutoMode.Checked
        $script:Cfg.XR.AutoModeHoldTimeMS = [int]$script:numAutoModeHold.Value
        $script:Cfg.XR.LimiterEnabled = $script:chkLimiter.Checked
        $script:Cfg.XR.LimiterThresholdDB = [int]$script:numLimiterThresh.Value
        $script:Cfg.XR.LimiterSnapBackSec = [int]$script:numLimiterSnapBack.Value
        $script:Cfg.XR.ShowLevelLabels = $script:chkShowLevels.Checked


        # --- OBS WS host/port/password from Settings ---
        $script:Cfg.OBS.Host = $tbObsHost.Text.Trim()
        $script:Cfg.OBS.Port = [int]$numObsPort.Value
        $script:Cfg.OBS.Password = $tbObsPwd.Text
        $script:Cfg.OBS.FadeBlackScene = $tbFadeScene.Text.Trim()
        $script:Cfg.OBS.FadeBlackMs = [int]$numFadeMs.Value
        $script:Cfg.OBS.FadeBlackHoldMs = [int]$numFadeHold.Value

        # PiP settings
        $script:Cfg.PiP.Enabled = $chkPiPEnabled.Checked
        $script:Cfg.PiP.SourceName = $tbPipSourceName.Text.Trim()
        try {
            if ($script:btnPip -and -not $script:btnPip.IsDisposed) {
                $script:btnPip.Visible = [bool]$script:Cfg.PiP.Enabled
            }
        }
        catch {}

        # keep preview/autoconnect in sync immediately
        try {
            $script:ObsWsHost = [string]$script:Cfg.OBS.Host
            $script:ObsWsPort = [int]$script:Cfg.OBS.Port
            if ($script:lblHint) {
                $script:lblHint.Text = "OBS: waiting for WebSocket on $($script:ObsWsHost):$($script:ObsWsPort) …"
            }
        }
        catch {}

        # Save ScenePTZ map from $spRows (pad to 8 rows) — PTZ removed
        $existingMap = @($script:Cfg.ScenePTZ)  # snapshot BEFORE overwriting
        $newMap = @()
        $rowIdx = 0
        foreach ($r in $spRows) {
            $sceneChosen = ""
            if ($null -ne $r.SceneCmb.SelectedItem) { $sceneChosen = [string]$r.SceneCmb.SelectedItem }
            elseif (-not [string]::IsNullOrWhiteSpace($r.SceneCmb.Text)) { $sceneChosen = [string]$r.SceneCmb.Text }

            # If OBS was offline the combo may have been blank even though a scene
            # was saved — preserve the existing value rather than wiping it.
            if ([string]::IsNullOrWhiteSpace($sceneChosen) -and $rowIdx -lt $existingMap.Count) {
                $existing = [string]$existingMap[$rowIdx].Scene
                if (-not [string]::IsNullOrWhiteSpace($existing)) { $sceneChosen = $existing }
            }
            $rowIdx++

            $newMap += @{
                Scene            = $sceneChosen
                PTZRecall        = $(if ([int]$r.PtzNum.Value -ge 0) { [int]$r.PtzNum.Value } else { $null })
                Snapshot         = $( if ($r.SnapCmb.SelectedItem) { [int][string]$r.SnapCmb.SelectedItem } else { $null } )
                AutoStartSeconds = [int]$r.SecNum.Value
                AutoStart        = [bool]$r.AutoChk.Checked
            }
        }
        while ($newMap.Count -lt 8) { $newMap += @{ Scene = ""; PTZRecall = $null; Snapshot = $null; AutoStartSeconds = 0; AutoStart = $false } }
        if ($newMap.Count -gt 8) { $newMap = $newMap[0..7] }
        $script:Cfg.ScenePTZ = $newMap

        Save-Settings | Out-Null
        try { XR-UpdateStatus } catch {}
        # Sync mixer panel visibility with saved state
        try {
            if ($script:Cfg.XR.XRMixerEnabled -and $script:Cfg.XR.MixerPanelEnabled) { Show-MixerPanel } else { Hide-MixerPanel }
        }
        catch {}
        # Start or stop XR-dependent timers immediately based on new XRMixerEnabled state
        try {
            if ([bool]$script:Cfg.XR.XRMixerEnabled -and $script:ObsConnected) {
                if ($script:DuckingTimer -and -not $script:DuckingTimer.Enabled) { $script:DuckingTimer.Start(); Log "Audio ducking timer started (OBS audio monitoring)." }
                if ($script:ZoomRaiseTimer -and -not $script:ZoomRaiseTimer.Enabled) { $script:ZoomRaiseTimer.Start(); Log "Zoom audio raise timer started." }
            }
            else {
                if ($script:DuckingTimer -and $script:DuckingTimer.Enabled) { $script:DuckingTimer.Stop() }
                if ($script:ZoomRaiseTimer -and $script:ZoomRaiseTimer.Enabled) { $script:ZoomRaiseTimer.Stop() }
            }
        }
        catch {}

        # If ducking setting changed and OBS is connected, reconnect to update audio monitoring subscription
        try {
            if ($script:ObsConnected) {
                # Preserve current scene before reconnecting.
                # Use worker's cached scene name (no UI-thread network call).
                $script:_preservedScene = if ($script:obsShared -and $script:obsShared.SceneName) {
                    $script:obsShared.SceneName
                }
                else {
                    Get-CurrentProgramSceneName
                }
                Log "Ducking setting changed - reconnecting OBS to update audio monitoring..."
                if ($script:_preservedScene) {
                    Log "Preserving current scene: '$($script:_preservedScene)'"
                }
                Close-Obs
                Start-Sleep -Milliseconds 500
                # Auto-reconnect will pick it up with the new subscription
            }
        }
        catch {}

    }
}

# Modern settings gear button
$btnSettingsGear = New-Object System.Windows.Forms.Button
$btnSettingsGear.Font = New-Object System.Drawing.Font("Segoe UI Symbol", 18, [System.Drawing.FontStyle]::Bold)
$btnSettingsGear.Text = "🛠"
$btnSettingsGear.Size = Sz 44 44  # Slightly larger for better visibility
$btnSettingsGear.FlatStyle = 'Flat'
$btnSettingsGear.FlatAppearance.BorderSize = 1
$btnSettingsGear.UseVisualStyleBackColor = $false
$btnSettingsGear.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 215)
$btnSettingsGear.ForeColor = [System.Drawing.Color]::White
$btnSettingsGear.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(0, 90, 180)
$btnSettingsGear.TabStop = $false
$btnSettingsGear.Anchor = ([System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right)
$btnSettingsGear.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
$btnSettingsGear.ImageAlign = [System.Drawing.ContentAlignment]::MiddleCenter
# Apply rounded corners to settings button
Set-RoundedCorners $btnSettingsGear 22  # Make it perfectly round
$script:_gearSpinFrames = @('⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏')
$script:_gearSpinIdx = 0
$script:_gearSpinTimer = New-Object System.Windows.Forms.Timer
$script:_gearSpinTimer.Interval = 120
$script:_gearSpinTimer.Add_Tick({
        $script:_gearSpinIdx = ($script:_gearSpinIdx + 1) % $script:_gearSpinFrames.Count
        try { $script:btnSettingsGear.Text = $script:_gearSpinFrames[$script:_gearSpinIdx] } catch {}
    })

$btnSettingsGear.Add_Click({
        # Guard: ignore extra clicks while dialog is open or being built
        if ($script:_settingsDialogBusy) { return }
        $script:_settingsDialogBusy = $true
        # Turn button orange and start spinner animation
        $origColor = $script:btnSettingsGear.BackColor
        $origText = $script:btnSettingsGear.Text
        $origFont = $script:btnSettingsGear.Font
        $script:btnSettingsGear.BackColor = [Drawing.Color]::FromArgb(200, 120, 0)
        $script:btnSettingsGear.Font = New-Object System.Drawing.Font('Segoe UI', 18, [System.Drawing.FontStyle]::Bold)
        $script:btnSettingsGear.Text = $script:_gearSpinFrames[0]
        $script:btnSettingsGear.Refresh()
        $script:_gearSpinTimer.Start()
        try {
            Show-SettingsDialog
        }
        finally {
            $script:_gearSpinTimer.Stop()
            $script:btnSettingsGear.Font = $origFont
            $script:btnSettingsGear.Text = $origText
            $script:btnSettingsGear.BackColor = $origColor
            $script:btnSettingsGear.Refresh()
            $script:_settingsDialogBusy = $false
        }
    })
$script:form.Controls.Add($btnSettingsGear)
$script:btnSettingsGear = $btnSettingsGear  # Store reference for tooltips
function Place-Gear {
    $m = 12  # Slightly more margin for modern look
    $fw = [int]$script:form.ClientSize.Width
    $fh = [int]$script:form.ClientSize.Height
    $sh = 0
    if ($script:statusStrip -and $script:statusStrip.Visible) {
        try { $sh = [int]$script:statusStrip.Height } catch { $sh = 0 }
    }
    $gw = [int]$btnSettingsGear.Width
    $gh = [int]$btnSettingsGear.Height
    $gx = $fw - $gw - $m
    $gy = $fh - $sh - $gh - $m
    if ($gx -lt 0) { $gx = 0 }
    if ($gy -lt 0) { $gy = 0 }
    $btnSettingsGear.Location = Pt $gx $gy
    $btnSettingsGear.Visible = $true
    $btnSettingsGear.BringToFront()
}
$script:form.Add_Shown({
        try {
            [void]$script:form.BeginInvoke([System.Action] { Place-Gear })
        }
        catch {
            Place-Gear
        }
    })
$script:form.Add_Resize({ Place-Gear })
Place-Gear

function Get-DpiScaleFactor {
    # Returns the current DPI scale factor (e.g. 1.5 for 150% scaling).
    # CopyFromScreen needs physical pixels; Cursor.Position returns logical pixels
    # on DPI-unaware processes. Multiply stored ROI coords by this factor.
    try {
        $g = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
        $s = [double]($g.DpiX / 96.0)
        $g.Dispose()
        if ($s -lt 1.0) { return 1.0 }
        return $s
    }
    catch { return 1.0 }
}

function Get-ROIText {
    $tl = $script:Cfg.ROI.TL; $br = $script:Cfg.ROI.BR
    if (-not $tl -or -not $br) { return "ROI: (unset)" }
    $x = [math]::Min($tl.X, $br.X); $y = [math]::Min($tl.Y, $br.Y)
    $w = [math]::Abs($br.X - $tl.X); $h = [math]::Abs($br.Y - $tl.Y)
    if ($w -le 0 -or $h -le 0) { "ROI: (invalid)" } else { "ROI: (X,Y,W,H)=($x,$y,$w,$h)" }
}

# ---------- Zoom control ----------
function Focus-ZoomWindow {
    try {
        $p = Get-Process -Name "Zoom" -ErrorAction SilentlyContinue |
        Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
        if ($p) {
            [Microsoft.VisualBasic.Interaction]::AppActivate($p.Id) | Out-Null
            Start-Sleep -Milliseconds 120
            return $true
        }
    }
    catch {}
    try {
        if ([Microsoft.VisualBasic.Interaction]::AppActivate("Zoom")) {
            Start-Sleep -Milliseconds 120
            return $true
        }
    }
    catch {}
    return $false
}
function Zoom-MuteAll {
    if (-not (Focus-ZoomWindow)) { Log "Zoom: could not activate window."; return $false }
    try { [System.Windows.Forms.SendKeys]::SendWait('%m'); Log "Zoom: ALT+M sent (Mute All except Host)."; return $true }catch { Log "Zoom sendkeys error: $_"; return $false }
}

function Zoom-CameraOn {
    # Only send Alt+V if camera is known to be off. If already on or state unknown, skip to avoid toggling it off.
    if ($script:ZoomCameraStatus -ne $false) {
        Log "Zoom Camera: already on or state unknown (state=$($script:ZoomCameraStatus)); skipping."
        return $true
    }
    if (-not (Focus-ZoomWindow)) { Log "Zoom: could not activate window."; return $false }
    try {
        [System.Windows.Forms.SendKeys]::SendWait('%v')
        Log "Zoom: ALT+V sent (Camera on)."
        $script:ZoomCameraStatus = $true
        $script:_lastManualToggleTime = Get-Date  # block UIA poll from overwriting for 3s
        $statusUpd = @{ Found = $true; MicOn = $script:ZoomMicStatus; CameraOn = $true }
        try { Update-ZoomStatusIcons $statusUpd } catch {}
        return $true
    }
    catch { Log "Zoom sendkeys error: $_"; return $false }
}

function Zoom-OpenParticipantsPanel {
    param([switch]$Silent)
    try {
        $root = Get-ZoomUIAutomationRoot
        if (-not $root) {
            Log "Zoom Participants: UI Automation not available."
            if (-not $Silent) { [System.Windows.Forms.MessageBox]::Show($script:form, "UI Automation is not available on this system.", "Zoom Participants") | Out-Null }
            return $false
        }

        $treeScope = [System.Windows.Automation.TreeScope]::Subtree
        $nameProp = [System.Windows.Automation.AutomationElement]::NameProperty
        $typeProp = [System.Windows.Automation.AutomationElement]::ControlTypeProperty
        $windowType = [System.Windows.Automation.ControlType]::Window
        $buttonType = [System.Windows.Automation.ControlType]::Button

        $nameCond = New-Object System.Windows.Automation.PropertyCondition($nameProp, "Zoom Meeting")
        $typeCond = New-Object System.Windows.Automation.PropertyCondition($typeProp, $windowType)
        $zoomCond = New-Object System.Windows.Automation.AndCondition($nameCond, $typeCond)
        $zoomWindow = $root.FindFirst($treeScope, $zoomCond)
        if (-not $zoomWindow) {
            Log "Zoom Participants: Zoom meeting window not found."
            if (-not $Silent) { [System.Windows.Forms.MessageBox]::Show($script:form, "Zoom meeting not detected. Start or join a Zoom meeting first.", "Zoom Participants") | Out-Null }
            return $false
        }

        # Button name is dynamic e.g. "Participants, open panel, 3 participants, Alt+U"
        # Scan all buttons and match by name wildcard
        $btnTypeCond = New-Object System.Windows.Automation.PropertyCondition($typeProp, $buttonType)
        $allButtons = $zoomWindow.FindAll($treeScope, $btnTypeCond)
        $participantsBtn = $null
        for ($i = 0; $i -lt $allButtons.Count; $i++) {
            $el = $allButtons.Item($i)
            $name = ''
            try { $name = $el.Current.Name } catch {}
            if ($name -like '*Participants*open panel*') {
                $participantsBtn = $el; break
            }
        }
        if (-not $participantsBtn) {
            Log "Zoom Participants: panel already open or button not found."
            # Panel may already be open — not an error
            return $true
        }

        $invokePattern = $participantsBtn.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
        if (-not $invokePattern) {
            Log "Zoom Participants: button does not support InvokePattern."
            if (-not $Silent) { [System.Windows.Forms.MessageBox]::Show($script:form, "Unable to click the Participants button via UI Automation.", "Zoom Participants") | Out-Null }
            return $false
        }

        $invokePattern.Invoke()
        Log "Zoom Participants: Participants panel opened."
        return $true
    }
    catch {
        Log "Zoom Participants: error opening panel: $_"
        if (-not $Silent) { [System.Windows.Forms.MessageBox]::Show($script:form, "Error opening Participants panel:`r`n$_", "Zoom Participants") | Out-Null }
        return $false
    }
}

function Zoom-OpenPollPanel {
    param([switch]$Silent)  # suppress message boxes when called from auto-mode
    try {
        $root = Get-ZoomUIAutomationRoot
        if (-not $root) {
            Log "Zoom Polls: UI Automation not available; cannot open Polls/Quizzes panel."
            if (-not $Silent) { [System.Windows.Forms.MessageBox]::Show($script:form, "UI Automation is not available on this system.`r`nCannot open Zoom Polls/Quizzes panel.", "Zoom Polls") | Out-Null }
            return $false
        }

        $treeScope = [System.Windows.Automation.TreeScope]::Subtree
        $nameProp = [System.Windows.Automation.AutomationElement]::NameProperty
        $typeProp = [System.Windows.Automation.AutomationElement]::ControlTypeProperty
        $windowType = [System.Windows.Automation.ControlType]::Window

        $nameCond = New-Object System.Windows.Automation.PropertyCondition($nameProp, "Zoom Meeting")
        $typeCond = New-Object System.Windows.Automation.PropertyCondition($typeProp, $windowType)
        $zoomCond = New-Object System.Windows.Automation.AndCondition($nameCond, $typeCond)

        $zoomWindow = $root.FindFirst($treeScope, $zoomCond)
        if (-not $zoomWindow) {
            Log "Zoom Polls: Zoom meeting window not found."
            if (-not $Silent) { [System.Windows.Forms.MessageBox]::Show($script:form, "Zoom meeting not detected. Start or join a Zoom meeting first.", "Zoom Polls") | Out-Null }
            return $false
        }

        $buttonType = [System.Windows.Automation.ControlType]::Button
        $buttonTypeCond = New-Object System.Windows.Automation.PropertyCondition($typeProp, $buttonType)
        $pollNameCond1 = New-Object System.Windows.Automation.PropertyCondition($nameProp, "Polls/quizzes")
        $pollNameCond2 = New-Object System.Windows.Automation.PropertyCondition($nameProp, "Polls / Quizzes")
        $nameOrCond = New-Object System.Windows.Automation.OrCondition($pollNameCond1, $pollNameCond2)
        $pollBtnCond = New-Object System.Windows.Automation.AndCondition($buttonTypeCond, $nameOrCond)

        $pollButton = $zoomWindow.FindFirst($treeScope, $pollBtnCond)
        if (-not $pollButton) {
            Log "Zoom Polls: Polls/Quizzes button not found."
            if (-not $Silent) { [System.Windows.Forms.MessageBox]::Show($script:form, "Polls/Quizzes feature not available in this Zoom meeting.", "Zoom Polls") | Out-Null }
            return $false
        }

        $invokePattern = $pollButton.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
        if (-not $invokePattern) {
            Log "Zoom Polls: Polls button does not support InvokePattern."
            if (-not $Silent) { [System.Windows.Forms.MessageBox]::Show($script:form, "Unable to click the Polls/Quizzes button via UI Automation.", "Zoom Polls") | Out-Null }
            return $false
        }

        $invokePattern.Invoke()
        Log "Zoom Polls: Polls/Quizzes panel opened."
        return $true
    }
    catch {
        Log "Zoom Polls: error opening polls panel: $_"
        if (-not $Silent) { [System.Windows.Forms.MessageBox]::Show($script:form, "Error opening Polls/Quizzes panel:`r`n$_", "Zoom Polls") | Out-Null }
        return $false
    }
}

function Zoom-StartFirstPoll {
    param(
        [int]$DelayMs = 700,
        [switch]$Silent  # suppress message boxes when called from auto-mode
    )

    try {
        $root = Get-ZoomUIAutomationRoot
        if (-not $root) { return $false }

        if ($DelayMs -gt 0) { Start-Sleep -Milliseconds $DelayMs }

        # Use narrow scope for top-level windows and full subtree only under the poll panel
        $treeScopeSubtree = [System.Windows.Automation.TreeScope]::Subtree
        $treeScopeWindows = [System.Windows.Automation.TreeScope]::Children
        $typeProp = [System.Windows.Automation.AutomationElement]::ControlTypeProperty

        $windowType = [System.Windows.Automation.ControlType]::Window
        $buttonType = [System.Windows.Automation.ControlType]::Button
        $listItemType = [System.Windows.Automation.ControlType]::ListItem

        $windowCond = New-Object System.Windows.Automation.PropertyCondition($typeProp, $windowType)
        $buttonCond = New-Object System.Windows.Automation.PropertyCondition($typeProp, $buttonType)
        $listItemCond = New-Object System.Windows.Automation.PropertyCondition($typeProp, $listItemType)

        $timeoutMs = 2000
        $stepMs = 500
        $elapsed = 0
        $launchButton = $null
        $pollPanelFound = $false

        while (-not $launchButton -and $elapsed -lt $timeoutMs) {

            $pollPanel = $null

            # Look for a dedicated Polls window first (top-level only, much cheaper)
            $windows = $root.FindAll($treeScopeWindows, $windowCond)
            if ($windows -and $windows.Count -gt 0) {
                for ($i = 0; $i -lt $windows.Count; $i++) {
                    $el = $windows.Item($i)
                    $n = ""
                    try { $n = $el.Current.Name } catch {}
                    if ($n -and $n -match 'poll') {
                        $pollPanel = $el
                        break
                    }
                }
            }

            if ($pollPanel) {
                # First check if a poll is already running (End/Stop button present)
                # Also trigger a delayed attendance read since results may be visible
                # If so, there is nothing to launch - treat as success
                $allButtons = $pollPanel.FindAll($treeScopeSubtree, $buttonCond)
                $pollAlreadyRunning = $false
                if ($allButtons -and $allButtons.Count -gt 0) {
                    for ($i = 0; $i -lt $allButtons.Count; $i++) {
                        $bn = ""
                        try { $bn = $allButtons.Item($i).Current.Name } catch {}
                        if ($bn -and $bn -match '(end poll|stop poll|end quiz|stop quiz)') {
                            $pollAlreadyRunning = $true
                            break
                        }
                    }
                }
                if ($pollAlreadyRunning) {
                    Log "Zoom Polls: Poll is already running - nothing to launch."
                    # Read attendance now (results may already be posted)
                    Invoke-ZoomAttendanceReadDelayed -DelayMs 1000
                    return $true
                }

                # Try to select the first poll item (may be ListItem or Text control type)
                $textType = [System.Windows.Automation.ControlType]::Text
                $textCond = New-Object System.Windows.Automation.PropertyCondition($typeProp, $textType)
                $items = $pollPanel.FindAll($treeScopeSubtree, $listItemCond)
                if (-not $items -or $items.Count -eq 0) {
                    # Fallback: Zoom sometimes uses Text controls instead of ListItem
                    $items = $pollPanel.FindAll($treeScopeSubtree, $textCond)
                }
                if ($items -and $items.Count -gt 0) {
                    $li = $items.Item(0)
                    try {
                        $selPattern = $li.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)
                        if ($selPattern) { $selPattern.Select() }
                    }
                    catch {}
                    # Give Zoom time to render the Launch button after selection
                    Start-Sleep -Milliseconds 600
                }

                # Scan the full poll panel for Launch/Start button (renders outside the list item)
                $buttons = $pollPanel.FindAll($treeScopeSubtree, $buttonCond)
                if ($buttons -and $buttons.Count -gt 0) {
                    for ($i = 0; $i -lt $buttons.Count; $i++) {
                        $b = $buttons.Item($i)
                        $n = ""
                        try { $n = $b.Current.Name } catch {}
                        if ($n -and $n -match '(launch|start|re-launch|relaunch)') {
                            $launchButton = $b
                            break
                        }
                    }
                }
                $pollPanelFound = $true
            }

            if (-not $launchButton) {
                Start-Sleep -Milliseconds $stepMs
                $elapsed += $stepMs
            }
        }

        if (-not $launchButton) {
            if ($pollPanelFound) {
                Log "Zoom Polls: Poll panel found but no launchable poll detected."
                if (-not $Silent) { [System.Windows.Forms.MessageBox]::Show($script:form, "Polls panel is open but no 'Launch' or 'Start' button was detected.", "Zoom Polls") | Out-Null }
            }
            else {
                Log "Zoom Polls: Polls panel not detected in UI Automation tree."
                if (-not $Silent) { [System.Windows.Forms.MessageBox]::Show($script:form, "Polls panel not detected in Zoom UI.", "Zoom Polls") | Out-Null }
            }
            return $false
        }

        $invokePattern = $launchButton.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
        if (-not $invokePattern) {
            Log "Zoom Polls: Launch button does not support InvokePattern."
            if (-not $Silent) { [System.Windows.Forms.MessageBox]::Show($script:form, "Unable to click poll Launch/Start button via UI Automation.", "Zoom Polls") | Out-Null }
            return $false
        }

        $invokePattern.Invoke()
        Log "Zoom Polls: Launch/Start button invoked."
        # Schedule an attendance read ~8s after launch (give participants time to answer)
        Invoke-ZoomAttendanceReadDelayed -DelayMs 8000
        return $true
    }
    catch {
        Log "Zoom Polls: error starting first poll: $_"
        if (-not $Silent) { [System.Windows.Forms.MessageBox]::Show($script:form, "Error starting poll:`r`n$_", "Zoom Polls") | Out-Null }
        return $false
    }
}

# Opens the Zoom Polls panel AND launches the first poll entirely in a background STA runspace.
# Polls button goes orange while working; purple when done. No UI thread freeze.
function Start-PollsRunspace {
    param([int]$DelayMs = 0)
    # Skip if a polls operation is already in flight
    if ($script:_pollsAsyncResult -and -not $script:_pollsAsyncResult.IsCompleted) { return }

    # Orange = working
    if ($btnZoomPolls) { $btnZoomPolls.BackColor = [Drawing.Color]::FromArgb(255, 140, 0) }

    $pollsScript = {
        param([int]$InitialDelay)
        try {
            Add-Type -AssemblyName UIAutomationClient -ErrorAction SilentlyContinue
            Add-Type -AssemblyName UIAutomationTypes  -ErrorAction SilentlyContinue

            if ($InitialDelay -gt 0) { Start-Sleep -Milliseconds $InitialDelay }

            $root = [System.Windows.Automation.AutomationElement]::RootElement
            $treeScopeSubtree = [System.Windows.Automation.TreeScope]::Subtree
            $treeScopeChildren = [System.Windows.Automation.TreeScope]::Children
            $nameProp = [System.Windows.Automation.AutomationElement]::NameProperty
            $typeProp = [System.Windows.Automation.AutomationElement]::ControlTypeProperty

            $windowCond = New-Object System.Windows.Automation.PropertyCondition($typeProp, [System.Windows.Automation.ControlType]::Window)
            $buttonCond = New-Object System.Windows.Automation.PropertyCondition($typeProp, [System.Windows.Automation.ControlType]::Button)
            $listItemCond = New-Object System.Windows.Automation.PropertyCondition($typeProp, [System.Windows.Automation.ControlType]::ListItem)
            $textCond = New-Object System.Windows.Automation.PropertyCondition($typeProp, [System.Windows.Automation.ControlType]::Text)
            $paneCond = New-Object System.Windows.Automation.PropertyCondition($typeProp, [System.Windows.Automation.ControlType]::Pane)

            # Step 1: Find Zoom Meeting window
            $nCond = New-Object System.Windows.Automation.PropertyCondition($nameProp, 'Zoom Meeting')
            $zCond = New-Object System.Windows.Automation.AndCondition($nCond, $windowCond)
            $zoomWin = $root.FindFirst($treeScopeSubtree, $zCond)
            if (-not $zoomWin) { return 'no_zoom_window' }

            # Step 2: Click Polls/Quizzes toolbar button
            $pn1 = New-Object System.Windows.Automation.PropertyCondition($nameProp, 'Polls/quizzes')
            $pn2 = New-Object System.Windows.Automation.PropertyCondition($nameProp, 'Polls / Quizzes')
            $pOr = New-Object System.Windows.Automation.OrCondition($pn1, $pn2)
            $pBC = New-Object System.Windows.Automation.AndCondition($buttonCond, $pOr)
            $pBtn = $zoomWin.FindFirst($treeScopeSubtree, $pBC)
            if (-not $pBtn) { return 'no_polls_button' }
            $inv = $pBtn.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
            if (-not $inv) { return 'no_invoke' }
            $inv.Invoke()

            # Step 3: Wait for panel to appear
            Start-Sleep -Milliseconds 900

            # Step 4: Find poll panel (top-level window or embedded pane)
            $pollPanel = $null
            $windows = $root.FindAll($treeScopeChildren, $windowCond)
            if ($windows) {
                for ($i = 0; $i -lt $windows.Count; $i++) {
                    $n = ''; try { $n = $windows.Item($i).Current.Name } catch {}
                    if ($n -match 'poll') { $pollPanel = $windows.Item($i); break }
                }
            }
            if (-not $pollPanel) {
                $panes = $zoomWin.FindAll($treeScopeSubtree, $paneCond)
                if ($panes) {
                    for ($i = 0; $i -lt $panes.Count; $i++) {
                        $n = ''; try { $n = $panes.Item($i).Current.Name } catch {}
                        if ($n -match 'poll') { $pollPanel = $panes.Item($i); break }
                    }
                }
                if (-not $pollPanel) { $pollPanel = $zoomWin }
            }

            # Step 5: Check if poll already running (End/Stop button present)
            $btns = $pollPanel.FindAll($treeScopeSubtree, $buttonCond)
            if ($btns) {
                for ($i = 0; $i -lt $btns.Count; $i++) {
                    $bn = ''; try { $bn = $btns.Item($i).Current.Name } catch {}
                    if ($bn -match '(end poll|stop poll|end quiz|stop quiz)') { return 'already_running' }
                }
            }

            # Step 6: Select first poll item (ListItem, fallback Text)
            $items = $pollPanel.FindAll($treeScopeSubtree, $listItemCond)
            if (-not $items -or $items.Count -eq 0) { $items = $pollPanel.FindAll($treeScopeSubtree, $textCond) }
            if ($items -and $items.Count -gt 0) {
                try {
                    $sel = $items.Item(0).GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)
                    if ($sel) { $sel.Select() }
                }
                catch {}
                Start-Sleep -Milliseconds 600
            }

            # Step 7: Find and click Launch/Start button
            $btns2 = $pollPanel.FindAll($treeScopeSubtree, $buttonCond)
            if ($btns2) {
                for ($i = 0; $i -lt $btns2.Count; $i++) {
                    $bn = ''; try { $bn = $btns2.Item($i).Current.Name } catch {}
                    if ($bn -match '(launch|start|re-launch|relaunch)') {
                        $inv2 = $btns2.Item($i).GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
                        if ($inv2) { $inv2.Invoke(); return 'launched' }
                    }
                }
            }
            return 'no_launch_btn'
        }
        catch { return "error:$_" }
    }

    $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'
    $rs.ThreadOptions = 'ReuseThread'
    $rs.Open()
    $script:_pollsRunspace = $rs

    $ps = [System.Management.Automation.PowerShell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($pollsScript).AddArgument($DelayMs)
    $script:_pollsPS = $ps
    $script:_pollsAsyncResult = $ps.BeginInvoke()

    # 200ms completion-check timer on UI thread
    if ($script:_pollsPollTimer -and -not $script:_pollsPollTimer.IsDisposed) {
        $script:_pollsPollTimer.Stop(); $script:_pollsPollTimer.Dispose()
    }
    $script:_pollsPollTimer = New-Object System.Windows.Forms.Timer
    $script:_pollsPollTimer.Interval = 200
    $script:_pollsPollTimer.Add_Tick({
            try {
                if (-not $script:_pollsAsyncResult -or -not $script:_pollsAsyncResult.IsCompleted) { return }
                $script:_pollsPollTimer.Stop()
                $script:_pollsPollTimer.Dispose()
                $script:_pollsPollTimer = $null

                $status = 'unknown'
                try {
                    $out = $script:_pollsPS.EndInvoke($script:_pollsAsyncResult)
                    if ($out -and $out.Count -gt 0) { $status = "$($out[0])" }
                }
                catch {}
                try { $script:_pollsPS.Dispose() }                                       catch {}
                try { $script:_pollsRunspace.Close(); $script:_pollsRunspace.Dispose() } catch {}
                $script:_pollsRunspace = $null
                $script:_pollsPS = $null

                # Restore Polls button to active purple
                if ($script:btnZoomPolls) { $script:btnZoomPolls.BackColor = [Drawing.Color]::FromArgb(120, 60, 180) }

                switch ($status) {
                    'launched' { Log 'Zoom Polls: launched successfully (background).'; Invoke-ZoomAttendanceReadDelayed -DelayMs 8000 }
                    'already_running' { Log 'Zoom Polls: poll already running (background).'; Invoke-ZoomAttendanceReadDelayed -DelayMs 1000 }
                    'no_zoom_window' { Log 'Zoom Polls: Zoom Meeting window not found.' }
                    'no_polls_button' { Log 'Zoom Polls: Polls/Quizzes button not found in toolbar.' }
                    'no_launch_btn' { Log 'Zoom Polls: panel opened but no Launch/Start button found.' }
                    default { Log "Zoom Polls: runspace result=$status" }
                }
            }
            catch { Log "Polls runspace poll-check error: $_" }
        })
    $script:_pollsPollTimer.Start()
}

# Opens the Zoom Participants panel in an STA background runspace so the UI thread never freezes.
function Start-ParticipantsPanelRunspace {
    param([int]$DelayMs = 0)
    # Skip if already in flight
    if ($script:_participantsAsyncResult -and -not $script:_participantsAsyncResult.IsCompleted) { return }

    $partScript = {
        param([int]$InitialDelay)
        try {
            Add-Type -AssemblyName UIAutomationClient -ErrorAction SilentlyContinue
            Add-Type -AssemblyName UIAutomationTypes  -ErrorAction SilentlyContinue

            if ($InitialDelay -gt 0) { Start-Sleep -Milliseconds $InitialDelay }

            $root = [System.Windows.Automation.AutomationElement]::RootElement
            $scope = [System.Windows.Automation.TreeScope]::Subtree
            $nameProp = [System.Windows.Automation.AutomationElement]::NameProperty
            $typeProp = [System.Windows.Automation.AutomationElement]::ControlTypeProperty
            $winType = [System.Windows.Automation.ControlType]::Window
            $btnType = [System.Windows.Automation.ControlType]::Button

            $nCond = New-Object System.Windows.Automation.PropertyCondition($nameProp, 'Zoom Meeting')
            $tCond = New-Object System.Windows.Automation.PropertyCondition($typeProp, $winType)
            $zCond = New-Object System.Windows.Automation.AndCondition($nCond, $tCond)
            $zoomWin = $root.FindFirst($scope, $zCond)
            if (-not $zoomWin) { return 'no_zoom_window' }

            $bCond = New-Object System.Windows.Automation.PropertyCondition($typeProp, $btnType)
            $allBtns = $zoomWin.FindAll($scope, $bCond)
            $pBtn = $null
            for ($i = 0; $i -lt $allBtns.Count; $i++) {
                $n = ''; try { $n = $allBtns.Item($i).Current.Name } catch {}
                if ($n -like '*Participants*open panel*') { $pBtn = $allBtns.Item($i); break }
            }
            if (-not $pBtn) { return 'already_open' }

            $inv = $pBtn.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
            if (-not $inv) { return 'no_invoke' }
            $inv.Invoke()
            return 'opened'
        }
        catch { return "error:$_" }
    }

    $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'
    $rs.ThreadOptions = 'ReuseThread'
    $rs.Open()
    $script:_participantsRunspace = $rs

    $ps = [System.Management.Automation.PowerShell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($partScript).AddArgument($DelayMs)
    $script:_participantsPS = $ps
    $script:_participantsAsyncResult = $ps.BeginInvoke()

    # 200ms completion-check timer on UI thread
    if ($script:_participantsPollTimer -and -not $script:_participantsPollTimer.IsDisposed) {
        $script:_participantsPollTimer.Stop(); $script:_participantsPollTimer.Dispose()
    }
    $script:_participantsPollTimer = New-Object System.Windows.Forms.Timer
    $script:_participantsPollTimer.Interval = 200
    $script:_participantsPollTimer.Add_Tick({
            try {
                if (-not $script:_participantsAsyncResult -or -not $script:_participantsAsyncResult.IsCompleted) { return }
                $script:_participantsPollTimer.Stop()
                $script:_participantsPollTimer.Dispose()
                $script:_participantsPollTimer = $null

                $status = 'unknown'
                try {
                    $out = $script:_participantsPS.EndInvoke($script:_participantsAsyncResult)
                    if ($out -and $out.Count -gt 0) { $status = "$($out[0])" }
                }
                catch {}
                try { $script:_participantsPS.Dispose() }                                             catch {}
                try { $script:_participantsRunspace.Close(); $script:_participantsRunspace.Dispose() } catch {}
                $script:_participantsRunspace = $null
                $script:_participantsPS = $null

                switch ($status) {
                    'opened' { Log 'Zoom Participants: Participants panel opened.' }
                    'already_open' { Log 'Zoom Participants: panel already open or button not found.' }
                    'no_zoom_window' { Log 'Zoom Participants: Zoom Meeting window not found.' }
                    'no_invoke' { Log 'Zoom Participants: button does not support InvokePattern.' }
                    default { Log "Zoom Participants: runspace result=$status" }
                }
            }
            catch { Log "Participants runspace poll-check error: $_" }
        })
    $script:_participantsPollTimer.Start()
}

# Runs Get-ZoomPollAttendance in an STA background runspace so the UI never freezes.
# Turns the Polls button orange while running, restores purple on completion.
function Start-AttendanceRunspace {
    # Skip if a read is already in flight
    if ($script:_attendanceAsyncResult -and -not $script:_attendanceAsyncResult.IsCompleted) { return }

    # Immediately orange = "reading in progress"
    if ($btnZoomPolls) { $btnZoomPolls.BackColor = [Drawing.Color]::FromArgb(255, 140, 0) }

    # Self-contained script block — no calls to script-level functions so it runs cleanly in an isolated runspace
    $readScript = {
        try {
            Add-Type -AssemblyName UIAutomationClient -ErrorAction SilentlyContinue
            Add-Type -AssemblyName UIAutomationTypes  -ErrorAction SilentlyContinue

            $treeScopeSubtree = [System.Windows.Automation.TreeScope]::Subtree
            $treeScopeChildren = [System.Windows.Automation.TreeScope]::Children
            $nameProp = [System.Windows.Automation.AutomationElement]::NameProperty
            $typeProp = [System.Windows.Automation.AutomationElement]::ControlTypeProperty
            $root = [System.Windows.Automation.AutomationElement]::RootElement

            $windowCond = New-Object System.Windows.Automation.PropertyCondition($typeProp, [System.Windows.Automation.ControlType]::Window)
            $textCond = New-Object System.Windows.Automation.PropertyCondition($typeProp, [System.Windows.Automation.ControlType]::Text)

            # Find poll panel: top-level window first, then embedded pane inside Zoom Meeting window
            $pollPanel = $null
            $windows = $root.FindAll($treeScopeChildren, $windowCond)
            if ($windows) {
                for ($i = 0; $i -lt $windows.Count; $i++) {
                    $n = ''; try { $n = $windows.Item($i).Current.Name } catch {}
                    if ($n -match 'poll') { $pollPanel = $windows.Item($i); break }
                }
            }
            if (-not $pollPanel) {
                $zoomNameCond = New-Object System.Windows.Automation.PropertyCondition($nameProp, 'Zoom Meeting')
                $zoomWinCond = New-Object System.Windows.Automation.AndCondition($windowCond, $zoomNameCond)
                $zoomWin = $root.FindFirst($treeScopeSubtree, $zoomWinCond)
                if ($zoomWin) {
                    $paneCond = New-Object System.Windows.Automation.PropertyCondition($typeProp, [System.Windows.Automation.ControlType]::Pane)
                    $panes = $zoomWin.FindAll($treeScopeSubtree, $paneCond)
                    if ($panes) {
                        for ($i = 0; $i -lt $panes.Count; $i++) {
                            $pn = ''; try { $pn = $panes.Item($i).Current.Name } catch {}
                            if ($pn -match 'poll') { $pollPanel = $panes.Item($i); break }
                        }
                    }
                    if (-not $pollPanel) { $pollPanel = $zoomWin }
                }
            }
            if (-not $pollPanel) { return $null }

            # Collect all non-empty text strings in document order
            $allTextElems = $pollPanel.FindAll($treeScopeSubtree, $textCond)
            $textList = [System.Collections.Generic.List[string]]::new()
            for ($i = 0; $i -lt $allTextElems.Count; $i++) {
                $txt = ''; try { $txt = $allTextElems.Item($i).Current.Name } catch {}
                if ($txt -ne '') { $textList.Add($txt) }
            }

            # "X of Y participated" for responder denominator
            $responded = 0; $totalInvited = 0
            foreach ($t in $textList) {
                if ($t -match '(\d+)\s+of\s+(\d+).*participated') {
                    $responded = [int]$Matches[1]; $totalInvited = [int]$Matches[2]; break
                }
            }

            # Sum (answer-number × vote-count) for every poll option
            $totalAttendance = 0; $anyVoteFound = $false; $resolvedResponded = $responded
            for ($i = 1; $i -lt $textList.Count; $i++) {
                $t = $textList[$i]
                if ($t -match '\((\d+)/(\d+)\)') {
                    $votes = [int]$Matches[1]; $total = [int]$Matches[2]
                    if ($total -gt $totalInvited) { $totalInvited = $total }
                    if ($resolvedResponded -eq 0) { $resolvedResponded = $total }
                    $answerNum = 0
                    if ($textList[$i - 1] -match '(\d+)') { $answerNum = [int]$Matches[1] }
                    if ($votes -gt 0 -and $answerNum -gt 0) {
                        $totalAttendance += $answerNum * $votes; $anyVoteFound = $true
                    }
                }
            }

            if ($anyVoteFound) {
                return [pscustomobject]@{
                    AttendanceAnswer = "$totalAttendance"
                    Responded        = $resolvedResponded
                    Total            = $totalInvited
                }
            }
            return $null
        }
        catch { return $null }
    }

    # Create an STA runspace (UI Automation requires STA thread)
    $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'
    $rs.ThreadOptions = 'ReuseThread'
    $rs.Open()
    $script:_attendanceRunspace = $rs

    $ps = [System.Management.Automation.PowerShell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($readScript)
    $script:_attendancePS = $ps
    $script:_attendanceAsyncResult = $ps.BeginInvoke()

    # 200ms completion-check timer — fires on the UI thread, never blocks it
    if ($script:_attendancePollTimer -and -not $script:_attendancePollTimer.IsDisposed) {
        $script:_attendancePollTimer.Stop(); $script:_attendancePollTimer.Dispose()
    }
    $script:_attendancePollTimer = New-Object System.Windows.Forms.Timer
    $script:_attendancePollTimer.Interval = 200
    $script:_attendancePollTimer.Add_Tick({
            try {
                if (-not $script:_attendanceAsyncResult -or -not $script:_attendanceAsyncResult.IsCompleted) { return }
                $script:_attendancePollTimer.Stop()
                $script:_attendancePollTimer.Dispose()
                $script:_attendancePollTimer = $null

                # Collect result from the runspace
                $result = $null
                try {
                    $out = $script:_attendancePS.EndInvoke($script:_attendanceAsyncResult)
                    if ($out -and $out.Count -gt 0) { $result = $out[0] }
                }
                catch {}
                try { $script:_attendancePS.Dispose() }   catch {}
                try { $script:_attendanceRunspace.Close(); $script:_attendanceRunspace.Dispose() } catch {}
                $script:_attendanceRunspace = $null
                $script:_attendancePS = $null

                # Restore Polls button to active purple
                if ($script:btnZoomPolls) { $script:btnZoomPolls.BackColor = [Drawing.Color]::FromArgb(120, 60, 180) }

                if ($result -and -not [string]::IsNullOrEmpty($result.AttendanceAnswer)) {
                    $script:ZoomAttendanceCount = $result
                    $ts = (Get-Date).ToString('HH:mm')
                    Log "Zoom Attendance: total=$($result.AttendanceAnswer), $($result.Responded)/$($result.Total) responded (at $ts)"
                    if ($script:lblAttendance) {
                        $script:lblAttendance.Text = "Att. $($result.AttendanceAnswer)  -  $ts"
                        $script:lblAttendance.Visible = $true
                    }
                    Start-AttendanceRefreshTimer
                }
                else {
                    Log 'Zoom Attendance: no data found in poll UI'
                }
            }
            catch { Log "Attendance poll-check error: $_" }
        })
    $script:_attendancePollTimer.Start()
}

# Schedules a one-shot timer to read poll attendance after a delay
function Invoke-ZoomAttendanceReadDelayed {
    param([int]$DelayMs = 5000)
    try {
        # Stop/dispose any previous one-shot timer still pending
        if ($script:_attendanceOneShotTimer -and -not $script:_attendanceOneShotTimer.IsDisposed) {
            $script:_attendanceOneShotTimer.Stop()
            $script:_attendanceOneShotTimer.Dispose()
        }
        # PS5 closure fix: use script-scope variable so the tick handler can reference it
        $script:_attendanceOneShotTimer = New-Object System.Windows.Forms.Timer
        $script:_attendanceOneShotTimer.Interval = $DelayMs
        $script:_attendanceOneShotTimer.Add_Tick({
                try {
                    $script:_attendanceOneShotTimer.Stop()
                    $script:_attendanceOneShotTimer.Dispose()
                    $script:_attendanceOneShotTimer = $null
                    Start-AttendanceRunspace
                }
                catch { Log "Attendance timer error: $_" }
            })
        $script:_attendanceOneShotTimer.Start()
    }
    catch {}
}

# Starts (or restarts) the repeating attendance refresh timer (every 5 min)
function Start-AttendanceRefreshTimer {
    try {
        # Don't create a second one if already running
        if ($script:_attendanceRefreshTimer -and -not $script:_attendanceRefreshTimer.IsDisposed) { return }
        $script:_attendanceRefreshTimer = New-Object System.Windows.Forms.Timer
        $script:_attendanceRefreshTimer.Interval = 300000  # 5 minutes
        $script:_attendanceRefreshTimer.Add_Tick({
                try {
                    if (-not $script:_pollsActivated -or -not $script:ZoomInMeeting) {
                        Stop-AttendanceRefreshTimer; return
                    }
                    Start-AttendanceRunspace
                }
                catch { Log "Attendance refresh error: $_" }
            })
        $script:_attendanceRefreshTimer.Start()
        Log "Zoom Attendance: auto-refresh started (every 5 min)"
    }
    catch {}
}

# Stops and disposes all attendance timers and any in-flight background runspace
function Stop-AttendanceRefreshTimer {
    try {
        # Clean up any in-flight polls runspace (open panel + start poll)
        if ($script:_pollsPollTimer -and -not $script:_pollsPollTimer.IsDisposed) {
            $script:_pollsPollTimer.Stop(); $script:_pollsPollTimer.Dispose()
            $script:_pollsPollTimer = $null
        }
        if ($script:_pollsRunspace) {
            try { $script:_pollsRunspace.Close() } catch {}
            try { $script:_pollsRunspace.Dispose() } catch {}
            $script:_pollsRunspace = $null
        }
        if ($script:_attendancePollTimer -and -not $script:_attendancePollTimer.IsDisposed) {
            $script:_attendancePollTimer.Stop()
            $script:_attendancePollTimer.Dispose()
            $script:_attendancePollTimer = $null
        }
        if ($script:_attendanceRunspace) {
            try { $script:_attendanceRunspace.Close() } catch {}
            try { $script:_attendanceRunspace.Dispose() } catch {}
            $script:_attendanceRunspace = $null
        }
        if ($script:_attendanceOneShotTimer -and -not $script:_attendanceOneShotTimer.IsDisposed) {
            $script:_attendanceOneShotTimer.Stop()
            $script:_attendanceOneShotTimer.Dispose()
            $script:_attendanceOneShotTimer = $null
        }
        if ($script:_attendanceRefreshTimer -and -not $script:_attendanceRefreshTimer.IsDisposed) {
            $script:_attendanceRefreshTimer.Stop()
            $script:_attendanceRefreshTimer.Dispose()
        }
        $script:_attendanceRefreshTimer = $null
        # Restore button color if it was left orange
        if ($script:btnZoomPolls) { $script:btnZoomPolls.BackColor = [Drawing.Color]::FromArgb(120, 60, 180) }
    }
    catch {}
}

# Reads attendance count from the open Zoom Polls/Quizzes window via UI Automation
# Returns [pscustomobject]@{Answered=N; Total=M} or $null if not found
function Get-ZoomPollAttendance {
    try {
        $root = Get-ZoomUIAutomationRoot
        if (-not $root) { return $null }

        $treeScopeSubtree = [System.Windows.Automation.TreeScope]::Subtree
        $treeScopeChildren = [System.Windows.Automation.TreeScope]::Children
        $nameProp = [System.Windows.Automation.AutomationElement]::NameProperty
        $typeProp = [System.Windows.Automation.AutomationElement]::ControlTypeProperty
        $windowCond = New-Object System.Windows.Automation.PropertyCondition(
            $typeProp, [System.Windows.Automation.ControlType]::Window)
        $textCond = New-Object System.Windows.Automation.PropertyCondition(
            $typeProp, [System.Windows.Automation.ControlType]::Text)

        # Find the Polls top-level window, or the panel embedded inside Zoom Meeting window
        $pollPanel = $null
        $windows = $root.FindAll($treeScopeChildren, $windowCond)
        if ($windows) {
            for ($i = 0; $i -lt $windows.Count; $i++) {
                $n = ""; try { $n = $windows.Item($i).Current.Name } catch {}
                if ($n -match 'poll') { $pollPanel = $windows.Item($i); break }
            }
        }

        # Fallback: poll panel may be embedded inside the Zoom Meeting window
        if (-not $pollPanel) {
            $zoomNameCond = New-Object System.Windows.Automation.PropertyCondition($nameProp, "Zoom Meeting")
            $zoomWinCond = New-Object System.Windows.Automation.AndCondition($windowCond, $zoomNameCond)
            $zoomWin = $root.FindFirst($treeScopeSubtree, $zoomWinCond)
            if ($zoomWin) {
                $paneCond = New-Object System.Windows.Automation.PropertyCondition(
                    $typeProp, [System.Windows.Automation.ControlType]::Pane)
                $panes = $zoomWin.FindAll($treeScopeSubtree, $paneCond)
                if ($panes) {
                    for ($i = 0; $i -lt $panes.Count; $i++) {
                        $pn = ""; try { $pn = $panes.Item($i).Current.Name } catch {}
                        if ($pn -match 'poll') { $pollPanel = $panes.Item($i); break }
                    }
                }
                if (-not $pollPanel) { $pollPanel = $zoomWin }
            }
        }
        if (-not $pollPanel) { return $null }

        # Collect all non-empty text strings in document order
        $allTextElems = $pollPanel.FindAll($treeScopeSubtree, $textCond)
        $textList = [System.Collections.Generic.List[string]]::new()
        for ($i = 0; $i -lt $allTextElems.Count; $i++) {
            $txt = ""; try { $txt = $allTextElems.Item($i).Current.Name } catch {}
            if ($txt -ne '') { $textList.Add($txt) }
        }
        Log "Get-ZoomPollAttendance: found $($textList.Count) text elements: $($textList -join ' | ')"

        # Find "X of Y (Z%) participated" summary
        $responded = 0; $totalInvited = 0
        foreach ($t in $textList) {
            if ($t -match '(\d+)\s+of\s+(\d+).*participated') {
                $responded = [int]$Matches[1]
                $totalInvited = [int]$Matches[2]
                break
            }
        }

        # Sum all answers: each option label (e.g. "3") × its vote count from "(votes/total) pct%"
        # This gives total people in attendance across all locations
        $totalAttendance = 0; $anyVoteFound = $false; $resolvedResponded = $responded
        for ($i = 1; $i -lt $textList.Count; $i++) {
            $t = $textList[$i]
            if ($t -match '\((\d+)/(\d+)\)') {
                $votes = [int]$Matches[1]
                $total = [int]$Matches[2]
                if ($total -gt $totalInvited) { $totalInvited = $total }
                if ($resolvedResponded -eq 0) { $resolvedResponded = $total }
                $answerLabel = $textList[$i - 1]
                # Parse the answer as a number (handles "7" and "7 or more" etc.)
                $answerNum = 0
                if ($answerLabel -match '(\d+)') { $answerNum = [int]$Matches[1] }
                if ($votes -gt 0 -and $answerNum -gt 0) {
                    $totalAttendance += $answerNum * $votes
                    $anyVoteFound = $true
                    Log "Get-ZoomPollAttendance: option '$answerLabel' x $votes votes = $($answerNum * $votes)"
                }
            }
        }

        if ($anyVoteFound) {
            Log "Get-ZoomPollAttendance: TOTAL attendance=$totalAttendance, $resolvedResponded/$totalInvited responded"
            return [pscustomobject]@{
                AttendanceAnswer = "$totalAttendance"
                Responded        = $resolvedResponded
                Total            = $totalInvited
            }
        }
        return $null
    }
    catch {
        Log "Get-ZoomPollAttendance error: $_"
        return $null
    }
}

function Get-ZoomFocusModeState {
    try {
        $root = Get-ZoomUIAutomationRoot
        if (-not $root) { return $null }

        $treeScope = [System.Windows.Automation.TreeScope]::Subtree
        $nameProp = [System.Windows.Automation.AutomationElement]::NameProperty
        $typeProp = [System.Windows.Automation.AutomationElement]::ControlTypeProperty
        $windowType = [System.Windows.Automation.ControlType]::Window

        $nameCond = New-Object System.Windows.Automation.PropertyCondition($nameProp, "Zoom Meeting")
        $typeCond = New-Object System.Windows.Automation.PropertyCondition($typeProp, $windowType)
        $zoomCond = New-Object System.Windows.Automation.AndCondition($nameCond, $typeCond)

        $zoomWindow = $root.FindFirst($treeScope, $zoomCond)
        if (-not $zoomWindow) { return $null }

        # Open the More / More meeting controls menu so the Focus Mode entry is visible
        $buttonType = [System.Windows.Automation.ControlType]::Button
        $buttonTypeCond = New-Object System.Windows.Automation.PropertyCondition($typeProp, $buttonType)
        $moreNameCond = New-Object System.Windows.Automation.PropertyCondition($nameProp, "More")
        $moreCond = New-Object System.Windows.Automation.AndCondition($buttonTypeCond, $moreNameCond)

        $moreButton = $zoomWindow.FindFirst($treeScope, $moreCond)
        if (-not $moreButton) {
            $menuItemTypeForMore = [System.Windows.Automation.ControlType]::MenuItem
            $miMoreTypeCond = New-Object System.Windows.Automation.PropertyCondition($typeProp, $menuItemTypeForMore)
            $moreMeetingNameCond = New-Object System.Windows.Automation.PropertyCondition($nameProp, "More meeting controls")
            $moreMiCond = New-Object System.Windows.Automation.AndCondition($miMoreTypeCond, $moreMeetingNameCond)
            $moreButton = $zoomWindow.FindFirst($treeScope, $moreMiCond)
        }

        if ($moreButton) {
            try {
                $invokeMore = $moreButton.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
                if ($invokeMore) {
                    $invokeMore.Invoke()
                    Start-Sleep -Milliseconds 300
                }
            }
            catch {}
        }

        $menuItemType = [System.Windows.Automation.ControlType]::MenuItem
        $miTypeCond = New-Object System.Windows.Automation.PropertyCondition($typeProp, $menuItemType)
        $startNameCond = New-Object System.Windows.Automation.PropertyCondition($nameProp, "Start focus mode")
        $stopNameCond = New-Object System.Windows.Automation.PropertyCondition($nameProp, "Stop focus mode")
        $nameAnyCond = New-Object System.Windows.Automation.OrCondition($startNameCond, $stopNameCond)
        $focusCond = New-Object System.Windows.Automation.AndCondition($miTypeCond, $nameAnyCond)

        $focusItem = $null
        $timeoutMs = 2000
        $stepMs = 250
        $elapsed = 0
        while (-not $focusItem -and $elapsed -lt $timeoutMs) {
            $focusItem = $root.FindFirst($treeScope, $focusCond)
            if (-not $focusItem) {
                Start-Sleep -Milliseconds $stepMs
                $elapsed += $stepMs
            }
        }

        if (-not $focusItem) { return $null }

        $name = ""
        try { $name = $focusItem.Current.Name } catch {}

        # Try to close the menu so we don't leave it hanging open
        try { [System.Windows.Forms.SendKeys]::SendWait("{ESC}") } catch {}

        if ([string]::IsNullOrWhiteSpace($name)) { return $null }
        if ($name -eq "Stop focus mode") { return $true }
        if ($name -eq "Start focus mode") { return $false }

        return $null
    }
    catch {
        Log "Get-ZoomFocusModeState error: $_"
        return $null
    }
}

function Get-ZoomMeetingParticipantInfo {
    param([string]$displayName)

    $result = @{
        MeetingRunning   = $false
        ParticipantCount = 0
        IsHost           = $false
    }

    try {
        $root = Get-ZoomUIAutomationRoot
        if (-not $root) { return $result }

        $treeScope = [System.Windows.Automation.TreeScope]::Subtree
        $nameProp = [System.Windows.Automation.AutomationElement]::NameProperty
        $typeProp = [System.Windows.Automation.AutomationElement]::ControlTypeProperty
        $windowType = [System.Windows.Automation.ControlType]::Window

        $nameCond = New-Object System.Windows.Automation.PropertyCondition($nameProp, "Zoom Meeting")
        $typeCond = New-Object System.Windows.Automation.PropertyCondition($typeProp, $windowType)
        $zoomCond = New-Object System.Windows.Automation.AndCondition($nameCond, $typeCond)

        $zoomWindow = $root.FindFirst($treeScope, $zoomCond)
        if (-not $zoomWindow) { return $result }

        $result.MeetingRunning = $true

        $paneControlType = [System.Windows.Automation.ControlType]::Pane
        $paneCond = New-Object System.Windows.Automation.PropertyCondition($typeProp, $paneControlType)

        $candidates = $zoomWindow.FindAll($treeScope, $paneCond)
        if (-not $candidates -or $candidates.Count -eq 0) { return $result }

        $participantCount = 0
        $isHost = $false

        for ($i = 0; $i -lt $candidates.Count; $i++) {
            $el = $candidates.Item($i)
            $name = ""
            try { $name = $el.Current.Name } catch {}
            if ([string]::IsNullOrWhiteSpace($name)) { continue }

            # Heuristic: participant panes expose audio/video status in the name
            if ($name -match '(Computer audio|Phone audio|Video on|Video off)') {
                $participantCount++

                if (-not $isHost -and $displayName -and $name -like "*${displayName}*" -and $name -like "*Host*") {
                    $isHost = $true
                }
            }
        }

        $result.ParticipantCount = $participantCount
        $result.IsHost = $isHost
        return $result
    }
    catch {
        Log "Get-ZoomMeetingParticipantInfo error: $_"
        return $result
    }
}

function Update-ZoomFocusButtonVisual {
    param([bool]$isOn)

    try {
        $script:ZoomFocusModeOn = [bool]$isOn

        if ($btnZoomFocus) {
            if ($isOn) {
                $btnZoomFocus.BackColor = [System.Drawing.Color]::FromArgb(0, 192, 0)
                $btnZoomFocus.ForeColor = [System.Drawing.Color]::Black
            }
            else {
                $btnZoomFocus.BackColor = [System.Drawing.Color]::FromArgb(128, 128, 128)
                $btnZoomFocus.ForeColor = [System.Drawing.Color]::White
            }
        }

        if ($lblZoomFocusStatus) {
            if ($isOn) {
                $lblZoomFocusStatus.Text = "Focus Mode Active"
                $lblZoomFocusStatus.ForeColor = [System.Drawing.Color]::FromArgb(0, 192, 0)
            }
            else {
                $lblZoomFocusStatus.Text = "Focus Mode Off"
                $lblZoomFocusStatus.ForeColor = [System.Drawing.Color]::LightGray
            }
        }
    }
    catch {}
}

function Zoom-ToggleFocusMode {
    try {
        # Cooldown guard: after stopping Focus Mode, Zoom re-disables it for ~60s.
        if (-not $script:ZoomFocusModeOn -and $script:ZoomFocusModeStoppedAt) {
            $secondsElapsed = ([DateTime]::Now - $script:ZoomFocusModeStoppedAt).TotalSeconds
            if ($secondsElapsed -lt 58) {
                $remaining = [int](58 - $secondsElapsed)
                Log "Focus Mode: cooldown active - Zoom needs ~${remaining}s more before focus can be re-enabled."
                if ($lblZoomFocusStatus) {
                    $lblZoomFocusStatus.Text = "Wait ${remaining}s"
                    $lblZoomFocusStatus.ForeColor = [System.Drawing.Color]::Orange
                }
                return $false
            }
        }

        $root = Get-ZoomUIAutomationRoot
        if (-not $root) { Log "Focus Mode: UI Automation not available."; return $false }

        $treeScope = [System.Windows.Automation.TreeScope]::Subtree
        $nameProp = [System.Windows.Automation.AutomationElement]::NameProperty
        $typeProp = [System.Windows.Automation.AutomationElement]::ControlTypeProperty
        $windowType = [System.Windows.Automation.ControlType]::Window

        $nameCond = New-Object System.Windows.Automation.PropertyCondition($nameProp, "Zoom Meeting")
        $typeCond = New-Object System.Windows.Automation.PropertyCondition($typeProp, $windowType)
        $zoomCond = New-Object System.Windows.Automation.AndCondition($nameCond, $typeCond)
        $zoomWindow = $root.FindFirst($treeScope, $zoomCond)
        if (-not $zoomWindow) { Log "Focus Mode: Zoom meeting window not found."; return $false }

        $buttonType = [System.Windows.Automation.ControlType]::Button
        $menuItemType = [System.Windows.Automation.ControlType]::MenuItem

        $buttonTypeCond = New-Object System.Windows.Automation.PropertyCondition($typeProp, $buttonType)
        $moreNameCond = New-Object System.Windows.Automation.PropertyCondition($nameProp, "More")
        $moreCond = New-Object System.Windows.Automation.AndCondition($buttonTypeCond, $moreNameCond)
        $moreButton = $zoomWindow.FindFirst($treeScope, $moreCond)

        # Fallback: 'More meeting controls' MenuItem for newer Zoom builds
        if (-not $moreButton) {
            $miMoreTypeCond = New-Object System.Windows.Automation.PropertyCondition($typeProp, $menuItemType)
            $moreMeetingNameCond = New-Object System.Windows.Automation.PropertyCondition($nameProp, "More meeting controls")
            $moreMiCond = New-Object System.Windows.Automation.AndCondition($miMoreTypeCond, $moreMeetingNameCond)
            $moreButton = $zoomWindow.FindFirst($treeScope, $moreMiCond)
        }

        if ($moreButton) {
            try {
                $invokeMore = $moreButton.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
                if ($invokeMore) { $invokeMore.Invoke(); Start-Sleep -Milliseconds 200 }
            }
            catch {}
        }

        $miTypeCond = New-Object System.Windows.Automation.PropertyCondition($typeProp, $menuItemType)
        $startNameCond = New-Object System.Windows.Automation.PropertyCondition($nameProp, "Start focus mode")
        $stopNameCond = New-Object System.Windows.Automation.PropertyCondition($nameProp, "Stop focus mode")
        $nameAnyCond = New-Object System.Windows.Automation.OrCondition($startNameCond, $stopNameCond)
        $focusCond = New-Object System.Windows.Automation.AndCondition($miTypeCond, $nameAnyCond)

        # Search from root: Zoom opens the submenu in a separate window on some builds
        $focusItem = $null
        $elapsed = 0
        while (-not $focusItem -and $elapsed -lt 1000) {
            $focusItem = $root.FindFirst($treeScope, $focusCond)
            if (-not $focusItem) { Start-Sleep -Milliseconds 100; $elapsed += 100 }
        }
        if (-not $focusItem) { Log "Focus Mode: Start/Stop focus mode menu item not found."; return $false }

        # Position cursor over the item (BoundingRectangle gives physical screen coords)
        try {
            $rect = $focusItem.Current.BoundingRectangle
            if ($rect -and -not $rect.IsEmpty) {
                $cx = [int](($rect.Left + $rect.Right) / 2)
                $cy = [int](($rect.Top + $rect.Bottom) / 2)
                [System.Windows.Forms.Cursor]::Position = [System.Drawing.Point]::new($cx, $cy)
            }
        }
        catch { Log "Focus Mode: could not position cursor on menu item: $_" }

        $targetOn = -not $script:ZoomFocusModeOn

        # Click via mouse_event -- InvokePattern/SetFocus both fail on this menu item
        try {
            Start-Sleep -Milliseconds 50
            Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices;
public class MouseClick {
    [DllImport("user32.dll")]
    public static extern void mouse_event(int dwFlags, int dx, int dy, int dwData, int dwExtraInfo);
}
'@ -ErrorAction SilentlyContinue
            [MouseClick]::mouse_event(0x02, 0, 0, 0, 0)
            [MouseClick]::mouse_event(0x04, 0, 0, 0, 0)
            Log "Focus Mode: clicked '$($focusItem.Current.Name)' via mouse_event."
        }
        catch { Log "Focus Mode: mouse click failed: $_" }

        # Record stop time for cooldown guard
        if (-not $targetOn) { $script:ZoomFocusModeStoppedAt = [DateTime]::Now }

        Update-ZoomFocusButtonVisual $targetOn
        Log "Focus Mode: Status updated to $(if ($targetOn) { 'ON' } else { 'OFF' })"
        return $true
    }
    catch {
        Log "Focus Mode: error toggling focus mode: $_"
        return $false
    }
}

# Runs Zoom-ToggleFocusMode in a background STA runspace so the UI thread never freezes.
# Called from both the Focus button click handler and the countdown-timer auto path.
function Start-FocusModeRunspace {
    param([switch]$FromAutoTimer)

    # Guard: skip if already in flight
    if ($script:_focusAsyncResult -and -not $script:_focusAsyncResult.IsCompleted) {
        Log "Focus Mode: runspace already in flight, skipping"
        return
    }

    if (-not $script:UIAutomationAvailable) {
        Log "Focus Mode: UI Automation not available"
        return
    }

    # Cooldown check (fast, on UI thread – no UIA calls)
    if (-not $script:ZoomFocusModeOn -and $script:ZoomFocusModeStoppedAt) {
        $secsElapsed = ([DateTime]::Now - $script:ZoomFocusModeStoppedAt).TotalSeconds
        if ($secsElapsed -lt 58) {
            $remaining = [int](58 - $secsElapsed)
            Log "Focus Mode: cooldown active - ~${remaining}s before Zoom re-enables it."
            if ($lblZoomFocusStatus) {
                $lblZoomFocusStatus.Text = "Wait ${remaining}s"
                $lblZoomFocusStatus.ForeColor = [System.Drawing.Color]::Orange
            }
            return
        }
    }

    $targetOn = -not $script:ZoomFocusModeOn
    $script:_focusModeFromAutoTimer = [bool]$FromAutoTimer

    # Immediate visual feedback
    if ($btnZoomFocus) {
        $btnZoomFocus.Enabled = $false
        $btnZoomFocus.Text = "Working..."
        $btnZoomFocus.BackColor = [System.Drawing.Color]::FromArgb(255, 165, 0)
    }
    if ($lblZoomFocusStatus) {
        $lblZoomFocusStatus.Text = "Processing Focus Mode..."
        $lblZoomFocusStatus.ForeColor = [System.Drawing.Color]::FromArgb(255, 165, 0)
    }

    $focusScript = {
        param($TargetOn)
        $result = @{ Success = $false; NewFocusOn = $TargetOn; Message = "" }
        try {
            Add-Type -AssemblyName UIAutomationClient -ErrorAction Stop
            Add-Type -AssemblyName UIAutomationTypes -ErrorAction Stop

            $root = [System.Windows.Automation.AutomationElement]::RootElement
            if (-not $root) { $result.Message = "No UIA root"; return $result }

            $treeScope = [System.Windows.Automation.TreeScope]::Subtree
            $nameProp = [System.Windows.Automation.AutomationElement]::NameProperty
            $typeProp = [System.Windows.Automation.AutomationElement]::ControlTypeProperty
            $windowType = [System.Windows.Automation.ControlType]::Window
            $btnType = [System.Windows.Automation.ControlType]::Button
            $miType = [System.Windows.Automation.ControlType]::MenuItem

            # Conditions for 'Start/Stop focus mode' menu item
            $miTypeCond = New-Object System.Windows.Automation.PropertyCondition($typeProp, $miType)
            $startCond = New-Object System.Windows.Automation.PropertyCondition($nameProp, 'Start focus mode')
            $stopCond = New-Object System.Windows.Automation.PropertyCondition($nameProp, 'Stop focus mode')
            $nameAnyCond = New-Object System.Windows.Automation.OrCondition($startCond, $stopCond)
            $focusCond = New-Object System.Windows.Automation.AndCondition($miTypeCond, $nameAnyCond)

            # ── Step 1: find Zoom Meeting window (scoped by name, fast) ──
            $winNameCond = New-Object System.Windows.Automation.PropertyCondition($nameProp, 'Zoom Meeting')
            $winTypeCond = New-Object System.Windows.Automation.PropertyCondition($typeProp, $windowType)
            $zoomCond = New-Object System.Windows.Automation.AndCondition($winNameCond, $winTypeCond)
            $zoomWindow = $root.FindFirst($treeScope, $zoomCond)
            if (-not $zoomWindow) { $result.Message = 'Zoom meeting window not found'; return $result }
            $zoomPid = $zoomWindow.Current.ProcessId

            # ── Step 2: find 'More meeting controls' INSIDE the Zoom window (scoped = fast) ──
            $moreNameCond = New-Object System.Windows.Automation.PropertyCondition($nameProp, 'More meeting controls')
            $moreMiCond = New-Object System.Windows.Automation.AndCondition($miTypeCond, $moreNameCond)
            $moreButton = $zoomWindow.FindFirst($treeScope, $moreMiCond)
            if (-not $moreButton) {
                # Fallback: button named 'More'
                $btnTypeCond = New-Object System.Windows.Automation.PropertyCondition($typeProp, $btnType)
                $moreBtnName = New-Object System.Windows.Automation.PropertyCondition($nameProp, 'More')
                $moreBtnCond = New-Object System.Windows.Automation.AndCondition($btnTypeCond, $moreBtnName)
                $moreButton = $zoomWindow.FindFirst($treeScope, $moreBtnCond)
            }
            if (-not $moreButton) { $result.Message = 'More meeting controls not found inside Zoom window'; return $result }

            # ── Step 3: invoke the More button (InvokePattern) to open the popup ──
            try {
                $invMore = $moreButton.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
                if ($invMore) { $invMore.Invoke() }
                else { $result.Message = 'More button has no InvokePattern'; return $result }
            }
            catch { $result.Message = "Could not invoke More button: $_"; return $result }

            # ── Step 4: wait up to 8 seconds for the popup menu item ──
            # The popup appears as a Zoom-owned top-level window outside the main window hierarchy.
            # We scan only Zoom-owned direct children of root (fast) rather than the whole desktop tree.
            $focusItem = $null
            $elapsed = 0
            $trueCond = [System.Windows.Automation.Condition]::TrueCondition
            while (-not $focusItem -and $elapsed -lt 8000) {
                Start-Sleep -Milliseconds 200
                $elapsed += 200

                # Check inside the Zoom window first
                $focusItem = $zoomWindow.FindFirst($treeScope, $focusCond)
                if ($focusItem) { break }

                # Then check Zoom-owned sibling (popup) windows
                try {
                    $topLevel = $root.FindAll([System.Windows.Automation.TreeScope]::Children, $trueCond)
                    for ($i = 0; $i -lt $topLevel.Count; $i++) {
                        $el = $topLevel.Item($i)
                        try {
                            if ($el.Current.ProcessId -eq $zoomPid) {
                                $fi = $el.FindFirst($treeScope, $focusCond)
                                if ($fi) { $focusItem = $fi; break }
                            }
                        }
                        catch {}
                    }
                }
                catch {}
            }
            if (-not $focusItem) { $result.Message = "Focus mode menu item not found after ${elapsed}ms"; return $result }

            # ── Step 5: wait briefly for the item to become enabled (popup may still be rendering) ──
            $enableWait = 0
            while ($enableWait -lt 1500) {
                try { if ($focusItem.Current.IsEnabled) { break } } catch { break }
                Start-Sleep -Milliseconds 150
                $enableWait += 150
            }

            # ── Step 6: try InvokePattern, fall back to physical mouse click at BoundingRectangle ──
            $invoked = $false
            try {
                $inv = $focusItem.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
                if ($inv) {
                    $inv.Invoke()
                    $invoked = $true
                    $result.Message = "Invoked '$($focusItem.Current.Name)' via InvokePattern (${elapsed}ms wait, ${enableWait}ms enable-wait)"
                    $result.Success = $true
                }
            }
            catch {}

            if (-not $invoked) {
                # Fallback: physical click at the menu item's screen coordinates
                try {
                    $rect = $focusItem.Current.BoundingRectangle
                    if ($rect -and -not $rect.IsEmpty) {
                        $cx = [int](($rect.Left + $rect.Right) / 2)
                        $cy = [int](($rect.Top + $rect.Bottom) / 2)
                        Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices;
public class FocusModeClick {
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(int f, int x, int y, int d, int e);
}
'@ -ErrorAction SilentlyContinue
                        [FocusModeClick]::SetCursorPos($cx, $cy)
                        Start-Sleep -Milliseconds 80
                        [FocusModeClick]::mouse_event(0x02, 0, 0, 0, 0)  # MOUSEEVENTF_LEFTDOWN
                        [FocusModeClick]::mouse_event(0x04, 0, 0, 0, 0)  # MOUSEEVENTF_LEFTUP
                        $result.Message = "Clicked '$($focusItem.Current.Name)' via mouse at ($cx,$cy) - InvokePattern was nonenabled"
                        $result.Success = $true
                        $invoked = $true
                    }
                    else { $result.Message = 'Fallback click failed: bounding rect is empty' }
                }
                catch { $result.Message = "Fallback click failed: $_" }
            }
        }
        catch {
            $result.Message = "Error: $_"
        }
        return $result
    }

    $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $rs.ApartmentState = [System.Threading.ApartmentState]::STA
    $rs.ThreadOptions = [System.Management.Automation.Runspaces.PSThreadOptions]::UseNewThread
    $rs.Open()
    $ps = [System.Management.Automation.PowerShell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($focusScript)
    [void]$ps.AddParameter('TargetOn', $targetOn)
    $script:_focusRunspace = $rs
    $script:_focusPS = $ps
    $script:_focusAsyncResult = $ps.BeginInvoke()

    # Dispose old poll timer if any
    if ($script:_focusPollTimer -and -not $script:_focusPollTimer.IsDisposed) {
        try { $script:_focusPollTimer.Stop(); $script:_focusPollTimer.Dispose() } catch {}
    }
    $script:_focusPollStartTime = [DateTime]::Now
    $script:_focusPollTimer = New-Object System.Windows.Forms.Timer
    $script:_focusPollTimer.Interval = 200
    $script:_focusPollTimer.Add_Tick({
            if (-not $script:_focusAsyncResult.IsCompleted) {
                # Timeout guard: if runspace hangs beyond 25 seconds, abort and restore button
                if (([DateTime]::Now - $script:_focusPollStartTime).TotalSeconds -lt 25) { return }
                Log 'Focus Mode: runspace timed out (>25s) - aborting'
                try { $script:_focusPollTimer.Stop(); $script:_focusPollTimer.Dispose() } catch {}
                $script:_focusPollTimer = $null
                try { $script:_focusRunspace.Close() } catch {}
                try { $script:_focusPS.Dispose() } catch {}
                try { $script:_focusRunspace.Dispose() } catch {}
                $script:_focusRunspace = $null; $script:_focusPS = $null; $script:_focusAsyncResult = $null
                if ($btnZoomFocus) { $btnZoomFocus.Enabled = $true; $btnZoomFocus.Text = 'Focus' }
                Update-ZoomFocusButtonVisual $script:ZoomFocusModeOn
                if ($lblZoomFocusStatus) { $lblZoomFocusStatus.Text = 'Focus: timed out - retry (took >25s)'; $lblZoomFocusStatus.ForeColor = [System.Drawing.Color]::Orange }
                return
            }
            try { $script:_focusPollTimer.Stop(); $script:_focusPollTimer.Dispose() } catch {}
            $script:_focusPollTimer = $null
            try {
                $results = $script:_focusPS.EndInvoke($script:_focusAsyncResult)
                $r = if ($results -and $results.Count -gt 0) { $results[0] } else { $null }
                if ($r -and $r.Success) {
                    Log "Focus Mode: $($r.Message)"
                    $newFocusOn = [bool]$r.NewFocusOn
                    if (-not $newFocusOn) { $script:ZoomFocusModeStoppedAt = [DateTime]::Now }
                    $script:ZoomFocusModeOn = $newFocusOn
                    Update-ZoomFocusButtonVisual $newFocusOn
                    if ($script:_focusModeFromAutoTimer) {
                        $script:_zoomFocusToggledThisMeeting = $true
                    }
                }
                else {
                    $msg = if ($r -and $r.Message) { $r.Message } else { 'null result' }
                    Log "Focus Mode: failed - $msg"
                    Update-ZoomFocusButtonVisual $script:ZoomFocusModeOn
                    if ($lblZoomFocusStatus -and $lblZoomFocusStatus.Text -notmatch '^Wait \d') {
                        $lblZoomFocusStatus.Text = "Focus Mode Failed"
                        $lblZoomFocusStatus.ForeColor = [System.Drawing.Color]::Red
                    }
                }
            }
            catch {
                Log "Focus Mode poll-check error: $_"
            }
            finally {
                try { $script:_focusPS.Dispose() } catch {}
                try { $script:_focusRunspace.Close(); $script:_focusRunspace.Dispose() } catch {}
                $script:_focusPS = $null
                $script:_focusRunspace = $null
                $script:_focusAsyncResult = $null
                if ($btnZoomFocus) { $btnZoomFocus.Enabled = $true; $btnZoomFocus.Text = "Focus" }
            }
        })
    $script:_focusPollTimer.Start()
}

# =========================
# === MEETING REMINDERS ===
# =========================
if (-not $script:_ActiveReminders) { $script:_ActiveReminders = @{} }

function New-FlashingReminderForm {
    param([string]$title, [string]$message)

    $f = New-Object System.Windows.Forms.Form
    $f.Text = $title
    $f.StartPosition = 'Manual'
    $f.Size = [System.Drawing.Size]::new(640, 420)
    $f.TopMost = $true
    # Anchor near the main form so it won't hide behind a TopMost Zoom window
    try {
        $fx = $script:form.Location.X
        $fy = $script:form.Location.Y + $script:form.Height + 5
        $f.Location = [System.Drawing.Point]::new($fx, $fy)
    }
    catch {
        try { $f.Location = [System.Drawing.Point]::new($script:form.Location.X, $script:form.Location.Y + 5) } catch {}
    }
    $f.FormBorderStyle = 'FixedDialog'
    $f.MaximizeBox = $false; $f.MinimizeBox = $false
    $f.BackColor = [System.Drawing.Color]::Yellow

    $tb = New-Object System.Windows.Forms.TextBox
    $tb.Multiline = $true
    $tb.ReadOnly = $true
    $tb.ScrollBars = 'Vertical'
    $tb.Font = New-Object System.Drawing.Font("Segoe UI", 11)
    $tb.Text = $message
    $tb.BorderStyle = 'None'
    $tb.Location = [System.Drawing.Point]::new(14, 14)
    $tb.Size = [System.Drawing.Size]::new(($f.ClientSize.Width - 28), 360)
    $tb.TabStop = $false
    $tb.HideSelection = $true
    $tb.SelectionStart = 0; $tb.SelectionLength = 0
    $tb.Add_GotFocus({ $this.SelectionLength = 0 })
    $f.Controls.Add($tb)

    $t = New-Object System.Windows.Forms.Timer
    $t.Interval = 450
    $t.Tag = @{ form = $f; toggle = $true }
    $f.Tag = @{ timer = $t; textbox = $tb }

    $t.Add_Tick({
            param($src, $e)
            try {
                $info = $src.Tag
                if (-not $info) { return }
                $frm = $info.form
                if (-not $frm -or $frm.IsDisposed) { $src.Stop(); return }
                $toggle = -not [bool]$info.toggle
                $info['toggle'] = $toggle
                $src.Tag = $info
                if ($toggle) { $frm.BackColor = [System.Drawing.Color]::Yellow }
                else { $frm.BackColor = [System.Drawing.SystemColors]::ControlLight }
            }
            catch {}
        })

    $f.Add_Shown({
            param($src, $e)
            try {
                $finfo = $src.Tag
                if ($finfo -and $finfo.timer) { $finfo.timer.Start() }
                if ($finfo -and $finfo.textbox) { try { $finfo.textbox.SelectionLength = 0 } catch {} }
                if ($finfo -and $finfo.auto) { try { $finfo.auto.Start() } catch {} }
            }
            catch {}
        })
    $f.Add_FormClosed({
            param($src, $e)
            try {
                $finfo = $src.Tag
                if ($finfo -and $finfo.timer) { $finfo.timer.Stop() }
                if ($finfo -and $finfo.auto) { $finfo.auto.Stop() }
                $k = $finfo.key
                if ($k -and $script:_ActiveReminders.Contains($k)) {
                    $st = $script:_ActiveReminders[$k]
                    $st['dismissed'] = $true
                    $st['form'] = $null
                    $script:_ActiveReminders[$k] = $st
                }
            }
            catch {}
        })
    return $f
}

function Show-ZoomReminderPopup {
    param([datetime]$meetingStart, [int]$reminderNum = 1)

    $key = $meetingStart.ToString('yyyyMMddHHmm') + "_R$reminderNum"
    if ($script:_ActiveReminders.Contains($key)) {
        $st = $script:_ActiveReminders[$key]
        if ($st -and $st.shown) { return }
    }

    $msg = if ($reminderNum -eq 1) { [string]$script:Cfg.Reminders.Message } else { [string]$script:Cfg.Reminders.Message2 }
    $title = if ($reminderNum -eq 1) { "Zoom Settings Reminder" } else { "Meeting Reminder #2" }
    $frm = New-FlashingReminderForm -title $title -message $msg

    $auto = New-Object System.Windows.Forms.Timer
    $auto.Interval = 20000
    $auto.Tag = @{ form = $frm; key = $key }
    $auto.Add_Tick({
            param($src, $e)
            try {
                $info = $src.Tag
                $frm = $info.form
                if ($frm -and -not $frm.IsDisposed) { $frm.Close() }
                $src.Stop()
            }
            catch {}
        })

    $tinfo = $frm.Tag
    $tinfo['key'] = $key
    $tinfo['auto'] = $auto
    $frm.Tag = $tinfo

    try { $frm.Show() | Out-Null } catch {}
    $script:_ActiveReminders[$key] = @{ shown = $true; dismissed = $false; form = $frm }
}

function Close-ReminderIfDue {
    param([datetime]$meetingStart, [int]$secRemaining)
    $key = $meetingStart.ToString('yyyyMMddHHmm')
    if (-not $script:_ActiveReminders.Contains($key)) { return }
    if ($secRemaining -le 5) {
        try {
            $st = $script:_ActiveReminders[$key]
            $f = $st.form
            if ($f -and -not $f.IsDisposed) { $f.Close() }
            $st['dismissed'] = $true
            $st['form'] = $null
            $script:_ActiveReminders[$key] = $st
        }
        catch {}
    }
}
function Dismiss-AllReminders {
    foreach ($k in @($script:_ActiveReminders.Keys)) {
        try {
            $st = $script:_ActiveReminders[$k]
            $f = $st.form
            if ($f -and -not $f.IsDisposed) { $f.Close() }
            $st['dismissed'] = $true
            $st['form'] = $null
            $script:_ActiveReminders[$k] = $st
        }
        catch {}
    }
}

# ---- XR Family Mixer (ping + OSC) ----
$XR_SNAPSHOT_PATH = "/-snap/load"

# X Air MAC address prefixes (Behringer/Music Group)
$XR_MAC_PREFIXES = @('fc-4d-d4', 'a0-99-9b', '00-1e-37', 'fc:4d:d4', 'a0:99:9b', '00:1e:37')

function Find-XAirByARP {
    try {
        # Populate ARP table by pinging local subnet
        $adapter = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and $_.InterfaceDescription -notmatch 'Virtual|Loopback' } | Select-Object -First 1
        if ($adapter) {
            $ip = Get-NetIPAddress -InterfaceIndex $adapter.InterfaceIndex -AddressFamily IPv4 | Select-Object -First 1
            if ($ip) {
                $subnet = $ip.IPAddress.Substring(0, $ip.IPAddress.LastIndexOf('.'))
                # Ping a few common addresses to populate ARP
                1..10 | ForEach-Object { $null = Test-Connection "$subnet.$_" -Count 1 -Quiet -ErrorAction SilentlyContinue }
                100, 200, 222 | ForEach-Object { $null = Test-Connection "$subnet.$_" -Count 1 -Quiet -ErrorAction SilentlyContinue }
                Start-Sleep -Milliseconds 500
            }
        }

        # Parse ARP table with better parsing
        $arp = arp -a
        foreach ($line in $arp) {
            # Match IP address first
            if ($line -match '(\d+\.\d+\.\d+\.\d+)\s+([0-9a-fA-F\-:]+)') {
                $foundIp = $matches[1]
                $mac = $matches[2].ToLower()
                
                # Check against known prefixes
                foreach ($prefix in $XR_MAC_PREFIXES) {
                    if ($mac -like "$prefix*") {
                        return $foundIp
                    }
                }
            }
        }
    }
    catch { }
    return $null
}

function Find-XAirBySubnetScan {
    param([string]$subnet)
    
    if ([string]::IsNullOrWhiteSpace($subnet)) {
        # Auto-detect subnet from active adapter
        try {
            $adapter = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and $_.InterfaceDescription -notmatch 'Virtual|Loopback' } | Select-Object -First 1
            if ($adapter) {
                $ip = Get-NetIPAddress -InterfaceIndex $adapter.InterfaceIndex -AddressFamily IPv4 | Select-Object -First 1
                if ($ip) {
                    $subnet = $ip.IPAddress.Substring(0, $ip.IPAddress.LastIndexOf('.'))
                }
            }
        }
        catch { return $null }
    }
    
    if ([string]::IsNullOrWhiteSpace($subnet)) { return $null }
    
    try {
        # Expanded list of common X Air addresses
        $commonHosts = @(222, 1, 2, 3, 10, 11, 20, 50, 100, 101, 150, 200)
        foreach ($hostIP in $commonHosts) {
            $testIp = "$subnet.$hostIP"
            try {
                # Test connection with very short timeout
                if (Test-Connection $testIp -Count 1 -Quiet -ErrorAction SilentlyContinue) {
                    # Device responds - try UDP port 10024 (X Air OSC port)
                    $udp = New-Object System.Net.Sockets.UdpClient
                    $udp.Client.ReceiveTimeout = 200
                    $udp.Client.SendTimeout = 200
                    try {
                        $udp.Connect($testIp, 10024)
                        # If connection succeeds, likely an X Air
                        $udp.Close()
                        return $testIp
                    }
                    catch {
                        $udp.Close()
                    }
                }
            }
            catch { }
        }
        
        # If nothing found in common addresses, try full sweep (faster method)
        $jobs = @()
        1..254 | ForEach-Object {
            $testIp = "$subnet.$_"
            if ($commonHosts -notcontains $_) {
                $jobs += Start-Job -ScriptBlock {
                    param($ip)
                    if (Test-Connection $ip -Count 1 -Quiet -ErrorAction SilentlyContinue) {
                        try {
                            $udp = New-Object System.Net.Sockets.UdpClient
                            $udp.Client.ReceiveTimeout = 200
                            $udp.Connect($ip, 10024)
                            $udp.Close()
                            return $ip
                        }
                        catch { }
                    }
                } -ArgumentList $testIp
            }
        }
        
        # Wait max 3 seconds for jobs
        $found = $jobs | Wait-Job -Timeout 3 | Receive-Job
        $jobs | Remove-Job -Force
        
        if ($found) {
            return ($found | Select-Object -First 1)
        }
    }
    catch { }
    return $null
}





# Fast broadcast discovery — sends OSC to whole subnet, mixer replies with its IP.
# Returns IP string within ~2 s, or $null if no mixer answers.
function Find-XAirByBroadcast {
    param(
        [int]$TimeoutMs = 2000,
        [scriptblock]$ProgressCallback = $null,
        [ref]$CancelToken = $null
    )
    $udp = $null
    try {
        $udp = New-Object System.Net.Sockets.UdpClient 0   # bind to OS-assigned local port
        $udp.EnableBroadcast = $true
        $udp.Client.ReceiveTimeout = 100   # short per-poll so we can loop & DoEvents

        # OSC /info  (12 bytes) — standard X-Air info request, port 10024
        $oscInfo = [byte[]](0x2F, 0x69, 0x6E, 0x66, 0x6F, 0x00, 0x00, 0x00, 0x2C, 0x00, 0x00, 0x00)
        # OSC /xinfo (12 bytes) — X32-style discovery, port 10023
        $oscXinfo = [byte[]](0x2F, 0x78, 0x69, 0x6E, 0x66, 0x6F, 0x00, 0x00, 0x2C, 0x00, 0x00, 0x00)

        $ep24 = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Broadcast, 10024)
        $ep23 = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Broadcast, 10023)
        try { [void]$udp.Send($oscInfo, $oscInfo.Length, $ep24) } catch {}
        try { [void]$udp.Send($oscXinfo, $oscXinfo.Length, $ep23) } catch {}

        if ($ProgressCallback) { & $ProgressCallback '255.255.255.255 (broadcast)' 0 }

        $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
        while ((Get-Date) -lt $deadline) {
            if ($CancelToken -and $CancelToken.Value) { return $null }
            [System.Windows.Forms.Application]::DoEvents()
            try {
                if ($udp.Available -gt 0) {
                    $remoteEP = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
                    $data = $udp.Receive([ref]$remoteEP)
                    if ($data -and $data.Length -gt 0) {
                        return $remoteEP.Address.ToString()
                    }
                }
            }
            catch { break }
            Start-Sleep -Milliseconds 50
        }
    }
    catch { }
    finally { try { $udp.Close() } catch {} }
    return $null
}

# Real X-Air discovery: checks saved IP, then UDP broadcast (no subnet scan).
# The X-Air always replies to broadcast /info — no slow fallback needed.
function XR-ScanForMixer {
    param(
        [string]$StartIP = "",
        [scriptblock]$ProgressCallback = $null,
        [ref]$CancelToken = $null
    )

    try {
        # ── Step 1: Check saved IP directly ──────────────────────────────────────
        $savedIP = if (-not [string]::IsNullOrWhiteSpace($StartIP)) { $StartIP } else {
            try { [string]$script:Cfg.XR.MixerIP } catch { "" }
        }

        if (-not [string]::IsNullOrWhiteSpace($savedIP)) {
            Log "Step 1: testing saved IP $savedIP..."
            if ($script:sbLeft -and -not $script:sbLeft.IsDisposed) {
                $script:sbLeft.Text = "Testing saved IP $savedIP..."
            }
            if ($ProgressCallback) { & $ProgressCallback $savedIP 5 }
            [System.Windows.Forms.Application]::DoEvents()
            if (Test-MixerPing -Ip $savedIP) {
                Log "✓ X-Air still at saved IP $savedIP"
                return $savedIP
            }
            Log "Saved IP $savedIP not responding — trying broadcast..."
        }

        # ── Step 2: UDP broadcast (up to 3 attempts, 3 s each) ───────────────────
        # X-Air always replies to OSC /info broadcast. Covers DHCP reassignment.
        Log 'Step 2: UDP broadcast discovery (up to 3 attempts)...'
        for ($attempt = 1; $attempt -le 3; $attempt++) {
            if ($CancelToken -and $CancelToken.Value) { Log 'Scan cancelled'; return $null }
            if ($script:sbLeft -and -not $script:sbLeft.IsDisposed) {
                $script:sbLeft.Text = "Broadcast attempt $attempt/3..."
            }
            if ($ProgressCallback) { & $ProgressCallback "Broadcast $attempt/3" ([int](10 + $attempt * 28)) }
            Log "Broadcast attempt $attempt/3..."
            $broadcastIP = Find-XAirByBroadcast -TimeoutMs 3000 -ProgressCallback $ProgressCallback -CancelToken $CancelToken
            if ($broadcastIP) {
                Log "✓ Found X-Air via broadcast at $broadcastIP"
                return $broadcastIP
            }
        }

        Log '✗ No X-Air mixer found (saved IP not responding, broadcast had no reply)'
        return $null
    }
    catch {
        Log "Scan error: $_"
        return $null
    }
}

# Test if device is actually an X-Air mixer using multiple validation methods
function Test-XAirDevice {
    param(
        [string]$IP,
        [ref]$CancelToken = $null
    )
    
    if ([string]::IsNullOrWhiteSpace($IP)) { return $false }
    
    # Check for cancellation at the start of each device test
    if ($CancelToken -and $CancelToken.Value) { return $false }
    
    # Don't test obviously wrong IPs
    $invalidIPs = @("127.0.0.1", "localhost", "192.168.1.1", "192.168.0.1", "192.168.4.1", "10.0.0.1")
    if ($invalidIPs -contains $IP) { return $false }
    
    try {
        # OSC-ONLY validation - send actual OSC message and wait for response
        # This prevents false positives from routers/devices with web interfaces
        $udpClient = New-Object System.Net.Sockets.UdpClient
        try {
            $udpClient.Connect($IP, 10024)
            
            # Send OSC "/info" command to request device info
            $oscMessage = @(47, 105, 110, 102, 111, 0, 0, 0)  # "/info" in OSC format
            [void]$udpClient.Send($oscMessage, $oscMessage.Length)
            
            # Set short timeout for response
            $udpClient.Client.ReceiveTimeout = 500  # 500ms timeout
            $endpoint = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
            
            try {
                $response = $udpClient.Receive([ref]$endpoint)
                if ($response -and $response.Length -gt 0) {
                    # Got OSC response = this IS an X-Air device
                    return $true
                }
            }
            catch {
                # No response or timeout = not an X-Air device
                return $false
            }
        }
        finally {
            try { $udpClient.Close() } catch {}
        }
        
        return $false
    }
    catch {
        return $false
    }
}

# X Air MAC address prefixes (Behringer/Music Group)
$XR_MAC_PREFIXES = @('fc-4d-d4', 'a0-99-9b', '00-1e-37')

function Find-XAirByARP {
    try {
        # Populate ARP table by pinging broadcast
        $adapter = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and $_.InterfaceDescription -notmatch 'Virtual|Loopback' } | Select-Object -First 1
        if ($adapter) {
            $ip = Get-NetIPAddress -InterfaceIndex $adapter.InterfaceIndex -AddressFamily IPv4 | Select-Object -First 1
            if ($ip) {
                $subnet = $ip.IPAddress.Substring(0, $ip.IPAddress.LastIndexOf('.')) + '.255'
                $null = Test-Connection $subnet -Count 1 -Quiet -ErrorAction SilentlyContinue
                Start-Sleep -Milliseconds 300
            }
        }

        # Parse ARP table
        $arp = arp -a
        foreach ($line in $arp) {
            foreach ($prefix in $XR_MAC_PREFIXES) {
                if ($line -match $prefix) {
                    $parts = $line -split '\s+' | Where-Object { $_ -ne '' }
                    if ($parts.Count -ge 2) {
                        $foundIp = $parts[0]
                        if ($foundIp -match '^\d+\.\d+\.\d+\.\d+$') {
                            return $foundIp
                        }
                    }
                }
            }
        }
    }
    catch { }
    return $null
}

function Find-XAirBySubnetScan {
    param([string]$subnet)
    
    if ([string]::IsNullOrWhiteSpace($subnet)) {
        # Auto-detect subnet from active adapter
        try {
            $adapter = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and $_.InterfaceDescription -notmatch 'Virtual|Loopback' } | Select-Object -First 1
            if ($adapter) {
                $ip = Get-NetIPAddress -InterfaceIndex $adapter.InterfaceIndex -AddressFamily IPv4 | Select-Object -First 1
                if ($ip) {
                    $subnet = $ip.IPAddress.Substring(0, $ip.IPAddress.LastIndexOf('.'))
                }
            }
        }
        catch { return $null }
    }
    
    if ([string]::IsNullOrWhiteSpace($subnet)) { return $null }
    
    try {
        # Quick ping sweep of common X Air addresses first
        $commonHosts = @(222, 1, 100, 10, 50, 200)
        foreach ($hostIP in $commonHosts) {
            $testIp = "$subnet.$hostIP"
            if (Test-Connection $testIp -Count 1 -Quiet -TimeoutSeconds 1 -ErrorAction SilentlyContinue) {
                # Try OSC handshake on port 10024
                try {
                    $udp = New-Object System.Net.Sockets.UdpClient
                    $udp.Client.ReceiveTimeout = 500
                    $udp.Connect($testIp, 10024)
                    $udp.Close()
                    return $testIp
                }
                catch { }
            }
        }
    }
    catch { }
    return $null
}

# Optional orange dot for "warning" (non-standard port). If not present, reuse green.
if (-not (Get-Variable -Scope Script -Name bmpOrange -ErrorAction SilentlyContinue) -or -not $script:bmpOrange) {
    try { $script:bmpOrange = New-DotBitmap ([System.Drawing.Color]::Gold) } catch { $script:bmpOrange = $bmpGreen }
}

# One-time helper (moved OUT of XR-SendOSC to avoid nested re-definitions)
function XR-Pad4Bytes {
    param([byte[]]$Bytes)
    $pad = (4 - ($Bytes.Length % 4)) % 4
    if ($pad -gt 0) { return ($Bytes + (New-Object byte[] $pad)) }
    return $Bytes
}

function Test-MixerPing {
    param([string]$Ip)
    if ([string]::IsNullOrWhiteSpace($Ip)) { return $false }
    
    # Don't consider these IPs as valid XR mixers
    $invalidIPs = @("127.0.0.1", "localhost", "192.168.1.1", "192.168.0.1", "192.168.4.1", "10.0.0.1")
    if ($invalidIPs -contains $Ip) { return $false }
    
    # Use OSC validation instead of ping to prevent false positives
    # This will only return true for actual X-Air mixers
    try {
        $udpClient = New-Object System.Net.Sockets.UdpClient
        try {
            $udpClient.Connect($Ip, 10024)
            
            # Send OSC "/info" command
            $oscMessage = @(47, 105, 110, 102, 111, 0, 0, 0)  # "/info" in OSC format
            [void]$udpClient.Send($oscMessage, $oscMessage.Length)
            
            # Short timeout for status check
            $udpClient.Client.ReceiveTimeout = 300
            $endpoint = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
            
            try {
                $response = $udpClient.Receive([ref]$endpoint)
                return ($response -and $response.Length -gt 0)
            }
            catch {
                return $false  # No OSC response = not an X-Air mixer
            }
        }
        finally {
            try { $udpClient.Close() } catch {}
        }
    }
    catch {
        return $false
    }
}

# Prevent overlapping timer ticks
$script:_xrBusy = $false
$script:_xrWasOnline = $false           # tracks previous online state for fader re-sync on reconnect
$script:_xrOfflineSince = $null         # datetime when mixer went offline (null = was online)
$script:_xrRuntimeScanDone = $false     # prevents repeated re-scans per offline period
$script:_xrBroadcastRetryTimer = $null  # periodic 2s broadcast retry after auto-scan fails
$script:_xrRetryBusy = $false           # prevents overlapping broadcast retry ticks
$script:_xrRetryCount = 0              # suppresses log spam (only logs every 20 ticks)

function XR-UpdateStatus {
    if ($script:_xrBusy) { return }
    $script:_xrBusy = $true
    try {
        $xrEnabled = [bool]$script:Cfg.XR.XRMixerEnabled

        # Read from Settings (never hard-coded)
        $ip = try { [string]$script:Cfg.XR.MixerIP } catch { "" }
        $port = try { [int]   $script:Cfg.XR.OscPort } catch { 0 }

        # If status label isn't ready or disposed, bail quietly
        if (-not $sbXR -or ($sbXR -and $sbXR.IsDisposed)) { return }

        # Hide XR status when XR mixer feature is disabled in Settings.
        $sbXR.Visible = $xrEnabled
        if (-not $xrEnabled) {
            $script:_xrWasOnline = $false
            $script:_xrOfflineSince = $null
            return
        }

        # Reachability by IP only (UDP has no handshake)
        $ipOk = $false
        try { $ipOk = Test-MixerPing -Ip $ip } catch {}

        if (-not $ipOk) {
            $sbXR.Text = "XR: Offline"
            $sbXR.Image = $bmpRed
            try { if ($script:_mixerPanel -and -not $script:_mixerPanel.IsDisposed) { $script:_mixerPanel.Text = "XR Mixer Panel  |  $ip  |  XR: Offline ✗" } } catch {}

            # Track when it first went offline
            if ($script:_xrWasOnline) {
                Log "Mixer went offline — waiting to reconnect..."
                $script:_xrOfflineSince = [datetime]::Now
                $script:_xrRuntimeScanDone = $false
            }
            $script:_xrWasOnline = $false

            # Re-scan once after 10s offline (gives mixer time to boot/get IP)
            if (-not $script:_xrRuntimeScanDone -and
                $script:_xrOfflineSince -and
                ([datetime]::Now - $script:_xrOfflineSince).TotalSeconds -ge 10 -and
                $script:Cfg.XR.XRMixerEnabled) {
                $script:_xrRuntimeScanDone = $true
                Log "Mixer offline 10s — running background scan..."
                try { Start-AutoScanAsync } catch {}
            }
            return
        }

        # IP is reachable — if just reconnected, re-read real fader positions from mixer
        $justReconnected = -not $script:_xrWasOnline
        $script:_xrWasOnline = $true
        $script:_xrOfflineSince = $null      # reset offline timer
        $script:_xrRuntimeScanDone = $false  # allow scan on next offline period
        # Stop broadcast retry timer — mixer is back online
        if ($script:_xrBroadcastRetryTimer) {
            try { $script:_xrBroadcastRetryTimer.Stop(); $script:_xrBroadcastRetryTimer.Dispose() } catch {}
            $script:_xrBroadcastRetryTimer = $null
            $script:_xrRetryBusy = $false
            $script:_xrRetryCount = 0
        }
        if ($justReconnected) {
            Log "Mixer reconnected ✓ — syncing faders"
            try { XR-SyncMixerFaders } catch {}
        }

        if ($port -ne 10024 -and $port -gt 0) {
            # Warn if using a non-standard port (common XR OSC port is 10024)
            $sbXR.Text = "XR: Online (IP) — Port $port?"
            $sbXR.Image = $bmpOrange
            try { if ($script:_mixerPanel -and -not $script:_mixerPanel.IsDisposed) { $script:_mixerPanel.Text = "XR Mixer Panel  |  $ip  |  XR: Online ✓" } } catch {}
        }
        else {
            $sbXR.Text = "XR: Online"
            $sbXR.Image = $bmpGreen
            try { if ($script:_mixerPanel -and -not $script:_mixerPanel.IsDisposed) { $script:_mixerPanel.Text = "XR Mixer Panel  |  $ip  |  XR: Online ✓" } } catch {}
        }
    }
    catch {
        try {
            if ($sbXR -and -not $sbXR.IsDisposed) {
                $sbXR.Text = "XR: Offline"
                $sbXR.Image = $bmpRed
            }
        }
        catch {}
    }
    finally {
        $script:_xrBusy = $false
    }
}

function XR-SendOSC {
    param(
        [string]$path,
        [Parameter(ValueFromPipeline = $true)]$value
    )
    try {
        $ip = [string]$script:Cfg.XR.MixerIP
        $port = [int]$script:Cfg.XR.OscPort
        
        # Better validation and user guidance
        if ([string]::IsNullOrWhiteSpace($ip) -or $ip -eq "127.0.0.1") { 
            if ($ip -eq "127.0.0.1") {
                throw "Mixer IP is set to localhost (127.0.0.1). Please configure your actual mixer IP address in XR Settings."
            }
            else {
                throw "Mixer IP not configured. Please set your mixer IP address in XR Settings."
            }
        }
        if ($port -lt 1 -or $port -gt 65535) { throw "OSC port out of range: $port" }

        # Debug logging for Zoom fader commands
        if ($path -like "*/ch/09/*") {
            Log "OSC Debug: Sending to $ip`:$port - Path: $path, Value: $value"
        }
        
        # Extra debug for any fader command issues
        if ($path -like "*/mix/fader") {
            Log "OSC Fader: $path -> $value (to $ip`:$port)"
        }

        $udp = New-Object System.Net.Sockets.UdpClient
        $udp.Connect($ip, $port) | Out-Null

        $enc = [Text.Encoding]::ASCII
        $addr = XR-Pad4Bytes ($enc.GetBytes($path + [char]0))
        
        # Determine if value is int or float and build appropriate message
        $valBytes = $null
        $typeTag = $null
        
        if ($value -is [int]) {
            $typeTag = XR-Pad4Bytes ($enc.GetBytes(",i" + [char]0))
            $valBytes = [BitConverter]::GetBytes([int]$value)
            if ([BitConverter]::IsLittleEndian) { [Array]::Reverse($valBytes) }
        }
        elseif ($value -is [double] -or $value -is [float] -or $value -is [single]) {
            $typeTag = XR-Pad4Bytes ($enc.GetBytes(",f" + [char]0))
            $valBytes = [BitConverter]::GetBytes([single]$value)
            if ([BitConverter]::IsLittleEndian) { [Array]::Reverse($valBytes) }
        }
        else {
            throw "Unsupported OSC value type: $($value.GetType().Name)"
        }

        $pkt = New-Object byte[] ($addr.Length + $typeTag.Length + $valBytes.Length)
        [Array]::Copy($addr, 0, $pkt, 0, $addr.Length)
        [Array]::Copy($typeTag, 0, $pkt, $addr.Length, $typeTag.Length)
        [Array]::Copy($valBytes, 0, $pkt, $addr.Length + $typeTag.Length, $valBytes.Length)

        [void]$udp.Send($pkt, $pkt.Length)
        $udp.Close()
        return $true
    }
    catch {
        Log "XR OSC error: $_"
        return $false
    }
}

# Initialize XR12 meter receiver (UDP listener on OSC port)
function XR-StartMeterReceiver {
    try {
        $mixerIP = [string]$script:Cfg.XR.MixerIP
        $mixerPort = [int]$script:Cfg.XR.OscPort   # 10024
        
        if ($script:XrMeterUdp) {
            try { $script:XrMeterUdp.Close() } catch { }
        }
        
        # 🔑 CRITICAL: Bind to ANY LOCAL PORT (ephemeral port)
        # XR12 replies to the SOURCE PORT that sent /meters, not to 10024
        # UdpClient(0) lets OS choose a free port - required for X-Air OSC
        $script:XrMeterUdp = New-Object System.Net.Sockets.UdpClient(0)
        $script:XrMeterUdp.Client.ReceiveTimeout = 10
        
        $localPort = $script:XrMeterUdp.Client.LocalEndPoint.Port
        Log "XR12 meter socket bound to LOCAL port $localPort (send to mixer ${mixerIP}:${mixerPort})"
        
        # ---- Send /xremote (required for XR12 OSC) ----
        $xremote = [System.Text.Encoding]::ASCII.GetBytes("/xremote`0")
        while ($xremote.Length % 4) { $xremote += 0 }
        [void]$script:XrMeterUdp.Send($xremote, $xremote.Length, $mixerIP, $mixerPort)
        Log "Sent /xremote"
        
        Start-Sleep -Milliseconds 100
        
        # ---- Test OSC communication by querying a fader ----
        # This verifies the mixer is actually responding to OSC
        $testQuery = [System.Text.Encoding]::ASCII.GetBytes("/ch/01/mix/fader`0")
        while ($testQuery.Length % 4) { $testQuery += 0 }
        try {
            [void]$script:XrMeterUdp.Send($testQuery, $testQuery.Length, $mixerIP, $mixerPort)
            Log "Sent OSC test query (fader read)"
        }
        catch {
            Log "OSC test query failed: $_"
        }
        
        # ---- Subscribe to meter stream ----
        Start-Sleep -Milliseconds 50   # brief pause so /xremote is registered
        try { XR-SubscribeMeters } catch { Log "XR-SubscribeMeters call failed: $_" }
        
        # ---- Start /xremote keepalive + meter re-subscription timer ----
        if (-not $script:XrKeepaliveTimer) {
            $script:XrKeepaliveTimer = New-Object System.Windows.Forms.Timer
            $script:XrKeepaliveTimer.Interval = 5000  # Every 5 seconds
            $script:XrKeepaliveTimer.Add_Tick({
                    try {
                        if ($script:XrMeterUdp) {
                            $ip = [string]$script:Cfg.XR.MixerIP
                            $port = [int]$script:Cfg.XR.OscPort
                            # 1) Send /xremote keepalive
                            $xr = [System.Text.Encoding]::ASCII.GetBytes("/xremote`0")
                            while ($xr.Length % 4) { $xr += 0 }
                            [void]$script:XrMeterUdp.Send($xr, $xr.Length, $ip, $port)
                            Log-Throttled "xr-keepalive" "Sent /xremote keepalive" 30
                            # 2) Re-subscribe to meters (X-Air expires subscriptions after ~10s)
                            XR-SubscribeMeters | Out-Null
                        }
                    }
                    catch { }
                })
        }
        $script:XrKeepaliveTimer.Start()
        Log "XR12 keepalive timer started (5s interval)"
        
        return $true
    }
    catch {
        Log "XR12 meter receiver failed: $_"
        return $false
    }
}

# Subscribe to XR12 meters (block 0, channels 1-8)
function XR-SubscribeMeters {
    try {
        if (-not $script:XrMeterUdp) {
            Log "XR12 meter subscription failed: socket not initialized"
            return $false
        }
        
        # Try every known format for X-Air meter subscription simultaneously.
        # We don't know which firmware/model variant the mixer uses, so we send all of them.
        $ip = [string]$script:Cfg.XR.MixerIP
        $port = [int]$script:Cfg.XR.OscPort
        $enc = [System.Text.Encoding]::ASCII
        
        # --- Format D: /meters ,s /meters/N  (CONFIRMED by Wireshark: what Mixing Station sends) ---
        # Address: "/meters\0"  (8 bytes)
        # TypeTag: ",s\0\0"     (4 bytes)
        # Arg:     "/meters/N\0" padded to 4-byte boundary
        $addrM = [byte[]]@(0x2F, 0x6D, 0x65, 0x74, 0x65, 0x72, 0x73, 0x00)  # "/meters\0"
        $typeS = [byte[]]@(0x2C, 0x73, 0x00, 0x00)                           # ",s\0\0"
        foreach ($bus in @("/meters/1", "/meters/2", "/meters/8")) {
            $argBytes = $enc.GetBytes($bus + [char]0)
            while ($argBytes.Length % 4 -ne 0) { $argBytes += [byte]0 }
            $pkt = $addrM + $typeS + $argBytes
            [void]$script:XrMeterUdp.Send($pkt, $pkt.Length, $ip, $port)
        }

        # --- Format A: /meters ,i <bank>  (xair-remote / Python community) ---
        $addrA = [byte[]]@(0x2F, 0x6D, 0x65, 0x74, 0x65, 0x72, 0x73, 0x00)  # "/meters\0"
        $typeI = [byte[]]@(0x2C, 0x69, 0x00, 0x00)                           # ",i\0\0"
        foreach ($bank in @(0, 1, 2, 3)) {
            $arg = [BitConverter]::GetBytes([int32]$bank)
            if ([BitConverter]::IsLittleEndian) { [Array]::Reverse($arg) }
            $pkt = $addrA + $typeI + $arg
            [void]$script:XrMeterUdp.Send($pkt, $pkt.Length, $ip, $port)
        }
        
        # --- Format B: /meters/N ,ii 0 50  (v5.x original, two-int args) ---
        $typeII = [byte[]]@(0x2C, 0x69, 0x69, 0x00)  # ",ii\0"
        $arg0 = [byte[]]@(0x00, 0x00, 0x00, 0x00)  # int32(0)
        $arg50 = [byte[]]@(0x00, 0x00, 0x00, 0x32)  # int32(50)
        foreach ($bank in @(1, 2, 3)) {
            $ab = $enc.GetBytes("/meters/$bank" + [char]0)
            while ($ab.Length % 4 -ne 0) { $ab += [byte]0 }
            $pkt = $ab + $typeII + $arg0 + $arg50
            [void]$script:XrMeterUdp.Send($pkt, $pkt.Length, $ip, $port)
        }
        
        # --- Format C: /meters/N ,i 50  (single int = rate ms) ---
        foreach ($bank in @(1, 2, 3)) {
            $ab = $enc.GetBytes("/meters/$bank" + [char]0)
            while ($ab.Length % 4 -ne 0) { $ab += [byte]0 }
            $pkt = $ab + $typeI + $arg50
            [void]$script:XrMeterUdp.Send($pkt, $pkt.Length, $ip, $port)
        }
        
        Log-Throttled "xr-sub-sent" "XR12 meter subscriptions sent (4 formats x banks 0-3)" 5
        return $true
    }
    catch {
        Log "XR12 meter subscription error: $_"
        return $false
    }
}

# Stop XR12 meter receiver
function XR-StopMeterReceiver {
    if ($script:XrKeepaliveTimer) {
        try {
            $script:XrKeepaliveTimer.Stop()
            $script:XrKeepaliveTimer = $null
        }
        catch { }
    }
    if ($script:XrMeterUdp) {
        try {
            $script:XrMeterUdp.Close()
            $script:XrMeterUdp = $null
            Log "XR12 meter receiver stopped"
        }
        catch { }
    }
}

# ---- OSC Parsing Helpers for XR12 Meters ----

function Read-OscString {
    param (
        [byte[]]$Bytes,
        [ref]$Offset
    )
    
    $start = $Offset.Value
    while ($Offset.Value -lt $Bytes.Length -and $Bytes[$Offset.Value] -ne 0) {
        $Offset.Value++
    }
    
    $str = [System.Text.Encoding]::ASCII.GetString(
        $Bytes[$start..($Offset.Value - 1)]
    )
    
    # Skip nulls + pad to 4-byte boundary
    while (($Offset.Value % 4) -ne 0) {
        $Offset.Value++
    }
    
    return $str
}

function Read-OscFloatBE {
    param (
        [byte[]]$Bytes,
        [ref]$Offset
    )
    
    $b = $Bytes[$Offset.Value..($Offset.Value + 3)]
    $Offset.Value += 4
    
    if ([BitConverter]::IsLittleEndian) {
        [Array]::Reverse($b)
    }
    
    return [BitConverter]::ToSingle($b, 0)
}

function Parse-XAirMeters {
    param ([byte[]]$PacketBytes)
    
    try {
        if ($PacketBytes.Length -lt 16) { return $null }
        
        # Standard OSC: address string at offset 0, null-terminated, padded to 4-byte boundary
        $addrEnd = 0
        while ($addrEnd -lt $PacketBytes.Length -and $PacketBytes[$addrEnd] -ne 0) { $addrEnd++ }
        $addrStr = [System.Text.Encoding]::ASCII.GetString($PacketBytes, 0, $addrEnd)
        
        # Only process /meters/* packets — silently ignore all other OSC messages
        if ($addrStr -notmatch '^/meters') { return $null }
        
        # Type tag starts after null-padded address (rounded up to multiple of 4)
        $typeOffset = $addrEnd + 1
        while ($typeOffset % 4 -ne 0) { $typeOffset++ }
        if (($typeOffset + 1) -ge $PacketBytes.Length) { return $null }
        
        # Expect blob type tag: ',b'
        if ($PacketBytes[$typeOffset] -ne 0x2C -or $PacketBytes[$typeOffset + 1] -ne 0x62) {
            return $null  # Not a blob response — skip silently
        }
        
        # Type tag string ',b\0\0' is 4 bytes; blob length (big-endian int32) follows
        $blobLenOffset = $typeOffset + 4
        if (($blobLenOffset + 3) -ge $PacketBytes.Length) { return $null }
        $lenBytes = $PacketBytes[$blobLenOffset..($blobLenOffset + 3)]
        if ([BitConverter]::IsLittleEndian) { [Array]::Reverse($lenBytes) }
        $blobLen = [BitConverter]::ToInt32($lenBytes, 0)
        
        $dataOffset = $blobLenOffset + 4
        if ($blobLen -le 0 -or ($dataOffset + $blobLen - 1) -ge $PacketBytes.Length) { return $null }
        
        Log-Throttled "xr-blob-len" "XR12 meter blob received: addr=$addrStr  $blobLen bytes" 5
        $blob = $PacketBytes[$dataOffset..($dataOffset + $blobLen - 1)]
        return @{ Address = $addrStr; Blob = $blob }
    }
    catch {
        Log "XR12 parse exception: $_"
        return $null
    }
}

# Decode X-Air meter blob into per-channel dBFS values.
# Confirmed format (Wireshark + log analysis on XR12):
#   Bytes 0-3 : channel count as LITTLE-ENDIAN int32  (e.g. 0x28 00 00 00 = 40)
#   Bytes 4+  : count × signed int16 LITTLE-ENDIAN meter values
#   Conversion: dBFS = rawInt16 / 256.0   (0x8000 = -128 dB = silence floor)
function Decode-XAirMeterBlob {
    param ([byte[]]$Blob)

    if ($Blob.Length -lt 6) { return @() }

    # Count is LITTLE-ENDIAN int32 (NOT big-endian)
    $count = [BitConverter]::ToInt32($Blob, 0)   # LE is native on x86/x64

    if ($count -le 0 -or $count -gt 128 -or (4 + $count * 2) -gt $Blob.Length) {
        Log-Throttled "xr-blob-bad" "Decode-XAirMeterBlob: count=$count blobLen=$($Blob.Length)" 5
        return @()
    }

    $meters = @()
    for ($i = 0; $i -lt $count; $i++) {
        $off = 4 + $i * 2
        # Signed int16 LITTLE-ENDIAN
        $raw = [BitConverter]::ToInt16($Blob, $off)
        # Formula confirmed: raw / 256.0 gives dBFS
        $dB = [Math]::Max(-90.0, [Math]::Min(0.0, [double]$raw / 256.0))
        $meters += @{ Peak = $dB; RMS = $dB }
    }

    Log-Throttled "xr-blob-ok" "Decode-XAirMeterBlob: $count channels decoded" 10
    return $meters
}

# Poll for XR12 meter packets AND fader responses (called by 50ms timer)
function XR-PollMeterPackets {
    if (-not $script:XrMeterUdp) { return }
    
    try {
        $maxReads = 30  # Up to 30 packets per tick; timeout/exception breaks the loop
        for ($i = 0; $i -lt $maxReads; $i++) {
            try {
                $remote = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
                $data = $script:XrMeterUdp.Receive([ref]$remote)
                if ($data.Length -lt 4) { continue }
                
                # UNCONDITIONAL raw hex logging for first 50 received packets
                # This catches meter data even if address parsing fails
                $script:_rawPktCount++
                if ($script:_rawPktCount -le 50) {
                    $hexHead = ($data[0..[Math]::Min(15, $data.Length - 1)] | ForEach-Object { $_.ToString('X2') }) -join ' '
                    Log "RAW#$($script:_rawPktCount) $($data.Length)b from $($remote.Address):$($remote.Port): $hexHead"
                }
                
                if ($data.Length -lt 8) { continue }
                
                # --- Parse OSC address from offset 0 ---
                $addrEnd = 0
                while ($addrEnd -lt $data.Length -and $data[$addrEnd] -ne 0) { $addrEnd++ }
                $addr = [System.Text.Encoding]::ASCII.GetString($data, 0, $addrEnd)
                $tOff = $addrEnd + 1; while ($tOff % 4 -ne 0) { $tOff++ }
                if ($tOff -ge $data.Length) { continue }
                
                # Diagnostic: log any received packet address (throttled per address to reduce noise)
                Log-Throttled "xr-rcv-$addr" "XR recv: $addr ($($data.Length)b)" 10
                
                # Raw hex dump for first 2 meter packets so we can verify blob format
                if ($addr -like '/meters/*' -and $script:_meterRawDumpCount -lt 2) {
                    $script:_meterRawDumpCount++
                    $hexStr = ($data | ForEach-Object { $_.ToString("X2") }) -join ' '
                    Log "METER DUMP[$addr] $($data.Length)b: $($hexStr.Substring(0, [Math]::Min(240, $hexStr.Length)))"
                }
                
                # --- Meter blob: /meters/N ,b <blob> ---
                $meterResult = Parse-XAirMeters $data
                if ($meterResult -and $meterResult.Blob) {
                    $channels = Decode-XAirMeterBlob $meterResult.Blob
                    # /meters/1: sequential input pre-fader — index 0=CH1, index 1=CH2, ..., index 8=CH9
                    # /meters/2: main LR output — index 0=LR Left (key 17), index 1=LR Right (key 18)
                    # /meters/8 and others: skipped — their silent bus values must not overwrite CH1-4
                    switch -Regex ($meterResult.Address) {
                        '/meters/1' {
                            for ($ch = 0; $ch -lt $channels.Count -and $ch -lt 16; $ch++) {
                                # Apply +15 dB calibration: XR12 raw pre-fader levels run ~15 dB below display
                                $script:XrMeterLevels[$ch + 1] = $channels[$ch].Peak + 15.0
                            }
                        }
                        '/meters/2' {
                            if ($channels.Count -ge 1) { $script:XrMeterLevels[17] = $channels[0].Peak + 15.0 }
                            if ($channels.Count -ge 2) { $script:XrMeterLevels[18] = $channels[1].Peak + 15.0 }
                        }
                        # /meters/8 and others: not stored (prevents overwriting CH1-4 with silent values)
                    }
                    Log-Throttled "xr-meter-ok" "XR12 meters OK: $($channels.Count) channels from $($meterResult.Address)" 10
                    continue
                }
                
                # --- Fader float response: /ch/NN/mix/fader ,f <val>  or  /lr/mix/fader ,f <val> ---
                if ($tOff + 1 -lt $data.Length -and $data[$tOff] -eq 0x2C -and $data[$tOff + 1] -eq 0x66) {
                    $fOff = $tOff + 4  # skip ',f\0\0'
                    if ($fOff + 3 -lt $data.Length) {
                        $fb = $data[$fOff..($fOff + 3)]
                        if ([BitConverter]::IsLittleEndian) { [Array]::Reverse($fb) }
                        $fval = [BitConverter]::ToSingle($fb, 0)
                        
                        if (-not $script:_cachedFaders) { $script:_cachedFaders = @{} }
                        
                        if ($addr -match '^/ch/(\d+)/mix/fader$') {
                            $chNum = [int]$Matches[1]
                            $script:_cachedFaders[$chNum] = $fval
                            # Update mixer panel TrackBar if open
                            if ($script:_mixerPanel -and -not $script:_mixerPanel.IsDisposed -and $chNum -ge 1 -and $chNum -le 9) {
                                $tb = $script:_mixerFaderBars[$chNum - 1]
                                if ($tb -and -not $tb.IsDisposed) {
                                    $tbVal = [Math]::Max(0, [Math]::Min(1000, [int]($fval * 1000)))
                                    $script:_mixerUpdating = $true
                                    try {
                                        $tb.Tag.Value = $tbVal
                                        $tb.Invalidate()
                                        $fl = $script:_mixerFaderLabels[$chNum - 1]
                                        if ($fl -and -not $fl.IsDisposed) {
                                            $fl.Text = if ($fval -lt 0.001) { "-inf" } else { ("{0:F1}" -f [double](ConvertTo-Decibels $fval)) + "dB" }
                                        }
                                    }
                                    catch {}
                                    $script:_mixerUpdating = $false
                                }
                                # Sync ON button highlight based on fader position
                                $ob = $script:_mixerOnBtns[$chNum - 1]
                                if ($ob -and -not $ob.IsDisposed) {
                                    $isOn = ($fval -gt 0.001)
                                    $ob.Tag.IsOn = $isOn
                                    if ($isOn) {
                                        $ob.BackColor = $ob.Tag.ColorBright
                                        $ob.ForeColor = [System.Drawing.Color]::White
                                    }
                                    else {
                                        $ob.BackColor = $ob.Tag.ColorDim
                                        $ob.ForeColor = [System.Drawing.Color]::FromArgb(160, 160, 160)
                                    }
                                }
                            }
                        }
                        elseif ($addr -eq '/lr/mix/fader') {
                            $script:_cachedFaders[0] = $fval  # 0 = master LR
                            # Update master TrackBar (index 9)
                            if ($script:_mixerPanel -and -not $script:_mixerPanel.IsDisposed) {
                                $tb = $script:_mixerFaderBars[9]
                                if ($tb -and -not $tb.IsDisposed) {
                                    $tbVal = [Math]::Max(0, [Math]::Min(1000, [int]($fval * 1000)))
                                    $script:_mixerUpdating = $true
                                    try {
                                        $tb.Tag.Value = $tbVal
                                        $tb.Invalidate()
                                        $fl = $script:_mixerFaderLabels[9]
                                        if ($fl -and -not $fl.IsDisposed) {
                                            $fl.Text = if ($fval -lt 0.001) { "-inf" } else { ("{0:F1}" -f [double](ConvertTo-Decibels $fval)) + "dB" }
                                        }
                                    }
                                    catch {}
                                    $script:_mixerUpdating = $false
                                }
                                # Sync master ON button highlight based on fader position
                                $ob = $script:_mixerOnBtns[9]
                                if ($ob -and -not $ob.IsDisposed) {
                                    $isOn = ($fval -gt 0.001)
                                    $ob.Tag.IsOn = $isOn
                                    if ($isOn) {
                                        $ob.BackColor = $ob.Tag.ColorBright
                                        $ob.ForeColor = [System.Drawing.Color]::White
                                    }
                                    else {
                                        $ob.BackColor = $ob.Tag.ColorDim
                                        $ob.ForeColor = [System.Drawing.Color]::FromArgb(160, 160, 160)
                                    }
                                }
                            }
                        }
                    }
                    continue
                }
                
                # All other packets (/-snap/load, /-stat/usb, etc.) — silently discard
            }
            catch {
                break  # Timeout = no more data this tick; exit read loop
            }
        }
    }
    catch {
        Log-Throttled "xr-meter-error" "XR meter poll error: $_" 10
    }
}

# Get meter level for a specific XR12 channel (1-based channel number)
# NOTE: XR12 OSC meter subscription not working - returns -90 until we solve this
function XR-GetMeterLevel {
    param([int]$channel)
    
    if ($channel -lt 1 -or $channel -gt 32) {
        Log "XR-GetMeterLevel: Invalid channel $channel"
        return -90.0
    }
    
    # Check cached meter value (if XR12 ever sends meters)
    if ($script:XrMeterLevels.Contains($channel)) {
        $level = $script:XrMeterLevels[$channel]
        Log-Throttled "xr-meter-ch$channel" "XR CH${channel} meter = $($level.ToString('F1')) dB" 3
        return $level
    }
    
    # No meter data yet — return silence
    return -90.0
}

function XR-SyncMixerFaders {
    # Query all channel faders — X-Air "get" = send bare address with NO type tag section
    try {
        $ip = [string]$script:Cfg.XR.MixerIP
        $port = [int]$script:Cfg.XR.OscPort
        if ([string]::IsNullOrWhiteSpace($ip) -or -not $script:XrMeterUdp) { return }
        
        # Channels 1-9
        for ($ch = 1; $ch -le 9; $ch++) {
            $a = "/ch/{0:D2}/mix/fader" -f $ch
            $ab = [System.Text.Encoding]::ASCII.GetBytes($a + [char]0)
            while ($ab.Length % 4 -ne 0) { $ab += [byte]0 }
            [void]$script:XrMeterUdp.Send($ab, $ab.Length, $ip, $port)
        }
        # Master LR
        $ab2 = [System.Text.Encoding]::ASCII.GetBytes("/lr/mix/fader" + [char]0)
        while ($ab2.Length % 4 -ne 0) { $ab2 += [byte]0 }
        [void]$script:XrMeterUdp.Send($ab2, $ab2.Length, $ip, $port)
        
        Log "Mixer Panel: Queried all fader positions from XR12"
    }
    catch { Log "XR-SyncMixerFaders error: $_" }
}

# Update snapshot button highlight in the mixer panel from any caller.
# Brightens the button matching $snapNum and dims all others.
function Sync-SnapPanelHighlight {
    param([int]$snapNum)
    # Track the currently active XR snapshot number globally
    $script:_activeXrSnapshot = $snapNum
    if (-not $script:_snapBtns -or $script:_snapBtns.Count -eq 0) { return }
    if (-not $script:_snapColorMap) { return }
    # Suppress per-button repaints during bulk color update to eliminate flicker
    $snapPnl = try { $script:_snapBtns[0].Parent } catch { $null }
    if ($script:_winMsgAvail -and $snapPnl -and -not $snapPnl.IsDisposed) { [WinMsg]::SuspendDraw($snapPnl.Handle) }
    for ($sai = 0; $sai -lt $script:_snapBtns.Count; $sai++) {
        $sb2 = $script:_snapBtns[$sai]
        if ($sb2 -and -not $sb2.IsDisposed) {
            $isActive = ($sb2.Tag.SnapNum -eq $snapNum)
            $sc2 = [string]$sb2.Tag.Color
            if ($isActive) {
                $script:_activeSnapIdx = $sb2.Tag.Index
                if ($sc2 -and $script:_snapColorMap.Contains($sc2)) {
                    $rc2 = $script:_snapColorMap[$sc2]
                    $sb2.BackColor = [System.Drawing.Color]::FromArgb(
                        [int]([Math]::Min(255, $rc2.R * 1.8)),
                        [int]([Math]::Min(255, $rc2.G * 1.8)),
                        [int]([Math]::Min(255, $rc2.B * 1.8))
                    )
                }
                else {
                    $sb2.BackColor = [System.Drawing.Color]::FromArgb(80, 120, 200)
                }
            }
            else {
                if ($sc2 -and $script:_snapColorMap.Contains($sc2)) {
                    $rc2 = $script:_snapColorMap[$sc2]
                    $sb2.BackColor = [System.Drawing.Color]::FromArgb(
                        [int]($rc2.R / 4), [int]($rc2.G / 4), [int]($rc2.B / 4)
                    )
                }
                else {
                    $sb2.BackColor = [System.Drawing.Color]::FromArgb(45, 45, 45)
                }
            }
            $sb2.ForeColor = if ($isActive) { [System.Drawing.Color]::Black } else { [System.Drawing.Color]::White }
        }
    }
    # Resume drawing — all button color changes repaint in a single batch
    if ($script:_winMsgAvail -and $snapPnl -and -not $snapPnl.IsDisposed) {
        [WinMsg]::ResumeDraw($snapPnl.Handle)
        $snapPnl.Refresh()
    }
}

function XR-LoadSnapshot {
    param([int]$n)
    if ($n -lt 1 -or $n -gt 10) { $n = 1 }
    # Determine Auto Mode snap number before the OSC send
    $autoSnapNum = if ($script:_snapBtns -and $script:_snapBtns.Count -ge 8) { $script:_snapBtns[7].Tag.SnapNum } else { 8 }
    $isAutoSnap = ($script:Cfg.XR.AutoModeEnabled -and ($n -eq $autoSnapNum))
    # Stop Auto Mode immediately whenever we are leaving the Auto Mode snapshot
    if (-not $isAutoSnap) { Stop-AutoMode }
    if (XR-SendOSC $XR_SNAPSHOT_PATH $n) {
        Log "XR: snapshot $n load sent."
        # Update mixer panel highlight immediately
        Sync-SnapPanelHighlight $n
        # After 600ms the mixer has settled — re-read all fader positions into the panel
        $st = New-Object System.Windows.Forms.Timer
        $st.Interval = 600
        $st.Add_Tick({ $this.Stop(); $this.Dispose(); XR-SyncMixerFaders })
        $st.Start()
        # After 850ms start Auto Mode (only for the auto snapshot)
        if ($isAutoSnap) {
            $stAM = New-Object System.Windows.Forms.Timer
            $stAM.Interval = 850
            $stAM.Add_Tick({ $this.Stop(); $this.Dispose(); Start-AutoMode })
            $stAM.Start()
        }
    }
}

# ---- Auto Mode: start, stop, and timer logic ----

function Update-AutoModeFaderDisplay {
    param([int]$ch, [double]$dB)
    # Update mixer panel fader bar visual (ch is 1-based, array is 0-based)
    $idx = $ch - 1
    $fb = $script:_mixerFaderBars[$idx]
    if ($fb -and -not $fb.IsDisposed) {
        $linear = ConvertTo-LinearFader $dB
        $fb.Tag.Value = [int]($linear * 1000)
        $fb.Invalidate()
    }
    $fl = $script:_mixerFaderLabels[$idx]
    if ($fl -and -not $fl.IsDisposed) {
        $fl.Text = if ($dB -le -89.0) { "-inf" } else { ("{0:F1}" -f $dB) + "dB" }
    }
}

function Start-AutoMode {
    try {
        Log "Auto Mode: Starting"
        $script:_autoModeActive = $true
        $script:_autoModeChHoldUntil = @{}
        $script:_autoModeLastDB = @{}
        $script:_autoModeWavePhase = 0.0
        $script:_autoModeWaveTick = 0
        $script:_autoMusicWasPlaying = $false
        # Channel 1 → 0 dB (unity, left running)
        $lin1 = ConvertTo-LinearFader 0.0
        XR-WriteFaderPosition 1 $lin1
        Update-AutoModeFaderDisplay 1 0.0
        # Channels 2-9 → -15 dB baseline
        $lin15 = ConvertTo-LinearFader -15.0
        for ($am = 2; $am -le 9; $am++) {
            XR-WriteFaderPosition $am $lin15
            Update-AutoModeFaderDisplay $am -15.0
            $script:_autoModeLastDB[$am] = -15.0
        }
        # Create/start the timer
        if ($script:_autoModeTimer -and -not $script:_autoModeTimer.IsDisposed) {
            $script:_autoModeTimer.Stop(); $script:_autoModeTimer.Dispose()
        }
        $script:_autoModeTimer = New-Object System.Windows.Forms.Timer
        $script:_autoModeTimer.Interval = 100
        $script:_autoModeTimer.Add_Tick({
                try {
                    if (-not $script:_autoModeActive) { $script:_autoModeTimer.Stop(); return }
                    $holdMS = [int]$script:Cfg.XR.AutoModeHoldTimeMS
                    $threshDB = -35.0
                    $highDB = 0.0
                    $lowDB = -15.0
                    $waveAmp = 3.0
                    $now = Get-Date
                    $mediaCh = [int]$script:Cfg.XR.MediaChannel   # the XR channel labeled "Media"
                    $musicOn = Music-IsPlaying                     # check once per tick
                    $script:_autoModeWaveTick++
                    $doWave = ($script:_autoModeWaveTick % 2 -eq 0)   # wave writes every 200ms
                    if ($doWave) { $script:_autoModeWavePhase += 0.12 }

                    # ---- Media channel: controlled solely by music play button state ----
                    if ($musicOn -and -not $script:_autoMusicWasPlaying) {
                        # Music just started — raise Media fader to 0 dB immediately
                        $linHigh = ConvertTo-LinearFader $highDB
                        XR-WriteFaderPosition $mediaCh $linHigh
                        Update-AutoModeFaderDisplay $mediaCh $highDB
                        $script:_autoModeLastDB[$mediaCh] = $highDB
                        $script:_autoMusicWasPlaying = $true
                        Log "Auto Mode: Background music started — Media ch$mediaCh raised to 0 dB"
                    }
                    elseif (-not $musicOn -and $script:_autoMusicWasPlaying) {
                        # Music just stopped — restore Media fader to -15 dB baseline
                        $linLow = ConvertTo-LinearFader $lowDB
                        XR-WriteFaderPosition $mediaCh $linLow
                        Update-AutoModeFaderDisplay $mediaCh $lowDB
                        $script:_autoModeLastDB[$mediaCh] = $lowDB
                        $script:_autoMusicWasPlaying = $false
                        Log "Auto Mode: Background music stopped — Media ch$mediaCh restored to -15 dB"
                    }

                    for ($am_ch = 2; $am_ch -le 9; $am_ch++) {
                        # Media channel is handled exclusively by music play state above — skip it here
                        if ($am_ch -eq $mediaCh) { continue }

                        $levelDB = try { [double](XR-GetMeterLevel $am_ch) } catch { -90.0 }
                        $holdUntil = $script:_autoModeChHoldUntil[$am_ch]
                        $inHold = ($null -ne $holdUntil -and $now -lt $holdUntil)

                        if ($levelDB -gt $threshDB) {
                            # Sound detected — raise to 0 dB and extend hold
                            $script:_autoModeChHoldUntil[$am_ch] = $now.AddMilliseconds($holdMS)
                            $lastDB = if ($script:_autoModeLastDB.Contains($am_ch)) { $script:_autoModeLastDB[$am_ch] } else { $lowDB }
                            if ([Math]::Abs($lastDB - $highDB) -gt 0.4) {
                                $linHigh = ConvertTo-LinearFader $highDB
                                XR-WriteFaderPosition $am_ch $linHigh
                                Update-AutoModeFaderDisplay $am_ch $highDB
                                $script:_autoModeLastDB[$am_ch] = $highDB
                            }
                        }
                        elseif ($inHold) {
                            # Hold period active — keep at 0 dB, no write needed
                        }
                        else {
                            # Idle — apply wave animation around -15 dB
                            $script:_autoModeChHoldUntil[$am_ch] = $null
                            if ($doWave) {
                                $waveOffset = [Math]::Sin($script:_autoModeWavePhase + ($am_ch - 2) * 0.75) * $waveAmp
                                $targetDB = $lowDB + $waveOffset
                                $lastDB = if ($script:_autoModeLastDB.Contains($am_ch)) { $script:_autoModeLastDB[$am_ch] } else { $lowDB }
                                if ([Math]::Abs($lastDB - $targetDB) -gt 0.3) {
                                    $linWave = ConvertTo-LinearFader $targetDB
                                    XR-WriteFaderPosition $am_ch $linWave
                                    Update-AutoModeFaderDisplay $am_ch $targetDB
                                    $script:_autoModeLastDB[$am_ch] = $targetDB
                                }
                            }
                        }
                    }
                }
                catch { Log "Auto Mode timer error: $_" }
            })
        $script:_autoModeTimer.Start()
        Log "Auto Mode: Active — Ch1=0dB, Ch2-9 at -15dB with auto-raise on input"
    }
    catch { Log "Start-AutoMode error: $_" }
}

function Stop-AutoMode {
    try {
        if (-not $script:_autoModeActive) { return }
        $script:_autoModeActive = $false
        if ($script:_autoModeTimer -and -not $script:_autoModeTimer.IsDisposed) {
            $script:_autoModeTimer.Stop()
            $script:_autoModeTimer.Dispose()
            $script:_autoModeTimer = $null
        }
        $script:_autoModeChHoldUntil = @{}
        $script:_autoModeLastDB = @{}
        Log "Auto Mode: Stopped"
    }
    catch { Log "Stop-AutoMode error: $_" }
}



# ---- Audio Ducking Functions ----

# Convert dB to linear fader value (0.0 to 1.0) using X Air fader curve
function ConvertTo-LinearFader {
    param([double]$dB)
    if ($dB -le -90) { return 0.0 }
    if ($dB -ge 10) { return 1.0 }
    
    # X Air fader curve: 0.75 = 0 dB (unity gain)
    # Based on empirical testing: 1 dB ≈ 0.01875 linear units below unity
    # Below 0 dB: 0.75 linear range covers 40 dB
    # Above 0 dB: map 0 to +10 dB as 0.75 to 1.0
    
    if ($dB -le 0) {
        # Map dB to linear: 40 dB range for 0.75 linear
        $linear = 0.75 + ($dB / 40.0) * 0.75
    }
    else {
        # Map 0..+10 dB to 0.75..1.0 linear
        $linear = 0.75 + ($dB / 10.0) * 0.25
    }
    
    if ($linear -lt 0.0) { $linear = 0.0 }
    if ($linear -gt 1.0) { $linear = 1.0 }
    return $linear
}

# Convert linear fader value (0.0 to 1.0) to dB using X Air fader curve
function ConvertTo-Decibels {
    param([double]$linear)
    if ($linear -le 0.0) { return -90.0 }
    if ($linear -ge 1.0) { return 10.0 }
    
    # X Air fader curve: 0.75 = 0 dB (unity gain)
    # Inverse: 1 dB ≈ 0.01875 linear units (40 dB range for 0.75 linear)
    
    if ($linear -le 0.75) {
        # Map 0.0..0.75 linear to -40..0 dB
        $dB = (($linear - 0.75) / 0.75) * 40.0
    }
    else {
        # Map 0.75..1.0 linear to 0..+10 dB
        $dB = (($linear - 0.75) / 0.25) * 10.0
    }
    
    return $dB
}

# Read fader position from X Air mixer (returns 0.0-1.0)
function XR-ReadFaderPosition {
    param([int]$channel)
    try {
        # For reading, we send a request and would need to listen for response
        # X Air doesn't have a direct query-response mechanism in simple UDP
        # We'll need to cache the last set value or use a subscription
        # For now, return cached value if available
        if ($script:_cachedFaders -and $script:_cachedFaders.Contains($channel)) {
            return $script:_cachedFaders[$channel]
        }
        return 0.75  # Default if not cached
    }
    catch {
        Log "XR: Error reading fader position for channel $channel - $_"
        return 0.75
    }
}

# Write fader position to X Air mixer (0.0-1.0)
function XR-WriteFaderPosition {
    param([int]$channel, [double]$linearValue)
    try {
        $oscPath = "/ch/{0:D2}/mix/fader" -f $channel
        if ($linearValue -lt 0.0) { $linearValue = 0.0 }
        if ($linearValue -gt 1.0) { $linearValue = 1.0 }
        
        # Cache the value
        if (-not $script:_cachedFaders) {
            $script:_cachedFaders = @{}
        }
        $script:_cachedFaders[$channel] = $linearValue
        
        if (XR-SendOSC $oscPath $linearValue) {
            Log "XR: Set channel $channel fader to $([math]::Round($linearValue, 3))"
            return $true
        }
        return $false
    }
    catch {
        Log "XR: Error writing fader position for channel $channel - $_"
        return $false
    }
}

# Auto-scan startup check - only scans when XR is offline and auto-scan is enabled
function Start-AutoScanCheck {
    try {
        # Check if current XR IP is working
        $currentIP = [string]$script:Cfg.XR.MixerIP
        
        if ([string]::IsNullOrWhiteSpace($currentIP)) {
            Log "Auto-scan: No XR IP configured, starting scan..."
            Start-AutoScanAsync
            return
        }
        
        # Test current IP
        Log "Auto-scan: Testing current XR IP: $currentIP"
        $isOnline = $false
        try { $isOnline = Test-MixerPing -Ip $currentIP } catch {}
        
        if ($isOnline) {
            Log "Auto-scan: Current XR IP is online, no scan needed"
            return
        }
        
        Log "Auto-scan: Current XR IP is offline, starting scan..."
        Start-AutoScanAsync
    }
    catch {
        Log "Auto-scan check error: $_"
    }
}

# Run auto-scan in background without blocking UI
function Start-AutoScanAsync {
    try {
        # Prevent multiple auto-scan timers
        if ($script:autoScanTimer) {
            $script:autoScanTimer.Stop()
            $script:autoScanTimer.Dispose()
            $script:autoScanTimer = $null
        }
        
        # Use a timer to run scan without blocking startup
        $script:autoScanTimer = New-Object System.Windows.Forms.Timer
        $script:autoScanTimer.Interval = 2000  # 2 second delay to let UI fully load
        $script:autoScanTimer.Add_Tick({
                try {
                    # Stop and dispose the one-shot delay timer first
                    if ($script:autoScanTimer) {
                        $script:autoScanTimer.Stop()
                        $script:autoScanTimer.Dispose()
                        $script:autoScanTimer = $null
                    }

                    # Block concurrent scans
                    if ($script:IsScanning) { Log 'Auto-scan: skipped — scan already running'; return }
                    $script:IsScanning = $true

                    Log 'Auto-scan: Searching for X-Air mixer...'
                    if ($script:sbLeft -and -not $script:sbLeft.IsDisposed) {
                        $script:sbLeft.Text = 'Auto-scanning for X-Air mixer...'
                    }

                    $cancelToken = [ref]$false
                    $progressCallback = {
                        param($currentIP, $percent)
                        if ($script:sbLeft -and -not $script:sbLeft.IsDisposed) {
                            $script:sbLeft.Text = "Auto-scan: $currentIP ($percent%)"
                        }
                    }

                    $foundIP = XR-ScanForMixer -StartIP '' -ProgressCallback $progressCallback -CancelToken $cancelToken

                    if ($foundIP) {
                        $script:Cfg.XR.MixerIP = $foundIP
                        Save-Settings
                        Log "Auto-scan: Found and saved X-Air at $foundIP"
                        if ($script:sbLeft -and -not $script:sbLeft.IsDisposed) {
                            $script:sbLeft.Text = "Auto-scan: Found X-Air at $foundIP"
                        }
                        # Stop any pending broadcast retry — mixer is found
                        if ($script:_xrBroadcastRetryTimer) {
                            $script:_xrBroadcastRetryTimer.Stop()
                            $script:_xrBroadcastRetryTimer.Dispose()
                            $script:_xrBroadcastRetryTimer = $null
                        }
                    }
                    else {
                        Log 'Auto-scan: No X-Air mixer found — will retry broadcast every 2s'
                        if ($script:sbLeft -and -not $script:sbLeft.IsDisposed) {
                            $script:sbLeft.Text = 'Auto-scan: No X-Air found — retrying...'
                        }
                        # Start periodic broadcast retry (every 2 s) until mixer responds.
                        # Busy flag prevents overlapping ticks; log only every 20 attempts.
                        # Note: same-IP reconnection is already caught by XR-UpdateStatus (1.5s).
                        # This retry exists only for DHCP IP-change detection.
                        if (-not $script:_xrBroadcastRetryTimer) {
                            $script:_xrRetryBusy = $false
                            $script:_xrRetryCount = 0
                            $script:_xrBroadcastRetryTimer = New-Object System.Windows.Forms.Timer
                            $script:_xrBroadcastRetryTimer.Interval = 2000
                            $script:_xrBroadcastRetryTimer.Add_Tick({
                                    # Skip if XR mixer disabled, scan in progress, or previous tick still running
                                    if (-not $script:Cfg.XR.XRMixerEnabled) { return }
                                    if ($script:IsScanning) { return }
                                    if ($script:_xrRetryBusy) { return }
                                    $script:_xrRetryBusy = $true
                                    $script:_xrRetryCount++
                                    try {
                                        $retryIP = Find-XAirByBroadcast -TimeoutMs 1500 -CancelToken ([ref]$false)
                                        if ($retryIP) {
                                            $script:Cfg.XR.MixerIP = $retryIP
                                            Save-Settings
                                            Log "Broadcast retry: Found X-Air at $retryIP — saved"
                                            if ($script:sbLeft -and -not $script:sbLeft.IsDisposed) {
                                                $script:sbLeft.Text = "Broadcast retry: Found X-Air at $retryIP"
                                            }
                                            $script:_xrBroadcastRetryTimer.Stop()
                                            $script:_xrBroadcastRetryTimer.Dispose()
                                            $script:_xrBroadcastRetryTimer = $null
                                        }
                                        else {
                                            # Log only every 20 attempts (~40 s) to avoid spam
                                            if ($script:_xrRetryCount % 20 -eq 1) {
                                                Log "Broadcast retry: no reply (attempt $($script:_xrRetryCount))"
                                            }
                                        }
                                    }
                                    finally { $script:_xrRetryBusy = $false }
                                })
                            $script:_xrBroadcastRetryTimer.Start()
                        }
                    }
                }
                catch {
                    Log "Auto-scan async error: $_"
                    if ($script:sbLeft -and -not $script:sbLeft.IsDisposed) {
                        $script:sbLeft.Text = 'Auto-scan failed'
                    }
                    if ($script:autoScanTimer) {
                        $script:autoScanTimer.Stop()
                        $script:autoScanTimer.Dispose()
                        $script:autoScanTimer = $null
                    }
                }
                finally {
                    $script:IsScanning = $false
                }
            })
        $script:autoScanTimer.Start()
    }
    catch {
        Log "Auto-scan async init error: $_"
        
        # Clean up timer on init error
        if ($script:autoScanTimer) {
            $script:autoScanTimer.Stop()
            $script:autoScanTimer.Dispose()
            $script:autoScanTimer = $null
        }
    }
}



# Check if WASAPI audio is active (direct Windows audio monitoring)
function Is-WasapiAudioActive {
    try {
        if (-not $script:Cfg.Audio.MonitoringEnabled) {
            return $false
        }
        if (-not $script:ObsConnected) {
            return $false
        }
        
        # Return cached state from monitoring timer (updated by OBS events)
        return $script:_audioActive
    }
    catch {
        Log "Is-WasapiAudioActive: Exception - $_"
        return $false
    }
}



# Check if Monitor XR channel level exceeds ducking threshold (via OSC meters)
function Is-MediaAudioActive {
    try {
        if (-not $script:Cfg.XR.DuckingEnabled) { return $false }
        # Read XR meter level for the configured monitor channel (updated every 50ms via OSC)
        $monCh = [int]$script:Cfg.XR.MediaChannel
        $threshDB = [double]$script:Cfg.XR.ThresholdDB
        $levelDB = -90.0
        if ($script:XrMeterLevels.Contains($monCh)) {
            $levelDB = [double]$script:XrMeterLevels[$monCh]
        }
        $audioActive = ($levelDB -gt $threshDB)
        Log-Throttled "xr-duck-check" "XR Duck: CH$monCh = $($levelDB.ToString('F1'))dB  threshold=$($threshDB)dB  active=$audioActive" 5
        return $audioActive
    }
    catch { return $false }
}

# Initialize ducking state variables
$script:_duckingActive = $false
$script:_storedPodiumFader = $null
$script:_belowThresholdSince = $null
$script:_lastMediaLevel = -90.0

# XR12 Meter polling timer - reads OSC meter packets from UDP
$script:XrMeterTimer = New-Object System.Windows.Forms.Timer
$script:XrMeterTimer.Interval = 50  # Poll every 50ms for meter packets

$script:XrMeterTimer.Add_Tick({
        # Poll for any incoming packets
        XR-PollMeterPackets
        
        # Send meter subscriptions EVERY tick so the stream doesn't expire
        try { XR-SubscribeMeters } catch {}
    })

# Initialize meter poll counter and raw dump diagnostic counter
$script:_meterPollCounter = 0
$script:_meterRawDumpCount = 0
$script:_rawPktCount = 0

# Ducking timer - monitors media level and ducks podium mic
# Uses XR12 meter data directly via OSC (not OBS audio)
$script:DuckingTimer = New-Object System.Windows.Forms.Timer
$script:DuckingTimer.Interval = 200  # Check every 200ms

$script:DuckingTimer.Add_Tick({
        try {
            # Event reader timer handles event polling
        
            # Only run if ducking is enabled
            if (-not $script:Cfg.XR.DuckingEnabled) {
                if ($script:_duckingActive) {
                    # Restore if we're ducked but ducking was disabled
                    if ($null -ne $script:_storedPodiumFader) {
                        XR-WriteFaderPosition $script:Cfg.XR.PodiumChannel $script:_storedPodiumFader
                        $script:_storedPodiumFader = $null
                    }
                    $script:_duckingActive = $false
                    if ($script:lblDuckingStatus) {
                        $script:lblDuckingStatus.Text = "Ducking: Disabled"
                        $script:lblDuckingStatus.ForeColor = [System.Drawing.Color]::Gray
                    }
                }
                return
            }

            # Suspend ducking while background music is playing — restore podium if currently ducked
            if ($script:Music._IsPlaying) {
                if ($script:_duckingActive) {
                    if ($null -ne $script:_storedPodiumFader) {
                        XR-WriteFaderPosition $script:Cfg.XR.PodiumChannel $script:_storedPodiumFader
                        $script:_storedPodiumFader = $null
                    }
                    $script:_duckingActive = $false
                    $script:_belowThresholdSince = $null
                }
                if ($script:lblDuckingStatus) {
                    $script:lblDuckingStatus.Text = "Ducking: Paused (music playing)"
                    $script:lblDuckingStatus.ForeColor = [System.Drawing.Color]::CornflowerBlue
                }
                return
            }
        
            # Check if Media scene has active audio (both scene active AND audio playing)
            $mediaAudioActive = Is-MediaAudioActive
        
            # Update status display
            if ($script:lblDuckingStatus) {
                $mediaScene = [string]$script:Cfg.OBS.SceneMed
                $currentScene = [string]$script:_lastProgramScene
                $isMediaScene = [string]::Equals($currentScene, $mediaScene, [StringComparison]::InvariantCultureIgnoreCase)
                
                $statusText = "Ducking: "
                if ($isMediaScene) {
                    $statusText += "Media scene"
                    if ($mediaAudioActive) {
                        $statusText += " + Audio"
                    }
                    else {
                        $statusText += " (no audio)"
                    }
                }
                else {
                    $statusText += "Other scene"
                }
                
                if ($script:_duckingActive) {
                    $statusText += " [DUCKED]"
                }
                $script:lblDuckingStatus.Text = $statusText
            }
        
            # State machine: Check if we should duck
            if ($mediaAudioActive -and -not $script:_duckingActive) {
                # Media scene is active WITH audio, start ducking
                $podiumChannel = $script:Cfg.XR.PodiumChannel
                $currentFader = XR-ReadFaderPosition $podiumChannel
                $script:_storedPodiumFader = $currentFader
            
                # Calculate ducked level
                $duckAmountDB = $script:Cfg.XR.DuckAmountDB  # This is negative, e.g. -15
                $currentDB = ConvertTo-Decibels $currentFader
                $duckedDB = $currentDB + $duckAmountDB  # e.g. 0 + (-15) = -15
                $duckedLinear = ConvertTo-LinearFader $duckedDB
            
                # Apply ducking
                XR-WriteFaderPosition $podiumChannel $duckedLinear
                $script:_duckingActive = $true
                $script:_belowThresholdSince = $null
            
                Log "XR Ducking: Media audio active"
                Log "  Current: $($currentDB.ToString('F1')) dB (linear: $($currentFader.ToString('F3')))"
                Log "  Ducking by: $duckAmountDB dB"
                Log "  Target: $($duckedDB.ToString('F1')) dB (linear: $($duckedLinear.ToString('F3')))"
            
                if ($script:lblDuckingStatus) {
                    $script:lblDuckingStatus.ForeColor = [System.Drawing.Color]::Orange
                }
            }
            # State machine: Check if we should restore
            elseif (-not $mediaAudioActive -and $script:_duckingActive) {
                # Media audio is not active (scene changed or audio stopped), check hold time
                if ($null -eq $script:_belowThresholdSince) {
                    $script:_belowThresholdSince = Get-Date
                }
            
                $elapsed = ((Get-Date) - $script:_belowThresholdSince).TotalMilliseconds
                if ($elapsed -ge $script:Cfg.XR.HoldTimeMS) {
                    # Hold time elapsed, restore podium
                    if ($null -ne $script:_storedPodiumFader) {
                        $restoredDB = ConvertTo-Decibels $script:_storedPodiumFader
                        XR-WriteFaderPosition $script:Cfg.XR.PodiumChannel $script:_storedPodiumFader
                        Log "XR Ducking: Media audio stopped, restoring podium to $($restoredDB.ToString('F1')) dB (linear: $($script:_storedPodiumFader.ToString('F3')))"
                    }
                
                    $script:_duckingActive = $false
                    $script:_storedPodiumFader = $null
                    $script:_belowThresholdSince = $null
                    $script:_audioActive = $false  # Clear audio active flag when releasing duck
                
                    if ($script:lblDuckingStatus) {
                        $script:lblDuckingStatus.ForeColor = [System.Drawing.Color]::Green
                    }
                }
            }
            # Reset hold timer if media audio becomes active again
            elseif ($mediaAudioActive -and $script:_duckingActive) {
                $script:_belowThresholdSince = $null
            }

            # ── Rover (Reader) Ducking ──────────────────────────────────────
            # Monitors XR OSC meter for RoverMonitorChannel and ducks RoverChannel1 + RoverChannel2
            # Only active when checkbox enabled AND the active XR snapshot matches (or Any is selected)
            if ($script:Cfg.XR.RoverDuckingEnabled) {
                $roverSnapTarget = [int]$script:Cfg.XR.RoverActiveSnapshot
                $activeSnap = [int]$script:_activeXrSnapshot
                # 0 = Any (always active); otherwise must match the selected snapshot
                $isRoverScene = ($roverSnapTarget -eq 0) -or ($activeSnap -eq $roverSnapTarget)

                # If snapshot changed away while ducked, restore immediately
                if (-not $isRoverScene) {
                    if ($script:_roverDuckingActive) {
                        if ($null -ne $script:_storedRoverCh1Fader) { XR-WriteFaderPosition $script:Cfg.XR.RoverChannel1 $script:_storedRoverCh1Fader }
                        if ($null -ne $script:_storedRoverCh2Fader) { XR-WriteFaderPosition $script:Cfg.XR.RoverChannel2 $script:_storedRoverCh2Fader }
                        $script:_roverDuckingActive = $false
                        $script:_storedRoverCh1Fader = $null
                        $script:_storedRoverCh2Fader = $null
                        $script:_roverBelowThresholdSince = $null
                        Log "Rover Ducking: snapshot changed away (active=$activeSnap target=$roverSnapTarget) - channels restored"
                    }
                }
                else {
                    # Read XR meter level for the Rover monitor channels (already dB, via OSC)
                    $roverMonCh = [int]$script:Cfg.XR.RoverMonitorChannel
                    $roverMonCh2 = [int]$script:Cfg.XR.RoverMonitorChannel2
                    $roverThreshDB = [double]$script:Cfg.XR.RoverThresholdDB
                    $roverLevelDB = -90.0
                    if ($script:XrMeterLevels.Contains($roverMonCh)) { $roverLevelDB = [double]$script:XrMeterLevels[$roverMonCh] }
                    $roverLevelDB2 = -90.0
                    if ($script:XrMeterLevels.Contains($roverMonCh2)) { $roverLevelDB2 = [double]$script:XrMeterLevels[$roverMonCh2] }
                    $readerAudioActive = ($roverLevelDB -gt $roverThreshDB) -or ($roverLevelDB2 -gt $roverThreshDB)
                    Log-Throttled "xr-rover-check" "XR Rover: CH$roverMonCh=$($roverLevelDB.ToString('F1'))dB CH$roverMonCh2=$($roverLevelDB2.ToString('F1'))dB threshold=$($roverThreshDB)dB active=$readerAudioActive" 5

                    if ($readerAudioActive -and -not $script:_roverDuckingActive) {
                        # Reader audio detected — store and duck both rover channels
                        $ch1 = $script:Cfg.XR.RoverChannel1
                        $ch2 = $script:Cfg.XR.RoverChannel2
                        $duckAmountDB = $script:Cfg.XR.RoverDuckAmountDB

                        $fader1 = XR-ReadFaderPosition $ch1
                        $fader2 = XR-ReadFaderPosition $ch2
                        $script:_storedRoverCh1Fader = $fader1
                        $script:_storedRoverCh2Fader = $fader2

                        $duckedLinear1 = ConvertTo-LinearFader ([double](ConvertTo-Decibels $fader1) + $duckAmountDB)
                        $duckedLinear2 = ConvertTo-LinearFader ([double](ConvertTo-Decibels $fader2) + $duckAmountDB)

                        XR-WriteFaderPosition $ch1 $duckedLinear1
                        XR-WriteFaderPosition $ch2 $duckedLinear2
                        $script:_roverDuckingActive = $true
                        $script:_roverBelowThresholdSince = $null

                        Log "Rover Ducking: Reader audio active - ducking ch$ch1 and ch$ch2 by $duckAmountDB dB"
                    }
                    elseif (-not $readerAudioActive -and $script:_roverDuckingActive) {
                        # Reader audio dropped — apply hold time before restoring
                        if ($null -eq $script:_roverBelowThresholdSince) {
                            $script:_roverBelowThresholdSince = Get-Date
                        }
                        $elapsed = ((Get-Date) - $script:_roverBelowThresholdSince).TotalMilliseconds
                        if ($elapsed -ge $script:Cfg.XR.RoverHoldTimeMS) {
                            if ($null -ne $script:_storedRoverCh1Fader) {
                                XR-WriteFaderPosition $script:Cfg.XR.RoverChannel1 $script:_storedRoverCh1Fader
                            }
                            if ($null -ne $script:_storedRoverCh2Fader) {
                                XR-WriteFaderPosition $script:Cfg.XR.RoverChannel2 $script:_storedRoverCh2Fader
                            }
                            $script:_roverDuckingActive = $false
                            $script:_storedRoverCh1Fader = $null
                            $script:_storedRoverCh2Fader = $null
                            $script:_roverBelowThresholdSince = $null
                            Log "Rover Ducking: Reader audio stopped - rover channels restored"
                        }
                    }
                    elseif ($readerAudioActive -and $script:_roverDuckingActive) {
                        # Still active — reset hold timer
                        $script:_roverBelowThresholdSince = $null
                    }
                } # end isRoverScene
            }
            elseif ($script:_roverDuckingActive) {
                # Rover ducking disabled while active — restore immediately
                if ($null -ne $script:_storedRoverCh1Fader) {
                    XR-WriteFaderPosition $script:Cfg.XR.RoverChannel1 $script:_storedRoverCh1Fader
                }
                if ($null -ne $script:_storedRoverCh2Fader) {
                    XR-WriteFaderPosition $script:Cfg.XR.RoverChannel2 $script:_storedRoverCh2Fader
                }
                $script:_roverDuckingActive = $false
                $script:_storedRoverCh1Fader = $null
                $script:_storedRoverCh2Fader = $null
                $script:_roverBelowThresholdSince = $null
            }
        }
        catch {
            Log "XR Ducking error: $_"
            if ($script:lblDuckingStatus) {
                $script:lblDuckingStatus.Text = "Ducking: Error - $_"
                $script:lblDuckingStatus.ForeColor = [System.Drawing.Color]::Red
            }
        }
    })

# ---- Zoom Audio Raise Timer ----
$script:ZoomRaiseTimer = New-Object System.Windows.Forms.Timer
$script:ZoomRaiseTimer.Interval = 200  # Check every 200ms
$script:_zoomRaiseBelowThresholdSince = $null
$script:ZoomRaiseTimer.Add_Tick({
        try {
            if (-not $script:Cfg.Zoom.AutoZoomAudio) { return }
            if (-not $script:Cfg.OBSControl.AutoStartAutoToggle) { return }
            if ($script:ShuttingDown) { return }
        
            # Check if Zoom audio is active
            $zoomAudioActive = $script:_zoomAudioActive
        
            # State machine: Check if we should raise the fader
            if ($zoomAudioActive -and -not $script:_zoomFaderRaised) {
                # Zoom audio detected and fader not yet raised
                $zoomLine = $script:Cfg.Zoom.ZoomInLine
                $targetDb = [double]$script:Cfg.Zoom.AudioLevelDb
            
                Log "Zoom Audio: Raising fader $zoomLine to $targetDb dB"
            
                # Convert dB to linear and send OSC command to raise the fader
                try {
                    $targetLinear = ConvertTo-LinearFader $targetDb
                    XR-WriteFaderPosition $zoomLine $targetLinear
                    $script:_zoomFaderRaised = $true
                    $script:_zoomRaiseBelowThresholdSince = $null
                    Log "Zoom Audio: Fader $zoomLine raised to $targetDb dB (linear: $($targetLinear.ToString('F3')))"
                }
                catch {
                    Log "Zoom Audio: Failed to raise fader: $_"
                }
            }
            # State machine: Check if we should lower the fader back
            elseif (-not $zoomAudioActive -and $script:_zoomFaderRaised) {
                # Zoom audio stopped, check hold time before lowering
                if ($null -eq $script:_zoomRaiseBelowThresholdSince) {
                    $script:_zoomRaiseBelowThresholdSince = Get-Date
                    Log "Zoom Audio: Starting hold time ($($script:Cfg.Zoom.HoldTimeMs)ms)"
                }
            
                $elapsed = ((Get-Date) - $script:_zoomRaiseBelowThresholdSince).TotalMilliseconds
                
                if ($elapsed -ge $script:Cfg.Zoom.HoldTimeMs) {
                    # Hold time elapsed, lower the fader back
                    $zoomLine = $script:Cfg.Zoom.ZoomInLine
                
                    Log "Zoom Audio: Lowering fader $zoomLine back to -90 dB"
                
                    try {
                        $loweredLinear = ConvertTo-LinearFader (-90.0)
                        XR-WriteFaderPosition $zoomLine $loweredLinear
                        $script:_zoomFaderRaised = $false
                        $script:_zoomAudioActive = $false  # Clear audio active flag
                        $script:_zoomRaiseBelowThresholdSince = $null
                        Log "Zoom Audio: Fader $zoomLine lowered back to -90 dB (linear: $($loweredLinear.ToString('F3')))"
                    }
                    catch {
                        Log "Zoom Audio: Failed to lower fader: $_"
                    }
                }
            }
            # Reset state if fader was manually moved down while we think it's raised
            elseif (-not $zoomAudioActive -and -not $script:_zoomFaderRaised) {
                # Audio not active and we think fader is down - this is normal, reset any stale timers
                $script:_zoomRaiseBelowThresholdSince = $null
            }
            # Audio still active, reset the threshold timer
            elseif ($zoomAudioActive -and $script:_zoomFaderRaised) {
                $script:_zoomRaiseBelowThresholdSince = $null
            }
        }
        catch {
            Log "Zoom Audio Raise error: $_"
        }
    })

# ---- Meeting schedule & actions ----
$script:running = $false
function Set-Chip($m) {
    switch ($m) {
        'Present' { $script:chip.BackColor = [System.Drawing.Color]::FromArgb(0, 128, 0); $script:chip.Text = 'Present' }
        'Absent' { $script:chip.BackColor = [System.Drawing.Color]::FromArgb(180, 0, 0); $script:chip.Text = 'Absent' }
        default { $script:chip.BackColor = [System.Drawing.Color]::FromArgb(128, 128, 128); $script:chip.ForeColor = [System.Drawing.Color]::White; $script:chip.Text = 'Inactive' }
    }
}
function Set-RunStateUI($r) {
    if ($r) { 
        $script:sbLeft.Text = "Auto running…"; 
        $btnAuto.Text = "Stop Auto Toggle"
        $btnAuto.BackColor = [System.Drawing.Color]::FromArgb(0, 192, 0)
        $btnAuto.ForeColor = [System.Drawing.Color]::Black
    }
    else { 
        $script:sbLeft.Text = "Idle"; 
        $btnAuto.Text = "Start Auto Toggle"
        # Use consistent red color when inactive (not theme colors)
        $btnAuto.BackColor = [System.Drawing.Color]::FromArgb(192, 0, 0)
        $btnAuto.ForeColor = [System.Drawing.Color]::White
    }
    # Keep Toggle Zoom enabled so click fires; the click handler shows a warning if running
    Set-Chip "Inactive"
}
function Start-AutoToggle {
    param([switch]$Silent)
    if ($script:running) { return }
    $script:_zoomWarningShownThisToggle = $false  # reset guard for this activation
    
    # Check if ROI is properly set before starting Auto Toggle (same validation as Grab-ROI)
    $tl = $script:Cfg.ROI.TL; $br = $script:Cfg.ROI.BR
    if (-not $tl -or -not $br) {
        [System.Windows.Forms.MessageBox]::Show($script:form, "ROI not set or invalid!", "Auto Toggle", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        return
    }
    $w = [math]::Abs($br.X - $tl.X); $h = [math]::Abs($br.Y - $tl.Y)
    if ($w -le 0 -or $h -le 0) {
        [System.Windows.Forms.MessageBox]::Show($script:form, "ROI not set or invalid!", "Auto Toggle", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        return
    }
    
    # When starting Auto Toggle MANUALLY, warn once about Zoom mic/camera state
    # When called with -Silent (auto-start path), fix state quietly without a blocking dialog
    if ($Silent) {
        try { Show-ZoomAutoToggleWarning -Silent } catch {}
    }
    else {
        try { Show-ZoomAutoToggleWarning } catch {}
    }
    
    # Stop background music and disable music button when Auto Toggle starts
    try {
        if (Music-IsPlaying) {
            Log "Auto Toggle: Stopping background music"
            $ms = [int]([math]::Max(200, $script:Music.FadeOutSeconds * 1000))
            Music-FadeOut -ms $ms -StopAfter $true
        }
        # Disable music button while Auto Toggle is active
        if ($btnMusicToggle) {
            $btnMusicToggle.Enabled = $false
            $btnMusicToggle.Text = "Music Disabled (Auto Toggle Active)"
            Log "Auto Toggle: Music button disabled"
        }
    }
    catch {
        Log "Auto Toggle: Error stopping music: $_"
    }
    
    # Check and start OBS Virtual Camera if it's off
    try {
        if (-not $script:VirtualCameraStatus) {
            Log "Auto Toggle: Starting OBS Virtual Camera (was off)"
            if (Invoke-ObsRequest "StartVirtualCam" @{}) {
                Log "Auto Toggle: Virtual Camera start command sent"
            }
        }
        else {
            Log "Auto Toggle: Virtual Camera already on, continuing"
        }
    }
    catch {
        Log "Auto Toggle: Error checking/starting virtual camera: $_"
    }
    
    $script:_lastHit = $null; $script:_stableCount = 0; $script:_lastSwitch = Get-Date
    $script:running = $true; $scanTimer.Start(); Set-RunStateUI $true; Log "Auto started (OCR → scenes)"

    # Grey-out Zoom mic and camera buttons while Auto Toggle is active.
    # Mic and camera MUST stay ON during a live meeting - locking prevents accidental toggling.
    try {
        if ($btnZoomMic -and $script:ZoomParticipantFound) {
            $btnZoomMic.Enabled = $false
            $script:ZoomMicLocked = $true
            $btnZoomMic.Refresh()  # Trigger Paint to draw red slash
            if ($script:tooltip) { $script:tooltip.SetToolTip($btnZoomMic, 'Locked: Auto Toggle is active — mic must stay ON during meeting') }
            Log 'Auto Toggle: Zoom mic button locked (red slash indicator shown)'
        }
        if ($btnZoomCamera -and $script:ZoomParticipantFound) {
            $btnZoomCamera.Enabled = $false
            $script:ZoomCamLocked = $true
            $btnZoomCamera.Refresh()  # Trigger Paint to draw red slash
            if ($script:tooltip) { $script:tooltip.SetToolTip($btnZoomCamera, 'Locked: Auto Toggle is active — camera must stay ON during meeting') }
            Log 'Auto Toggle: Zoom camera button locked (red slash indicator shown)'
        }
    }
    catch { Log "Auto Toggle: Error locking Zoom buttons: $_" }
}
function Stop-AutoToggle {
    if (-not $script:running) { return }
    $script:running = $false; $scanTimer.Stop(); Set-RunStateUI $false; Log "Auto stopped"

    # Re-enable Zoom mic/camera buttons and restore normal tooltips
    try {
        if ($btnZoomMic -and $script:ZoomParticipantFound) {
            $btnZoomMic.Enabled = $true
            $script:ZoomMicLocked = $false
            $btnZoomMic.Refresh()  # Remove red slash
            if ($script:tooltip) { $script:tooltip.SetToolTip($btnZoomMic, 'Microphone status and toggle (Alt+A). Green=ON, Red=Muted') }
            Log 'Auto Toggle: Zoom mic button unlocked (red slash removed)'
        }
        if ($btnZoomCamera -and $script:ZoomParticipantFound) {
            $btnZoomCamera.Enabled = $true
            $script:ZoomCamLocked = $false
            $btnZoomCamera.Refresh()  # Remove red slash
            if ($script:tooltip) { $script:tooltip.SetToolTip($btnZoomCamera, 'Camera status and toggle (Alt+V). Green=ON, Red=Off') }
            Log 'Auto Toggle: Zoom camera button unlocked (red slash removed)'
        }
    }
    catch { Log "Auto Toggle: Error unlocking Zoom buttons: $_" }
    
    # Re-enable music button when Auto Toggle stops
    try {
        if ($btnMusicToggle) {
            $btnMusicToggle.Enabled = $true
            $btnMusicToggle.Text = "Play Background Music"
            Log "Auto Toggle: Music button re-enabled"
        }
    }
    catch {
        Log "Auto Toggle: Error re-enabling music button: $_"
    }
}

$script:OcrIntervalMs = 300
$script:ConfirmHits = 1
$script:MinSwitchMs = 1000
$script:_lastHit = $null
$script:_stableCount = 0
$script:_lastSwitch = Get-Date
$script:_ocrBroken = $null       # $null=never tested, $false=working, $true=config broken
$script:_ocrBrokenCount = 0      # consecutive structural failures (ROI/Tesseract)
$script:_ocrBrokenAlerted = $false  # one-time D-alert already shown this session
$script:_lastOcrText = $null     # last text returned by Tesseract (null=never run)

# Async OCR state — Tesseract runs as a fire-and-forget process; no UI blocking
$script:_ocrProc = $null
$script:_ocrPngTmp = $null
$script:_ocrOutBase = $null
$scanTimer = New-Object System.Windows.Forms.Timer
$scanTimer.Interval = $script:OcrIntervalMs
$scanTimer.Add_Tick({
        if (-not $script:running) { return }
        if ($script:_ftbActive) { return }   # don't OCR-switch during fade-to-black sequence
        if (-not $script:Cfg.ROI.TL -or -not $script:Cfg.ROI.BR) { $script:sbLeft.Text = "ROI not set."; Set-OcrHealth $false; return }
        if (-not (Test-Path $script:Cfg.Tesseract)) { $script:sbLeft.Text = "Tesseract path invalid."; Set-OcrHealth $false; return }

        # ── Collect result when Tesseract process has finished ──────────────────
        if ($null -ne $script:_ocrProc) {
            if (-not $script:_ocrProc.HasExited) { return }   # still running — wait next tick
            $txt = ''
            try {
                if ($script:_ocrOutBase -and (Test-Path $script:_ocrOutBase)) {
                    $raw = Get-Content $script:_ocrOutBase -Raw -ErrorAction SilentlyContinue
                    $txt = if ($raw) { ($raw -replace '\s+', ' ').Trim() } else { '' }
                }
            }
            catch {}
            try { $script:_ocrProc.Dispose() } catch {}
            try { Remove-Item $script:_ocrPngTmp  -ErrorAction SilentlyContinue } catch {}
            try { Remove-Item $script:_ocrOutBase -ErrorAction SilentlyContinue } catch {}
            $script:_ocrProc = $null; $script:_ocrPngTmp = $null; $script:_ocrOutBase = $null
            Set-OcrHealth $true   # Tesseract completed — OCR pipeline is functional

            $kw = [string]$script:Cfg.Keyword
            $hit = ($txt -and -not [string]::IsNullOrWhiteSpace($kw) -and $txt.ToLower().Contains($kw.ToLower()))
            $script:_lastOcrText = $txt
            Update-JwlOcrTooltip
            $chipVal = if ($hit) { 'Present' } else { 'Absent' }
            $ocrLabel = if ($hit) { 'hit' } else { 'miss' }
            Set-Chip $chipVal; $script:sbLeft.Text = 'OCR: ' + $ocrLabel

            if ($null -eq $script:_lastHit) { $script:_lastHit = $hit; $script:_stableCount = 1 }
            elseif ($hit -eq $script:_lastHit) { $script:_stableCount++ }
            else { $script:_lastHit = $hit; $script:_stableCount = 1 }

            if ($script:_stableCount -ge $script:ConfirmHits) {
                $since = (Get-Date) - $script:_lastSwitch
                if ($since.TotalMilliseconds -ge $script:MinSwitchMs) {
                    $camScene = Get-CameraScene
                    if ($hit) {
                        # Return to whatever was live before we switched to Media (if known),
                        # else fall back to current non-media Program scene, else to selected camera scene.
                        $target = $null
                        if ($script:_preMediaScene -and -not [string]::IsNullOrWhiteSpace($script:_preMediaScene)) {
                            $target = $script:_preMediaScene
                        }
                        elseif ($script:_lastProgramScene -and -not [string]::Equals($script:_lastProgramScene, $script:Cfg.OBS.SceneMed, 'InvariantCultureIgnoreCase')) {
                            $target = $script:_lastProgramScene
                        }
                        else {
                            $target = $camScene
                        }
                        if (Program-Switch $target) { $script:_preMediaScene = $null }
                    }
                    else {
                        # Going to Media: remember where we were so we can come back
                        if ($script:_lastProgramScene -and -not [string]::Equals($script:_lastProgramScene, $script:Cfg.OBS.SceneMed, 'InvariantCultureIgnoreCase')) {
                            $script:_preMediaScene = $script:_lastProgramScene
                        }
                        [void](Program-Switch $script:Cfg.OBS.SceneMed)
                    }
                    $script:_lastSwitch = Get-Date; $script:_stableCount = 0
                }
            }
            return   # result handled; new OCR pass starts on next tick
        }

        # ── Start new Tesseract pass (fire-and-forget — never blocks UI thread) ─
        $bmp = Grab-ROI
        if ($null -eq $bmp) { $script:sbLeft.Text = "ROI invalid."; Set-OcrHealth $false; return }
        $bw = $null
        try {
            $bw = Preprocess-Binary $bmp
            $pngTmp = [System.IO.Path]::ChangeExtension([System.IO.Path]::GetTempFileName(), '.png')
            $outBase = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), [System.IO.Path]::GetRandomFileName())
            $bw.Save($pngTmp, [System.Drawing.Imaging.ImageFormat]::Png)
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $script:Cfg.Tesseract
            $psi.Arguments = '"' + $pngTmp + '" "' + $outBase + '" --oem 1 --psm 6'
            $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
            $p = New-Object System.Diagnostics.Process; $p.StartInfo = $psi
            [void]$p.Start()
            $script:_ocrProc = $p
            $script:_ocrPngTmp = $pngTmp
            $script:_ocrOutBase = $outBase + '.txt'
        }
        catch { $script:sbLeft.Text = "OCR start error." }
        finally { try { $bw.Dispose() } catch {}; try { $bmp.Dispose() } catch {} }
    })
$btnAuto.Add_Click({ if (-not $script:running) { Start-AutoToggle } else { Stop-AutoToggle } })

# ---- Auto-badge overlay system ----
# Colored pill badges on auto-function buttons showing T-minus until each function fires.
# Badge only appears within 10 minutes of the auto-trigger (configurable via $script:_badge_ShowThreshold).
$script:_badge_Music = @{ Visible = $false; Text = ''; Color = [System.Drawing.Color]::Green }
$script:_badge_AutoToggle = @{ Visible = $false; Text = ''; Color = [System.Drawing.Color]::Green }
$script:_badge_VCam = @{ Visible = $false; Text = ''; Color = [System.Drawing.Color]::Green }
$script:_badge_ZoomMute = @{ Visible = $false; Text = ''; Color = [System.Drawing.Color]::Green }
$script:_badge_ZoomMic = @{ Visible = $false; Text = ''; Color = [System.Drawing.Color]::Green }
$script:_badge_ZoomCam = @{ Visible = $false; Text = ''; Color = [System.Drawing.Color]::Green }
$script:_badge_ZoomFocus = @{ Visible = $false; Text = ''; Color = [System.Drawing.Color]::Green }

function Format-BadgeTime([int]$s) {
    if ($s -ge 60) { return ([string][math]::Ceiling($s / 60)) + 'm' }
    return "${s}s"
}

function Get-BadgeColor([int]$s) {
    if ($s -ge 300) { return [System.Drawing.Color]::FromArgb(34, 160, 34) }    # green
    if ($s -ge 120) { return [System.Drawing.Color]::FromArgb(180, 155, 0) }    # yellow
    if ($s -ge 60) { return [System.Drawing.Color]::FromArgb(220, 115, 0) }    # orange
    return [System.Drawing.Color]::FromArgb(210, 30, 30)                         # red
}

# Max seconds ahead to show badge (10 min). Further away = hidden to avoid clutter.
$script:_badge_ShowThreshold = 600

function Update-AutoBadge($badge, [bool]$enabled, [int]$triggerSecs, [bool]$alreadyDone, [int]$secToMeeting) {
    if (-not $enabled -or $alreadyDone -or $secToMeeting -lt 0) { $badge.Visible = $false; return }
    $timeLeft = $secToMeeting - $triggerSecs
    if ($timeLeft -le 0 -or $timeLeft -gt $script:_badge_ShowThreshold) { $badge.Visible = $false; return }
    $badge.Visible = $true
    $badge.Text = $(Format-BadgeTime $timeLeft)
    $badge.Color = $(Get-BadgeColor $timeLeft)
}

function Update-AutoBadges([int]$secToMeeting) {
    try {
        Update-AutoBadge $script:_badge_Music `
        ([bool]$script:Cfg.Music.AutoStopBeforeMeeting) `
        ([int]$script:Cfg.Music.PreStopSeconds) `
        ([bool]$script:_meetingAutoStopped) `
            $secToMeeting
        $btnMusicToggle.Invalidate()

        Update-AutoBadge $script:_badge_AutoToggle `
        ([bool]$script:Cfg.OBSControl.AutoStartAutoToggle) `
        ([int]$script:Cfg.OBSControl.AutoToggleLeadSeconds) `
        ([bool]$script:_autoStartedToggleThisMeeting) `
            $secToMeeting
        $btnAuto.Invalidate()

        Update-AutoBadge $script:_badge_VCam `
        ([bool]$script:Cfg.OBSControl.AutoVirtualCamera) `
        ([int]$script:Cfg.OBSControl.AutoVirtualCameraSeconds) `
        ([bool]$script:_autoStartedVirtualCameraThisMeeting) `
            $secToMeeting
        if ($script:btnVCamStatus -and -not $script:btnVCamStatus.IsDisposed) { $script:btnVCamStatus.Invalidate() }

        Update-AutoBadge $script:_badge_ZoomMute `
        ([bool]$script:Cfg.Zoom.AutoMuteAll) `
        ([int]$script:Cfg.Zoom.AutoMuteSeconds) `
        ([bool]$script:_zoomMutedThisMeeting) `
            $secToMeeting
        $btnZoomMuteAll.Invalidate()
        # Drive the label below the Mute All button
        if ($script:lblZoomMuteBadge) {
            if ($script:_badge_ZoomMute.Visible) {
                $script:lblZoomMuteBadge.Text = $script:_badge_ZoomMute.Text
                $script:lblZoomMuteBadge.ForeColor = $script:_badge_ZoomMute.Color
                $script:lblZoomMuteBadge.Visible = $true
            }
            else {
                $script:lblZoomMuteBadge.Visible = $false
            }
        }

        Update-AutoBadge $script:_badge_ZoomMic `
        ([bool]$script:Cfg.Zoom.AutoUnmuteHost) `
        ([int]$script:Cfg.Zoom.AutoUnmuteSeconds) `
        ([bool]$script:_zoomUnmutedThisMeeting) `
            $secToMeeting
        # Drive the label below the mic button
        if ($script:lblZoomMicBadge) {
            if ($script:_badge_ZoomMic.Visible) {
                $script:lblZoomMicBadge.Text = $script:_badge_ZoomMic.Text
                $script:lblZoomMicBadge.ForeColor = $script:_badge_ZoomMic.Color
                $script:lblZoomMicBadge.Visible = $true
            }
            else {
                $script:lblZoomMicBadge.Visible = $false
            }
        }

        Update-AutoBadge $script:_badge_ZoomCam `
        ([bool]$script:Cfg.Zoom.AutoCameraOn) `
        ([int]$script:Cfg.Zoom.AutoCameraSeconds) `
        ([bool]$script:_zoomCameraToggledThisMeeting) `
            $secToMeeting
        # Drive the label below the camera button
        if ($script:lblZoomCamBadge) {
            if ($script:_badge_ZoomCam.Visible) {
                $script:lblZoomCamBadge.Text = $script:_badge_ZoomCam.Text
                $script:lblZoomCamBadge.ForeColor = $script:_badge_ZoomCam.Color
                $script:lblZoomCamBadge.Visible = $true
            }
            else {
                $script:lblZoomCamBadge.Visible = $false
            }
        }

        Update-AutoBadge $script:_badge_ZoomFocus `
        ([bool]$script:Cfg.Zoom.AutoFocusMode) `
        ([int]$script:Cfg.Zoom.AutoFocusSeconds) `
        ([bool]$script:_zoomFocusToggledThisMeeting) `
            $secToMeeting
        $btnZoomFocus.Invalidate()
        # Drive the label below the Focus button
        if ($script:lblZoomFocusBadge) {
            if ($script:_badge_ZoomFocus.Visible) {
                $script:lblZoomFocusBadge.Text = $script:_badge_ZoomFocus.Text
                $script:lblZoomFocusBadge.ForeColor = $script:_badge_ZoomFocus.Color
                $script:lblZoomFocusBadge.Visible = $true
            }
            else {
                $script:lblZoomFocusBadge.Visible = $false
            }
        }
    }
    catch {}
}

$script:_badgePaint = {
    param($src, $e)
    $badge = switch ($src.Tag) {
        'Music' { $script:_badge_Music }
        'AutoToggle' { $script:_badge_AutoToggle }
        'VCam' { $script:_badge_VCam }
        'ZoomMute' { $script:_badge_ZoomMute }
        'ZoomMic' { $script:_badge_ZoomMic }
        'ZoomCam' { $script:_badge_ZoomCam }
        'ZoomFocus' { $script:_badge_ZoomFocus }
        default { $null }
    }
    if (-not $badge -or -not $badge.Visible -or -not $badge.Text) { return }
    try {
        $g = $e.Graphics
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $bW = 40; $bH = 16; $r = 8
        $bx = [int]($src.Width - $bW - 3)
        $by = 2
        $brush = New-Object System.Drawing.SolidBrush($badge.Color)
        $g.FillEllipse($brush, $bx, $by, $bH, $bH)                       # left cap
        $g.FillEllipse($brush, ($bx + $bW - $bH), $by, $bH, $bH)        # right cap
        $g.FillRectangle($brush, ($bx + $r), $by, ($bW - $bH), $bH)     # middle
        $brush.Dispose()
        $font = New-Object System.Drawing.Font("Segoe UI", 7.5, [System.Drawing.FontStyle]::Bold)
        $sb = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)
        $sf = New-Object System.Drawing.StringFormat
        $sf.Alignment = [System.Drawing.StringAlignment]::Center
        $sf.LineAlignment = [System.Drawing.StringAlignment]::Center
        $sf.Trimming = [System.Drawing.StringTrimming]::Character
        $tRect = New-Object System.Drawing.RectangleF ($bx + 1), ($by + 1), ($bW - 2), ($bH - 2)
        $g.DrawString($badge.Text, $font, $sb, $tRect, $sf)
        $font.Dispose(); $sb.Dispose(); $sf.Dispose()
    }
    catch {}
}

$btnMusicToggle.Tag = 'Music'; $btnMusicToggle.Add_Paint($script:_badgePaint)
$btnAuto.Tag = 'AutoToggle'; $btnAuto.Add_Paint($script:_badgePaint)
if ($script:btnVCamStatus -and -not $script:btnVCamStatus.IsDisposed) {
    $script:btnVCamStatus.Tag = 'VCam'; $script:btnVCamStatus.Add_Paint($script:_badgePaint)
}
# Mute All, Mic, Camera and Focus use labels below the button instead of paint badges.
# Music, AutoToggle, VCam use paint badges (they are enabled buttons with sufficient width).

# --------- Meeting scheduler ---------
$script:_clockFlashOn = $false
$script:_clockCountdownMode = $false   # True when clock shows M:SS countdown instead of time
$script:_lastNextMeeting = $null
$script:_meetingAutoStopped = $false
$script:_zoomMutedThisMeeting = $false
$script:_zoomCameraToggledThisMeeting = $false
$script:_zoomUnmutedThisMeeting = $false
$script:_zoomFocusToggledThisMeeting = $false
$script:_autoStartedToggleThisMeeting = $false
$script:_xrSnapshotSentThisMeeting = $false

function Parse-TimeOfDay([string]$s) {
    if (-not $s) { return $null }
    $s = ($s.Trim() -replace '\.', ':')
    # NOTE: single custom format specifiers in TryParseExact require a % prefix (e.g. '%H' not 'H')
    $formats = @('H:mm:ss', 'HH:mm:ss', 'h:mm:ss tt', 'hh:mm:ss tt', 'h:mm tt', 'hh:mm tt', 'h:mm', 'hh:mm', 'H:mm', 'HH:mm', 'h:m tt', 'H:m', 'h tt', 'hh tt', '%H', '%h')
    $styles = [System.Globalization.DateTimeStyles]::AllowWhiteSpaces
    $out = [datetime]::MinValue
    foreach ($fmt in $formats) {
        try { if ([datetime]::TryParseExact($s, $fmt, [System.Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$out)) { return $out.TimeOfDay } } catch {}
    }
    if ([datetime]::TryParse($s, [ref]$out)) { return $out.TimeOfDay }
    return $null
}
function Get-DayIndex([string]$name) {
    if (-not $name) { return $null }
    $t = $name.Trim().ToLower()
    $map = @{'sun' = 0; 'sunday' = 0; 'mon' = 1; 'monday' = 1; 'tue' = 2; 'tues' = 2; 'tuesday' = 2; 'wed' = 3; 'wednesday' = 3; 'thu' = 4; 'thur' = 4; 'thurs' = 4; 'thursday' = 4; 'fri' = 5; 'friday' = 5; 'sat' = 6; 'saturday' = 6 }
    return $map[$t]
}
function Get-NextMeeting([datetime]$now) {
    $cands = @()
    foreach ($raw in @($script:Cfg.Meeting.Lines)) {
        if ([string]::IsNullOrWhiteSpace($raw)) { continue }
        $line = ($raw -as [string]).Trim() -replace '\s+', ' '
        $m = [regex]::Match($line, '^\s*(?<day>[A-Za-z]{3,9})\s+(?<time>.+)$')
        $dow = $null; $tstr = $null
        if ($m.Success) { $dow = $m.Groups['day'].Value; $tstr = $m.Groups['time'].Value }
        else { $dow = $null; $tstr = $line }

        $tod = Parse-TimeOfDay $tstr
        if ($null -eq $tod) { Log "Meeting parse skipped: '$line'"; continue }

        if ($dow) {
            $idx = Get-DayIndex $dow; if ($null -eq $idx) { Log "Unknown day: '$dow'"; continue }
            $daysAhead = ($idx - [int]$now.DayOfWeek); if ($daysAhead -lt 0) { $daysAhead += 7 }
            $dt = (Get-Date ($now.Date.AddDays($daysAhead) + $tod)); if ($dt -le $now) { $dt = $dt.AddDays(7) }
            $cands += $dt
        }
        else {
            $dt = (Get-Date ($now.Date + $tod)); if ($dt -le $now) { $dt = $dt.AddDays(1) }
            $cands += $dt
        }
    }
    if ($cands.Count -eq 0) { return $null }
    return ($cands | Sort-Object)[0]
}

$script:meetingTimer = New-Object System.Windows.Forms.Timer
$script:meetingTimer.Interval = 1000

$script:meetingTimer.Add_Tick({
        try {
            $now = Get-Date
            $next = Get-NextMeeting $now

            if (-not $next) {
                $lblNext.Text = "Next: —"

                # reset UI/flags
                if ($btnClock.BackColor -ne $script:_clockDefaultBackColor) {
                    $btnClock.BackColor = $script:_clockDefaultBackColor
                }
                $btnClock.ForeColor = [System.Drawing.Color]::Black
                $script:_clockFlashOn = $false
                $script:_clockCountdownMode = $false
                $script:_meetingAutoStopped = $false
                $script:_zoomMutedThisMeeting = $false
                $script:_zoomCameraToggledThisMeeting = $false
                $script:_zoomUnmutedThisMeeting = $false
                $script:_zoomFocusToggledThisMeeting = $false
                $script:_autoStartedToggleThisMeeting = $false
                $script:_autoStartedVirtualCameraThisMeeting = $false
                $script:_xrSnapshotSentThisMeeting = $false
                $script:_lastNextMeeting = $null

                foreach ($k in @($script:_ActiveReminders.Keys)) {
                    try { $script:_ActiveReminders[$k].Close() } catch {}
                    try { $script:_ActiveReminders.Remove($k) | Out-Null } catch {}
                }
                Update-AutoBadges -99999   # no meeting — clear all badges
                return
            }

            if (-not $script:_lastNextMeeting -or $script:_lastNextMeeting -ne $next) {
                Log ("Next meeting: " + $next.ToString("ddd HH:mm:ss"))
                $script:_lastNextMeeting = $next
                $script:_meetingAutoStopped = $false
                $script:_zoomMutedThisMeeting = $false
                $script:_zoomCameraToggledThisMeeting = $false
                $script:_zoomUnmutedThisMeeting = $false
                $script:_zoomFocusToggledThisMeeting = $false
                $script:_autoStartedToggleThisMeeting = $false
                $script:_autoStartedVirtualCameraThisMeeting = $false
                $script:_xrSnapshotSentThisMeeting = $false
                $script:_clockFlashOn = $false
            }

            $sec = [int]([math]::Round(($next - $now).TotalSeconds))
            $absSec = [math]::Abs($sec)
            $tH = [math]::Floor($absSec / 3600)
            $tM = [math]::Floor(($absSec % 3600) / 60)
            $tS = $absSec % 60
            $tStr = if ($tH -gt 0) { "${tH}h ${tM}m ${tS}s" } elseif ($tM -gt 0) { "${tM}m ${tS}s" } else { "${tS}s" }
            $tLabel = if ($sec -ge 0) { "T-$tStr" } else { "T+$tStr" }
            $lblNext.Text = "Next: " + $next.ToString("ddd h:mm tt") + "  ($tLabel)"
            Update-AutoBadges $sec

            # Auto-stop background music before meeting
            if ($script:Cfg.Music.AutoStopBeforeMeeting -and $sec -ge 0 -and
                $sec -le [int]$script:Cfg.Music.PreStopSeconds -and
                -not $script:_meetingAutoStopped) {
                if (Music-IsPlaying) {
                    $ms = [int]([math]::Max(200, $script:Music.FadeOutSeconds * 1000))
                    Music-FadeOut -ms $ms -StopAfter $true
                    Log "Background music fading out ($sec s to meeting)"
                }
                $script:_meetingAutoStopped = $true
            }

            # Auto-start Auto Toggle shortly before meeting
            if ($script:Cfg.OBSControl.AutoStartAutoToggle -and $sec -ge 0 -and
                $sec -le [int]$script:Cfg.OBSControl.AutoToggleLeadSeconds -and
                -not $script:_autoStartedToggleThisMeeting) {
                # Set guard FIRST — prevents re-entry on every subsequent timer tick
                # while Start-AutoToggle is executing (it can call Focus-ZoomWindow etc.)
                $script:_autoStartedToggleThisMeeting = $true
                # -Silent: auto-start path never shows a blocking MessageBox dialog
                Start-AutoToggle -Silent
                Log "Auto Toggle started (T-$sec s)"
            }

            # Auto-start Virtual Camera shortly before meeting
            if ($script:Cfg.OBSControl.AutoVirtualCamera -and $sec -ge 0 -and
                $sec -le [int]$script:Cfg.OBSControl.AutoVirtualCameraSeconds -and
                -not $script:_autoStartedVirtualCameraThisMeeting) {
                if (-not $script:VirtualCameraStatus) {
                    try {
                        Send-ObsRequest "StartVirtualCam" @{} | Out-Null
                        Log "Auto Virtual Camera started (T-$sec s)"
                        $script:_autoStartedVirtualCameraThisMeeting = $true
                    }
                    catch {
                        Log "Auto Virtual Camera failed: $_"
                    }
                }
                else {
                    Log "Auto Virtual Camera: already running"
                    $script:_autoStartedVirtualCameraThisMeeting = $true
                }
            }

            # Auto mute everyone in Zoom N seconds before meeting
            if ($script:Cfg.Zoom.AutoMuteAll -and $sec -ge 0 -and
                $sec -le [int]$script:Cfg.Zoom.AutoMuteSeconds -and
                -not $script:_zoomMutedThisMeeting) {
                if (Zoom-MuteAll) { $script:_zoomMutedThisMeeting = $true }
            }

            # Auto unmute host (self) N seconds before meeting, but only if mic is currently muted
            if ($script:Cfg.Zoom.AutoUnmuteHost -and $sec -ge 0 -and
                $sec -le [int]$script:Cfg.Zoom.AutoUnmuteSeconds -and
                -not $script:_zoomUnmutedThisMeeting) {
                if (Zoom-UnmuteIfMuted) { $script:_zoomUnmutedThisMeeting = $true }
            }

            # Auto toggle Zoom camera ON N seconds before meeting
            if ($script:Cfg.Zoom.AutoCameraOn -and $sec -ge 0 -and
                $sec -le [int]$script:Cfg.Zoom.AutoCameraSeconds -and
                -not $script:_zoomCameraToggledThisMeeting) {
                if (Zoom-CameraOn) { $script:_zoomCameraToggledThisMeeting = $true }
            }

            # Auto prepare Zoom Focus Mode N seconds before meeting
            if ($script:Cfg.Zoom.AutoFocusMode -and $sec -ge 0 -and
                $sec -le [int]$script:Cfg.Zoom.AutoFocusSeconds -and
                -not $script:_zoomFocusToggledThisMeeting -and
                -not $script:ZoomFocusModeOn) {
                # Only attempt to turn Focus Mode ON (do not auto-stop).
                # Optimistic lock: prevent re-entry on every countdown second while runspace is working
                $script:_zoomFocusToggledThisMeeting = $true
                Start-FocusModeRunspace -FromAutoTimer
            }

            # Auto-switch to ScenePTZ scenes before meeting
            foreach ($ptz in @($script:Cfg.ScenePTZ)) {
                if (-not $ptz) { continue }
                if (-not $ptz.AutoStart) { continue }
                if (-not $ptz.Scene) { continue }
      
                $leadSec = [int]$ptz.AutoStartSeconds
                $flagKey = "_scenePTZ_$($ptz.Scene)_switched"
      
                # Get or create the flag variable
                $flagValue = $false
                try {
                    $flagValue = Get-Variable -Name $flagKey -Scope Script -ValueOnly -ErrorAction SilentlyContinue
                }
                catch {
                    Set-Variable -Name $flagKey -Value $false -Scope Script
                    $flagValue = $false
                }
      
                if ($sec -ge 0 -and $sec -le $leadSec -and -not $flagValue) {
                    # Only attempt scene switch if OBS is connected
                    if ($script:ObsConnected) {
                        Program-Switch $ptz.Scene
                        $script:SelectedScene = $ptz.Scene
                        $script:_preMediaScene = $null
                        try { $btnCam.Text = $ptz.Scene } catch {}
            
                        # Load the XR snapshot if configured
                        if ($null -ne $ptz.Snapshot) {
                            XR-LoadSnapshot ([int]$ptz.Snapshot)
                        }
            
                        Log "Auto-switched to scene '$($ptz.Scene)' (T-$sec s, lead=$leadSec s)"
                        Set-Variable -Name $flagKey -Value $true -Scope Script
                    }
                    else {
                        Log "Auto-switch delayed: '$($ptz.Scene)' (T-$sec s, lead=$leadSec s) - OBS not connected"
                    }
                }
      
                # Reset flag after meeting starts
                if ($sec -lt -5 -and $flagValue) {
                    Set-Variable -Name $flagKey -Value $false -Scope Script
                }
            }

            # Popup reminders (positive = before start, negative = after start)
            $rem1Sec = [int]$script:Cfg.Reminders.Seconds
            if ($script:Cfg.Reminders.ZoomEnabled) {
                if (($rem1Sec -ge 0 -and $sec -ge 0 -and $sec -le $rem1Sec) -or
                    ($rem1Sec -lt 0 -and $sec -lt 0 -and $sec -ge $rem1Sec)) {
                    Show-ZoomReminderPopup $next 1
                }
            }
            $rem2Sec = [int]$script:Cfg.Reminders.Reminder2Seconds
            if ($script:Cfg.Reminders.Reminder2Enabled) {
                if (($rem2Sec -ge 0 -and $sec -ge 0 -and $sec -le $rem2Sec) -or
                    ($rem2Sec -lt 0 -and $sec -lt 0 -and $sec -ge $rem2Sec)) {
                    Show-ZoomReminderPopup $next 2
                }
            }
            Close-ReminderIfDue $next $sec

            # 5-minute countdown: show M:SS on clock and flash green→yellow→red
            if ($sec -ge 0 -and $sec -le 300) {
                $script:_clockCountdownMode = $true
                $cdMin = [Math]::Floor($sec / 60)
                $cdSec = $sec % 60
                $btnClock.Text = ("{0}:{1:D2}" -f $cdMin, $cdSec)

                $script:_clockFlashOn = -not $script:_clockFlashOn

                if ($sec -le 15) {
                    # Last 15 seconds: flash RED  (honors the FlashClockRedLast15 setting)
                    if ($script:Cfg.Meeting.FlashClockRedLast15) {
                        $btnClock.BackColor = if ($script:_clockFlashOn) {
                            [System.Drawing.Color]::FromArgb(220, 0, 0)
                        }
                        else {
                            [System.Drawing.Color]::FromArgb(255, 120, 120)
                        }
                        $btnClock.ForeColor = [System.Drawing.Color]::White
                    }
                }
                elseif ($sec -le 60) {
                    # 1 min down to 15 sec: flash YELLOW
                    $btnClock.BackColor = if ($script:_clockFlashOn) {
                        [System.Drawing.Color]::FromArgb(240, 180, 0)
                    }
                    else {
                        [System.Drawing.Color]::FromArgb(255, 235, 130)
                    }
                    $btnClock.ForeColor = [System.Drawing.Color]::Black
                }
                else {
                    # 5 min down to 1 min: flash GREEN
                    $btnClock.BackColor = if ($script:_clockFlashOn) {
                        [System.Drawing.Color]::FromArgb(0, 170, 0)
                    }
                    else {
                        [System.Drawing.Color]::FromArgb(140, 230, 140)
                    }
                    $btnClock.ForeColor = [System.Drawing.Color]::Black
                }
            }
            else {
                # Outside the 5-minute window — restore normal clock display
                if ($script:_clockCountdownMode) {
                    $script:_clockCountdownMode = $false
                    $btnClock.ForeColor = [System.Drawing.Color]::Black
                }
                if ($btnClock.BackColor -ne $script:_clockDefaultBackColor) {
                    $btnClock.BackColor = $script:_clockDefaultBackColor
                }
            }

            # Reset per-meeting flags a few seconds after start
            if ($sec -lt -5) {
                $script:_meetingAutoStopped = $false
                $script:_zoomMutedThisMeeting = $false
                $script:_zoomCameraToggledThisMeeting = $false
                $script:_zoomFocusToggledThisMeeting = $false
                $script:_autoStartedToggleThisMeeting = $false
                $script:_autoStartedVirtualCameraThisMeeting = $false
                $script:_xrSnapshotSentThisMeeting = $false
                $script:_clockFlashOn = $false
                $script:_clockCountdownMode = $false
                $btnClock.ForeColor = [System.Drawing.Color]::Black
                if ($btnClock.BackColor -ne $script:_clockDefaultBackColor) {
                    $btnClock.BackColor = $script:_clockDefaultBackColor
                }
            }
        }
        catch {
            Log "meetingTimer tick error: $_"
        }
    })
$script:meetingTimer.Start()

# --------- OCR helpers ----------
function Grab-ROI {
    $tl = $script:Cfg.ROI.TL; $br = $script:Cfg.ROI.BR
    if (-not $tl -or -not $br) { return $null }
    $x = [math]::Min($tl.X, $br.X); $y = [math]::Min($tl.Y, $br.Y)
    $w = [math]::Abs($br.X - $tl.X); $h = [math]::Abs($br.Y - $tl.Y)
    if ($w -le 0) { return $null }
    # If TL and BR were set on the same text line, height may be near zero.
    # Auto-expand 30 px above and below so OCR captures enough content.
    if ($h -lt 30) { $y = [math]::Max(0, $y - 30); $h = 60 }
    # Coords were captured as logical pixels (DPI-unaware Cursor::Position).
    # CopyFromScreen runs in the DPI-aware pwsh.exe process and needs physical pixels — scale up.
    $dpi = Get-DpiScaleFactor
    $x = [int]($x * $dpi); $y = [int]($y * $dpi); $w = [int]($w * $dpi); $h = [int]($h * $dpi)
    $rect = New-Object System.Drawing.Rectangle $x, $y, $w, $h
    $bmp = New-Object System.Drawing.Bitmap $rect.Width, $rect.Height
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    try {
        $g.CopyFromScreen($rect.Location, [System.Drawing.Point]::Empty, $rect.Size)
    }
    catch {
        # GDI handle temporarily invalid (e.g. display waking from sleep) — skip this pass
        $g.Dispose(); $bmp.Dispose(); return $null
    }
    $g.Dispose()
    return $bmp
}
function Preprocess-Binary([System.Drawing.Bitmap]$bmp) {
    # Fast grayscale via GDI+ ColorMatrix — no per-pixel PowerShell loop
    $out = New-Object System.Drawing.Bitmap $bmp.Width, $bmp.Height
    $g = [System.Drawing.Graphics]::FromImage($out)
    $cm = New-Object System.Drawing.Imaging.ColorMatrix
    $cm.Matrix00 = 0.299; $cm.Matrix01 = 0.299; $cm.Matrix02 = 0.299
    $cm.Matrix10 = 0.587; $cm.Matrix11 = 0.587; $cm.Matrix12 = 0.587
    $cm.Matrix20 = 0.114; $cm.Matrix21 = 0.114; $cm.Matrix22 = 0.114
    $cm.Matrix33 = 1.0; $cm.Matrix44 = 1.0
    $ia = New-Object System.Drawing.Imaging.ImageAttributes
    $ia.SetColorMatrix($cm)
    $g.DrawImage($bmp,
        (New-Object System.Drawing.Rectangle 0, 0, $bmp.Width, $bmp.Height),
        0, 0, $bmp.Width, $bmp.Height,
        [System.Drawing.GraphicsUnit]::Pixel, $ia)
    $g.Dispose(); $ia.Dispose()
    return $out
}
function OCR-Text([System.Drawing.Bitmap]$bmp) {
    $tpath = $script:Cfg.Tesseract
    if (-not (Test-Path $tpath)) { Log "Tesseract not found: $tpath"; return "" }
    $tmp = [System.IO.Path]::ChangeExtension([System.IO.Path]::GetTempFileName(), '.png')
    try { $bmp.Save($tmp, [System.Drawing.Imaging.ImageFormat]::Png) }catch { Log "Temp save failed: $_"; return "" }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $tpath; $psi.Arguments = '"' + $tmp + '" stdout --oem 1 --psm 6'
    $psi.RedirectStandardOutput = $true; $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $p = New-Object System.Diagnostics.Process; $p.StartInfo = $psi
    try {
        [void]$p.Start()
        # Read stdout async to avoid deadlock, then pump UI messages while waiting
        $stdoutTask = $p.StandardOutput.ReadToEndAsync()
        while (-not $p.WaitForExit(30)) { [System.Windows.Forms.Application]::DoEvents() }
        $txt = $stdoutTask.Result
    }
    finally { try { $p.Dispose() }catch {}; try { Remove-Item $tmp -EA SilentlyContinue }catch {} }
    return ($txt -replace '\s+', ' ').Trim()
}

# --------- Persist + startup (clean) ----------
$script:form.Add_FormClosing({
        param($src, $e)
    
        # Check if OBS is still running and show reminder (anchored near main form, TopMost so it won't hide behind Zoom)
        try {
            if ($script:ObsConnected) {
                $dlg = New-Object System.Windows.Forms.Form
                $dlg.Text = "OBS Still Running"
                $dlg.Size = New-Object System.Drawing.Size(340, 160)
                $dlg.FormBorderStyle = 'FixedDialog'
                $dlg.MaximizeBox = $false
                $dlg.MinimizeBox = $false
                $dlg.TopMost = $true
                $dlg.StartPosition = 'Manual'
                $dlg.BackColor = [System.Drawing.Color]::FromArgb(40, 40, 40)
                $dlg.ForeColor = [System.Drawing.Color]::White
                # Position just below the main form (or fallback to top-left of form)
                try {
                    $fx = $script:form.Location.X
                    $fy = $script:form.Location.Y + $script:form.Height + 5
                    $dlg.Location = New-Object System.Drawing.Point($fx, $fy)
                }
                catch {
                    $dlg.Location = New-Object System.Drawing.Point(100, 100)
                }
                $lbl = New-Object System.Windows.Forms.Label
                $lbl.Text = "Please Remember to Close OBS and Virtual Cam!"
                $lbl.AutoSize = $false
                $lbl.Size = New-Object System.Drawing.Size(310, 40)
                $lbl.Location = New-Object System.Drawing.Point(12, 10)
                $lbl.TextAlign = 'MiddleCenter'
                $lbl.ForeColor = [System.Drawing.Color]::Yellow
                $lbl.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
                $dlg.Controls.Add($lbl)
                $btnOk = New-Object System.Windows.Forms.Button
                $btnOk.Text = "OK"
                $btnOk.Size = New-Object System.Drawing.Size(80, 28)
                $btnOk.Location = New-Object System.Drawing.Point(125, 80)
                $btnOk.DialogResult = [System.Windows.Forms.DialogResult]::OK
                $btnOk.FlatStyle = 'Flat'
                $btnOk.BackColor = [System.Drawing.Color]::FromArgb(70, 70, 70)
                $btnOk.ForeColor = [System.Drawing.Color]::White
                $dlg.Controls.Add($btnOk)
                $dlg.AcceptButton = $btnOk
                $dlg.ShowDialog() | Out-Null
                $dlg.Dispose()
            }
        }
        catch {}
    
        # Stop Auto Toggle if active
        try {
            if ($script:AutoToggleActive) {
                Log "Stopping Auto Toggle before closing..."
                $script:AutoToggleActive = $false
                $script:btnAutoToggle.BackColor = [System.Drawing.Color]::LightGray
                $script:btnAutoToggle.Text = "Auto Toggle: OFF"
            }
        }
        catch {}
        
        # Clean up V-Cam status window
        try {
            if ($script:btnVCamStatus -and -not $script:btnVCamStatus.IsDisposed) {
                $script:btnVCamStatus.Dispose()
                $script:btnVCamStatus = $null
            }
        }
        catch {}

        # Stop ALL timers to prevent runspace errors during shutdown
        try {
            $timersToStop = @(
                'DuckingTimer', 'ZoomRaiseTimer', 'XrMeterTimer', 'xrTimer', 'MusicTimer', 'MusicFadeTimer', 
                'CutFlashTimer', 'AudioMonitorTimer', 'obsTimer', 'obsAutoTimer', 
                'obsPingTimer', 'obsBtnPulseTimer', 'XrKeepaliveTimer', 'meetingTimer', 'VCamFlashTimer',
                'meetingTickTimer', 'ZoomStatusTimer', '_jwlOcrTimer'
            )
            
            foreach ($timerName in $timersToStop) {
                $timer = Get-Variable -Name $timerName -Scope Script -ErrorAction SilentlyContinue
                if ($timer -and $timer.Value) {
                    try {
                        $timer.Value.Stop()
                        $timer.Value.Dispose()
                        Set-Variable -Name $timerName -Value $null -Scope Script
                    }
                    catch {}
                }
            }
        }
        catch {}
    
        # Disconnect from OBS
        try {
            if ($script:ObsConnected) {
                Log "Disconnecting OBS before closing..."
                Close-Obs
            }
        }
        catch {}
    
        try {
            # persist window position
            $script:Cfg.WindowX = [int]$script:form.Left
            $script:Cfg.WindowY = [int]$script:form.Top
            Save-Settings | Out-Null
        }
        catch {}

        # Stop XR12 meter receiver
        try {
            XR-StopMeterReceiver
        }
        catch {}

        # Close mixer panel on exit
        try { $script:_appExiting = $true; Hide-MixerPanel } catch {}
    })

$script:form.Add_Shown({
        try { Place-Gear } catch {}
        try {
            if ($script:Cfg.Update.Enabled -and $script:Cfg.Update.CheckOnStartup) {
                Set-UpdateStatusLabel 'Update: checking...' ([System.Drawing.Color]::LightGray) $false
                $script:_updateCheckTimer = New-Object System.Windows.Forms.Timer
                $script:_updateCheckTimer.Interval = 3500
                $script:_updateCheckTimer.Add_Tick({
                        try {
                            $script:_updateCheckTimer.Stop()
                            $script:_updateCheckTimer.Dispose()
                            $script:_updateCheckTimer = $null
                        }
                        catch {}
                        try { Check-ForAppUpdate -Startup } catch {}
                    })
                $script:_updateCheckTimer.Start()
            }
            else {
                Set-UpdateStatusLabel 'Update: disabled' ([System.Drawing.Color]::Gray) $false
            }
        }
        catch {}

        # Apply theme once at startup
        try { Apply-Theme-FromCfg } catch {}

        # XR status timer: create once, then start
        try {
            if (-not $script:xrTimer) {
                $script:xrTimer = New-Object System.Windows.Forms.Timer
                $script:xrTimer.Interval = 1500
                $script:xrTimer.Add_Tick({ 
                        if ($script:ShuttingDown) { return }
                        try { XR-UpdateStatus } catch {} 
                    })
            }
            XR-UpdateStatus
            $script:xrTimer.Start()
        }
        catch {}

        # Background music: optional auto-start (guarded by Meeting Mode)
        try {
            if ($script:Cfg.Music.AutoStart -and $script:Cfg.Music.Folder) {
                if (-not (Is-MeetingGuardActive)) {
                    $script:Music.Folder = $script:Cfg.Music.Folder
                    
                    # Only load folder if playlist doesn't exist or is empty
                    try {
                        $needsLoad = (-not $script:Music.Playlist) -or ($script:Music.Playlist.count -eq 0)
                        if ($needsLoad) {
                            Music-LoadFolder $script:Music.Folder
                        }
                    }
                    catch {
                        Music-LoadFolder $script:Music.Folder
                    }
                    
                    Music-Start
                    Log "Background music: auto-started."
                }
                else {
                    Log "Auto-start skipped due to Meeting Mode."
                }
            }
        }
        catch {
            Log "Music auto-start failed: $_"
        }


        # Start the lightweight UI updater for the music toggle
        try { $script:MusicTimer.Start() } catch {}
        
        # Start OBS audio monitoring timer (passive OBS event listener - always needed when OBS is connected)
        try {
            if ($script:AudioMonitorTimer -and $script:Cfg.Audio.MonitoringEnabled) {
                $script:AudioMonitorTimer.Start()
                Log "OBS audio monitoring started (via WebSocket InputVolumeMeters events)."
            }
        }
        catch {
            Log "OBS audio monitoring start failed: $_"
        }
        
        # XR12 meter receiver - DISABLED (using OBS audio monitoring instead)
        # Uncomment below if you need XR12 meters for other features
        # try {
        #     if (XR-StartMeterReceiver) {
        #         if ($script:XrMeterTimer) {
        #             $script:XrMeterTimer.Start()
        #             Log "XR12 meter polling started."
        #         }
        #     }
        # }
        # catch {
        #     Log "XR12 meter receiver start failed: $_"
        # }
        
        # Start audio ducking timer (OBS audio-based, only when XR Mixer is enabled)
        try {
            if ($script:DuckingTimer -and [bool]$script:Cfg.XR.XRMixerEnabled) {
                $script:DuckingTimer.Start()
                Log "Audio ducking timer started (OBS audio monitoring)."
            }
        }
        catch {
            Log "Timer start failed: $_"
        }
        
        # Start Zoom audio raise timer (only when XR Mixer is enabled - adjusts XR fader for Zoom line)
        try {
            if ($script:ZoomRaiseTimer -and [bool]$script:Cfg.XR.XRMixerEnabled) {
                $script:ZoomRaiseTimer.Start()
                Log "Zoom audio raise timer started."
            }
        }
        catch {
            Log "Zoom raise timer start failed: $_"
        }

        # Auto-open Mixer Panel if it was open last session
        try {
            if ($script:Cfg.XR.XRMixerEnabled -and $script:Cfg.XR.MixerPanelEnabled -and -not [string]::IsNullOrWhiteSpace([string]$script:Cfg.XR.MixerIP)) {
                Show-MixerPanel
            }
        }
        catch { Log "Mixer Panel auto-open failed: $_" }

        # JWL second display state — continuous OCR polling (every 3 s).
        # When Auto Toggle is running: reuses scanTimer's _lastHit (no double Tesseract call).
        # When Auto Toggle is OFF: runs its own OCR so the button stays accurate independently.
        try {
            $script:_jwlOcrTimer = New-Object System.Windows.Forms.Timer
            $script:_jwlOcrTimer.Interval = 3000
            $script:_jwlOcrTimer.Add_Tick({
                    # Keep Media Fix detection fresh so status checks stay explicit in fix mode.
                    try { Test-JwlMediaFix | Out-Null } catch {}

                    # Structural health check — runs every 3s regardless of Auto Toggle state
                    try {
                        if (-not $script:Cfg.ROI.TL -or -not $script:Cfg.ROI.BR) {
                            Set-OcrHealth $false
                        }
                        elseif (-not (Test-Path $script:Cfg.Tesseract)) {
                            Set-OcrHealth $false
                        }
                        else {
                            if ($script:_ocrBroken -eq $true) { Set-OcrHealth $true }
                        }
                    }
                    catch {}

                    if ($script:running) {
                        # Auto Toggle is active — reuse scanTimer's result (no double OCR)
                        try {
                            if ($null -ne $script:_lastHit) {
                                $newState = [bool]$script:_lastHit
                                if ($script:jwlOutOn -ne $newState) {
                                    $script:jwlOutOn = $newState
                                    Update-JwlMonitorButton
                                    Log "[JWL] OCR state (from scanTimer): $(if ($newState) {'ON'} else {'OFF'})"
                                }
                                if ($script:JwlMediaFixActive) {
                                    $kwFix = [string]$script:Cfg.Keyword
                                    $txtFix = [string]$script:_lastOcrText
                                    $stateFix = if ($newState) { 'keyword FOUND' } else { 'keyword NOT found' }
                                    $txtPreviewFix = if ($txtFix) { $txtFix.Substring(0, [math]::Min(80, $txtFix.Length)) } else { '(empty)' }
                                    Log-Throttled 'jwl-fix-auto' "[JWL] Fix-mode Auto Check: $stateFix | keyword='$kwFix' | OCR='$txtPreviewFix'" 20
                                }
                            }
                        }
                        catch { Log "[JWL] OCR state check error: $_" }
                    }
                    else {
                        # Auto Toggle is OFF — run OCR independently to keep button accurate
                        try {
                            $bmp = Grab-ROI
                            if ($bmp) {
                                try {
                                    $processed = Preprocess-Binary $bmp
                                    $txt = OCR-Text $processed
                                    $processed.Dispose()
                                }
                                catch { $txt = OCR-Text $bmp }
                                finally { $bmp.Dispose() }
                                $kw = [string]$script:Cfg.Keyword
                                $hit = ($txt -and -not [string]::IsNullOrWhiteSpace($kw) -and $txt.ToLower().Contains($kw.ToLower()))
                                $script:_lastOcrText = $txt
                                $script:_lastHit = $hit
                                Set-OcrHealth $true
                                Update-JwlOcrTooltip
                                $newState = [bool]$hit
                                if ($script:jwlOutOn -ne $newState) {
                                    $script:jwlOutOn = $newState
                                    Update-JwlMonitorButton
                                    Log "[JWL] OCR state (own scan): $(if ($newState) {'ON'} else {'OFF'})"
                                }
                                if ($script:JwlMediaFixActive) {
                                    $stateFix = if ($hit) { 'keyword FOUND' } else { 'keyword NOT found' }
                                    $txtPreviewFix = if ($txt) { $txt.Substring(0, [math]::Min(80, $txt.Length)) } else { '(empty)' }
                                    Log-Throttled 'jwl-fix-auto' "[JWL] Fix-mode Auto Check: $stateFix | keyword='$kw' | OCR='$txtPreviewFix'" 20
                                }
                            }
                        }
                        catch { Log "[JWL] Independent OCR error: $_" }
                    }
                })
            $script:_jwlOcrTimer.Start()
        }
        catch {}

        # One-shot startup probe: determine JWL display state via OCR after 2s
        try {
            $script:_jwlStartupProbe = New-Object System.Windows.Forms.Timer
            $script:_jwlStartupProbe.Interval = 2000
            $script:_jwlStartupProbe.Add_Tick({
                    $script:_jwlStartupProbe.Stop()
                    try {
                        $bmp = Grab-ROI
                        if ($bmp) {
                            try {
                                $processed = Preprocess-Binary $bmp
                                $txt = OCR-Text $processed
                                $processed.Dispose()
                            }
                            catch { $txt = OCR-Text $bmp }
                            finally { $bmp.Dispose() }
                            $kw = [string]$script:Cfg.Keyword
                            $hit = ($txt -and -not [string]::IsNullOrWhiteSpace($kw) -and $txt.ToLower().Contains($kw.ToLower()))
                            $script:jwlOutOn = [bool]$hit
                            if ($null -eq $script:_lastHit) { $script:_lastHit = $hit }
                            $script:_lastOcrText = $txt
                            Set-OcrHealth $true
                            Update-JwlOcrTooltip
                            Update-JwlMonitorButton
                            $probeState = if ($hit) { "ON" } else { "OFF" }
                            Log "[JWL] Startup OCR probe: display is $probeState (keyword=$(if($hit){'found'}else{'not found'}))"
                        }
                        else { Set-OcrHealth $false; Log "[JWL] Startup OCR probe: ROI not set, skipping" }
                    }
                    catch { Log "[JWL] Startup probe error: $_" }
                })
            $script:_jwlStartupProbe.Start()
        }
        catch {}
    })

# --------- Init + run ----------
Update-MusicToggleButton
Update-ObsButton $false
# Ensure startup visuals comply with new rules
$script:SelectedScene = $DEFAULT_SPEAKER
try { $btnCam.Text = $DEFAULT_SPEAKER; $btnBlank.Text = $DEFAULT_SPEAKER } catch {}
# Start auto-reconnect timer
try { Ensure-AutoTimer } catch { Log "Auto-timer init failed: $_" }

# Set all tooltips (after all buttons are created)
try { Set-AllTooltips } catch { Log "Tooltip init failed:" }

Log "Ready (v6.1.8e). Auto-reconnect enabled."

# Auto-scan runs automatically whenever XR Mixer is enabled
try { 
    if ($script:Cfg.XR.XRMixerEnabled) {
        Start-AutoScanCheck
    }
}
catch { 
    Log "Auto-scan check failed: $_" 
}

# =============================
# === ZOOM AUTOMATION FUNCTIONS ===
# =============================

function Test-ZoomInstalled {
    # Check common Zoom installation paths
    $zoomPaths = @(
        "${env:ProgramFiles}\Zoom\bin\Zoom.exe",
        "${env:ProgramFiles(x86)}\Zoom\bin\Zoom.exe",
        "${env:LOCALAPPDATA}\Zoom\bin\Zoom.exe",
        "${env:APPDATA}\Zoom\bin\Zoom.exe"
    )
    
    foreach ($path in $zoomPaths) {
        if (Test-Path $path) {
            return $path
        }
    }
    
    # Check if zoom is in PATH
    try {
        $zoomInPath = Get-Command "Zoom.exe" -ErrorAction SilentlyContinue
        if ($zoomInPath) {
            return $zoomInPath.Source
        }
    }
    catch {}
    
    return $null
}

function Start-ZoomProcess {
    $zoomPath = Test-ZoomInstalled
    if (-not $zoomPath) {
        [System.Windows.Forms.MessageBox]::Show(
            "Zoom Workplace is not installed or not found in common locations.",
            "Zoom Not Found",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
        return $false
    }
    
    try {
        # Check if Zoom is already running
        $zoomProcess = Get-Process "Zoom" -ErrorAction SilentlyContinue
        if ($zoomProcess) {
            Log "Zoom is already running"
            return $true
        }
        
        Log "Starting Zoom Workplace..."
        Start-Process -FilePath $zoomPath -WindowStyle Normal
        
        # Wait a moment for Zoom to start
        $timeout = 10 # seconds
        $elapsed = 0
        while ($elapsed -lt $timeout) {
            Start-Sleep -Seconds 1
            $elapsed++
            $zoomProcess = Get-Process "Zoom" -ErrorAction SilentlyContinue
            if ($zoomProcess) {
                Log "Zoom started successfully"
                Start-Sleep -Seconds 2  # Give it time to fully initialize
                return $true
            }
        }
        
        Log "Zoom failed to start within $timeout seconds"
        return $false
    }
    catch {
        Log "Failed to start Zoom: $_"
        [System.Windows.Forms.MessageBox]::Show(
            "Failed to start Zoom Workplace: $_",
            "Error",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
        return $false
    }
}

# ========== ZOOM UI AUTOMATION FOR STATUS MONITORING ==========

function Get-ZoomUIAutomationRoot {
    # Check if UI Automation assemblies are available
    if (-not $script:UIAutomationAvailable) {
        return $null
    }

    # Use cached result if we've already tested and know it's not working
    if ($script:UIAutomationTested -and -not $script:UIAutomationWorking) {
        return $null
    }

    try {
        if (-not $script:UIAutomationTested) {
            $script:UIAutomationTested = $true
            Log "Testing .NET UI Automation root element access..."
        }

        # Use managed UIAutomation: System.Windows.Automation
        $root = [System.Windows.Automation.AutomationElement]::RootElement

        if (-not $script:UIAutomationWorking) {
            $script:UIAutomationWorking = $true
            Log "UI Automation (.NET) is working - Zoom status monitoring enabled"
            try { Update-ZoomStatusTooltips } catch {}
        }

        return $root
    }
    catch {
        if (-not $script:UIAutomationTested) {
            Log "UI Automation (.NET) not available: $_ - Zoom status monitoring disabled"
            $script:UIAutomationWorking = $false
            $script:UIAutomationTested = $true
        }
        return $null
    }
}

# Runs the Zoom participant status read in an STA background runspace so the UI thread never freezes.
# Reuses the persistent $script:_zoomStatusRS runspace (created in Start-ZoomStatusMonitoring) so
# UIAutomation assemblies are loaded only once — eliminating per-call startup overhead.
# On completion the 200ms polling timer calls Update-ZoomStatusIcons on the UI thread.
function Start-ZoomStatusRunspace {
    # Guard: skip if a read is already in flight
    if ($script:_statusAsyncResult -and -not $script:_statusAsyncResult.IsCompleted) { return }

    if (-not $script:UIAutomationAvailable) { return }
    $dn = $script:Cfg.Zoom.JoinDisplayName
    if ([string]::IsNullOrWhiteSpace($dn)) { return }

    # Quick pre-check: if Zoom isn't running at all, handle immediately on UI thread (no heavy work)
    $zp = Get-Process 'Zoom' -ErrorAction SilentlyContinue
    if (-not $zp) {
        if ($script:ZoomParticipantFound) {
            Log 'Refresh-ZoomStatus: Zoom is not running (clearing status)'
            Update-ZoomStatusIcons @{ Found = $false }
        }
        return
    }

    $statusScript = {
        param([string]$DisplayName)
        try {
            Add-Type -AssemblyName UIAutomationClient -ErrorAction SilentlyContinue
            Add-Type -AssemblyName UIAutomationTypes  -ErrorAction SilentlyContinue

            $root = [System.Windows.Automation.AutomationElement]::RootElement
            $treeScopeSubtree = [System.Windows.Automation.TreeScope]::Subtree
            $typeProp = [System.Windows.Automation.AutomationElement]::ControlTypeProperty
            $nameProp = [System.Windows.Automation.AutomationElement]::NameProperty
            $windowType = [System.Windows.Automation.ControlType]::Window
            $paneType = [System.Windows.Automation.ControlType]::Pane

            $nCond = New-Object System.Windows.Automation.PropertyCondition($nameProp, 'Zoom Meeting')
            $tCond = New-Object System.Windows.Automation.PropertyCondition($typeProp, $windowType)
            $zCond = New-Object System.Windows.Automation.AndCondition($nCond, $tCond)
            $zoomWin = $root.FindFirst($treeScopeSubtree, $zCond)
            if (-not $zoomWin) { return @{ Found = $false; Reason = 'no_window' } }

            $paneCond = New-Object System.Windows.Automation.PropertyCondition($typeProp, $paneType)
            $candidates = $zoomWin.FindAll($treeScopeSubtree, $paneCond)
            if (-not $candidates -or $candidates.Count -eq 0) {
                return @{ Found = $false; Reason = 'no_panes' }
            }

            $participantPane = $null
            for ($i = 0; $i -lt $candidates.Count; $i++) {
                $el = $candidates.Item($i)
                $name = ''
                try { $name = $el.Current.Name } catch {}
                if (-not [string]::IsNullOrWhiteSpace($name) -and $name -like "*$DisplayName*") {
                    $participantPane = $el; break
                }
            }
            if (-not $participantPane) { return @{ Found = $false; Reason = 'no_participant' } }

            $nameProp2 = ''
            try { $nameProp2 = $participantPane.Current.Name } catch {}
            if ([string]::IsNullOrWhiteSpace($nameProp2)) { return @{ Found = $false; Reason = 'empty_name' } }

            $micOn = $null
            if ($nameProp2 -like '*unmuted*') { $micOn = $true }
            elseif ($nameProp2 -like '*muted*') { $micOn = $false }
            $cameraOn = -not ($nameProp2 -like '*Video off*')

            return @{
                Found      = $true
                MicOn      = $micOn
                CameraOn   = $cameraOn
                StatusText = $nameProp2
            }
        }
        catch { return @{ Found = $false; Reason = "error:$_" } }
    }

    # Reuse the persistent runspace — no CreateRunspace/Open/assembly-load overhead per call
    $rs = $script:_zoomStatusRS
    if (-not $rs -or $rs.RunspaceStateInfo.State -ne 'Opened') {
        # Fallback: create a one-shot runspace if persistent one isn't ready yet
        $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
        $rs.ApartmentState = 'STA'
        $rs.ThreadOptions = 'ReuseThread'
        $rs.Open()
        $script:_statusRunspace = $rs  # mark as disposable
    }
    else {
        $script:_statusRunspace = $null  # persistent — don't dispose after scan
    }

    $ps = [System.Management.Automation.PowerShell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($statusScript).AddArgument($dn)
    $script:_statusPS = $ps
    $script:_statusAsyncResult = $ps.BeginInvoke()

    # 200ms completion-check timer — fires on UI thread, never blocks it
    if ($script:_statusPollTimer -and -not $script:_statusPollTimer.IsDisposed) {
        $script:_statusPollTimer.Stop(); $script:_statusPollTimer.Dispose()
    }
    $pollTimer = New-Object System.Windows.Forms.Timer
    $script:_statusPollTimer = $pollTimer
    $pollTimer.Interval = 200
    $pollTimer.Add_Tick({
            try {
                if (-not $script:_statusAsyncResult -or -not $script:_statusAsyncResult.IsCompleted) { return }
                try { $pollTimer.Stop() } catch {}
                try { $pollTimer.Dispose() } catch {}
                if ([object]::ReferenceEquals($script:_statusPollTimer, $pollTimer)) { $script:_statusPollTimer = $null }

                $status = $null
                try {
                    $out = $script:_statusPS.EndInvoke($script:_statusAsyncResult)
                    if ($out -and $out.Count -gt 0) { $status = $out[0] }
                }
                catch {}
                $script:_statusAsyncResult = $null
                try { $script:_statusPS.Dispose() } catch {}
                # Only dispose the runspace if it was a one-shot fallback (not the persistent one)
                if ($script:_statusRunspace) {
                    try { $script:_statusRunspace.Close(); $script:_statusRunspace.Dispose() } catch {}
                    $script:_statusRunspace = $null
                }
                $script:_statusPS = $null

                if ($status -and $status['Found']) {
                    $st = $status['StatusText']
                    Log "Found Zoom participant: $($script:Cfg.Zoom.JoinDisplayName)"
                    Log "Participant status: $st"

                    # Skip mic/cam colour overwrite if user manually clicked within the last 3 seconds
                    $skipColorUpdate = $script:_lastManualToggleTime -and
                    ((Get-Date) - $script:_lastManualToggleTime).TotalSeconds -lt 3

                    # While Auto Toggle is active, protect mic/camera from being forced OFF by a
                    # stale UIA poll result (Zoom may not have processed Alt+A/Alt+V yet).
                    # If the poll says mic/cam is off but our local state says on, re-correct silently.
                    if ($script:running -and -not $skipColorUpdate) {
                        $pollMicOn = $status['MicOn']
                        $pollCamOn = $status['CameraOn']
                        if ($pollMicOn -eq $false -and $script:ZoomMicStatus -eq $true) {
                            Log 'Auto Toggle active: UIA poll says mic=off but local=on — re-correcting silently'
                            try { Zoom-UnmuteIfMuted } catch {}
                            $skipColorUpdate = $true
                        }
                        if ($pollCamOn -eq $false -and $script:ZoomCameraStatus -eq $true) {
                            Log 'Auto Toggle active: UIA poll says camera=off but local=on — re-correcting silently'
                            try { Zoom-CameraOn } catch {}
                            $skipColorUpdate = $true
                        }
                    }

                    if ($skipColorUpdate) {
                        # Still update ZoomParticipantFound / enable buttons, but preserve the user's chosen colour
                        $script:ZoomParticipantFound = $true
                        $script:ZoomInMeeting = $true
                        Log 'Refresh-ZoomStatus: skipping colour overwrite (recent toggle or Auto Toggle active)'
                        try { Update-ZoomJoinButtonVisual } catch {}
                    }
                    else {
                        Update-ZoomStatusIcons $status
                        Log 'Refresh-ZoomStatus: Zoom status refreshed (participant detected)'
                    }
                }
                else {
                    if ($script:ZoomParticipantFound) {
                        Update-ZoomStatusIcons @{ Found = $false }
                        Log 'Refresh-ZoomStatus: Zoom participant no longer detected'
                    }
                    else {
                        $reason = if ($status -and $status['Reason']) { $status['Reason'] } else { 'null' }
                        Log-Throttled 'ZoomParticipant' "Zoom participant not found ($reason)" 5
                    }
                }
            }
            catch { Log "Zoom status poll-check error: $_" }
        })
    $pollTimer.Start()
}

function Update-ZoomStatusIcons {
    param($status)
    
    try {
        # Support both hashtable and object-style status input
        $found = $null
        $micOn = $null
        $camOn = $null

        if ($status -is [hashtable]) {
            if ($status.Contains('Found')) { $found = [bool]$status['Found'] }
            if ($status.Contains('MicOn')) { $micOn = [bool]$status['MicOn'] }
            if ($status.Contains('CameraOn')) { $camOn = [bool]$status['CameraOn'] }
        }
        else {
            $found = [bool]$status.Found
            $micOn = [bool]$status.MicOn
            $camOn = [bool]$status.CameraOn
        }

        if (-not $found) {
            # Zoom participant not found - show neutral grey and disable
            # Zoom-specific controls until a meeting is active.
            $script:ZoomParticipantFound = $false
            $script:ZoomInMeeting = $false
            $script:_zoomNotFoundStreak++

            if ($btnZoomMuteAll) {
                $btnZoomMuteAll.Enabled = $false
                $btnZoomMuteAll.BackColor = [Drawing.Color]::FromArgb(128, 128, 128)
            }
            if ($btnZoomMic) {
                $btnZoomMic.Enabled = $false
                $btnZoomMic.BackColor = [Drawing.Color]::FromArgb(128, 128, 128)
            }
            if ($btnZoomCamera) {
                $btnZoomCamera.Enabled = $false
                $btnZoomCamera.BackColor = [Drawing.Color]::FromArgb(128, 128, 128)
            }
            # Only reset polls state after 2+ consecutive misses (~10s) to survive brief detection blips
            if ($script:_zoomNotFoundStreak -ge 2) {
                $script:_pollsActivated = $false
                if ($btnZoomPolls) {
                    $btnZoomPolls.Enabled = $false
                    $btnZoomPolls.BackColor = [Drawing.Color]::FromArgb(128, 128, 128)
                }
                Stop-AttendanceRefreshTimer
                if ($script:lblAttendance) { $script:lblAttendance.Text = "Polls: --" }
                $script:_participantsAutoOpened = $false  # Reset so it opens again next meeting (only on confirmed end, not brief blip)
            }
            else {
                # Brief blip: keep polls button state, just disable it temporarily
                if ($btnZoomPolls) { $btnZoomPolls.Enabled = $false }
            }

            if ($btnZoomFocus) {
                $btnZoomFocus.Enabled = $false
                Update-ZoomFocusButtonVisual $false
            }
            $btnZoomMic.Text = [char]0xE720   # mic icon
            $btnZoomCamera.Text = [char]0xE714   # camera icon
            try { Update-ZoomJoinButtonVisual } catch {}
            return
        }

        $script:ZoomParticipantFound = $true
        $script:ZoomInMeeting = $true
        $script:_zoomNotFoundStreak = 0  # Reset miss counter when participant is found

        # Background runspace already proved UIAutomation works — mark it so UI-thread calls skip the 11s test
        if (-not $script:UIAutomationTested) {
            $script:UIAutomationTested = $true
            $script:UIAutomationWorking = $true
        }

        # Auto-open the Participants panel once per meeting (fires on first detection)
        # Runs in a background STA runspace so the UI thread (and OBS capture) never freezes
        if (-not $script:_participantsAutoOpened) {
            $script:_participantsAutoOpened = $true
            Log 'Auto-opening Participants panel in background (2s delay)...'
            Start-ParticipantsPanelRunspace -DelayMs 2000
        }

        # Auto-start Polls if the join-timer missed it (meeting loaded too slowly)
        if ($script:Cfg.Zoom.AutoPollsAfterJoin -and -not $script:_pollsActivated) {
            Log 'Auto Polls: triggering from first participant detection (join-timer missed)...'
            $script:_pollsActivated = $true
            if ($btnZoomPolls) { $btnZoomPolls.BackColor = [Drawing.Color]::FromArgb(120, 60, 180) }
            try { [void](Focus-ZoomWindow) } catch {}
            Start-PollsRunspace -DelayMs 500
        }

        if ($btnZoomMuteAll) {
            $btnZoomMuteAll.Enabled = $true
            $btnZoomMuteAll.BackColor = [Drawing.Color]::FromArgb(200, 80, 80)
        }
        # Only re-enable mic/cam if Auto Toggle is NOT locking them
        if ($btnZoomMic) { $btnZoomMic.Enabled = (-not $script:running) }
        if ($btnZoomCamera) { $btnZoomCamera.Enabled = (-not $script:running) }
        if ($btnZoomPolls) {
            $btnZoomPolls.Enabled = $true
            # Stay gray until polls are manually clicked or auto-started
            if ($script:_pollsActivated) {
                $btnZoomPolls.BackColor = [Drawing.Color]::FromArgb(120, 60, 180)
            }
            else {
                $btnZoomPolls.BackColor = [Drawing.Color]::FromArgb(128, 128, 128)
            }
        }

        if ($btnZoomFocus) {
            $btnZoomFocus.Enabled = $true
        }
        
        # Update microphone status
        if ($micOn) {
            $btnZoomMic.BackColor = [Drawing.Color]::FromArgb(0, 180, 0)  # Green for ON
            $btnZoomMic.FlatAppearance.MouseOverBackColor = [Drawing.Color]::FromArgb(0, 210, 0)
            $btnZoomMic.FlatAppearance.MouseDownBackColor = [Drawing.Color]::FromArgb(0, 140, 0)
            $script:ZoomMicStatus = $true
        }
        else {
            $btnZoomMic.BackColor = [Drawing.Color]::FromArgb(200, 50, 50)  # Red for OFF/MUTED
            $btnZoomMic.FlatAppearance.MouseOverBackColor = [Drawing.Color]::FromArgb(230, 80, 80)
            $btnZoomMic.FlatAppearance.MouseDownBackColor = [Drawing.Color]::FromArgb(160, 30, 30)
            $script:ZoomMicStatus = $false
        }
        try { $btnZoomMic.Refresh() } catch {}
        
        # Update camera status  
        if ($camOn) {
            $btnZoomCamera.BackColor = [Drawing.Color]::FromArgb(0, 180, 0)  # Green for ON
            $btnZoomCamera.FlatAppearance.MouseOverBackColor = [Drawing.Color]::FromArgb(0, 210, 0)
            $btnZoomCamera.FlatAppearance.MouseDownBackColor = [Drawing.Color]::FromArgb(0, 140, 0)
            $script:ZoomCameraStatus = $true
        }
        else {
            $btnZoomCamera.BackColor = [Drawing.Color]::FromArgb(200, 50, 50)  # Red for OFF
            $btnZoomCamera.FlatAppearance.MouseOverBackColor = [Drawing.Color]::FromArgb(230, 80, 80)
            $btnZoomCamera.FlatAppearance.MouseDownBackColor = [Drawing.Color]::FromArgb(160, 30, 30)
            $script:ZoomCameraStatus = $false
        }
        try { $btnZoomCamera.Refresh() } catch {}

        try { Update-ZoomJoinButtonVisual } catch {}
    }
    catch {
        Log "Error updating Zoom status icons: $_"
    }
}

function Update-ZoomStatusTooltips {
    try {
        if ($script:UIAutomationAvailable -and $script:UIAutomationWorking) {
            $script:tooltip.SetToolTip($btnZoomMic, "Microphone status and toggle (Alt+A). Green MIC=ON, Red MUTE=Muted")
            $script:tooltip.SetToolTip($btnZoomCamera, "Camera status and toggle (Alt+V). Green CAM=ON, Red OFF=Camera off")
        }
        else {
            $script:tooltip.SetToolTip($btnZoomMic, "Zoom microphone control (Alt+A) - Text shows MIC or MUTE status")
            $script:tooltip.SetToolTip($btnZoomCamera, "Zoom camera control (Alt+V) - Text shows CAM or OFF status")
        }
    }
    catch {
        Log "Error updating Zoom status tooltips: $_"
    }
}

function Update-ZoomJoinButtonVisual {
    try {
        if (-not $btnZoomJoin) { return }

        # Stop any running checking animation
        if ($script:_joinAnimTimer -and -not $script:_joinAnimTimer.IsDisposed) {
            $script:_joinAnimTimer.Stop(); $script:_joinAnimTimer.Dispose()
            $script:_joinAnimTimer = $null
        }

        if ($script:ZoomInMeeting) {
            # Meeting active: orange button, updated text and tooltip
            $btnZoomJoin.Text = "In Meeting"
            $btnZoomJoin.BackColor = [System.Drawing.Color]::FromArgb(255, 165, 0)
            if ($script:tooltip) {
                $script:tooltip.SetToolTip($btnZoomJoin, "Zoom meeting is active — click to focus the Zoom window")
            }
        }
        else {
            # No meeting: blue button, plain join text
            $btnZoomJoin.Text = "Join Zoom"
            $btnZoomJoin.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 215)
            if ($script:tooltip) {
                $script:tooltip.SetToolTip($btnZoomJoin, "Join Zoom meeting using the configured Meeting ID")
            }
        }
    }
    catch {
        Log "Error updating Join Zoom button visual: $_"
    }
}

function Start-ZoomStatusMonitoring {
    # Initialize MIC/CAM visuals to neutral grey until a meeting is detected
    if ($btnZoomMic) {
        $btnZoomMic.BackColor = [Drawing.Color]::FromArgb(128, 128, 128)
        $btnZoomMic.Text = [char]0xE720
        $btnZoomMic.Enabled = $false
    }
    if ($btnZoomCamera) {
        $btnZoomCamera.BackColor = [Drawing.Color]::FromArgb(128, 128, 128)
        $btnZoomCamera.Text = [char]0xE714
        $btnZoomCamera.Enabled = $false
    }

    try { Update-ZoomStatusTooltips } catch {}

    # Stop any existing timer before (re)starting
    if ($script:ZoomStatusTimer) {
        try { $script:ZoomStatusTimer.Stop(); $script:ZoomStatusTimer.Dispose() } catch {}
        $script:ZoomStatusTimer = $null
    }

    if (-not $script:UIAutomationAvailable) {
        Log "Zoom status monitoring: UI Automation not available — polling disabled"
        return
    }

    # Create a persistent STA runspace once — reused for every scan so UIAutomation
    # assemblies are only loaded a single time, eliminating per-call startup overhead.
    if (-not $script:_zoomStatusRS -or $script:_zoomStatusRS.RunspaceStateInfo.State -ne 'Opened') {
        try {
            $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
            $rs.ApartmentState = 'STA'
            $rs.ThreadOptions = 'ReuseThread'
            $rs.Open()
            # Pre-load UIAutomation assemblies so every subsequent scan is near-instant
            $init = [System.Management.Automation.PowerShell]::Create()
            $init.Runspace = $rs
            [void]$init.AddScript('Add-Type -AssemblyName UIAutomationClient -ErrorAction SilentlyContinue; Add-Type -AssemblyName UIAutomationTypes -ErrorAction SilentlyContinue')
            [void]$init.Invoke()
            $init.Dispose()
            $script:_zoomStatusRS = $rs
            Log 'Zoom status runspace: persistent STA runspace ready'
        }
        catch { Log "Zoom status runspace init error: $_" }
    }

    # Poll every 5 seconds; Start-ZoomStatusRunspace has all the guards needed
    $script:ZoomStatusTimer = New-Object System.Windows.Forms.Timer
    $script:ZoomStatusTimer.Interval = 5000
    $script:ZoomStatusTimer.Add_Tick({
            if ($script:ShuttingDown) { $script:ZoomStatusTimer.Stop(); return }
            try { Start-ZoomStatusRunspace } catch {}
        })
    $script:ZoomStatusTimer.Start()
    Log "Zoom status monitoring started (polling every 5 s)"
}

function Stop-ZoomStatusMonitoring {
    if ($script:ZoomStatusTimer) {
        try {
            $script:ZoomStatusTimer.Stop()
            $script:ZoomStatusTimer.Dispose()
        }
        catch {}
        $script:ZoomStatusTimer = $null
        Log "Zoom status monitoring stopped"
    }
    # Close the persistent runspace on shutdown
    if ($script:_zoomStatusRS) {
        try { $script:_zoomStatusRS.Close(); $script:_zoomStatusRS.Dispose() } catch {}
        $script:_zoomStatusRS = $null
    }
}

function Start-ZoomJoinMeeting {
    try {
        # Validate Meeting ID is provided
        if ([string]::IsNullOrWhiteSpace($script:Cfg.Zoom.JoinMeetingID)) {
            Log "Join Meeting: No Meeting ID configured - please configure in Zoom settings"
            [System.Windows.Forms.MessageBox]::Show(
                $script:form,
                "No Meeting ID is configured.`n`nPlease go to Settings and enter your Zoom Meeting ID before joining.",
                "Meeting ID Not Configured",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            ) | Out-Null
            return
        }
        
        Log "Starting Zoom Join Meeting automation..."
        Log "Meeting ID: '$($script:Cfg.Zoom.JoinMeetingID)'"
        Log "Display Name: '$($script:Cfg.Zoom.JoinDisplayName)'"
        
        # Update status if we have a status label
        try { 
            if ($script:sbLeft -and -not $script:sbLeft.IsDisposed) { 
                $script:sbLeft.Text = "Launching Zoom..." 
            } 
        }
        catch {}
        
        # Note: We don't need to manually start Zoom - the URL scheme will handle this
        
        # Update status
        try { 
            if ($script:sbLeft -and -not $script:sbLeft.IsDisposed) { 
                $script:sbLeft.Text = "Joining meeting directly..." 
            } 
        }
        catch {}
        
        # Use Zoom URL scheme for direct meeting join (much more reliable!)
        # Strip spaces from meeting ID — spaces in confno= break the URL on some systems
        $cleanMeetingId = ($script:Cfg.Zoom.JoinMeetingID -replace '\s', '')
        $meetingUrl = "zoommtg://zoom.us/join?confno=$cleanMeetingId"
        
        # Add display name if configured (simple URL encoding)
        if (-not [string]::IsNullOrWhiteSpace($script:Cfg.Zoom.JoinDisplayName)) {
            $encodedName = [System.Uri]::EscapeDataString($script:Cfg.Zoom.JoinDisplayName)
            $meetingUrl += "&uname=$encodedName"
        }
        
        # Add password if configured  
        if (-not [string]::IsNullOrWhiteSpace($script:Cfg.Zoom.JoinMeetingPassword)) {
            $encodedPassword = [System.Uri]::EscapeDataString($script:Cfg.Zoom.JoinMeetingPassword)
            $meetingUrl += "&pwd=$encodedPassword"
        }

        $safeMeetingUrl = $meetingUrl -replace '([?&]pwd=)[^&]*', '$1***'
        Log "Launching Zoom with URL: $safeMeetingUrl"
        
        try {
            # Launch Zoom directly to the meeting
            Start-Process $meetingUrl -ErrorAction Stop

            # Auto-click the Zoom "Join" confirmation popup that appears after URL launch
            if ($script:_autoJoinClickTimer -and -not $script:_autoJoinClickTimer.IsDisposed) {
                $script:_autoJoinClickTimer.Stop(); $script:_autoJoinClickTimer.Dispose()
            }
            $script:_autoJoinClickAttempts = 0
            $script:_autoJoinClickTimer = New-Object System.Windows.Forms.Timer
            $script:_autoJoinClickTimer.Interval = 600
            $script:_autoJoinClickTimer.Add_Tick({
                    try {
                        $script:_autoJoinClickAttempts++
                        if ($script:_autoJoinClickAttempts -gt 20) {
                            $script:_autoJoinClickTimer.Stop(); $script:_autoJoinClickTimer.Dispose()
                            Log "Auto-Join: Join button not found within 12s - giving up"; return
                        }
                        $uiaRoot = [System.Windows.Automation.AutomationElement]::RootElement
                        $scope = [System.Windows.Automation.TreeScope]::Subtree
                        $np = [System.Windows.Automation.AutomationElement]::NameProperty
                        $tp = [System.Windows.Automation.AutomationElement]::ControlTypeProperty
                        $cBtn = New-Object System.Windows.Automation.PropertyCondition($tp, [System.Windows.Automation.ControlType]::Button)
                        $cName = New-Object System.Windows.Automation.PropertyCondition($np, "Join")
                        $cJoin = New-Object System.Windows.Automation.AndCondition($cBtn, $cName)
                        $joinBtn = $null
                        try { $joinBtn = $uiaRoot.FindFirst($scope, $cJoin) } catch {}
                        if ($joinBtn) {
                            $script:_autoJoinClickTimer.Stop(); $script:_autoJoinClickTimer.Dispose()
                            try {
                                $inv = $joinBtn.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
                                if ($inv) { $inv.Invoke(); Log "Auto-Join: clicked Join button via InvokePattern" }
                                else { Log "Auto-Join: InvokePattern not available on Join button" }
                            }
                            catch { Log "Auto-Join: invoke error: $_" }
                        }
                    }
                    catch {
                        Log "Auto-Join timer error: $_"
                        try { $script:_autoJoinClickTimer.Stop(); $script:_autoJoinClickTimer.Dispose() } catch {}
                    }
                })
            $script:_autoJoinClickTimer.Start()

            Log "Zoom meeting join launched - auto-clicking Join confirmation..."
            
            # If audio/video settings are configured, we may need to handle them after join
            if ($script:Cfg.Zoom.JoinDontConnectAudio -or $script:Cfg.Zoom.JoinTurnOffVideo) {
                Log "Note: Audio/video preferences set. You may need to manually adjust them in Zoom."
                # The URL scheme doesn't support audio/video settings, so we inform the user
            }
            
            Log "Zoom Join Meeting automation completed successfully."

            # After join, schedule a short series of status refreshes so the MIC/CAM
            # buttons auto-activate once the Zoom meeting window and participant are ready
            try {
                # Ensure any previous status timer is cleaned up
                if ($script:ZoomStatusTimer) {
                    try {
                        $script:ZoomStatusTimer.Stop()
                        $script:ZoomStatusTimer.Dispose()
                    }
                    catch {}
                    $script:ZoomStatusTimer = $null
                }

                $script:ZoomStatusTimer = New-Object System.Windows.Forms.Timer
                $script:ZoomStatusTimer.Interval = 1000  # Reduced from 2000ms for faster detection

                # Use the Tag property to track how many attempts we've made
                $script:ZoomStatusTimer.Tag = 0

                $script:ZoomStatusTimer.Add_Tick({
                        param($src, $e)
                        try {
                            # Guard against shutdown
                            if ($script:ShuttingDown) {
                                $src.Stop(); $src.Dispose(); return
                            }

                            # Increment attempt counter (stored in Tag)
                            $attempt = 0
                            try { if ($null -ne $src.Tag) { $attempt = [int]$src.Tag } } catch {}
                            $attempt++
                            $src.Tag = $attempt

                            # Refresh Zoom status (reuses persistent runspace — near-instant)
                            try { Start-ZoomStatusRunspace } catch {}

                            # Stop if we already detected a participant or we've tried enough times
                            if ($script:ZoomParticipantFound -or $attempt -ge 10) {
                                # Increased from 8 to 10 attempts for better detection
                                $src.Stop(); $src.Dispose()
                            }
                        }
                        catch {}
                    })

                $script:ZoomStatusTimer.Start()
                Log "Zoom Join: scheduled post-join Zoom status checks (up to ~10 seconds)."  # Updated timing description
            }
            catch {}
            
            # Update status
            try { 
                if ($script:sbLeft -and -not $script:sbLeft.IsDisposed) { 
                    $script:sbLeft.Text = "Joined meeting successfully" 
                } 
            }
            catch {}
        }
        catch {
            Log "Error launching Zoom URL: $_"
            # Removed blocking MessageBox for better performance - info available in logs
        }
    }
    catch {
        Log "Zoom Join Meeting error: $_"
        # Removed blocking MessageBox for better performance
    }
    finally {
        # Reset status
        try { 
            if ($script:sbLeft -and -not $script:sbLeft.IsDisposed) { 
                $script:sbLeft.Text = "Ready" 
            } 
        }
        catch {}
    }
}

function Start-ZoomJoinOrRefresh {
    # Decide based on whether an actual Zoom Meeting window exists, not just the process
    try {
        $zoomProcs = Get-Process "Zoom" -ErrorAction SilentlyContinue
    }
    catch {
        $zoomProcs = $null
    }

    $meetingProc = $null

    if ($zoomProcs) {
        try {
            $meetingProc = $zoomProcs | Where-Object { $_.MainWindowTitle -like "*Zoom Meeting*" } | Select-Object -First 1
        }
        catch {
            $meetingProc = $null
        }
    }

    if ($meetingProc) {
        # Already inside a meeting: refresh status synchronously (fast, like v5.1.1)
        Log "Zoom Join/Refresh: Zoom meeting window detected - refreshing status only"
        # Show a 'syncing' colour on mic/cam buttons so user knows something is happening
        try {
            if ($btnZoomMic -and $script:ZoomParticipantFound) {
                $btnZoomMic.BackColor = [Drawing.Color]::FromArgb(80, 80, 180)   # soft blue = syncing
            }
            if ($btnZoomCamera -and $script:ZoomParticipantFound) {
                $btnZoomCamera.BackColor = [Drawing.Color]::FromArgb(80, 80, 180)
            }
        }
        catch {}
        Start-ZoomStatusRunspace
    }
    else {
        # No active meeting window (Zoom closed or idle): join via URL scheme
        Log "Zoom Join/Refresh: No active Zoom meeting window - joining meeting via URL"
        Start-ZoomJoinMeeting
    }
}

# Start Zoom status monitoring  
Start-ZoomStatusMonitoring

# Startup sync: if Zoom is already in a meeting when the app launches, read real mic/cam state
$script:_startupSyncTimer = New-Object System.Windows.Forms.Timer
$script:_startupSyncTimer.Interval = 2000  # 2s delay so form fully loads first
$script:_startupSyncTimer.Add_Tick({
        $script:_startupSyncTimer.Stop()
        $script:_startupSyncTimer.Dispose()
        $script:_startupSyncTimer = $null
        try {
            $mp = Get-Process 'Zoom' -ErrorAction SilentlyContinue |
            Where-Object { $_.MainWindowTitle -like '*Zoom Meeting*' } |
            Select-Object -First 1
            if ($mp) {
                Log 'Startup sync: Zoom meeting already active - reading mic/camera status'
                # Show pulsing animation on Join button so user sees it is being checked
                if ($btnZoomJoin) {
                    if ($script:_joinAnimTimer -and -not $script:_joinAnimTimer.IsDisposed) {
                        $script:_joinAnimTimer.Stop(); $script:_joinAnimTimer.Dispose()
                    }
                    $script:_joinAnimFrame = 0
                    $script:_joinAnimTimer = New-Object System.Windows.Forms.Timer
                    $script:_joinAnimTimer.Interval = 600
                    $script:_joinAnimTimer.Add_Tick({
                            try {
                                $f = @('Checking.  ', 'Checking.. ', 'Checking...')
                                $btnZoomJoin.Text = $f[$script:_joinAnimFrame % 3]
                                $script:_joinAnimFrame++
                            }
                            catch {}
                        })
                    $btnZoomJoin.Text = 'Checking.  '
                    $btnZoomJoin.BackColor = [System.Drawing.Color]::FromArgb(255, 140, 0)
                    $script:_joinAnimTimer.Start()
                }
                Start-ZoomStatusRunspace

                # Auto-start Polls if enabled (same logic as clicking Join Zoom)
                if ($script:Cfg.Zoom.AutoPollsAfterJoin) {
                    if ($script:_autoJoinPollsTimer -and -not $script:_autoJoinPollsTimer.IsDisposed) {
                        $script:_autoJoinPollsTimer.Stop()
                        $script:_autoJoinPollsTimer.Dispose()
                    }
                    $script:_autoJoinPollsAttempts = 0
                    $script:_autoJoinPollsTimer = New-Object System.Windows.Forms.Timer
                    $script:_autoJoinPollsTimer.Interval = 3500
                    $script:_autoJoinPollsTimer.Add_Tick({
                            try {
                                $script:_autoJoinPollsAttempts++
                                $zoomMeeting = Get-Process 'Zoom' -ErrorAction SilentlyContinue |
                                Where-Object { $_.MainWindowTitle -like '*Zoom Meeting*' } |
                                Select-Object -First 1
                                if ($zoomMeeting -or $script:_autoJoinPollsAttempts -ge 3) {
                                    $script:_autoJoinPollsTimer.Stop()
                                    if ($zoomMeeting) {
                                        Log "Auto Polls: Zoom meeting active after $($script:_autoJoinPollsAttempts * 3.5)s - launching polls"
                                        $script:_pollsActivated = $true
                                        if ($btnZoomPolls) { $btnZoomPolls.BackColor = [Drawing.Color]::FromArgb(120, 60, 180) }
                                        [void](Focus-ZoomWindow)
                                        Start-PollsRunspace -DelayMs 0
                                    }
                                    else {
                                        Log "Auto Polls: Zoom meeting not detected after ~10s - skipping"
                                    }
                                }
                            }
                            catch {
                                Log "Auto Polls startup timer error: $_"
                                try { $script:_autoJoinPollsTimer.Stop() } catch {}
                            }
                        })
                    $script:_autoJoinPollsTimer.Start()
                }
            }
        }
        catch {}
    })
$script:_startupSyncTimer.Start()

# Periodic Zoom status refresh every 30 seconds while a meeting is active.
# This catches state drift (e.g. host muted by Zoom, camera dropped) without heavy polling.
$script:_periodicZoomRefreshTimer = New-Object System.Windows.Forms.Timer
$script:_periodicZoomRefreshTimer.Interval = 30000  # 30 seconds
$script:_periodicZoomRefreshTimer.Add_Tick({
        try {
            if ($script:ZoomInMeeting -and -not $script:running) {
                # Only refresh when in a meeting AND Auto Toggle is NOT active
                # (Auto Toggle already has its own correction logic for the active state)
                Log 'Periodic Zoom refresh: checking mic/camera status'
                Start-ZoomStatusRunspace
            }
        }
        catch {}
    })
$script:_periodicZoomRefreshTimer.Start()

# Add form closing handler to cleanup timers
$script:form.Add_FormClosed({
        try {
            Stop-ZoomStatusMonitoring
        }
        catch {
            Log "Error stopping Zoom monitoring: $_"
        }
    })

# =============================================================
# === XR MIXER PANEL ==========================================
# =============================================================
# Floating live-fader + meter window.
# 9 input channels (Ch 1–9) + 1 master LR channel.
# Meters read from $script:XrMeterLevels (populated by XR12 OSC).
# Faders use XR-WriteFaderPosition / XR-SendOSC.
# =============================================================

function Show-MixerPanel {
    # Bring to front if already open
    if ($script:_mixerPanel -and -not $script:_mixerPanel.IsDisposed) {
        try { $script:_mixerPanel.BringToFront(); $script:_mixerPanel.Activate() } catch {}
        return
    }

    if ([string]::IsNullOrWhiteSpace([string]$script:Cfg.XR.MixerIP)) {
        [System.Windows.Forms.MessageBox]::Show(
            $script:form,
            "Please set the Mixer IP in XR Settings first.",
            "XR Mixer Panel",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
        # Uncheck panel checkbox to avoid misleading state
        try { if ($script:chkMixerPanel) { $script:chkMixerPanel.Checked = $false } } catch {}
        return
    }

    # Start XR meter receiver if not already running
    if (-not $script:XrMeterUdp) {
        try {
            if (XR-StartMeterReceiver) {
                $script:XrMeterTimer.Start()
                Log "Mixer Panel: XR meter receiver started"
            }
        }
        catch { Log "Mixer Panel: Could not start meter receiver: $_" }
    }

    # ---- Layout constants (scaled by current UI scale) ----
    $sc = if ($script:_currentUIScale -gt 0) { [double]$script:_currentUIScale } else { 1.0 }
    $script:_mixerOpenScale = $sc   # Capture scale at open time (used by ResizeEnd handler)
    $CH_W = [int][Math]::Round(78 * $sc)   # input channel strip width
    $MST_W = [int][Math]::Round(100 * $sc)   # master strip width
    $SNAP_W = [int][Math]::Round(150 * $sc)   # snapshot panel width
    $RULER_W = [int][Math]::Round(34 * $sc)   # dB scale ruler width
    $MARGIN = $RULER_W + [int][Math]::Round(8 * $sc)   # left margin includes ruler
    $mainFormH = try { [int]$script:form.Height } catch { 750 }
    # Always match the main form height so mixer stays aligned regardless of scale or saved state
    $FRM_H = $mainFormH
    # Reset any stale saved base so it doesn't override on future opens
    $script:Cfg.XR.MixerPanelBaseH = 0
    $STRIP_H = [Math]::Max([int][Math]::Round(320 * $sc), $FRM_H - [int][Math]::Round(56 * $sc))
    $FRM_W = $MARGIN + 9 * $CH_W + $MST_W + $SNAP_W + [int][Math]::Round(8 * $sc) + [int][Math]::Round(14 * $sc)

    $MTR_W = [int][Math]::Round(18 * $sc)   # meter bar width
    $BTN_H = [int][Math]::Round(24 * $sc)   # height of per-channel action buttons
    $FADER_TOP = [int][Math]::Round(70 * $sc)   # y where fader starts
    $FADER_H = [Math]::Max([int][Math]::Round(80 * $sc), $STRIP_H - $FADER_TOP - [int][Math]::Round(84 * $sc))

    # Save layout for scroll-handler use (script scope so closures can read them)
    $script:_mpFaderTop = $FADER_TOP
    $script:_mpFaderH = $FADER_H

    # ---- Create form ----
    $frmM = New-Object System.Windows.Forms.Form
    $frmM.Text = "XR Mixer Panel"
    $frmM.Font = New-Object System.Drawing.Font('Segoe UI', [float](9.0 * $sc))
    $frmM.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::SizableToolWindow
    $frmM.ControlBox = $false   # hides the X button; close only via main app
    # Enable double buffering on the mixer form to eliminate flicker during repaints
    try {
        $frmM.GetType().GetProperty('DoubleBuffered', [System.Reflection.BindingFlags]'NonPublic,Instance').SetValue($frmM, $true)
    }
    catch {}
    $frmM.Size = [System.Drawing.Size]::new($FRM_W, $FRM_H)
    $frmM.MinimumSize = [System.Drawing.Size]::new([int][Math]::Round(640 * $sc), [int][Math]::Round(400 * $sc))
    $frmM.ShowInTaskbar = $false
    $frmM.BackColor = [System.Drawing.Color]::FromArgb(28, 28, 28)
    $frmM.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual

    # Compute position BEFORE Show() so WinForms honours Manual StartPosition
    $mainLeft = try { [int]$script:form.Left } catch { 400 }
    $mainTop = try { [int]$script:form.Top } catch { 100 }
    $workArea = try { [System.Windows.Forms.Screen]::FromHandle($script:form.Handle).WorkingArea } catch { [System.Drawing.Rectangle]::new(0, 0, 1920, 1080) }
    $panelX = [Math]::Max($workArea.Left, $mainLeft - $FRM_W - 6)
    $panelY = [Math]::Max($workArea.Top, [Math]::Min($mainTop, $workArea.Bottom - $FRM_H))
    $frmM.Location = [System.Drawing.Point]::new($panelX, $panelY)

    $script:_mixerPanel = $frmM
    $script:_mixerMeterPanels = New-Object object[] 10
    $script:_mixerFaderBars = New-Object object[] 10
    $script:_mixerLevelLabels = New-Object object[] 10
    $script:_mixerFaderLabels = New-Object object[] 10
    $script:_meterPeakDB = [double[]](@(-90.0) * 10)   # peak-hold per strip, reset on open
    $script:_meterRmsLin = [double[]](@(0.0) * 10)     # RMS EMA (linear power), reset on open

    # ---- Resolve labels from config ----
    $chLabels = @("Ch 1", "Ch 2", "Ch 3", "Ch 4", "Ch 5", "Ch 6", "Ch 7", "Ch 8", "Ch 9")
    if ($script:Cfg.XR.MixerChannelLabels -and $script:Cfg.XR.MixerChannelLabels.Count -ge 9) {
        for ($ci = 0; $ci -lt 9; $ci++) { $chLabels[$ci] = [string]$script:Cfg.XR.MixerChannelLabels[$ci] }
    }
    $masterLabel = if ($script:Cfg.XR.MixerMasterLabel) { [string]$script:Cfg.XR.MixerMasterLabel } else { "Master" }

    $snapLabels = @("", "", "", "", "", "", "", "")
    $snapNums = @(1, 2, 3, 4, 5, 6, 7, 8)
    $snapColors = @("", "", "", "", "", "", "", "")
    if ($script:Cfg.XR.MixerSnapLabels -and $script:Cfg.XR.MixerSnapLabels.Count -gt 0) {
        $cntSL = [Math]::Min(8, $script:Cfg.XR.MixerSnapLabels.Count)
        for ($ci = 0; $ci -lt $cntSL; $ci++) { $snapLabels[$ci] = [string]$script:Cfg.XR.MixerSnapLabels[$ci] }
    }
    if ($script:Cfg.XR.MixerSnapNumbers -and $script:Cfg.XR.MixerSnapNumbers.Count -gt 0) {
        $cntSN = [Math]::Min(8, $script:Cfg.XR.MixerSnapNumbers.Count)
        for ($ci = 0; $ci -lt $cntSN; $ci++) { $snapNums[$ci] = [int]$script:Cfg.XR.MixerSnapNumbers[$ci] }
    }
    if ($script:Cfg.XR.MixerSnapColors -and $script:Cfg.XR.MixerSnapColors.Count -gt 0) {
        $cntSC = [Math]::Min(8, $script:Cfg.XR.MixerSnapColors.Count)
        for ($ci = 0; $ci -lt $cntSC; $ci++) { $snapColors[$ci] = [string]$script:Cfg.XR.MixerSnapColors[$ci] }
    }

    # ---- Strip role color + mute button references (for pair-connector ovals) ----
    $script:_stripRoleColors = @{}
    $script:_mixerMuteButtons = New-Object object[] 10
    $script:_mixerOnBtns = New-Object object[] 10
    $script:_masterFaderLocked = $true   # Master fader locked by default

    # ---- Build 9 input channel strips + 1 master strip ----
    for ($i = 0; $i -lt 10; $i++) {
        $isM = ($i -eq 9)
        $ch = $i + 1   # OSC channel 1-9; 10 = master placeholder
        $sw = if ($isM) { $MST_W } else { $CH_W }
        $sx = if ($isM) { $MARGIN + 9 * $CH_W } else { $MARGIN + $i * $CH_W }

        # Divider line before master
        if ($isM) {
            $div = New-Object System.Windows.Forms.Label
            $div.Location = [System.Drawing.Point]::new(($sx - 2), 2)
            $div.Size = [System.Drawing.Size]::new(2, $STRIP_H + 10)
            $div.BackColor = [System.Drawing.Color]::FromArgb(90, 90, 90)
            $frmM.Controls.Add($div)
        }

        # Strip background panel
        $pSt = New-Object System.Windows.Forms.Panel
        $pSt.Location = [System.Drawing.Point]::new($sx, 4)
        $pSt.Size = [System.Drawing.Size]::new($sw, $STRIP_H)
        $pSt.BackColor = if ($isM) { [System.Drawing.Color]::FromArgb(38, 38, 52) } `
            else { [System.Drawing.Color]::FromArgb(42, 42, 42) }
        $pSt.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
        $frmM.Controls.Add($pSt)

        # Channel label (TextBox — read-only by default; right-click to edit)
        $tbL = New-Object System.Windows.Forms.TextBox
        $tbL.Text = if ($isM) { $masterLabel } else { $chLabels[$i] }
        $tbL.Size = [System.Drawing.Size]::new(($sw - 6), 20)
        $tbL.Location = [System.Drawing.Point]::new(3, 4)
        $tbL.BorderStyle = [System.Windows.Forms.BorderStyle]::None
        $tbL.BackColor = [System.Drawing.Color]::FromArgb(55, 55, 68)
        $tbL.ForeColor = if ($isM) { [System.Drawing.Color]::LightYellow } else { [System.Drawing.Color]::White }
        $tbL.Font = New-Object System.Drawing.Font("Segoe UI", 7.5, [System.Drawing.FontStyle]::Bold)
        $tbL.TextAlign = [System.Windows.Forms.HorizontalAlignment]::Center
        $tbL.ReadOnly = $true      # locked until right-click
        $tbL.TabStop = $false      # don't receive focus via Tab or on form open
        $tbL.Cursor = [System.Windows.Forms.Cursors]::Default
        $tbL.Tag = $i
        # Right-click: unlock for editing
        $tbL.Add_MouseDown({
                param($s, $e)
                if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Right) {
                    $s.ReadOnly = $false
                    $s.Cursor = [System.Windows.Forms.Cursors]::IBeam
                    $s.BackColor = [System.Drawing.Color]::FromArgb(75, 75, 95)
                    $s.Focus() | Out-Null
                    $s.SelectAll()
                }
            })
        $tbL.Add_LostFocus({
                param($s, $e)
                # Save if we were in edit mode
                if (-not $s.ReadOnly) {
                    $ii = [int]$s.Tag
                    if ($ii -lt 9) {
                        $arr = $script:Cfg.XR.MixerChannelLabels
                        if (-not $arr -or $arr.Count -lt 9) { $arr = "Ch 1", "Ch 2", "Ch 3", "Ch 4", "Ch 5", "Ch 6", "Ch 7", "Ch 8", "Ch 9" }
                        $arr[$ii] = $s.Text
                        $script:Cfg.XR.MixerChannelLabels = $arr
                    }
                    else { $script:Cfg.XR.MixerMasterLabel = $s.Text }
                    try { Save-Settings | Out-Null } catch {}
                }
                # Restore locked appearance
                $s.ReadOnly = $true
                $s.Cursor = [System.Windows.Forms.Cursors]::Default
                $s.BackColor = [System.Drawing.Color]::FromArgb(55, 55, 68)
            })
        $pSt.Controls.Add($tbL)

        # Meter level label (dBFS reading)
        $lblLvl = New-Object System.Windows.Forms.Label
        $lblLvl.Text = if ($isM) { "L/R" } else { "-∞" }
        $lblLvl.Size = [System.Drawing.Size]::new(($sw - 6), 16)
        $lblLvl.Location = [System.Drawing.Point]::new(3, 26)
        $lblLvl.ForeColor = [System.Drawing.Color]::FromArgb(160, 230, 160)
        $lblLvl.BackColor = [System.Drawing.Color]::Transparent
        $lblLvl.Font = New-Object System.Drawing.Font("Consolas", 7)
        $lblLvl.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
        $pSt.Controls.Add($lblLvl)
        $lblLvl.Visible = [bool]$script:Cfg.XR.ShowLevelLabels
        $script:_mixerLevelLabels[$i] = $lblLvl

        # Role label above fader (right-click to edit text + color)
        $roleLabel = New-Object System.Windows.Forms.Label
        $roleLabel.Size = [System.Drawing.Size]::new(($sw - 6), $BTN_H)
        $roleLabel.Location = [System.Drawing.Point]::new(3, 44)
        $roleLabel.BorderStyle = [System.Windows.Forms.BorderStyle]::None
        $roleLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
        $roleLabel.Font = New-Object System.Drawing.Font("Segoe UI", 7.5, [System.Drawing.FontStyle]::Bold)
        $roleLabel.Cursor = [System.Windows.Forms.Cursors]::Hand
        $roleLabel.Tag = $i   # strip index
        # Load saved label + color
        $savedRoleText = ""
        $savedRoleColor = ""
        if ($script:Cfg.XR.MixerRoleLabels -and $script:Cfg.XR.MixerRoleLabels.Count -gt $i) { $savedRoleText = [string]$script:Cfg.XR.MixerRoleLabels[$i] }
        if ($script:Cfg.XR.MixerRoleColors -and $script:Cfg.XR.MixerRoleColors.Count -gt $i) { $savedRoleColor = [string]$script:Cfg.XR.MixerRoleColors[$i] }
        $roleLabel.Text = $savedRoleText
        # Apply saved color
        $script:_roleLabelColors = if (-not $script:_roleLabelColors) { @{} } else { $script:_roleLabelColors }
        $colorMap = @{
            "Red"     = [System.Drawing.Color]::FromArgb(160, 40, 40)
            "Blue"    = [System.Drawing.Color]::FromArgb(30, 80, 180)
            "Green"   = [System.Drawing.Color]::FromArgb(30, 140, 50)
            "Yellow"  = [System.Drawing.Color]::FromArgb(180, 160, 0)
            "Magenta" = [System.Drawing.Color]::FromArgb(160, 40, 160)
            "Cyan"    = [System.Drawing.Color]::FromArgb(0, 150, 170)
            "White"   = [System.Drawing.Color]::FromArgb(200, 200, 200)
        }
        if ($savedRoleColor -and $colorMap.Contains($savedRoleColor)) {
            $roleLabel.BackColor = $colorMap[$savedRoleColor]
            $roleLabel.ForeColor = if ($savedRoleColor -eq "Yellow" -or $savedRoleColor -eq "White") { [System.Drawing.Color]::Black } else { [System.Drawing.Color]::White }
        }
        else {
            $roleLabel.BackColor = [System.Drawing.Color]::FromArgb(45, 45, 58)
            $roleLabel.ForeColor = [System.Drawing.Color]::FromArgb(210, 210, 210)
        }
        # Right-click: flash + show edit context menu
        $roleLabel.Add_MouseDown({
                param($rlSender, $rlEvt)
                if ($rlEvt.Button -ne [System.Windows.Forms.MouseButtons]::Right) { return }
                $rlIdx = [int]$rlSender.Tag
                $script:_rlEditCtrl = $rlSender
                $script:_rlEditIdx = $rlIdx
                # Flash: toggle bright white 3 times
                $script:_rlFlashOrigBack = $rlSender.BackColor
                $script:_rlFlashOrigFore = $rlSender.ForeColor
                $flashTimer = New-Object System.Windows.Forms.Timer
                $flashTimer.Interval = 80
                $script:_rlFlashCount = 0
                $flashTimer.Add_Tick({
                        $script:_rlFlashCount++
                        if ($script:_rlFlashCount % 2 -eq 1) {
                            $script:_rlEditCtrl.BackColor = [System.Drawing.Color]::White
                            $script:_rlEditCtrl.ForeColor = [System.Drawing.Color]::Black
                        }
                        else {
                            $script:_rlEditCtrl.BackColor = $script:_rlFlashOrigBack
                            $script:_rlEditCtrl.ForeColor = $script:_rlFlashOrigFore
                        }
                        if ($script:_rlFlashCount -ge 6) { $this.Stop(); $this.Dispose() }
                    })
                $flashTimer.Start()
                # Show inline edit panel (label + color in one session, like snapshot edit)
                if ($script:_roleLabelEditPnl -and -not $script:_roleLabelEditPnl.IsDisposed) {
                    $curTxt = $rlSender.Text
                    if ([string]::IsNullOrWhiteSpace($curTxt)) { $curTxt = "Label" }
                    $script:_rlEditTB.Text = $curTxt
                    $rlCurColor = ""
                    if ($script:Cfg.XR.MixerRoleColors -and $script:Cfg.XR.MixerRoleColors.Count -gt $rlIdx) {
                        $rlCurColor = [string]$script:Cfg.XR.MixerRoleColors[$rlIdx]
                    }
                    $script:_roleLabelEditPnl.Tag = @{ ActiveIdx = $rlIdx; SelectedColor = $rlCurColor }
                    # Highlight matching color swatch
                    foreach ($rlSw in $script:_roleLabelEditPnl.Controls) {
                        if ($rlSw -is [System.Windows.Forms.Panel] -and $rlSw.Tag -is [string]) {
                            $rlSw.BorderStyle = if ([string]$rlSw.Tag -eq $rlCurColor) {
                                [System.Windows.Forms.BorderStyle]::Fixed3D
                            }
                            else { [System.Windows.Forms.BorderStyle]::FixedSingle }
                        }
                    }
                    # Position panel below the clicked label, clamped to mixer form
                    $ptScr = $rlSender.PointToScreen([System.Drawing.Point]::new(0, 0))
                    $ptCli = $script:_mixerPanel.PointToClient($ptScr)
                    $rlPx = $ptCli.X
                    $rlPy = $ptCli.Y + $rlSender.Height + 2
                    if (($rlPx + $script:_roleLabelEditPnl.Width) -gt ($script:_mixerPanel.ClientSize.Width - 4)) {
                        $rlPx = $script:_mixerPanel.ClientSize.Width - $script:_roleLabelEditPnl.Width - 4
                    }
                    if (($rlPy + $script:_roleLabelEditPnl.Height) -gt ($script:_mixerPanel.ClientSize.Height - 4)) {
                        $rlPy = $ptCli.Y - $script:_roleLabelEditPnl.Height - 2
                    }
                    if ($rlPx -lt 0) { $rlPx = 0 }
                    if ($rlPy -lt 0) { $rlPy = 0 }
                    $script:_roleLabelEditPnl.Location = [System.Drawing.Point]::new($rlPx, $rlPy)
                    $script:_roleLabelEditPnl.BringToFront()
                    $script:_roleLabelEditPnl.Visible = $true
                    $script:_rlEditTB.Focus()
                    $script:_rlEditTB.SelectAll()
                }
            })
        $pSt.Controls.Add($roleLabel)
        $roleLabel.Add_Paint({
                param($bSr, $pe)
                $g = $pe.Graphics
                $rc = $bSr.ClientRectangle
                if ($rc.Width -le 0 -or $rc.Height -le 0) { return }
                $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
                $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit
                $base = $bSr.BackColor
                $topC = [System.Drawing.Color]::FromArgb(
                    [Math]::Min(255, $base.R + 70), [Math]::Min(255, $base.G + 70), [Math]::Min(255, $base.B + 70))
                $botC = [System.Drawing.Color]::FromArgb(
                    [Math]::Max(0, $base.R - 35), [Math]::Max(0, $base.G - 35), [Math]::Max(0, $base.B - 35))
                $lgb = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
                    $rc, $topC, $botC, [System.Drawing.Drawing2D.LinearGradientMode]::Vertical)
                $g.FillRectangle($lgb, $rc); $lgb.Dispose()
                $sH = [Math]::Max(1, [Math]::Min($rc.Height - 1, [int]($rc.Height * 0.42)))
                $sR = [System.Drawing.Rectangle]::new(0, 0, $rc.Width, $sH)
                $shin = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
                    $sR,
                    [System.Drawing.Color]::FromArgb(80, 255, 255, 255),
                    [System.Drawing.Color]::FromArgb(0, 255, 255, 255),
                    [System.Drawing.Drawing2D.LinearGradientMode]::Vertical)
                $g.FillRectangle($shin, $sR); $shin.Dispose()
                $pen2 = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(50, 50, 50), 1)
                $g.DrawRectangle($pen2, 0, 0, $rc.Width - 1, $rc.Height - 1); $pen2.Dispose()
                $sf2 = New-Object System.Drawing.StringFormat
                $sf2.Alignment = [System.Drawing.StringAlignment]::Center
                $sf2.LineAlignment = [System.Drawing.StringAlignment]::Center
                $sb3 = New-Object System.Drawing.SolidBrush($bSr.ForeColor)
                $g.DrawString($bSr.Text, $bSr.Font, $sb3,
                    [System.Drawing.RectangleF]::new(0, 0, $rc.Width, $rc.Height), $sf2)
                $sb3.Dispose(); $sf2.Dispose()
            })

        # Fader position label (below fader)
        $lblFdr = New-Object System.Windows.Forms.Label
        # Fall back to 0.0 (fader bottom = -inf) when offline — never show 0 dB while disconnected
        $initLinear = if (-not $isM) { try { [double](XR-ReadFaderPosition $ch) } catch { 0.0 } } else { 0.0 }
        $initDB = try { [double](ConvertTo-Decibels $initLinear) } catch { 0.0 }
        $lblFdr.Text = if ($initLinear -lt 0.001) { "-inf" } else { ("{0:F1}" -f $initDB) + "dB" }
        $lblFdr.Size = [System.Drawing.Size]::new(($sw - 6), 16)
        $lblFdr.Location = [System.Drawing.Point]::new(3, ($FADER_TOP + $FADER_H + $BTN_H * 2 + 8))
        $lblFdr.ForeColor = [System.Drawing.Color]::FromArgb(200, 200, 200)
        $lblFdr.BackColor = [System.Drawing.Color]::Transparent
        $lblFdr.Font = New-Object System.Drawing.Font("Consolas", 7)
        $lblFdr.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
        $pSt.Controls.Add($lblFdr)
        $script:_mixerFaderLabels[$i] = $lblFdr

        # Meter panel (left portion of fader area)
        $mW2 = if ($isM) { ($MTR_W * 2 + 2) } else { $MTR_W }
        $pM = New-Object System.Windows.Forms.Panel
        $pM.Location = [System.Drawing.Point]::new(3, $FADER_TOP)
        $pM.Size = [System.Drawing.Size]::new($mW2, $FADER_H)
        $pM.BackColor = [System.Drawing.Color]::FromArgb(12, 12, 12)
        $pM.Tag = $i
        Enable-OwnerDrawDoubleBuffer $pM
        $pM.Add_Paint({
                param($s2, $e2)
                $ii2 = [int]$s2.Tag
                $isM2 = ($ii2 -eq 9)
                $g2 = $e2.Graphics
                # Dimmed zone background: near-black (>+8), red (+8..-7), yellow (-7..-18), green (below -18)
                $g2.Clear([System.Drawing.Color]::FromArgb(12, 12, 12))
                $_bgH = $s2.Height; $_bgW = $s2.Width
                $_bgTopPad = 0                              # no gap — red zone starts at top of panel
                $_bgBlkY = [int]($_bgH * 0.05)             # +8 dB boundary
                $_bgRedY = [int]($_bgH * 0.355)            # -7 dB boundary
                $_bgYelY = [int]($_bgH * 0.52)             # -18 dB boundary
                $g2.FillRectangle((New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(12, 12, 12))), 0, $_bgTopPad, $_bgW, ([Math]::Max(0, $_bgBlkY - $_bgTopPad)))
                $g2.FillRectangle((New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(63, 17, 17))), 0, $_bgBlkY, $_bgW, ([Math]::Max(0, $_bgRedY - $_bgBlkY)))
                $g2.FillRectangle((New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(57, 55, 9))), 0, $_bgRedY, $_bgW, ([Math]::Max(0, $_bgYelY - $_bgRedY)))
                $g2.FillRectangle((New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(11, 55, 20))), 0, $_bgYelY, $_bgW, ($_bgH - $_bgYelY))

                # Shared helper: draw a single vertical bar given dBFS value
                # Scale matches ruler: +10 dB at top, -70 dB at bottom (80 dB span)
                $drawBar = {
                    param([System.Drawing.Graphics]$gx, [double]$dBFS, [int]$xOff, [int]$barW, [int]$barH)
                    # dBFS is already calibrated (+15 applied at source in XrMeterLevels)
                    $dB = [Math]::Min(10.0, $dBFS)
                    # Two-segment linear scale: top 25% = +10..0 dB, bottom 75% = 0..-50 dB
                    # 0 dB sits at exactly 25% from top — same as fader unity mark
                    $pct = if ($dB -ge 10.0) { 1.0 } elseif ($dB -gt 0.0) { 0.75 + ($dB / 10.0) * 0.25 } elseif ($dB -gt -50.0) { 0.75 * (1.0 + $dB / 50.0) } else { 0.0 }
                    $fillH = [int]($pct * $barH)
                    if ($fillH -le 0) { return }
                    $fillY = $barH - $fillH
                    # Thresholds (display dB): near-black >+8, red >-7, yellow >-18, green otherwise
                    $blkY = [int]($barH * 0.05)     # 1.0 - (0.75 + (8/10)*0.25)  = 0.05
                    $redY = [int]($barH * 0.355)    # 1.0 - 0.75*(1 - 7/50)       = 0.355
                    $yelY = [int]($barH * 0.52)     # 1.0 - 0.75*(1 - 18/50)      = 0.52
                    $dy = $fillY
                    if ($dy -lt $blkY) {
                        $hh = [Math]::Min($blkY, $barH) - $dy
                        $gx.FillRectangle((New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(12, 12, 12))), $xOff, $dy, $barW, $hh)
                        $dy = $blkY
                    }
                    if ($dy -lt $redY) {
                        $hh = [Math]::Min($redY, $barH) - $dy
                        $gx.FillRectangle((New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(210, 40, 40))), $xOff, $dy, $barW, $hh)
                        $dy = $redY
                    }
                    if ($dy -lt $yelY) {
                        $hh = [Math]::Min($yelY, $barH) - $dy
                        $gx.FillRectangle((New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(220, 200, 0))), $xOff, $dy, $barW, $hh)
                        $dy = $yelY
                    }
                    if ($dy -lt $barH) {
                        $gx.FillRectangle((New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(0, 200, 80))), $xOff, $dy, $barW, ($barH - $dy))
                    }
                }

                if (-not $isM2) {
                    $dBFS2 = try { [double](XR-GetMeterLevel ($ii2 + 1)) } catch { -90.0 }
                    # Update peak hold — reset when signal drops below -50 dB (silence)
                    if ($dBFS2 -le -50.0) { $script:_meterPeakDB[$ii2] = -90.0 }
                    elseif ($dBFS2 -gt $script:_meterPeakDB[$ii2]) { $script:_meterPeakDB[$ii2] = $dBFS2 }
                    # Update RMS EMA (α=0.93 → ~1.4 s time constant at 100 ms ticks)
                    $script:_meterRmsLin[$ii2] = 0.93 * $script:_meterRmsLin[$ii2] + 0.07 * [Math]::Pow(10.0, $dBFS2 / 10.0)
                    & $drawBar $g2 $dBFS2 0 $s2.Width $s2.Height
                    # Draw RMS line — thin white, slower-moving perceived loudness indicator
                    $rmsDB2 = 10.0 * [Math]::Log10([Math]::Max(1e-12, $script:_meterRmsLin[$ii2]))
                    if ($rmsDB2 -gt -89.0) {
                        $rmsC2 = [Math]::Min(10.0, $rmsDB2)
                        $rmsPct2 = if ($rmsC2 -ge 10.0) { 1.0 } elseif ($rmsC2 -gt 0.0) { 0.75 + ($rmsC2 / 10.0) * 0.25 } elseif ($rmsC2 -gt -50.0) { 0.75 * (1.0 + $rmsC2 / 50.0) } else { 0.0 }
                        $rmsY2 = [Math]::Max(0, [Math]::Min($s2.Height - 1, $s2.Height - [int](($rmsPct2 - 0.10) * $s2.Height)))
                        $rmsPen2 = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(18, 18, 18), 2)
                        $g2.DrawLine($rmsPen2, 0, $rmsY2, $s2.Width - 1, $rmsY2)
                        $rmsPen2.Dispose()
                    }
                    # Draw peak-hold line (color matches bar: near-black >+8, red >-7, yellow >-18, green otherwise)
                    $pkDB2 = $script:_meterPeakDB[$ii2]
                    if ($pkDB2 -gt -89.0) {
                        $pkDB2c = [Math]::Min(10.0, $pkDB2)
                        $pkPct2 = if ($pkDB2c -ge 10.0) { 1.0 } elseif ($pkDB2c -gt 0.0) { 0.75 + ($pkDB2c / 10.0) * 0.25 } elseif ($pkDB2c -gt -50.0) { 0.75 * (1.0 + $pkDB2c / 50.0) } else { 0.0 }
                        $pkY2 = [Math]::Max(0, [Math]::Min($s2.Height - 2, $s2.Height - [int]($pkPct2 * $s2.Height)))
                        $pkCol2 = if ($pkDB2 -gt 8.0) { [System.Drawing.Color]::FromArgb(12, 12, 12) } elseif ($pkDB2 -gt -7.0) { [System.Drawing.Color]::FromArgb(210, 40, 40) } elseif ($pkDB2 -gt -18.0) { [System.Drawing.Color]::FromArgb(220, 200, 0) } else { [System.Drawing.Color]::FromArgb(0, 200, 80) }
                        $pkPen2 = New-Object System.Drawing.Pen($pkCol2, 2)
                        $g2.DrawLine($pkPen2, 0, $pkY2, $s2.Width - 1, $pkY2)
                        $pkPen2.Dispose()
                    }
                }
                else {
                    # Master: two side-by-side bars showing peak across all 9 input channels
                    # /meters/2 index 0+1 are CH1/CH2 post-fader, NOT the main LR bus,
                    # so we compute the true peak from all channels already tracked.
                    $hw = [int](($s2.Width - 2) / 2)
                    $masterPeak = -90.0
                    for ($cm = 1; $cm -le 9; $cm++) {
                        $cv = try { [double](XR-GetMeterLevel $cm) } catch { -90.0 }
                        if ($cv -gt $masterPeak) { $masterPeak = $cv }
                    }
                    # Update master peak hold — reset when all channels drop below -50 dB
                    if ($masterPeak -le -50.0) { $script:_meterPeakDB[9] = -90.0 }
                    elseif ($masterPeak -gt $script:_meterPeakDB[9]) { $script:_meterPeakDB[9] = $masterPeak }
                    # Update master RMS EMA
                    $script:_meterRmsLin[9] = 0.93 * $script:_meterRmsLin[9] + 0.07 * [Math]::Pow(10.0, $masterPeak / 10.0)
                    & $drawBar $g2 $masterPeak 0         $hw $s2.Height
                    & $drawBar $g2 $masterPeak ($hw + 2) $hw $s2.Height
                    # Draw master RMS line
                    $rmsDBM = 10.0 * [Math]::Log10([Math]::Max(1e-12, $script:_meterRmsLin[9]))
                    if ($rmsDBM -gt -89.0) {
                        $rmsMc = [Math]::Min(10.0, $rmsDBM)
                        $rmsMpct = if ($rmsMc -ge 10.0) { 1.0 } elseif ($rmsMc -gt 0.0) { 0.75 + ($rmsMc / 10.0) * 0.25 } elseif ($rmsMc -gt -50.0) { 0.75 * (1.0 + $rmsMc / 50.0) } else { 0.0 }
                        $rmsMy = [Math]::Max(0, [Math]::Min($s2.Height - 1, $s2.Height - [int](($rmsMpct - 0.10) * $s2.Height)))
                        $rmsMpen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(18, 18, 18), 2)
                        $g2.DrawLine($rmsMpen, 0, $rmsMy, $s2.Width - 1, $rmsMy)
                        $rmsMpen.Dispose()
                    }
                    # Draw master peak-hold line (color: near-black >+8, red >-7, yellow >-18, green otherwise)
                    $pkM = $script:_meterPeakDB[9]
                    if ($pkM -gt -89.0) {
                        $pkMc = [Math]::Min(10.0, $pkM)
                        $pkMpct = if ($pkMc -ge 10.0) { 1.0 } elseif ($pkMc -gt 0.0) { 0.75 + ($pkMc / 10.0) * 0.25 } elseif ($pkMc -gt -50.0) { 0.75 * (1.0 + $pkMc / 50.0) } else { 0.0 }
                        $pkMy = [Math]::Max(0, [Math]::Min($s2.Height - 2, $s2.Height - [int]($pkMpct * $s2.Height)))
                        $pkColM = if ($pkM -gt 8.0) { [System.Drawing.Color]::FromArgb(12, 12, 12) } elseif ($pkM -gt -7.0) { [System.Drawing.Color]::FromArgb(210, 40, 40) } elseif ($pkM -gt -18.0) { [System.Drawing.Color]::FromArgb(220, 200, 0) } else { [System.Drawing.Color]::FromArgb(0, 200, 80) }
                        $pkPenM = New-Object System.Drawing.Pen($pkColM, 2)
                        $g2.DrawLine($pkPenM, 0, $pkMy, $s2.Width - 1, $pkMy)
                        $pkPenM.Dispose()
                    }
                }
            })
        $pSt.Controls.Add($pM)
        $script:_mixerMeterPanels[$i] = $pM

        # Custom rectangular fader Panel (owner-drawn, replaces TrackBar)
        $fbX = $mW2 + 5
        $fbW = [Math]::Max(22, $sw - $fbX - 2)
        # Handle color: use role label color if set, otherwise default blue
        $fdrHandleColor = [System.Drawing.Color]::FromArgb(30, 100, 200)
        if ($savedRoleColor -and $colorMap.Contains($savedRoleColor)) {
            $fdrHandleColor = $colorMap[$savedRoleColor]
        }
        $tb = New-Object System.Windows.Forms.Panel
        $tb.Location = [System.Drawing.Point]::new($fbX, $FADER_TOP)
        $tb.Size = [System.Drawing.Size]::new($fbW, $FADER_H)
        $tb.BackColor = [System.Drawing.Color]::FromArgb(28, 28, 28)
        $tb.TabStop = $true
        $tb.Cursor = [System.Windows.Forms.Cursors]::SizeNS
        Enable-OwnerDrawDoubleBuffer $tb
        $tb.Tag = @{
            Index          = $i
            Value          = [Math]::Max(0, [Math]::Min(1000, [int]($initLinear * 1000)))
            HandleColor    = $fdrHandleColor
            HasCustomColor = [bool]($savedRoleColor -and $colorMap.Contains($savedRoleColor))
            Dragging       = $false
            DragStartY     = 0
            DragStartVal   = 0
        }
        $tb.Add_MouseEnter({ $args[0].Focus() })
        $tb.Add_Paint({
                param($pSr, $pEv)
                $g = $pEv.Graphics
                $w = $pSr.Width
                $h = $pSr.Height
                $td = $pSr.Tag
                $val = [double]$td.Value   # 0..1000
                $hH = 34                  # handle height px (taller)
                $numW = 13                  # px reserved on left for dB labels
                # --- dB scale ruler labels & tick marks (left zone) ---
                $sf = New-Object System.Drawing.Font("Consolas", 5)
                $tp = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(55, 55, 55), 1)
                $dbMarks = @(
                    @{ Label = "+10"; dB = 10.0 },
                    @{ Label = " +5"; dB = 5.0 },
                    @{ Label = "  0"; dB = 0.0 },
                    @{ Label = " -5"; dB = -5.0 },
                    @{ Label = "-10"; dB = -10.0 },
                    @{ Label = "-15"; dB = -15.0 },
                    @{ Label = "-20"; dB = -20.0 },
                    @{ Label = "-25"; dB = -25.0 },
                    @{ Label = "-30"; dB = -30.0 },
                    @{ Label = "-35"; dB = -35.0 },
                    @{ Label = "-40"; dB = -40.0 },
                    @{ Label = "-50"; dB = -50.0 }
                )
                foreach ($mk in $dbMarks) {
                    $dBval = [double]$mk.dB
                    $linFdr = if ($dBval -ge 10.0) { 1.0 } elseif ($dBval -gt 0.0) { 0.75 + ($dBval / 10.0) * 0.25 } elseif ($dBval -gt -50.0) { 0.75 * (1.0 + $dBval / 50.0) } else { 0.0 }
                    # Align tick to fader handle center: same formula as handle paint (travel = h-hH-2, center = hY + hH/2)
                    $y = 1 + [int]((1.0 - $linFdr) * ($h - $hH - 2)) + [int]($hH / 2)
                    $isZero = ($mk.Label.Trim() -eq "0")
                    $col = if ($isZero) { [System.Drawing.Color]::FromArgb(220, 200, 0) } else { [System.Drawing.Color]::FromArgb(90, 90, 90) }
                    $br = New-Object System.Drawing.SolidBrush($col)
                    $ly = [Math]::Min($y, $h - 1)
                    $g.DrawLine($tp, $numW, $ly, $w, $ly)
                    $textY = [Math]::Max(0, [Math]::Min($h - 7, $y - 3))
                    $g.DrawString($mk.Label, $sf, $br, 0, $textY)
                    try { $br.Dispose() } catch {}
                }
                try { $sf.Dispose() } catch {}
                try { $tp.Dispose() } catch {}
                # --- Handle Y: value 1000 = top, 0 = bottom ---
                $travel = $h - $hH - 2
                $hY = 1 + [int]( (1.0 - $val / 1000.0) * $travel )
                $cY = $hY + [int]($hH / 2)
                # --- Groove split: above handle = dim, below handle = bright ---
                $gW = 4; $gX = $numW + [int](($w - $numW - $gW) / 2)
                if ($td.HasCustomColor) {
                    $hc = $td.HandleColor
                    $grooveTopColor = [System.Drawing.Color]::FromArgb(
                        [Math]::Max(0, [int]($hc.R * 0.345)),
                        [Math]::Max(0, [int]($hc.G * 0.345)),
                        [Math]::Max(0, [int]($hc.B * 0.345))
                    )
                    $grooveBottomColor = [System.Drawing.Color]::FromArgb(
                        [Math]::Min(255, [int]($hc.R * 1.15)),
                        [Math]::Min(255, [int]($hc.G * 1.15)),
                        [Math]::Min(255, [int]($hc.B * 1.15))
                    )
                }
                else {
                    $grooveTopColor = [System.Drawing.Color]::FromArgb(80, 80, 80)
                    $grooveBottomColor = [System.Drawing.Color]::FromArgb(185, 185, 185)
                }
                $grooveTopY = 2
                $grooveBottomY = [Math]::Max($grooveTopY, [Math]::Min($h - 2, $cY))
                $grooveBottomEnd = $h - 2
                if ($grooveBottomY -gt $grooveTopY) {
                    $gBrTop = [System.Drawing.SolidBrush]::new($grooveTopColor)
                    $g.FillRectangle($gBrTop, $gX, $grooveTopY, $gW, ($grooveBottomY - $grooveTopY))
                    $gBrTop.Dispose()
                }
                if ($grooveBottomEnd -gt $grooveBottomY) {
                    # Fade zone: dim at handle, brightens over ~10dB (~30px) downward
                    $fadePixels = [Math]::Min(150, ($grooveBottomEnd - $grooveBottomY))
                    $fadeEnd = $grooveBottomY + $fadePixels
                    if ($fadePixels -gt 1) {
                        $fadeRect = [System.Drawing.Rectangle]::new($gX, $grooveBottomY, $gW, $fadePixels)
                        $fadeBrush = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
                            $fadeRect,
                            $grooveTopColor,
                            $grooveBottomColor,
                            [System.Drawing.Drawing2D.LinearGradientMode]::Vertical)
                        $g.FillRectangle($fadeBrush, $fadeRect)
                        $fadeBrush.Dispose()
                    }
                    else {
                        $gBrFade = [System.Drawing.SolidBrush]::new($grooveBottomColor)
                        $g.FillRectangle($gBrFade, $gX, $grooveBottomY, $gW, $fadePixels)
                        $gBrFade.Dispose()
                    }
                    # Solid bright section below the fade zone
                    if ($grooveBottomEnd -gt $fadeEnd) {
                        $gBrBottom = [System.Drawing.SolidBrush]::new($grooveBottomColor)
                        $g.FillRectangle($gBrBottom, $gX, $fadeEnd, $gW, ($grooveBottomEnd - $fadeEnd))
                        $gBrBottom.Dispose()
                    }
                }
                # --- Handle: 3D gradient with shine ---
                $hRect2 = [System.Drawing.Rectangle]::new($numW, $hY, $w - $numW - 2, $hH)
                $hBase = $td.HandleColor
                $hTopC = [System.Drawing.Color]::FromArgb([Math]::Min(255, $hBase.R + 70), [Math]::Min(255, $hBase.G + 70), [Math]::Min(255, $hBase.B + 70))
                $hBotC = [System.Drawing.Color]::FromArgb([Math]::Max(0, $hBase.R - 35), [Math]::Max(0, $hBase.G - 35), [Math]::Max(0, $hBase.B - 35))
                $hLgb = New-Object System.Drawing.Drawing2D.LinearGradientBrush($hRect2, $hTopC, $hBotC, [System.Drawing.Drawing2D.LinearGradientMode]::Vertical)
                $g.FillRectangle($hLgb, $hRect2); $hLgb.Dispose()
                $hSH = [Math]::Max(1, [int]($hH * 0.42))
                $hSR = [System.Drawing.Rectangle]::new($numW, $hY, $w - $numW - 2, $hSH)
                $hShin = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
                    $hSR,
                    [System.Drawing.Color]::FromArgb(80, 255, 255, 255),
                    [System.Drawing.Color]::FromArgb(0, 255, 255, 255),
                    [System.Drawing.Drawing2D.LinearGradientMode]::Vertical)
                $g.FillRectangle($hShin, $hSR); $hShin.Dispose()
                # Handle border
                $bPen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(50, 50, 50), 1)
                $g.DrawRectangle($bPen, $numW, $hY, $w - $numW - 3, $hH - 1)
                $bPen.Dispose()
                # White horizontal center line
                $lPen = New-Object System.Drawing.Pen([System.Drawing.Color]::White, 2)
                $g.DrawLine($lPen, $numW + 2, $cY, $w - 4, $cY)
                $lPen.Dispose()
            })
        if ($isM) { $tb.Cursor = [System.Windows.Forms.Cursors]::No }
        $tb.Add_MouseDown({
                param($mSr, $mEv)
                if ($mEv.Button -ne [System.Windows.Forms.MouseButtons]::Left) { return }
                if ($mSr.Tag.Index -eq 9 -and $script:_masterFaderLocked) { return }
                $td = $mSr.Tag; $td.Dragging = $true
                $td.DragStartY = $mEv.Y; $td.DragStartVal = $td.Value
                $mSr.Capture = $true
            })
        $tb.Add_MouseMove({
                param($mSr, $mEv)
                $td = $mSr.Tag
                if (-not $td.Dragging) { return }
                $hH = 34; $travel = $mSr.Height - $hH - 2
                if ($travel -le 0) { return }
                $dy = $mEv.Y - $td.DragStartY
                $newVal = [Math]::Max(0, [Math]::Min(1000, $td.DragStartVal - [int]($dy * 1000.0 / $travel)))
                $td.Value = $newVal
                $mSr.Invalidate()
                if ($script:_mixerUpdating) { return }
                $ii = $td.Index; $linear = $newVal / 1000.0
                if ($ii -lt 9) { XR-WriteFaderPosition ($ii + 1) $linear }
                else { try { XR-SendOSC "/lr/mix/fader" ([single]$linear) } catch {} }
                $fl = $script:_mixerFaderLabels[$ii]
                if ($fl -and -not $fl.IsDisposed) {
                    $fl.Text = if ($linear -lt 0.001) { "-inf" } else { ("{0:F1}" -f [double](ConvertTo-Decibels $linear)) + "dB" }
                }
            })
        $tb.Add_MouseUp({
                param($mSr, $mEv)
                $mSr.Tag.Dragging = $false; $mSr.Capture = $false
            })
        $tb.Add_MouseWheel({
                param($mSr, $mEv)
                $td = $mSr.Tag
                if ($td.Index -eq 9 -and $script:_masterFaderLocked) { return }
                $delta = if ($mEv.Delta -gt 0) { 30 } else { -30 }
                $newVal = [Math]::Max(0, [Math]::Min(1000, $td.Value + $delta))
                $td.Value = $newVal; $mSr.Invalidate()
                if ($script:_mixerUpdating) { return }
                $ii = $td.Index; $linear = $newVal / 1000.0
                if ($ii -lt 9) { XR-WriteFaderPosition ($ii + 1) $linear }
                else { try { XR-SendOSC "/lr/mix/fader" ([single]$linear) } catch {} }
                $fl = $script:_mixerFaderLabels[$ii]
                if ($fl -and -not $fl.IsDisposed) {
                    $fl.Text = if ($linear -lt 0.001) { "-inf" } else { ("{0:F1}" -f [double](ConvertTo-Decibels $linear)) + "dB" }
                }
            })
        $pSt.Controls.Add($tb)
        $script:_mixerFaderBars[$i] = $tb

        # Unity (0 dB) marker line — at linear 0.75 → Value 250 = 25% from top
        $unityPct = 0.25   # 1.0 - 0.75 = 0.25 (inverted mapping)
        $unityY = $FADER_TOP + [int]($unityPct * $FADER_H)
        $uLine = New-Object System.Windows.Forms.Label
        $uLine.Location = [System.Drawing.Point]::new(($fbX - 2), $unityY)
        $uLine.Size = [System.Drawing.Size]::new(4, 2)
        $uLine.BackColor = [System.Drawing.Color]::FromArgb(200, 200, 0)
        $pSt.Controls.Add($uLine)

        # Buttons below fader
        # --- ON toggle button (was Solo/Dim) ---
        # OFF state: dimmed version of the label color (or grey if no color)
        # ON  state: bright label color; sends fader to 0 dB (linear 0.75)
        # OFF click: sends fader to -inf (linear 0.0)
        $onBtnColorBright = if ($savedRoleColor -and $colorMap.Contains($savedRoleColor)) {
            $colorMap[$savedRoleColor]
        }
        else {
            [System.Drawing.Color]::FromArgb(30, 100, 200)   # default blue
        }
        $onBtnColorDim = [System.Drawing.Color]::FromArgb(
            [int]($onBtnColorBright.R / 4),
            [int]($onBtnColorBright.G / 4),
            [int]($onBtnColorBright.B / 4)
        )
        $btnBot1 = New-Object System.Windows.Forms.Button
        $btnBot1.Size = [System.Drawing.Size]::new(($sw - 6), $BTN_H)
        $btnBot1.Location = [System.Drawing.Point]::new(3, ($FADER_TOP + $FADER_H + 4))
        $btnBot1.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
        $btnBot1.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(80, 80, 80)
        $btnBot1.FlatAppearance.BorderSize = 0
        $btnBot1.BackColor = $onBtnColorDim
        $btnBot1.ForeColor = [System.Drawing.Color]::FromArgb(160, 160, 160)
        $btnBot1.Font = New-Object System.Drawing.Font("Segoe UI", 7.5, [System.Drawing.FontStyle]::Bold)
        $btnBot1.Text = if ($isM) { "* LOCK" } else { "ON" }
        $btnBot1.Tag = @{
            Index       = $i
            IsOn        = $false
            ColorBright = $onBtnColorBright
            ColorDim    = $onBtnColorDim
            IsM         = $isM
        }
        $btnBot1.Add_Click({
                param($bSr, $bEv)
                $bt = $bSr.Tag
                # Master strip: left-click when unlocked → re-lock; ignore when already locked
                if ($bt.IsM) {
                    if (-not $script:_masterFaderLocked) {
                        $script:_masterFaderLocked = $true
                        $bSr.BackColor = $bt.ColorDim
                        $bSr.ForeColor = [System.Drawing.Color]::FromArgb(160, 160, 160)
                        $bSr.Text = "* LOCK"
                        $fbCtrl = $script:_mixerFaderBars[9]
                        if ($fbCtrl -and -not $fbCtrl.IsDisposed) {
                            $fbCtrl.Cursor = [System.Windows.Forms.Cursors]::No
                        }
                    }
                    return
                }
                $bt.IsOn = -not $bt.IsOn
                $ii = $bt.Index
                if ($bt.IsOn) {
                    # Turn ON: bright color, fader to 0 dB (linear 0.75)
                    $bSr.BackColor = $bt.ColorBright
                    $bSr.ForeColor = [System.Drawing.Color]::White
                    $linearVal = [single]0.75   # 0 dB on X-Air curve
                    if ($ii -lt 9) {
                        XR-WriteFaderPosition ($ii + 1) $linearVal
                        $fbCtrl = $script:_mixerFaderBars[$ii]
                        if ($fbCtrl -and -not $fbCtrl.IsDisposed) {
                            $fbCtrl.Tag.Value = 750; $fbCtrl.Invalidate()
                        }
                        $fl = $script:_mixerFaderLabels[$ii]
                        if ($fl -and -not $fl.IsDisposed) { $fl.Text = "0.0dB" }
                    }
                    else {
                        try { XR-SendOSC "/lr/mix/fader" $linearVal } catch {}
                        $fbCtrl = $script:_mixerFaderBars[9]
                        if ($fbCtrl -and -not $fbCtrl.IsDisposed) {
                            $fbCtrl.Tag.Value = 750; $fbCtrl.Invalidate()
                        }
                        $fl = $script:_mixerFaderLabels[9]
                        if ($fl -and -not $fl.IsDisposed) { $fl.Text = "0.0dB" }
                    }
                }
                else {
                    # Turn OFF: dim color, fader to -inf (linear 0.0)
                    $bSr.BackColor = $bt.ColorDim
                    $bSr.ForeColor = [System.Drawing.Color]::FromArgb(160, 160, 160)
                    $linearVal = [single]0.0
                    if ($ii -lt 9) {
                        XR-WriteFaderPosition ($ii + 1) $linearVal
                        $fbCtrl = $script:_mixerFaderBars[$ii]
                        if ($fbCtrl -and -not $fbCtrl.IsDisposed) {
                            $fbCtrl.Tag.Value = 0; $fbCtrl.Invalidate()
                        }
                        $fl = $script:_mixerFaderLabels[$ii]
                        if ($fl -and -not $fl.IsDisposed) { $fl.Text = "-inf" }
                    }
                    else {
                        try { XR-SendOSC "/lr/mix/fader" $linearVal } catch {}
                        $fbCtrl = $script:_mixerFaderBars[9]
                        if ($fbCtrl -and -not $fbCtrl.IsDisposed) {
                            $fbCtrl.Tag.Value = 0; $fbCtrl.Invalidate()
                        }
                        $fl = $script:_mixerFaderLabels[9]
                        if ($fl -and -not $fl.IsDisposed) { $fl.Text = "-inf" }
                    }
                }
            })
        $btnBot1.Add_MouseDown({
                param($bSr, $bEv)
                if (-not $bSr.Tag.IsM) { return }
                if ($bEv.Button -eq [System.Windows.Forms.MouseButtons]::Right) {
                    $script:_masterFaderLocked = $false
                    $bt = $bSr.Tag
                    $bSr.BackColor = $bt.ColorBright
                    $bSr.ForeColor = [System.Drawing.Color]::White
                    $bSr.Text = "OPEN"
                    $fbCtrl = $script:_mixerFaderBars[9]
                    if ($fbCtrl -and -not $fbCtrl.IsDisposed) {
                        $fbCtrl.Cursor = [System.Windows.Forms.Cursors]::SizeNS
                    }
                }
            })
        $btnBot1.Add_Paint({
                param($bSr, $pe)
                $g = $pe.Graphics
                $rc = $bSr.ClientRectangle
                if ($rc.Width -le 0 -or $rc.Height -le 0) { return }
                $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
                $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit
                $base = $bSr.BackColor
                $topC = [System.Drawing.Color]::FromArgb(
                    [Math]::Min(255, $base.R + 70), [Math]::Min(255, $base.G + 70), [Math]::Min(255, $base.B + 70))
                $botC = [System.Drawing.Color]::FromArgb(
                    [Math]::Max(0, $base.R - 35), [Math]::Max(0, $base.G - 35), [Math]::Max(0, $base.B - 35))
                $lgb = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
                    $rc, $topC, $botC, [System.Drawing.Drawing2D.LinearGradientMode]::Vertical)
                $g.FillRectangle($lgb, $rc); $lgb.Dispose()
                $sH = [Math]::Max(1, [Math]::Min($rc.Height - 1, [int]($rc.Height * 0.42)))
                $sR = [System.Drawing.Rectangle]::new(0, 0, $rc.Width, $sH)
                $shin = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
                    $sR,
                    [System.Drawing.Color]::FromArgb(80, 255, 255, 255),
                    [System.Drawing.Color]::FromArgb(0, 255, 255, 255),
                    [System.Drawing.Drawing2D.LinearGradientMode]::Vertical)
                $g.FillRectangle($shin, $sR); $shin.Dispose()
                $pen2 = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(50, 50, 50), 1)
                $g.DrawRectangle($pen2, 0, 0, $rc.Width - 1, $rc.Height - 1); $pen2.Dispose()
                $sf2 = New-Object System.Drawing.StringFormat
                $sf2.Alignment = [System.Drawing.StringAlignment]::Center
                $sf2.LineAlignment = [System.Drawing.StringAlignment]::Center
                $sb3 = New-Object System.Drawing.SolidBrush($bSr.ForeColor)
                $g.DrawString($bSr.Text, $bSr.Font, $sb3,
                    [System.Drawing.RectangleF]::new(0, 0, $rc.Width, $rc.Height), $sf2)
                $sb3.Dispose(); $sf2.Dispose()
            })
        $pSt.Controls.Add($btnBot1)
        $script:_mixerOnBtns[$i] = $btnBot1

        # --- M-Mute momentary button (was FX/Mute) ---
        # Hold to mute the channel via OSC /ch/NN/mix/on 0; release to unmute (on=1)
        $mmBtnColorBright = if ($savedRoleColor -and $colorMap.Contains($savedRoleColor)) {
            $colorMap[$savedRoleColor]
        }
        else {
            [System.Drawing.Color]::FromArgb(30, 100, 200)
        }
        $mmBtnColorDim = [System.Drawing.Color]::FromArgb(
            [int]($mmBtnColorBright.R / 4),
            [int]($mmBtnColorBright.G / 4),
            [int]($mmBtnColorBright.B / 4)
        )
        $btnBot2 = New-Object System.Windows.Forms.Button
        $btnBot2.Size = [System.Drawing.Size]::new(($sw - 6), $BTN_H)
        $btnBot2.Location = [System.Drawing.Point]::new(3, ($FADER_TOP + $FADER_H + $BTN_H + 6))
        $btnBot2.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
        $btnBot2.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(80, 80, 80)
        $btnBot2.FlatAppearance.BorderSize = 0
        $btnBot2.BackColor = $mmBtnColorDim
        $btnBot2.ForeColor = [System.Drawing.Color]::FromArgb(160, 160, 160)
        $btnBot2.Font = New-Object System.Drawing.Font("Segoe UI", 7.5, [System.Drawing.FontStyle]::Bold)
        $btnBot2.Text = "M-Mute"
        $btnBot2.Tag = @{
            Index       = $i
            ColorBright = $mmBtnColorBright
            ColorDim    = $mmBtnColorDim
        }
        $btnBot2.Add_MouseDown({
                param($bSr, $bEv)
                if ($bEv.Button -ne [System.Windows.Forms.MouseButtons]::Left) { return }
                $bt = $bSr.Tag
                $ii = $bt.Index
                # Bright color = active / muting
                $bSr.BackColor = $bt.ColorBright
                $bSr.ForeColor = [System.Drawing.Color]::White
                # Send mute: /ch/NN/mix/on = 0  (or /lr/mix/on = 0 for master)
                if ($ii -lt 9) {
                    try { XR-SendOSC ("/ch/{0:D2}/mix/on" -f ($ii + 1)) ([int]0) } catch {}
                }
                else {
                    try { XR-SendOSC "/lr/mix/on" ([int]0) } catch {}
                }
            })
        $btnBot2.Add_MouseUp({
                param($bSr, $bEv)
                if ($bEv.Button -ne [System.Windows.Forms.MouseButtons]::Left) { return }
                $bt = $bSr.Tag
                $ii = $bt.Index
                # Dim color = inactive / unmuted
                $bSr.BackColor = $bt.ColorDim
                $bSr.ForeColor = [System.Drawing.Color]::FromArgb(160, 160, 160)
                # Send unmute: /ch/NN/mix/on = 1  (or /lr/mix/on = 1 for master)
                if ($ii -lt 9) {
                    try { XR-SendOSC ("/ch/{0:D2}/mix/on" -f ($ii + 1)) ([int]1) } catch {}
                }
                else {
                    try { XR-SendOSC "/lr/mix/on" ([int]1) } catch {}
                }
            })
        # Safety: if mouse leaves while held, unmute so channel doesn't stay muted
        $btnBot2.Add_MouseLeave({
                param($bSr, $bEv)
                $bt = $bSr.Tag
                # Only restore if button is currently in bright (active/muted) state
                if ($bSr.BackColor.R -eq $bt.ColorBright.R -and
                    $bSr.BackColor.G -eq $bt.ColorBright.G -and
                    $bSr.BackColor.B -eq $bt.ColorBright.B) {
                    $ii = $bt.Index
                    $bSr.BackColor = $bt.ColorDim
                    $bSr.ForeColor = [System.Drawing.Color]::FromArgb(160, 160, 160)
                    if ($ii -lt 9) {
                        try { XR-SendOSC ("/ch/{0:D2}/mix/on" -f ($ii + 1)) ([int]1) } catch {}
                    }
                    else {
                        try { XR-SendOSC "/lr/mix/on" ([int]1) } catch {}
                    }
                }
            })
        $btnBot2.Add_Paint({
                param($bSr, $pe)
                $g = $pe.Graphics
                $rc = $bSr.ClientRectangle
                if ($rc.Width -le 0 -or $rc.Height -le 0) { return }
                $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
                $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit
                $base = $bSr.BackColor
                $topC = [System.Drawing.Color]::FromArgb(
                    [Math]::Min(255, $base.R + 70), [Math]::Min(255, $base.G + 70), [Math]::Min(255, $base.B + 70))
                $botC = [System.Drawing.Color]::FromArgb(
                    [Math]::Max(0, $base.R - 35), [Math]::Max(0, $base.G - 35), [Math]::Max(0, $base.B - 35))
                $lgb = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
                    $rc, $topC, $botC, [System.Drawing.Drawing2D.LinearGradientMode]::Vertical)
                $g.FillRectangle($lgb, $rc); $lgb.Dispose()
                $sH = [Math]::Max(1, [Math]::Min($rc.Height - 1, [int]($rc.Height * 0.42)))
                $sR = [System.Drawing.Rectangle]::new(0, 0, $rc.Width, $sH)
                $shin = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
                    $sR,
                    [System.Drawing.Color]::FromArgb(80, 255, 255, 255),
                    [System.Drawing.Color]::FromArgb(0, 255, 255, 255),
                    [System.Drawing.Drawing2D.LinearGradientMode]::Vertical)
                $g.FillRectangle($shin, $sR); $shin.Dispose()
                $pen2 = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(50, 50, 50), 1)
                $g.DrawRectangle($pen2, 0, 0, $rc.Width - 1, $rc.Height - 1); $pen2.Dispose()
                $sf2 = New-Object System.Drawing.StringFormat
                $sf2.Alignment = [System.Drawing.StringAlignment]::Center
                $sf2.LineAlignment = [System.Drawing.StringAlignment]::Center
                $sb3 = New-Object System.Drawing.SolidBrush($bSr.ForeColor)
                $g.DrawString($bSr.Text, $bSr.Font, $sb3,
                    [System.Drawing.RectangleF]::new(0, 0, $rc.Width, $rc.Height), $sf2)
                $sb3.Dispose(); $sf2.Dispose()
            })
        $pSt.Controls.Add($btnBot2)
        # Store references for pair-connector ovals
        $script:_mixerMuteButtons[$i] = $btnBot2
        $script:_stripRoleColors[$i] = $savedRoleColor
    }

    # ---- Pair connector ovals between adjacent same-color M-Mute buttons ----
    $connDotSize = 16
    $connY = 4 + $FADER_TOP + $FADER_H + $BTN_H + 6 + [int]($BTN_H / 2) - [int]($connDotSize / 2)
    for ($pi = 0; $pi -lt 9; $pi++) {
        $colA = if ($script:_stripRoleColors.Contains($pi)) { $script:_stripRoleColors[$pi] }     else { "" }
        $colB = if ($script:_stripRoleColors.Contains($pi + 1)) { $script:_stripRoleColors[$pi + 1] } else { "" }
        if ([string]::IsNullOrEmpty($colA) -or $colA -ne $colB) { continue }
        # Build a bright version of the shared color (amplify x1.8, cap at 255)
        $rawC = $colorMap[$colA]
        $connColor = [System.Drawing.Color]::FromArgb(
            [int]([Math]::Min(255, $rawC.R * 1.8)),
            [int]([Math]::Min(255, $rawC.G * 1.8)),
            [int]([Math]::Min(255, $rawC.B * 1.8))
        )
        $connX = $MARGIN + ($pi + 1) * $CH_W - [int]($connDotSize / 2)
        $connPnl = New-Object System.Windows.Forms.Panel
        $connPnl.Location = [System.Drawing.Point]::new($connX, $connY)
        $connPnl.Size = [System.Drawing.Size]::new($connDotSize, $connDotSize)
        $connPnl.BackColor = [System.Drawing.Color]::FromArgb(28, 28, 28)
        $connPnl.Cursor = [System.Windows.Forms.Cursors]::Hand
        $connPnl.Tag = @{
            ChA       = $pi
            ChB       = $pi + 1
            ConnColor = $connColor
            Held      = $false
            BtnA      = $script:_mixerMuteButtons[$pi]
            BtnB      = $script:_mixerMuteButtons[$pi + 1]
        }
        $connPnl.Add_Paint({
                param($cs, $ce)
                $ce.Graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
                $br = New-Object System.Drawing.SolidBrush($cs.Tag.ConnColor)
                $ce.Graphics.FillEllipse($br, 1, 1, $cs.Width - 2, $cs.Height - 2)
                $br.Dispose()
            })
        $connPnl.Add_MouseDown({
                param($cs, $ce)
                if ($ce.Button -ne [System.Windows.Forms.MouseButtons]::Left) { return }
                $ct = $cs.Tag
                $ct.Held = $true
                # Light up both M-Mute buttons
                $bA = $ct.BtnA; $bB = $ct.BtnB
                if ($bA -and -not $bA.IsDisposed) { $bA.BackColor = $bA.Tag.ColorBright; $bA.ForeColor = [System.Drawing.Color]::White }
                if ($bB -and -not $bB.IsDisposed) { $bB.BackColor = $bB.Tag.ColorBright; $bB.ForeColor = [System.Drawing.Color]::White }
                try { XR-SendOSC ("/ch/{0:D2}/mix/on" -f ($ct.ChA + 1)) ([int]0) } catch {}
                try { XR-SendOSC ("/ch/{0:D2}/mix/on" -f ($ct.ChB + 1)) ([int]0) } catch {}
            })
        $connPnl.Add_MouseUp({
                param($cs, $ce)
                if ($ce.Button -ne [System.Windows.Forms.MouseButtons]::Left) { return }
                $ct = $cs.Tag
                $ct.Held = $false
                # Dim both M-Mute buttons
                $bA = $ct.BtnA; $bB = $ct.BtnB
                if ($bA -and -not $bA.IsDisposed) { $bA.BackColor = $bA.Tag.ColorDim; $bA.ForeColor = [System.Drawing.Color]::FromArgb(160, 160, 160) }
                if ($bB -and -not $bB.IsDisposed) { $bB.BackColor = $bB.Tag.ColorDim; $bB.ForeColor = [System.Drawing.Color]::FromArgb(160, 160, 160) }
                try { XR-SendOSC ("/ch/{0:D2}/mix/on" -f ($ct.ChA + 1)) ([int]1) } catch {}
                try { XR-SendOSC ("/ch/{0:D2}/mix/on" -f ($ct.ChB + 1)) ([int]1) } catch {}
            })
        $connPnl.Add_MouseLeave({
                param($cs, $ce)
                $ct = $cs.Tag
                if (-not $ct.Held) { return }
                $ct.Held = $false
                # Dim both M-Mute buttons (safety restore)
                $bA = $ct.BtnA; $bB = $ct.BtnB
                if ($bA -and -not $bA.IsDisposed) { $bA.BackColor = $bA.Tag.ColorDim; $bA.ForeColor = [System.Drawing.Color]::FromArgb(160, 160, 160) }
                if ($bB -and -not $bB.IsDisposed) { $bB.BackColor = $bB.Tag.ColorDim; $bB.ForeColor = [System.Drawing.Color]::FromArgb(160, 160, 160) }
                try { XR-SendOSC ("/ch/{0:D2}/mix/on" -f ($ct.ChA + 1)) ([int]1) } catch {}
                try { XR-SendOSC ("/ch/{0:D2}/mix/on" -f ($ct.ChB + 1)) ([int]1) } catch {}
            })
        $frmM.Controls.Add($connPnl)
        $connPnl.BringToFront()
    }

    # ---- dB scale ruler (left side, aligned with faders) ----
    $pRuler = New-Object System.Windows.Forms.Panel
    $pRuler.Location = [System.Drawing.Point]::new(2, $FADER_TOP)
    $pRuler.Size = [System.Drawing.Size]::new(($RULER_W - 2), $FADER_H)
    $pRuler.BackColor = [System.Drawing.Color]::FromArgb(22, 22, 22)
    $pRuler.Tag = $FADER_H
    $pRuler.Add_Paint({
            param($prs, $pre)
            $rH = $prs.Height   # use actual runtime height, same as fader panels
            $gr = $pre.Graphics
            $gr.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::None
            $gr.Clear([System.Drawing.Color]::FromArgb(22, 22, 22))
            $sf = New-Object System.Drawing.Font("Consolas", 6)
            $tp = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(60, 60, 60), 1)
            # Two-segment linear dB scale — 0 dB at 25% from top (matches fader unity)
            # Top 25% = +10 to 0 dB ; Bottom 75% = 0 to -50 dB ; marks every 5 dB
            $dbMarks = @(
                @{ Label = "+10"; dB = 10.0 },
                @{ Label = " +5"; dB = 5.0 },
                @{ Label = "  0"; dB = 0.0 },
                @{ Label = " -5"; dB = -5.0 },
                @{ Label = "-10"; dB = -10.0 },
                @{ Label = "-15"; dB = -15.0 },
                @{ Label = "-20"; dB = -20.0 },
                @{ Label = "-25"; dB = -25.0 },
                @{ Label = "-30"; dB = -30.0 },
                @{ Label = "-35"; dB = -35.0 },
                @{ Label = "-40"; dB = -40.0 },
                @{ Label = "-50"; dB = -50.0 }
            )
            $hH = 34   # must match fader handle height
            foreach ($mk in $dbMarks) {
                $dBval = [double]$mk.dB
                $linFdr = if ($dBval -ge 10.0) { 1.0 } elseif ($dBval -gt 0.0) { 0.75 + ($dBval / 10.0) * 0.25 } elseif ($dBval -gt -50.0) { 0.75 * (1.0 + $dBval / 50.0) } else { 0.0 }
                # Identical formula to fader ruler: align to handle center
                $y = 1 + [int]((1.0 - $linFdr) * ($rH - $hH - 2)) + [int]($hH / 2)
                $isZero = ($mk.Label.Trim() -eq "0")
                $col = if ($isZero) { [System.Drawing.Color]::FromArgb(220, 200, 0) } else { [System.Drawing.Color]::FromArgb(130, 130, 130) }
                $br = New-Object System.Drawing.SolidBrush($col)
                $ly = [Math]::Min($y, $rH - 1)
                $gr.DrawLine($tp, 0, $ly, $prs.Width, $ly)
                $textY = [Math]::Max(0, [Math]::Min($rH - 10, $y - 4))
                $gr.DrawString($mk.Label, $sf, $br, 0, $textY)
                try { $br.Dispose() } catch {}
            }
            try { $sf.Dispose() } catch {}
            try { $tp.Dispose() } catch {}
        })
    # $frmM.Controls.Add($pRuler)   # ruler hidden: does not align with fader strips

    # ---- Role-label inline edit panel (shared overlay, floats over fader strips on right-click) ----
    $rlEditPnlW = 160
    $rlEditPnlH = 80
    $script:_roleLabelEditPnl = New-Object System.Windows.Forms.Panel
    $script:_roleLabelEditPnl.Size = [System.Drawing.Size]::new($rlEditPnlW, $rlEditPnlH)
    $script:_roleLabelEditPnl.BackColor = [System.Drawing.Color]::FromArgb(32, 32, 54)
    $script:_roleLabelEditPnl.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $script:_roleLabelEditPnl.Visible = $false
    $script:_roleLabelEditPnl.Tag = @{ ActiveIdx = -1; SelectedColor = "" }
    # Text box for label name
    $script:_rlEditTB = New-Object System.Windows.Forms.TextBox
    $script:_rlEditTB.Size = [System.Drawing.Size]::new(($rlEditPnlW - 6), 22)
    $script:_rlEditTB.Location = [System.Drawing.Point]::new(3, 3)
    $script:_rlEditTB.BackColor = [System.Drawing.Color]::FromArgb(50, 50, 75)
    $script:_rlEditTB.ForeColor = [System.Drawing.Color]::White
    $script:_rlEditTB.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $script:_rlEditTB.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $script:_roleLabelEditPnl.Controls.Add($script:_rlEditTB)
    # Color swatches row: no-color (dark) + 7 named colors
    $rlColorDefs = @(
        @{ Key = ""; Color = [System.Drawing.Color]::FromArgb(55, 55, 72) }
        @{ Key = "Red"; Color = [System.Drawing.Color]::FromArgb(160, 40, 40) }
        @{ Key = "Blue"; Color = [System.Drawing.Color]::FromArgb(30, 80, 180) }
        @{ Key = "Green"; Color = [System.Drawing.Color]::FromArgb(30, 140, 50) }
        @{ Key = "Yellow"; Color = [System.Drawing.Color]::FromArgb(180, 160, 0) }
        @{ Key = "Magenta"; Color = [System.Drawing.Color]::FromArgb(160, 40, 160) }
        @{ Key = "Cyan"; Color = [System.Drawing.Color]::FromArgb(0, 150, 170) }
        @{ Key = "White"; Color = [System.Drawing.Color]::FromArgb(200, 200, 200) }
    )
    $rlSwSize = 17
    $rlSwStartX = [int](($rlEditPnlW - $rlColorDefs.Count * $rlSwSize) / 2)
    $rlSwY = 30
    foreach ($rlCd in $rlColorDefs) {
        $rlSwatch = New-Object System.Windows.Forms.Panel
        $rlSwatch.Size = [System.Drawing.Size]::new($rlSwSize, $rlSwSize)
        $rlSwatch.Location = [System.Drawing.Point]::new($rlSwStartX, $rlSwY)
        $rlSwatch.BackColor = $rlCd.Color
        $rlSwatch.Cursor = [System.Windows.Forms.Cursors]::Hand
        $rlSwatch.Tag = $rlCd.Key
        $rlSwatch.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
        $rlSwatch.Add_Click({
                param($rsS, $rsE)
                $selK = [string]$rsS.Tag
                $script:_roleLabelEditPnl.Tag.SelectedColor = $selK
                foreach ($rlSw2 in $script:_roleLabelEditPnl.Controls) {
                    if ($rlSw2 -is [System.Windows.Forms.Panel] -and $rlSw2.Tag -is [string]) {
                        $rlSw2.BorderStyle = if ([string]$rlSw2.Tag -eq $selK) {
                            [System.Windows.Forms.BorderStyle]::Fixed3D
                        }
                        else { [System.Windows.Forms.BorderStyle]::FixedSingle }
                    }
                }
            })
        $script:_roleLabelEditPnl.Controls.Add($rlSwatch)
        $rlSwStartX += $rlSwSize
    }
    # Save button
    $rlSaveBtn = New-Object System.Windows.Forms.Button
    $rlSaveBtn.Text = "Save"
    $rlSaveBtn.Size = [System.Drawing.Size]::new(64, 22)
    $rlSaveBtn.Location = [System.Drawing.Point]::new(3, 53)
    $rlSaveBtn.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $rlSaveBtn.BackColor = [System.Drawing.Color]::FromArgb(20, 90, 40)
    $rlSaveBtn.ForeColor = [System.Drawing.Color]::White
    $rlSaveBtn.Font = New-Object System.Drawing.Font("Segoe UI", 8)
    $rlSaveBtn.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(50, 150, 80)
    $rlSaveBtn.Add_Click({
            param($rlSS, $rlSE)
            $rlTag = $script:_roleLabelEditPnl.Tag
            $rlIdx2 = [int]$rlTag.ActiveIdx
            if ($rlIdx2 -lt 0) { return }
            $rlNewText = [string]$script:_rlEditTB.Text
            $rlNewColor = [string]$rlTag.SelectedColor
            # Update the role label control live
            if ($script:_rlEditCtrl -and -not $script:_rlEditCtrl.IsDisposed) {
                $script:_rlEditCtrl.Text = $rlNewText
                $rlCMap = @{
                    "Red"     = [System.Drawing.Color]::FromArgb(160, 40, 40)
                    "Blue"    = [System.Drawing.Color]::FromArgb(30, 80, 180)
                    "Green"   = [System.Drawing.Color]::FromArgb(30, 140, 50)
                    "Yellow"  = [System.Drawing.Color]::FromArgb(180, 160, 0)
                    "Magenta" = [System.Drawing.Color]::FromArgb(160, 40, 160)
                    "Cyan"    = [System.Drawing.Color]::FromArgb(0, 150, 170)
                    "White"   = [System.Drawing.Color]::FromArgb(200, 200, 200)
                }
                if ($rlNewColor -and $rlCMap.Contains($rlNewColor)) {
                    $script:_rlEditCtrl.BackColor = $rlCMap[$rlNewColor]
                    $script:_rlEditCtrl.ForeColor = if ($rlNewColor -eq "Yellow" -or $rlNewColor -eq "White") { [System.Drawing.Color]::Black } else { [System.Drawing.Color]::White }
                }
                else {
                    $script:_rlEditCtrl.BackColor = [System.Drawing.Color]::FromArgb(45, 45, 58)
                    $script:_rlEditCtrl.ForeColor = [System.Drawing.Color]::FromArgb(210, 210, 210)
                }
                $script:_rlEditCtrl.Invalidate()
            }
            # Persist label
            $rlArrL = $script:Cfg.XR.MixerRoleLabels
            if (-not $rlArrL -or $rlArrL.Count -lt 10) { $rlArrL = @("", "", "", "", "", "", "", "", "", "") }
            $rlArrL[$rlIdx2] = $rlNewText
            $script:Cfg.XR.MixerRoleLabels = $rlArrL
            # Persist color
            $rlArrC = $script:Cfg.XR.MixerRoleColors
            if (-not $rlArrC -or $rlArrC.Count -lt 10) { $rlArrC = @("", "", "", "", "", "", "", "", "", "") }
            $rlArrC[$rlIdx2] = $rlNewColor
            $script:Cfg.XR.MixerRoleColors = $rlArrC
            try { Save-Settings | Out-Null } catch {}
            $script:_roleLabelEditPnl.Visible = $false
        })
    # Cancel button
    $rlCancelBtn = New-Object System.Windows.Forms.Button
    $rlCancelBtn.Text = "X"
    $rlCancelBtn.Size = [System.Drawing.Size]::new(32, 22)
    $rlCancelBtn.Location = [System.Drawing.Point]::new(69, 53)
    $rlCancelBtn.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $rlCancelBtn.BackColor = [System.Drawing.Color]::FromArgb(90, 22, 22)
    $rlCancelBtn.ForeColor = [System.Drawing.Color]::White
    $rlCancelBtn.Font = New-Object System.Drawing.Font("Segoe UI", 8)
    $rlCancelBtn.Add_Click({ param($rlCc, $rlCe) $script:_roleLabelEditPnl.Visible = $false })
    $script:_roleLabelEditPnl.Controls.Add($rlSaveBtn)
    $script:_roleLabelEditPnl.Controls.Add($rlCancelBtn)
    $frmM.Controls.Add($script:_roleLabelEditPnl)

    # ---- Snapshot panel (8 configurable buttons) ----
    $spX = $MARGIN + 9 * $CH_W + $MST_W + 6
    $pSnap = New-Object System.Windows.Forms.Panel
    $pSnap.Location = [System.Drawing.Point]::new($spX, 4)
    $pSnap.Size = [System.Drawing.Size]::new(($SNAP_W - 4), $STRIP_H)
    $pSnap.BackColor = [System.Drawing.Color]::FromArgb(26, 26, 44)
    $pSnap.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $frmM.Controls.Add($pSnap)

    $lblSH = New-Object System.Windows.Forms.Label
    $lblSH.Text = "Snapshots"
    $lblSH.Size = [System.Drawing.Size]::new([int][Math]::Round(80 * $sc), 20)
    $lblSH.Location = [System.Drawing.Point]::new(4, 4)
    $lblSH.ForeColor = [System.Drawing.Color]::LightGray
    $lblSH.Font = New-Object System.Drawing.Font("Segoe UI", 8, [System.Drawing.FontStyle]::Bold)
    $lblSH.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $pSnap.Controls.Add($lblSH)

    # Scan button — top-right corner of snapshot panel
    $scanBtnW = [int][Math]::Round(52 * $sc)
    $btnMixScan = New-Object System.Windows.Forms.Button
    $btnMixScan.Text = "Scan"
    $btnMixScan.Size = [System.Drawing.Size]::new($scanBtnW, 20)
    $btnMixScan.Location = [System.Drawing.Point]::new(($SNAP_W - 4 - $scanBtnW - 2), 4)
    $btnMixScan.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $btnMixScan.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(80, 80, 130)
    $btnMixScan.FlatAppearance.BorderSize = 1
    $btnMixScan.BackColor = [System.Drawing.Color]::FromArgb(35, 55, 95)
    $btnMixScan.ForeColor = [System.Drawing.Color]::FromArgb(160, 200, 255)
    $btnMixScan.Font = New-Object System.Drawing.Font("Segoe UI", 7, [System.Drawing.FontStyle]::Bold)
    $pSnap.Controls.Add($btnMixScan)

    # IP label — shows current mixer IP below the header row
    $lblMixIP = New-Object System.Windows.Forms.Label
    $lblMixIP.Text = if (-not [string]::IsNullOrWhiteSpace($script:Cfg.XR.MixerIP)) { $script:Cfg.XR.MixerIP } else { "No IP set" }
    $lblMixIP.Size = [System.Drawing.Size]::new(($SNAP_W - 14), 14)
    $lblMixIP.Location = [System.Drawing.Point]::new(4, 25)
    $lblMixIP.ForeColor = [System.Drawing.Color]::FromArgb(100, 180, 255)
    $lblMixIP.Font = New-Object System.Drawing.Font("Segoe UI", 7)
    $lblMixIP.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $pSnap.Controls.Add($lblMixIP)

    # Scan button click — runs XR-ScanForMixer (saved IP + broadcast only) and updates IP
    $btnMixScan.Add_Click({
            if ($script:IsScanning) { return }   # ignore if already scanning
            $script:IsScanning = $true
            $script:ScanCancelToken = [ref]$false
            try {
                if ($btnMixScan -and -not $btnMixScan.IsDisposed) {
                    $btnMixScan.Text = "..."
                    $btnMixScan.BackColor = [System.Drawing.Color]::FromArgb(120, 80, 0)
                    $btnMixScan.ForeColor = [System.Drawing.Color]::Orange
                } 
            }
            catch {}
            try {
                if ($lblMixIP -and -not $lblMixIP.IsDisposed) {
                    $lblMixIP.Text = "Scanning..."
                    $lblMixIP.ForeColor = [System.Drawing.Color]::Orange
                } 
            }
            catch {}
            try { if ($frmM -and -not $frmM.IsDisposed) { $frmM.Refresh() } } catch {}
            try {
                $mixProgressCb = {
                    param($curIP, $pct)
                    try {
                        if ($lblMixIP -and -not $lblMixIP.IsDisposed) {
                            $lblMixIP.Text = "$curIP ($pct%)"
                        } 
                    }
                    catch {}
                    [System.Windows.Forms.Application]::DoEvents()
                }
                $foundIP = XR-ScanForMixer -ProgressCallback $mixProgressCb -CancelToken $script:ScanCancelToken
                if ($foundIP) {
                    $script:Cfg.XR.MixerIP = $foundIP
                    Save-Settings | Out-Null
                    try {
                        if ($lblMixIP -and -not $lblMixIP.IsDisposed) {
                            $lblMixIP.Text = $foundIP
                            $lblMixIP.ForeColor = [System.Drawing.Color]::FromArgb(80, 220, 80)
                        } 
                    }
                    catch {}
                    try { if ($frmM -and -not $frmM.IsDisposed) { $frmM.Text = "XR Mixer Panel  |  $foundIP  |  XR: Online ✓" } } catch {}
                }
                else {
                    try {
                        if ($lblMixIP -and -not $lblMixIP.IsDisposed) {
                            $lblMixIP.Text = "Not found — retrying..."
                            $lblMixIP.ForeColor = [System.Drawing.Color]::FromArgb(220, 80, 80)
                        } 
                    }
                    catch {}
                    # Also start the broadcast retry timer so the panel updates automatically
                    if (-not $script:_xrBroadcastRetryTimer -and $script:Cfg.XR.XRMixerEnabled) {
                        $script:_xrRetryBusy = $false
                        $script:_xrRetryCount = 0
                        $script:_xrBroadcastRetryTimer = New-Object System.Windows.Forms.Timer
                        $script:_xrBroadcastRetryTimer.Interval = 2000
                        $script:_xrBroadcastRetryTimer.Add_Tick({
                                if (-not $script:Cfg.XR.XRMixerEnabled) { return }
                                if ($script:IsScanning) { return }
                                if ($script:_xrRetryBusy) { return }
                                $script:_xrRetryBusy = $true
                                $script:_xrRetryCount++
                                try {
                                    $retryIP = Find-XAirByBroadcast -TimeoutMs 1500 -CancelToken ([ref]$false)
                                    if ($retryIP) {
                                        $script:Cfg.XR.MixerIP = $retryIP
                                        Save-Settings
                                        Log "Broadcast retry: Found X-Air at $retryIP — saved"
                                        if ($script:sbLeft -and -not $script:sbLeft.IsDisposed) {
                                            $script:sbLeft.Text = "Broadcast retry: Found X-Air at $retryIP"
                                        }
                                        $script:_xrBroadcastRetryTimer.Stop()
                                        $script:_xrBroadcastRetryTimer.Dispose()
                                        $script:_xrBroadcastRetryTimer = $null
                                    }
                                    else {
                                        if ($script:_xrRetryCount % 20 -eq 1) {
                                            Log "Broadcast retry: no reply (attempt $($script:_xrRetryCount))"
                                        }
                                    }
                                }
                                finally { $script:_xrRetryBusy = $false }
                            })
                        $script:_xrBroadcastRetryTimer.Start()
                        Log 'Scan: mixer not found — broadcast retry started (every 2s)'
                    }
                }
            }
            catch {
                try {
                    if ($lblMixIP -and -not $lblMixIP.IsDisposed) {
                        $lblMixIP.Text = "Scan error"
                        $lblMixIP.ForeColor = [System.Drawing.Color]::Red
                    } 
                }
                catch {}
                Log "Mixer panel scan error: $_"
            }
            finally {
                $script:IsScanning = $false
                try {
                    if ($btnMixScan -and -not $btnMixScan.IsDisposed) {
                        $btnMixScan.Text = "Scan"
                        $btnMixScan.BackColor = [System.Drawing.Color]::FromArgb(35, 55, 95)
                        $btnMixScan.ForeColor = [System.Drawing.Color]::FromArgb(160, 200, 255)
                    } 
                }
                catch {}
            }
        })

    # Color palette (same as role labels)
    $script:_snapColorMap = @{
        "Red"     = [System.Drawing.Color]::FromArgb(160, 40, 40)
        "Blue"    = [System.Drawing.Color]::FromArgb(30, 80, 180)
        "Green"   = [System.Drawing.Color]::FromArgb(30, 140, 50)
        "Yellow"  = [System.Drawing.Color]::FromArgb(180, 160, 0)
        "Magenta" = [System.Drawing.Color]::FromArgb(160, 40, 160)
        "Cyan"    = [System.Drawing.Color]::FromArgb(0, 150, 170)
        "White"   = [System.Drawing.Color]::FromArgb(200, 200, 200)
    }
    $script:_snapColorNames = @("Red", "Blue", "Green", "Yellow", "Magenta", "Cyan", "White")

    $snapBtnW = $SNAP_W - 16                                         # 134 px
    $snapBtnH = [Math]::Max(34, [int](($STRIP_H - 44) / 8))          # evenly fills height (adjusted for IP row)
    $snapBtnAreaH = $snapBtnH - 4                                        # rendered button height

    # Build 8 snap buttons (gray by default, colored + titled after config)
    $script:_snapBtns = @()
    for ($si = 0; $si -lt 8; $si++) {
        $bY = 42 + $si * $snapBtnH
        $sColor = $snapColors[$si]
        $sTitle = $snapLabels[$si]
        $sNum = $snapNums[$si]

        if ($sColor -and $script:_snapColorMap.Contains($sColor)) {
            $rawSC = $script:_snapColorMap[$sColor]
            $sBg = [System.Drawing.Color]::FromArgb(
                [int]($rawSC.R / 4), [int]($rawSC.G / 4), [int]($rawSC.B / 4)
            )
        }
        else {
            $sBg = [System.Drawing.Color]::FromArgb(45, 45, 45)
        }

        $sBtn = New-Object System.Windows.Forms.Button
        $sBtn.Size = [System.Drawing.Size]::new($snapBtnW, $snapBtnAreaH)
        $sBtn.Location = [System.Drawing.Point]::new(6, ($bY + 2))
        $sBtn.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
        $sBtn.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(70, 70, 90)
        $sBtn.FlatAppearance.BorderSize = 0
        $sBtn.BackColor = $sBg
        $sBtn.ForeColor = [System.Drawing.Color]::White
        $sBtn.Text = $sTitle
        $sBtn.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
        $sBtn.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
        $sBtn.Tag = @{ Index = $si; Title = $sTitle; SnapNum = $sNum; Color = $sColor }
        $sBtn.Add_Paint({
                param($bSr, $pe)
                $g = $pe.Graphics
                $rc = $bSr.ClientRectangle
                if ($rc.Width -le 0 -or $rc.Height -le 0) { return }
                $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
                $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit
                $base = $bSr.BackColor
                $topC = [System.Drawing.Color]::FromArgb(
                    [Math]::Min(255, $base.R + 70), [Math]::Min(255, $base.G + 70), [Math]::Min(255, $base.B + 70))
                $botC = [System.Drawing.Color]::FromArgb(
                    [Math]::Max(0, $base.R - 35), [Math]::Max(0, $base.G - 35), [Math]::Max(0, $base.B - 35))
                $lgb = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
                    $rc, $topC, $botC, [System.Drawing.Drawing2D.LinearGradientMode]::Vertical)
                $g.FillRectangle($lgb, $rc); $lgb.Dispose()
                $sH = [Math]::Max(1, [Math]::Min($rc.Height - 1, [int]($rc.Height * 0.42)))
                $sR = [System.Drawing.Rectangle]::new(0, 0, $rc.Width, $sH)
                $shin = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
                    $sR,
                    [System.Drawing.Color]::FromArgb(80, 255, 255, 255),
                    [System.Drawing.Color]::FromArgb(0, 255, 255, 255),
                    [System.Drawing.Drawing2D.LinearGradientMode]::Vertical)
                $g.FillRectangle($shin, $sR); $shin.Dispose()
                $pen2 = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(50, 50, 50), 1)
                $g.DrawRectangle($pen2, 0, 0, $rc.Width - 1, $rc.Height - 1); $pen2.Dispose()
                $sf2 = New-Object System.Drawing.StringFormat
                $sf2.Alignment = [System.Drawing.StringAlignment]::Center
                $sf2.LineAlignment = [System.Drawing.StringAlignment]::Center
                $sb3 = New-Object System.Drawing.SolidBrush($bSr.ForeColor)
                $g.DrawString($bSr.Text, $bSr.Font, $sb3,
                    [System.Drawing.RectangleF]::new(0, 0, $rc.Width, $rc.Height), $sf2)
                $sb3.Dispose(); $sf2.Dispose()
            })
        $script:_snapBtns += $sBtn
        $pSnap.Controls.Add($sBtn)
    }

    # ---- Shared edit overlay (shown on 2-sec right-click hold) ----
    $snapEditH = 106
    $script:_snapEditPnl = New-Object System.Windows.Forms.Panel
    $script:_snapEditPnl.Size = [System.Drawing.Size]::new($snapBtnW, $snapEditH)
    $script:_snapEditPnl.BackColor = [System.Drawing.Color]::FromArgb(32, 32, 54)
    $script:_snapEditPnl.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $script:_snapEditPnl.Visible = $false
    $script:_snapEditPnl.Tag = @{ ActiveIndex = -1; SelectedColor = "" }

    # A – Title text box
    $script:_snapTitleTB = New-Object System.Windows.Forms.TextBox
    $script:_snapTitleTB.Size = [System.Drawing.Size]::new(($snapBtnW - 4), 20)
    $script:_snapTitleTB.Location = [System.Drawing.Point]::new(2, 3)
    $script:_snapTitleTB.BackColor = [System.Drawing.Color]::FromArgb(50, 50, 75)
    $script:_snapTitleTB.ForeColor = [System.Drawing.Color]::White
    $script:_snapTitleTB.Font = New-Object System.Drawing.Font("Segoe UI", 8)
    $script:_snapTitleTB.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $script:_snapEditPnl.Controls.Add($script:_snapTitleTB)

    # B – Snapshot number selector
    $script:_snapNumUD = New-Object System.Windows.Forms.NumericUpDown
    $script:_snapNumUD.Minimum = 1
    $script:_snapNumUD.Maximum = 10
    $script:_snapNumUD.Size = [System.Drawing.Size]::new(56, 20)
    $script:_snapNumUD.Location = [System.Drawing.Point]::new(2, 27)
    $script:_snapNumUD.BackColor = [System.Drawing.Color]::FromArgb(48, 48, 70)
    $script:_snapNumUD.ForeColor = [System.Drawing.Color]::White
    $script:_snapNumUD.Font = New-Object System.Drawing.Font("Segoe UI", 8)
    $script:_snapEditPnl.Controls.Add($script:_snapNumUD)

    $snapNumLbl = New-Object System.Windows.Forms.Label
    $snapNumLbl.Text = "Snapshot #"
    $snapNumLbl.Size = [System.Drawing.Size]::new(($snapBtnW - 62), 20)
    $snapNumLbl.Location = [System.Drawing.Point]::new(60, 29)
    $snapNumLbl.ForeColor = [System.Drawing.Color]::LightGray
    $snapNumLbl.Font = New-Object System.Drawing.Font("Segoe UI", 7.5)
    $script:_snapEditPnl.Controls.Add($snapNumLbl)

    # C – Color swatches (7, centered)
    $snapSwSize = 17
    $snapSwStartX = [int](($snapBtnW - 7 * $snapSwSize) / 2)
    $snapSwY = 52
    foreach ($snapCN in $script:_snapColorNames) {
        $swP = New-Object System.Windows.Forms.Panel
        $swP.Size = [System.Drawing.Size]::new($snapSwSize, $snapSwSize)
        $swP.Location = [System.Drawing.Point]::new($snapSwStartX, $snapSwY)
        $swP.BackColor = $script:_snapColorMap[$snapCN]
        $swP.Cursor = [System.Windows.Forms.Cursors]::Hand
        $swP.Tag = $snapCN
        $swP.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
        $swP.Add_Click({
                param($sws, $swe)
                $selC = [string]$sws.Tag
                $script:_snapEditPnl.Tag.SelectedColor = $selC
                foreach ($c2 in $script:_snapEditPnl.Controls) {
                    if ($c2 -is [System.Windows.Forms.Panel] -and
                        $c2.Tag -is [string] -and
                        $snapColorNames -contains [string]$c2.Tag) {
                        $c2.BorderStyle = if ([string]$c2.Tag -eq $selC) {
                            [System.Windows.Forms.BorderStyle]::Fixed3D
                        }
                        else {
                            [System.Windows.Forms.BorderStyle]::FixedSingle
                        }
                    }
                }
            })
        $script:_snapEditPnl.Controls.Add($swP)
        $snapSwStartX += $snapSwSize
    }

    # Save button
    $snapSaveBtn = New-Object System.Windows.Forms.Button
    $snapSaveBtn.Text = "Save"
    $snapSaveBtn.Size = [System.Drawing.Size]::new(64, 22)
    $snapSaveBtn.Location = [System.Drawing.Point]::new(2, 76)
    $snapSaveBtn.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $snapSaveBtn.BackColor = [System.Drawing.Color]::FromArgb(20, 90, 40)
    $snapSaveBtn.ForeColor = [System.Drawing.Color]::White
    $snapSaveBtn.Font = New-Object System.Drawing.Font("Segoe UI", 8)
    $snapSaveBtn.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(50, 150, 80)
    $snapSaveBtn.Add_Click({
            param($ss, $se)
            $et = $script:_snapEditPnl.Tag
            $idx = [int]$et.ActiveIndex
            if ($idx -lt 0) { return }
            $newTitle = [string]$script:_snapTitleTB.Text
            $newNum = [int]$script:_snapNumUD.Value
            $newColor = [string]$et.SelectedColor

            # Persist to config
            $arrL = $script:Cfg.XR.MixerSnapLabels
            $arrN = $script:Cfg.XR.MixerSnapNumbers
            $arrC = $script:Cfg.XR.MixerSnapColors
            if (-not $arrL -or $arrL.Count -lt 8) { $arrL = @("", "", "", "", "", "", "", "") }
            if (-not $arrN -or $arrN.Count -lt 8) { $arrN = @(1, 2, 3, 4, 5, 6, 7, 8) }
            if (-not $arrC -or $arrC.Count -lt 8) { $arrC = @("", "", "", "", "", "", "", "") }
            $arrL[$idx] = $newTitle
            $arrN[$idx] = $newNum
            $arrC[$idx] = $newColor
            $script:Cfg.XR.MixerSnapLabels = $arrL
            $script:Cfg.XR.MixerSnapNumbers = $arrN
            $script:Cfg.XR.MixerSnapColors = $arrC
            try { Save-Settings | Out-Null } catch {}

            # Update button appearance
            $btn = $script:_snapBtns[$idx]
            $btn.Tag.Title = $newTitle
            $btn.Tag.SnapNum = $newNum
            $btn.Tag.Color = $newColor
            $btn.Text = $newTitle
            if ($newColor -and $script:_snapColorMap.Contains($newColor)) {
                $rawSX = $script:_snapColorMap[$newColor]
                $btn.BackColor = [System.Drawing.Color]::FromArgb(
                    [int]($rawSX.R / 4), [int]($rawSX.G / 4), [int]($rawSX.B / 4)
                )
            }
            else {
                $btn.BackColor = [System.Drawing.Color]::FromArgb(45, 45, 45)
            }
            $btn.ForeColor = [System.Drawing.Color]::White
            $btn.Invalidate()
            $script:_snapEditPnl.Visible = $false
        })

    # Cancel button
    $snapCancelBtn = New-Object System.Windows.Forms.Button
    $snapCancelBtn.Text = "X"
    $snapCancelBtn.Size = [System.Drawing.Size]::new(32, 22)
    $snapCancelBtn.Location = [System.Drawing.Point]::new(68, 76)
    $snapCancelBtn.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $snapCancelBtn.BackColor = [System.Drawing.Color]::FromArgb(90, 22, 22)
    $snapCancelBtn.ForeColor = [System.Drawing.Color]::White
    $snapCancelBtn.Font = New-Object System.Drawing.Font("Segoe UI", 8)
    $snapCancelBtn.Add_Click({ param($sc, $se) $script:_snapEditPnl.Visible = $false })

    $script:_snapEditPnl.Controls.Add($snapSaveBtn)
    $script:_snapEditPnl.Controls.Add($snapCancelBtn)
    $pSnap.Controls.Add($script:_snapEditPnl)

    # Right-click hold (2 s) timer → open edit overlay
    $script:_snapHoldTimer = New-Object System.Windows.Forms.Timer
    $script:_snapHoldTimer.Interval = 2000
    $script:_snapHoldTimer.Tag = -1   # index of button being held
    $script:_snapHoldTimer.Add_Tick({
            $script:_snapHoldTimer.Stop()
            $idx = [int]$script:_snapHoldTimer.Tag
            if ($idx -lt 0) { return }

            $btn = $script:_snapBtns[$idx]
            $editY = $btn.Location.Y - 2
            $maxY = $script:_snapEditPnl.Parent.Height - $script:_snapEditPnl.Height - 4
            if ($editY -gt $maxY) { $editY = $maxY }
            if ($editY -lt 28) { $editY = 28 }
            $script:_snapEditPnl.Location = [System.Drawing.Point]::new($btn.Location.X, $editY)

            # Populate controls from current button state
            $script:_snapEditPnl.Tag.ActiveIndex = $idx
            $script:_snapEditPnl.Tag.SelectedColor = [string]$btn.Tag.Color
            $script:_snapTitleTB.Text = [string]$btn.Tag.Title
            $script:_snapNumUD.Value = [Math]::Max(1, [Math]::Min(10, [int]$btn.Tag.SnapNum))

            # Highlight matching swatch
            $curC = [string]$btn.Tag.Color
            foreach ($c2 in $script:_snapEditPnl.Controls) {
                if ($c2 -is [System.Windows.Forms.Panel] -and
                    $c2.Tag -is [string] -and
                    $script:_snapColorNames -contains [string]$c2.Tag) {
                    $c2.BorderStyle = if ([string]$c2.Tag -eq $curC) {
                        [System.Windows.Forms.BorderStyle]::Fixed3D
                    }
                    else {
                        [System.Windows.Forms.BorderStyle]::FixedSingle
                    }
                }
            }

            $script:_snapEditPnl.Visible = $true
            $script:_snapEditPnl.BringToFront()
            $script:_snapTitleTB.Focus()
        })

    # Attach mouse handlers to all 8 snap buttons
    foreach ($sBtn in $script:_snapBtns) {
        $sBtn.Add_MouseDown({
                param($bs, $be)
                if ($be.Button -ne [System.Windows.Forms.MouseButtons]::Right) { return }
                # Toggle: right-click while overlay open → close it
                if ($script:_snapEditPnl.Visible) { $script:_snapEditPnl.Visible = $false; return }
                $script:_snapHoldTimer.Tag = $bs.Tag.Index
                $script:_snapHoldTimer.Start()
            })
        $sBtn.Add_MouseUp({
                param($bs, $be)
                if ($be.Button -eq [System.Windows.Forms.MouseButtons]::Right) {
                    $script:_snapHoldTimer.Stop(); return
                }
                # Left-click = load snapshot (only if a title is configured)
                if ($be.Button -ne [System.Windows.Forms.MouseButtons]::Left) { return }
                if ($script:_snapEditPnl.Visible) { return }
                $t = $bs.Tag
                if ([string]::IsNullOrEmpty($t.Title)) { return }
                # Auto Mode guard: button index 7 (snap #8) requires Auto Mode enabled in settings
                if ($t.Index -eq 7 -and -not $script:Cfg.XR.AutoModeEnabled) {
                    [System.Windows.Forms.MessageBox]::Show(
                        "Auto Mode is not enabled.`n`nTo use this snapshot, please:`n  1. Enable 'Enable Auto Mode' in XR Mixer Settings`n  2. Make sure Snapshot 8 on your X-Air mixer is set up for Auto Mode",
                        "Auto Mode Not Enabled",
                        [System.Windows.Forms.MessageBoxButtons]::OK,
                        [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
                    return
                }
                XR-LoadSnapshot $t.SnapNum
                Log "Mixer Panel: Snapshot $($t.SnapNum) ('$($t.Title)') loaded"
            })
        $sBtn.Add_MouseLeave({
                param($bs, $be)
                $script:_snapHoldTimer.Stop()
            })
    }

    # ---- Meter + level refresh timer (100 ms) ----
    $script:_mixerPanelTimer = New-Object System.Windows.Forms.Timer
    $script:_mixerPanelTimer.Interval = 100
    $script:_mixerPanelTimer.Add_Tick({
            try {
                if (-not $script:_mixerPanel -or $script:_mixerPanel.IsDisposed) {
                    $script:_mixerPanelTimer.Stop(); return
                }

                # Invalidate all meter panels so Paint handlers redraw
                for ($ti = 0; $ti -lt 10; $ti++) {
                    $mp = $script:_mixerMeterPanels[$ti]
                    if ($mp -and -not $mp.IsDisposed) { $mp.Invalidate() }
                }

                # Update input channel level labels
                for ($ti = 0; $ti -lt 9; $ti++) {
                    $dBt = try { [double](XR-GetMeterLevel ($ti + 1)) } catch { -90.0 }
                    $ll = $script:_mixerLevelLabels[$ti]
                    if ($ll -and -not $ll.IsDisposed) {
                        $txt = if ($dBt -le -89.0) { "-inf" } else { ("{0:F0}" -f $dBt) + "dB" }
                        if ($ll.Text -ne $txt) { $ll.Text = $txt }
                    }
                }

                # ---- Limiter: fire when fader is between -0.5 dB and +10 dB and input exceeds threshold ----
                if ($script:Cfg.XR.LimiterEnabled) {
                    $limThreshDB = [double]$script:Cfg.XR.LimiterThresholdDB
                    $limSnapMS = [int]$script:Cfg.XR.LimiterSnapBackSec * 1000
                    $limNow = Get-Date
                    for ($li = 0; $li -lt 9; $li++) {
                        $limCh = $li + 1
                        # Skip channel if still in cooldown
                        $limCool = $script:_limiterChCoolUntil[$limCh]
                        if ($null -ne $limCool -and $limNow -lt $limCool) { continue }
                        # Get current fader position from cache
                        $limLinear = if ($script:_cachedFaders -and $script:_cachedFaders.Contains($limCh)) { [double]$script:_cachedFaders[$limCh] } else { 0.75 }
                        $limFaderDB = [double](ConvertTo-Decibels $limLinear)
                        # Only act if fader is between -0.5 dB and +10 dB,
                        # UNLESS a snap-back is already pending (limiter previously fired and
                        # reduced the fader to -3 dB — that value is below -0.5 dB so without
                        # this exception the snap-back elseif block would never be reached)
                        if (($limFaderDB -lt -0.5 -or $limFaderDB -gt 10.0) -and -not $script:_limiterPreValue.Contains($limCh)) { continue }
                        # Check pre-fader input level
                        $limLevelDB = try { [double](XR-GetMeterLevel $limCh) } catch { -90.0 }
                        if ($limLevelDB -gt $limThreshDB) {
                            # Store pre-reduction fader value the first time limiter fires on this channel
                            if (-not $script:_limiterPreValue.Contains($limCh)) {
                                $script:_limiterPreValue[$limCh] = $limLinear
                            }
                            $script:_limiterBelowSince.Remove($limCh)
                            $limNewLinear = ConvertTo-LinearFader -3.0
                            XR-WriteFaderPosition $limCh $limNewLinear
                            # Update visual
                            $liFb = $script:_mixerFaderBars[$li]
                            if ($liFb -and -not $liFb.IsDisposed) {
                                $liFb.Tag.Value = [int]($limNewLinear * 1000); $liFb.Invalidate()
                            }
                            $liFl = $script:_mixerFaderLabels[$li]
                            if ($liFl -and -not $liFl.IsDisposed) { $liFl.Text = "-3.0dB" }
                            # 3 second cooldown before firing again on same channel
                            $script:_limiterChCoolUntil[$limCh] = $limNow.AddMilliseconds(3000)
                            Log "Limiter: Ch$limCh input $([Math]::Round($limLevelDB,1)) dB exceeded $limThreshDB dB — fader reduced to -3 dB"
                        }
                        elseif ($script:_limiterPreValue.Contains($limCh)) {
                            # Level is below threshold and we have a stored pre-reduction value — track snap-back timer
                            if (-not $script:_limiterBelowSince.Contains($limCh)) {
                                $script:_limiterBelowSince[$limCh] = $limNow
                            }
                            elseif (($limNow - $script:_limiterBelowSince[$limCh]).TotalMilliseconds -ge $limSnapMS) {
                                # Snap fader back to original value
                                $limRestoreLinear = [double]$script:_limiterPreValue[$limCh]
                                XR-WriteFaderPosition $limCh $limRestoreLinear
                                $limRestoreDB = [Math]::Round([double](ConvertTo-Decibels $limRestoreLinear), 1)
                                # Update visual
                                $liFb = $script:_mixerFaderBars[$li]
                                if ($liFb -and -not $liFb.IsDisposed) {
                                    $liFb.Tag.Value = [int]($limRestoreLinear * 1000); $liFb.Invalidate()
                                }
                                $liFl = $script:_mixerFaderLabels[$li]
                                if ($liFl -and -not $liFl.IsDisposed) { $liFl.Text = "${limRestoreDB}dB" }
                                $script:_limiterPreValue.Remove($limCh)
                                $script:_limiterBelowSince.Remove($limCh)
                                Log "Limiter: Ch$limCh level below threshold for $($script:Cfg.XR.LimiterSnapBackSec)s — fader restored to ${limRestoreDB} dB"
                            }
                        }
                    }
                }

                # Update master level label — same source as bar graph: peak of all 9 input channels
                $ll9 = $script:_mixerLevelLabels[9]
                if ($ll9 -and -not $ll9.IsDisposed) {
                    $mDB9 = -90.0
                    for ($cm9 = 1; $cm9 -le 9; $cm9++) {
                        $cv9 = try { [double](XR-GetMeterLevel $cm9) } catch { -90.0 }
                        if ($cv9 -gt $mDB9) { $mDB9 = $cv9 }
                    }
                    $txt9 = if ($mDB9 -le -89.0) { "-inf" } else { ("{0:F0}" -f $mDB9) + "dB" }
                    if ($ll9.Text -ne $txt9) { $ll9.Text = $txt9 }
                }
            }
            catch { Log "MixerPanel timer error: $_" }
        })
    $script:_mixerPanelTimer.Start()

    # ---- Cleanup when panel is closed ----
    $frmM.Add_FormClosed({
            try {
                if ($script:_mixerPanelTimer) {
                    $script:_mixerPanelTimer.Stop()
                    $script:_mixerPanelTimer.Dispose()
                    $script:_mixerPanelTimer = $null
                }
                $script:_mixerPanel = $null
                # Only save MixerPanelEnabled=$false when the USER closes the panel,
                # NOT when the main app is exiting (it would overwrite the saved $true)
                if (-not $script:_appExiting -and -not $script:_mixerReopeningForScale) {
                    $script:Cfg.XR.MixerPanelEnabled = $false
                    try { Save-Settings | Out-Null } catch {}
                    try { if ($script:chkMixerPanel -and -not $script:chkMixerPanel.IsDisposed) { $script:chkMixerPanel.Checked = $false } } catch {}
                }
            }
            catch {}
        })

    # Show without owner first so WinForms cannot override the Manual size/position.
    # Then assign Owner after Show() — Windows uses it to pin the mixer to the same
    # virtual desktop as the main form without affecting layout.
    $frmM.Show()
    $frmM.Owner = $script:form
    # Save mixer size when user resizes it
    $frmM.Add_ResizeEnd({
            # Mixer height always matches main form — nothing to save on resize
        })
    # Re-apply location after Show() to guarantee WinForms honours it
    $frmM.Location = [System.Drawing.Point]::new($panelX, $panelY)
    $frmM.BringToFront()
    $frmM.Activate()
    # Deep repaint after layout settles so all custom-drawn controls colour correctly
    $repaintTimer = New-Object System.Windows.Forms.Timer
    $repaintTimer.Interval = 120
    $repaintTimer.Add_Tick({
            $this.Stop(); $this.Dispose()
            try {
                if ($frmM -and -not $frmM.IsDisposed) {
                    $frmM.Invalidate($true)
                    $frmM.Update()
                }
            }
            catch {}
        })
    $repaintTimer.Start()
    # Set XR status in title bar (deferred 50 ms so form renders first)
    $xrTitleInitTimer = New-Object System.Windows.Forms.Timer
    $xrTitleInitTimer.Interval = 50
    $xrTitleInitTimer.Add_Tick({
            $this.Stop(); $this.Dispose()
            try {
                $online = $false
                $titIP = try { [string]$script:Cfg.XR.MixerIP } catch { "" }
                try { $online = Test-MixerPing -Ip $titIP } catch {}
                if ($frmM -and -not $frmM.IsDisposed) {
                    $frmM.Text = if ($online) { "XR Mixer Panel  |  $titIP  |  XR: Online ✓" } else { "XR Mixer Panel  |  $titIP  |  XR: Offline ✗" }
                }
            }
            catch {}
        })
    $xrTitleInitTimer.Start()
    # Apply dark title bar via DWM (Windows 10 1903+ / Windows 11)
    try {
        if (-not ([System.Management.Automation.PSTypeName]'DwmDarkTitle').Type) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class DwmDarkTitle {
    [DllImport("dwmapi.dll")]
    public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int attrValue, int attrSize);
}
'@
        }
        $dark = 1
        [DwmDarkTitle]::DwmSetWindowAttribute($frmM.Handle, 20, [ref]$dark, 4) | Out-Null
    }
    catch {}
    # Fetch actual fader positions from mixer as soon as panel opens
    $st0 = New-Object System.Windows.Forms.Timer
    $st0.Interval = 300
    $st0.Add_Tick({ $this.Stop(); $this.Dispose(); XR-SyncMixerFaders })
    $st0.Start()
}
function Hide-MixerPanel {
    if ($script:_mixerPanel -and -not $script:_mixerPanel.IsDisposed) {
        try { $script:_mixerPanel.Close() } catch {}
    }
}

# Apply saved UI scale before showing the form
try {
    $script:_savedScaleLevel = [int]$script:Cfg.UI.ScaleLevel
    if ($script:_savedScaleLevel -gt 0 -and $script:_savedScaleLevel -le 2) {
        Apply-UIScale $script:_savedScaleLevel
    }
    else {
        Apply-UIScale 0
    }
}
catch {}

[void]$script:form.ShowDialog()







