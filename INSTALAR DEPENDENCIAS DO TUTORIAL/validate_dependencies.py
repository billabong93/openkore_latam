#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
Script de Validação de Dependências
Verifica se todas as dependências estão instaladas corretamente
"""

import sys
import subprocess
from typing import Tuple, List

def print_header(text: str):
    """Imprime um cabeçalho formatado"""
    print("\n" + "=" * 70)
    print(f"  {text}")
    print("=" * 70 + "\n")

def check_command(command: List[str], name: str) -> Tuple[bool, str]:
    """
    Verifica se um comando existe e funciona
    
    Args:
        command: Lista com o comando e argumentos
        name: Nome amigável do comando
        
    Returns:
        Tupla (sucesso, mensagem)
    """
    try:
        result = subprocess.run(
            command,
            capture_output=True,
            text=True,
            timeout=10
        )
        if result.returncode == 0:
            output = result.stdout.strip()
            return True, f"[OK] {name} está funcionando\n    {output.split(chr(10))[0]}"
        else:
            return False, f"[ERRO] {name} retornou erro: {result.stderr.strip()}"
    except FileNotFoundError:
        return False, f"[ERRO] {name} não encontrado no sistema"
    except subprocess.TimeoutExpired:
        return False, f"[ERRO] {name} demorou muito para responder"
    except Exception as e:
        return False, f"[ERRO] {name}: {str(e)}"

def check_python_module(module_name: str, import_name: str = None) -> Tuple[bool, str]:
    """
    Verifica se um módulo Python está instalado
    
    Args:
        module_name: Nome do módulo para exibição
        import_name: Nome para importação (se diferente)
        
    Returns:
        Tupla (sucesso, mensagem)
    """
    if import_name is None:
        import_name = module_name
    
    try:
        __import__(import_name)
        return True, f"[OK] Módulo {module_name} está instalado"
    except ImportError:
        return False, f"[ERRO] Módulo {module_name} NÃO está instalado"
    except Exception as e:
        return False, f"[ERRO] Módulo {module_name}: {str(e)}"

def check_perl_module(module_name: str) -> Tuple[bool, str]:
    """
    Verifica se um módulo Perl está instalado
    
    Args:
        module_name: Nome do módulo Perl
        
    Returns:
        Tupla (sucesso, mensagem)
    """
    try:
        result = subprocess.run(
            ['perl', f'-M{module_name}', '-e', f'print "[OK] {module_name} instalado"'],
            capture_output=True,
            text=True,
            timeout=5
        )
        if result.returncode == 0:
            return True, result.stdout.strip()
        else:
            return False, f"[ERRO] Módulo Perl {module_name} NÃO está instalado"
    except FileNotFoundError:
        return False, "[ERRO] Perl não encontrado"
    except subprocess.TimeoutExpired:
        return False, f"[ERRO] Timeout ao verificar {module_name}"
    except Exception as e:
        return False, f"[ERRO] {module_name}: {str(e)}"

def main():
    """Função principal"""
    print("\n" + "=" * 70)
    print("  VALIDAÇÃO DE DEPENDÊNCIAS - OpenKore/BypassIP")
    print("  DMCore - Douglas")
    print("=" * 70)
    
    results = []
    
    # Verifica Perl
    print_header("VERIFICANDO PERL")
    success, msg = check_command(['perl', '--version'], 'Perl')
    results.append(success)
    print(msg)
    
    # Verifica módulos Perl
    print_header("VERIFICANDO MÓDULOS PERL")
    perl_modules = ['Tk', 'CPAN']
    for module in perl_modules:
        success, msg = check_perl_module(module)
        results.append(success)
        print(msg)
    
    # Verifica Python
    print_header("VERIFICANDO PYTHON")
    success, msg = check_command([sys.executable, '--version'], 'Python')
    results.append(success)
    print(msg)
    
    # Verifica pip
    success, msg = check_command([sys.executable, '-m', 'pip', '--version'], 'pip')
    results.append(success)
    print(msg)
    
    # Verifica módulos Python
    print_header("VERIFICANDO MÓDULOS PYTHON")
    python_modules = [
        ('pymem', 'pymem'),
        ('colorama', 'colorama'),
        ('pywin32', 'win32api'),
    ]
    
    for display_name, import_name in python_modules:
        success, msg = check_python_module(display_name, import_name)
        results.append(success)
        print(msg)
    
    # Resumo final
    print_header("RESUMO FINAL")
    
    total = len(results)
    success_count = sum(results)
    fail_count = total - success_count
    
    print(f"Total de verificações: {total}")
    print(f"Sucesso: {success_count}")
    print(f"Falhas: {fail_count}")
    print()
    
    if fail_count == 0:
        print("[SUCESSO] ✓ Todas as dependências estão instaladas corretamente!")
        print("\nVocê pode usar o OpenKore/BypassIP sem problemas.")
        return 0
    else:
        print("[AVISO] ⚠ Algumas dependências não foram encontradas")
        print("\nRecomendações:")
        print("1. Execute o script install_openkore_dependencies.bat como administrador")
        print("2. Reinicie o computador para atualizar as variáveis de ambiente")
        print("3. Execute este script de validação novamente")
        return 1

if __name__ == "__main__":
    try:
        exit_code = main()
        print("\n" + "=" * 70)
        input("\nPressione ENTER para sair...")
        sys.exit(exit_code)
    except KeyboardInterrupt:
        print("\n\n[INFO] Validação cancelada pelo usuário")
        sys.exit(1)
    except Exception as e:
        print(f"\n[ERRO CRÍTICO] {str(e)}")
        input("\nPressione ENTER para sair...")
        sys.exit(1)
