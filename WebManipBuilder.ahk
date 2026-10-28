#Requires AutoHotkey v2.0 64-bit
#SingleInstance Force
#Include %A_ScriptDir%\WebManipLib.ahk

/************************************************************************
 * WebManip Builder
 *  1. Browse to a page.
 *  2. Press "Pick element" (F2) and click something on the page.
 *  3. Choose an action (Click, Set value, ...) and add it as a step to a function.
 *  4. Run the function to test it, then Export to MyFunctions.ahk to use in your own scripts.
 * Functions are saved in functions.json next to this script.
 ***********************************************************************/
Builder.Start()

class Builder {
	; [display name, action key] for steps that act on an element
	static Actions := [
		['Click', 'click'],
		['Set value', 'setvalue'],
		['Type keys (real keyboard)', 'typekeys'],
		['Press keys (e.g. {Enter})', 'presskey'],
		['Select option', 'select'],
		['Check', 'check'],
		['Uncheck', 'uncheck'],
		['Double-click', 'dblclick'],
		['Hover', 'hover'],
		['Focus', 'focus'],
		['Scroll into view', 'scroll'],
		['Get text -> variable', 'gettext'],
		['Get value -> variable', 'getvalue'],
		['Wait for element', 'waitfor'],
		['Wait until element gone', 'waitgone']]
	static OtherSteps := Map('navigate', 'Go to URL', 'sleep', 'Pause (ms)', 'waitload', 'Wait for page load')
	static GenMethod := Map('click', 'Click', 'dblclick', 'DoubleClick', 'check', 'Check', 'uncheck', 'Uncheck',
		'hover', 'Hover', 'focus', 'Focus', 'scroll', 'ScrollTo')

	static S(n) => Round(n * this.scale)

	static Start() {
		this.scale := A_ScreenDPI / 96
		this.ActionName := Map(), this.ActionKey := Map()
		for a in this.Actions
			this.ActionName[a[2]] := a[1], this.ActionKey[a[1]] := a[2]
		for k, v in this.OtherSteps
			this.ActionName[k] := v
		this.file := A_ScriptDir '\functions.json'
		this.exportFile := A_ScriptDir '\MyFunctions.ahk'
		this.LoadProject()
		this.cur := 0, this.picking := false, this.running := false, this.stopReq := false
		this.lastParams := Map(), this.lastParams.CaseSense := false

		g := this.g := Gui('+Resize -DPIScale +MinSize' this.S(1000) 'x' this.S(720), 'WebManip Builder')
		g.SetFont('s9', 'Segoe UI')
		c := this.c := {}
		c.back := g.AddButton(, '◀')
		c.fwd := g.AddButton(, '▶')
		c.reload := g.AddButton(, '⟳')
		c.url := g.AddEdit('r1')
		c.go := g.AddButton('Default', 'Go')
		c.pick := g.AddButton(, '🎯  Pick element  (F2)')
		g.SetFont('bold')
		c.lblSel := g.AddText(, 'Selected element')
		g.SetFont('norm')
		c.info := g.AddEdit('ReadOnly Multi -WantReturn', 'Nothing picked yet. Press "Pick element" (F2), then click something on the page.')
		g.SetFont('bold')
		c.lblCands := g.AddText(, 'Ways to target it')
		g.SetFont('norm')
		c.cands := g.AddListView('-Multi Grid NoSortHdr', ['OK', 'Method', 'Matches', 'Selector'])
		c.highlight := g.AddButton(, 'Highlight in page')
		c.retest := g.AddButton(, 'Re-test match counts')
		c.custom := g.AddEdit('r1')
		c.addCustom := g.AddButton(, 'Test + add custom')
		g.SetFont('bold')
		c.lblAct := g.AddText(, 'Action')
		c.lblVal := g.AddText(, 'Value')
		g.SetFont('norm')
		names := []
		for a in this.Actions
			names.Push(a[1])
		c.action := g.AddDropDownList('Choose1', names)
		c.value := g.AddEdit('r1')
		c.hint := g.AddText('cGray', '')
		c.try := g.AddButton(, 'Try it now')
		c.add := g.AddButton(, 'Add as new step')
		c.update := g.AddButton(, 'Replace selected step')
		g.SetFont('bold')
		c.lblFn := g.AddText('+0x200', 'Function:')
		g.SetFont('norm')
		c.fn := g.AddDropDownList()
		c.newFn := g.AddButton(, 'New')
		c.renFn := g.AddButton(, 'Rename')
		c.delFn := g.AddButton(, 'Delete')
		c.steps := g.AddListView('-Multi Grid NoSortHdr', ['#', 'Action', 'Target', 'Value'])
		c.up := g.AddButton(, '▲')
		c.down := g.AddButton(, '▼')
		c.del := g.AddButton(, 'Remove')
		c.addNav := g.AddButton(, '+ Go to URL')
		c.addWait := g.AddButton(, '+ Pause')
		c.addLoad := g.AddButton(, '+ Wait load')
		c.run := g.AddButton(, '▶  Run function')
		c.runRows := g.AddButton(, '▶  Run for each row…')
		c.export := g.AddButton(, 'Export to MyFunctions.ahk')
		c.folder := g.AddButton(, 'Open folder')
		this.sb := g.AddStatusBar()

		; events
		c.back.OnEvent('Click', (*) => this.Safe(() => this.wm.Back()))
		c.fwd.OnEvent('Click', (*) => this.Safe(() => this.wm.Forward()))
		c.reload.OnEvent('Click', (*) => this.Safe(() => this.wm.Reload()))
		c.go.OnEvent('Click', (*) => this.Go())
		c.pick.OnEvent('Click', (*) => this.TogglePick())
		c.cands.OnEvent('DoubleClick', (*) => this.HighlightSel())
		c.cands.OnEvent('ContextMenu', (lv, row, *) => this.CopySelector(row))
		c.highlight.OnEvent('Click', (*) => this.HighlightSel())
		c.retest.OnEvent('Click', (*) => this.Safe(() => this.Retest(true)))
		c.addCustom.OnEvent('Click', (*) => this.AddCustom())
		c.action.OnEvent('Change', (*) => this.UpdateHint())
		c.try.OnEvent('Click', (*) => this.TryNow())
		c.add.OnEvent('Click', (*) => this.AddStep(false))
		c.update.OnEvent('Click', (*) => this.AddStep(true))
		c.fn.OnEvent('Change', (*) => this.RefreshSteps())
		c.newFn.OnEvent('Click', (*) => this.NewFn())
		c.renFn.OnEvent('Click', (*) => this.RenameFn())
		c.delFn.OnEvent('Click', (*) => this.DeleteFn())
		c.steps.OnEvent('DoubleClick', (*) => this.LoadStep())
		c.up.OnEvent('Click', (*) => this.MoveStep(-1))
		c.down.OnEvent('Click', (*) => this.MoveStep(1))
		c.del.OnEvent('Click', (*) => this.DeleteStep())
		c.addNav.OnEvent('Click', (*) => this.AddNavStep())
		c.addWait.OnEvent('Click', (*) => this.AddWaitStep())
		c.addLoad.OnEvent('Click', (*) => this.InsertStep(Map('action', 'waitload', 'value', '')))
		c.run.OnEvent('Click', (*) => this.RunOrStop())
		c.runRows.OnEvent('Click', (*) => this.RunRows())
		c.export.OnEvent('Click', (*) => this.Export())
		c.folder.OnEvent('Click', (*) => Run('explorer "' A_ScriptDir '"'))
		g.OnEvent('Size', (gui, minMax, *) => minMax != -1 && this.Layout())
		g.OnEvent('Close', (*) => (this.SaveProject(), ExitApp()))
		HotIfWinActive('ahk_id ' g.Hwnd)
		Hotkey('F2', (*) => this.TogglePick())
		HotIf()

		w := Min(this.S(1450), A_ScreenWidth - 40), h := Min(this.S(900), A_ScreenHeight - 80)
		g.Show('w' w ' h' h)
		this.Status('Starting browser…')
		try {
			this.wm := WebManip(g.Hwnd)
		} catch as e {
			MsgBox('Could not start the WebView2 browser:`n`n' e.Message
				'`n`nMake sure the Microsoft Edge WebView2 Runtime is installed and you are running 64-bit AutoHotkey v2.', 'WebManip', 'Iconx')
			ExitApp()
		}
		this.wm.OnPicked := (msg) => this.OnPicked(msg)
		this.wm.OnNavigated := () => (this.c.url.Value := this.wm.Url)
		this.Layout()
		this.UpdateHint()
		this.RefreshFnList()
		c.url.Value := this.proj.Get('lastUrl', 'https://example.com')
		this.Go()
	}

	; ================================================================== layout
	static Layout() {
		if !this.HasOwnProp('c')
			return
		rc := Buffer(16), DllCall('GetClientRect', 'ptr', this.g.Hwnd, 'ptr', rc)
		cw := NumGet(rc, 8, 'int'), ch := NumGet(rc, 12, 'int')
		this.sb.GetPos(, , , &sbh)
		c := this.c, p := this.S(8), g4 := this.S(4), bh := this.S(28), RW := this.S(490)
		rx := cw - RW + p, pw := RW - 2 * p
		y := p
		c.back.Move(p, y, this.S(30), bh)
		c.fwd.Move(p + this.S(32), y, this.S(30), bh)
		c.reload.Move(p + this.S(64), y, this.S(30), bh)
		urlX := p + this.S(100), goW := this.S(48)
		c.url.Move(urlX, y + this.S(3), rx - p - goW - g4 - urlX, this.S(23))
		c.go.Move(rx - p - goW, y, goW, bh)
		c.pick.Move(rx, y, pw, bh)
		webY := y + bh + p
		if this.HasOwnProp('wm')
			this.wm.SetBounds(p, webY, rx - 2 * p, ch - sbh - webY - p)
		y := webY
		c.lblSel.Move(rx, y, pw, this.S(18)), y += this.S(20)
		c.info.Move(rx, y, pw, this.S(80)), y += this.S(84)
		c.lblCands.Move(rx, y, pw, this.S(18)), y += this.S(20)
		c.cands.Move(rx, y, pw, this.S(150)), y += this.S(154)
		this.Row(rx, y, pw, bh, [[c.highlight, 0], [c.retest, 0]]), y += bh + g4
		this.Row(rx, y, pw, bh, [[c.custom, 0], [c.addCustom, this.S(130)]]), y += bh + p
		this.Row(rx, y, pw, this.S(18), [[c.lblAct, this.S(200)], [c.lblVal, 0]]), y += this.S(20)
		this.Row(rx, y, pw, this.S(24), [[c.action, this.S(200)], [c.value, 0]]), y += this.S(28)
		c.hint.Move(rx, y, pw, this.S(18)), y += this.S(22)
		this.Row(rx, y, pw, bh, [[c.try, 0], [c.add, 0], [c.update, 0]]), y += bh + this.S(14)
		this.Row(rx, y, pw, this.S(24), [[c.lblFn, this.S(64)], [c.fn, 0], [c.newFn, this.S(50)], [c.renFn, this.S(60)], [c.delFn, this.S(56)]])
		y += this.S(30)
		row3Y := ch - sbh - p - bh, row2Y := row3Y - g4 - bh, row1Y := row2Y - g4 - bh
		c.steps.Move(rx, y, pw, Max(this.S(60), row1Y - g4 - y))
		this.Row(rx, row1Y, pw, bh, [[c.up, this.S(32)], [c.down, this.S(32)], [c.del, 0], [c.addNav, 0], [c.addWait, 0], [c.addLoad, 0]])
		this.Row(rx, row2Y, pw, bh, [[c.run, 0], [c.runRows, 0]])
		this.Row(rx, row3Y, pw, bh, [[c.export, 0], [c.folder, this.S(110)]])
		lvw := pw - this.S(24)
		c.cands.ModifyCol(1, this.S(30)), c.cands.ModifyCol(2, this.S(150)), c.cands.ModifyCol(3, this.S(60))
		c.cands.ModifyCol(4, lvw - this.S(240))
		c.steps.ModifyCol(1, this.S(28)), c.steps.ModifyCol(2, this.S(120)), c.steps.ModifyCol(3, this.S(170))
		c.steps.ModifyCol(4, lvw - this.S(318))
	}
	static Row(x, y, w, h, items) {
		gap := this.S(4), fixed := 0, flex := 0
		for it in items
			it[2] ? fixed += it[2] : flex++
		fw := flex ? (w - fixed - gap * (items.Length - 1)) // flex : 0
		for it in items {
			cw := it[2] || fw
			; a drop-down's height is the height of its open list
			it[1].Move(x, y, cw, it[1].Type = 'DDL' ? this.S(320) : h)
			x += cw + gap
		}
	}

	; ================================================================== helpers
	static Status(text) => this.sb.SetText('  ' text)
	static Safe(fn) {
		try fn()
		catch as e
			this.Status('Error: ' e.Message)
	}
	static CurFn() {
		i := this.c.fn.Value
		return i ? this.proj['functions'][i] : 0
	}
	static Unique(cd) => cd['count'] = 1 && cd['hit']
	static IsIdent(s) => RegExMatch(s, '^[A-Za-z_][A-Za-z0-9_]*$')
	static VarName(v) => this.IsIdent(Trim(v)) ? Trim(v) : 'result'

	; ================================================================== browsing / picking
	static Go() {
		url := Trim(this.c.url.Value)
		if url = ''
			return
		try {
			this.wm.Navigate(url, false)
			this.proj['lastUrl'] := url
			this.Status('Loading ' url)
		} catch as e
			this.Status('Could not open that address: ' e.Message)
	}

	static TogglePick() {
		if !this.HasOwnProp('wm')
			return
		if this.picking {
			this.picking := false
			this.wm.SetPickMode(false)
			this.c.pick.Text := '🎯  Pick element  (F2)'
			this.Status('Pick cancelled.')
			return
		}
		this.picking := true
		this.wm.SetPickMode(true)
		this.wm.ctrl.MoveFocus(0)
		this.c.pick.Text := '■  Picking… click an element  (Esc / F2 to cancel)'
		this.Status('Hover over the page and click the element you want.')
	}

	static OnPicked(msg) {
		this.picking := false
		this.wm.SetPickMode(false)
		this.c.pick.Text := '🎯  Pick element  (F2)'
		if msg['type'] = 'pickCancel'
			return this.Status('Pick cancelled.')
		cands := msg['cands']
		this.cur := { frames: msg['frames'], tag: msg['tag'], label: this.MakeLabel(msg), cands: cands }
		info := 'Tag: <' StrLower(msg['tag']) '>'
		for k in ['id', 'name', 'inputType']
			if msg[k] != ''
				info .= '    ' (k = 'inputType' ? 'type' : k) ': ' msg[k]
		if msg['classes'] != ''
			info .= '`r`nClass: ' msg['classes']
		if msg['text'] != ''
			info .= '`r`nText: ' SubStr(msg['text'], 1, 120)
		if msg['value'] != ''
			info .= '`r`nCurrent value: ' msg['value']
		if msg['frames'].Length
			info .= '`r`nInside ' msg['frames'].Length ' frame(s) — handled automatically.'
		this.c.info.Value := info
		this.FillCands()
		; suggest an action
		tag := msg['tag'], typ := StrLower(msg['inputType'])
		act := tag = 'SELECT' ? 'Select option'
			: (tag = 'INPUT' && typ = 'checkbox') ? 'Check'
			: (tag = 'TEXTAREA' || (tag = 'INPUT' && !RegExMatch(typ, '^(button|submit|reset|radio|checkbox|image|file)$'))) ? 'Set value'
			: 'Click'
		this.c.action.Choose(act)
		this.UpdateHint()
		n := 0
		for cd in cands
			n += this.Unique(cd)
		this.Status('Picked ' this.cur.label ' — ' n ' of ' cands.Length ' ways match exactly one element.')
	}

	static MakeLabel(msg) {
		tag := StrLower(msg['tag'])
		txt := msg['text']
		if StrLen(txt) > 30
			txt := SubStr(txt, 1, 30) '…'
		if msg['id'] != '' && !RegExMatch(msg['id'], '\d{4,}')
			return tag '#' msg['id']
		if msg['name'] != ''
			return tag '[name=' msg['name'] ']'
		if txt != ''
			return tag ' "' txt '"'
		return tag
	}

	static FillCands(selRow := 0) {
		lv := this.c.cands
		lv.Opt('-Redraw'), lv.Delete()
		if this.cur
			for cd in this.cur.cands {
				lv.Add(, this.Unique(cd) ? '✔' : '✘', cd['label'], cd['count'], cd['v'])
				if !selRow && this.Unique(cd)
					selRow := A_Index
			}
		lv.Opt('+Redraw')
		if selRow
			lv.Modify(selRow, 'Select Focus Vis')
	}

	; Re-count matches for every way of targeting the current element.
	static Retest(showStatus := false) {
		if !this.cur
			return this.Status('Pick an element first.')
		strategies := []
		for cd in this.cur.cands
			strategies.Push(Map('t', cd['t'], 'v', cd['v']))
		target := Map('frames', this.cur.frames, 'strategies', strategies, 'tag', '', 'label', 'frame')
		counts := this.wm.Do('probe', target, '', 3000)
		sel := this.c.cands.GetNext()
		for i, cd in this.cur.cands
			cd['count'] := counts[i]
		this.FillCands(sel)
		if showStatus
			this.Status('Match counts updated.')
	}

	; Right-click a row: copy its selector (CSS or XPath) to the clipboard.
	static CopySelector(row) {
		if !this.cur || !row || row > this.cur.cands.Length
			return
		cd := this.cur.cands[row]
		this.c.cands.Modify(row, 'Select Focus')
		A_Clipboard := cd['v']
		this.Status('Copied ' (cd['t'] = 'xpath' ? 'XPath' : 'CSS selector') ' to clipboard: ' cd['v'])
		ToolTip('Copied!')
		SetTimer(() => ToolTip(), -1000)
	}

	static HighlightSel() {
		if !this.cur || !(row := this.c.cands.GetNext())
			return this.Status('Select one of the ways in the list first.')
		cd := this.cur.cands[row]
		target := Map('frames', this.cur.frames, 'strategies', [Map('t', cd['t'], 'v', cd['v'])], 'tag', '', 'label', cd['label'])
		try {
			this.wm.Do('highlight', target, '', 1500)
			this.Status('Highlighted (green) using: ' cd['label'])
		} catch as e
			this.Status(e.Message)
	}

	static AddCustom() {
		sel := Trim(this.c.custom.Value)
		if sel = ''
			return this.Status('Type a CSS selector or XPath in the box first.')
		t := RegExMatch(sel, '^[(/]') ? 'xpath' : 'css'
		if !this.cur
			this.cur := { frames: [], tag: '', label: SubStr(sel, 1, 40), cands: [] }
		target := Map('frames', this.cur.frames, 'strategies', [Map('t', t, 'v', sel)], 'tag', '', 'label', 'frame')
		try counts := this.wm.Do('probe', target, '', 3000)
		catch as e
			return this.Status('Error: ' e.Message)
		if counts[1] < 0
			return this.Status('That selector is not valid ' (t = 'css' ? 'CSS.' : 'XPath.'))
		this.cur.cands.InsertAt(1, Map('t', t, 'v', sel, 'label', 'Custom ' (t = 'css' ? 'CSS' : 'XPath'), 'count', counts[1], 'hit', 1))
		this.FillCands(1)
		this.Status('Custom selector matches ' counts[1] ' element(s).' (counts[1] = 1 ? '' : ' It must match exactly 1 to be used.'))
	}

	static UpdateHint() {
		key := this.ActionKey[this.c.action.Text]
		hints := Map(
			'setvalue', 'Text to put in the field. Use {name} to make it a function parameter.',
			'typekeys', 'Text to type. Use {name} to make it a function parameter.',
			'presskey', 'AutoHotkey keys, e.g. {Enter}  {Tab}  ^a',
			'select', 'Option text (or value). Use {name} for a parameter.',
			'gettext', 'Variable name to store the result in (default: result).',
			'getvalue', 'Variable name to store the result in (default: result).',
			'waitfor', 'Max seconds to wait (default 10).',
			'waitgone', 'Max seconds to wait (default 10).')
		this.c.hint.Text := hints.Get(key, '(no value needed)')
		this.c.value.Enabled := hints.Has(key)
	}

	; ================================================================== steps
	; Builds the saved target: every way that matches exactly one element, selected one first.
	static BuildTarget() {
		if !this.cur {
			MsgBox('Pick an element first (F2).', 'WebManip', 'Icon!')
			return 0
		}
		try this.Retest()
		catch as e {
			if MsgBox('Could not re-check the element on the current page:`n' e.Message
				'`n`nUse the match counts from when it was picked?', 'WebManip', 'YesNo Icon?') = 'No'
				return 0
		}
		row := this.c.cands.GetNext(), cands := this.cur.cands, ordered := []
		if row && this.Unique(cands[row])
			ordered.Push(cands[row])
		for i, cd in cands
			if i != row && this.Unique(cd)
				ordered.Push(cd)
		if !ordered.Length {
			MsgBox('None of the ways to target this element match exactly one element right now.'
				'`n`nTry: picking it again, picking its parent/child, or adding a custom selector.', 'WebManip', 'Icon!')
			return 0
		}
		if row && !this.Unique(cands[row])
			this.Status('Note: "' cands[row]['label'] '" matches ' cands[row]['count'] ' elements, so it was skipped. Using "' ordered[1]['label'] '" first.')
		strategies := []
		for cd in ordered
			strategies.Push(Map('t', cd['t'], 'v', cd['v']))
		return Map('frames', this.cur.frames, 'strategies', strategies, 'tag', this.cur.tag, 'label', this.cur.label)
	}

	static EditorStep() {
		if !(t := this.BuildTarget())
			return 0
		return Map('action', this.ActionKey[this.c.action.Text], 'target', t, 'value', this.c.value.Value)
	}

	static AddStep(replace) {
		if !(fn := this.CurFn()) && !(fn := this.NewFn())
			return
		if replace && !this.c.steps.GetNext()
			return this.Status('Select the step to replace in the list first.')
		if !(step := this.EditorStep())
			return
		if replace {
			r := this.c.steps.GetNext()
			fn['steps'][r] := step
			this.SaveProject(), this.RefreshSteps(r)
			this.Status('Step ' r ' replaced.')
		} else
			this.InsertStep(step)
	}

	; Inserts after the selected step (or at the end).
	static InsertStep(step) {
		if !(fn := this.CurFn()) && !(fn := this.NewFn())
			return
		r := this.c.steps.GetNext()
		pos := r ? r + 1 : fn['steps'].Length + 1
		fn['steps'].InsertAt(pos, step)
		this.SaveProject(), this.RefreshSteps(pos)
		this.Status('Added step ' pos ': ' this.ActionName[step['action']])
	}

	static AddNavStep() {
		ib := InputBox('Address to open. Use {name} to make part of it a parameter.', 'Go to URL', 'w500 h120', this.wm.Url)
		if ib.Result = 'OK' && Trim(ib.Value) != ''
			this.InsertStep(Map('action', 'navigate', 'value', Trim(ib.Value)))
	}
	static AddWaitStep() {
		ib := InputBox('Pause for how many milliseconds?', 'Pause', 'w300 h110', '1000')
		if ib.Result = 'OK' && IsInteger(ib.Value)
			this.InsertStep(Map('action', 'sleep', 'value', ib.Value))
	}

	static LoadStep() {
		if !(fn := this.CurFn()) || !(r := this.c.steps.GetNext())
			return
		st := fn['steps'][r]
		if !st.Has('target') {
			if st['action'] = 'waitload'
				return
			ib := InputBox('New value:', this.ActionName[st['action']], 'w500 h110', st['value'])
			if ib.Result = 'OK'
				st['value'] := ib.Value, this.SaveProject(), this.RefreshSteps(r)
			return
		}
		t := st['target'], cands := []
		for i, s in t['strategies']
			cands.Push(Map('t', s['t'], 'v', s['v'], 'label', 'Saved way #' i, 'count', 1, 'hit', 1))
		this.cur := { frames: t['frames'], tag: t['tag'], label: t['label'], cands: cands }
		this.c.info.Value := 'Loaded from step ' r ': ' t['label']
			. '`r`nEdit the action/value, then "Replace selected step".'
		this.c.action.Choose(this.ActionName[st['action']])
		this.c.value.Value := st['value']
		this.UpdateHint()
		this.FillCands(1)
		try {
			this.Retest()
			this.wm.Do('highlight', t, '', 1500)
			this.Status('Loaded step ' r ' (highlighted in green).')
		} catch as e
			this.Status('Loaded step ' r ' — not found on this page right now: ' e.Message)
	}

	static MoveStep(dir) {
		if !(fn := this.CurFn()) || !(r := this.c.steps.GetNext())
			return
		n := r + dir, steps := fn['steps']
		if n < 1 || n > steps.Length
			return
		tmp := steps[r], steps[r] := steps[n], steps[n] := tmp
		this.SaveProject(), this.RefreshSteps(n)
	}
	static DeleteStep() {
		if !(fn := this.CurFn()) || !(r := this.c.steps.GetNext())
			return
		fn['steps'].RemoveAt(r)
		this.SaveProject(), this.RefreshSteps(Min(r, fn['steps'].Length))
	}

	static RefreshSteps(sel := 0) {
		lv := this.c.steps
		lv.Opt('-Redraw'), lv.Delete()
		if fn := this.CurFn()
			for i, st in fn['steps']
				lv.Add(, i, this.ActionName[st['action']], st.Has('target') ? st['target']['label'] : '', st['value'])
		lv.Opt('+Redraw')
		if sel
			lv.Modify(sel, 'Select Focus Vis')
	}

	; ================================================================== functions
	static RefreshFnList(selName := '') {
		names := [], sel := 0
		for fn in this.proj['functions'] {
			names.Push(fn['name'])
			if fn['name'] = selName
				sel := A_Index
		}
		this.c.fn.Delete()
		this.c.fn.Add(names)
		if names.Length
			this.c.fn.Choose(sel || 1)
		this.RefreshSteps()
	}
	static AskFnName(title, default := '') {
		loop {
			ib := InputBox('Function name (letters, digits, _, no spaces). Example: SubmitTimesheet', title, 'w380 h120', default)
			if ib.Result != 'OK'
				return ''
			name := Trim(ib.Value)
			if !this.IsIdent(name) {
				MsgBox("Use only letters, digits and _ (and don't start with a digit).", title, 'Icon!')
				continue
			}
			taken := false
			for fn in this.proj['functions']
				if fn['name'] = name && name != default
					taken := true
			if taken || this.IsReserved(name) {
				MsgBox('"' name '" is already used. Pick another name.', title, 'Icon!')
				continue
			}
			return name
		}
	}
	static IsReserved(name) {
		if name = 'wm'
			return true
		try return IsSet(%name%) ; built-in functions/classes (MsgBox, Send, JSON, ...)
		return false
	}
	static NewFn() {
		if (name := this.AskFnName('New function')) = ''
			return 0
		fn := Map('name', name, 'steps', [])
		this.proj['functions'].Push(fn)
		this.SaveProject(), this.RefreshFnList(name)
		return fn
	}
	static RenameFn() {
		if !(fn := this.CurFn())
			return
		if (name := this.AskFnName('Rename function', fn['name'])) = ''
			return
		fn['name'] := name
		this.SaveProject(), this.RefreshFnList(name)
	}
	static DeleteFn() {
		if !(fn := this.CurFn())
			return
		if MsgBox('Delete function "' fn['name'] '" and its ' fn['steps'].Length ' step(s)?', 'WebManip', 'YesNo Icon!') != 'Yes'
			return
		this.proj['functions'].RemoveAt(this.c.fn.Value)
		this.SaveProject(), this.RefreshFnList()
	}

	; Parameters = {name} placeholders that aren't variables set by an earlier "Get" step.
	static ParamsOf(steps) {
		params := [], seen := Map(), vars := Map()
		seen.CaseSense := false, vars.CaseSense := false
		for st in steps {
			a := st['action'], v := st['value']
			if a = 'gettext' || a = 'getvalue' {
				vars[this.VarName(v)] := 1
				continue
			}
			if !(a = 'navigate' || a = 'setvalue' || a = 'typekeys' || a = 'select')
				continue
			pos := 1
			while RegExMatch(v, '\{([A-Za-z_]\w*)\}', &m, pos) {
				pos := m.Pos + m.Len
				if !vars.Has(m[1]) && !seen.Has(m[1])
					seen[m[1]] := 1, params.Push(m[1])
			}
		}
		return params
	}
	static Expand(v, scope) {
		out := '', pos := 1
		while RegExMatch(v, '\{([A-Za-z_]\w*)\}', &m, pos) {
			out .= SubStr(v, pos, m.Pos - pos) (scope.Has(m[1]) ? scope[m[1]] : m[0])
			pos := m.Pos + m.Len
		}
		return out SubStr(v, pos)
	}
	static AskParams(params, title) {
		scope := Map(), scope.CaseSense := false
		for p in params {
			ib := InputBox('Value for "' p '":', title, 'w360 h110', this.lastParams.Get(p, ''))
			if ib.Result != 'OK'
				return 0
			scope[p] := this.lastParams[p] := ib.Value
		}
		return scope
	}

	; ================================================================== running
	static RunStep(st, scope) {
		a := st['action'], v := st['value'], t := st.Get('target', '')
		switch a {
			case 'navigate': this.wm.Navigate(this.Expand(v, scope))
			case 'sleep': Sleep(IsInteger(v) ? Integer(v) : 1000)
			case 'waitload': this.wm.WaitLoad()
			case 'gettext', 'getvalue': return scope[this.VarName(v)] := this.wm.Do(a, t)
			case 'waitfor', 'waitgone': this.wm.Do(a, t, '', IsNumber(v) && v > 0 ? Round(v * 1000) : '')
			case 'typekeys': this.wm.TypeKeys(t, this.Expand(v, scope))
			case 'presskey': this.wm.PressKeys(t, v)
			default: this.wm.Do(a, t, this.Expand(v, scope))
		}
	}

	static TryNow() {
		if !(st := this.EditorStep())
			return
		if !(scope := this.AskParams(this.ParamsOf([st]), 'Try it now'))
			return
		try {
			r := this.RunStep(st, scope)
			if st['action'] = 'gettext' || st['action'] = 'getvalue'
				MsgBox('Result:`n`n' r, 'WebManip')
			this.Status('Done: ' this.ActionName[st['action']] ' ' st['target']['label'])
		} catch as e {
			this.Status('Failed: ' e.Message)
			MsgBox(e.Message, 'Try it now — failed', 'Icon!')
		}
	}

	; Runs every step of fn. Throws an Error naming the failed step (with .stopped if the user pressed Stop).
	static RunSteps(fn, scope, prefix := '') {
		steps := fn['steps'], n := steps.Length
		for st in steps {
			i := A_Index
			if this.stopReq {
				e := Error('Stopped by user before step ' i '.'), e.stopped := true
				throw e
			}
			this.c.steps.Modify(i, 'Select Focus Vis')
			label := st.Has('target') ? ' ' st['target']['label'] : ''
			this.Status(prefix 'Step ' i '/' n ': ' this.ActionName[st['action']] label)
			try this.RunStep(st, scope)
			catch as e
				throw Error('Step ' i ' (' this.ActionName[st['action']] '): ' e.Message)
		}
	}
	static GetVars(fn) {
		vars := []
		for st in fn['steps']
			if (st['action'] = 'gettext' || st['action'] = 'getvalue') && !this.HasIn(vars, this.VarName(st['value']))
				vars.Push(this.VarName(st['value']))
		return vars
	}
	static SetRunning(on) {
		this.running := on, this.stopReq := false
		this.c.run.Text := on ? '■  Stop' : '▶  Run function'
		this.c.runRows.Text := on ? '■  Stop' : '▶  Run for each row…'
	}

	static RunOrStop() {
		if this.running {
			this.stopReq := true
			return this.Status('Stopping after the current step…')
		}
		if !(fn := this.CurFn()) || !fn['steps'].Length
			return this.Status('Choose a function that has steps.')
		if !(scope := this.AskParams(this.ParamsOf(fn['steps']), 'Run ' fn['name']))
			return
		this.SetRunning(true)
		try {
			this.RunSteps(fn, scope)
			out := ''
			for name in this.GetVars(fn)
				out .= name ' = ' scope[name] '`n'
			this.Status('Finished ' fn['name'] ' (' fn['steps'].Length ' steps).')
			if out != ''
				MsgBox('Finished. Values read:`n`n' out, fn['name'], 'Iconi')
		} catch as e {
			this.Status(e.Message)
			if !e.HasProp('stopped')
				MsgBox(e.Message, 'Run ' fn['name'] ' failed', 'Icon!')
		} finally
			this.SetRunning(false)
	}

	; ================================================================== run once per row of a CSV / Excel file
	static RunRows() {
		if this.running {
			this.stopReq := true
			return this.Status('Stopping after the current step…')
		}
		if !(fn := this.CurFn()) || !fn['steps'].Length
			return this.Status('Choose a function that has steps.')
		path := FileSelect(1, this.proj.Get('lastData', ''), 'Choose the data file (first row = column names)',
			'Data files (*.csv; *.txt; *.xlsx; *.xlsm; *.xls)')
		if path = ''
			return
		this.Status('Reading ' path '…')
		try rows := WebManip.ReadTable(path)
		catch as e
			return (this.Status('Could not read the file.'), MsgBox(e.Message, 'Read data file', 'Icon!'))
		if !rows.Length
			return MsgBox('No data rows found. The first row must be the column names, with data below it.', 'Read data file', 'Icon!')
		this.proj['lastData'] := path, this.SaveProject()
		params := this.ParamsOf(fn['steps'])
		if !(opt := this.RowsDialog(fn, params, rows, path))
			return this.Status('Cancelled.')

		; results file: one line per row, written as we go
		DirCreate(A_ScriptDir '\Results')
		SplitPath(path, , , , &base)
		logPath := A_ScriptDir '\Results\' base '_' fn['name'] '_' FormatTime(, 'yyyyMMdd_HHmmss') '.csv'
		vars := this.GetVars(fn)
		head := ['File row', 'Status', 'Error']
		head.Push(vars*), head.Push(rows.Headers*)
		f := FileOpen(logPath, 'w', 'UTF-8')
		f.WriteLine(WebManip.CsvLine(head))

		okN := 0, failN := 0, stopped := false, stoppedOnError := 0, total := opt.to - opt.from + 1
		this.SetRunning(true)
		try {
			loop total {
				idx := opt.from + A_Index - 1, row := rows[idx]
				scope := Map(), scope.CaseSense := false
				for p, col in opt.map
					scope[p] := col = '' ? '' : row[col]
				status := 'OK', err := ''
				try this.RunSteps(fn, scope, 'Row ' A_Index ' of ' total ' (file row ' row.SheetRow ') — ')
				catch as e {
					if e.HasProp('stopped')
						stopped := true, status := 'Not run (stopped)'
					else
						status := 'FAILED', err := e.Message
				}
				line := [row.SheetRow, status, err]
				for name in vars
					line.Push(scope.Has(name) ? scope[name] : '')
				for h in rows.Headers
					line.Push(row[h])
				f.WriteLine(WebManip.CsvLine(line))
				f.Read(0) ; flush to disk so results survive a crash
				if stopped
					break
				status = 'OK' ? okN++ : failN++
				if status = 'FAILED' && !opt.skip {
					stoppedOnError := row.SheetRow
					break
				}
			}
		} finally {
			f.Close()
			this.SetRunning(false)
		}
		msg := okN ' row(s) succeeded, ' failN ' failed'
			. (stopped ? ', then you stopped it' : stoppedOnError ? ', stopped at file row ' stoppedOnError ' (set "If a row fails" to skip to keep going)' : '')
			. '.`n`nResults: ' logPath '`n`nOpen the results file?'
		this.Status(okN ' OK, ' failN ' failed. Results saved in the Results folder.')
		if MsgBox(msg, 'Run ' fn['name'] ' for each row', 'YesNo ' (failN ? 'Icon!' : 'Iconi')) = 'Yes'
			try Run('"' logPath '"')
	}

	; Asks which column feeds each {input}, which rows to run, and what to do on errors.
	static RowsDialog(fn, params, rows, path) {
		norm := (s) => RegExReplace(StrLower(s), '[^a-z0-9]')
		cols := rows.Headers.Clone()
		cols.Push('(leave blank)')
		res := { value: 0 }
		d := Gui('+Owner' this.g.Hwnd ' -MinimizeBox', 'Run ' fn['name'] ' for each row')
		d.SetFont('s9', 'Segoe UI')
		SplitPath(path, &fname)
		d.SetFont('bold')
		d.AddText('w440', fname)
		d.SetFont('norm')
		d.AddText('w440', rows.Length ' data row(s), ' rows.Headers.Length ' column(s).')
		ddls := Map()
		if params.Length {
			d.AddText('xm y+12 w440', 'Which column goes into each input of ' fn['name'] '?')
			for p in params {
				pick := cols.Length
				for i, h in rows.Headers
					if norm(h) = norm(p)
						pick := i
				d.AddText('xm y+10 w150 Right', '{' p '}')
				ddls[p] := d.AddDropDownList('x+8 yp-3 w280 Choose' pick, cols)
			}
		} else
			d.AddText('xm y+12 w440 cGray', 'This function has no {inputs}, so the same steps will just run once per row.')
		d.AddText('xm y+16', 'Run rows')
		eFrom := d.AddEdit('x+6 yp-3 w55 Number', 1)
		d.AddText('x+6 yp+3', 'to')
		eTo := d.AddEdit('x+6 yp-3 w55 Number', rows.Length)
		d.AddText('x+6 yp+3 cGray', '(1 = first data row)')
		d.AddText('xm y+14', 'If a row fails:')
		eErr := d.AddDropDownList('x+6 yp-3 w220 Choose1', ['Stop', 'Skip it and keep going'])
		d.AddText('xm y+14 w440 cGray', 'Tip: start the function with a "Go to URL" step so every row starts from the same page. '
			. 'A results file (with OK/FAILED per row) is saved in the Results folder.')
		bRun := d.AddButton('xm y+14 w110 Default', 'Run')
		bCancel := d.AddButton('x+8 w110', 'Cancel')
		bRun.OnEvent('Click', OnRun)
		bCancel.OnEvent('Click', (*) => d.Destroy())
		d.OnEvent('Close', (*) => d.Destroy())
		d.OnEvent('Escape', (*) => d.Destroy())
		this.g.Opt('+Disabled')
		d.Show()
		WinWaitClose('ahk_id ' d.Hwnd)
		this.g.Opt('-Disabled')
		WinActivate('ahk_id ' this.g.Hwnd)
		return res.value

		OnRun(*) {
			from := Integer(eFrom.Value || 0), to := Integer(eTo.Value || 0)
			if from < 1 || to > rows.Length || from > to
				return MsgBox('Rows must be between 1 and ' rows.Length ', and the first number must not be bigger than the second.', 'Run', 'Icon!')
			m := Map()
			for p, ddl in ddls
				m[p] := ddl.Value = cols.Length ? '' : ddl.Text
			res.value := { map: m, from: from, to: to, skip: eErr.Value = 2 }
			d.Destroy()
		}
	}

	; ================================================================== save / export
	static LoadProject() {
		this.proj := Map('functions', [])
		if FileExist(this.file) {
			try this.proj := JSON.Parse(FileRead(this.file, 'UTF-8'))
			catch as e
				MsgBox('Could not read functions.json: ' e.Message '`nStarting with an empty list (the file is not changed until you edit something).', 'WebManip', 'Icon!')
		}
		if !this.proj.Has('functions')
			this.proj['functions'] := []
	}
	static SaveProject() {
		f := FileOpen(this.file, 'w', 'UTF-8')
		f.Write(JSON.Stringify(this.proj, '  '))
		f.Close()
	}

	static AhkStr(s) {
		s := StrReplace(s, '``', '````')
		s := StrReplace(s, "'", "``'")
		s := StrReplace(s, ';', '``;')
		s := StrReplace(s, '`r', '``r'), s := StrReplace(s, '`n', '``n')
		return "'" s "'"
	}
	; Value text -> AHK expression, turning {param} into variables.
	static Expr(v, known) {
		parts := [], lit := '', pos := 1
		while RegExMatch(v, '\{([A-Za-z_]\w*)\}', &m, pos) {
			lit .= SubStr(v, pos, m.Pos - pos)
			if known.Has(m[1]) {
				if lit != ''
					parts.Push(this.AhkStr(lit)), lit := ''
				parts.Push(m[1])
			} else
				lit .= m[0]
			pos := m.Pos + m.Len
		}
		lit .= SubStr(v, pos)
		if lit != '' || !parts.Length
			parts.Push(this.AhkStr(lit))
		out := ''
		for p in parts
			out .= (A_Index > 1 ? ' ' : '') p
		return out
	}

	static GenFunction(fn) {
		steps := fn['steps'], params := this.ParamsOf(steps)
		known := Map(), known.CaseSense := false, vars := []
		for p in params
			known[p] := 1
		for st in steps
			if st['action'] = 'gettext' || st['action'] = 'getvalue' {
				name := this.VarName(st['value']), known[name] := 1
				if !this.HasIn(vars, name)
					vars.Push(name)
			}
		sig := fn['name'] '(wm'
		for p in params
			sig .= ', ' p
		out := sig ') {`n'
		for i, st in steps {
			a := st['action'], v := st['value']
			loc := st.Has('target') ? this.AhkStr(JSON.Stringify(st['target'])) : ''
			out .= '`t`; ' i '. ' this.ActionName[a] (st.Has('target') ? ': ' StrReplace(st['target']['label'], '`n', ' ') : '') '`n`t'
			switch a {
				case 'navigate': out .= 'wm.Navigate(' this.Expr(v, known) ')'
				case 'sleep': out .= 'Sleep(' (IsInteger(v) ? v : 1000) ')'
				case 'waitload': out .= 'wm.WaitLoad()'
				case 'gettext': out .= this.VarName(v) ' := wm.GetText(' loc ')'
				case 'getvalue': out .= this.VarName(v) ' := wm.GetValue(' loc ')'
				case 'waitfor', 'waitgone':
					out .= 'wm.' (a = 'waitfor' ? 'WaitFor' : 'WaitGone') '(' loc (IsNumber(v) && v > 0 ? ', ' Round(v * 1000) : '') ')'
				case 'setvalue': out .= 'wm.SetValue(' loc ', ' this.Expr(v, known) ')'
				case 'typekeys': out .= 'wm.TypeKeys(' loc ', ' this.Expr(v, known) ')'
				case 'select': out .= 'wm.SelectOption(' loc ', ' this.Expr(v, known) ')'
				case 'presskey': out .= 'wm.PressKeys(' loc ', ' this.AhkStr(v) ')'
				default: out .= 'wm.' this.GenMethod[a] '(' loc ')'
			}
			out .= '`n'
		}
		if vars.Length = 1
			out .= '`treturn ' vars[1] '`n'
		else if vars.Length > 1 {
			out .= '`treturn Map('
			for name in vars
				out .= (A_Index > 1 ? ', ' : '') "'" name "', " name
			out .= ')`n'
		}
		return out '}`n'
	}
	static HasIn(arr, val) {
		for x in arr
			if x = val
				return true
		return false
	}

	static Export() {
		fns := this.proj['functions']
		if !fns.Length
			return this.Status('Nothing to export yet.')
		code := '`; ======================================================================`n'
			. '`; Generated by WebManip Builder on ' FormatTime(, 'yyyy-MM-dd HH:mm') '`n'
			. '`; Do not edit by hand: re-export from the builder (this file is overwritten).`n'
			. '`; Every function takes the WebManip browser object (wm) as its first argument.`n'
			. '`; See Run_MyFunctions.ahk for how to use them.`n'
			. '`; ======================================================================`n`n'
		list := ''
		for fn in fns {
			code .= this.GenFunction(fn) '`n'
			p := this.ParamsOf(fn['steps']), ps := ''
			for x in p
				ps .= ', ' x
			list .= '   ' fn['name'] '(wm' ps ')`n'
		}
		f := FileOpen(this.exportFile, 'w', 'UTF-8')
		f.Write(code)
		f.Close()
		this.Status('Exported ' fns.Length ' function(s) to MyFunctions.ahk')
		MsgBox('Saved ' this.exportFile '`n`nFunctions:`n' list '`nCall them from Run_MyFunctions.ahk (or any script that includes WebManipLib.ahk and MyFunctions.ahk).', 'Export', 'Iconi')
	}
}
