@echo off
setlocal enableextensions

:: Checa admin (sem usar cacls)
net session >nul 2>&1
if %errorlevel% neq 0 (
  echo Solicitando permissões de administrador...
  powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)

:: Caminhos
set "PYTHON_PATH=python"
set "SCRIPT_PATH=%~dp0start.py"

:: Executa e propaga código de saída do Python
"%PYTHON_PATH%" "%SCRIPT_PATH%"
exit /b %errorlevel%
