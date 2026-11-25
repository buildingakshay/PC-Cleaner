@echo off
title PC Cleaner
cd /d "%~dp0"
:menu
cls
echo ==========================================
echo              PC CLEANER
echo ==========================================
echo  1. Scan only (safe, deletes nothing)
echo  2. Clean (asks before each step)
echo  3. Clean as Administrator (also cleans Windows folders)
echo  4. Exit
echo.
set /p choice=Pick 1-4:
if "%choice%"=="1" powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0PCCleaner.ps1" & pause & goto menu
if "%choice%"=="2" powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0PCCleaner.ps1" -Clean & pause & goto menu
if "%choice%"=="3" powershell -NoProfile -Command "Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile -ExecutionPolicy Bypass -NoExit -File \"%~dp0PCCleaner.ps1\" -Clean'" & goto menu
if "%choice%"=="4" exit /b
goto menu
