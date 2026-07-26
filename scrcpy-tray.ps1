# scrcpy-tray — your Android phone shows up in the Windows tray the moment you plug it in.
#
# The design rule: no device, no icon at all. Plug a phone in and the icon appears;
# click it and the screen mirrors through scrcpy. The action this was actually built
# for is "Screenshot now" — it pulls a frame straight off the device with
# `adb exec-out screencap -p` and puts it on the Windows clipboard, which scrcpy
# itself has no option for.
#
# Requires scrcpy and adb to be installed separately; nothing is bundled. See README.
#
# Run hidden via scrcpy-tray.vbs (no console window). Windows PowerShell 5.1 is used
# deliberately: it defaults to STA, which WinForms and the clipboard both require.
#
# This file MUST stay UTF-8 with BOM. PS 5.1 reads a BOM-less .ps1 as ANSI, and any
# non-ASCII character in it then breaks the parser.
#
# The five bugs a silent-failure audit caught, kept here because each is easy to
# reintroduce:
#   F1  the process timeouts were dead code — ReadToEnd() blocks before
#       WaitForExit(timeout) can ever run, so a wedged adb froze the UI thread
#       permanently, with no error and no way to reach the menu that fixes it.
#   F2  offline / authorizing / unknown device states all collapsed into "no device"
#       AND latched there, because the change-detect key stopped re-evaluating.
#       Any `adb connect` TCP target sits in `offline` routinely, so this was not
#       a corner case.
#   F3  Save-Screenshot returned success unconditionally, so the "copied" balloon
#       fired even when the clipboard write had thrown into an empty catch.
#   F4  the change-detect key was committed BEFORE the UI work it described, so any
#       failure in that work latched the state as "handled" forever.
#   F5  no single-instance guard: two tray icons, and 'Quit' only closed one.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ── F5: single instance. Without this the Startup shortcut plus any manual launch
# leaves two icons, two pollers, and a 'Quit' that only closes the one you clicked.
$script:mutex = New-Object System.Threading.Mutex($false, 'Global\ScrcpyTraySingleInstance')
if (-not $script:mutex.WaitOne(0, $false)) { exit 0 }

# ── locating scrcpy and adb ───────────────────────────────────────────────────
# This tool does NOT bundle scrcpy or adb. They are separate projects with their own
# licences and release cadence; shipping copies would mean redistributing someone
# else's binaries and pinning users to whatever version happened to be current.
# So look for an existing install, ordered by how explicit the user was about it:
#   1. $env:SCRCPY_HOME          - explicit wins over everything
#   2. this script's own folder  - for people who drop it into the scrcpy folder
#   3. PATH                      - winget / scoop / chocolatey / manual PATH entry
#   4. common install locations  - last resort, best effort
function Find-Tool {
  param(
    [string]$Exe,
    # Searched before anything else. Used to make adb resolve to the copy sitting
    # next to scrcpy — see the version-mismatch note below.
    [string]$PreferDir
  )

  if ($PreferDir) {
    $p = Join-Path $PreferDir $Exe
    if (Test-Path -LiteralPath $p) { return (Resolve-Path $p).Path }
  }

  if ($env:SCRCPY_HOME) {
    $p = Join-Path $env:SCRCPY_HOME $Exe
    if (Test-Path -LiteralPath $p) { return (Resolve-Path $p).Path }
  }

  # $PSScriptRoot is empty when the file is dot-sourced or run via -Command rather
  # than -File; Join-Path throws on an empty Path, so guard it.
  if ($PSScriptRoot) {
    $here = Join-Path $PSScriptRoot $Exe
    if (Test-Path -LiteralPath $here) { return (Resolve-Path $here).Path }
  }

  $cmd = Get-Command $Exe -ErrorAction SilentlyContinue
  if ($cmd -and $cmd.Source) { return $cmd.Source }

  foreach ($root in @(
      (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages'),
      (Join-Path $env:USERPROFILE 'scoop\apps\scrcpy\current'),
      'C:\ProgramData\chocolatey\lib\scrcpy\tools',
      (Join-Path $env:ProgramFiles 'scrcpy'),
      (Join-Path $env:USERPROFILE 'Tools\scrcpy'))) {
    if (-not (Test-Path -LiteralPath $root)) { continue }
    $hit = Get-ChildItem -LiteralPath $root -Filter $Exe -Recurse -File -ErrorAction SilentlyContinue |
           Select-Object -First 1
    if ($hit) { return $hit.FullName }
  }
  return $null
}

$SCRCPY = Find-Tool 'scrcpy.exe'

# adb resolves next to scrcpy FIRST, on purpose. scrcpy ships the adb it was tested
# with; a different adb already on PATH (Android SDK platform-tools, for instance)
# produces "adb server version doesn't match this client" — the first entry in
# scrcpy's own FAQ. Only fall back to PATH if scrcpy did not bring one.
$scrcpyDir = if ($SCRCPY) { Split-Path -Parent $SCRCPY } else { $null }
$ADB = Find-Tool 'adb.exe' -PreferDir $scrcpyDir

if (-not $SCRCPY -or -not $ADB) {
  $missing = @()
  if (-not $SCRCPY) { $missing += 'scrcpy.exe' }
  if (-not $ADB)    { $missing += 'adb.exe' }
  [System.Windows.Forms.MessageBox]::Show(
    ("Could not find: {0}`n`n" -f ($missing -join ', ')) +
    "scrcpy-tray does not bundle scrcpy or adb - install scrcpy first:`n" +
    "    winget install Genymobile.scrcpy`n`n" +
    "If it is already installed somewhere unusual, point SCRCPY_HOME at that folder:`n" +
    '    setx SCRCPY_HOME "C:\path\to\scrcpy"',
    'scrcpy-tray', 'OK', 'Error') | Out-Null
  exit 1
}

# scrcpy runs with this as working directory so it finds scrcpy-server beside it.
$TOOL = Split-Path -Parent $SCRCPY

# Screenshots go to the real shell Pictures folder, which is often OneDrive-redirected -
# that way they land where Explorer actually looks, and get backed up with everything else.
$picRoot = [Environment]::GetFolderPath('MyPictures')
if ([string]::IsNullOrWhiteSpace($picRoot)) { $picRoot = Join-Path $env:USERPROFILE 'Pictures' }
$SHOTDIR = Join-Path $picRoot 'Phone'

$POLL_MS = 15000   # backstop; WM_DEVICECHANGE drives the fast path

function Ensure-ShotDir {
  if (Test-Path $SHOTDIR) { return $true }
  try { New-Item -ItemType Directory -Path $SHOTDIR -Force -ErrorAction Stop | Out-Null; return $true }
  catch { return $false }
}

# ─── running console tools without ever blocking the UI thread ────────────────
# F1: the reads MUST be async and WaitForExit MUST be the thing that enforces the
# timeout. The previous order (synchronous ReadToEnd, then WaitForExit(timeout))
# meant the timeout could only be evaluated after the child had already closed
# stdout — i.e. it protected nothing, and a child that held stdout open hung the
# tray forever. Returns $null on timeout/failure so callers can tell it apart
# from a legitimately empty result.
function Invoke-Captured {
  param([string]$Exe, [string[]]$ArgList, [int]$TimeoutMs = 8000)
  $p = $null
  try {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe
    $psi.Arguments = ($ArgList -join ' ')
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    if (-not $p) { return $null }

    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()   # drained so a full pipe can't block the child

    if (-not $p.WaitForExit($TimeoutMs)) {
      try { $p.Kill() } catch { }
      return $null
    }
    if (-not $outTask.Wait(2000)) { return $null }
    $null = $errTask.Wait(500)
    return $outTask.Result
  }
  catch { return $null }
  finally { if ($p) { try { $p.Dispose() } catch { } } }
}

# Same contract, raw bytes: screencap emits a PNG, not text.
function Invoke-CapturedBytes {
  param([string]$Exe, [string[]]$ArgList, [int]$TimeoutMs = 20000)
  $p = $null
  try {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe
    $psi.Arguments = ($ArgList -join ' ')
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    if (-not $p) { return $null }

    $ms = New-Object System.IO.MemoryStream
    $copy = $p.StandardOutput.BaseStream.CopyToAsync($ms)
    $errTask = $p.StandardError.ReadToEndAsync()

    if (-not $p.WaitForExit($TimeoutMs)) {
      try { $p.Kill() } catch { }
      return $null
    }
    if (-not $copy.Wait(5000)) { return $null }
    $null = $errTask.Wait(500)
    return $ms.ToArray()
  }
  catch { return $null }
  finally { if ($p) { try { $p.Dispose() } catch { } } }
}

# ─── device state ────────────────────────────────────────────────────────────
# F2: returns AdbOk so "adb did not answer" is never mistaken for "no phone".
# States seen in the wild: device (usable), unauthorized (needs the on-phone
# prompt), offline (post-sleep re-enumeration, and any `adb connect` TCP target
# until disconnect), authorizing, "no permissions". Everything that is not
# `device` still deserves a visible, explained icon.
function Get-DeviceSnapshot {
  $raw = Invoke-Captured $ADB @('devices', '-l')
  if ($null -eq $raw) { return [pscustomobject]@{ AdbOk = $false; Devices = @() } }

  $list = @()
  foreach ($line in ($raw -split "`r?`n")) {
    if ($line -match '^\s*$' -or $line -match '^List of devices') { continue }
    if ($line -match '^\*') { continue }                 # daemon start chatter
    if ($line -match '^adb(\.exe)?\s') { continue }       # "adb server version ..." if it lands on stdout
    $parts = $line -split '\s+', 3
    if ($parts.Count -lt 2) { continue }
    $model = ''
    if ($line -match 'model:(\S+)') { $model = $Matches[1] -replace '_', ' ' }
    # "no permissions" splits across columns; normalise anything unexpected.
    $state = $parts[1]
    if ($state -eq 'no') { $state = 'no permissions' }
    $list += [pscustomobject]@{ Serial = $parts[0]; State = $state; Model = $model }
  }
  return [pscustomobject]@{ AdbOk = $true; Devices = $list }
}

function Get-UsableDevices {
  $snap = Get-DeviceSnapshot
  return @($snap.Devices | Where-Object { $_.State -eq 'device' })
}

function Format-DeviceLabel {
  param($Dev)
  if ($Dev.Model) { return "$($Dev.Model) [$($Dev.Serial)]" }
  return $Dev.Serial
}

# ─── actions ─────────────────────────────────────────────────────────────────
# scrcpy.exe is built as a CONSOLE subsystem binary (PE Subsystem = 3), so launching it
# normally allocates a black console window that sits next to the mirror window for the
# whole session. That is why the project ships scrcpy-noconsole.vbs, which wraps it in
# `WScript.Shell.Run(..., 0, false)`.
#
# We get the same result without shelling out to a .vbs: UseShellExecute = false plus
# CreateNoWindow = true means no console is ever allocated. scrcpy's own SDL window is a
# separate top-level window and still appears normally.
function Start-Scrcpy {
  param([string[]]$ScrcpyArgs, [string]$LogFile)
  # Suppressing the console also throws away everything scrcpy prints - the device it
  # picked, the renderer, the texture size. That output is genuinely useful, so when a
  # log file is asked for we capture both streams into it and the bar can show them on
  # demand. Start-Process pumps the redirected streams itself; doing it by hand from
  # inside a WinForms message loop is how you deadlock a child process.
  if ($LogFile) {
    try {
      return Start-Process -FilePath $SCRCPY -ArgumentList $ScrcpyArgs `
               -WorkingDirectory $TOOL -WindowStyle Hidden -PassThru `
               -RedirectStandardOutput $LogFile -RedirectStandardError "$LogFile.err" `
               -ErrorAction Stop
    } catch { }   # fall through to the plain launch
  }
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName         = $SCRCPY
  $psi.Arguments        = ($ScrcpyArgs -join ' ')
  $psi.WorkingDirectory = $TOOL          # so it finds scrcpy-server beside the exe
  $psi.UseShellExecute  = $false
  $psi.CreateNoWindow   = $true          # <- kills the stray console window
  return [System.Diagnostics.Process]::Start($psi)
}

# Path of the log for the most recent mirror session, so the menu can show what scrcpy
# printed. A floating toolbar over the mirror window was built and then removed: docked
# above the window it covered scrcpy's own title bar (minimise and close with it), and
# docked under the title bar - the correct place, where every application puts a toolbar
# - it covered the top of the picture, because that space belongs to scrcpy's client
# area. Trying to make room by disabling the aspect-ratio lock and growing the window
# did not help either: measured by sampling pixels, scrcpy stretches to fill rather than
# letterboxing, so there was no black band to hide in. A separate window stuck to
# another application's window never stopped reading as a sticker, so the menu stayed.
$script:lastLog = $null

function Start-Mirror {
  param([string]$Serial)
  $sargs = @('--stay-awake', '--window-title', '"Phone"')
  if ($Serial) { $sargs = @('-s', $Serial) + $sargs }
  $log = Join-Path $env:TEMP ('scrcpy-tray-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
  try {
    $p = Start-Scrcpy $sargs $log
    if ($null -eq $p) { return $false }
    $script:lastLog = $log
    return $true
  } catch { return $false }
}

# scrcpy prints the device it picked, the renderer and the texture size, and hiding its
# console throws all of that away. It is captured at launch instead, and this puts it
# back within reach: the real output, then a prompt in the scrcpy folder for anything
# this tool does not cover.
function Show-ScrcpyLog {
  if (-not $script:lastLog -or -not (Test-Path -LiteralPath $script:lastLog)) {
    $tray.ShowBalloonTip(3000, 'No log yet', 'Start mirroring first', 'Info'); return
  }
  try {
    $err = "$($script:lastLog).err"
    $cmd = "Set-Location -LiteralPath '$TOOL'; " +
           "Write-Host '--- scrcpy output for this session ---' -ForegroundColor Cyan; " +
           "Get-Content -LiteralPath '$($script:lastLog)'; " +
           "if (Test-Path -LiteralPath '$err') { Get-Content -LiteralPath '$err' }; " +
           "Write-Host ''; Write-Host '--- scrcpy folder; run it with any flags ---' -ForegroundColor DarkGray"
    Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') `
      -ArgumentList '-NoExit', '-NoProfile', '-Command', $cmd -WorkingDirectory $TOOL
  } catch {
    $tray.ShowBalloonTip(3000, 'Failed', 'Could not open the terminal', 'Error')
  }
}

# ─── recording ────────────────────────────────────────────────────────────────
# Recording is a toggle, and stopping it has to be GRACEFUL. scrcpy finalises the
# container (writes the moov atom) while shutting down; killing the process instead
# leaves an .mp4 that most players refuse to open. So: CloseMainWindow() sends WM_CLOSE
# the same way clicking the X does, and force-killing is only a last resort after the
# process ignored the polite request. That trade is the whole reason this is not a
# one-liner.
$script:rec = $null   # @{ Process; File; Serial; StartedAt }

function Test-Recording {
  if (-not $script:rec) { return $false }
  try {
    if ($script:rec.Process.HasExited) { $script:rec = $null; return $false }
    return $true
  } catch { $script:rec = $null; return $false }
}

function Start-Record {
  param([string]$Serial)
  if (Test-Recording) { return $null }
  if (-not (Ensure-ShotDir)) { return $null }
  $file = Join-Path $SHOTDIR ('phone-' + (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss') + '.mp4')
  $sargs = @('--record', "`"$file`"", '--stay-awake', '--window-title', '"Phone - recording"')
  if ($Serial) { $sargs = @('-s', $Serial) + $sargs }
  try {
    $proc = Start-Scrcpy $sargs
    if (-not $proc) { return $null }
    $script:rec = @{ Process = $proc; File = $file; Serial = $Serial; StartedAt = Get-Date }
    return $file
  } catch { return $null }
}

# Returns a status object so the caller can tell the truth about what happened,
# rather than assuming the file is fine because the click worked.
function Stop-Record {
  $r = [pscustomobject]@{ File = $null; Stopped = $false; Forced = $false; SizeKB = 0; Seconds = 0; Error = $null }
  if (-not (Test-Recording)) { $r.Error = 'not recording'; return $r }

  $proc = $script:rec.Process
  $r.File    = $script:rec.File
  $r.Seconds = [math]::Round(((Get-Date) - $script:rec.StartedAt).TotalSeconds)

  try {
    # WM_CLOSE - identical to the user clicking the window's X, so scrcpy finalises
    # the container on its way out.
    $null = $proc.CloseMainWindow()
    if (-not $proc.WaitForExit(8000)) {
      # It ignored the close. Force it and say so: the file may be unplayable.
      try { $proc.Kill(); $null = $proc.WaitForExit(3000) } catch { }
      $r.Forced = $true
    }
    $r.Stopped = $true
  } catch { $r.Error = $_.Exception.Message }

  $script:rec = $null

  # scrcpy flushes on exit; give the filesystem a beat before measuring.
  Start-Sleep -Milliseconds 400
  if ($r.File -and (Test-Path -LiteralPath $r.File)) {
    $r.SizeKB = [math]::Round((Get-Item -LiteralPath $r.File).Length / 1KB)
    if ($r.SizeKB -eq 0) { $r.Error = 'the recording file is empty' }
  } else {
    $r.Error = 'the recording file was not written'
  }
  return $r
}

function Announce-Record {
  param($Result)
  if (-not $Result.Stopped) {
    $tray.ShowBalloonTip(3000, 'Recording', $Result.Error, 'Warning'); return
  }
  if ($Result.Error) {
    $tray.ShowBalloonTip(4000, 'Recording problem', $Result.Error, 'Error'); return
  }
  $name = Split-Path $Result.File -Leaf
  if ($Result.Forced) {
    $tray.ShowBalloonTip(5000, 'Recording force-stopped',
      "$name - $($Result.SizeKB) KB. scrcpy ignored the close request, so the file may not play.", 'Warning')
  } else {
    $tray.ShowBalloonTip(3000, 'Recording saved', "$name - $($Result.Seconds)s, $($Result.SizeKB) KB", 'Info')
  }
}

# Pull a frame with `exec-out screencap -p`. exec-out (not `shell`) is required:
# `adb shell` mangles the binary stream with CRLF translation and corrupts the PNG.
#
# F3: returns a STATUS object and verifies each step. The old version returned the
# filename unconditionally, so the caller announced "Print copiado" even when the
# file was never written and the clipboard was never touched.
function Save-Screenshot {
  param([string]$Serial)
  $r = [pscustomobject]@{ File = $null; Saved = $false; Clipboard = $false; Error = $null }

  if (-not (Ensure-ShotDir)) { $r.Error = 'Could not create the screenshots folder'; return $r }

  $a = @()
  if ($Serial) { $a += @('-s', $Serial) }
  $a += @('exec-out', 'screencap', '-p')
  $bytes = Invoke-CapturedBytes $ADB $a
  if ($null -eq $bytes) { $r.Error = 'adb did not respond (timeout)'; return $r }
  if ($bytes.Length -lt 1024) { $r.Error = "Response too small ($($bytes.Length) bytes)"; return $r }
  # A PNG starts with 89 50 4E 47. Anything else is an adb error message, not an image.
  if (-not ($bytes[0] -eq 0x89 -and $bytes[1] -eq 0x50 -and $bytes[2] -eq 0x4E -and $bytes[3] -eq 0x47)) {
    $r.Error = 'The device did not return a PNG'
    return $r
  }

  $file = Join-Path $SHOTDIR ('print-' + (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss') + '.png')
  try {
    [System.IO.File]::WriteAllBytes($file, $bytes)
    $r.File = $file
    $r.Saved = $true
  } catch { $r.Error = "Failed to save: $($_.Exception.Message)"; return $r }

  # Clipboard is the whole point of the feature, so its failure must surface.
  # SetImage throws ExternalException whenever another process holds the clipboard.
  try {
    $ms = New-Object System.IO.MemoryStream(,$bytes)
    $img = [System.Drawing.Image]::FromStream($ms)
    [System.Windows.Forms.Clipboard]::SetImage($img)
    $img.Dispose()
    $ms.Dispose()
    $r.Clipboard = $true
  } catch {
    $r.Error = "Saved, but did not copy: $($_.Exception.Message)"
  }
  return $r
}

function Announce-Screenshot {
  param($Result)
  if ($Result.Saved -and $Result.Clipboard) {
    $tray.ShowBalloonTip(2500, 'Screenshot copied', (Split-Path $Result.File -Leaf), 'Info')
  } elseif ($Result.Saved) {
    $tray.ShowBalloonTip(4000, 'Screenshot saved (clipboard failed)', $Result.Error, 'Warning')
  } else {
    $tray.ShowBalloonTip(4000, 'Screenshot failed', $Result.Error, 'Error')
  }
}

# ─── tray plumbing ───────────────────────────────────────────────────────────
$icon = $null
try {
  $png = Join-Path $TOOL 'icon.png'
  if (Test-Path $png) {
    $bmp = New-Object System.Drawing.Bitmap $png
    $icon = [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
  }
} catch { $icon = $null }
if (-not $icon) { try { $icon = [System.Drawing.Icon]::ExtractAssociatedIcon($SCRCPY) } catch { } }
# F7: a null icon yields a tray entry with hIcon=0 — invisible, so the app looks dead.
if (-not $icon) { $icon = [System.Drawing.SystemIcons]::Application }

$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Icon = $icon
$tray.Visible = $false
$tray.Text = 'Phone'

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$tray.ContextMenuStrip = $menu

$script:lastKey     = ''
$script:lastKind    = 'none'   # none | usable | attention
$script:soloSerial  = ''

function Add-MenuItem {
  param([string]$Text, [scriptblock]$OnClick, [switch]$Bold)
  $mi = New-Object System.Windows.Forms.ToolStripMenuItem
  $mi.Text = $Text
  if ($Bold) { $mi.Font = New-Object System.Drawing.Font($menu.Font, [System.Drawing.FontStyle]::Bold) }
  if ($OnClick) { $mi.add_Click($OnClick) } else { $mi.Enabled = $false }
  $menu.Items.Add($mi) | Out-Null
  return $mi
}

function Rebuild-Menu {
  param($Snapshot)
  $menu.Items.Clear()
  $devs   = @($Snapshot.Devices)
  $usable = @($devs | Where-Object { $_.State -eq 'device' })
  $other  = @($devs | Where-Object { $_.State -ne 'device' })

  if (-not $Snapshot.AdbOk) {
    Add-MenuItem 'adb did not respond - try Restart adb' $null | Out-Null
  }
  elseif ($usable.Count -eq 0 -and $other.Count -eq 0) {
    Add-MenuItem 'No device connected' $null | Out-Null
  }
  elseif ($usable.Count -eq 1) {
    # Assign BEFORE creating handlers that read it.
    $script:soloSerial = $usable[0].Serial
    Add-MenuItem 'Mirror screen' {
      if (-not (Start-Mirror $script:soloSerial)) {
        $tray.ShowBalloonTip(3000, 'Failed', 'Could not start scrcpy', 'Error')
      }
    } -Bold | Out-Null
    Add-MenuItem 'Screenshot now (save + copy)' { Announce-Screenshot (Save-Screenshot $script:soloSerial) } | Out-Null
    Add-MenuItem 'Screenshot and open' {
      $res = Save-Screenshot $script:soloSerial
      Announce-Screenshot $res
      if ($res.Saved) { Start-Process $res.File }
    } | Out-Null
    # Recording is a toggle: the same slot starts and stops it, so one click each way.
    if (Test-Recording) {
      $elapsed = [math]::Round(((Get-Date) - $script:rec.StartedAt).TotalSeconds)
      Add-MenuItem ("Stop recording  ({0}s)" -f $elapsed) { Announce-Record (Stop-Record) } -Bold | Out-Null
    } else {
      Add-MenuItem 'Record screen' {
        $f = Start-Record $script:soloSerial
        if ($f) { $tray.ShowBalloonTip(2500, 'Recording', 'Click the tray icon menu again to stop', 'Info') }
        else { $tray.ShowBalloonTip(3000, 'Failed', 'Could not start recording', 'Error') }
      } | Out-Null
    }
  }
  elseif ($usable.Count -gt 1) {
    # More than one usable device: every action needs an explicit target.
    foreach ($d in $usable) {
      $sub = New-Object System.Windows.Forms.ToolStripMenuItem
      $sub.Text = (Format-DeviceLabel $d)
      $ser = $d.Serial
      $m1 = New-Object System.Windows.Forms.ToolStripMenuItem
      $m1.Text = 'Mirror screen'
      $m1.add_Click([scriptblock]::Create("Start-Mirror '$ser' | Out-Null"))
      $m2 = New-Object System.Windows.Forms.ToolStripMenuItem
      $m2.Text = 'Screenshot'
      $m2.add_Click([scriptblock]::Create("Announce-Screenshot (Save-Screenshot '$ser')"))
      $sub.DropDownItems.AddRange(@($m1, $m2))
      $menu.Items.Add($sub) | Out-Null
    }
  }

  # F2: states that are not `device` get their own explained row instead of silence.
  foreach ($d in $other) {
    $hint = switch ($d.State) {
      'unauthorized'   { 'authorise USB debugging on the phone screen' }
      'authorizing'    { 'waiting for authorisation...' }
      'offline'        { 'offline - replug the cable, or adb disconnect if over Wi-Fi' }
      'no permissions' { 'no USB permission - restart adb' }
      default          { "state: $($d.State)" }
    }
    Add-MenuItem ("$(Format-DeviceLabel $d) - $hint") $null | Out-Null
  }

  $menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null
  # F8: create the folder instead of doing nothing when it does not exist yet.
  Add-MenuItem 'Open screenshots folder' {
    if (Ensure-ShotDir) { Start-Process $SHOTDIR }
    else { $tray.ShowBalloonTip(3000, 'Failed', 'Could not create the folder', 'Error') }
  } | Out-Null
  Add-MenuItem 'Show scrcpy log / terminal' { Show-ScrcpyLog } | Out-Null
  Add-MenuItem 'Restart adb' {
    $a = Invoke-Captured $ADB @('kill-server')
    $b = Invoke-Captured $ADB @('start-server')
    if ($null -eq $b) { $tray.ShowBalloonTip(3500, 'adb', 'start-server did not respond', 'Warning') }
    else { $tray.ShowBalloonTip(2000, 'adb', 'Restarted', 'Info') }
    $script:lastKey = ''    # force a full re-evaluation on the next tick
    Refresh-State
  } | Out-Null
  $menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null
  Add-MenuItem 'Quit' { $tray.Visible = $false; [System.Windows.Forms.Application]::Exit() } | Out-Null
}

function Refresh-State {
  $snap   = Get-DeviceSnapshot
  $devs   = @($snap.Devices)
  $usable = @($devs | Where-Object { $_.State -eq 'device' })
  $other  = @($devs | Where-Object { $_.State -ne 'device' })

  $key = "adb=$($snap.AdbOk);" + (($devs | ForEach-Object { "$($_.Serial):$($_.State)" }) -join ',')
  if ($key -eq $script:lastKey) { return }

  $kind = if ($usable.Count -gt 0) { 'usable' }
          elseif ($other.Count -gt 0 -or -not $snap.AdbOk) { 'attention' }
          else { 'none' }

  Rebuild-Menu $snap

  if ($kind -eq 'usable') {
    $names = ($usable | ForEach-Object { if ($_.Model) { $_.Model } else { $_.Serial } }) -join ', '
    $t = "Phone: $names"
    # NotifyIcon.Text is capped at 63 chars by the shell.
    $tray.Text = if ($t.Length -gt 62) { $t.Substring(0, 62) } else { $t }
    $tray.Visible = $true
    # F10: announce on any transition INTO usable, including unauthorized -> device.
    # The old guard was `if (-not $tray.Visible)`, which suppressed exactly that case.
    if ($script:lastKind -ne 'usable') {
      $tray.ShowBalloonTip(2000, 'Phone connected', "$names - click to mirror", 'Info')
    }
  }
  elseif ($kind -eq 'attention') {
    $tray.Text = if (-not $snap.AdbOk) { 'Phone: adb did not respond' } else { 'Phone: needs attention' }
    $tray.Visible = $true
    if ($script:lastKind -ne 'attention') {
      $msg = if (-not $snap.AdbOk) { 'adb did not respond - use Restart adb' }
             else { ($other | ForEach-Object { "$(Format-DeviceLabel $_): $($_.State)" }) -join '; ' }
      $tray.ShowBalloonTip(4000, 'Device needs attention', $msg, 'Warning')
    }
  }
  else {
    # No device at all: disappear completely, as asked.
    $tray.Visible = $false
  }

  # F4: commit the change-detect key only AFTER the UI work it describes has run.
  # Committing first meant any failure above latched the state as "handled" and the
  # icon could never recover on later ticks.
  $script:lastKind = $kind
  $script:lastKey  = $key
}

# Left-click mirrors straight away; right-click gets the menu (WinForms default).
$tray.add_MouseClick({
  if ($_.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
    $u = Get-UsableDevices
    if ($u.Count -eq 1) {
      if (-not (Start-Mirror $u[0].Serial)) {
        $tray.ShowBalloonTip(3000, 'Failed', 'Could not start scrcpy', 'Error')
      }
    }
    elseif ($u.Count -gt 1) {
      $tray.ShowBalloonTip(2500, 'Multiple devices', 'Use the right-click menu', 'Info')
    }
    else {
      $tray.ShowBalloonTip(2500, 'No device ready', 'See the right-click menu', 'Warning')
      Refresh-State
    }
  }
})

# Rebuild on open, not just on device-state change. Refresh-State deliberately
# early-returns when nothing about the DEVICES changed, but the menu also reflects
# things it does not watch - recording running or not, and the elapsed counter. Without
# this the "Stop recording" entry would never appear. One adb call per menu open is
# cheap and buys a menu that is never stale.
$menu.add_Opening({
  try { Rebuild-Menu (Get-DeviceSnapshot) } catch { }
})

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = $POLL_MS
$timer.add_Tick({ Refresh-State })
$timer.Start()

# ─── fast path: WM_DEVICECHANGE ───────────────────────────────────────────────
# Deliberately NOT Register-WmiEvent: those -Action handlers only run when the
# PowerShell pipeline is idle, and Application.Run() keeps it busy forever, so the
# event would never fire. A hidden top-level window receives the DBT_DEVNODES_CHANGED
# broadcast through the WinForms message loop instead, which always pumps.
# (Audit confirmed this path works: BroadcastSystemMessage reaches the unshown form,
# and Application.Run() with no main form still pumps its messages.)
Add-Type -ReferencedAssemblies System.Windows.Forms -TypeDefinition @'
using System;
using System.Windows.Forms;

public class DeviceWatcherForm : Form {
    public event EventHandler DeviceChanged;
    protected override void WndProc(ref Message m) {
        if (m.Msg == 0x0219) {                 // WM_DEVICECHANGE
            EventHandler h = DeviceChanged;
            if (h != null) h(this, EventArgs.Empty);
        }
        base.WndProc(ref m);
    }
}
'@

$watcher = New-Object DeviceWatcherForm
$watcher.ShowInTaskbar = $false
$watcher.WindowState = [System.Windows.Forms.FormWindowState]::Minimized
$null = $watcher.Handle    # forces window creation without ever showing it

# USB enumeration is not finished when the message lands, and the broadcast repeats
# several times per plug event — so coalesce into one delayed re-check.
$debounce = New-Object System.Windows.Forms.Timer
$debounce.Interval = 1500
$debounce.add_Tick({ $debounce.Stop(); Refresh-State })
$watcher.add_DeviceChanged({ $debounce.Stop(); $debounce.Start() })

Refresh-State
[System.Windows.Forms.Application]::Run()

$timer.Stop()
$debounce.Stop()
$tray.Visible = $false
$tray.Dispose()
$watcher.Dispose()
try { $script:mutex.ReleaseMutex() } catch { }
$script:mutex.Dispose()
