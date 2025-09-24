# -*- coding: utf-8 -*-
import os, sys, time, msvcrt, pymem, win32process
from colorama import init as colorama_init, Fore, Style
colorama_init(autoreset=True)

# === sempre usa bypass.txt ao lado do .py ===
BASE_DIR = os.path.dirname(os.path.abspath(__file__))
BYPASS_FILE = os.path.join(BASE_DIR, "bypass.txt")

DEFAULTS = {
    "6901_EXE_PATH": r"C:\Gravity\Ragnarok\ragexe.exe",
    "6902_EXE_PATH": r"C:\Gravity\Ragnarok\ragexe.exe",
    "6903_EXE_PATH": r"C:\Gravity\Ragnarok\ragexe.exe",
    "IP": "172.65.175.75",
    "TAADDRESS_ADDR": "0x0144C1E8",
    "DOMAIN_PTR_ADDR": "0x010D6C98",
}
PORT_OPTIONS = [6901, 6902, 6903]
DEFAULT_TA = "lt-account-01.gnjoylatam.com:6951"
DEFAULT_DOMAIN = "lt-account-01.gnjoylatam.com:6900"

def ensure_bypass_file():
    if os.path.exists(BYPASS_FILE): return
    lines = [
        "# bypass.txt - key=value",
        "6901_EXE_PATH = C:\\Gravity\\Ragnarok\\ragexe.exe",
        "6902_EXE_PATH = C:\\Gravity\\Ragnarok_6902\\ragexe.exe",
        "6903_EXE_PATH = C:\\Gravity\\Ragnarok_6903\\ragexe.exe",
        "",
        "IP = 172.65.175.75",
        "TAADDRESS_ADDR = 0x0144C1E8",
        "DOMAIN_PTR_ADDR = 0x010D6C98",
        ""
    ]
    with open(BYPASS_FILE, "w", encoding="utf-8") as f: f.write("\n".join(lines))

def parse_kv_file(path):
    data = {}
    if not os.path.exists(path): return data
    with open(path, "r", encoding="utf-8") as f:
        for raw in f:
            line = raw.strip()
            if not line or line.startswith("#") or "=" not in line: continue
            k, v = line.split("=", 1)
            k = k.strip().upper()
            v = v.strip().strip('"').strip("'")
            data[k] = v
    return data

def parse_int_any(x):
    try:
        x = x.strip()
        if x.lower().startswith("0x"): return int(x, 16)
        return int(x)
    except: return 0

def get_cfg():
    ensure_bypass_file()
    kv = parse_kv_file(BYPASS_FILE)
    cfg = {}
    for p in PORT_OPTIONS:
        key = f"{p}_EXE_PATH"
        cfg[key] = kv.get(key.upper(), DEFAULTS[key])
    cfg["IP"] = kv.get("IP", DEFAULTS["IP"])
    cfg["TAADDRESS_ADDR"]  = parse_int_any(kv.get("TAADDRESS_ADDR",  DEFAULTS["TAADDRESS_ADDR"]))
    cfg["DOMAIN_PTR_ADDR"] = parse_int_any(kv.get("DOMAIN_PTR_ADDR", DEFAULTS["DOMAIN_PTR_ADDR"]))
    return cfg

def clear(): os.system("cls")
def render_menu(idx, cfg):
    clear()
    print(f"{Fore.CYAN}{Style.BRIGHT}╔════════════════════════════════════════════════════════════╗{Style.RESET_ALL}")
    print(f"{Fore.CYAN}{Style.BRIGHT}║     RAGNAROK MULTI-PORT BYPASS — Celtos / openkore.com.br  ║{Style.RESET_ALL}")
    print(f"{Fore.CYAN}{Style.BRIGHT}╚════════════════════════════════════════════════════════════╝{Style.RESET_ALL}")
    print(f"{Fore.YELLOW}Use ↑/↓ ou W/S para selecionar a porta. Enter=Confirmar  Esc=Cancelar{Style.RESET_ALL}\n")
    print(f"{Fore.BLUE}bypass.txt: {Fore.WHITE}{BYPASS_FILE}{Style.RESET_ALL}\n")
    for i, p in enumerate(PORT_OPTIONS):
        mark = f"{Fore.GREEN}{Style.BRIGHT}>>{Style.RESET_ALL}" if i==idx else "  "
        path = cfg.get(f"{p}_EXE_PATH","")
        print(f"{mark} Porta {Fore.MAGENTA}{p}{Style.RESET_ALL}  —  {Fore.WHITE}{path}{Style.RESET_ALL}")
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
        s = ch.decode().lower()
        if s=='w': return 'UP'
        if s=='s': return 'DOWN'
    except: pass
    return None

def choose_port(cfg):
    i=0; render_menu(i,cfg)
    while True:
        k=read_key()
        if k=='UP':   i=(i-1)%len(PORT_OPTIONS); render_menu(i,cfg)
        elif k=='DOWN': i=(i+1)%len(PORT_OPTIONS); render_menu(i,cfg)
        elif k=='ENTER': return PORT_OPTIONS[i]
        elif k=='ESC': print("Cancelado."); sys.exit(0)

def run_bypass(exe_path, ip, port, TAADDRESS_ADDR, DOMAIN_PTR_ADDR):
    if not os.path.isfile(exe_path):
        print(f"{Fore.RED}EXE não encontrado: {exe_path}{Style.RESET_ALL}"); sys.exit(1)
    value = f"{ip}:{port}".encode("utf-8").ljust(33, b'\x00')
    is_ta=False; is_dom=False
    h_process, h_thread, pid, tid = win32process.CreateProcess(
        None, f"\"{exe_path}\" 1rag1", None, None, False, 0, None, os.path.dirname(exe_path), win32process.STARTUPINFO()
    )
    pm = pymem.Pymem(pid)
    while True:
        try:
            ta = pm.read_string(TAADDRESS_ADDR)
            if not is_ta and ta == DEFAULT_TA:
                print(f"[taaddress] {ta} -> {ip}:{port}")
                pm.write_bytes(TAADDRESS_ADDR, value, len(value)); is_ta=True
            domain_addr = pm.read_uint(DOMAIN_PTR_ADDR)
            dom = pm.read_string(domain_addr)
            if not is_dom and dom == DEFAULT_DOMAIN:
                print(f"[domain]   {dom} -> {ip}:{port}")
                pm.write_bytes(domain_addr, value, len(value)); is_dom=True
            if is_ta and is_dom:
                print(f"{Fore.GREEN}{Style.BRIGHT}Sucesso.{Style.RESET_ALL}")
                sys.exit(0)
        except pymem.pymem.exception.MemoryWriteError as e:
            print(f"erro ao sobrescrever: {e}"); sys.exit(1)
        except Exception:
            pass
        time.sleep(0.01)

def main():
    cfg = get_cfg()
    port = choose_port(cfg)
    exe_path = cfg.get(f"{port}_EXE_PATH")
    ip = cfg["IP"]; TA = cfg["TAADDRESS_ADDR"]; DP = cfg["DOMAIN_PTR_ADDR"]
    print("\nIniciando cliente:", exe_path)
    print(f"Aplicando bypass em runtime: {ip}:{port}")
    print(f"TAADDRESS_ADDR: 0x{TA:08X}   DOMAIN_PTR_ADDR: 0x{DP:08X}\n")
    run_bypass(exe_path, ip, port, TA, DP)

if __name__ == "__main__":
    main()
