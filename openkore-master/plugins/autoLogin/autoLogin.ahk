; ====== autoLogin.ahk — AHK v2 (foco + tecla ESC) ======
#Requires AutoHotkey v2
#SingleInstance Force
SendMode "Input"
SetTitleMatchMode 2
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

; ---------- Execução simples ----------
if (ShouldStop())
    ExitApp

hwnd := FindRagexeWindow()
if !hwnd
    ExitApp

if !ForceActivate(hwnd)
    ExitApp

if (ShouldStop())
    ExitApp

ReleaseMods()
Sleep 120
SendEsc()
Sleep 300
ExitApp

; ===================== util: stop =====================
ShouldStop() {
    global stopFlag
    return FileExist(stopFlag)
}

; ===================== Foco/ativação =====================
FindRagexeWindow() {
    list := WinGetList("ahk_exe ragexe.exe")
    if (list.Length = 0)
        return 0
    return list[1]
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

ReleaseMods() {
    for sc in [0x1D, 0x2A, 0x36, 0x38] {
        DllCall("keybd_event", "uchar", 0, "uchar", sc, "uint", 0x0002, "uptr", 0)
    }
}

SendEsc() {
    DllCall("keybd_event", "uchar", 0x1B, "uchar", 0x01, "uint", 0, "uptr", 0)
    Sleep 80
    DllCall("keybd_event", "uchar", 0x1B, "uchar", 0x01, "uint", 0x0002, "uptr", 0)
}
