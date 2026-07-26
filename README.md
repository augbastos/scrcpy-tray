# scrcpy-tray

Your Android phone appears in the Windows tray the moment you plug it in. Click the
icon to mirror the screen. Right-click to grab a screenshot straight to your clipboard.

No device connected, no icon — the tray stays empty until there is actually something
to click.

> Not an official Genymobile project, and not affiliated with it. This is a small
> third-party companion that drives [scrcpy](https://github.com/Genymobile/scrcpy)
> and `adb` from the outside.

## Why this exists

scrcpy is excellent, and it is deliberately a one-shot command-line tool: you run it,
it mirrors, it exits. Two things sit just outside that scope:

- **Launching it when a device shows up.** scrcpy's author solved this himself with
  [autoadb](https://github.com/rom1v/autoadb) — a separate Rust tool that runs a command
  whenever a device connects (`autoadb scrcpy -s {}`). Its last release was in May 2022,
  and its Windows binaries were published marked "untested" by the author.
- **Taking a screenshot.** scrcpy has no single-frame capture option at all. The usual
  answer is to mirror the screen and then screenshot the mirror window, which costs you
  resolution and picks up the window chrome.

scrcpy-tray covers both, natively on Windows: it watches for the device, and it pulls
screenshots straight off the phone with `adb exec-out screencap -p` — full device
resolution, no window in the way, straight onto the clipboard.

If you are on Linux or macOS, use **autoadb** — it is cross-platform and it is by the
person who actually maintains scrcpy.

## What it does

| | |
|---|---|
| **Invisible when idle** | No icon at all while no device is connected |
| **Appears on plug** | Reacts to `WM_DEVICECHANGE`, so it shows up as the device enumerates |
| **Left-click** | Mirror the screen via scrcpy |
| **Screenshot now** | Full-resolution PNG off the device → saved *and* on the clipboard |
| **Record screen** | `scrcpy --record` into your Pictures folder |
| **Explains problems** | `unauthorized`, `offline`, `authorizing` and "adb didn't answer" each get their own message instead of silently looking like "no phone" |
| **One instance** | Named mutex, so the startup shortcut plus a manual launch can't give you two icons |

Screenshots and recordings go to `<Pictures>\Phone\`, resolved through the real shell
folder — so if your Pictures is OneDrive-redirected, they land where you actually look
and get backed up with everything else.

## Requirements

- Windows 10 or 11
- Windows PowerShell 5.1 (ships with Windows — **not** PowerShell 7, see below)
- [scrcpy](https://github.com/Genymobile/scrcpy) and `adb`, installed separately

**Nothing is bundled.** scrcpy and adb are separate projects with their own licences and
release cadence; shipping copies would mean redistributing someone else's binaries and
pinning you to whatever version happened to be current when this was packaged.

```powershell
winget install Genymobile.scrcpy
```

## Install

```powershell
git clone https://github.com/augbastos/scrcpy-tray.git
cd scrcpy-tray
.\install.ps1
```

`install.ps1` finds your scrcpy, creates a Startup shortcut so the tray comes back after
a reboot, and launches it. Run `.\install.ps1 -Uninstall` to undo it.

To run it once without installing:

```powershell
wscript.exe scrcpy-tray.vbs
```

### If it can't find scrcpy

It looks, in order: `$env:SCRCPY_HOME`, its own folder, `PATH`, then the usual winget /
scoop / chocolatey locations. If yours lives somewhere unusual:

```powershell
setx SCRCPY_HOME "C:\path\to\scrcpy"
```

**adb is resolved next to scrcpy first, on purpose.** scrcpy ships the adb it was tested
against; picking a different adb off your `PATH` (an Android SDK platform-tools, say) is
what produces `adb server version doesn't match this client` — the first entry in
scrcpy's own FAQ.

## Why PowerShell 5.1 and not 7

Windows PowerShell 5.1 defaults to a single-threaded apartment (STA). WinForms and
`Clipboard.SetImage` both require it. PowerShell 7 defaults to MTA and the clipboard
write fails. The launcher pins 5.1 deliberately — this is not an oversight.

## What is verified, and what is not

Being straight about this, because "works on my machine" is not a test matrix.

**Verified:** the script parses and runs under PowerShell 5.1; the icon stays hidden with
no device attached; the single-instance mutex rejects a second launch; every scrcpy flag
used (`-s`, `--stay-awake`, `--window-title`, `--record`) exists in scrcpy 4.1; the
scrcpy/adb discovery finds a real install.

**Not yet verified:** the device-attached paths — mirroring, screenshot capture, the
clipboard write, recording, multi-device selection, and unplugging mid-session. They are
written and reviewed but have not been exercised against a physical phone in CI.

Bug reports with your Windows version, scrcpy version and phone model are welcome.

## Known limitations

- Windows only. The tray, the device-change hook and the clipboard are all Win32.
- The fast path is `WM_DEVICECHANGE`; a 15-second poll is the backstop. Worst case, a
  device takes up to 15 seconds to appear.
- Wireless (`adb connect`) targets stay listed as `offline` until `adb disconnect`. They
  are shown with that state rather than hidden, but they cannot be mirrored while offline.
- Recording stops when you close the scrcpy window; there is no stop button in the menu.

## Prior art

- **[autoadb](https://github.com/rom1v/autoadb)** by rom1v (scrcpy's author) — runs any
  command on device connect, cross-platform, Rust. The direct ancestor of the idea here.
  scrcpy-tray was written independently; autoadb publishes no licence, so no code from it
  was read or reused.
- **scrcpy issues [#352](https://github.com/Genymobile/scrcpy/issues/352) and
  [#694](https://github.com/Genymobile/scrcpy/issues/694)** — the long-running requests
  for autorun-on-plug that led to autoadb.

## Licence

MIT — see [LICENSE](LICENSE).

scrcpy is Apache-2.0 and belongs to Genymobile; adb is part of the Android SDK
platform-tools. Neither is redistributed here.
