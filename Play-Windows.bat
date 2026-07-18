@echo off
rem Pokemon Red (LOVE2D) - double-click launcher for Windows.
rem First run: decodes a user-provided .gb and installs Python/LOVE if needed,
rem builds the game data, then launches. Later runs: launches straight away.
title Pokemon Red - LOVE2D port
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "scripts\bootstrap.ps1"
if errorlevel 1 (
  echo.
  echo Something went wrong - see the messages above.
  pause
)
