// WebManip page helper. Injected into every page and every frame by WebManipLib.ahk.
// - Element picker (hover highlight + click to select)
// - Builds several ways ("strategies") to target the picked element and counts matches for each
// - Runs actions (click, set value, ...) using a list of strategies, falling back in order
//   until one matches exactly ONE element.
// Frames: each frame runs its own copy; frames talk to their parent with postMessage,
// so this works for same-origin and cross-origin iframes.
(function () {
  if (window.__wm) return;
  const W = (window.__wm = {});
  const isTop = window === window.top;
  const host = m => { try { window.chrome.webview.postMessage(m); } catch (e) {} };
  const sleep = ms => new Promise(r => setTimeout(r, ms));
  let seq = 0;
  const pending = new Map();

  // ---------------------------------------------------------------- querying
  function qAll(doc, s) {
    try {
      if (s.t === 'xpath') {
        const r = doc.evaluate(s.v, doc, null, XPathResult.ORDERED_NODE_SNAPSHOT_TYPE, null);
        const out = [];
        for (let i = 0; i < r.snapshotLength; i++) {
          const n = r.snapshotItem(i);
          if (n.nodeType === 1) out.push(n);
        }
        return out;
      }
      return Array.from(doc.querySelectorAll(s.v));
    } catch (e) {
      return null; // invalid selector
    }
  }

  const esc = s => (window.CSS && CSS.escape ? CSS.escape(s) : String(s).replace(/([^\w-])/g, '\\$1'));
  const attrVal = v => '"' + String(v).replace(/\\/g, '\\\\').replace(/"/g, '\\"') + '"';
  const xlit = s =>
    !s.includes("'") ? `'${s}'` : !s.includes('"') ? `"${s}"` :
      'concat(' + s.split("'").map(p => `'${p}'`).join(`,"'",`) + ')';
  // ids/classes that look machine-generated and likely to change between page loads
  const dyn = s => /\d{4,}|^[0-9a-f-]{8,}$|^:|:$|^(ember|react|mui|ext-gen|j_id|ng-|_ngcontent|css-|sc-|jss|x-auto)/i.test(s);
  const stableClasses = el =>
    Array.from(el.classList).filter(c => !dyn(c) &&
      !/^(is-|has-|ng-)|active|hover|focus|selected|checked|open|show|visible|highlight|disabled|__wm/i.test(c));
  const tagOf = el => el.tagName.toLowerCase();
  const normText = el => (el.textContent || '').replace(/\s+/g, ' ').trim();
  const nthOfType = el => { let i = 1, s = el; while ((s = s.previousElementSibling)) if (s.tagName === el.tagName) i++; return i; };
  const sameTypeSiblings = el => {
    const p = el.parentElement;
    if (!p) return false;
    for (const c of p.children) if (c !== el && c.tagName === el.tagName) return true;
    return false;
  };
  const isPlainTag = el => /^[a-z][a-z0-9-]*$/i.test(el.tagName);

  // ---------------------------------------------------------------- selector generation
  function smartPath(el) {
    // Walk up from the element, adding one level at a time, until the path is unique.
    // Anchors on the nearest ancestor with a stable unique id.
    const doc = el.ownerDocument, parts = [];
    for (let n = el; n && n.nodeType === 1; n = n.parentElement) {
      if (n !== el && n.id && !dyn(n.id) && (qAll(doc, { t: 'css', v: '#' + esc(n.id) }) || []).length === 1) {
        parts.unshift('#' + esc(n.id));
      } else {
        let s = tagOf(n) + stableClasses(n).slice(0, 2).map(c => '.' + esc(c)).join('');
        if (sameTypeSiblings(n)) s += `:nth-of-type(${nthOfType(n)})`;
        parts.unshift(s);
      }
      const sel = parts.join(' > ');
      const r = qAll(doc, { t: 'css', v: sel });
      if (r && r.length === 1 && r[0] === el) return sel;
    }
    return parts.join(' > ');
  }

  function fullCssPath(el) {
    const parts = [];
    for (let n = el; n && n.nodeType === 1; n = n.parentElement) {
      let s = tagOf(n);
      if (sameTypeSiblings(n)) s += `:nth-of-type(${nthOfType(n)})`;
      parts.unshift(s);
    }
    return parts.join(' > ');
  }

  function fullXPath(el) {
    const parts = [];
    for (let n = el; n && n.nodeType === 1; n = n.parentElement) {
      const name = isPlainTag(n) ? tagOf(n) : `*[name()='${n.tagName}']`;
      parts.unshift(n.parentElement ? `${name}[${nthOfType(n)}]` : name);
    }
    return '/' + parts.join('/');
  }

  function candidates(el) {
    const doc = el.ownerDocument, tag = tagOf(el), out = [], seen = new Set();
    let rank = 0;
    const add = (t, v, label, penalty = 0) => {
      rank++;
      if (!v || seen.has(t + '|' + v)) return;
      seen.add(t + '|' + v);
      const r = qAll(doc, { t, v });
      if (!r) return;
      out.push({ t, v, label, count: r.length, hit: r.includes(el), rank: rank + penalty });
    };

    if (el.id) add('css', '#' + esc(el.id), dyn(el.id) ? 'ID (looks auto-generated)' : 'ID', dyn(el.id) ? 100 : 0);
    for (const a of ['data-testid', 'data-test-id', 'data-test', 'data-qa', 'data-cy', 'data-automation-id', 'name']) {
      const v = el.getAttribute(a);
      if (v && v.length < 150) add('css', `${tag}[${a}=${attrVal(v)}]`, 'Attribute: ' + a, dyn(v) ? 100 : 0);
    }
    // Form field found via its <label> text (good when ids are auto-generated)
    if (el.labels && el.labels.length) {
      const lab = el.labels[0], lt = normText(lab);
      if (lt && lt.length <= 80) {
        if (lab.contains(el)) add('xpath', `//label[normalize-space(.)=${xlit(lt)}]//${tag}`, 'By label text');
        else if (lab.htmlFor) add('xpath', `//*[@id=//label[normalize-space(.)=${xlit(lt)}]/@for]`, 'By label text');
      }
    }
    for (const a of ['aria-label', 'placeholder', 'title', 'alt', 'for']) {
      const v = el.getAttribute(a);
      if (v && v.length < 150) add('css', `${tag}[${a}=${attrVal(v)}]`, 'Attribute: ' + a);
    }
    if (tag === 'input' && /^(submit|button|reset)$/i.test(el.type) && el.value)
      add('css', `input[type=${attrVal(el.type)}][value=${attrVal(el.value)}]`, 'Button caption');
    const txt = normText(el);
    if (txt && txt.length <= 80 && el.children.length <= 3 && isPlainTag(el))
      add('xpath', `//${tag}[normalize-space(.)=${xlit(txt)}]`, 'Exact text');
    if (tag === 'a') {
      const h = el.getAttribute('href');
      if (h && h.length < 150 && !/^javascript:|^#$/i.test(h)) add('css', `a[href=${attrVal(h)}]`, 'Link address');
    }
    const cls = stableClasses(el);
    if (cls.length) add('css', tag + cls.slice(0, 3).map(c => '.' + esc(c)).join(''), 'Tag + class');
    add('css', smartPath(el), 'Smart path (shortest unique)');
    add('css', fullCssPath(el), 'Full CSS path');
    add('xpath', fullXPath(el), 'Full XPath');

    // Unique matches first, then by preference order
    out.sort((a, b) => ((b.count === 1 && b.hit) - (a.count === 1 && a.hit)) || a.rank - b.rank);
    out.forEach(c => delete c.rank);
    return out;
  }

  const uniqueStrategies = el => candidates(el).filter(c => c.count === 1 && c.hit).map(c => ({ t: c.t, v: c.v }));

  function describe(el) {
    const isField = 'value' in el && /^(INPUT|TEXTAREA|SELECT)$/.test(el.tagName);
    return {
      type: 'picked',
      tag: el.tagName,
      id: el.id || '',
      name: el.getAttribute('name') || '',
      inputType: el.getAttribute('type') || '',
      classes: typeof el.className === 'string' ? el.className : '',
      text: (el.innerText || el.textContent || '').replace(/\s+/g, ' ').trim().slice(0, 200),
      value: isField ? String(el.value).slice(0, 200) : '',
      cands: candidates(el),
      frames: [],
      url: location.href
    };
  }

  // Send a message toward the host, letting each parent frame prepend how to find the iframe.
  function report(msg) {
    if (isTop) host(msg);
    else window.parent.postMessage({ __wm: 'up', msg }, '*');
  }

  // ---------------------------------------------------------------- picker
  let picking = false, box = null, tip = null, hoverEl = null;
  function overlay() {
    if (box && box.isConnected) return;
    const root = document.documentElement;
    box = document.createElement('div');
    box.setAttribute('data-wm-overlay', '');
    box.style.cssText = 'position:fixed;z-index:2147483647;pointer-events:none;border:2px solid #e8590c;background:rgba(232,89,12,.15);border-radius:2px;display:none;box-sizing:border-box';
    tip = document.createElement('div');
    tip.setAttribute('data-wm-overlay', '');
    tip.style.cssText = 'position:fixed;z-index:2147483647;pointer-events:none;background:#222;color:#fff;font:12px/1.4 Consolas,monospace;padding:2px 6px;border-radius:3px;display:none;max-width:60vw;white-space:nowrap;overflow:hidden;text-overflow:ellipsis';
    root.appendChild(box);
    root.appendChild(tip);
  }
  function hideOverlay() { if (box) box.style.display = tip.style.display = 'none'; }
  function realTarget(e) {
    let el = e.target;
    while (el && el.namespaceURI === 'http://www.w3.org/2000/svg') el = el.parentElement; // click on icon -> use its container
    if (!el || el.nodeType !== 1 || el.hasAttribute('data-wm-overlay')) return null;
    return el;
  }
  function onMove(e) {
    if (!picking) return;
    const el = realTarget(e);
    if (!el) return;
    hoverEl = el;
    overlay();
    const r = el.getBoundingClientRect();
    Object.assign(box.style, { display: 'block', left: r.left + 'px', top: r.top + 'px', width: r.width + 'px', height: r.height + 'px' });
    let label = tagOf(el) + (el.id ? '#' + el.id : '') + stableClasses(el).slice(0, 2).map(c => '.' + c).join('');
    tip.textContent = label + `  ${Math.round(r.width)}×${Math.round(r.height)}`;
    tip.style.display = 'block';
    tip.style.left = Math.max(0, r.left) + 'px';
    tip.style.top = (r.top > 22 ? r.top - 22 : r.bottom + 2) + 'px';
  }
  function block(e) {
    if (!picking) return;
    e.preventDefault();
    e.stopPropagation();
    e.stopImmediatePropagation();
    if (e.type === 'click') {
      const el = realTarget(e) || hoverEl;
      if (!el) return;
      hideOverlay();
      report(describe(el));
    }
  }
  function onKey(e) {
    if (picking && e.key === 'Escape') { e.preventDefault(); report({ type: 'pickCancel', frames: [] }); }
  }
  ['mousedown', 'mouseup', 'click', 'dblclick', 'pointerdown', 'pointerup', 'contextmenu', 'auxclick'].forEach(t =>
    window.addEventListener(t, block, true));
  window.addEventListener('mousemove', onMove, true);
  window.addEventListener('keydown', onKey, true);

  W.setPick = on => {
    picking = !!on;
    if (!picking) hideOverlay();
    for (let i = 0; i < window.frames.length; i++) {
      try { window.frames[i].postMessage({ __wm: 'pick', on: picking }, '*'); } catch (e) {}
    }
    return picking;
  };

  // ---------------------------------------------------------------- actions
  function flash(el) {
    overlay();
    const r = el.getBoundingClientRect();
    Object.assign(box.style, { display: 'block', left: r.left + 'px', top: r.top + 'px', width: r.width + 'px', height: r.height + 'px', borderColor: '#2b8a3e', background: 'rgba(43,138,62,.2)' });
    setTimeout(() => { if (box) Object.assign(box.style, { display: 'none', borderColor: '#e8590c', background: 'rgba(232,89,12,.15)' }); }, 1500);
  }

  // Try each strategy in order; the first one that finds exactly ONE element (with the expected tag) wins.
  async function find(doc, target, timeout) {
    const end = Date.now() + (timeout || 0);
    const list = target.strategies || [];
    let summary = '';
    for (;;) {
      const parts = [];
      for (let i = 0; i < list.length; i++) {
        const r = qAll(doc, list[i]);
        if (r && r.length === 1 && (!target.tag || r[0].tagName === target.tag)) return { el: r[0], used: i };
        parts.push(`#${i + 1}: ${r === null ? 'invalid' : r.length === 1 ? 'wrong tag' : r.length + ' matches'}`);
      }
      summary = parts.join(', ');
      if (Date.now() >= end) break;
      await sleep(150);
    }
    const name = target.label ? `"${target.label}"` : 'element';
    return { error: `Could not find exactly one ${name}. Tried ${list.length} way(s): ${summary || 'none'}` };
  }

  function fireMouse(el, types) {
    const r = el.getBoundingClientRect();
    const o = { bubbles: true, cancelable: true, view: el.ownerDocument.defaultView, clientX: r.left + r.width / 2, clientY: r.top + r.height / 2, button: 0 };
    for (const t of types) {
      const Ctor = t.startsWith('pointer') && window.PointerEvent ? PointerEvent : MouseEvent;
      el.dispatchEvent(new Ctor(t, o));
    }
  }

  function nativeSet(el, v) {
    const proto = el.tagName === 'TEXTAREA' ? el.ownerDocument.defaultView.HTMLTextAreaElement.prototype
      : el.ownerDocument.defaultView.HTMLInputElement.prototype;
    const d = Object.getOwnPropertyDescriptor(proto, 'value');
    if (d && d.set) d.set.call(el, v); else el.value = v; // works with React/Vue-controlled inputs
  }
  const fire = (el, t) => el.dispatchEvent(new Event(t, { bubbles: true }));

  function selectOption(el, v) {
    v = String(v);
    const opts = Array.from(el.options || []);
    const o = opts.find(o => o.text.trim() === v) || opts.find(o => o.value === v) ||
      opts.find(o => o.text.trim().toLowerCase().includes(v.toLowerCase()));
    if (!o) throw new Error(`No option "${v}". Options: ` + opts.map(o => o.text.trim()).slice(0, 15).join(' | '));
    el.value = o.value;
    o.selected = true;
    fire(el, 'input');
    fire(el, 'change');
  }

  async function act(cmd) {
    const a = cmd.action, target = cmd.target || {}, to = cmd.timeout == null ? 10000 : cmd.timeout;
    if (a === 'probe') {
      const counts = (target.strategies || []).map(s => { const r = qAll(document, s); return r === null ? -1 : r.length; });
      return { ok: true, value: counts };
    }
    if (a === 'exists') {
      const f = await find(document, target, to);
      return { ok: true, value: f.el ? 1 : 0 };
    }
    if (a === 'waitgone') {
      const end = Date.now() + to;
      for (;;) {
        const f = await find(document, target, 0);
        if (!f.el) return { ok: true };
        if (Date.now() >= end) return { ok: false, error: 'Element still present after timeout' };
        await sleep(150);
      }
    }
    const f = await find(document, target, to);
    if (!f.el) return { ok: false, error: f.error };
    const el = f.el;
    let value;
    switch (a) {
      case 'highlight':
        el.scrollIntoView({ block: 'center', inline: 'nearest' });
        flash(el);
        break;
      case 'click':
        el.scrollIntoView({ block: 'center', inline: 'nearest' });
        try { el.focus({ preventScroll: true }); } catch (e) {}
        fireMouse(el, ['pointerover', 'mouseover', 'pointerdown', 'mousedown', 'pointerup', 'mouseup']);
        el.click();
        break;
      case 'dblclick':
        el.scrollIntoView({ block: 'center', inline: 'nearest' });
        el.click();
        fireMouse(el, ['dblclick']);
        break;
      case 'setvalue':
        el.scrollIntoView({ block: 'center', inline: 'nearest' });
        el.focus();
        if (el.tagName === 'SELECT') selectOption(el, cmd.value);
        else if (el.isContentEditable) { el.textContent = String(cmd.value); fire(el, 'input'); }
        else { nativeSet(el, String(cmd.value)); fire(el, 'input'); fire(el, 'change'); }
        break;
      case 'select':
        selectOption(el, cmd.value);
        break;
      case 'check':
      case 'uncheck': {
        const want = a === 'check';
        const aria = el.getAttribute('aria-checked');
        const cur = 'checked' in el && /^(INPUT)$/.test(el.tagName) ? el.checked : aria === 'true';
        if (cur !== want) el.click();
        break;
      }
      case 'focus':
        el.scrollIntoView({ block: 'center', inline: 'nearest' });
        el.focus();
        break;
      case 'hover':
        el.scrollIntoView({ block: 'center', inline: 'nearest' });
        fireMouse(el, ['pointerover', 'pointerenter', 'mouseover', 'mouseenter', 'mousemove']);
        break;
      case 'scroll':
        el.scrollIntoView({ block: 'center', inline: 'nearest' });
        break;
      case 'gettext':
        value = (el.innerText || el.textContent || '').trim();
        break;
      case 'getvalue':
        value = 'value' in el ? String(el.value) : (el.textContent || '').trim();
        break;
      case 'getattr':
        value = el.getAttribute(String(cmd.value)) || '';
        break;
      case 'waitfor':
        break;
      default:
        return { ok: false, error: 'Unknown action: ' + a };
    }
    return { ok: true, value, used: f.used };
  }

  // Route a command down through any iframes, then run it in the right document.
  async function run(cmd) {
    const target = cmd.target || {};
    const frames = target.frames || [];
    if (!frames.length) return act(cmd);
    const f = await find(document, Object.assign({ tag: '', label: 'frame' }, frames[0]), cmd.timeout == null ? 10000 : cmd.timeout);
    if (!f.el) return { ok: false, error: 'Frame not found. ' + f.error };
    const id = ++seq;
    const child = Object.assign({}, cmd, { target: Object.assign({}, target, { frames: frames.slice(1) }) });
    return new Promise(res => {
      pending.set(id, res);
      try { f.el.contentWindow.postMessage({ __wm: 'exec', id, cmd: child }, '*'); }
      catch (e) { pending.delete(id); res({ ok: false, error: 'Cannot reach frame: ' + e.message }); return; }
      setTimeout(() => { if (pending.delete(id)) res({ ok: false, error: 'Frame did not respond (still loading?)' }); },
        (cmd.timeout == null ? 10000 : cmd.timeout) + 4000);
    });
  }
  const safe = p => p.catch(e => ({ ok: false, error: String((e && e.message) || e) }));

  // Called by the host (top frame only). The result comes back as a web message.
  W.exec = (id, cmd) => {
    safe(run(cmd)).then(r => host(Object.assign({ type: 'result', id }, r)));
    return 'ok';
  };

  window.addEventListener('message', e => {
    const d = e.data;
    if (!d || typeof d !== 'object' || !d.__wm) return;
    if (d.__wm === 'pick' && e.source === window.parent) {
      W.setPick(d.on);
    } else if (d.__wm === 'exec' && e.source === window.parent) {
      safe(run(d.cmd)).then(r => window.parent.postMessage({ __wm: 'result', id: d.id, r }, '*'));
    } else if (d.__wm === 'result') {
      const res = pending.get(d.id);
      if (res) { pending.delete(d.id); res(d.r); }
    } else if (d.__wm === 'up') {
      const ifr = Array.from(document.querySelectorAll('iframe,frame')).find(f => f.contentWindow === e.source);
      if (!ifr) return;
      const loc = { tag: ifr.tagName, strategies: uniqueStrategies(ifr) };
      d.msg.frames = [loc].concat(d.msg.frames || []);
      report(d.msg);
    }
  }, true);
})();
