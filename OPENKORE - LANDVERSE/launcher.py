import os
import sys
import subprocess
import msvcrt
import ctypes
import time

try:
    from colorama import init, Fore, Style, Back
except ImportError:
    subprocess.check_call([sys.executable, "-m", "pip", "install", "colorama"])
    from colorama import init, Fore, Style, Back

init(autoreset=True)

def is_admin():
    try:
        return ctypes.windll.shell32.IsUserAnAdmin()
    except:
        return False

def get_key():
    key = msvcrt.getch()
    if key == b'\xe0' or key == b'\x00':  # Arrow keys prefix
        key = msvcrt.getch()
        return {b'H': 'up', b'P': 'down'}.get(key, None)
    elif key == b'\r':
        return 'enter'
    return None

def select_port():
    options = ["2350", "2351", "2352"]
    selected = 0
    
    while True:
        os.system('cls' if os.name == 'nt' else 'clear')
            
        print("\n")
        print(f"    {Fore.CYAN}" + "="*40)
        print(f"          {Fore.YELLOW}OPENKORE LAUNCHER - SELECT PORT")
        print(f"    {Fore.CYAN}" + "="*40)
        print(f"\n         {Fore.RESET}Use UP/DOWN arrows and ENTER\n")
            
        for i, option in enumerate(options):
            if i == selected:
                print(f"            {Fore.GREEN}>> [ {option} ] <<")
            else:
                print(f"                 {Fore.WHITE}{option}     ")
            
        print(f"\n    {Fore.CYAN}" + "="*40 + "\n")
            
        # Simple debounce/wait for key
        action = get_key()
        if action == 'up':
            selected = (selected - 1) % len(options)
        elif action == 'down':
            selected = (selected + 1) % len(options)
        elif action == 'enter':
            return options[selected]

def read_config(path):
    config = {}
    if not os.path.exists(path):
        return config
    with open(path, 'r') as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith(';'): continue
            if '=' in line:
                key, value = line.split('=', 1)
                config[key.strip()] = value.strip()
    return config

def main():
    script_dir = os.path.dirname(os.path.abspath(__file__))
    os.chdir(script_dir)
    
    # 1. Select Port
    port = select_port()
    print(f"\n{Fore.GREEN}Selected Port: {port}")
    os.environ["OPENKORE_PORT"] = port

    # 2. Load Config
    config = read_config("config.ini")
    game_folder = config.get("GAME_FOLDER")
    game_exe = config.get("GAME_EXE")
    game_arg = config.get("GAME_ARG", "")

    if not game_folder or not game_exe:
        print(f"{Fore.RED}Error: Missing GAME_FOLDER or GAME_EXE in config.ini")
        input("Press Enter to exit...")
        return

    # 3. Launch Game
    print(f"{Fore.YELLOW}Launching Game...")
    
    # Check if paths are absolute, if not, assume relative to game folder? 
    # Usually GAME_FOLDER is absolute or relative to script. 
    # Batch did `cd /d %GAME_FOLDER%`.
    
    try:
        # Resolve game exe path. If it's just a filename, it's expected to be in GAME_FOLDER
        game_exe_path = os.path.join(game_folder, game_exe) if not os.path.isabs(game_exe) else game_exe
        
        args = [game_exe_path]
        if game_arg:
            args.extend(game_arg.split())

        # Launch process
        game_process = subprocess.Popen(
            args,
            cwd=game_folder,
            shell=False 
        )
        print(f"{Fore.GREEN}Game launched with PID: {game_process.pid}")
    except Exception as e:
        print(f"{Fore.RED}Failed to launch game: {e}")
        input("Press Enter to exit...")
        return

    # 4. Launch OpenKore
    print(f"{Fore.YELLOW}Launching OpenKore...")
    # OpenKore must be run from script_dir (which we are in)
    
    try:
        subprocess.run(["perl", "openkore.pl"], cwd=script_dir)
    except KeyboardInterrupt:
        pass 
    except Exception as e:
        print(f"{Fore.RED}Error running OpenKore: {e}")

    # 5. Kill Game Process
    print(f"{Fore.YELLOW}OpenKore closed. Terminating Game...")
    try:
        subprocess.run(["taskkill", "/PID", str(game_process.pid), "/F"])
    except Exception as e:
        print(f"{Fore.RED}Error killing game process: {e}")

if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        print(f"{Fore.RED}Critical Error: {e}")
        input("Press Enter to exit...")