# Bitmap/icon drawing helpers — dot-sourced (see Logging.ps1 header note on why not Import-Module).
# Self-contained: no $script: state dependencies.

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
