Option Explicit

Dim shell, fso, scriptDir, ps1, sessionPath, cmd
If WScript.Arguments.Count <> 1 Then WScript.Quit 2

sessionPath = WScript.Arguments(0)
If InStr(sessionPath, Chr(34)) > 0 Or InStr(sessionPath, vbCr) > 0 Or InStr(sessionPath, vbLf) > 0 Then WScript.Quit 3

Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
ps1 = fso.BuildPath(scriptDir, "session_worker.ps1")
If Not fso.FileExists(ps1) Then WScript.Quit 4

cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File " & QuoteArgument(ps1) & " -SessionPath " & QuoteArgument(sessionPath)
shell.Run cmd, 0, False

Function QuoteArgument(value)
    QuoteArgument = Chr(34) & Replace(value, Chr(34), Chr(34) & Chr(34)) & Chr(34)
End Function
