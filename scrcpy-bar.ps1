# scrcpy-bar - a control strip that rides on top of the scrcpy mirror window.
#
# Buttons: Screenshot | Record | Info | Quit
#
# Why an overlay and not buttons inside the scrcpy window: that window belongs to SDL,
# inside another process. The two ways to put controls on it are (a) reparent it into a
# window of ours with SetParent, which routinely breaks SDL input handling, fullscreen
# and per-monitor DPI, or (b) float a separate always-on-top window that tracks its
# position. (b) is the honest one, and it is what this does.
#
# Launched automatically by scrcpy-tray when mirroring starts. Can also be run by hand
# against an already-running mirror:
#   powershell -NoProfile -ExecutionPolicy Bypass -STA -File scrcpy-bar.ps1 -Serial <serial>
#
# Exits when the mirror window goes away.

[CmdletBinding()]
param(
  [string]$Serial = '',
  [string]$WindowTitle = 'Phone',
  # Where scrcpy's own stdout/stderr were captured, so "Open terminal with scrcpy log"
  # can show exactly what the old console used to print.
  [string]$LogFile = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Add-Type @'
using System;
using System.Text;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public static class Native {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr p);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint msg, IntPtr wp, IntPtr lp);
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINT p);
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
    public delegate bool EnumProc(IntPtr h, IntPtr p);

    // Where the window's CONTENT starts on screen - i.e. just under the title bar.
    // The toolbar belongs there, the way every normal application lays itself out:
    // title bar, then toolbar, then content.
    public static bool ClientOrigin(IntPtr h, out int x, out int y, out int w) {
        x = 0; y = 0; w = 0;
        RECT c;
        if (!GetClientRect(h, out c)) return false;
        POINT p; p.X = 0; p.Y = 0;
        if (!ClientToScreen(h, ref p)) return false;
        x = p.X; y = p.Y; w = c.R - c.L;
        return true;
    }

    public const uint WM_CLOSE = 0x0010;
    // Same thing as clicking the window's X. scrcpy shuts down cleanly on this, which
    // matters when a recording is still finalising its container.
    public static bool CloseWindow(IntPtr h) { return PostMessage(h, WM_CLOSE, IntPtr.Zero, IntPtr.Zero); }

    public const int SW_HIDE = 0;
    public const uint SWP_NOSIZE = 0x0001, SWP_NOACTIVATE = 0x0010, SWP_SHOWWINDOW = 0x0040;
    public static readonly IntPtr HWND_TOPMOST = new IntPtr(-1);

    public static string Cls(IntPtr h) { var s = new StringBuilder(256); GetClassName(h, s, 256); return s.ToString(); }
    public static string Txt(IntPtr h) { var s = new StringBuilder(256); GetWindowText(h, s, 256); return s.ToString(); }

    // The mirror window is SDL_app. The headless recorder is also SDL_app but hidden,
    // so only visible windows count here.
    public static IntPtr FindScrcpy(string title) {
        IntPtr found = IntPtr.Zero;
        EnumWindows((h, p) => {
            if (!IsWindowVisible(h)) return true;
            if (Cls(h) != "SDL_app") return true;
            if (!string.IsNullOrEmpty(title) && Txt(h).IndexOf(title, StringComparison.OrdinalIgnoreCase) < 0) return true;
            found = h; return false;
        }, IntPtr.Zero);
        return found;
    }
}

// A bar that never takes focus. WS_EX_NOACTIVATE is the part that matters: without it,
// clicking a button pulls focus off the mirror and your next keystroke goes nowhere.
public class OverlayBar : Form {
    protected override bool ShowWithoutActivation { get { return true; } }
    protected override CreateParams CreateParams {
        get {
            CreateParams cp = base.CreateParams;
            cp.ExStyle |= 0x08000000;  // WS_EX_NOACTIVATE
            cp.ExStyle |= 0x00000080;  // WS_EX_TOOLWINDOW - keep it out of Alt-Tab
            return cp;
        }
    }
}
'@ -ReferencedAssemblies System.Windows.Forms, System.Drawing

# ── locate scrcpy + adb (same rules as the tray) ─────────────────────────────
function Find-Tool {
  param([string]$Exe, [string]$PreferDir)
  if ($PreferDir) { $p = Join-Path $PreferDir $Exe; if (Test-Path -LiteralPath $p) { return (Resolve-Path $p).Path } }
  if ($env:SCRCPY_HOME) { $p = Join-Path $env:SCRCPY_HOME $Exe; if (Test-Path -LiteralPath $p) { return (Resolve-Path $p).Path } }
  if ($PSScriptRoot) { $p = Join-Path $PSScriptRoot $Exe; if (Test-Path -LiteralPath $p) { return (Resolve-Path $p).Path } }
  $c = Get-Command $Exe -ErrorAction SilentlyContinue
  if ($c -and $c.Source) { return $c.Source }
  foreach ($root in @((Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages'),
                      (Join-Path $env:USERPROFILE 'Tools\scrcpy'),
                      (Join-Path $env:ProgramFiles 'scrcpy'))) {
    if (-not (Test-Path -LiteralPath $root)) { continue }
    $h = Get-ChildItem -LiteralPath $root -Filter $Exe -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($h) { return $h.FullName }
  }
  return $null
}
$SCRCPY = Find-Tool 'scrcpy.exe'
$ADB    = Find-Tool 'adb.exe' -PreferDir $(if ($SCRCPY) { Split-Path -Parent $SCRCPY } else { $null })
if (-not $ADB -or -not $SCRCPY) {
  [System.Windows.Forms.MessageBox]::Show('scrcpy or adb not found', 'scrcpy-bar') | Out-Null; exit 1
}
$TOOL    = Split-Path -Parent $SCRCPY
$SHOTDIR = Join-Path ([Environment]::GetFolderPath('MyPictures')) 'Phone'
$dev = @(); if ($Serial) { $dev = @('-s', $Serial) }

function Invoke-AdbBytes {
  param([string[]]$ArgList, [int]$TimeoutMs = 20000)
  $p = $null
  try {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $ADB; $psi.Arguments = ($ArgList -join ' ')
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    $ms = New-Object System.IO.MemoryStream
    $copy = $p.StandardOutput.BaseStream.CopyToAsync($ms)
    $err  = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($TimeoutMs)) { try { $p.Kill() } catch { }; return $null }
    if (-not $copy.Wait(5000)) { return $null }
    $null = $err.Wait(500)
    return $ms.ToArray()
  } catch { return $null } finally { if ($p) { try { $p.Dispose() } catch { } } }
}
function Invoke-AdbText {
  param([string[]]$ArgList, [int]$TimeoutMs = 8000)
  $b = Invoke-AdbBytes $ArgList $TimeoutMs
  if ($null -eq $b) { return $null }
  return [System.Text.Encoding]::UTF8.GetString($b).Trim()
}

# ── the bar ──────────────────────────────────────────────────────────────────
$BAR_H = 34
$bar = New-Object OverlayBar
$bar.FormBorderStyle = 'None'
$bar.ShowInTaskbar   = $false
$bar.TopMost         = $true
$bar.StartPosition   = 'Manual'
$bar.Height          = $BAR_H
$bar.BackColor       = [System.Drawing.Color]::FromArgb(28, 28, 30)
$bar.Visible         = $false

$status = New-Object System.Windows.Forms.Label
$status.AutoSize = $false; $status.Dock = 'Right'; $status.Width = 200
$status.ForeColor = [System.Drawing.Color]::FromArgb(150, 150, 155)
$status.TextAlign = 'MiddleRight'
$status.Font = New-Object System.Drawing.Font('Segoe UI', 8)
$bar.Controls.Add($status)

function Set-Status {
  param([string]$Text, [System.Drawing.Color]$Color = [System.Drawing.Color]::FromArgb(150,150,155))
  $status.ForeColor = $Color; $status.Text = $Text
}

function New-BarButton {
  param([string]$Text, [int]$X, [int]$Width, [scriptblock]$OnClick)
  $b = New-Object System.Windows.Forms.Button
  $b.Text = $Text; $b.Left = $X; $b.Top = 4; $b.Width = $Width; $b.Height = 26
  $b.FlatStyle = 'Flat'; $b.FlatAppearance.BorderSize = 0
  $b.BackColor = [System.Drawing.Color]::FromArgb(45, 45, 48)
  $b.ForeColor = [System.Drawing.Color]::White
  $b.Font = New-Object System.Drawing.Font('Segoe UI', 9)
  $b.TabStop = $false
  $b.add_Click($OnClick)
  $bar.Controls.Add($b)
  return $b
}

# ── screenshot ───────────────────────────────────────────────────────────────
$btnShot = New-BarButton 'Screenshot' 6 88 {
  Set-Status 'capturing...'
  $bytes = Invoke-AdbBytes ($dev + @('exec-out', 'screencap', '-p'))
  if ($null -eq $bytes -or $bytes.Length -lt 1024 -or
      -not ($bytes[0] -eq 0x89 -and $bytes[1] -eq 0x50 -and $bytes[2] -eq 0x4E -and $bytes[3] -eq 0x47)) {
    Set-Status 'screenshot failed' ([System.Drawing.Color]::FromArgb(255,120,120)); return
  }
  if (-not (Test-Path $SHOTDIR)) { New-Item -ItemType Directory -Path $SHOTDIR -Force | Out-Null }
  $file = Join-Path $SHOTDIR ('print-' + (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss') + '.png')
  try { [System.IO.File]::WriteAllBytes($file, $bytes) }
  catch { Set-Status 'could not save' ([System.Drawing.Color]::FromArgb(255,120,120)); return }
  $clip = $false
  try {
    $ms = New-Object System.IO.MemoryStream(,$bytes)
    $img = [System.Drawing.Image]::FromStream($ms)
    [System.Windows.Forms.Clipboard]::SetImage($img)
    $img.Dispose(); $ms.Dispose(); $clip = $true
  } catch { }
  if ($clip) { Set-Status 'copied to clipboard' ([System.Drawing.Color]::FromArgb(120,220,140)) }
  else       { Set-Status 'saved (clipboard failed)' ([System.Drawing.Color]::FromArgb(240,200,120)) }
}

# ── recording ────────────────────────────────────────────────────────────────
# Recording runs as a SECOND scrcpy process alongside the mirror, so the picture you
# are watching is never interrupted. Two flags make that bearable:
#   -N / --no-playback   record only, do not render
#   --no-control         the recorder must not compete for input with the mirror
#
# It is NOT started with --no-window, even though that sounds right: with no window
# there is nothing to send WM_CLOSE to, the only way out is Kill(), and scrcpy writes
# the MP4 moov atom during shutdown — measured, a killed recording produces a file no
# player will open. So it keeps its window and we hide it with ShowWindow(SW_HIDE)
# instead. A hidden window still receives WM_CLOSE, so the file finalises properly.
$script:rec = $null

function Test-Recording {
  if (-not $script:rec) { return $false }
  try { if ($script:rec.Process.HasExited) { $script:rec = $null; return $false }; return $true }
  catch { $script:rec = $null; return $false }
}

function Start-Recording {
  if (Test-Recording) { return $true }
  if (-not (Test-Path $SHOTDIR)) { New-Item -ItemType Directory -Path $SHOTDIR -Force | Out-Null }
  $file = Join-Path $SHOTDIR ('phone-' + (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss') + '.mp4')
  $a = @()
  if ($Serial) { $a += @('-s', $Serial) }
  $a += @('-N', '--no-control', '--record', "`"$file`"")
  try {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $SCRCPY; $psi.Arguments = ($a -join ' ')
    $psi.WorkingDirectory = $TOOL; $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    # Hide its window as soon as it exists, so only the mirror stays on screen.
    for ($i = 0; $i -lt 40 -and $p.MainWindowHandle -eq 0; $i++) { Start-Sleep -Milliseconds 100; $p.Refresh() }
    if ($p.MainWindowHandle -ne 0) { $null = [Native]::ShowWindow($p.MainWindowHandle, [Native]::SW_HIDE) }
    $script:rec = @{ Process = $p; File = $file; StartedAt = Get-Date }
    return $true
  } catch { return $false }
}

function Stop-Recording {
  if (-not (Test-Recording)) { return $null }
  $p = $script:rec.Process; $file = $script:rec.File
  $secs = [math]::Round(((Get-Date) - $script:rec.StartedAt).TotalSeconds)
  $forced = $false
  try {
    $null = $p.CloseMainWindow()
    if (-not $p.WaitForExit(8000)) { try { $p.Kill(); $null = $p.WaitForExit(3000) } catch { }; $forced = $true }
  } catch { }
  $script:rec = $null
  Start-Sleep -Milliseconds 500
  $kb = if (Test-Path -LiteralPath $file) { [math]::Round((Get-Item -LiteralPath $file).Length / 1KB) } else { 0 }
  return [pscustomobject]@{ File = $file; Seconds = $secs; SizeKB = $kb; Forced = $forced }
}

$btnRec = New-BarButton 'Record' 98 80 {
  if (Test-Recording) {
    $r = Stop-Recording
    if (-not $r -or $r.SizeKB -eq 0) { Set-Status 'recording failed' ([System.Drawing.Color]::FromArgb(255,120,120)) }
    elseif ($r.Forced)               { Set-Status "saved $($r.SizeKB)KB (forced)" ([System.Drawing.Color]::FromArgb(240,200,120)) }
    else                             { Set-Status "saved $($r.Seconds)s, $($r.SizeKB)KB" ([System.Drawing.Color]::FromArgb(120,220,140)) }
  } else {
    if (Start-Recording) { Set-Status 'recording...' ([System.Drawing.Color]::FromArgb(255,140,140)) }
    else { Set-Status 'could not start recording' ([System.Drawing.Color]::FromArgb(255,120,120)) }
  }
}

# ── info ─────────────────────────────────────────────────────────────────────
# The things scrcpy prints to a console you were never meant to look at.
$script:info = $null

function Show-DeviceInfo {
  if (-not $script:info) {
    Set-Status 'reading device...'
    $props = Invoke-AdbText ($dev + @('shell', 'getprop'))
    $size  = Invoke-AdbText ($dev + @('shell', 'wm', 'size'))
    $dens  = Invoke-AdbText ($dev + @('shell', 'wm', 'density'))
    $bat   = Invoke-AdbText ($dev + @('shell', 'dumpsys', 'battery'))
    function Prop([string]$k) {
      if ($props -and $props -match "\[$([regex]::Escape($k))\]:\s*\[([^\]]*)\]") { return $Matches[1] }
      return '?'
    }
    $lvl = if ($bat -and $bat -match 'level:\s*(\d+)') { $Matches[1] + '%' } else { '?' }
    $scrcpyVer = try { (& $SCRCPY --version 2>&1 | Select-Object -First 1) } catch { '?' }
    $script:info = @"
Model         $(Prop 'ro.product.model')
Manufacturer  $(Prop 'ro.product.manufacturer')
Android       $(Prop 'ro.build.version.release')   (SDK $(Prop 'ro.build.version.sdk'))
Serial        $(if ($Serial) { $Serial } else { '(single device)' })
Screen        $(if ($size) { ($size -replace 'Physical size:\s*','').Trim() } else { '?' })
Density       $(if ($dens) { ($dens -replace 'Physical density:\s*','').Trim() } else { '?' })
Battery       $lvl

$scrcpyVer
Screenshots   $SHOTDIR
"@
  }
  Set-Status ''
  [System.Windows.Forms.MessageBox]::Show($script:info, 'Device info',
    [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
}

# The classic way: a real console sitting in the scrcpy folder, so you can run scrcpy
# with any flag it has. This tool covers the common actions; it does not try to replace
# the command line, and this button is the honest admission of that. Same idea as the
# open_a_terminal_here.bat that ships with scrcpy.
function Open-Terminal {
  try {
    $pwshExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $intro   = if ($Serial) { "scrcpy -s $Serial <options>" } else { 'scrcpy <options>' }
    $cmd = "Set-Location -LiteralPath '$TOOL'; " +
           "Write-Host 'scrcpy working directory - run it with any flags you like.' -ForegroundColor Cyan; " +
           "Write-Host '  $intro' -ForegroundColor DarkGray; " +
           "Write-Host '  .\scrcpy.exe --help' -ForegroundColor DarkGray"
    Start-Process -FilePath $pwshExe `
      -ArgumentList '-NoExit', '-NoProfile', '-Command', $cmd `
      -WorkingDirectory $TOOL
    Set-Status 'terminal opened'
  } catch {
    Set-Status 'could not open terminal' ([System.Drawing.Color]::FromArgb(255,120,120))
  }
}

# The console scrcpy used to open on its own. Its output is captured to a file at
# launch, so this shows the real thing - device picked, renderer, texture size - and
# then leaves you at a prompt in the scrcpy folder, exactly like the old behaviour.
function Open-TerminalWithLog {
  if (-not $LogFile) {
    Set-Status 'no log for this session' ([System.Drawing.Color]::FromArgb(240,200,120)); return
  }
  try {
    $pwshExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $err = "$LogFile.err"
    $cmd = "Set-Location -LiteralPath '$TOOL'; " +
           "Write-Host '--- scrcpy output for this session ---' -ForegroundColor Cyan; " +
           "if (Test-Path -LiteralPath '$LogFile') { Get-Content -LiteralPath '$LogFile' }; " +
           "if (Test-Path -LiteralPath '$err') { Get-Content -LiteralPath '$err' }; " +
           "Write-Host ''; " +
           "Write-Host '--- you are in the scrcpy folder; run it with any flags ---' -ForegroundColor DarkGray"
    Start-Process -FilePath $pwshExe -ArgumentList '-NoExit', '-NoProfile', '-Command', $cmd -WorkingDirectory $TOOL
    Set-Status 'terminal opened'
  } catch {
    Set-Status 'could not open terminal' ([System.Drawing.Color]::FromArgb(255,120,120))
  }
}

# Info gives the quick box, a bare terminal, or the old scrcpy console output.
$infoMenu = New-Object System.Windows.Forms.ContextMenuStrip
$miInfo = $infoMenu.Items.Add('Device info')
$miInfo.add_Click({ Show-DeviceInfo })
$null = $infoMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$miLog = $infoMenu.Items.Add('Open terminal with scrcpy log')
$miLog.add_Click({ Open-TerminalWithLog })
$miTerm = $infoMenu.Items.Add('Open terminal (empty)')
$miTerm.add_Click({ Open-Terminal })

$btnInfo = New-BarButton 'Info' 182 56 {
  $infoMenu.Show($btnInfo, 0, $btnInfo.Height)
}

# ── quit ─────────────────────────────────────────────────────────────────────
# Closes the mirror the same way clicking its X does, finishing any recording first so
# the file is not lost.
$btnQuit = New-BarButton 'Quit' 242 52 {
  if (Test-Recording) { Set-Status 'finishing recording...'; $null = Stop-Recording }
  if ($script:target -ne [IntPtr]::Zero -and [Native]::IsWindow($script:target)) {
    $null = [Native]::CloseWindow($script:target)
  }
  [System.Windows.Forms.Application]::Exit()
}

# ── follow the mirror window ─────────────────────────────────────────────────
# Polling GetWindowRect is deliberate: a SetWinEventHook for EVENT_OBJECT_LOCATIONCHANGE
# is the "correct" answer but needs its own message pump. 60 ms tracks smoothly enough
# that the bar reads as attached rather than as a separate window chasing it.
$script:target = [IntPtr]::Zero
$script:gone   = 0

$follow = New-Object System.Windows.Forms.Timer
$follow.Interval = 60
$follow.add_Tick({
  if ($script:target -eq [IntPtr]::Zero -or -not [Native]::IsWindow($script:target)) {
    $script:target = [Native]::FindScrcpy($WindowTitle)
    if ($script:target -eq [IntPtr]::Zero) {
      if ($bar.Visible) { $bar.Hide() }
      # The mirror is gone for good; take the bar with it.
      $script:gone++
      if ($script:gone -gt 50) { [System.Windows.Forms.Application]::Exit() }
      return
    }
  }
  $script:gone = 0

  if ([Native]::IsIconic($script:target) -or -not [Native]::IsWindowVisible($script:target)) {
    if ($bar.Visible) { $bar.Hide() }
    return
  }

  # Sit directly under scrcpy's title bar, on top of the content - the standard
  # title / toolbar / content stack every other application uses. Anchoring to the
  # CLIENT origin rather than the window rect is what keeps the title bar (and its
  # minimise and close buttons) clear.
  $cx = 0; $cy = 0; $cw = 0
  if (-not [Native]::ClientOrigin($script:target, [ref]$cx, [ref]$cy, [ref]$cw)) { return }
  $x = $cx
  $y = $cy
  $w = $cw

  if ($bar.Width -ne $w) { $bar.Width = $w }
  if ($bar.Left -ne $x -or $bar.Top -ne $y) {
    [Native]::SetWindowPos($bar.Handle, [Native]::HWND_TOPMOST, $x, $y, 0, 0,
      ([Native]::SWP_NOSIZE -bor [Native]::SWP_NOACTIVATE)) | Out-Null
    $bar.Left = $x; $bar.Top = $y
  }
  if (-not $bar.Visible) {
    $bar.Show()
    [Native]::SetWindowPos($bar.Handle, [Native]::HWND_TOPMOST, $x, $y, 0, 0,
      ([Native]::SWP_NOSIZE -bor [Native]::SWP_NOACTIVATE -bor [Native]::SWP_SHOWWINDOW)) | Out-Null
  }

  if (Test-Recording) {
    $e = [math]::Round(((Get-Date) - $script:rec.StartedAt).TotalSeconds)
    if ($btnRec.Text -ne "Stop $e s") { $btnRec.Text = "Stop $e s" }
    $btnRec.BackColor = [System.Drawing.Color]::FromArgb(120, 40, 40)
  } elseif ($btnRec.Text -ne 'Record') {
    $btnRec.Text = 'Record'
    $btnRec.BackColor = [System.Drawing.Color]::FromArgb(45, 45, 48)
  }
})

# Wait for the mirror window to map before giving up.
$script:target = [Native]::FindScrcpy($WindowTitle)
for ($i = 0; $i -lt 40 -and $script:target -eq [IntPtr]::Zero; $i++) {
  Start-Sleep -Milliseconds 250
  $script:target = [Native]::FindScrcpy($WindowTitle)
}
if ($script:target -eq [IntPtr]::Zero) { exit 1 }

$follow.Start()
Set-Status 'ready'
[System.Windows.Forms.Application]::Run()

$follow.Stop()
if (Test-Recording) { $null = Stop-Recording }
$bar.Dispose()
