import os
import pymem
import time
import win32process
import sys  # <<--- IMPORTANTE

EXE_PATH = r"C:\Gravity\Ragnarok\ragexe.exe"
IP = "172.65.175.75"

TAADDRESS_ADDR = 0x014491E0
DOMAIN_PTR_ADDR = 0x010D3C98

while True:
    porta_input = input(f"Digite a porta para o servidor Ragnarok (padrão: 6901): ").strip()
    if porta_input == "":
        PORT = 6901
        break
    elif porta_input.isdigit() and 0 < int(porta_input) < 65536:
        PORT = int(porta_input)
        break
    else:
        print("Porta inválida. Digite um número entre 1 e 65535 ou deixe em branco para usar o padrão.")

# 1- Abre o Rag
h_process, h_thread, pid, tid = win32process.CreateProcess(
    None,
    f"\"{EXE_PATH}\" 1rag1",
    None,
    None,
    False,
    0,
    None,
    os.path.dirname(EXE_PATH),
    win32process.STARTUPINFO()
)
pm = pymem.Pymem(pid)
value = f"{IP}:{PORT}".encode("utf-8").ljust(33, b'\x00')
is_taaddress_overwrited = False
is_domain_overwrited = False

# 2- Espera iniciar os valores default
# 3- Sobrescreve com IP e porta definidos.
while True:
    try:
        taaddress = pm.read_string(TAADDRESS_ADDR)
        if not is_taaddress_overwrited and taaddress == "lt-account-01.gnjoylatam.com:6951":
            print(f"[taaddress] substituindo {taaddress} por {IP}:{PORT}")
            pm.write_bytes(TAADDRESS_ADDR, value, len(value))
            is_taaddress_overwrited = True

        domain_addr = pm.read_uint(DOMAIN_PTR_ADDR)
        domain = pm.read_string(domain_addr)
        if not is_domain_overwrited and domain == "lt-account-01.gnjoylatam.com:6900":
            print(f"[domain] substituindo {domain} por {IP}:{PORT}")
            pm.write_bytes(domain_addr, value, len(value))
            is_domain_overwrited = True

        if is_taaddress_overwrited and is_domain_overwrited:
            print("sucesso")
            sys.exit(0)  # <<--- encerra o script de forma limpa
    except pymem.pymem.exception.MemoryWriteError as e:
        print(f"erro ao sobrescrever: {e}")
        sys.exit(1)
    except Exception:
        pass
    time.sleep(0.01)
