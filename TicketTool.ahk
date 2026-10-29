#Requires AutoHotkey v2.0 64-bit
#SingleInstance Force
#Include %A_ScriptDir%\WebManipLib.ahk
#Include %A_ScriptDir%\TicketLib.ahk        ; this project's functions (row pages, gather data, HTTP)
#Include *i %A_ScriptDir%\MyFunctions.ahk   ; functions exported from WebManipBuilder.ahk

/************************************************************************
 * Ticket Tool
 *   Left:   list (top half) + ticket fields (bottom half)
 *   Middle: tabs, each holding its own browser
 *   Right:  buttons you set up in ButtonClicked() below
 *
 * Useful bits for your own code:
 *   app.Web['Remedy']            the Remedy browser (a WebManip, so .Click, .SetValue, .GetText ... work)
 *   app.Current                  the browser on the tab that is showing
 *   app.Fields['Ticket'].Value   read/write a field: Ticket, Description, Account, Category, Symptom
 *   app.List                     the ListView (app.List.Add(, 'col1', 'col2', ...))
 *   app.ShowTab('AOS')           switch tab by name or number
 *   app.AddTab('Name ✕', url)    open a temporary tab; app.RemoveTab(wm) closes it
 *
 * Pop-ups (like sign-in windows) open in an extra "Pop-up ✕" tab and close by themselves
 * when the site is done with them. Right-click a pop-up tab to close it yourself.
 ***********************************************************************/

; ---- Tabs: name and start page (leave url '' for a blank page) ----
TABS := [
	{name: 'Remedy', url: ''},
	{name: 'AOS',    url: ''},
	{name: 'Sat',    url: ''},
	{name: 'Scope',  url: ''},
]

; ---- Button captions, top to bottom. Add or remove as you like. ----
BUTTONS := ['Gather data', 'Button 2', 'Button 3', 'Button 4', 'Button 5',
	'Button 6', 'Button 7', 'Button 8', 'Button 9', 'Button 10']

app := TicketApp(TABS, BUTTONS)

; ---- Placeholder rows so the list isn't empty. Remove these when you load real tickets. ----
; Columns: Ticket, Description, Account, Category, Symptom
app.List.Add(, 'INC0001001', 'Printer offline', '1000234', 'Hardware', 'No power')
app.List.Add(, 'INC0001002', 'Cannot log in', '1000871', 'Access', 'Password expired')
app.List.Add(, 'INC0001003', 'Slow internet', '1000502', 'Network', 'Drops every hour')
app.List.ModifyCol()

; ---- What each button does. n = button number (1 = top). ----
ButtonClicked(n, *) {
	try {
		switch n {
		case 1: GatherData(app)   ; settings are in TicketLib.ahk
		; case 2: app.Web['Remedy'].Click('#search')
		; case 3: app.Fields['Account'].Value := app.Web['AOS'].GetText('#acct')
		default:
			ToolTip('Button ' n ' is not set up yet.')
			SetTimer(() => ToolTip(), -1500)
		}
	} catch as e
		MsgBox('Button ' n ' stopped:`n`n' e.Message, 'Ticket Tool', 'Icon!')
}

; ---- Runs when you click a row in the list. Fills the fields from the row's columns. ----
RowSelected(row) {
	for i, key in ['Ticket', 'Description', 'Account', 'Category', 'Symptom']
		app.Fields[key].Value := app.List.GetText(row, i)
}

; ---- Runs when you double-click a row. Opens that ticket's pages (set them in TicketLib.ahk). ----
RowDoubleClicked(row) {
	ticket := app.List.GetText(row, 1), account := app.List.GetText(row, 3)
	try {
		if !OpenRowPages(app, ticket, account) {
			ToolTip('No pages set up yet. Fill in ROW_PAGES in TicketLib.ahk.')
			SetTimer(() => ToolTip(), -2500)
		}
	} catch as e
		MsgBox('Could not open the pages:`n`n' e.Message, 'Ticket Tool', 'Icon!')
}


class TicketApp {
	__New(tabs, buttons) {
		this.S := (n) => Round(n * A_ScreenDPI / 96)
		S := this.S
		g := this.gui := Gui('+Resize -DPIScale +MinSize' S(900) 'x' S(520), 'Ticket Tool')
		g.SetFont('s9', 'Segoe UI')
		g.OnEvent('Close', (*) => ExitApp())
		g.OnEvent('Size', (gui, minMax, w, h) => minMax != -1 && this.Layout(w, h))

		; left: list + fields
		this.List := g.Add('ListView', 'Grid -Multi', ['Ticket', 'Description', 'Account', 'Category', 'Symptom'])
		this.List.OnNotify(-101, ObjBindMethod(this, '_ListChanged'))   ; fires on click, arrow keys and code
		this.List.OnEvent('DoubleClick', (lv, row) => row && RowDoubleClicked(row))
		this.Fields := Map(), this.Fields.CaseSense := false
		this.labels := Map()
		for f in [['Ticket', 'Ticket number'], ['Description', 'Description'], ['Account', 'Account number'],
				['Category', 'Category'], ['Symptom', 'Symptom']] {
			this.labels[f[1]] := g.Add('Text', '', f[2])
			this.Fields[f[1]] := g.Add('Edit', f[1] = 'Description' ? 'Multi WantReturn VScroll' : '')
		}

		; middle: tabs (the browsers sit on top of the tab's page area)
		this.names := []
		for t in tabs
			this.names.Push(t.name)
		this.tab := g.Add('Tab3', '', this.names)
		this.tab.UseTab()
		this.tab.OnEvent('Change', (*) => this.ShowTab(this.tab.Value))
		this.tab.OnEvent('ContextMenu', ObjBindMethod(this, '_TabRightClick'))   ; right-click a pop-up tab to close it

		; address bar under the tabs; it always works on the tab that is showing
		this.navBack := g.Add('Button', '', '◀')
		this.navBack.OnEvent('Click', (*) => this.Current.Back())
		this.navFwd := g.Add('Button', '', '▶')
		this.navFwd.OnEvent('Click', (*) => this.Current.Forward())
		this.navReload := g.Add('Button', '', '⟳')
		this.navReload.OnEvent('Click', (*) => this.Current.Reload())
		this.urlBox := g.Add('Edit', '')
		this.navGo := g.Add('Button', 'Default', 'Go')   ; Default = Enter in the address box presses Go
		this.navGo.OnEvent('Click', (*) => this.GoUrl())

		; right: buttons
		this.buttons := []
		for i, cap in buttons {
			b := g.Add('Button', '', cap)
			b.OnEvent('Click', ButtonClicked.Bind(i))
			this.buttons.Push(b)
		}

		g.Show('w' S(1500) ' h' S(850))

		; one browser per tab (all share logins/cookies with the builder)
		this.Web := Map(), this.Web.CaseSense := false
		this.views := []
		for n, t in tabs {
			wm := WebManip(g.Hwnd, t.url != '' ? {url: t.url} : {})
			wm.OnNavigated := ObjBindMethod(this, '_UrlChanged', wm)
			wm.OnPopup := ObjBindMethod(this, '_AddPopup')
			this.Web[t.name] := wm
			this.views.Push(wm)
		}
		g.GetClientPos(, , &w, &h)
		this.Layout(w, h)
		this.ShowTab(1)
	}

	Current => this.views[this.tab.Value]

	_ListChanged(lv, p) {   ; LVN_ITEMCHANGED: call RowSelected when a row becomes selected
		off := A_PtrSize * 3
		item := NumGet(p, off, 'int'), newState := NumGet(p, off + 8, 'uint'), oldState := NumGet(p, off + 12, 'uint')
		if item >= 0 && (newState & 2) && !(oldState & 2)
			RowSelected(item + 1)
	}

	ShowTab(which) {
		i := which
		if !IsInteger(which)
			for n, name in this.names
				if name = which
					i := n
		this.tab.Value := i
		for n, wm in this.views
			wm.ctrl.IsVisible := (n = i)
		this._UrlChanged(this.views[i])
	}

	; ---- temporary tabs: pop-ups (e.g. sign-in windows) and tabs opened from code.
	; They sit after the fixed tabs, close when the page closes itself, or on right-click.

	/** Opens a temporary tab and returns its browser. Close it with RemoveTab(). */
	AddTab(name := 'Tab ✕', url := '') {
		wm := WebManip(this.gui.Hwnd, {env: this.views[1].env, hidden: true})
		this._AddTemp(wm, name)
		if url != ''
			wm.Navigate(url, false)
		return wm
	}

	/** Closes a temporary tab. If it was showing, goes back to the tab you were on before. */
	RemoveTab(wm) {
		cur := this.Current, found := false
		for i, v in this.views
			if v = wm && i > this.Web.Count {
				this.views.RemoveAt(i), this.names.RemoveAt(i)
				this.tab.Delete(i)
				found := true
				break
			}
		wm.Close()
		if !found
			return
		target := cur = wm ? wm.returnTo : cur, back := 1
		for i, v in this.views
			if v = target
				back := i
		this.ShowTab(back)
	}

	_AddPopup(pop) => this._AddTemp(pop, 'Pop-up ✕')

	_AddTemp(wm, name) {
		wm.returnTo := this.Current
		wm.OnNavigated := ObjBindMethod(this, '_UrlChanged', wm)
		wm.OnPopup := ObjBindMethod(this, '_AddPopup')
		wm.OnClosed := ObjBindMethod(this, 'RemoveTab')
		this.views.Push(wm), this.names.Push(name)
		this.tab.Add([name])
		if this.HasOwnProp('webRect')
			wm.SetBounds(this.webRect*)
		this.ShowTab(this.views.Length)
	}

	_TabRightClick(tab, item, isRightClick, x, y) {
		tab.GetPos(&tx, &ty)
		ht := Buffer(12, 0), NumPut('int', x - tx, 'int', y - ty, ht)
		i := SendMessage(0x130D, 0, ht, tab) + 1   ; TCM_HITTEST: which tab was clicked
		if i > this.Web.Count && i <= this.views.Length   ; temporary tabs come after the fixed ones
			this.RemoveTab(this.views[i])
	}

	GoUrl() {
		; Enter pressed in one of the ticket fields also lands here: ignore it
		try if (f := this.gui.FocusedCtrl) && f.Type = 'Edit' && f != this.urlBox
			return
		url := Trim(this.urlBox.Value)
		if url != ''
			try this.Current.Navigate(url, false)
			catch as e
				MsgBox('Could not open that address:`n`n' e.Message, 'Ticket Tool', 'Icon!')
	}

	_UrlChanged(wm) {   ; a tab's page changed: update the address box if that tab is showing
		if !wm.closed && wm = this.Current {
			url := wm.Url
			this.urlBox.Value := url = 'about:blank' ? '' : url
		}
	}

	Layout(w, h) {
		S := this.S, m := S(8), leftW := S(340), rightW := S(130)

		; left half/half
		innerH := h - 2 * m
		lvH := innerH // 2 - m // 2
		this.List.Move(m, m, leftW, lvH)
		y := m + lvH + m
		lblH := S(17), editH := S(23), gap := S(6)
		singles := 4
		descH := (h - m) - y - singles * (lblH + editH + gap) - lblH - gap
		for key in ['Ticket', 'Description', 'Account', 'Category', 'Symptom'] {
			this.labels[key].Move(m, y, leftW, lblH), y += lblH
			eh := key = 'Description' ? Max(descH, editH * 2) : editH
			this.Fields[key].Move(m, y, leftW, eh), y += eh + gap
		}

		; right buttons
		bx := w - m - rightW, by := m, bh := S(30)
		for b in this.buttons
			b.Move(bx, by, rightW, bh), by += bh + gap

		; middle tabs
		; the tab control is only the strip of tab headers; the browser fills the space below it
		tx := m + leftW + m, tw := bx - m - tx
		rc := Buffer(16), NumPut('int', 0, 'int', 0, 'int', tw, 'int', S(200), rc)
		SendMessage(0x1328, 0, rc, this.tab)   ; TCM_ADJUSTRECT: how tall the header strip is
		stripH := NumGet(rc, 4, 'int')
		this.tab.Move(tx, m, tw, stripH)
		ny := m + stripH + S(4), nh := S(26), nb := S(32), goW := S(44)
		this.navBack.Move(tx, ny, nb, nh)
		this.navFwd.Move(tx + nb + S(2), ny, nb, nh)
		this.navReload.Move(tx + 2 * (nb + S(2)), ny, nb, nh)
		ux := tx + 3 * (nb + S(2)) + S(4)
		this.urlBox.Move(ux, ny + S(1), tw - (ux - tx) - goW - S(4), nh - S(2))
		this.navGo.Move(tx + tw - goW, ny, goW, nh)
		wy := ny + nh + S(4)
		this.webRect := [tx, wy, tw, h - m - wy]
		if this.HasOwnProp('views')
			for wm in this.views
				wm.SetBounds(this.webRect*)

		; repaint the whole window and every control so nothing is left half-drawn
		; RDW_INVALIDATE | RDW_ERASE | RDW_ALLCHILDREN | RDW_UPDATENOW
		DllCall('RedrawWindow', 'ptr', this.gui.Hwnd, 'ptr', 0, 'ptr', 0, 'uint', 0x1 | 0x4 | 0x80 | 0x100)
	}
}
