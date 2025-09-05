@echo off
:: Verifica se está sendo executado como administrador
>nul 2>&1 "%SYSTEMROOT%\system32\cacls.exe" "%SYSTEMROOT%\system32\config\system"
if '%errorlevel%' NEQ '0' (
    echo Solicitando permissões de administrador...
    powershell -Command "Start-Process '%~f0' -Verb runAs"
    exit /b
)

:: Caminho do Python (ajuste se necessário)
set PYTHON_PATH=python

:: Caminho do script na mesma pasta do .bat
set SCRIPT_PATH=%~dp0script.py

:: Executa o script Python
%PYTHON_PATH% "%SCRIPT_PATH%"

pause
