# Logging module — dot-sourced (NOT Import-Module) so $script: vars resolve to the
# caller's (main script's) scope, preserving existing behavior exactly.

$script:LogBuffer = New-Object System.Collections.ArrayList
$script:sbLeft = $null
# Noise pattern: XR/OSC/meter messages suppressed unless XrDebugLog is enabled
$script:_xrNoiseRx = '(?i)(^OSC |^XR[: ]|^XR12|^Sent /|^Mixer Panel|^METER |^RAW#|/meters/|/xremote|keepalive|meter sub|blob|XR recv|OSC Fader|OSC Debug|Auto-scan|^Auto Mode: (Wave|Tick))'

# Audit fix: persistent on-disk log file. Previously the log was RAM-only (+ console echo),
# so a crash or force-close lost the entire session's history - a real diagnostics gap for a
# live production tool. One file per calendar day, kept alongside settings.json, auto-pruned
# to the most recent 14 days. Failures here must never break the app, so everything is
# best-effort/try-caught and the in-memory buffer + console behavior above is unchanged.
$script:_logFileWriter = $null
$script:_logFileInitTried = $false

function Get-LogFileDir {
    try {
        $appDataFolder = [Environment]::GetFolderPath('ApplicationData')
        $logDir = Join-Path (Join-Path $appDataFolder 'JWL-OBS-Assistant') 'logs'
        if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
        return $logDir
    }
    catch { return $null }
}

function Initialize-FileLogging {
    if ($script:_logFileInitTried) { return }
    $script:_logFileInitTried = $true
    try {
        $logDir = Get-LogFileDir
        if (-not $logDir) { return }

        $logPath = Join-Path $logDir ("app_{0}.log" -f (Get-Date).ToString('yyyyMMdd'))
        $writer = New-Object System.IO.StreamWriter($logPath, $true, [System.Text.Encoding]::UTF8)
        $writer.AutoFlush = $true
        $script:_logFileWriter = $writer
        $writer.WriteLine("`r`n===== Session started $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') =====")

        # Prune: keep only the 14 most recent daily log files
        Get-ChildItem $logDir -Filter 'app_*.log' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -Skip 14 |
        Remove-Item -Force -ErrorAction SilentlyContinue
    }
    catch {
        # File logging is a best-effort enhancement - never let it block app startup.
        $script:_logFileWriter = $null
    }
}

function Close-FileLogging {
    try {
        if ($script:_logFileWriter) {
            $script:_logFileWriter.WriteLine("===== Session ended $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') =====")
            $script:_logFileWriter.Flush()
            $script:_logFileWriter.Dispose()
        }
    }
    catch {}
    finally { $script:_logFileWriter = $null }
}

function Log([string]$msg) {
    # Suppress verbose XR/OSC/meter noise unless debug logging is enabled
    if ($script:Cfg -and $script:Cfg.XR -and (-not $script:Cfg.XR.XrDebugLog)) {
        if ($msg -match $script:_xrNoiseRx) { return }
    }
    $stamp = (Get-Date).ToString("HH:mm:ss")
    $line = "[$stamp] $msg"

    try {
        [void]$script:LogBuffer.Add($line)
        # Cap buffer so a long-running session doesn't grow unbounded
        if ($script:LogBuffer.Count -gt 5000) { $script:LogBuffer.RemoveRange(0, $script:LogBuffer.Count - 4000) }
    }
    catch {}

    # Persist to disk so log history survives a crash/force-close (best-effort; never throws)
    try {
        if (-not $script:_logFileInitTried) { Initialize-FileLogging }
        if ($script:_logFileWriter) { $script:_logFileWriter.WriteLine($line) }
    }
    catch {}

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

# ---- lightweight throttled logger for repetitive events ----
if (-not $script:__lastLogAt) { $script:__lastLogAt = @{} }
function Write-ThrottledLog([string]$key, [string]$msg, [int]$everySec = 10) {
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

function Get-RootErrorMessage($ex) { try { $e = $ex; while ($e.InnerException) { $e = $e.InnerException }; return [string]$e.Message }catch { return [string]$ex } }
