/* Original optional adapter. No host internals, message bodies, title writes or save automation. */
(function installNativeTitleSuggestions(win) {
  'use strict';
  const VERSION = '1.0.0';
  if (win.__codexNativeTitle?.version === VERSION) return;
  win.__codexNativeTitle?.dispose();
  const doc = win.document, ROW = '[data-app-action-sidebar-thread-id]';
  const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
  let disposed = false, queued = false, pending = null, session = null;
  const listeners = [];
  function on(target, name, fn, options) { target.addEventListener(name, fn, options); listeners.push(() => target.removeEventListener(name, fn, options)); }
  function visible(el) { return el?.isConnected && !el.closest('[hidden],[aria-hidden="true"],[data-app-shell-active-page="false"]') && el.getClientRects().length > 0; }
  function identity(row) {
    if (!visible(row) || row.getAttribute('data-app-action-sidebar-thread-kind') !== 'local') return null;
    const host = row.getAttribute('data-app-action-sidebar-thread-host-id');
    if (host !== '' && host !== 'local') return null;
    const key = row.getAttribute('data-app-action-sidebar-thread-id') || '';
    const id = key.replace(/^local:(?:local:)?/, '');
    return UUID.test(id) ? {id, key, title: row.getAttribute('data-app-action-sidebar-thread-title')} : null;
  }
  function active() {
    const rows = [...doc.querySelectorAll(ROW + '[data-app-action-sidebar-thread-active="true"]')].filter(visible);
    const values = rows.map(identity);
    if (values.some(x => !x)) return null;
    return new Set(values.map(x => x.id)).size === 1 ? values[0] : null;
  }
  function remember(value, source) { pending = {value, source, at: Date.now()}; }
  function capture(event) {
    const target = event.target instanceof win.Element ? event.target : null;
    if (!target || session?.dialog.contains(target) || target.closest('[data-codex-native-title]')) return;
    const row = target.closest(ROW);
    if (event.type === 'contextmenu' || event.type === 'dblclick') {
      remember(row ? identity(row) : null, 'row');
      return;
    }
    if (row && target.closest('button,[aria-haspopup="menu"]')) { remember(identity(row), 'row'); return; }
    const menuItem = target.closest('[role="menuitem"]');
    if (menuItem) {
      if (!/^(重命名(?:聊天)?|Rename(?: chat)?)(?:$|\s|⌘|Ctrl|Alt|Shift)/i.test(menuItem.textContent.trim())) pending = null;
      return;
    }
    if (target.closest('[role="menu"],[data-radix-menu-content]')) return;
    const button = target.closest('button');
    if (button && /^(Chat actions|聊天操作|聊天操作菜单|对话操作|更多操作)$/i.test(button.getAttribute('aria-label') || '')) {
      remember(active(), 'current'); return;
    }
    pending = null;
  }
  for (const name of ['pointerdown', 'contextmenu', 'dblclick']) on(doc, name, capture, true);
  on(doc, 'keydown', event => {
    if ((event.ctrlKey || event.metaKey) && event.altKey && event.key.toLowerCase() === 'r') remember(active(), 'current');
    if (event.key === 'Escape' && !session) pending = null;
    if ((event.key === 'ContextMenu' || (event.shiftKey && event.key === 'F10')) && event.target instanceof win.Element) remember(identity(event.target.closest(ROW)), 'row');
    if (['Enter', ' ', 'ArrowDown'].includes(event.key) && event.target instanceof win.Element && event.target.matches('button,[aria-haspopup="menu"]') && event.target.closest(ROW)) remember(identity(event.target.closest(ROW)), 'row');
  }, true);
  function post(endpoint, data) {
    if (typeof win.__codexTitleBridge?.post !== 'function') return Promise.reject(Error('bridge_unavailable'));
    try { return Promise.resolve(win.__codexTitleBridge.post(endpoint, data)); } catch (error) { return Promise.reject(error); }
  }
  function cancel(s) {
    s.epoch++;
    if (s.requestId) post('/native/cancel', {requestId: s.requestId, threadId: s.threadId}).catch(() => {});
    s.requestId = null;
  }
  function close() {
    if (!session) return;
    const s = session; session = null; cancel(s); s.input.removeEventListener('input', s.edited); s.input.removeEventListener('change', s.edited); s.host.remove();
  }
  function render(s, message, title = '') {
    if (session !== s) return;
    s.status.textContent = message; s.suggestion.textContent = title;
    s.use.disabled = !s.title || s.dirty || s.blocked;
    s.again.disabled = s.loading || s.dirty || s.blocked || !s.threadId;
  }
  function valid(s) { return session === s && visible(s.dialog) && s.input.isConnected && !s.blocked && win.location.href === s.locationAtOpen && (active()?.id || null) === s.activeAtOpen; }
  async function generate(s, refresh) {
    if (!valid(s) || s.dirty || !s.threadId) return;
    cancel(s); const epoch = s.epoch, requestId = win.crypto.randomUUID();
    s.requestId = requestId; s.title = null; s.loading = true;
    render(s, '正在生成标题建议…');
    try {
      const result = await post('/native/suggest', {threadId: s.threadId, currentTitle: s.initial.slice(0, 200), requestId, refresh});
      if (!valid(s) || epoch !== s.epoch || s.dirty) return;
      if (result.requestId !== requestId || result.threadId !== s.threadId || typeof result.title !== 'string' || !result.title.trim() || result.title.length > 60) throw Error('invalid_response');
      s.title = result.title; s.loading = false; s.requestId = null;
      render(s, result.cached ? '标题建议（缓存）' : '标题建议', s.title);
    } catch (_) {
      if (!valid(s) || epoch !== s.epoch) return;
      s.loading = false; s.requestId = null;
      render(s, '生成未完成，请重试；仍可手动修改并保存。');
    }
  }
  function findDialog() {
    const matches = [...doc.querySelectorAll('[role="dialog"]')].filter(visible).filter(d => {
      const labelled = (d.getAttribute('aria-labelledby') || '').split(/\s+/).map(id => doc.getElementById(id)?.textContent || '').join(' ').trim();
      const heading = d.querySelector('h1,h2,[role="heading"]')?.textContent.trim();
      return /^(重命名聊天|Rename chat)$/i.test(labelled || heading || '');
    });
    if (matches.length !== 1) return null;
    const d = matches[0];
    const inputs = [...d.querySelectorAll('input')].filter(i => visible(i) && /^(Chat title|聊天标题|对话标题)$/i.test(i.getAttribute('aria-label') || '') && ['text', ''].includes(i.getAttribute('type') || '') && !i.disabled);
    return inputs.length === 1 ? {dialog: d, input: inputs[0]} : null;
  }
  function open(found) {
    let proof = pending && Date.now() - pending.at < 15000 ? pending.value : null;
    pending = null;
    if (proof?.title != null && proof.title !== found.input.value) proof = null;
    const host = doc.createElement('div'); host.setAttribute('data-codex-native-title', VERSION);
    const root = host.attachShadow({mode: 'open'});
    root.innerHTML = '<style>:host{display:block;margin:12px 0 4px;color:inherit;font:13px/1.5 system-ui}*{box-sizing:border-box}.panel{padding:10px 12px;border:1px solid #7776;border-radius:10px;background:#80800808}p{margin:0 0 7px;overflow-wrap:anywhere}button{font:inherit;color:inherit;background:transparent;border:1px solid #7778;border-radius:7px;padding:4px 10px;margin-right:8px;cursor:pointer}button:disabled{opacity:.45;cursor:default}.title{font-weight:600}.foot{opacity:.65;font-size:11px;margin-top:8px}</style><section class="panel" aria-label="AI 标题建议"><p role="status" aria-live="polite"></p><p class="title"></p><button type="button" data-action="use">采用建议</button><button type="button" data-action="again">再想一个</button><p class="foot">采用后可编辑，点击原生“保存”才会改名。</p></section>';
    const s = session = {...found, host, threadId: proof?.id || null, activeAtOpen: active()?.id || null, locationAtOpen: win.location.href, initial: found.input.value, epoch: 0, dirty: false, blocked: false, loading: false, title: null,
      status: root.querySelector('[role="status"]'), suggestion: root.querySelector('.title'), use: root.querySelector('[data-action="use"]'), again: root.querySelector('[data-action="again"]')};
    s.edited = () => { if (s.writing) return; s.dirty = true; s.loading = false; cancel(s); render(s, '已保留你的手动输入；本次不再替换标题。', s.title || ''); };
    s.input.addEventListener('input', s.edited); s.input.addEventListener('change', s.edited);
    s.use.addEventListener('click', () => {
      if (!valid(s) || s.dirty || !s.title || s.input.value !== s.initial) { s.edited(); return; }
      s.writing = true;
      try { Object.getOwnPropertyDescriptor(win.HTMLInputElement.prototype, 'value').set.call(s.input, s.title); s.input.dispatchEvent(new win.Event('input', {bubbles: true})); s.initial = s.title; }
      finally { s.writing = false; }
      render(s, '已填入建议，请确认后点击“保存”。', s.title);
    });
    s.again.addEventListener('click', () => generate(s, true));
    root.addEventListener('keydown', event => { if (event.key === 'Enter' || event.key === ' ') event.stopPropagation(); });
    attach(s);
    if (s.threadId) generate(s, false); else render(s, '未能确认目标聊天，请关闭后从侧栏聊天菜单重新打开。');
  }
  function attach(s) {
    if (s.input.parentElement !== s.dialog) s.input.parentElement.insertAdjacentElement('afterend', s.host);
    else s.dialog.append(s.host);
  }
  function scan() {
    queued = false; if (disposed) return;
    const found = findDialog();
    if (session && (!found || found.dialog !== session.dialog || found.input !== session.input)) close();
    if (!session && found) { open(found); return; }
    if (!session) return;
    const s = session;
    if (!s.blocked && ((active()?.id || null) !== s.activeAtOpen || win.location.href !== s.locationAtOpen)) { s.blocked = true; s.loading = false; cancel(s); render(s, '当前聊天已切换，请重新打开重命名。'); }
    // Reattach only our panel after a host rerender; do not replace native content.
    if (!s.host.isConnected && s.input.isConnected) attach(s);
  }
  function schedule() { if (!queued && !disposed) { queued = true; win.queueMicrotask(scan); } }
  on(win, 'popstate', schedule); on(win, 'hashchange', schedule);
  const observer = new win.MutationObserver(schedule);
  observer.observe(doc.documentElement, {childList: true, subtree: true, attributes: true, attributeFilter: ['aria-hidden','hidden','data-state','data-app-action-sidebar-thread-active','data-app-shell-active-page']});
  win.__codexNativeTitle = {version: VERSION, dispose() { if (disposed) return; disposed = true; observer.disconnect(); listeners.splice(0).forEach(fn => fn()); close(); pending = null; delete win.__codexNativeTitle; }};
  scan();
})(window);
