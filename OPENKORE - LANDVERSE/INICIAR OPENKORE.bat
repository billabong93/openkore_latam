@echo off

:: Enable delayed expansion for real-time variable updates inside loops
setlocal enabledelayedexpansion

:: Save current cwd
set "CURRENT_CWD=%cd%"

:ASK_PORT
set /p OPENKORE_PORT="Enter OpenKore Port (2350, 2351, 2352): "
if "%OPENKORE_PORT%"=="2350" goto PORT_SET
if "%OPENKORE_PORT%"=="2351" goto PORT_SET
if "%OPENKORE_PORT%"=="2352" goto PORT_SET
echo Invalid port. Please enter 2350, 2351, or 2352.
goto ASK_PORT

:PORT_SET

:: Load 'config.ini'
for /f "tokens=1,2 delims==" %%a in (config.ini) do (
    if %%a==GAME_FOLDER set GAME_FOLDER=%%b
    if %%a==GAME_EXE set GAME_EXE=%%b
    if %%a==GAME_ARG set GAME_ARG=%%b
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
perl openkore.pl

:: Kill game process
taskkill /PID %GAME_PID% /F