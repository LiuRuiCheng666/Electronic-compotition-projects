@echo off
chcp 65001 >nul
cd /d "%~dp0"
if defined YIZHEN_PYTHON (
  "%YIZHEN_PYTHON%" -X utf8 server.py
) else (
  py -3 -X utf8 server.py
)
if errorlevel 1 pause
