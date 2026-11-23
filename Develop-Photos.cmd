@echo off
setlocal EnableExtensions DisableDelayedExpansion
set "interpreter=%~dp0.venv\Scripts\python.exe"
set "version="
if exist "%interpreter%" goto run
set "interpreter=py"
set "version=-3"
where py >nul 2>nul
if not errorlevel 1 goto run
set "interpreter=python"
set "version="
:run
"%interpreter%" %version% -B "%~dp0tools\develop_photos.py" %*
set "result=%errorlevel%"
if not "%result%"=="0" pause
exit /b %result%
