#Requires AutoHotkey v2
#SingleInstance Force

; Include conforme sua estrutura:
#Include %A_ScriptDir%\Lib\AutoHotInterception.ahk

if !FileExist(A_ScriptDir "\Lib\AutoHotInterception.ahk") {
    MsgBox "Não encontrei: " A_ScriptDir "\Lib\AutoHotInterception.ahk`n"
         . "Coloque a pasta Lib do AHI aqui e tente novamente."
    ExitApp
}

; --- cria o objeto do AHI ---
AHI := ""
try {
    AHI := AutoHotInterception()
} catch as e {
    MsgBox "Falha ao carregar AHI: " e.Message
    ExitApp
}

outLines := []
idx := 0

; --- 1) Tenta API que já retorna apenas teclados (lista de IDs) ---
ids := []
try {
    ids := AHI.GetKeyboards()
} catch as e {
    ids := []
}

if (IsObject(ids) && ids.Length > 0) {
    for _, devId in ids {
        idx += 1
        vid := "", pid := "", handle := ""
        info := ""
        try info := AHI.GetDeviceInfo(devId)
        if IsObject(info) {
            try vid := Format("{:04X}", info.Vid)
            try pid := Format("{:04X}", info.Pid)
            try handle := info.Handle
        }
        lineTxt := Format("index={:02} | keyboard_id={}", idx, devId)
        if (vid != "")
            lineTxt .= Format(" | VID=0x{} | PID=0x{}", vid, pid)
        if (handle != "")
            lineTxt .= " | Handle=" handle
        outLines.Push(lineTxt)
    }
} else {
    ; --- 2) Fallback: GetDeviceList() (pode devolver ints ou objetos) ---
    devs := []
    try {
        devs := AHI.GetDeviceList()
    } catch as e {
        devs := []
    }

    for _, dv in devs {
        devId := dv
        isMouse := false
        vid := "", pid := "", handle := ""

        if IsObject(dv) {
            devId := dv.Id
            try if (dv.HasOwnProp("isMouse") && dv.isMouse)
                isMouse := true
            if (!isMouse) {
                try vid := Format("{:04X}", dv.Vid)
                try pid := Format("{:04X}", dv.Pid)
                try handle := dv.Handle
            }
        } else {
            info := ""
            try info := AHI.GetDeviceInfo(devId)
            if IsObject(info) {
                try if (info.HasOwnProp("isMouse") && info.isMouse)
                    isMouse := true
                if (!isMouse) {
                    try vid := Format("{:04X}", info.Vid)
                    try pid := Format("{:04X}", info.Pid)
                    try handle := info.Handle
                }
            }
        }

        if (isMouse)
            continue

        idx += 1
        lineTxt := Format("index={:02} | keyboard_id={}", idx, devId)
        if (vid != "")
            lineTxt .= Format(" | VID=0x{} | PID=0x{}", vid, pid)
        if (handle != "")
            lineTxt .= " | Handle=" handle
        outLines.Push(lineTxt)
    }
}

if (outLines.Length = 0) {
    MsgBox "Nenhum teclado detectado pelo AHI.`n"
         . "Instale o driver Interception e reinicie o Windows."
    ExitApp
}

; --- grava o arquivo de saída ---
outPath := A_ScriptDir "\AHI_keyboards.txt"
fh := FileOpen(outPath, "w", "UTF-8")
fh.WriteLine("Lista de teclados (AHI) — use keyboard_index ou keyboard_id no autoLogin.ini")
fh.WriteLine("---------------------------------------------------------------")
for _, lineTxt in outLines
    fh.WriteLine(lineTxt)
fh.WriteLine("---------------------------------------------------------------")
fh.Close()

; --- copia automaticamente a lista inteira para a área de transferência ---
clip := ""
for _, lineTxt in outLines
    clip .= lineTxt "`r`n"
A_Clipboard := RTrim(clip, "`r`n")

; --- preview e sair automaticamente após OK ---
preview := ""
showN := (outLines.Length < 6) ? outLines.Length : 6
Loop showN
    preview .= outLines[A_Index] "`n"

MsgBox "Teclados detectados (" outLines.Length "):`n`n" preview "`nArquivo salvo em:`n" outPath
ExitApp
