; ====== autoLogin.ahk — AHK v2 (focar ragexe + ESC) ======
#SingleInstance Force
SendMode "Input"
SetTitleMatchMode 2
CoordMode "Mouse", "Window"
SetKeyDelay 30, 30
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

; ---------- Le exe do INI ----------
ini    := A_ScriptDir "\autoLogin.ini"
exePath := IniRead(ini, "ports", targetPort, "")
if (exePath = "") {
    MsgBox "autoLogin.ahk: porta " targetPort " não mapeada em [ports] do INI.", "autoLogin", "Iconx"
    ExitApp
}

; ---------- Foca janela alvo ----------
hwnd := EnsureClientForPort(NormalizePath(exePath))
if !hwnd {
    ExitApp
}

; ---------- Pressiona ESC ----------
HardPressScan(0x01, false, 60) ; ESC (SC=0x01)
ExitApp

; ===================== helpers =====================
NormalizePath(p) {
    p := StrReplace(p, "/", "\")
    return StrLower(p)
}
EnsureClientForPort(exeN) {
    hwnd := FindWindowByExePath(exeN)
    if !hwnd
        return 0
    if !ForceActivate(hwnd)
        return 0
    return hwnd
}
FindWindowByExePath(exeN) {
    list := WinGetList("ahk_exe ragexe.exe")
    for hwnd in list {
        pid  := WinGetPID(hwnd)
        path := GetProcessPath(pid)
        if (path != "" && path = exeN)
            return hwnd
    }
    return 0
}
ForceActivate(hwnd, tries := 8) {
    Loop tries {
        if WinActive("ahk_id " hwnd)
            return true
        DllCall("ShowWindow", "ptr", hwnd, "int", 9) ; SW_RESTORE
        DllCall("BringWindowToTop", "ptr", hwnd)
        DllCall("SetForegroundWindow", "ptr", hwnd)
        DllCall("SetActiveWindow", "ptr", hwnd)
        DllCall("SetFocus", "ptr", hwnd)
        Sleep 80
        if WinActive("ahk_id " hwnd)
            return true
        ; Focus bridge
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

; ----- SendInput por scancode -----
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
HardPressScan(sc, isExt := false, holdMs := 60) {
    HardKeyEvent(sc, isExt, true)
    Sleep holdMs
    HardKeyEvent(sc, isExt, false)
}
