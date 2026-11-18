@echo off
setlocal
chcp 65001 >nul
set "PYTHONUTF8=1"
set "PYTHONIOENCODING=utf-8"
set "RESEARCH_PY=%~dp0..\.runtime\python.exe"
if exist "%RESEARCH_PY%" goto run
set "RESEARCH_PY=%~dp0..\..\stock-research.runtime\python.exe"
if not exist "%RESEARCH_PY%" goto missing
:run
if "%~1"=="" (
  "%RESEARCH_PY%" -B -u -X utf8 "%~dp0tools\transfer.py" serve
  pause
) else (
  "%RESEARCH_PY%" -B -u -X utf8 "%~dp0tools\transfer.py" %*
)
exit /b %errorlevel%
:missing
echo Please run tools\transfer.py with Python 3.12 or the original project runtime.
pause
exit /b 1
