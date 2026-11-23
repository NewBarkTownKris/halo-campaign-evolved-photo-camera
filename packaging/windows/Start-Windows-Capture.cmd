@echo off
setlocal
where py >nul 2>nul
if errorlevel 1 goto use_python
py -3 -B "%~dp0capture_windows.py"
goto done
:use_python
python -B "%~dp0capture_windows.py"
:done
set "result=%errorlevel%"
if not "%result%"=="0" pause
exit /b %result%
