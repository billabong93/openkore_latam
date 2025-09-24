# -*- coding: utf-8 -*-
# ragnarok_bypass_selector.py
# Aberto / aplicado conforme bypass.txt ao lado do arquivo.
# Requisitos: pip install pymem pywin32 colorama
# Execute como Administrador.

import os
import sys
import time
import msvcrt
import pymem
import win32process
import win32api
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
    "TAADDRESS_ADDR": "0x0144C1E8",
    "DOMAIN_PTR_ADDR": "0x010D6C98",
}

# Timings — aumente se o cliente demorar mais pra iniciar
INIT_WAIT_MAX = 15.0       # segundos para esperar as strings aparecerem
INIT_POLL = 0.05           # intervalo de polling enquanto esperando
AFTER_PATCH_GRACE = 1.0    # tempo de folga após escrever (evita crash)
BETWEEN_LAUNCH_SLEEP = 3.0 # intervalo entre lançamentos quando abrir todas
# ---------------------------------------------------------

DEFAULT_TA = "lt-account-01.gnjoylatam.com:6951"
DEFAULT_DOMAIN = "lt-account-01.gnjoylatam.com:6900"

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
        "# Ponteiros (hex ou decimal)\n"
        f"TAADDRESS_ADDR = {DEFAULTS['TAADDRESS_ADDR']}\n"
        f"DOMAIN_PTR_ADDR = {DEFAULTS['DOMAIN_PTR_ADDR']}\n"
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

def parse_int_any(x):
    if x is None:
        return 0
    s = str(x).strip()
    try:
        if s.lower().startswith("0x"):
            return int(s, 16)
        return int(s)
    except Exception:
        return 0

def get_cfg():
    ensure_bypass_file()
    kv = parse_kv_file(BYPASS_FILE)
    cfg = {}
    for p in PORT_OPTIONS:
        key = f"{p}_EXE_PATH"
        cfg[key] = kv.get(key.upper(), DEFAULTS[key])
    cfg["IP"] = kv.get("IP", DEFAULTS["IP"])
    cfg["TAADDRESS_ADDR"] = parse_int_any(kv.get("TAADDRESS_ADDR", DEFAULTS["TAADDRESS_ADDR"]))
    cfg["DOMAIN_PTR_ADDR"] = parse_int_any(kv.get("DOMAIN_PTR_ADDR", DEFAULTS["DOMAIN_PTR_ADDR"]))
    return cfg

# ---------------- UI / Menu ----------------
def clear(): os.system("cls")

def render_menu(idx, cfg):
    clear()
    print(f"{Fore.CYAN}{Style.BRIGHT}╔════════════════════════════════════════════════════════════╗{Style.RESET_ALL}")
    print(f"{Fore.CYAN}{Style.BRIGHT}║     RAGNAROK MULTI-PORT BYPASS — Celtos / openkore.com.br  ║{Style.RESET_ALL}")
    print(f"{Fore.CYAN}{Style.BRIGHT}╚════════════════════════════════════════════════════════════╝{Style.RESET_ALL}")
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

    print("\n" + f"{Fore.BLUE}IP: {Fore.WHITE}{cfg['IP']}   {Fore.BLUE}TA: {Fore.WHITE}0x{cfg['TAADDRESS_ADDR']:08X}   {Fore.BLUE}PTR: {Fore.WHITE}0x{cfg['DOMAIN_PTR_ADDR']:08X}{Style.RESET_ALL}")

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

# ---------------- Core: abrir + aplicar bypass ----------------
def patch_instance(exe_path, ip, port, TAADDRESS_ADDR, DOMAIN_PTR_ADDR, stagger_msg=""):
    """
    Abre 1 cliente, espera strings default aparecerem (ou tenta fallback),
    escreve IP:PORT e retorna True/False.
    """
    if not os.path.isfile(exe_path):
        print(f"{Fore.RED}EXE não encontrado: {exe_path}{Style.RESET_ALL}")
        return False

    print(f"{Fore.CYAN}{stagger_msg}Abrindo porta {port} — {exe_path}{Style.RESET_ALL}")

    value = f"{ip}:{port}".encode("utf-8").ljust(33, b'\x00')
    is_ta = False
    is_dom = False

    # Cria processo normal (não suspended) como você pediu
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
    except Exception as e:
        print(f"{Fore.RED}Falha pymem abrir pid {pid}: {e}{Style.RESET_ALL}")
        # tentar fechar handles abertos
        try:
            win32api.CloseHandle(h_thread)
            win32api.CloseHandle(h_process)
        except Exception:
            pass
        return False

    # espera inicilização das strings (até INIT_WAIT_MAX)
    t0 = time.time()
    ta_ready = False
    dom_ready = False
    while time.time() - t0 < INIT_WAIT_MAX:
        try:
            if not ta_ready:
                try:
                    ta_val = pm.read_string(TAADDRESS_ADDR)
                    if ta_val and ta_val.startswith(DEFAULT_TA.split(":")[0]):
                        ta_ready = True
                except Exception:
                    pass
            if not dom_ready:
                try:
                    domain_addr = pm.read_uint(DOMAIN_PTR_ADDR)
                    if domain_addr:
                        dom_val = pm.read_string(domain_addr)
                        if dom_val and dom_val.startswith(DEFAULT_DOMAIN.split(":")[0]):
                            dom_ready = True
                except Exception:
                    pass
            if ta_ready and dom_ready:
                break
        except Exception:
            pass
        time.sleep(INIT_POLL)

    # tenta aplicar (se não estiver pronto, tenta mesmo assim como fallback)
    try:
        # TAADDRESS
        try:
            pm.write_bytes(TAADDRESS_ADDR, value, len(value))
            is_ta = True
            print(f"[taaddress] escrito {ip}:{port}")
        except Exception as e:
            print(f"{Fore.YELLOW}[taaddress] write falhou (tentando continuar): {e}{Style.RESET_ALL}")

        # DOMAIN (ponteiro -> string)
        try:
            domain_addr = pm.read_uint(DOMAIN_PTR_ADDR)
            if domain_addr:
                pm.write_bytes(domain_addr, value, len(value))
                is_dom = True
                print(f"[domain] escrito {ip}:{port}")
            else:
                print(f"{Fore.YELLOW}[domain] ponteiro lido = 0 (ignorando){Style.RESET_ALL}")
        except Exception as e:
            print(f"{Fore.YELLOW}[domain] write falhou (tentando continuar): {e}{Style.RESET_ALL}")

        # folga pra estabilizar
        time.sleep(AFTER_PATCH_GRACE)

        if is_ta and is_dom:
            print(f"{Fore.GREEN}{Style.BRIGHT}OK porta {port}.{Style.RESET_ALL}\n")
            return True
        else:
            print(f"{Fore.RED}Parcial porta {port}: TA={is_ta} DOM={is_dom}{Style.RESET_ALL}\n")
            return False
    finally:
        # cleanup - fechar pm e handles
        try:
            # pymem: fechar processo/handle interno se disponível
            pm.close_process()
        except Exception:
            try:
                pm.close_handle()
            except Exception:
                pass
        try:
            win32api.CloseHandle(h_thread)
        except Exception:
            pass
        try:
            win32api.CloseHandle(h_process)
        except Exception:
            pass

# ---------------- main ----------------
def main():
    cfg = get_cfg()
    sel = choose_item(cfg)
    ip = cfg["IP"]
    TA = cfg["TAADDRESS_ADDR"]
    DP = cfg["DOMAIN_PTR_ADDR"]

    if sel == MENU_ALL:
        ok_all = True
        for idx, port in enumerate(PORT_OPTIONS, start=1):
            exe_path = cfg.get(f"{port}_EXE_PATH")
            ok = patch_instance(exe_path, ip, port, TA, DP, stagger_msg=f"[{idx}/3] ")
            ok_all = ok_all and ok
            time.sleep(BETWEEN_LAUNCH_SLEEP)
        if ok_all:
            print(f"{Fore.GREEN}{Style.BRIGHT}Todas as portas abertas com sucesso.{Style.RESET_ALL}")
            sys.exit(0)
        else:
            print(f"{Fore.RED}{Style.BRIGHT}Uma ou mais portas falharam.{Style.RESET_ALL}")
            sys.exit(1)
    else:
        port = sel
        exe_path = cfg.get(f"{port}_EXE_PATH")
        print()
        print(f"{Fore.CYAN}Iniciando cliente: {exe_path}{Style.RESET_ALL}")
        print(f"{Fore.CYAN}Aplicando bypass em runtime: {ip}:{port}{Style.RESET_ALL}")
        print(f"{Fore.CYAN}TAADDRESS_ADDR: {Style.RESET_ALL}0x{TA:08X}   {Fore.CYAN}DOMAIN_PTR_ADDR: {Style.RESET_ALL}0x{DP:08X}\n")
        ok = patch_instance(exe_path, ip, port, TA, DP)
        sys.exit(0 if ok else 1)

if __name__ == "__main__":
    main()
