@echo off

:: Enable delayed expansion for real-time variable updates inside loops
setlocal enabledelayedexpansion

:: Save current cwd
set "CURRENT_CWD=%cd%"

REM This script starts the CLIENT with a specified account configuration.
if "%~1"=="" (
    REM Create PowerShell menu script
    (
        echo $path = 'accounts'
        echo $files = Get-ChildItem -Path $path -Filter *.txt
        echo if ^($files.Count -eq 0^) { Write-Host "No accounts found."; Start-Sleep 2; exit 1 }
        echo $selection = 0
        echo while ^($true^) {
        echo     Clear-Host
        echo     Write-Host "Select an account (Use Up/Down arrows and Enter):" -ForegroundColor Cyan
        echo     for ^($i=0; $i -lt $files.Count; $i++^) {
        echo         if ^($i -eq $selection^) {
        echo             Write-Host "^> $($files[$i].BaseName)" -ForegroundColor Green
        echo         } else {
        echo             Write-Host "  $($files[$i].BaseName)"
        echo         }
        echo     }
        echo     $key = $host.UI.RawUI.ReadKey^('NoEcho,IncludeKeyDown'^)
        echo     if ^($key.VirtualKeyCode -eq 38^) { 
        echo         $selection--
        echo         if ^($selection -lt 0^) { $selection = $files.Count - 1 } 
        echo     } elseif ^($key.VirtualKeyCode -eq 40^) { 
        echo         $selection++
        echo         if ^($selection -ge $files.Count^) { $selection = 0 } 
        echo     } elseif ^($key.VirtualKeyCode -eq 13^) { 
        echo         [IO.File]::WriteAllText^('selected_account.tmp', $files[$selection].BaseName^)
        echo         exit 0
        echo     }
        echo }
    ) > menu.ps1

    REM Run menu
    powershell -ExecutionPolicy Bypass -File menu.ps1
    
    REM Read selection
    if exist selected_account.tmp (
        set /p account=<selected_account.tmp
        del selected_account.tmp
    )
    if exist menu.ps1 del menu.ps1
) else (
    set account=%~1
)

REM If account is empty, throw error and exit
if "%account%"=="" (
    echo No account specified. Exiting...
    exit /b
)

REM If account is a number, format account file
if "%account:~0,1%" geq "0" if "%account:~0,1%" leq "9" (
    set account_file=accounts\account%account%.txt
) else (
    set account_file=accounts\%account%.txt
)

REM If account not exist, throw error and exit
if not exist "%account_file%" (
    echo Account file "%account_file%" does not exist.
    exit /b
)

:: Load 'config.ini'
for /f "tokens=1,2 delims==" %%a in (config.ini) do (
    if %%a==GAME_FOLDER set GAME_FOLDER=%%b
    if %%a==GAME_EXE set GAME_EXE=%%b
    if %%a==GAME_ARG set GAME_ARG=%%b
)

:: Load 'account.txt'
for /f "usebackq tokens=1,* delims= " %%a in ("%account_file%") do (
    if /i "%%a"=="username"         set "RO_USERNAME=%%b"
    if /i "%%a"=="password"         set "RO_PASSWORD=%%b"
    if /i "%%a"=="char"             set "RO_CHAR=%%b"
    if /i "%%a"=="XKore_listenIp"   set "OPENKORE_HOST=%%b"
    if /i "%%a"=="XKore_port"       set "OPENKORE_PORT=%%b"
)

:: Set game server
set RO_SERVER=0

:: Set game cwd
cd /d %GAME_FOLDER%

:: Run game exe
for /f %%p in ('powershell -nologo -command "Start-Process -FilePath '%GAME_EXE%' -ArgumentList '%GAME_ARG%' -PassThru | Select-Object -ExpandProperty Id"') do (
    set "GAME_PID=%%p"
)

:: Set openkore cwd
cd /d %CURRENT_CWD%

:: Run openkore perl
perl openkore.pl --config="%account_file%"

:: Kill game process
taskkill /PID %GAME_PID% /F
