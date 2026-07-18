Option Explicit
Dim fso, shell, scriptDir, ps1, cmd, mode, sessionPath
Set fso = CreateObject("Scripting.FileSystemObject")
Set shell = CreateObject("WScript.Shell")
scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
ps1 = scriptDir & "\auto_archive.ps1"
If WScript.Arguments.Count < 1 Then WScript.Quit 2
mode = WScript.Arguments(0)
If StrComp(mode, "Session", vbTextCompare) <> 0 And StrComp(mode, "Recovery", vbTextCompare) <> 0 Then WScript.Quit 2

cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File " & QuoteArgument(ps1) & " -RunMode " & mode
If StrComp(mode, "Session", vbTextCompare) = 0 Then
    If WScript.Arguments.Count <> 2 Then WScript.Quit 2
    sessionPath = WScript.Arguments(1)
    If InStr(sessionPath, Chr(34)) > 0 Or InStr(sessionPath, vbCr) > 0 Or InStr(sessionPath, vbLf) > 0 Then WScript.Quit 2
    cmd = cmd & " -SessionPath " & QuoteArgument(sessionPath)
Else
    If WScript.Arguments.Count <> 1 Then WScript.Quit 2
End If

shell.Run cmd, 0, False

Function QuoteArgument(value)
    QuoteArgument = Chr(34) & value & Chr(34)
End Function
