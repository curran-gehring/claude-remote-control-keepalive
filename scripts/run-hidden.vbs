' Runs a PowerShell script fully hidden (no console-window flash).
' Task Scheduler's "Hidden" checkbox still flashes a window with powershell.exe;
' launching through wscript with WindowStyle=0 does not.
' Usage: wscript.exe run-hidden.vbs "<full path to .ps1>"
Option Explicit
Dim shell
If WScript.Arguments.Count < 1 Then WScript.Quit 2
Set shell = CreateObject("WScript.Shell")
shell.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -File """ & WScript.Arguments(0) & """", 0, False
