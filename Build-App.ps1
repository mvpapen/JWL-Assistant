param(
    [string]$Version = '7.0.5b',
    [string]$Source
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $Source) { $Source = Join-Path $root "JWL+OBS Assistant v$Version new UI.ps1" }
$out = Join-Path $root "JWL+OBS Assistant v$Version.exe"
$icon = Join-Path $root 'Installer\jwl-assistant.ico'

if (-not (Test-Path $Source)) { throw "Source script not found: $Source" }
if (-not (Test-Path $icon)) { throw "Icon not found: $icon" }

# Refuse to compile a script that does not parse.
$parseErrors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($Source, [ref]$null, [ref]$parseErrors)
if ($parseErrors -and $parseErrors.Count -gt 0) {
    $parseErrors | Select-Object -First 5 | ForEach-Object { Write-Host $_.ToString() -ForegroundColor Red }
    throw "Source script has $($parseErrors.Count) parse error(s) - not building."
}

Import-Module ps2exe

# The EXE file version must be numeric: a letter suffix (7.0.5b) becomes the 4th part (a=1, b=2, ...).
$fileVersion = '0.0.0.0'
if ($Version -match '^(\d+)\.(\d+)\.(\d+)([a-zA-Z]?)$') {
    $letterNo = if ($Matches[4]) { [int][char]$Matches[4].ToLower() - [int][char]'a' + 1 } else { 0 }
    $fileVersion = "$($Matches[1]).$($Matches[2]).$($Matches[3]).$letterNo"
}

$params = @{
    inputFile  = $Source
    outputFile = $out
    iconFile   = $icon
    x64        = $true
    sta        = $true
    noConsole  = $true
    title      = 'JWL Assistant'
    product    = 'JWL Assistant'
    company    = 'mvpapen'
    copyright  = 'Copyright (c) 2026 Michel von Papen'
    version    = $fileVersion
}

Invoke-ps2exe @params
Write-Host "EXE built -> $out" -ForegroundColor Green
