#Requires AutoHotkey v2.0 64-bit
#Include %A_LineFile%\..\WebManipLib.ahk

/************************************************************************
 * TicketLib: functions for Ticket Tool.
 * Settings are at the top of each section. Everything takes `app` (the Ticket Tool).
 ***********************************************************************/


; ======================================================================
; 1. Double-click a row: open that ticket's pages in the tabs
; ======================================================================

; Page to open in each tab. {ticket} and {account} are replaced with the row's values.
; Leave a tab '' to leave it alone.
ROW_PAGES := Map(
	'Remedy', '',   ; e.g. 'https://remedy.example.com/ticket?id={ticket}'
	'AOS',    '',   ; e.g. 'https://aos.example.com/account/{account}'
	'Sat',    '',
	'Scope',  '',
)

/** Opens the ROW_PAGES for a ticket. Returns how many tabs were sent somewhere. */
OpenRowPages(app, ticket, account) {
	opened := 0
	for name, page in ROW_PAGES {
		if page = '' || !app.Web.Has(name)
			continue
		url := StrReplace(page, '{ticket}', UrlEncode(ticket))
		url := StrReplace(url, '{account}', UrlEncode(account))
		app.Web[name].Navigate(url, false)
		opened++
	}
	return opened
}


; ======================================================================
; 2. Gather data: get a site's cookies so scripts can call its API
; ======================================================================

GATHER_URL := ''                   ; page to open (it sets the cookies; sign in there if asked)
GATHER_COOKIES := []               ; cookie names to wait for, e.g. ['JSESSIONID', 'XSRF-TOKEN']
GATHER_COOKIE_URL := ''            ; site the cookies belong to: the Domain shown in F12 > Application > Cookies,
                                   ; e.g. 'con.portal.com' (an https:// address works too). '' = GATHER_URL's site
GATHER_TIMEOUT := 120000           ; how long to wait, in ms (time to sign in)

Gathered := Map()                  ; the last cookies gathered (name -> value); Http() sends these

/**
 * Opens GATHER_URL in a temporary tab, waits until every GATHER_COOKIES cookie exists,
 * closes the tab, and returns all the site's cookies as a Map (also saved in Gathered).
 * Throws if it times out or you close the tab first.
 */
GatherCookies(app, url := '', names := '', cookieUrl := '', timeout := '') {
	global Gathered
	url := url != '' ? url : GATHER_URL
	names := IsObject(names) ? names : GATHER_COOKIES
	cookieUrl := cookieUrl != '' ? cookieUrl : GATHER_COOKIE_URL != '' ? GATHER_COOKIE_URL : url
	timeout := timeout != '' ? timeout : GATHER_TIMEOUT
	if url = ''
		throw ValueError('Set GATHER_URL in TicketLib.ahk first.', -1)
	wm := app.AddTab('Gathering… ✕', url)
	end := A_TickCount + timeout
	c := Map(), missing := '', lastErr := ''
	try loop {
		if wm.closed
			throw Error('The tab was closed before the cookies were found.', -1)
		try {
			c := wm.Cookies(cookieUrl)
			missing := ''
			for n in names
				if !c.Has(n) || c[n] = ''
					missing .= n ' '
			if c.Count && missing = '' {
				Gathered := c
				return c
			}
		} catch as e
			lastErr := e.Message
		if A_TickCount > end
			throw TimeoutError(_GatherReport(wm, cookieUrl, c, missing, lastErr), -1)
		Sleep(500)
	} finally
		app.RemoveTab(wm)
}

_GatherReport(wm, cookieUrl, found, missing, lastErr) {   ; explains a timeout so it can be fixed
	msg := 'Timed out waiting for: ' Trim(missing) '`n`nLooked for cookies on: ' cookieUrl
	seen := ''
	for k in found
		seen .= (seen = '' ? '' : ', ') k
	msg .= '`nCookies found there: ' (seen = '' ? '(none)' : seen)
	if seen = '' {   ; nothing on that site: list the domains the browser does have cookies for
		doms := Map()
		try for ck in wm.AllCookies()
			doms[LTrim(ck.Domain, '.')] := 1
		list := '', shown := 0
		for d in doms
			if ++shown <= 25
				list .= (list = '' ? '' : ', ') d
		if doms.Count > 25
			list .= ' … and ' (doms.Count - 25) ' more'
		msg .= '`nSites the browser has cookies for: ' (list = '' ? '(none)' : list)
	}
	if lastErr != ''
		msg .= '`n`nLast error: ' lastErr
	return msg
}

/** For a button: gathers the cookies and says how it went. */
GatherData(app) {
	static busy := false
	if busy
		return
	busy := true
	try {
		ToolTip('Gathering data… sign in if the page asks.')
		c := GatherCookies(app)
		ToolTip('Got ' c.Count ' cookies.')
		SetTimer(() => ToolTip(), -2500)
	} catch as e {
		ToolTip()
		MsgBox('Gather data failed:`n`n' e.Message, 'Ticket Tool', 'Icon!')
	}
	busy := false
}


; ======================================================================
; HTTP requests using the gathered cookies
; ======================================================================

/**
 * Sends an HTTP request with the gathered cookies.
 * body: text, or a Map/Array (sent as JSON). headers: Map of extra headers.
 * Returns {Status, Text}. Use HttpJson() to get parsed JSON back.
 */
Http(method, url, body := '', headers := '', cookies := '') {
	if !IsObject(cookies)
		cookies := Gathered
	req := ComObject('WinHttp.WinHttpRequest.5.1')
	req.Open(method, url, false)
	if cookies.Count
		req.SetRequestHeader('Cookie', CookieHeader(cookies))
	if body is Map || body is Array {
		body := JSON.Stringify(body)
		req.SetRequestHeader('Content-Type', 'application/json')
	}
	if IsObject(headers)
		for k, v in headers
			req.SetRequestHeader(k, v)
	req.Send(body)
	return {Status: req.Status, Text: req.ResponseText}
}

/** Like Http(), but throws on a non-2xx status and returns the reply parsed as JSON (Map/Array). */
HttpJson(method, url, body := '', headers := '', cookies := '') {
	r := Http(method, url, body, headers, cookies)
	if r.Status < 200 || r.Status >= 300
		throw Error('HTTP ' r.Status ' from ' url '`n`n' SubStr(r.Text, 1, 500), -1)
	return JSON.Parse(r.Text)
}

/** "name=value; name2=value2" for a Cookie header. */
CookieHeader(cookies) {
	s := ''
	for k, v in cookies
		s .= (s = '' ? '' : '; ') k '=' v
	return s
}

/** Makes text safe to put in a URL. */
UrlEncode(s) {
	out := ''
	buf := Buffer(StrPut(s, 'UTF-8'))
	StrPut(s, buf, 'UTF-8')
	loop buf.Size - 1 {
		b := NumGet(buf, A_Index - 1, 'uchar')
		if (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) || b = 0x2D || b = 0x2E || b = 0x5F || b = 0x7E
			out .= Chr(b)
		else
			out .= Format('%{:02X}', b)
	}
	return out
}
