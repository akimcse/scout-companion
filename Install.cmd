@echo off
REM Double-click installer.
REM
REM Install.ps1 has to be launched with -ExecutionPolicy Bypass, and typing that
REM out is the last thing standing between "I downloaded it" and "it runs".
REM This is that command, so the zip can be installed by double-clicking.
setlocal
cd /d "%~dp0"

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install.ps1" -Run
set RC=%ERRORLEVEL%

REM Hold the window open on failure only. A successful install has already said
REM what it did, and a console that lingers after a double-click reads as
REM "something went wrong".
if not "%RC%"=="0" (
  echo.
  echo Install failed with code %RC%.
  echo.
  pause
)
exit /b %RC%
