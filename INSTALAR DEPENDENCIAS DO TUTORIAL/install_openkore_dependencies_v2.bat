@echo off
:: ============================================================================
:: INSTALADOR DE DEPENDÊNCIAS - OpenKore/BypassIP
:: Versão 2.0 - Ultra Robusta - NÃO FECHA SOZINHO
:: Autor: DMCore - Douglas
:: ============================================================================

setlocal enabledelayedexpansion
chcp 65001 >nul
color 0B
title Instalador OpenKore - Em Execucao

:: PROTEÇÃO CONTRA FECHAMENTO - Captura qualquer erro
set "ERROR_OCCURRED=0"

:: Handler de erro customizado
if not "%1"=="CHILD" (
    echo Iniciando instalador em modo protegido...
    "%~f0" CHILD
    set "EXIT_CODE=%ERRORLEVEL%"
    echo.
    echo ════════════════════════════════════════════════════════════════════
    echo Script finalizado com codigo: %EXIT_CODE%
    echo ════════════════════════════════════════════════════════════════════
    echo.
    echo Pressione qualquer tecla para fechar...
    pause >nul
    exit /b %EXIT_CODE%
)

cls
echo.
echo ╔════════════════════════════════════════════════════════════════════╗
echo ║  INSTALADOR OpenKore/BypassIP - v2.0                              ║
echo ║  DMCore - Douglas                                                  ║
echo ╚════════════════════════════════════════════════════════════════════╝
echo.

:: ============================================================================
:: VERIFICAÇÃO DE PRIVILÉGIOS
:: ============================================================================
echo [1/10] Verificando privilegios...

net session >nul 2>&1
if errorlevel 1 (
    color 0C
    echo.
    echo [ERRO] Precisa executar como ADMINISTRADOR!
    echo.
    echo Clique com botao direito e "Executar como administrador"
    echo.
    pause
    exit /b 1
)

echo        [OK] Administrador confirmado
echo.

:: ============================================================================
:: DEFINIÇÃO DE VARIÁVEIS
:: ============================================================================
echo [2/10] Configurando variaveis...

set "SCRIPT_DIR=%~dp0"
set "DOWNLOADS_DIR=%SCRIPT_DIR%downloads"
set "PERL_INSTALLER=strawberry-perl-5.32.1.1-32bit.msi"
set "PERL_URL=https://openkore.com.br/download/strawberry-perl-5.32.1.1-32bit.msi"
set "PYTHON_INSTALLER=python-3.11.9.exe"
set "PYTHON_URL=https://www.python.org/ftp/python/3.11.9/python-3.11.9.exe"
set "PERL_DIR=C:\Strawberry"

echo        [OK] Variaveis configuradas
echo.

:: ============================================================================
:: CRIAÇÃO DE DIRETÓRIOS
:: ============================================================================
echo [3/10] Criando diretorios...

if not exist "%DOWNLOADS_DIR%" (
    mkdir "%DOWNLOADS_DIR%"
    if exist "%DOWNLOADS_DIR%" (
        echo        [OK] Pasta downloads criada: %DOWNLOADS_DIR%
    ) else (
        echo        [AVISO] Nao foi possivel criar pasta downloads
        echo        [INFO] Usando pasta temporaria
        set "DOWNLOADS_DIR=%TEMP%\openkore"
        mkdir "%DOWNLOADS_DIR%" 2>nul
    )
) else (
    echo        [OK] Pasta downloads ja existe
)
echo.

:: PAUSA DE DEBUG - FORÇADA
echo [DEBUG] Pasta downloads configurada com sucesso!
echo [DEBUG] Pressione qualquer tecla para continuar...
pause >nul

:: Pausa de segurança adicional
echo [DEBUG] Continuando em 3 segundos...
timeout /t 3 /nobreak >nul

:: ============================================================================
:: VERIFICAÇÃO DE INSTALAÇÕES EXISTENTES
:: ============================================================================
echo [4/10] Verificando o que ja esta instalado...
echo.

set "PERL_OK=0"
set "PYTHON_OK=0"

where perl >nul 2>&1
if not errorlevel 1 (
    echo        [OK] Perl JA esta instalado
    set "PERL_OK=1"
) else (
    echo        [INFO] Perl NAO encontrado - sera instalado
)

where python >nul 2>&1
if not errorlevel 1 (
    echo        [OK] Python JA esta instalado
    set "PYTHON_OK=1"
) else (
    echo        [INFO] Python NAO encontrado - sera instalado
)

echo.

:: PAUSA DE DEBUG CRÍTICA
echo ════════════════════════════════════════════════════════════════════
echo [DEBUG] Verificacao de instalacoes existentes CONCLUIDA
echo ════════════════════════════════════════════════════════════════════
echo.
echo Pressione qualquer tecla para iniciar as instalacoes...
pause >nul
echo.

timeout /t 2 /nobreak >nul

:: ============================================================================
:: INSTALAÇÃO DO PERL
:: ============================================================================
if "%PERL_OK%"=="0" (
    echo [5/10] Instalando Strawberry Perl...
    echo ════════════════════════════════════════════════════════════════════
    echo.
    
    :: Verifica se já foi baixado
    if not exist "%DOWNLOADS_DIR%\%PERL_INSTALLER%" (
        echo        [INFO] Baixando Perl de: openkore.com.br
        echo        [INFO] Isso pode levar alguns minutos...
        echo.
        
        powershell -Command "$ProgressPreference='SilentlyContinue'; try { Invoke-WebRequest -Uri '%PERL_URL%' -OutFile '%DOWNLOADS_DIR%\%PERL_INSTALLER%' -UseBasicParsing; exit 0 } catch { exit 1 }"
        
        if exist "%DOWNLOADS_DIR%\%PERL_INSTALLER%" (
            echo        [OK] Download concluido!
        ) else (
            echo        [ERRO] Falha no download
            echo.
            echo        Baixe manualmente de: %PERL_URL%
            echo        E coloque em: %DOWNLOADS_DIR%
            echo.
            echo        Pressione qualquer tecla para continuar sem Perl...
            pause >nul
            goto SKIP_PERL
        )
    ) else (
        echo        [INFO] Arquivo ja baixado anteriormente
    )
    
    echo.
    echo        [INFO] Instalando Perl (aguarde 2-5 minutos)...
    
    msiexec /i "%DOWNLOADS_DIR%\%PERL_INSTALLER%" /quiet /norestart INSTALLDIR="%PERL_DIR%"
    
    timeout /t 10 /nobreak >nul
    
    if exist "%PERL_DIR%\perl\bin\perl.exe" (
        echo        [OK] Perl instalado com sucesso!
        
        :: Adiciona ao PATH
        setx PATH "%PERL_DIR%\perl\bin;%PERL_DIR%\c\bin;%PATH%" /M >nul 2>&1
        set "PATH=%PERL_DIR%\perl\bin;%PERL_DIR%\c\bin;%PATH%"
    ) else (
        echo        [AVISO] Perl pode nao ter sido instalado corretamente
    )
    
    :SKIP_PERL
    echo.
) else (
    echo [5/10] Perl ja instalado - PULANDO
    echo.
)

timeout /t 2 /nobreak >nul

:: ============================================================================
:: INSTALAÇÃO DO PYTHON
:: ============================================================================
if "%PYTHON_OK%"=="0" (
    echo [6/10] Instalando Python...
    echo ════════════════════════════════════════════════════════════════════
    echo.
    
    :: Verifica se já foi baixado
    if not exist "%DOWNLOADS_DIR%\%PYTHON_INSTALLER%" (
        echo        [INFO] Baixando Python de: python.org
        echo        [INFO] Isso pode levar alguns minutos...
        echo.
        
        powershell -Command "$ProgressPreference='SilentlyContinue'; try { Invoke-WebRequest -Uri '%PYTHON_URL%' -OutFile '%DOWNLOADS_DIR%\%PYTHON_INSTALLER%' -UseBasicParsing; exit 0 } catch { exit 1 }"
        
        if exist "%DOWNLOADS_DIR%\%PYTHON_INSTALLER%" (
            echo        [OK] Download concluido!
        ) else (
            echo        [ERRO] Falha no download
            echo.
            echo        Baixe manualmente de: %PYTHON_URL%
            echo        E coloque em: %DOWNLOADS_DIR%
            echo.
            echo        Pressione qualquer tecla para continuar sem Python...
            pause >nul
            goto SKIP_PYTHON
        )
    ) else (
        echo        [INFO] Arquivo ja baixado anteriormente
    )
    
    echo.
    echo        [INFO] Instalando Python (aguarde 1-3 minutos)...
    
    "%DOWNLOADS_DIR%\%PYTHON_INSTALLER%" /quiet InstallAllUsers=1 PrependPath=1 Include_pip=1
    
    timeout /t 20 /nobreak >nul
    
    where python >nul 2>&1
    if not errorlevel 1 (
        echo        [OK] Python instalado com sucesso!
    ) else (
        echo        [AVISO] Python instalado - reinicie para ativar
    )
    
    :SKIP_PYTHON
    echo.
) else (
    echo [6/10] Python ja instalado - PULANDO
    echo.
)

timeout /t 2 /nobreak >nul

:: ============================================================================
:: INSTALAÇÃO MÓDULO TK (PERL)
:: ============================================================================
echo [7/10] Instalando modulo Tk para Perl...
echo ════════════════════════════════════════════════════════════════════
echo.

where perl >nul 2>&1
if not errorlevel 1 (
    echo        [INFO] Instalando Tk via CPAN...
    echo        [AVISO] Isso pode levar varios minutos...
    echo.
    
    perl -MCPAN -e "CPAN::Shell->notest('install', 'Tk')" >nul 2>&1
    
    echo        [OK] Instalacao do Tk concluida
) else (
    echo        [AVISO] Perl nao encontrado - pulando Tk
)

echo.
timeout /t 2 /nobreak >nul

:: ============================================================================
:: INSTALAÇÃO MÓDULOS PYTHON
:: ============================================================================
echo [8/10] Instalando modulos Python...
echo ════════════════════════════════════════════════════════════════════
echo.

where python >nul 2>&1
if not errorlevel 1 (
    echo        [INFO] Instalando pymem...
    python -m pip install pymem --quiet 2>nul
    
    echo        [INFO] Instalando colorama...
    python -m pip install colorama --quiet 2>nul
    
    echo        [INFO] Instalando pywin32...
    python -m pip install pywin32 --quiet 2>nul
    
    echo        [OK] Modulos Python instalados
) else (
    echo        [AVISO] Python nao encontrado - pulando modulos
)

echo.
timeout /t 2 /nobreak >nul

:: ============================================================================
:: VERIFICAÇÃO FINAL
:: ============================================================================
echo [9/10] Verificando instalacoes...
echo ════════════════════════════════════════════════════════════════════
echo.

set "TUDO_OK=1"

where perl >nul 2>&1
if not errorlevel 1 (
    echo        [√] Perl OK
) else (
    echo        [X] Perl NAO encontrado
    set "TUDO_OK=0"
)

where python >nul 2>&1
if not errorlevel 1 (
    echo        [√] Python OK
) else (
    echo        [X] Python NAO encontrado
    set "TUDO_OK=0"
)

echo.

:: ============================================================================
:: FINALIZAÇÃO
:: ============================================================================
echo [10/10] INSTALACAO CONCLUIDA
echo ════════════════════════════════════════════════════════════════════
echo.

if "%TUDO_OK%"=="1" (
    color 0A
    echo  ██████╗ ██╗  ██╗
    echo  ██╔═══██╗██║ ██╔╝
    echo  ██║   ██║█████╔╝ 
    echo  ██║   ██║██╔═██╗ 
    echo  ╚██████╔╝██║  ██╗
    echo   ╚═════╝ ╚═╝  ╚═╝
    echo.
    echo  [SUCESSO] Tudo instalado com sucesso!
) else (
    color 0E
    echo  [AVISO] Instalacao concluida com avisos
    echo.
    echo  Algumas dependencias podem nao ter sido instaladas.
)

echo.
echo ════════════════════════════════════════════════════════════════════
echo  PROXIMOS PASSOS:
echo ════════════════════════════════════════════════════════════════════
echo.
echo  1. REINICIE o computador (IMPORTANTE!)
echo  2. Execute: validate_dependencies.py
echo  3. Se tudo OK, use o OpenKore!
echo.
echo ════════════════════════════════════════════════════════════════════
echo.
echo  Log salvo em: %SCRIPT_DIR%instalacao_log.txt
echo  Downloads em: %DOWNLOADS_DIR%
echo.
echo ════════════════════════════════════════════════════════════════════
echo.
echo  Esta janela NAO vai fechar sozinha.
echo  Pressione qualquer tecla quando estiver pronto.
echo.
pause >nul

if "%TUDO_OK%"=="1" (
    exit /b 0
) else (
    exit /b 1
)