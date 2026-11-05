# Theme kit (PS 5.1 safe) - dot-sourced (see Logging.ps1 header note on why not Import-Module).

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
    Back     = [Drawing.Color]::FromArgb(220, 220, 228)
    Panel    = [Drawing.Color]::FromArgb(220, 220, 228)
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
function Set-ThemeRecursive([Windows.Forms.Control]$root, [hashtable]$theme, [bool]$dark) {
    Set-ControlTheme $root $theme $dark
    foreach ($child in $root.Controls) { Set-ThemeRecursive $child $theme $dark }
}
function Register-ThemeForNewControls(
    [Windows.Forms.Control]$root,
    [hashtable]$theme,
    [bool]$dark,
    [int]$version
) {
    # Capture stable copies for the handler's closure + version guard
    $t = $theme
    $d = [bool]$dark
    $v = [int]$version

    # Audit fix #14: every dark/light toggle used to add a brand-new ControlAdded handler to
    # every control in the tree, forever - old handlers were version-gated to silently no-op
    # but were NEVER removed, so a long session with many theme toggles would accumulate one
    # extra delegate per control per toggle. Track the handler we attach per-control so the
    # previous toggle's handler is explicitly removed before the new one is added.
    if (-not $script:_themeControlAddedHandlers) {
        $script:_themeControlAddedHandlers = New-Object 'System.Collections.Generic.Dictionary[object,object]'
    }
    if ($script:_themeControlAddedHandlers.ContainsKey($root)) {
        try { $root.remove_ControlAdded($script:_themeControlAddedHandlers[$root]) } catch {}
        $script:_themeControlAddedHandlers.Remove($root) | Out-Null
    }

    $handler = [Windows.Forms.ControlEventHandler]{
        param($s, $e)
        try {
            # Only theme if this handler matches the current theme version
            if ($v -ne $script:ThemeVersion) { return }
            Set-ThemeRecursive $e.Control $t $d
            Register-ThemeForNewControls $e.Control $t $d $v
        }
        catch {}
    }
    $root.add_ControlAdded($handler)
    $script:_themeControlAddedHandlers[$root] = $handler

    foreach ($child in $root.Controls) {
        Register-ThemeForNewControls $child $t $d $v
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
        Set-ThemeRecursive $Form $theme $Enable

        # Hook future controls, but only for this version
        Register-ThemeForNewControls $Form $theme $Enable $ver

        # Dark title bar (supported on Win10+)
        Set-DarkTitleBar $Form $Enable

        # BackColor changes correctly in memory but WinForms doesn't always repaint a Form with
        # many overlapping child controls on its own - force it so the color change is visible.
        $Form.Invalidate($true)
        $Form.Update()
    }
    catch {}
}
