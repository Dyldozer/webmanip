#Requires AutoHotkey v2.0 64-bit
#SingleInstance Force
#Include %A_ScriptDir%\WebManipLib.ahk
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
 ***********************************************************************/

; ---- Tabs: name and start page (leave url '' for a blank page) ----
TABS := [
	{name: 'Remedy', url: ''},
	{name: 'AOS',    url: ''},
	{name: 'Sat',    url: ''},
	{name: 'Scope',  url: ''},
]

; ---- Button captions, top to bottom. Add or remove as you like. ----
BUTTONS := ['Button 1', 'Button 2', 'Button 3', 'Button 4', 'Button 5',
	'Button 6', 'Button 7', 'Button 8', 'Button 9', 'Button 10']

app := TicketApp(TABS, BUTTONS)

; ---- What each button does. n = button number (1 = top). ----
ButtonClicked(n, *) {
	try {
		switch n {
		; case 1: app.Web['Remedy'].Click('#search')
		; case 2: app.Fields['Account'].Value := app.Web['AOS'].GetText('#acct')
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
			wm.OnNavigated := ObjBindMethod(this, '_UrlChanged', n)
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
		this._UrlChanged(i)
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

	_UrlChanged(n) {   ; a tab's page changed: update the address box if that tab is showing
		if n = this.tab.Value {
			url := this.views[n].Url
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
		if this.HasOwnProp('views')
			for wm in this.views
				wm.SetBounds(tx, wy, tw, h - m - wy)

		; repaint the whole window and every control so nothing is left half-drawn
		; RDW_INVALIDATE | RDW_ERASE | RDW_ALLCHILDREN | RDW_UPDATENOW
		DllCall('RedrawWindow', 'ptr', this.gui.Hwnd, 'ptr', 0, 'ptr', 0, 'uint', 0x1 | 0x4 | 0x80 | 0x100)
	}
}
