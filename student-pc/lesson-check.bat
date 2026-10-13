@echo off
rem Lesson check: diagnostics and safe fixes for camera, microphone, sound and internet.
rem Run this file from the extracted folder (not from inside the ZIP).
cd /d "%~dp0"
if not exist "%~dp0lesson-check.ps1" (
  echo lesson-check.ps1 not found next to this file.
  echo Extract the ZIP first: right-click - Extract All, then run lesson-check.bat from that folder.
  echo.
  pause
  exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0lesson-check.ps1" %*
echo.
pause
