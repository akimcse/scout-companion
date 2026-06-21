@echo off
REM Launches Scout Companion in a single-threaded-apartment PowerShell host (required for WPF).
REM Double-click this file to start, or run it from a shortcut on startup.
start "" /min powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0scout-companion.ps1"
