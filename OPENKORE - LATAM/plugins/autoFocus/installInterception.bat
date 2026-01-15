@echo off
setlocal
set "DIR=%~dp0Interception"
if not exist "%DIR%\install-interception.exe" (
  echo Nao achei: %DIR%\install-interception.exe
  pause
  exit /b 1
)
echo Solicitando privilegios de Administrador...
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "Start-Process -FilePath '%DIR%\install-interception.exe' -ArgumentList '/install' -Verb RunAs -Wait"
echo .
echo Se nao apareceu erro, reinicie o Windows para ativar o driver.
pause
