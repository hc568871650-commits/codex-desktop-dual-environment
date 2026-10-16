import test from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import {allowedPage, validTarget, Cdp, bridgeBootstrap, installationScript} from './loader.mjs';

const page = {id: 'ABC-123', type: 'page', url: 'app://-/index.html', webSocketDebuggerUrl: 'ws://127.0.0.1:9333/devtools/page/ABC-123'};
test('only the exact application page and its matching websocket are accepted', () => {
  assert.equal(allowedPage(page, 9333), true);
  for (const change of [{url:'https://chatgpt.com'}, {url:'app://-/other.html'}, {url:'app://-/index.html?window=quick-chat'},
    {type:'iframe'}, {webSocketDebuggerUrl:'ws://evil.example:9333/devtools/page/ABC-123'},
    {webSocketDebuggerUrl:'ws://127.0.0.1:9334/devtools/page/ABC-123'},
    {webSocketDebuggerUrl:'ws://127.0.0.1:9333/devtools/page/OTHER'},
    {webSocketDebuggerUrl:'ws://user:pass@127.0.0.1:9333/devtools/page/ABC-123'}]) assert.equal(allowedPage({...page,...change},9333),false);
});
test('runtime target cannot select another home/profile/CLI/desktop', () => {
  const binding = {home:'E:\\Api\\Home',profile:'E:\\Api\\Profile',desktop:{path:'C:\\Codex\\ChatGPT.exe'},cli:{path:'C:\\Codex\\codex.exe'}};
  const target = {pid:10,port:9333,startedTicks:'639277142275284480',browserPath:'/devtools/browser/123abc',home:binding.home,profile:binding.profile,desktopExe:binding.desktop.path,cli:binding.cli.path};
  assert.equal(validTarget(target,binding),true);
  for(const key of ['home','profile','desktopExe','cli'])assert.equal(validTarget({...target,[key]:'E:\\Other'},binding),false);
  assert.equal(validTarget({...target,port:0},binding),false);
});
test('in-page bridge correlates responses and rejects outstanding work on dispose', async () => {
  const messages=[];const window={send:value=>messages.push(JSON.parse(value))};
  const scope={window,location:{protocol:'app:',hostname:'-',pathname:'/index.html'},setTimeout,clearTimeout,Map,Promise,Error,Object,JSON};
  assert.equal(vm.runInNewContext(bridgeBootstrap('send','receive','nonce'),scope),true);
  const request=window.__codexTitleBridge.post('/native/suggest',{requestId:'one'});
  assert.equal(messages[0].nonce,'nonce');assert.equal(messages[0].method,'/native/suggest');
  window.receive({id:messages[0].id,result:{title:'hello'}});assert.equal((await request).title,'hello');
  const pending=window.__codexTitleBridge.post('/native/suggest',{requestId:'two'});
  window.__codexTitleBridge.dispose();await assert.rejects(pending,/closed/);
  assert.equal(window.receive,undefined);
});
test('bridge never installs on a web page', () => {
  const window={};assert.equal(vm.runInNewContext(bridgeBootstrap('send','receive','nonce'),{window,location:{protocol:'https:'}}),false);
  assert.equal(window.__codexTitleBridge,undefined);
});
test('scope gate and renderer installation are atomic in one expression', () => {
  const window={};const code=installationScript('window.__codexNativeTitle={version:1};', 'send','receive','nonce');
  assert.equal(vm.runInNewContext(code,{window,location:{protocol:'https:'}}),false);
  assert.equal(window.__codexNativeTitle,undefined);
  const scope={window,location:{protocol:'app:',hostname:'-',pathname:'/index.html'},Map,Promise,Object,JSON,Error,setTimeout,clearTimeout};
  assert.equal(vm.runInNewContext(code,scope),true);
  assert.equal(window.__codexNativeTitle.version,1);
});
test('CDP correlates IDs and rejects pending requests on disconnect', async () => {
  class Socket extends EventTarget {send(raw){this.last=JSON.parse(raw);}close(){this.dispatchEvent(new Event('close'));}}
  const socket=new Socket(), cdp=new Cdp(socket);
  const p=cdp.call('Runtime.enable');socket.dispatchEvent(new MessageEvent('message',{data:JSON.stringify({id:socket.last.id,result:{enabled:true}})}));
  assert.equal((await p).enabled,true);
  const pending=cdp.call('Runtime.evaluate');socket.close();await assert.rejects(pending,/closed/);
});
