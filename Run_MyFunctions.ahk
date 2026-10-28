#Requires AutoHotkey v2.0 64-bit
#SingleInstance Force
#Include %A_ScriptDir%\WebManipLib.ahk
#Include *i %A_ScriptDir%\MyFunctions.ahk   ; created by "Export" in WebManipBuilder.ahk

/************************************************************************
 * Example of using your exported functions.
 * Opens a browser window (logins/cookies are shared with the builder),
 * then hotkeys run your functions inside it.
 ***********************************************************************/
wm := WebManip(0, {title: 'Work Browser', url: 'https://example.com'})

; ---- Put your own hotkeys here. Examples (remove the leading ; to use): ----
; ^!1:: RunSafe(() => Login(wm, 'my.username', 'my password'))
; ^!2:: RunSafe(() => MsgBox('Status is: ' GetStatus(wm)))

; ---- Run a function once per row of a CSV / Excel file (first row = column names): ----
; ^!3:: RunSafe(() => EachRow('C:\Data\hours.xlsx', row => SubmitHours(wm, row['Name'], row['Hours'])))

; Runs fn(row) for every data row; a failed row is reported and skipped.
EachRow(file, fn) {
	failed := ''
	for row in WebManip.ReadTable(file) {
		try fn(row)
		catch as e
			failed .= 'File row ' row.SheetRow ': ' e.Message '`n'
	}
	MsgBox(failed = '' ? 'All rows done.' : 'Done. These rows failed:`n`n' failed, 'WebManip')
}

; Ctrl+Alt+R: run any exported function that takes no parameters, by name.
^!r:: {
	ib := InputBox('Function name to run:', 'Run function', 'w300 h110')
	if ib.Result = 'OK' && ib.Value != ''
		RunSafe(() => %ib.Value%(wm))
}

; You can also write steps by hand with plain CSS selectors or XPath:
;   wm.SetValue('#search', 'hello')
;   wm.Click('//button[normalize-space(.)="Search"]')
;   txt := wm.GetText('.result-count')
;   if wm.Exists('#error-banner', 2000) ...

RunSafe(fn) {
	try fn()
	catch as e
		MsgBox('Script stopped:`n`n' e.Message, 'WebManip', 'Icon!')
}
