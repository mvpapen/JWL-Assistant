$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$src = Join-Path $root 'JWL+OBS Assistant v6.1.8e.ps1'
$out = Join-Path $root 'JWL+OBS Assistant v6.1.8e x.exe'
$icon = Join-Path $root 'Installer\jwl-assistant.ico'

Import-Module ps2exe

$params = @{
    inputFile  = $src
    outputFile = $out
    x64        = $true
    sta        = $true
    noConsole  = $true
    title      = 'JWL Assistant'
    product    = 'JWL Assistant'
    version    = '6.1.8.0'
}

if (Test-Path $icon) {
    $params.iconFile = $icon
}

Invoke-ps2exe @params
