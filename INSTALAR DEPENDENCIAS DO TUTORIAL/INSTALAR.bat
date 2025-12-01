@echo off
:: ============================================================================
:: INSTALADOR DE DEPENDÊNCIAS - OpenKore/BypassIP
:: Autor: DMCore - Douglas
:: Este script NÃO VAI FECHAR sozinho!
:: ============================================================================

setlocal enabledelayedexpansion
chcp 65001 >nul
color 0B
title Instalador OpenKore/BypassIP

cls
echo.
echo ╔════════════════════════════════════════════════════════════════════╗
echo ║                                                                    ║
echo ║     INSTALADOR DE DEPENDÊNCIAS - OpenKore/BypassIP                ║
echo ║     DMCore - Douglas                                               ║
echo ║                                                                    ║
echo ╚════════════════════════════════════════════════════════════════════╝
echo.

:: Verifica privilégios de administrador
echo [INFO] Verificando privilegios de administrador...
timeout /t 1 /nobreak >nul

net session >nul 2>&1
if %errorLevel% neq 0 (
    color 0C
    echo.
    echo ════════════════════════════════════════════════════════════════════
    echo  [ERRO] PRECISA EXECUTAR COMO ADMINISTRADOR
    echo ════════════════════════════════════════════════════════════════════
    echo.
    echo Como fazer:
    echo  1. Clique com botao direito em: INSTALAR.bat
    echo  2. Selecione "Executar como administrador"
    echo  3. Clique em "Sim" na janela de confirmacao
    echo.
    echo ════════════════════════════════════════════════════════════════════
    echo.
    echo Pressione qualquer tecla para fechar...
    pause >nul
    exit /b 1
)

echo [OK] Privilegios de administrador confirmados!
echo.

:: Verifica se o instalador principal existe
if not exist "%~dp0install_openkore_dependencies_v2.bat" (
    color 0C
    echo [ERRO] Arquivo install_openkore_dependencies_v2.bat nao encontrado!
    echo.
    echo Certifique-se de que os 3 arquivos estao na MESMA PASTA:
    echo  - INSTALAR.bat
    echo  - install_openkore_dependencies_v2.bat
    echo  - validate_dependencies.py
    echo.
    echo Pasta atual: %~dp0
    echo.
    echo Pressione qualquer tecla para fechar...
    pause >nul
    exit /b 1
)

echo ════════════════════════════════════════════════════════════════════
echo  PRONTO PARA INSTALAR
echo ════════════════════════════════════════════════════════════════════
echo.
echo O que sera instalado:
echo  - Strawberry Perl 5.32.1.1 (32-bit)
echo  - Python 3.11.9
echo  - Modulo Tk para Perl
echo  - Modulos Python: pymem, colorama, pywin32
echo.
echo Tempo estimado: 10 a 30 minutos
echo Tamanho: aproximadamente 2 GB
echo.
echo IMPORTANTE: NAO feche esta janela durante a instalacao!
echo.
echo ════════════════════════════════════════════════════════════════════
echo.
echo Pressione qualquer tecla para INICIAR a instalacao...
echo (ou feche a janela para CANCELAR)
echo.
pause >nul

:: Aguarda confirmação do usuário
echo.
echo [INFO] Iniciando instalacao...
timeout /t 2 /nobreak >nul

cls
echo.
echo ════════════════════════════════════════════════════════════════════
echo  INSTALACAO EM ANDAMENTO - AGUARDE
echo ════════════════════════════════════════════════════════════════════
echo.
echo [AVISO] Esta janela vai mostrar o progresso da instalacao.
echo [AVISO] NAO FECHE esta janela ate aparecer a mensagem final!
echo.

:: Chama o instalador principal E AGUARDA
call "%~dp0install_openkore_dependencies_v2.bat"
set "RESULTADO=!errorLevel!"

:: PAUSA FORÇADA para evitar fechamento
timeout /t 2 /nobreak >nul

:: GARANTE que não vai fechar
cls
echo.
echo ════════════════════════════════════════════════════════════════════
echo  INSTALACAO CONCLUIDA
echo ════════════════════════════════════════════════════════════════════
echo.

if !RESULTADO! equ 0 (
    color 0A
    echo [SUCESSO] Todas as dependencias foram instaladas!
    echo.
    echo O que foi instalado:
    echo  [√] Strawberry Perl 5.32.1.1
    echo  [√] Python 3.11.9
    echo  [√] Modulo Tk
    echo  [√] Modulos Python
    echo.
) else (
    color 0E
    echo [AVISO] A instalacao pode ter encontrado alguns problemas.
    echo.
    echo Verifique o arquivo: instalacao_log.txt
    echo.
)

echo ════════════════════════════════════════════════════════════════════
echo  PROXIMOS PASSOS
echo ════════════════════════════════════════════════════════════════════
echo.
echo  1. REINICIE o computador (IMPORTANTE!)
echo.
echo  2. Apos reiniciar, execute: validate_dependencies.py
echo     (Para confirmar que tudo esta funcionando)
echo.
echo  3. Se tudo estiver OK, ja pode usar o OpenKore!
echo.
echo ════════════════════════════════════════════════════════════════════
echo.
echo Log detalhado salvo em: instalacao_log.txt
echo.
echo ════════════════════════════════════════════════════════════════════
echo.
echo Esta janela NAO vai fechar sozinha.
echo Pressione qualquer tecla quando estiver pronto para fechar.
echo.
pause >nul

exit /b !RESULTADO!