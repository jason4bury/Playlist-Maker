@echo off
rem Playlist Maker - double-click to start it.
rem Each time, this makes (or refreshes) the Playlist Maker shortcut in this folder and in the Start menu,
rem then starts Playlist Maker from it. After the first run you can use the shortcut, the Start menu or
rem a pinned taskbar button instead: they start Playlist Maker without a console window.
rem The execution-policy bypass applies to Playlist Maker's own run only; no Windows settings are changed.
rem If Playlist Maker doesn't open, run   "Playlist Maker.cmd" debug   to start it in this window and see any errors.
setlocal
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if /i "%~1"=="debug" (
    "%PS%" -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0Playlist-Maker.ps1"
    pause
    exit /b
)
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0New-PlaylistMakerShortcut.ps1" -Launch
if errorlevel 1 pause
