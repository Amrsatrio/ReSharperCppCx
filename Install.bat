@echo off
setlocal

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install.ps1" %*
set "EXIT_CODE=%ERRORLEVEL%"

if "%~1"=="" pause
exit /b %EXIT_CODE%
