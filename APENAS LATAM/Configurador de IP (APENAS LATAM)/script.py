import json
import subprocess
import sys
import ctypes

# =================== CONFIG ===================
SECONDARY_LAST_OCTET = 75          # 1..254 (XX do IP secundário)
SECONDARY_NET = "172.65.175."      # rede secundária
SECONDARY_MASK = "255.255.255.0"   # /24
DNS_PRIMARY = "8.8.8.8"
DNS_SECONDARY = "8.8.4.4"
# ==============================================

def ensure_admin():
    try:
        is_admin = ctypes.windll.shell32.IsUserAnAdmin()
    except Exception:
        is_admin = False
    if not is_admin:
        params = " ".join([f'"{a}"' if " " in a else a for a in sys.argv])
        ctypes.windll.shell32.ShellExecuteW(None, "runas",
                                            sys.executable, params, None, 1)
        sys.exit(0)

def run_ps(ps):
    cmd = ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", ps]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(f"PowerShell error:\n{r.stderr.strip()}")
    return r.stdout.strip()

def cidr_to_mask(prefix_len: int) -> str:
    mask = (0xffffffff << (32 - prefix_len)) & 0xffffffff
    return ".".join(str((mask >> (8*i)) & 0xff) for i in [3,2,1,0])

def main():
    print("=== FEITO POR CELTOS - forum openkore.com.br ===\n")
    ensure_admin()

    # Coleta interface ATIVA com gateway IPv4 + infos
    ps_collect = r"""
$conf = Get-NetIPConfiguration |
  Where-Object { $_.IPv4DefaultGateway -ne $null -and $_.NetAdapter.Status -eq 'Up' } |
  Select-Object -First 1
if (-not $conf) { throw 'Nenhuma interface ativa com gateway IPv4 encontrada.' }

$ipv4 = $conf.IPv4Address | Select-Object -First 1
$gw   = $conf.IPv4DefaultGateway
$iface = Get-NetIPInterface -InterfaceIndex $conf.InterfaceIndex -AddressFamily IPv4

# Lista completa de IPv4 atuais dessa interface
$ips = Get-NetIPAddress -InterfaceIndex $conf.InterfaceIndex -AddressFamily IPv4 | ForEach-Object {
  [PSCustomObject]@{IPAddress=$_.IPAddress; PrefixLength=$_.PrefixLength}
}

[PSCustomObject]@{
  InterfaceAlias = $conf.InterfaceAlias
  InterfaceIndex = $conf.InterfaceIndex
  PrimaryIP      = $ipv4.IPAddress
  PrimaryPrefix  = [int]$ipv4.PrefixLength
  Gateway        = $gw.NextHop
  DhcpEnabled    = ($iface.Dhcp -eq 'Enabled')
  AllIPv4        = $ips
} | ConvertTo-Json -Compress
"""
    data = json.loads(run_ps(ps_collect))
    alias   = data["InterfaceAlias"]
    ifindex = data["InterfaceIndex"]
    prim_ip = data["PrimaryIP"]
    prim_pl = int(data["PrimaryPrefix"])
    prim_mask = cidr_to_mask(prim_pl)
    gw      = data["Gateway"]
    dhcp_on = bool(data["DhcpEnabled"])

    # IP secundário alvo
    last = int(SECONDARY_LAST_OCTET)
    if not (1 <= last <= 254):
        raise SystemExit("SECONDARY_LAST_OCTET inválido. Use 1..254.")
    sec_ip = f"{SECONDARY_NET}{last}"

    print(f"[INFO] Interface: {alias} (Index {ifindex})")
    print(f"[INFO] Primário : {prim_ip}/{prim_pl} (máscara {prim_mask})  GW {gw}")
    print(f"[INFO] Secundário alvo: {sec_ip}/{SECONDARY_MASK}")
    print(f"[INFO] DHCP: {'ON' if dhcp_on else 'OFF'}")

    # 1) Converter para estático SÓ se DHCP estiver ligado (preservando IP/GW)
    if dhcp_on:
        r = subprocess.run([
            "netsh","interface","ip","set","address",
            f"name={alias}", "static", prim_ip, prim_mask, gw, "1"
        ], capture_output=True, text=True)
        if r.returncode != 0:
            raise SystemExit(f"[ERRO] set address estático:\n{r.stderr}")
        print("[OK] DHCP desativado e IP primário fixado.")
    else:
        print("[OK] IP primário já está estático. Não alterado.")

    # 2) DNS fixos (limpa e aplica)
    subprocess.run(["netsh","interface","ip","delete","dns",f"name={alias}","all"],
                   capture_output=True, text=True)
    r1 = subprocess.run([
        "netsh","interface","ip","set","dns",
        f"name={alias}","static",DNS_PRIMARY,"primary"
    ], capture_output=True, text=True)
    if r1.returncode != 0:
        raise SystemExit(f"[ERRO] set DNS primário:\n{r1.stderr}")
    subprocess.run([
        "netsh","interface","ip","add","dns",
        f"name={alias}",DNS_SECONDARY,"index=2"
    ], capture_output=True, text=True)
    print("[OK] DNS aplicados.")

    # 3) Garante que o IP primário continua presente (não mexemos nele)
    ps_has_primary = fr"""
(Get-NetIPAddress -InterfaceIndex {ifindex} -AddressFamily IPv4 |
  Where-Object {{ $_.IPAddress -eq '{prim_ip}' -and $_.PrefixLength -eq {prim_pl} }}) -ne $null
"""
    if run_ps(ps_has_primary).strip().lower() != "true":
        # Re-adiciona como primário sem alterar gateway
        rfix = subprocess.run([
            "netsh","interface","ip","add","address",
            f"name={alias}", prim_ip, prim_mask
        ], capture_output=True, text=True)
        if rfix.returncode != 0 and "exists" not in (rfix.stderr or "").lower():
            raise SystemExit(f"[ERRO] restaurar IP primário:\n{rfix.stderr}")
        print("[OK] IP primário restaurado.")

    # 4) Remove qualquer 172.65.175.* diferente do alvo e aplica o alvo
    ps_clean_sec = fr"""
Get-NetIPAddress -InterfaceIndex {ifindex} -AddressFamily IPv4 |
  Where-Object {{ $_.IPAddress -like '172.65.175.*' -and $_.IPAddress -ne '{sec_ip}' }} |
  ForEach-Object {{ $_ | Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue }}
"""
    run_ps(ps_clean_sec)

    ps_has_sec = fr"""
(Get-NetIPAddress -InterfaceIndex {ifindex} -AddressFamily IPv4 |
  Where-Object {{ $_.IPAddress -eq '{sec_ip}' }}) -ne $null
"""
    if run_ps(ps_has_sec).strip().lower() != "true":
        r3 = subprocess.run([
            "netsh","interface","ip","add","address",
            f"name={alias}", sec_ip, SECONDARY_MASK
        ], capture_output=True, text=True)
        if r3.returncode != 0 and "exists" not in (r3.stderr or "").lower():
            raise SystemExit(f"[ERRO] add secundário:\n{r3.stderr}")
        print("[OK] IP secundário aplicado.")
    else:
        print("[OK] IP secundário já está correto.")

    print("\n[SUCESSO] Primário preservado, DNS fixos e secundário configurado.")

if __name__ == "__main__":
    main()
