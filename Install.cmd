@echo off
setlocal EnableExtensions
rem ============================================================================
rem  Fast installer launcher for Archive Password Extractor (extended)
rem
rem  What it does:
rem    1. Changes to the directory this file lives in.
rem    2. Runs the installer with the execution policy bypassed for THIS
rem       process only (nothing is changed machine-wide or for other sessions).
rem    3. Prefers PowerShell 7+ (pwsh) when available, otherwise falls back to
rem       the built-in Windows PowerShell.
rem
rem  Usage:
rem    Double-click this file, or run it from a terminal. Any extra arguments
rem    are forwarded to Install-ArchivePwExtract.ps1, e.g.:
rem        Install.cmd -SomeParameter Value
rem ============================================================================

title Archive Password Extractor - Installer

rem --- 1. cd to the script directory ------------------------------------------
cd /d "%~dp0"

set "INSTALLER=%~dp0Install-ArchivePwExtract.ps1"

if not exist "%INSTALLER%" (
    echo [ERROR] Could not find Install-ArchivePwExtract.ps1 next to this launcher.
    echo         Expected: "%INSTALLER%"
    echo.
    pause
    exit /b 1
)

rem --- 2/3. set session-only execution-policy bypass and run the installer -----
where pwsh >nul 2>nul
if %errorlevel%==0 (
    echo Using PowerShell 7+ ^(pwsh^)...
    pwsh -NoProfile -ExecutionPolicy Bypass -File "%INSTALLER%" %*
) else (
    echo PowerShell 7 not found, using Windows PowerShell...
    powershell -NoProfile -ExecutionPolicy Bypass -File "%INSTALLER%" %*
)

set "RC=%errorlevel%"
echo.
if not "%RC%"=="0" (
    echo Installer exited with code %RC%.
) else (
    echo Done.
)
echo.
pause
endlocal & exit /b %RC%
