/* Runs only a new isolated fixture page, never an installed application's CDP session. */
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const {chromium} = require('playwright');
const script = fs.readFileSync(process.env.TITLE_RENDERER_UNDER_TEST || path.join(__dirname, 'renderer.js'), 'utf8');
const A = '11111111-1111-4111-8111-111111111111', B = '22222222-2222-4222-8222-222222222222';
(async () => {
 const browser = await chromium.launch({headless: true, ...(process.env.TITLE_TEST_CHANNEL ? {channel: process.env.TITLE_TEST_CHANNEL} : {})});
 try {
  const page = await browser.newPage();
  await page.route('http://127.0.0.1:19876/**', route => route.fulfill({contentType: 'text/html', body: '<!doctype html><html><body></body></html>'}));
  async function fixture() {
   await page.goto('http://127.0.0.1:19876/fixture');
   await page.setContent(`<div id="a" data-app-action-sidebar-thread-id="local:${A}" data-app-action-sidebar-thread-kind="local" data-app-action-sidebar-thread-host-id="local" data-app-action-sidebar-thread-active="true" data-app-action-sidebar-thread-title="旧标题 A">旧标题 A<button aria-haspopup="menu">…</button></div><div id="b" data-app-action-sidebar-thread-id="local:${B}" data-app-action-sidebar-thread-kind="local" data-app-action-sidebar-thread-host-id="local" data-app-action-sidebar-thread-active="false" data-app-action-sidebar-thread-title="旧标题 B">旧标题 B<button aria-haspopup="menu">…</button></div><button aria-label="Chat actions" id="header">…</button>`);
   await page.evaluate(() => {
    window.requests = []; window.cancels = []; window.saves = 0;
    window.__codexTitleBridge = {post(endpoint, data) {
      if (endpoint === '/native/cancel') {window.cancels.push(data); return Promise.resolve({cancelled: true});}
      return new Promise((resolve, reject) => window.requests.push({data, resolve, reject}));
    }};
    window.openDialog = (title = '旧标题 A') => {
      const div = document.createElement('div'); div.setAttribute('role', 'dialog'); div.setAttribute('aria-labelledby', 'heading');
      div.innerHTML = '<h2 id="heading">重命名聊天</h2><div><input type="text" aria-label="聊天标题"></div><button id="save">保存</button>';
      div.querySelector('input').value = title; document.body.append(div);
      div.querySelector('#save').onclick = () => window.saves++;
    };
   });
   await page.addScriptTag({content: script});
  }
  async function open(row = 'a', title = '旧标题 A') {
    if(row === 'header') await page.locator('#header').dispatchEvent('pointerdown');
    else await page.locator('#' + row).dispatchEvent('contextmenu');
    await page.evaluate(title => window.openDialog(title), title);
    await page.locator('[data-codex-native-title]').waitFor();
  }
  async function resolve(index = 0, title = '建议新标题') {
    await page.evaluate(({index, title}) => { const r = window.requests[index]; r.resolve({...r.data, title, cached: false}); }, {index, title});
    await page.waitForTimeout(20);
  }
  async function count() {return page.evaluate(() => window.requests.length);}
  const input = () => page.locator('[role="dialog"] input');
  const use = () => page.getByRole('button', {name: '采用建议'});
  await fixture(); await open('b', '旧标题 B');
  assert.equal(await page.evaluate(() => window.requests[0].data.threadId), B, 'inactive context target');
  assert.deepEqual(Object.keys(await page.evaluate(() => window.requests[0].data)).sort(), ['currentTitle','refresh','requestId','threadId']);
  await resolve(); assert.equal(await input().inputValue(), '旧标题 B'); await use().click();
  assert.equal(await input().inputValue(), '建议新标题'); assert.equal(await page.evaluate(() => window.saves), 0);
  await fixture(); await open('header'); assert.equal(await page.evaluate(() => window.requests[0].data.threadId), A, 'current thread explicit actions');
  await fixture(); await page.evaluate(() => window.openDialog()); await page.locator('[data-codex-native-title]').waitFor(); assert.equal(await count(), 0, 'no identity no generation');
  await fixture(); await open(); await input().fill('我自己的标题'); await resolve(); assert.equal(await input().inputValue(), '我自己的标题'); assert(await use().isDisabled()); assert.equal(await page.evaluate(() => window.cancels.length), 1);
  await fixture(); await open(); await page.evaluate(() => document.querySelector('[role="dialog"]').remove()); await page.waitForTimeout(20); await resolve(); assert.equal(await page.locator('[data-codex-native-title]').count(), 0); assert.equal(await page.evaluate(() => window.cancels.length), 1);
  await open(); assert.equal(await count(), 2); await resolve(1, '新一轮'); assert.equal(await page.locator('.title').textContent(), '新一轮');
  await fixture(); await open(); await page.evaluate(() => {document.querySelector('#a').setAttribute('data-app-action-sidebar-thread-active', 'false');document.querySelector('#b').setAttribute('data-app-action-sidebar-thread-active', 'true');}); await resolve(); assert(await use().isDisabled()); assert.equal(await input().inputValue(), '旧标题 A');
  await fixture(); await open(); await resolve(); await page.evaluate(() => document.querySelector('[data-codex-native-title]').remove()); await page.waitForTimeout(20); assert.equal(await page.locator('[data-codex-native-title]').count(), 1); assert.equal(await count(), 1, 'panel rerender no repeated billing');
  await page.addScriptTag({content: script}); assert.equal(await page.locator('[data-codex-native-title]').count(), 1); assert.equal(await count(), 1);
  await page.evaluate(() => window.__codexNativeTitle.dispose()); assert.equal(await page.locator('[data-codex-native-title]').count(), 0);
  await fixture(); await page.locator('#b').evaluate(el => el.setAttribute('data-app-action-sidebar-thread-host-id', 'remote-host')); await open('b', '旧标题 B'); assert.equal(await count(), 0, 'foreign host rejected');
  await fixture(); await page.locator('#b').dispatchEvent('dblclick'); await page.evaluate(() => window.openDialog('旧标题 B')); await page.locator('[data-codex-native-title]').waitFor(); assert.equal(await page.evaluate(() => window.requests[0].data.threadId), B);
  await fixture(); await open(); await resolve(); await page.getByRole('button', {name: '再想一个'}).click(); assert.equal(await page.evaluate(() => window.requests[1].data.refresh), true); await resolve(1, '二次标题'); await use().click(); assert.equal(await input().inputValue(), '二次标题');
  await fixture(); await open(); await page.evaluate(() => {const r=window.requests[0];r.resolve({...r.data,threadId:'wrong',title:'错误'});}); await page.waitForTimeout(20); assert(await use().isDisabled());
  await fixture(); await open(); await page.evaluate(() => document.querySelector('[role="dialog"]').remove()); await page.waitForTimeout(20); await open(); await resolve(1, '当前请求'); await resolve(0, '迟到请求'); assert.equal(await page.locator('.title').textContent(), '当前请求');
  await fixture(); await open(); await page.evaluate(() => {const old=document.querySelector('input');const next=old.cloneNode();next.value='重绘输入';old.replaceWith(next);}); await page.waitForTimeout(20); await resolve(); assert.equal(await input().inputValue(), '重绘输入'); assert.equal(await count(), 1); assert(await use().isDisabled());
  await fixture(); await page.locator('#b').evaluate(el=>el.setAttribute('data-app-action-sidebar-thread-active','true')); await open('header'); assert.equal(await count(), 0, 'ambiguous active target');
  await fixture(); await open('b', '另一个聊天标题'); assert.equal(await count(), 0, 'explicit target consistency mismatch');
  await fixture(); await open(); await resolve(); await page.evaluate(() => {window.nativeInputEvents=0;document.querySelector('input').addEventListener('input',()=>window.nativeInputEvents++);}); await use().click(); assert.equal(await page.evaluate(()=>window.nativeInputEvents),1,'native controlled input event emitted');
  await fixture(); await page.evaluate(()=>{document.querySelector('#a').setAttribute('data-app-action-sidebar-thread-title','长'.repeat(300));}); await open('a','长'.repeat(300)); assert.equal(await page.evaluate(()=>window.requests[0].data.currentTitle.length),200,'long initial title stays bounded');
  await fixture(); await page.locator('#a').dispatchEvent('contextmenu'); await page.evaluate(()=>{const m=document.createElement('div');m.setAttribute('role','menuitem');m.textContent='重命名 Ctrl+R';document.body.append(m);m.dispatchEvent(new PointerEvent('pointerdown',{bubbles:true}));window.openDialog();});await page.locator('[data-codex-native-title]').waitFor();assert.equal(await count(),1,'rename shortcut label preserves row identity');
  console.log('PASS: 20 isolated DOM fixture scenarios; native Codex UI not controlled.');
 } finally { await browser.close(); }
})().catch(e => {console.error(e); process.exitCode=1;});
