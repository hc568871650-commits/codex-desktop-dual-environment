// Original, narrowly scoped CDP loader. Windows launcher validates ownership first.
import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {spawn} from 'node:child_process';
import {randomBytes, randomUUID} from 'node:crypto';
import readline from 'node:readline';

const HERE = path.dirname(fileURLToPath(import.meta.url));
export function allowedPage(target, port) {
  try {
    if (target.type !== 'page' || !/^[a-zA-Z0-9_-]{1,100}$/.test(target.id)) return false;
    const page = new URL(target.url), ws = new URL(target.webSocketDebuggerUrl);
    return page.protocol === 'app:' && page.hostname === '-' && page.pathname === '/index.html'
      && !/avatar|quick.?chat|codex.?micro|devtools|browser/i.test(page.search)
      && ws.protocol === 'ws:' && ws.hostname === '127.0.0.1'
      && Number(ws.port) === port && !ws.username && !ws.password && !ws.search && !ws.hash
      && ws.pathname === '/devtools/page/' + target.id;
  } catch { return false; }
}
export function validTarget(target, binding) {
  return Number.isInteger(target.port) && target.port > 0 && target.port < 65536
    && Number.isInteger(target.pid) && target.pid > 0
    && typeof target.startedTicks === 'string' && /^\d{15,20}$/.test(target.startedTicks)
    && /^\/devtools\/browser\/[a-zA-Z0-9_-]+$/.test(target.browserPath)
    && samePath(target.home, binding.home) && samePath(target.profile, binding.profile)
    && samePath(target.desktopExe, binding.desktop.path) && samePath(target.cli, binding.cli.path);
}
function samePath(a, b) { return typeof a === 'string' && typeof b === 'string' && path.win32.resolve(a).toLowerCase() === path.win32.resolve(b).toLowerCase(); }
function readJson(file) { return JSON.parse(fs.readFileSync(file, 'utf8').replace(/^\uFEFF/, '')); }

export class Cdp {
  constructor(socket) {
    this.socket = socket; this.sequence = 0; this.pending = new Map(); this.onEvent = () => {};
    socket.addEventListener('message', event => {
      if (typeof event.data !== 'string' || event.data.length > 2_000_000) return;
      let data; try { data = JSON.parse(event.data); } catch { return; }
      if (data.id && this.pending.has(data.id)) {
        const item = this.pending.get(data.id); clearTimeout(item.timer); this.pending.delete(data.id);
        data.error ? item.reject(Error('cdp_request_failed')) : item.resolve(data.result);
      } else if (data.method) this.onEvent(data);
    });
    socket.addEventListener('close', () => this.rejectAll());
    socket.addEventListener('error', () => this.rejectAll());
  }
  rejectAll() { for (const item of this.pending.values()) { clearTimeout(item.timer); item.reject(Error('cdp_closed')); } this.pending.clear(); }
  call(method, params = {}) {
    return new Promise((resolve, reject) => {
      const id = ++this.sequence;
      const timer = setTimeout(() => { this.pending.delete(id); reject(Error('cdp_timeout')); }, 5000);
      this.pending.set(id, {resolve, reject, timer});
      try { this.socket.send(JSON.stringify({id, method, params})); }
      catch { clearTimeout(timer); this.pending.delete(id); reject(Error('cdp_closed')); }
    });
  }
  close() { this.rejectAll(); this.socket.close(); }
}

export function bridgeBootstrap(bindingName, receiveName, nonce) {
  return `(()=>{if(location.protocol!=='app:'||location.hostname!=='-'||location.pathname!=='/index.html')return false;
    window.__codexNativeTitle?.dispose?.();
    window.__codexTitleBridge?.dispose?.();
    const pending=new Map(); let sequence=0;
    const receive=(message)=>{const p=pending.get(message.id);if(!p)return;clearTimeout(p.timer);pending.delete(message.id);message.error?p.reject(new Error(message.error)):p.resolve(message.result);};
    Object.defineProperty(window,${JSON.stringify(receiveName)},{value:receive,configurable:true});
    const bridge={post(method,data){return new Promise((resolve,reject)=>{const id=String(++sequence);const timer=setTimeout(()=>{pending.delete(id);reject(new Error('title_request_timeout'));},55000);pending.set(id,{resolve,reject,timer});try{window[${JSON.stringify(bindingName)}](JSON.stringify({nonce:${JSON.stringify(nonce)},id,method,data}));}catch{clearTimeout(timer);pending.delete(id);reject(new Error('title_bridge_unavailable'));}});},dispose(){for(const p of pending.values()){clearTimeout(p.timer);p.reject(new Error('title_bridge_closed'));}pending.clear();delete window[${JSON.stringify(receiveName)}];}};
    Object.defineProperty(window,'__codexTitleBridge',{value:bridge,configurable:true});return true;})()`;
}
export function installationScript(renderer, bindingName, receiveName, nonce) {
  // One evaluation: navigation cannot occur between scope validation and installation.
  return `(()=>{if(!(${bridgeBootstrap(bindingName, receiveName, nonce)}))return false;\n${renderer}\nreturn !!window.__codexNativeTitle;})()`;
}

async function main() {
  const args = process.argv.slice(2);
  const bindingFile = args[args.indexOf('--binding') + 1], targetFile = args[args.indexOf('--target') + 1];
  if (!args.includes('--binding') || !args.includes('--target')) throw Error('arguments_required');
  const binding = readJson(bindingFile), target = readJson(targetFile);
  if (!validTarget(target, binding)) throw Error('target_binding_mismatch');
  const statusPath = path.join(binding.stateDirectory, 'native-status.json');
  const disabledPath = path.join(binding.installRoot, 'DISABLED');
  const renderer = fs.readFileSync(path.join(HERE, 'renderer.js'), 'utf8');
  let worker, stopping = false, workerReady = false, timer, attempts = 0, lastGenerationError = null;
  const pages = new Map(), requests = new Map(), pageFailures = new Map();
  function status(state, reason = null) {
    const value = {schema: 1, state, reason, utc: new Date().toISOString(), desktopPid: target.pid,
      attachedPages: pages.size, generatedRequests: attempts, nativeSavePerformed: false, lastGenerationError};
    try { const temp = statusPath + '.' + process.pid + '.tmp'; fs.writeFileSync(temp, JSON.stringify(value)); fs.renameSync(temp, statusPath); } catch {}
  }
  function sendWorker(method, data, callback = () => {}) {
    if (!workerReady || !worker || worker.stdin.destroyed) { callback({error: 'title_worker_unavailable'}); return; }
    const id = randomUUID();
    requests.set(id, callback);
    try { worker.stdin.write(JSON.stringify({id, method, data}) + '\n'); }
    catch { requests.delete(id); callback({error: 'title_worker_unavailable'}); }
  }
  async function detach(page) {
    if (page.closed) return;
    page.closed = true;
    pages.delete(page.id);
    for (const requestId of page.active) sendWorker('/native/cancel', {requestId});
    page.active.clear();
    try {
      await page.cdp.call('Runtime.evaluate', {expression: `if(location.protocol==='app:'&&location.hostname==='-'&&location.pathname==='/index.html'){window.__codexNativeTitle?.dispose?.();window.__codexTitleBridge?.dispose?.();delete window.__codexTitleBridge;delete window[${JSON.stringify(page.bindingName ?? '')}];}`});
      if (page.bindingName) await page.cdp.call('Runtime.removeBinding', {name: page.bindingName});
    } catch {}
    page.cdp.close();
  }
  async function stop(reason) {
    if (stopping) return;
    stopping = true; clearInterval(timer);
    await Promise.allSettled([...pages.values()].map(detach));
    if (worker && !worker.stdin.destroyed) { worker.stdin.end(JSON.stringify({method: 'shutdown'}) + '\n'); }
    status('stopped', reason);
    // Worker cancels owned generation on stdin EOF. Bounded emergency cleanup only targets this child.
    setTimeout(() => { if (worker && worker.exitCode === null) worker.kill(); process.exit(0); }, 4000);
  }
  async function fetchJson(route) {
    const response = await fetch(`http://127.0.0.1:${target.port}${route}`, {signal: AbortSignal.timeout(3000), redirect: 'error'});
    if (!response.ok) throw Error('debug_endpoint_unavailable');
    const body = await response.text();
    if (body.length > 1_000_000) throw Error('debug_response_oversize');
    return JSON.parse(body);
  }
  async function attach(item) {
    const socket = new WebSocket(item.webSocketDebuggerUrl);
    const page = {id: item.id, cdp: new Cdp(socket), closed: false, active: new Set(), ready: false};
    pages.set(item.id, page);
    try {
      await new Promise((resolve, reject) => {
        const limit = setTimeout(() => { socket.close(); reject(Error('debug_connect_timeout')); }, 4000);
        socket.addEventListener('open', () => { clearTimeout(limit); resolve(); }, {once: true});
        socket.addEventListener('error', () => { clearTimeout(limit); reject(Error('debug_connect_failed')); }, {once: true});
      });
      const nonce = randomBytes(24).toString('hex'), name = '__codexTitleSend_' + randomBytes(8).toString('hex');
      page.bindingName = name;
      const receive = '__codexTitleReceive_' + randomBytes(8).toString('hex');
      page.cdp.onEvent = event => {
        if (event.method === 'Runtime.executionContextsCleared') { void detach(page); return; }
        if (event.method !== 'Runtime.bindingCalled' || event.params?.name !== name || page.closed) return;
        let message;
        try { if (event.params.payload.length > 16384) return; message = JSON.parse(event.params.payload); } catch { return; }
        if (message.nonce !== nonce || !/^\d{1,12}$/.test(message.id) || !message.data || typeof message.data !== 'object') return;
        if (!['/native/suggest', '/native/cancel'].includes(message.method)) return;
        const rid = message.data.requestId;
        if (typeof rid !== 'string' || !/^[A-Za-z0-9_-]{1,100}$/.test(rid)) return;
        const reply = payload => {
          if (page.closed) return;
          void page.cdp.call('Runtime.evaluate', {expression: `window[${JSON.stringify(receive)}]?.(${JSON.stringify({id: message.id, ...payload})})`, contextId: event.params.executionContextId}).catch(() => {});
        };
        if (fs.existsSync(disabledPath)) { reply({error: 'title_disabled'}); void stop('disabled'); return; }
        if (message.method === '/native/cancel') {
          if (page.active.has(rid)) sendWorker('/native/cancel', {requestId: rid});
          reply({result: {cancelled: true}}); return;
        }
        if (page.active.size >= 2) { reply({error: 'busy'}); return; }
        page.active.add(rid); attempts++; status('attached');
        sendWorker('/native/suggest', message.data, result => {
          page.active.delete(rid);
          lastGenerationError = result.error ? (/^[a-z0-9_]{1,80}$/.test(result.error) ? result.error : 'generation_failed') : null;
          status(stopping ? 'stopped' : 'attached'); reply(result);
        });
      };
      socket.addEventListener('close', () => { void detach(page); });
      await page.cdp.call('Runtime.enable');
      await page.cdp.call('Runtime.addBinding', {name});
      const result = await page.cdp.call('Runtime.evaluate', {expression: installationScript(renderer, name, receive, nonce), returnByValue: true});
      if (page.closed || result.exceptionDetails || result.result?.value !== true) throw Error('page_scope_changed_or_incompatible');
      pageFailures.delete(item.id); page.ready = true; status('attached');
    } catch {
      const count = (pageFailures.get(item.id)?.count ?? 0) + 1;
      pageFailures.set(item.id, {count, retryAt: count >= 3 ? Infinity : Date.now() + count * 5000});
      await detach(page); status('waiting', count >= 3 ? 'page_incompatible_restart_required' : 'page_attach_failed');
    }
  }
  let discovering = false, failures = 0;
  async function discover() {
    if (discovering || stopping) return;
    if (fs.existsSync(disabledPath)) { await stop('disabled'); return; }
    discovering = true;
    try {
      const version = await fetchJson('/json/version');
      const ws = new URL(version.webSocketDebuggerUrl);
      if (ws.protocol !== 'ws:' || ws.hostname !== '127.0.0.1' || Number(ws.port) !== target.port || ws.pathname !== target.browserPath) { await stop('browser_identity_changed'); return; }
      const targets = await fetchJson('/json/list');
      if (!Array.isArray(targets)) throw Error('invalid_target_list');
      const allowed = targets.filter(item => allowedPage(item, target.port));
      const ids = new Set(allowed.map(item => item.id));
      for (const id of pageFailures.keys()) if (!ids.has(id)) pageFailures.delete(id);
      await Promise.allSettled([...pages.values()].filter(page => !ids.has(page.id)).map(detach));
      // Bounded sequential attachments; no broad injection into browser tabs.
      for (const item of allowed.slice(0, 8)) if (!pages.has(item.id) && !(pageFailures.get(item.id)?.retryAt > Date.now())) await attach(item);
      const blocked = [...pageFailures.values()].some(item => item.count >= 3);
      failures = 0; status(pages.size ? 'attached' : 'waiting', pages.size ? null : blocked ? 'page_incompatible_restart_required' : 'main_page_not_found');
    } catch { if (++failures >= 3) await stop('debug_connection_lost'); else status('waiting', 'debug_connection_unavailable'); }
    finally { discovering = false; }
  }
  status('starting');
  worker = spawn(binding.python.path, ['-I', '-B', '-X', 'utf8', path.join(HERE, 'worker.py'), '--binding', bindingFile],
    {windowsHide: true, stdio: ['pipe', 'pipe', 'ignore'], cwd: HERE});
  worker.stdin.on('error', () => {
    workerReady = false;
    for (const callback of requests.values()) callback({error: 'title_worker_unavailable'});
    requests.clear(); void stop('worker_pipe_closed');
  });
  const ready = new Promise((resolve, reject) => {
    const limit = setTimeout(() => reject(Error('worker_start_timeout')), 35000);
    const lines = readline.createInterface({input: worker.stdout});
    lines.on('line', line => {
      if (line.length > 16384) return;
      let result; try { result = JSON.parse(line); } catch { return; }
      if (result.type === 'ready') { clearTimeout(limit); workerReady = true; resolve(); }
      else if (result.type === 'failed') { clearTimeout(limit); reject(Error('worker_initialization_failed')); }
      else if (requests.has(result.id)) { const callback = requests.get(result.id); requests.delete(result.id); callback(result.error ? {error: String(result.error).slice(0,100)} : {result: result.result}); }
    });
    worker.once('error', () => { clearTimeout(limit); reject(Error('worker_start_failed')); });
    worker.once('exit', () => { clearTimeout(limit); reject(Error('worker_exited')); });
  });
  worker.on('exit', () => { workerReady = false; for (const callback of requests.values()) callback({error: 'title_worker_unavailable'}); requests.clear(); void stop('worker_exited'); });
  process.on('SIGTERM', () => { void stop('stopped_by_host'); });
  process.on('SIGINT', () => { void stop('stopped_by_user'); });
  try { await ready; await discover(); if (!stopping) timer = setInterval(() => { void discover(); }, 2500); }
  catch { await stop('worker_initialization_failed'); }
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch(() => { process.stderr.write('Native title loader could not start.\n'); process.exitCode = 1; });
}
