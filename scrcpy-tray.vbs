' Launches the scrcpy tray with no console window.
' Windows PowerShell 5.1 on purpose: it defaults to STA, which WinForms and
' Clipboard.SetImage both require. pwsh 7 defaults to MTA and breaks the clipboard.
Option Explicit
Dim sh, here, ps, cmd
Set sh = CreateObject("WScript.Shell")
here = Left(WScript.ScriptFullName, InStrRev(WScript.ScriptFullName, "\"))
ps = "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"
cmd = """" & ps & """ -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File """ & here & "scrcpy-tray.ps1"""
' 0 = hidden window, False = do not wait
sh.Run cmd, 0, False
