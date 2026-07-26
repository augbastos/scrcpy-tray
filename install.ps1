# scrcpy-tray installer.
#
# Creates a Startup shortcut so the tray comes back after a reboot, then launches it.
# Deliberately does NOT need administrator: everything it touches is per-user.
#
#   .\install.ps1              install and start
#   .\install.ps1 -Uninstall   remove the shortcut and stop the tray

[CmdletBinding()]
param(
  [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'

$here      = $PSScriptRoot
$vbs       = Join-Path $here 'scrcpy-tray.vbs'
$ps1       = Join-Path $here 'scrcpy-tray.ps1'
$startup   = [Environment]::GetFolderPath('Startup')
$shortcut  = Join-Path $startup 'scrcpy-tray.lnk'

function Stop-Tray {
  $procs = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
           Where-Object { $_.CommandLine -like '*scrcpy-tray.ps1*' }
  foreach ($p in $procs) {
    try { Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop; Write-Host "  stopped pid $($p.ProcessId)" }
    catch { Write-Warning "  could not stop pid $($p.ProcessId): $($_.Exception.Message)" }
  }
  return @($procs).Count
}

if ($Uninstall) {
  Write-Host 'Uninstalling scrcpy-tray...' -ForegroundColor Cyan
  if (Test-Path -LiteralPath $shortcut) {
    Remove-Item -LiteralPath $shortcut -Force
    Write-Host "  removed $shortcut"
  } else {
    Write-Host '  no startup shortcut found'
  }
  $n = Stop-Tray
  if ($n -eq 0) { Write-Host '  tray was not running' }
  Write-Host 'Done. Nothing else was installed, so nothing else to remove.' -ForegroundColor Green
  return
}

Write-Host 'Installing scrcpy-tray...' -ForegroundColor Cyan

foreach ($f in @($vbs, $ps1)) {
  if (-not (Test-Path -LiteralPath $f)) { throw "Missing file: $f — run this from inside the cloned repo." }
}

# Fail early with a useful message rather than letting the tray pop an error box at boot.
$scrcpy = $null
if ($env:SCRCPY_HOME -and (Test-Path -LiteralPath (Join-Path $env:SCRCPY_HOME 'scrcpy.exe'))) {
  $scrcpy = Join-Path $env:SCRCPY_HOME 'scrcpy.exe'
} else {
  $cmd = Get-Command 'scrcpy.exe' -ErrorAction SilentlyContinue
  if ($cmd) { $scrcpy = $cmd.Source }
  else {
    foreach ($root in @(
        (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages'),
        (Join-Path $env:USERPROFILE 'scoop\apps\scrcpy\current'),
        'C:\ProgramData\chocolatey\lib\scrcpy\tools',
        (Join-Path $env:ProgramFiles 'scrcpy'),
        (Join-Path $env:USERPROFILE 'Tools\scrcpy'))) {
      if (-not (Test-Path -LiteralPath $root)) { continue }
      $hit = Get-ChildItem -LiteralPath $root -Filter 'scrcpy.exe' -Recurse -File -ErrorAction SilentlyContinue |
             Select-Object -First 1
      if ($hit) { $scrcpy = $hit.FullName; break }
    }
  }
}

if ($scrcpy) {
  Write-Host "  found scrcpy: $scrcpy"
  try { Write-Host "  $(& $scrcpy --version 2>&1 | Select-Object -First 1)" } catch { }
} else {
  Write-Warning '  scrcpy.exe not found.'
  Write-Warning '  Install it first:  winget install Genymobile.scrcpy'
  Write-Warning '  Or point SCRCPY_HOME at your install:  setx SCRCPY_HOME "C:\path\to\scrcpy"'
  Write-Warning '  Continuing anyway — the tray will tell you the same thing when it starts.'
}

Stop-Tray | Out-Null

$sh  = New-Object -ComObject WScript.Shell
$lnk = $sh.CreateShortcut($shortcut)
$lnk.TargetPath       = 'wscript.exe'
$lnk.Arguments        = '"{0}"' -f $vbs
$lnk.WorkingDirectory = $here
$lnk.Description      = 'scrcpy-tray - Android device in the Windows tray'
if ($scrcpy) { $lnk.IconLocation = "$scrcpy,0" }
$lnk.Save()
Write-Host "  startup shortcut: $shortcut"

Start-Process wscript.exe -ArgumentList ('"{0}"' -f $vbs) -WindowStyle Hidden
Start-Sleep -Seconds 3

$running = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -like '*scrcpy-tray.ps1*' })
if ($running.Count -gt 0) {
  Write-Host "  running (pid $($running[0].ProcessId))"
  Write-Host ''
  Write-Host 'Installed. Plug in an Android phone and the icon will appear in the tray.' -ForegroundColor Green
  Write-Host 'No icon while nothing is connected - that is the intended behaviour.' -ForegroundColor DarkGray
} else {
  Write-Warning '  the tray did not stay running.'
  Write-Warning '  Run it in the foreground to see the error:'
  Write-Warning "    powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File `"$ps1`""
}
