$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Drawing

$iconPath = Join-Path $PSScriptRoot 'jwl-assistant.ico'
$size = 256
$bitmap = New-Object System.Drawing.Bitmap $size, $size
$graphics = [System.Drawing.Graphics]::FromImage($bitmap)
$graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
$graphics.Clear([System.Drawing.Color]::FromArgb(18, 35, 64))

$ellipse = New-Object System.Drawing.Rectangle 8, 8, 240, 240
$gradient = New-Object System.Drawing.Drawing2D.LinearGradientBrush $ellipse, ([System.Drawing.Color]::FromArgb(0, 123, 255)), ([System.Drawing.Color]::FromArgb(0, 191, 165)), 45
$outline = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(220, 255, 255, 255)), 6
$graphics.FillEllipse($gradient, $ellipse)
$graphics.DrawEllipse($outline, $ellipse)

$font = New-Object System.Drawing.Font 'Segoe UI', 82, ([System.Drawing.FontStyle]::Bold), ([System.Drawing.GraphicsUnit]::Pixel)
$stringFormat = New-Object System.Drawing.StringFormat
$stringFormat.Alignment = 'Center'
$stringFormat.LineAlignment = 'Center'
$shadowBrush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(80, 0, 0, 0))
$textBrush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::White)
$shadowRect = New-Object System.Drawing.RectangleF 4, 8, 256, 256
$textRect = New-Object System.Drawing.RectangleF 0, 0, 256, 256
$graphics.DrawString('J', $font, $shadowBrush, $shadowRect, $stringFormat)
$graphics.DrawString('J', $font, $textBrush, $textRect, $stringFormat)

$iconHandle = $bitmap.GetHicon()
$icon = [System.Drawing.Icon]::FromHandle($iconHandle)
$fileStream = [System.IO.File]::Open($iconPath, [System.IO.FileMode]::Create)
$icon.Save($fileStream)
$fileStream.Close()

$graphics.Dispose()
$gradient.Dispose()
$outline.Dispose()
$font.Dispose()
$shadowBrush.Dispose()
$textBrush.Dispose()
$bitmap.Dispose()
$icon.Dispose()

[pscustomobject]@{
    FullName      = $iconPath
    Length        = (Get-Item $iconPath).Length
    LastWriteTime = (Get-Item $iconPath).LastWriteTime
}
