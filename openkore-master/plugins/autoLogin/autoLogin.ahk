; ====== autoLogin.ahk — AHK v2 (focus forte + scancode + AHI opcional + stop flag + mutex) ======
#Requires AutoHotkey v2
#SingleInstance Force
SendMode "Input"
SetKeyDelay 30, 30
SetTitleMatchMode 2
CoordMode "Mouse", "Window"
SetWinDelay 30

; ---------- CLI: --port N / --port=N ----------
targetPort := ""
for idx, arg in A_Args {
    if RegExMatch(arg, "i)^--port(?:=(\d+))?$", &m) {
        if (m[1] != "")
            targetPort := m[1]
        else if (idx < A_Args.Length)
            targetPort := A_Args[idx + 1]
    }
}
if (targetPort = "")
    targetPort := "6901"

; stop flag (criado pelo .pl)
global stopFlag := A_ScriptDir "\autoLogin.stop_" targetPort

; ---------- mutex simples p/ 1 instância por porta ----------
lockFile := A_ScriptDir "\autoLogin.lock_" targetPort
if FileExist(lockFile) {
    ExitApp
}
FileAppend(FormatTime(, "yyyy-MM-dd HH:mm:ss") " tick=" A_TickCount "`r`n", lockFile, "UTF-8")
OnExit(() => (FileExist(lockFile) ? FileDelete(lockFile) : 0))

; ---------- INI helpers ----------
ini := A_ScriptDir "\autoLogin.ini"
logFile := A_ScriptDir "\autoLogin.log"

ReadStr(section, key, defaultVal := "") {
    global ini
    val := IniRead(ini, section, key, defaultVal)
    val := RegExReplace(val, "[;#].*$")
    return Trim(val)
}
ReadInt(section, key, defaultVal := 0) {
    val := ReadStr(section, key, defaultVal)
    if (val = "")
        return defaultVal
    if RegExMatch(val, "^-?\d+", &m)
        return Integer(m[0])
    return defaultVal
}
Log(msg) {
    global logFile, debug
    if (debug)
        FileAppend(FormatTime(, "yyyy-MM-dd HH:mm:ss") "  " msg "`r`n", logFile, "UTF-8")
}

; ---------- Config ----------
debug             := ReadInt("client", "debug", 1)
winW              := ReadInt("client", "width",  1024)
winH              := ReadInt("client", "height", 768)
runElev           := ReadInt("client", "run_elevated", 0)
forceRes          := ReadInt("client", "force_resize", 1)
autoRun           := ReadInt("client", "auto_run_if_missing", 0)

winW     := ReadInt("client_" targetPort, "width",  winW)
winH     := ReadInt("client_" targetPort, "height", winH)
runElev  := ReadInt("client_" targetPort, "run_elevated",  runElev)
forceRes := ReadInt("client_" targetPort, "force_resize",  forceRes)
autoRun  := ReadInt("client_" targetPort, "auto_run_if_missing", autoRun)

exePath     := ReadStr("ports", targetPort, "")
serverIndex := ReadInt("flow_" targetPort, "server_index", ReadInt("flow_default", "server_index", 0))
charSlot    := ReadInt("flow_" targetPort, "char_slot",    ReadInt("flow_default", "char_slot",    0))
passFill    := ReadStr("flow_" targetPort, "pass_fill",    ReadStr("flow_default", "pass_fill", "aaaa"))

; ENTER extra após clicar em JOGAR
global afterCharEnter := ReadInt("flow_" targetPort, "after_char_press_enter", ReadInt("flow_default", "after_char_press_enter", 1))
global afterCharDelay := ReadInt("flow_" targetPort, "after_char_enter_delay", ReadInt("flow_default", "after_char_enter_delay", 900))

; coords 1024x768
charX := ReadInt("coords_1024x768", "char_x", 160)
charY := ReadInt("coords_1024x768", "char_y", 220)
playX := ReadInt("coords_1024x768", "play_x", 890)
playY := ReadInt("coords_1024x768", "play_y", 620)

; ---------- Driver (AHI) ----------
useAHI       := ReadInt("driver", "use_ahi", 0)
ahi_kb_id    := ReadInt("driver", "keyboard_id", 0)
ahi_kb_index := ReadInt("driver", "keyboard_index", 1)

global AHI := "", AHI_Ready := false, AHI_DevId := 0
#Include *i %A_ScriptDir%\Lib\AutoHotInterception.ahk
if (useAHI && FileExist(A_ScriptDir "\Lib\AutoHotInterception.ahk")) {
    AHI := AutoHotInterception()
    if (ahi_kb_id > 0) {
        AHI_DevId := ahi_kb_id
        AHI_Ready := true
        Log("AHI: keyboard_id=" AHI_DevId)
    } else {
        devs := AHI.GetDeviceList()
        idx := 0
        Loop devs.Length {
            di := devs[A_Index]
            if (di.isMouse)
                continue
            idx += 1
            if (idx = ahi_kb_index) {
                AHI_DevId := di.Id
                AHI_Ready := true
                Log("AHI: keyboard_index=" ahi_kb_index " -> DevId=" AHI_DevId)
                break
            }
        }
        if (!AHI_Ready)
            Log("AHI: teclado não encontrado pelo keyboard_index=" ahi_kb_index)
    }
} else if (useAHI) {
    Log("AHI: Lib\\AutoHotInterception.ahk não encontrada. Prosseguindo sem driver.")
}

if (exePath = "") {
    MsgBox "autoLogin.ahk: porta " targetPort " não mapeada em [ports] do INI.", "autoLogin", "Iconx"
    ExitApp
}

; ---------- Execução ----------
Log("PORT=" targetPort " | EXE=" exePath)
hwnd := EnsureClientForPort(exePath, winW, winH, forceRes, autoRun)
if !hwnd {
    Log("Falha: não foi possível localizar/abrir a janela do cliente.")
    ExitApp
}

; ==== fluxo ====
TryConfirm(hwnd)                ; ENTER → 5s
DoLogin(hwnd, passFill)         ; TAB → (limpa) → senha → ENTER
ChooseServer(hwnd, serverIndex) ; ENTER + respiro maior p/ handshake
ChooseCharacter(hwnd, charX, charY, playX, playY)
Sleep 600
ExitApp

; ===================== util: stop/mutex =====================
ShouldStop() {
    global stopFlag
    return FileExist(stopFlag)
}

; ===================== Foco/ativação =====================
ForceActivate(hwnd, tries := 8) {
    Loop tries {
        if WinActive("ahk_id " hwnd)
            return true
        DllCall("ShowWindow", "ptr", hwnd, "int", 9) ; SW_RESTORE
        DllCall("BringWindowToTop", "ptr", hwnd)
        DllCall("SetForegroundWindow", "ptr", hwnd)
        DllCall("SetActiveWindow", "ptr", hwnd)
        DllCall("SetFocus", "ptr", hwnd)
        Sleep 60
        if WinActive("ahk_id " hwnd)
            return true
        hFore   := DllCall("GetForegroundWindow", "ptr")
        tidFore := DllCall("GetWindowThreadProcessId", "ptr", hFore, "uint*", 0, "uint")
        tidThis := DllCall("GetCurrentThreadId", "uint")
        tidTgt  := DllCall("GetWindowThreadProcessId", "ptr", hwnd, "uint*", 0, "uint")
        DllCall("AttachThreadInput", "uint", tidThis, "uint", tidFore, "int", 1)
        DllCall("AttachThreadInput", "uint", tidThis, "uint", tidTgt,  "int", 1)
        DllCall("BringWindowToTop", "ptr", hwnd)
        DllCall("SetForegroundWindow", "ptr", hwnd)
        DllCall("SetActiveWindow", "ptr", hwnd)
        DllCall("SetFocus", "ptr", hwnd)
        DllCall("AttachThreadInput", "uint", tidThis, "uint", tidTgt,  "int", 0)
        DllCall("AttachThreadInput", "uint", tidThis, "uint", tidFore, "int", 0)
        Sleep 80
        if WinActive("ahk_id " hwnd)
            return true
    }
    return false
}
FocusClick(hwnd) {
    if !WinExist("ahk_id " hwnd)
        return
    if !ForceActivate(hwnd)
        return
    WinGetPos &wx, &wy, &ww, &wh, "ahk_id " hwnd
    Click ww//2, wh//2
}

; ===================== Teclado (SendInput + AHI) =====================
ReleaseMods() {
    ; Ctrl(0x1D), Shift-L(0x2A), Shift-R(0x36), Alt(0x38)
    for sc in [0x1D, 0x2A, 0x36, 0x38] {
        ; OS
        DllCall("keybd_event", "uchar", 0, "uchar", sc, "uint", 0x0002, "uptr", 0) ; KEYEVENTF_KEYUP via vk=0 + sc
        ; AHI
        if (AHI_Ready)
            try AHI.SendKeyEvent(AHI_DevId, sc, 0)
    }
}
HardKeyEvent(sc, isExtended := false, isDown := true) {
    flags := 0x0008
    if (isExtended) flags |= 0x0001
    if (!isDown)    flags |= 0x0002
    size := (A_PtrSize = 8) ? 40 : 28
    buf  := Buffer(size, 0)
    NumPut("UInt",   1,  buf, 0)
    NumPut("UShort", 0,  buf, 4)
    NumPut("UShort", sc, buf, 6)
    NumPut("UInt",   flags, buf, 8)
    NumPut("UInt",   0,  buf, 12)
    NumPut("Ptr",    0,  buf, 16)
    DllCall("SendInput", "UInt", 1, "Ptr", buf.Ptr, "Int", size)
}
HardPressScan(sc, isExtended := false, holdMs := 60) {
    HardKeyEvent(sc, isExtended, true)
    Sleep holdMs
    HardKeyEvent(sc, isExtended, false)
}
GetScanByName(name, &sc, &ext) {
    static tbl := Map(
        "ENTER", [0x1C, false],
        "TAB",   [0x0F, false],
        "HOME",  [0x47, true],
        "DOWN",  [0x50, true],
        "BACK",  [0x0E, false],
        "CTRL",  [0x1D, false]
    )
    sw := StrUpper(Trim(name))
    if tbl.Has(sw) {
        sc  := tbl[sw][1], ext := tbl[sw][2]
        return 1
    }
    sc := 0, ext := false
    return 0
}
HardPress(name, holdMs := 60) {
    sc := 0, ext := false
    if (GetScanByName(name, &sc, &ext))
        HardPressScan(sc, ext, holdMs)
}

; ===== AHI – compat layer =====
AHI_Send(sc, down, isExt := false) {
    global AHI, AHI_DevId, AHI_Ready
    static mode := ""   ; "4","3","ext","none"
    if (!AHI_Ready || !IsObject(AHI) || !AHI_DevId)
        return false

    if (mode = "4") {
        try {
            AHI.SendKeyEvent(AHI_DevId, sc, down, isExt)
            return true
        } catch as e {
            mode := ""
        }
    }
    if (mode = "3") {
        try {
            AHI.SendKeyEvent(AHI_DevId, sc, down)
            return true
        } catch as e {
            mode := ""
        }
    }
    if (mode = "ext") {
        try {
            AHI.SendExtendedKeyEvent(AHI_DevId, sc, down, isExt)
            return true
        } catch as e {
            mode := ""
        }
    }

    try {
        AHI.SendKeyEvent(AHI_DevId, sc, down, isExt), mode := "4"
        return true
    } catch as e {}
    try {
        AHI.SendKeyEvent(AHI_DevId, sc, down), mode := "3"
        return true
    } catch as e {}
    try {
        AHI.SendExtendedKeyEvent(AHI_DevId, sc, down, isExt), mode := "ext"
        return true
    } catch as e {}

    mode := "none"
    return false
}
AHI_PressSC(sc, isExt := false, holdMs := 60) {
    if (!AHI_Send(sc, 1, isExt))
        return
    Sleep holdMs
    AHI_Send(sc, 0, isExt)
}
AHI_PressName(name, holdMs := 60) {
    sc := 0, ext := false
    if (GetScanByName(name, &sc, &ext))
        AHI_PressSC(sc, ext, holdMs)
}
TypeBothAZ09(text, perKeyMs := 40) {
    for char in StrSplit(text) {
        u := StrUpper(char)
        if (u ~= "^[A-Z0-9]$") {
            vk := Ord(u)
            sc := DllCall("MapVirtualKey", "UInt", vk, "UInt", 0, "UInt")
            HardPressScan(sc, false, perKeyMs)
            if (AHI_Ready)
                AHI_PressSC(sc, false, perKeyMs)
        }
    }
}

; ===================== Util / Janela alvo =====================
NormalizePath(p) {
    p := StrReplace(p, "/", "\")
    return StrLower(p)
}
GetProcessPath(pid) {
    h := DllCall("OpenProcess", "UInt", 0x1000, "Int", 0, "UInt", pid, "Ptr")
    if (!h)
        return ""
    size := 512
    buf  := Buffer(size*2, 0) ; UTF-16
    ok := DllCall("QueryFullProcessImageNameW", "Ptr", h, "UInt", 0, "Ptr", buf.Ptr, "UInt*", size)
    DllCall("CloseHandle", "Ptr", h)
    if (ok) {
        return StrLower(StrReplace(StrGet(buf.Ptr, size, "UTF-16"), "/", "\")) ; escape
    }
    return ""
}
EnsureClientForPort(exePath, w, h, forceRes, autoRun) {
    exeN := NormalizePath(exePath)
    hwnd := FindWindowByExePath(exeN)
    if !hwnd && autoRun {
        Run exePath
        hwnd := WaitForWindowByPath(exeN, 20000)
    }
    if !hwnd
        return 0
    if !ForceActivate(hwnd)
        return 0

    if (forceRes) {
        rect := Buffer(16, 0)
        ok := DllCall("GetWindowRect", "ptr", hwnd, "ptr", rect.Ptr)
        if (ok) {
            left   := NumGet(rect, 0,  "int")
            top    := NumGet(rect, 4,  "int")
            right  := NumGet(rect, 8,  "int")
            bottom := NumGet(rect, 12, "int")
            cw := right - left, ch := bottom - top
            if (cw != w || ch != h) {
                Log("Redimensionando para " w "x" h)
                DllCall("MoveWindow", "ptr", hwnd, "int", left, "int", top, "int", w, "int", h, "int", 1)
                Sleep 200
            }
        } else {
            Log("GetWindowRect falhou")
        }
    }
    return hwnd
}
FindWindowByExePath(exeN) {
    list := WinGetList("ahk_exe ragexe.exe")
    for hwnd in list {
        pid := WinGetPID(hwnd)
        path := GetProcessPath(pid)
        if (path != "" && path = exeN)
            return hwnd
    }
    return 0
}
WaitForWindowByPath(exeN, timeoutMs := 10000) {
    t0 := A_TickCount
    while (A_TickCount - t0 < timeoutMs) {
        hwnd := FindWindowByExePath(exeN)
        if (hwnd)
            return hwnd
        Sleep 250
    }
    return 0
}

; ===================== Fluxo =====================
TryConfirm(hwnd) {
    if (ShouldStop()) ExitApp
    FocusClick(hwnd)
    ReleaseMods()
    Sleep 150
    HardPress("ENTER", 60), AHI_PressName("ENTER", 60)
    Sleep 5000
}
DoLogin(hwnd, passFill) {
    if (ShouldStop()) ExitApp
    FocusClick(hwnd)
    ReleaseMods()
    Sleep 150
    HardPress("TAB", 60), AHI_PressName("TAB", 60)
    Sleep 2000

    ; Ctrl+A + Backspace — OS
    HardKeyEvent(0x1D, false, true)   ; Ctrl down
    scA := DllCall("MapVirtualKey", "UInt", 0x41, "UInt", 0, "UInt")
    HardPressScan(scA, false, 40)     ; A
    HardKeyEvent(0x1D, false, false)  ; Ctrl up
    HardPress("BACK", 40)

    ; AHI (se disponível)
    if (AHI_Ready) {
        AHI_Send(0x1D, 1, false)
        AHI_Send(scA,  1, false)
        Sleep 40
        AHI_Send(scA,  0, false)
        AHI_Send(0x1D, 0, false)
        AHI_PressName("BACK", 40)
    }

    TypeBothAZ09(passFill, 40)
    Sleep 200
    HardPress("ENTER", 60), AHI_PressName("ENTER", 60)
    Sleep 1400
}
ChooseServer(hwnd, idx) {
    if (ShouldStop()) ExitApp
    FocusClick(hwnd)
    ReleaseMods()
    Sleep 150
    ; Basta ENTER no servidor já focado
    HardPress("ENTER", 60), AHI_PressName("ENTER", 60)

    ; >>> Janela crítica: dê tempo pro handshake (token→char). <<<
    ; Acelerar demais aqui costuma derrubar a sessão.
    Sleep 2500
}
ChooseCharacter(hwnd, charX, charY, playX, playY) {
    if (ShouldStop()) ExitApp
    FocusClick(hwnd)
    ReleaseMods()
    Sleep 200
    Click charX, charY
    Sleep 200
    Click playX, playY
    Sleep 500
    if (afterCharEnter) {
        HardPress("ENTER", 60), AHI_PressName("ENTER", 60)
        Sleep afterCharDelay
    }
}

; Hotkey de debug: F8 mostra X/Y
F8:: {
    MouseGetPos &mx, &my
    ToolTip "X:" mx "  Y:" my, mx+20, my+20
    Sleep 900
    ToolTip
}
