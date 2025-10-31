# -*- coding: utf-8 -*-
# ragnarok_bypass_unified.py
# Script unificado: busca ponteiros dinamicamente + aplica bypass
# Requisitos: pip install pymem pywin32 colorama
# Execute como Administrador.

import os
import sys
import time
import msvcrt
import pymem
import win32process
import win32api
import ctypes
from ctypes import wintypes
from colorama import init as colorama_init, Fore, Style

colorama_init(autoreset=True)

# ---------------- CONFIG (ajuste se quiser) ----------------
BASE_DIR = os.path.dirname(os.path.abspath(__file__))
BYPASS_FILE = os.path.join(BASE_DIR, "bypass.txt")

PORT_OPTIONS = [6901, 6902, 6903]
MENU_ALL = "ALL"

DEFAULTS = {
    "6901_EXE_PATH": r"C:\Gravity\Ragnarok\ragexe.exe",
    "6902_EXE_PATH": r"C:\Gravity\Ragnarok_6902\ragexe.exe",
    "6903_EXE_PATH": r"C:\Gravity\Ragnarok_6903\ragexe.exe",
    "IP": "172.65.175.75",
    "AUTOMATICO": "false",
}

# Timings
INIT_WAIT_MAX = 10.0       # segundos para esperar as strings aparecerem
INIT_POLL = 5.0            # intervalo de polling enquanto esperando
AFTER_PATCH_GRACE = 5.0    # tempo de folga após escrever
BETWEEN_LAUNCH_SLEEP = 10.0 # intervalo entre lançamentos quando abrir todas
MAX_SEARCH_ATTEMPTS = 50    # tentativas de busca de strings
SEARCH_INTERVAL = 1.0       # intervalo entre tentativas de busca
# ---------------------------------------------------------

DEFAULT_TA = "lt-account-01.gnjoylatam.com:6951"
DEFAULT_DOMAIN = "lt-account-01.gnjoylatam.com:6900"
DEFAULT_HOSTNAME = "lt-account-01.gnjoylatam.com"

# Windows API constants para busca de memória
PROCESS_QUERY_INFORMATION = 0x0400
PROCESS_VM_READ = 0x0010
MEM_COMMIT = 0x1000
PAGE_READONLY = 0x02
PAGE_READWRITE = 0x04
PAGE_EXECUTE_READ = 0x20
PAGE_EXECUTE_READWRITE = 0x40

class MEMORY_BASIC_INFORMATION(ctypes.Structure):
    _fields_ = [
        ("BaseAddress", ctypes.c_void_p),
        ("AllocationBase", ctypes.c_void_p),
        ("AllocationProtect", wintypes.DWORD),
        ("RegionSize", ctypes.c_size_t),
        ("State", wintypes.DWORD),
        ("Protect", wintypes.DWORD),
        ("Type", wintypes.DWORD)
    ]

# ---------------- file helpers ----------------
def ensure_bypass_file():
    if os.path.exists(BYPASS_FILE):
        return
    template = (
        "# bypass.txt - key=value\n"
        "# Caminhos por porta:\n"
        f"6901_EXE_PATH = {DEFAULTS['6901_EXE_PATH']}\n"
        f"6902_EXE_PATH = {DEFAULTS['6902_EXE_PATH']}\n"
        f"6903_EXE_PATH = {DEFAULTS['6903_EXE_PATH']}\n\n"
        "# IP (será combinado com a porta escolhida)\n"
        f"IP = {DEFAULTS['IP']}\n\n"
        "# Modo automático: se true, abre 3 instâncias sem mostrar menu\n"
        f"AUTOMATICO = {DEFAULTS['AUTOMATICO']}\n\n"
        "# Ponteiros encontrados (atualizados automaticamente):\n"
        "# TAADDRESS_ADDR = 0x00000000\n"
        "# DOMAIN_PTR_ADDR = 0x00000000\n"
    )
    with open(BYPASS_FILE, "w", encoding="utf-8") as f:
        f.write(template)

def parse_kv_file(path):
    out = {}
    if not os.path.exists(path):
        return out
    with open(path, "r", encoding="utf-8") as f:
        for raw in f:
            line = raw.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            k = k.strip().upper()
            v = v.strip().strip('"').strip("'")
            out[k] = v
    return out

def save_pointers_to_file(ta_addr, domain_ptr_addr):
    """Salva os ponteiros encontrados no bypass.txt"""
    try:
        lines = []
        if os.path.exists(BYPASS_FILE):
            with open(BYPASS_FILE, "r", encoding="utf-8") as f:
                lines = f.readlines()
        
        # Atualiza ou adiciona os ponteiros
        ta_found = False
        dom_found = False
        
        for i, line in enumerate(lines):
            if line.strip().startswith("TAADDRESS_ADDR"):
                lines[i] = f"TAADDRESS_ADDR = 0x{ta_addr:08X}\n"
                ta_found = True
            elif line.strip().startswith("DOMAIN_PTR_ADDR"):
                lines[i] = f"DOMAIN_PTR_ADDR = 0x{domain_ptr_addr:08X}\n"
                dom_found = True
        
        if not ta_found:
            lines.append(f"TAADDRESS_ADDR = 0x{ta_addr:08X}\n")
        if not dom_found:
            lines.append(f"DOMAIN_PTR_ADDR = 0x{domain_ptr_addr:08X}\n")
        
        with open(BYPASS_FILE, "w", encoding="utf-8") as f:
            f.writelines(lines)
        
        print(f"{Fore.GREEN}Ponteiros salvos em {BYPASS_FILE}{Style.RESET_ALL}")
    except Exception as e:
        print(f"{Fore.YELLOW}Aviso: Não foi possível salvar ponteiros: {e}{Style.RESET_ALL}")

def get_cfg():
    ensure_bypass_file()
    kv = parse_kv_file(BYPASS_FILE)
    cfg = {}
    for p in PORT_OPTIONS:
        key = f"{p}_EXE_PATH"
        cfg[key] = kv.get(key.upper(), DEFAULTS[key])
    cfg["IP"] = kv.get("IP", DEFAULTS["IP"])
    cfg["AUTOMATICO"] = kv.get("AUTOMATICO", DEFAULTS["AUTOMATICO"]).lower() == "true"
    return cfg

# ---------------- Memory Search Functions ----------------
def find_string_in_memory(pm, target_string):
    """Encontra endereço de uma string na memória do processo"""
    kernel32 = ctypes.windll.kernel32
    handle = pm.process_handle
    
    address = 0
    while address < 0x7FFFFFFF:
        mbi = MEMORY_BASIC_INFORMATION()
        result = kernel32.VirtualQueryEx(
            handle,
            ctypes.c_void_p(address),
            ctypes.byref(mbi),
            ctypes.sizeof(mbi)
        )
        
        if result == 0:
            break
            
        # Verifica se os valores são válidos
        if (mbi.BaseAddress is None or mbi.RegionSize is None or 
            mbi.State != MEM_COMMIT or 
            mbi.Protect not in [PAGE_READONLY, PAGE_READWRITE, PAGE_EXECUTE_READ, PAGE_EXECUTE_READWRITE]):
            address = (mbi.BaseAddress or 0) + (mbi.RegionSize or 0x1000)
            continue
            
        try:
            # Lê a região em chunks
            chunk_size = 4096
            for offset in range(0, mbi.RegionSize, chunk_size):
                read_size = min(chunk_size, mbi.RegionSize - offset)
                
                buffer = ctypes.create_string_buffer(read_size)
                bytes_read = ctypes.c_size_t()
                
                if kernel32.ReadProcessMemory(
                    handle,
                    ctypes.c_void_p(mbi.BaseAddress + offset),
                    buffer,
                    read_size,
                    ctypes.byref(bytes_read)
                ):
                    data = buffer.raw[:bytes_read.value]
                    target_bytes = target_string.encode('utf-8')
                    
                    pos = data.find(target_bytes)
                    if pos != -1:
                        found_address = mbi.BaseAddress + offset + pos
                        return found_address
                        
        except Exception:
            pass
            
        address = mbi.BaseAddress + mbi.RegionSize
    
    return None

def find_pointer_to_address(pm, target_address):
    """Encontra ponteiro que aponta para um endereço específico"""
    kernel32 = ctypes.windll.kernel32
    handle = pm.process_handle
    target_bytes = ctypes.c_uint32(target_address).value.to_bytes(4, 'little')
    
    address = 0
    while address < 0x7FFFFFFF:
        mbi = MEMORY_BASIC_INFORMATION()
        result = kernel32.VirtualQueryEx(
            handle,
            ctypes.c_void_p(address),
            ctypes.byref(mbi),
            ctypes.sizeof(mbi)
        )
        
        if result == 0:
            break
            
        # Verifica se os valores são válidos
        if (mbi.BaseAddress is None or mbi.RegionSize is None or 
            mbi.State != MEM_COMMIT or 
            mbi.Protect not in [PAGE_READWRITE, PAGE_EXECUTE_READWRITE]):
            address = (mbi.BaseAddress or 0) + (mbi.RegionSize or 0x1000)
            continue
            
        try:
            chunk_size = 4096
            for offset in range(0, mbi.RegionSize, chunk_size):
                read_size = min(chunk_size, mbi.RegionSize - offset)
                
                buffer = ctypes.create_string_buffer(read_size)
                bytes_read = ctypes.c_size_t()
                
                if kernel32.ReadProcessMemory(
                    handle,
                    ctypes.c_void_p(mbi.BaseAddress + offset),
                    buffer,
                    read_size,
                    ctypes.byref(bytes_read)
                ):
                    data = buffer.raw[:bytes_read.value]
                    
                    # Busca por ponteiros alinhados (4 bytes)
                    for i in range(0, len(data) - 3, 4):
                        if data[i:i+4] == target_bytes:
                            pointer_address = mbi.BaseAddress + offset + i
                            return pointer_address
                            
        except Exception:
            pass
            
        address = mbi.BaseAddress + mbi.RegionSize
    
    return None

def find_pointers_dynamically(pm):
    """
    Busca dinamicamente os ponteiros no processo.
    Retorna tupla (taaddress_addr, domain_ptr_addr, domain_string_addr)
    """
    print(f"{Fore.CYAN}Buscando ponteiros na memória do processo...{Style.RESET_ALL}")
    
    hostname_addr = None
    taaddress_addr = None
    domain_string_addr = None
    
    # Loop de busca - tenta encontrar as strings
    for attempt in range(MAX_SEARCH_ATTEMPTS):
        print(f"  Tentativa {attempt + 1}/{MAX_SEARCH_ATTEMPTS}")
        
        # Busca pelas strings conhecidas
        if not hostname_addr:
            hostname_addr = find_string_in_memory(pm, DEFAULT_HOSTNAME)
            if hostname_addr:
                print(f"  {Fore.GREEN}✓ Hostname base encontrado: 0x{hostname_addr:08X}{Style.RESET_ALL}")
        
        if not taaddress_addr:
            taaddress_addr = find_string_in_memory(pm, DEFAULT_TA)
            if taaddress_addr:
                print(f"  {Fore.GREEN}✓ taaddress encontrado: 0x{taaddress_addr:08X}{Style.RESET_ALL}")
        
        if not domain_string_addr:
            domain_string_addr = find_string_in_memory(pm, DEFAULT_DOMAIN)
            if domain_string_addr:
                print(f"  {Fore.GREEN}✓ domain string encontrado: 0x{domain_string_addr:08X}{Style.RESET_ALL}")
        
        # Se encontrou pelo menos taaddress ou hostname, continua
        if taaddress_addr or hostname_addr:
            break
            
        time.sleep(SEARCH_INTERVAL)
    
    if not taaddress_addr and not hostname_addr:
        print(f"{Fore.RED}Não encontrou nenhuma string do servidor na memória{Style.RESET_ALL}")
        return None, None, None
    
    # Usa o endereço que encontrou (prioridade: taaddress específico, depois hostname base)
    target_addr = taaddress_addr if taaddress_addr else hostname_addr
    
    if not domain_string_addr:
        print(f"{Fore.YELLOW}Domain string não encontrada, usando hostname base{Style.RESET_ALL}")
        domain_string_addr = hostname_addr
    
    # Busca ponteiro para domain
    domain_ptr_addr = None
    if domain_string_addr:
        print(f"{Fore.CYAN}Buscando ponteiro para domain...{Style.RESET_ALL}")
        domain_ptr_addr = find_pointer_to_address(pm, domain_string_addr)
        if domain_ptr_addr:
            print(f"  {Fore.GREEN}✓ Ponteiro domain encontrado: 0x{domain_ptr_addr:08X} -> 0x{domain_string_addr:08X}{Style.RESET_ALL}")
        else:
            print(f"  {Fore.YELLOW}Ponteiro domain não encontrado (usará busca direta){Style.RESET_ALL}")
    
    return target_addr, domain_ptr_addr, domain_string_addr

# ---------------- UI / Menu ----------------
def clear(): os.system("cls")

def render_menu(idx, cfg):
    clear()
    print(f"{Fore.CYAN}{Style.BRIGHT}╔═══════════════════════════════════════════════════════════╗{Style.RESET_ALL}")
    print(f"{Fore.CYAN}{Style.BRIGHT}║     RAGNAROK UNIFIED BYPASS — Celtos / openkore.com.br    ║{Style.RESET_ALL}")
    print(f"{Fore.CYAN}{Style.BRIGHT}║           Busca ponteiros + Aplica bypass                 ║{Style.RESET_ALL}")
    print(f"{Fore.CYAN}{Style.BRIGHT}╚═══════════════════════════════════════════════════════════╝{Style.RESET_ALL}")
    print(f"{Fore.YELLOW}Use ↑/↓ ou W/S para selecionar. Enter=Confirmar  Esc=Cancelar{Style.RESET_ALL}\n")
    print(f"{Fore.BLUE}bypass.txt: {Fore.WHITE}{BYPASS_FILE}{Style.RESET_ALL}\n")

    items = PORT_OPTIONS + [MENU_ALL]
    for i, it in enumerate(items):
        marker = f"{Fore.GREEN}{Style.BRIGHT}>>{Style.RESET_ALL}" if i == idx else "  "
        if it == MENU_ALL:
            print(f"{marker} {Fore.MAGENTA}Abrir todas (6901/6902/6903){Style.RESET_ALL}")
        else:
            path = cfg.get(f"{it}_EXE_PATH", "")
            print(f"{marker} Porta {Fore.MAGENTA}{it}{Style.RESET_ALL}  —  {Fore.WHITE}{path}{Style.RESET_ALL}")

    print("\n" + f"{Fore.BLUE}IP: {Fore.WHITE}{cfg['IP']}{Style.RESET_ALL}")
    print(f"{Fore.YELLOW}Ponteiros serão buscados dinamicamente ao iniciar{Style.RESET_ALL}")

def read_key():
    ch = msvcrt.getch()
    if ch in (b'\xe0', b'\x00'):
        ch2 = msvcrt.getch()
        if ch2 == b'H': return 'UP'
        if ch2 == b'P': return 'DOWN'
        return None
    if ch in (b'\r', b'\n'): return 'ENTER'
    if ch == b'\x1b': return 'ESC'
    try:
        s = ch.decode('utf-8').lower()
        if s == 'w': return 'UP'
        if s == 's': return 'DOWN'
    except Exception:
        pass
    return None

def choose_item(cfg):
    items = PORT_OPTIONS + [MENU_ALL]
    i = 0
    render_menu(i, cfg)
    while True:
        k = read_key()
        if k == 'UP':
            i = (i - 1) % len(items)
            render_menu(i, cfg)
        elif k == 'DOWN':
            i = (i + 1) % len(items)
            render_menu(i, cfg)
        elif k == 'ENTER':
            return items[i]
        elif k == 'ESC':
            print("Cancelado."); sys.exit(0)

# ---------------- Core: abrir + buscar ponteiros + aplicar bypass ----------------
def patch_instance(exe_path, ip, port, stagger_msg=""):
    """
    Abre 1 cliente, busca ponteiros dinamicamente, aplica bypass e retorna True/False.
    """
    if not os.path.isfile(exe_path):
        print(f"{Fore.RED}EXE não encontrado: {exe_path}{Style.RESET_ALL}")
        return False

    print(f"{Fore.CYAN}{stagger_msg}Abrindo porta {port} — {exe_path}{Style.RESET_ALL}")

    value = f"{ip}:{port}".encode("utf-8").ljust(33, b'\x00')

    # Cria processo normal
    try:
        h_process, h_thread, pid, tid = win32process.CreateProcess(
            None, f"\"{exe_path}\" 1rag1",
            None, None, False, 0, None, os.path.dirname(exe_path),
            win32process.STARTUPINFO()
        )
    except Exception as e:
        print(f"{Fore.RED}Falha CreateProcess: {e}{Style.RESET_ALL}")
        return False

    # anexa com pymem
    try:
        pm = pymem.Pymem(pid)
        print(f"Processo iniciado! PID: {pid}")
    except Exception as e:
        print(f"{Fore.RED}Falha pymem abrir pid {pid}: {e}{Style.RESET_ALL}")
        try:
            win32api.CloseHandle(h_thread)
            win32api.CloseHandle(h_process)
        except Exception:
            pass
        return False

    # Aguarda o processo carregar
    print(f"{Fore.CYAN}Aguardando processo carregar...{Style.RESET_ALL}")
    time.sleep(8)

    # Busca ponteiros dinamicamente
    taaddress_addr, domain_ptr_addr, domain_string_addr = find_pointers_dynamically(pm)
    
    if not taaddress_addr:
        print(f"{Fore.RED}Falha ao encontrar ponteiros necessários{Style.RESET_ALL}")
        try:
            pm.close_process()
        except:
            pass
        return False
    
    print(f"\n{Fore.GREEN}Ponteiros encontrados:{Style.RESET_ALL}")
    print(f"  TAADDRESS: 0x{taaddress_addr:08X}")
    if domain_ptr_addr and domain_string_addr:
        print(f"  DOMAIN_PTR: 0x{domain_ptr_addr:08X} -> 0x{domain_string_addr:08X}")
    elif domain_string_addr:
        print(f"  DOMAIN_STRING: 0x{domain_string_addr:08X} (sem ponteiro)")
    
    # Salva ponteiros encontrados no arquivo
    if domain_ptr_addr:
        save_pointers_to_file(taaddress_addr, domain_ptr_addr)
    
    # Aplica o bypass
    print(f"\n{Fore.CYAN}Aplicando bypass: {ip}:{port}{Style.RESET_ALL}")
    is_ta = False
    is_dom = False
    
    max_attempts = 100
    attempt = 0
    
    while attempt < max_attempts:
        try:
            # TAADDRESS
            if not is_ta:
                try:
                    current_value = pm.read_string(taaddress_addr)
                    if DEFAULT_HOSTNAME in current_value:
                        pm.write_bytes(taaddress_addr, value, len(value))
                        is_ta = True
                        print(f"{Fore.GREEN}[taaddress] substituído: {current_value} -> {ip}:{port}{Style.RESET_ALL}")
                except Exception as e:
                    if "MemoryWriteError" in str(type(e)):
                        print(f"{Fore.RED}GameGuard bloqueou escrita no taaddress{Style.RESET_ALL}")
                        break
            
            # DOMAIN via ponteiro
            if not is_dom and domain_ptr_addr:
                try:
                    domain_addr = pm.read_uint(domain_ptr_addr)
                    if domain_addr:
                        domain = pm.read_string(domain_addr)
                        if DEFAULT_HOSTNAME in domain:
                            pm.write_bytes(domain_addr, value, len(value))
                            is_dom = True
                            print(f"{Fore.GREEN}[domain] substituído: {domain} -> {ip}:{port}{Style.RESET_ALL}")
                except Exception as e:
                    if "MemoryWriteError" in str(type(e)):
                        print(f"{Fore.RED}GameGuard bloqueou escrita no domain{Style.RESET_ALL}")
                        break
            
            # DOMAIN direto (se não tem ponteiro)
            if not is_dom and domain_string_addr and not domain_ptr_addr:
                try:
                    domain = pm.read_string(domain_string_addr)
                    if DEFAULT_HOSTNAME in domain:
                        pm.write_bytes(domain_string_addr, value, len(value))
                        is_dom = True
                        print(f"{Fore.GREEN}[domain-direct] substituído: {domain} -> {ip}:{port}{Style.RESET_ALL}")
                except Exception as e:
                    if "MemoryWriteError" in str(type(e)):
                        print(f"{Fore.RED}GameGuard bloqueou escrita no domain-direct{Style.RESET_ALL}")
                        break
            
            if is_ta and is_dom:
                break
                
        except pymem.exception.MemoryWriteError:
            print(f"{Fore.RED}GameGuard bloqueou todas as escritas na memória{Style.RESET_ALL}")
            break
        except Exception:
            pass
            
        time.sleep(0.01)
        attempt += 1
    
    # Resultado
    success = is_ta and is_dom
    
    if success:
        print(f"\n{Fore.GREEN}{Style.BRIGHT}✓ Bypass aplicado com sucesso na porta {port}!{Style.RESET_ALL}\n")
    else:
        print(f"\n{Fore.YELLOW}Bypass parcial porta {port}: TA={is_ta} DOM={is_dom}{Style.RESET_ALL}\n")
    
    # Cleanup
    try:
        pm.close_process()
    except:
        try:
            pm.close_handle()
        except:
            pass
    try:
        win32api.CloseHandle(h_thread)
    except:
        pass
    try:
        win32api.CloseHandle(h_process)
    except:
        pass
    
    return success

def launch_all_instances(cfg, ip):
    """Abre todas as 3 instâncias automaticamente"""
    print(f"\n{Fore.CYAN}{Style.BRIGHT}╔══════════════════════════════════════════════════╗{Style.RESET_ALL}")
    print(f"{Fore.CYAN}{Style.BRIGHT}║      MODO AUTOMÁTICO: Abrindo 3 instâncias       ║{Style.RESET_ALL}")
    print(f"{Fore.CYAN}{Style.BRIGHT}╚══════════════════════════════════════════════════╝{Style.RESET_ALL}\n")
    
    ok_all = True
    for idx, port in enumerate(PORT_OPTIONS, start=1):
        exe_path = cfg.get(f"{port}_EXE_PATH")
        ok = patch_instance(exe_path, ip, port, stagger_msg=f"[{idx}/3] ")
        ok_all = ok_all and ok
        
        if idx < len(PORT_OPTIONS):
            print(f"{Fore.CYAN}Aguardando {BETWEEN_LAUNCH_SLEEP}s antes do próximo...{Style.RESET_ALL}")
            time.sleep(BETWEEN_LAUNCH_SLEEP)
    
    return ok_all

# ---------------- main ----------------
def main():
    print(f"{Fore.CYAN}{Style.BRIGHT}")
    print("╔═══════════════════════════════════════════════════════════╗")
    print("║                                                           ║")
    print("║       RAGNAROK UNIFIED BYPASS - Busca Automática          ║")
    print("║                                                           ║")
    print("╚═══════════════════════════════════════════════════════════╝")
    print(f"{Style.RESET_ALL}")
    
    cfg = get_cfg()
    ip = cfg["IP"]
    automatico = cfg["AUTOMATICO"]
    
    # Verifica se está no modo automático
    if automatico:
        print(f"{Fore.GREEN}Modo automático ativado (automatico=true no bypass.txt){Style.RESET_ALL}")
        ok_all = launch_all_instances(cfg, ip)
        
        if ok_all:
            print(f"\n{Fore.GREEN}{Style.BRIGHT}✓ Todas as 3 instâncias abertas com sucesso!{Style.RESET_ALL}")
            sys.exit(0)
        else:
            print(f"\n{Fore.RED}{Style.BRIGHT}✗ Uma ou mais instâncias falharam.{Style.RESET_ALL}")
            sys.exit(1)
    
    # Modo manual - mostra menu
    sel = choose_item(cfg)

    if sel == MENU_ALL:
        ok_all = launch_all_instances(cfg, ip)
        
        if ok_all:
            print(f"\n{Fore.GREEN}{Style.BRIGHT}✓ Todas as portas abertas com sucesso!{Style.RESET_ALL}")
            sys.exit(0)
        else:
            print(f"\n{Fore.RED}{Style.BRIGHT}✗ Uma ou mais portas falharam.{Style.RESET_ALL}")
            sys.exit(1)
    else:
        port = sel
        exe_path = cfg.get(f"{port}_EXE_PATH")
        print(f"\n{Fore.CYAN}Iniciando cliente na porta {port}...{Style.RESET_ALL}")
        print(f"{Fore.CYAN}Bypass será aplicado para: {ip}:{port}{Style.RESET_ALL}\n")
        ok = patch_instance(exe_path, ip, port)
        sys.exit(0 if ok else 1)

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print(f"\n{Fore.YELLOW}Operação cancelada pelo usuário{Style.RESET_ALL}")
        sys.exit(1)
    except Exception as e:
        print(f"\n{Fore.RED}Erro: {e}{Style.RESET_ALL}")
        import traceback
        traceback.print_exc()
        sys.exit(1)