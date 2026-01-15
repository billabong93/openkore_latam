; ====== autoFocus.ahk — AHK v2 (focus forte / scancode / AHI) ======
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

; ---------- INI helpers ----------
ini := A_ScriptDir "\autoFocus.ini"
logFile := A_ScriptDir "\autoFocus.log"

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

exePath := ReadStr("ports", targetPort, "")

; ---------- Driver (AHI) ----------
useAHI       := ReadInt("driver", "use_ahi", 0)
ahi_kb_id    := ReadInt("driver", "keyboard_id", 0)       ; se 0, tentamos pelo index
ahi_kb_index := ReadInt("driver", "keyboard_index", 1)    ; 1 = primeiro teclado

global AHI := "", AHI_Ready := false, AHI_DevId := 0
#Include *i %A_ScriptDir%\Lib\AutoHotInterception.ahk
if (useAHI && FileExist(A_ScriptDir "\Lib\AutoHotInterception.ahk")) {
    AHI := AutoHotInterception()
    if (ahi_kb_id > 0) {
        AHI_DevId := ahi_kb_id
        AHI_Ready := true
        Log("AHI: usando keyboard_id=" AHI_DevId)
    } else {
        devs := AHI.GetDeviceList()
        idx := 0
        loop devs.Length {
            di := devs[A_Index]
            if (di.isMouse)
                continue
            idx += 1
            if (idx = ahi_kb_index) {
                AHI_DevId := di.Id
                AHI_Ready := true
                Log("AHI: keyboard_index=" ahi_kb_index " -> DevId=" AHI_DevId " VID=" Format("{:04X}", di.Vid) " PID=" Format("{:04X}", di.Pid))
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
    MsgBox "autoFocus.ahk: porta " targetPort " não mapeada em [ports] do INI.", "autoFocus", "Iconx"
    ExitApp
}

; --------------- Elevação ---------------
if (runElev = 1 && !A_IsAdmin) {
    Log("Reexecutando elevado...")
    Run Format('*RunAs "{}" --port {}', A_ScriptFullPath, targetPort)
    ExitApp
}

; ------------ Execução (Foco e ESC) ------------
Log("PORT=" targetPort " | EXE=" exePath)
hwnd := EnsureClientForPort(exePath, winW, winH, forceRes, autoRun)
if !hwnd {
    Log("Falha: não foi possível localizar/abrir a janela do cliente.")
    ExitApp
}
FocusClick(hwnd)
Sleep 150
PressBoth("ENTER", 60)   ; <<< único keypress solicitado
Sleep 200
ExitApp

; ===================== Forçar ativação + foco (WinAPI) =====================
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

; ===================== Scancode (SendInput) / AHI (driver) =====================
HardKeyEvent(sc, isExtended := false, isDown := true) {
    flags := 0x0008
    if (isExtended) flags |= 0x0001
    if (!isDown)    flags |= 0x0002
    size := (A_PtrSize = 8) ? 40 : 28
    buf  := Buffer(size, 0)
    NumPut("UInt",   1,  buf, 0)          ; INPUT_KEYBOARD
    NumPut("UShort", 0,  buf, 4)          ; wVk=0 (usar SC)
    NumPut("UShort", sc, buf, 6)          ; wScan
    NumPut("UInt",   flags, buf, 8)       ; dwFlags
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
        "ESC",   [0x01, false],   ;  <<< adicionado
        "ENTER", [0x1C, false],
        "TAB",   [0x0F, false],
        "HOME",  [0x47, true],
        "DOWN",  [0x50, true],
        "BACK",  [0x0E, false],
        "CTRL",  [0x1D, false]
    )
    sw := StrUpper(Trim(name))
    if tbl.Has(sw) {
        sc  := tbl[sw][1]
        ext := tbl[sw][2]
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

; ======= AHI (4 args / 3 args / Extendendido) =======
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
        AHI.SendKeyEvent(AHI_DevId, sc, down, isExt)
        mode := "4"
        return true
    } catch as e {
    }
    try {
        AHI.SendKeyEvent(AHI_DevId, sc, down)
        mode := "3"
        return true
    } catch as e {
    }
    try {
        AHI.SendExtendedKeyEvent(AHI_DevId, sc, down, isExt)
        mode := "ext"
        return true
    } catch as e {
    }

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

; ----- Camada combinada (driver + scancode) -----
PressBoth(name, holdMs := 60) {
    HardPress(name, holdMs)
    AHI_PressName(name, holdMs)
}

; ===================== Utils Win32 =====================
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

; ===================== Janela alvo =====================
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

; (F8 para mostrar X/Y permanece)
F8:: {
    MouseGetPos &mx, &my
    ToolTip "X:" mx "  Y:" my, mx+20, my+20
    Sleep 900
    ToolTip
}
