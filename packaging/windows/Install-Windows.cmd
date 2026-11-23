@echo off
setlocal
set "installer=%~dp0tools\install_runtime.py"
if not exist "%installer%" set "installer=%~dp0..\..\tools\install_runtime.py"
where py >nul 2>nul
if errorlevel 1 goto use_python
py -3 -B "%installer%" --archives "%~dp0." %*
goto done
:use_python
python -B "%installer%" --archives "%~dp0." %*
:done
set "result=%errorlevel%"
if not "%result%"=="0" pause
exit /b %result%
