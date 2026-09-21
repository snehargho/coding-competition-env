@echo off
rem NexGen Coding Competition 2026 - Windows setup (entry point).
rem This wrapper runs setup.ps1, the actual engine, with execution policy
rem bypassed for this process only. Safe to run twice. No admin needed.
setlocal
title NexGen Setup

set "PSEXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PSEXE%" (
    echo Windows PowerShell was not found. This script needs Windows 10 or 11.
    pause
    exit /b 1
)
if not exist "%~dp0setup.ps1" (
    echo setup.ps1 was not found next to setup.bat. Download the full folder.
    pause
    exit /b 1
)

echo ============================================================
echo   NexGen Coding Competition - environment setup
echo   Installs / verifies: gcc, make, Python 3, pip, and the
echo   Python libraries used in the rounds.
echo   Nothing needs administrator rights. It is safe to run
echo   this again if something failed the first time.
echo ============================================================
echo.

"%PSEXE%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup.ps1" %*
set "RC=%ERRORLEVEL%"

echo.
if "%RC%"=="0" (
    echo Setup finished: all required checks passed.
) else (
    echo Setup finished with issues. Open setup-report.txt next to this
    echo script and show it to an invigilator.
)
echo.
pause
exit /b %RC%
