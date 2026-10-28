#Requires AutoHotkey v2.0 64-bit
#Include %A_LineFile%\..\WebView2.ahk

/************************************************************************
 * WebManip runtime: an embedded Edge (WebView2) browser you can script.
 *
 *   wm := WebManip(0, {url: 'https://example.com'})   ; opens its own browser window
 *   wm.Click('#save')                                  ; CSS selector
 *   wm.SetValue('//input[@name="q"]', 'hello')         ; XPath
 *   wm.Click('{"frames":[],"strategies":[...]}')       ; locator made by the builder
 *
 * Every action waits (default 10 s) until its target matches EXACTLY ONE element.
 * A builder locator holds several ways to find the element; they are tried in order and
 * the first one that matches exactly one element (with the expected tag) is used.
 * If none do, the action throws an Error instead of touching the wrong element.
 ***********************************************************************/
class WebManip {
	/**
	 * @param hostHwnd Window to put the browser in. 0 = create a new window.
	 * @param opts {title, width, height, url, dataDir, exitOnClose}
	 */
	__New(hostHwnd := 0, opts := {}) {
		this.results := Map(), this.seq := 0, this.navDone := true, this.navOk := true
		this.OnPicked := 0, this.OnNavigated := 0, this.OnLoaded := 0, this.gui := 0
		this.DefaultTimeout := 10000
		SplitPath(A_LineFile, , &dir)
		this.dir := dir
		if !hostHwnd {
			g := this.gui := Gui('+Resize', opts.HasProp('title') ? opts.title : 'WebManip Browser')
			g.OnEvent('Size', (gui, minMax, *) => minMax != -1 && this.HasOwnProp('ctrl') && this.Fill())
			if !opts.HasProp('exitOnClose') || opts.exitOnClose
				g.OnEvent('Close', (*) => ExitApp())
			g.Show('w' (opts.HasProp('width') ? opts.width : 1200) ' h' (opts.HasProp('height') ? opts.height : 800))
			hostHwnd := g.Hwnd
		}
		this.hwnd := hostHwnd
		dataDir := opts.HasProp('dataDir') ? opts.dataDir : dir '\WebView2Data'
		this.ctrl := WebView2.CreateControllerAsync(hostHwnd, 0, dataDir, '', dir '\WebView2Loader.dll').await()
		this.wv := this.ctrl.CoreWebView2
		this.wv.AddScriptToExecuteOnDocumentCreatedAsync(FileRead(dir '\wm_helper.js', 'UTF-8')).await()
		this.wv.add_WebMessageReceived((s, a) => this._OnMessage(a))
		this.wv.add_NavigationStarting((s, a) => (this.navDone := false))
		this.wv.add_NavigationCompleted((s, a) => this._OnNavCompleted(a))
		this.wv.add_SourceChanged((s, a) => this._Fire('OnNavigated'))
		this.wv.add_NewWindowRequested((s, a) => this._OnNewWindow(a))
		if opts.HasProp('url')
			this.Navigate(opts.url, false)
	}

	; ------------------------------------------------------------------ browser
	Navigate(url, wait := true, timeout := 30000) {
		url := Trim(url)
		if !RegExMatch(url, 'i)^[a-z][a-z0-9+.-]*:')
			url := 'https://' url
		this.navDone := false
		this.wv.Navigate(url)
		if wait
			this.WaitLoad(timeout)
	}
	/** Waits until the current navigation has finished and the document is fully loaded. */
	WaitLoad(timeout := 30000) {
		end := A_TickCount + timeout
		Sleep(200) ; give a navigation started by a click a moment to begin
		while !this.navDone {
			if A_TickCount > end
				throw TimeoutError('Page did not finish loading.', -1)
			Sleep(30)
		}
		loop {
			try if this.wv.ExecuteScriptAsync('document.readyState').await(3000) = '"complete"'
				return
			if A_TickCount > end
				throw TimeoutError('Page did not finish loading.', -1)
			Sleep(50)
		}
	}
	Back() => this.wv.GoBack()
	Forward() => this.wv.GoForward()
	Reload() => this.wv.Reload()
	Url => this.wv.Source
	Title => this.wv.DocumentTitle
	/** Runs JavaScript in the top page and returns the result (objects come back as Map/Array). */
	JS(code) => JSON.Parse(this.wv.ExecuteScriptAsync(code).await())
	Fill() => this.ctrl.Fill()
	SetBounds(x, y, w, h) {
		rc := Buffer(16), NumPut('int', x, 'int', y, 'int', x + w, 'int', y + h, rc)
		this.ctrl.Bounds := rc
	}
	SetPickMode(on) {
		try this.wv.ExecuteScriptAsync('window.__wm && __wm.setPick(' (on ? 'true' : 'false') ')').await(3000)
	}

	; ------------------------------------------------------------------ element actions
	Click(target, timeout := '') => this.Do('click', target, '', timeout)
	DoubleClick(target, timeout := '') => this.Do('dblclick', target, '', timeout)
	SetValue(target, value, timeout := '') => this.Do('setvalue', target, value, timeout)
	SelectOption(target, textOrValue, timeout := '') => this.Do('select', target, textOrValue, timeout)
	Check(target, timeout := '') => this.Do('check', target, '', timeout)
	Uncheck(target, timeout := '') => this.Do('uncheck', target, '', timeout)
	Focus(target, timeout := '') => this.Do('focus', target, '', timeout)
	Hover(target, timeout := '') => this.Do('hover', target, '', timeout)
	ScrollTo(target, timeout := '') => this.Do('scroll', target, '', timeout)
	Highlight(target, timeout := '') => this.Do('highlight', target, '', timeout)
	GetText(target, timeout := '') => this.Do('gettext', target, '', timeout)
	GetValue(target, timeout := '') => this.Do('getvalue', target, '', timeout)
	GetAttr(target, name, timeout := '') => this.Do('getattr', target, name, timeout)
	/** Throws if the element doesn't appear (as exactly one match) within the timeout. */
	WaitFor(target, timeout := '') => this.Do('waitfor', target, '', timeout)
	WaitGone(target, timeout := '') => this.Do('waitgone', target, '', timeout)
	/** Returns true/false. Doesn't wait unless you pass a timeout. */
	Exists(target, timeout := 0) => this.Do('exists', target, '', timeout)
	/** Types text with the real keyboard (for sites that ignore SetValue). */
	TypeKeys(target, text, timeout := '') {
		this._FocusForKeys(target, timeout)
		SendText(text)
	}
	/** Sends AutoHotkey keys, e.g. '{Enter}', '{Tab}', '^a'. */
	PressKeys(target, keys, timeout := '') {
		this._FocusForKeys(target, timeout)
		Send(keys)
	}

	/** Low-level: run any helper action. Returns the action's value (if any). */
	Do(action, target, value := '', timeout := '') {
		if timeout = ''
			timeout := this.DefaultTimeout
		cmd := '{"action":' JSON.Quote(action) ',"target":' WebManip.Locator(target)
			. ',"value":' JSON.Quote(String(value)) ',"timeout":' Integer(timeout) '}'
		return this._Exec(cmd, timeout)
	}

	/** Turns a Map / locator JSON / CSS / XPath into locator JSON. */
	static Locator(target) {
		if IsObject(target)
			return JSON.Stringify(target)
		if SubStr(LTrim(target), 1, 1) = '{' {
			try JSON.Parse(target)
			catch
				throw ValueError('Locator is not valid JSON: ' SubStr(target, 1, 80), -2)
			return target
		}
		t := RegExMatch(target, '^\s*[(/]') ? 'xpath' : 'css'
		return '{"frames":[],"strategies":[{"t":"' t '","v":' JSON.Quote(target) '}]}'
	}

	; ------------------------------------------------------------------ data files
	/**
	 * Reads a .csv / .txt / .xlsx / .xls file. The first row must be the column names.
	 * Returns an Array of Maps (column name -> cell text, names not case-sensitive).
	 * The Array has a .Headers property; each Map has a .SheetRow property (row number in the file).
	 *   for row in WebManip.ReadTable('C:\data\hours.csv')
	 *       SubmitHours(wm, row['Name'], row['Hours'])
	 * Excel files need Excel installed; only the first sheet is read, as the cells are displayed.
	 */
	static ReadTable(path) {
		loop files path
			path := A_LoopFileFullPath
		if !FileExist(path)
			throw Error('File not found: ' path, -1)
		SplitPath(path, , , &ext)
		if RegExMatch(ext, 'i)^xls') {
			tmp := A_Temp '\wm_table_' A_TickCount '.csv'
			enc := WebManip._ExcelToCsv(path, tmp)
			text := FileRead(tmp, enc)
			try FileDelete(tmp)
		} else
			text := FileRead(path) ; UTF-8 with BOM, otherwise the system code page (what Excel saves)
		return WebManip.ParseCsv(text)
	}
	static _ExcelToCsv(src, dst) {
		try xl := ComObject('Excel.Application')
		catch
			throw Error('Excel is not installed here. Save the sheet as CSV and choose that file instead.', -2)
		enc := 'UTF-8'
		xl.DisplayAlerts := false
		try {
			wb := xl.Workbooks.Open(src, 0, true) ; read-only, works even if the file is open
			wb.Worksheets(1).Activate()
			try wb.SaveAs(dst, 62)               ; CSV UTF-8
			catch {
				wb.SaveAs(dst, 6)                ; plain CSV (older Excel)
				enc := 'CP0'
			}
			wb.Close(false)
		} finally
			xl.Quit()
		return enc
	}
	static ParseCsv(text) {
		text := RTrim(text, '`r`n')
		first := SubStr(text, 1, (InStr(text, '`n') || StrLen(text) + 1) - 1)
		d := ','
		for c in [';', '`t']
			if StrSplit(first, c).Length > StrSplit(first, d).Length
				d := c
		dq := d = '`t' ? '\t' : d
		pat := '\G(?:"((?:[^"]++|"")*+)"|([^' dq '\r\n]*+))(' dq '|\r?\n|$)'
		lines := [], row := [], pos := 1
		loop {
			if !RegExMatch(text, pat, &m, pos)
				throw Error('Could not read the CSV near character ' pos, -2)
			row.Push(SubStr(m[0], 1, 1) = '"' ? StrReplace(m[1], '""', '"') : m[2])
			pos += m.Len
			if m[3] != d {
				lines.Push(row), row := []
				if m[3] = ''
					break
			}
		}
		headers := [], seen := Map(), seen.CaseSense := false
		for i, h in lines[1] {
			h := Trim(h)
			if h = ''
				h := 'Column' i
			if seen.Has(h)
				h .= '_' i
			seen[h] := 1, headers.Push(h)
		}
		rows := []
		rows.Headers := headers
		loop lines.Length - 1 {
			cells := lines[A_Index + 1], blank := true
			for v in cells
				if Trim(v) != ''
					blank := false
			if blank
				continue
			r := Map(), r.CaseSense := false
			for i, h in headers
				r[h] := cells.Has(i) ? cells[i] : ''
			r.SheetRow := A_Index + 1
			rows.Push(r)
		}
		return rows
	}
	static CsvLine(values) {
		out := ''
		for v in values {
			v := String(v ?? '')
			if RegExMatch(v, '[",\r\n;]')
				v := '"' StrReplace(v, '"', '""') '"'
			out .= (A_Index > 1 ? ',' : '') v
		}
		return out
	}

	; ------------------------------------------------------------------ internals
	_Exec(cmdJson, timeout) {
		id := ++this.seq
		end := A_TickCount + timeout + 6000
		loop {
			try r := this.wv.ExecuteScriptAsync('window.__wm ? __wm.exec(' id ',' cmdJson ') : "nohelper"').await(5000)
			catch
				r := ''
			if r = '"ok"'
				break
			if A_TickCount > end
				throw Error('The page is not ready (helper not loaded). Is a page open and finished loading?', -2)
			Sleep(100)
		}
		while !this.results.Has(id) {
			if A_TickCount > end
				throw TimeoutError('No response from the page (did it navigate away mid-action?).', -2)
			Sleep(15)
		}
		res := this.results.Delete(id)
		if !res.Get('ok', 0)
			throw Error(res.Get('error', 'Action failed.'), -2)
		return res.Get('value', '')
	}
	_FocusForKeys(target, timeout) {
		top := DllCall('GetAncestor', 'ptr', this.hwnd, 'uint', 2, 'ptr')
		WinActivate('ahk_id ' top)
		WinWaitActive('ahk_id ' top, , 2)
		this.ctrl.MoveFocus(0)
		if target != ''
			this.Do('focus', target, '', timeout)
		Sleep(50)
	}
	_OnMessage(args) {
		try msg := JSON.Parse(args.WebMessageAsJson)
		catch
			return
		if !(msg is Map) || !msg.Has('type')
			return
		switch msg['type'] {
			case 'result': this.results[msg['id']] := msg
			case 'picked', 'pickCancel': this._Fire('OnPicked', msg)
		}
	}
	_OnNavCompleted(args) {
		this.navDone := true
		try this.navOk := args.IsSuccess
		this._Fire('OnLoaded')
	}
	_OnNewWindow(args) {
		; Open popups / target=_blank links in this same view instead of a separate window.
		uri := args.Uri
		args.Handled := true
		SetTimer(() => this.wv.Navigate(uri), -1)
	}
	_Fire(name, args*) {
		if fn := this.%name%
			SetTimer(() => fn(args*), -1) ; run outside the COM callback
	}
}

/************************************************************************
 * Minimal JSON: objects -> Map, arrays -> Array, true/false -> 1/0, null -> ''.
 ***********************************************************************/
class JSON {
	static Parse(text) {
		pos := 1
		v := JSON._Value(text, &pos)
		JSON._Ws(text, &pos)
		if pos <= StrLen(text)
			throw ValueError('JSON: unexpected text at ' pos)
		return v
	}
	static _Ws(t, &p) {
		while (c := SubStr(t, p, 1)) != '' && InStr(' `t`r`n', c)
			p++
	}
	static _Value(t, &p) {
		JSON._Ws(t, &p)
		c := SubStr(t, p, 1)
		if c = '{' {
			m := Map(), p++
			JSON._Ws(t, &p)
			if SubStr(t, p, 1) = '}'
				return (p++, m)
			loop {
				JSON._Ws(t, &p)
				k := JSON._Str(t, &p)
				JSON._Ws(t, &p)
				if SubStr(t, p++, 1) != ':'
					throw ValueError('JSON: expected ":" at ' (p - 1))
				m[k] := JSON._Value(t, &p)
				JSON._Ws(t, &p)
				c := SubStr(t, p++, 1)
				if c = '}'
					return m
				if c != ','
					throw ValueError('JSON: expected "," or "}" at ' (p - 1))
			}
		}
		if c = '[' {
			a := [], p++
			JSON._Ws(t, &p)
			if SubStr(t, p, 1) = ']'
				return (p++, a)
			loop {
				a.Push(JSON._Value(t, &p))
				JSON._Ws(t, &p)
				c := SubStr(t, p++, 1)
				if c = ']'
					return a
				if c != ','
					throw ValueError('JSON: expected "," or "]" at ' (p - 1))
			}
		}
		if c = '"'
			return JSON._Str(t, &p)
		if RegExMatch(t, '\G-?\d+(\.\d+)?([eE][+-]?\d+)?', &m, p) {
			p += m.Len
			return (m[1] != '' || m[2] != '') ? Float(m[0]) : Integer(m[0])
		}
		if SubStr(t, p, 4) == 'true'
			return (p += 4, 1)
		if SubStr(t, p, 5) == 'false'
			return (p += 5, 0)
		if SubStr(t, p, 4) == 'null'
			return (p += 4, '')
		throw ValueError('JSON: unexpected character at ' p)
	}
	static _Str(t, &p) {
		if !RegExMatch(t, '\G"((?:[^"\\]++|\\.)*+)"', &m, p)
			throw ValueError('JSON: bad string at ' p)
		p += m.Len
		s := m[1]
		if !InStr(s, '\')
			return s
		out := '', i := 1
		while j := InStr(s, '\', true, i) {
			out .= SubStr(s, i, j - i)
			c := SubStr(s, j + 1, 1)
			switch c, true {
				case 'n': out .= '`n'
				case 'r': out .= '`r'
				case 't': out .= '`t'
				case 'b': out .= Chr(8)
				case 'f': out .= Chr(12)
				case 'u': out .= Chr(Integer('0x' SubStr(s, j + 2, 4))), j += 4
				default: out .= c
			}
			i := j + 2
		}
		return out . SubStr(s, i)
	}

	static Stringify(v, indent := '', _lvl := '') {
		if v is Map || v is Array || (IsObject(v) && Type(v) = 'Object') {
			nl := indent = '' ? '' : '`n', in2 := _lvl indent, sep := indent = '' ? ':' : ': '
			out := ''
			if v is Array {
				for x in v
					out .= (A_Index > 1 ? ',' : '') nl in2 JSON.Stringify(x ?? '', indent, in2)
				return '[' out (out = '' ? '' : nl _lvl) ']'
			}
			for k, x in (v is Map ? v : v.OwnProps())
				out .= (A_Index > 1 ? ',' : '') nl in2 JSON.Quote(String(k)) sep JSON.Stringify(x ?? '', indent, in2)
			return '{' out (out = '' ? '' : nl _lvl) '}'
		}
		if v is Number
			return String(v)
		return JSON.Quote(String(v))
	}
	static Quote(s) {
		s := StrReplace(s, '\', '\\'), s := StrReplace(s, '"', '\"')
		s := StrReplace(s, '`n', '\n'), s := StrReplace(s, '`r', '\r'), s := StrReplace(s, '`t', '\t')
		while RegExMatch(s, '[\x00-\x1F]', &m)
			s := StrReplace(s, m[0], Format('\u{:04X}', Ord(m[0])))
		return '"' s '"'
	}
}
