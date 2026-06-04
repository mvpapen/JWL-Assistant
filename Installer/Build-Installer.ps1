$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$issPath = Join-Path $scriptDir 'JWL-Assistant-Setup.iss'

$isccCandidates = @(
    (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'),
    (Join-Path $env:ProgramFiles 'Inno Setup 6\ISCC.exe'),
    (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe')
)

$iscc = $isccCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $iscc) {
    Write-Host 'Inno Setup Compiler not found.' -ForegroundColor Yellow
    Write-Host 'Install Inno Setup 6 from: https://jrsoftware.org/isdl.php' -ForegroundColor Yellow
    exit 1
}

Write-Host "Using ISCC: $iscc"
& $iscc $issPath
if ($LASTEXITCODE -ne 0) {
    throw "Installer build failed with exit code $LASTEXITCODE"
}

Write-Host 'Installer build completed.' -ForegroundColor Green
