const assert = require('node:assert/strict');
const {TitleSuggestions} = require('./suggestion.js');
function fixture() {
  let value = '旧标题';
  const calls = [], cancelled = [], rendered = [];
  const controller = new TitleSuggestions({
    request: data => new Promise((resolve, reject) => calls.push({data, resolve, reject})),
    cancel: id => cancelled.push(id), render: data => rendered.push(data),
    readValue: () => value, writeValue: text => {value = text;}
  });
  return {controller, calls, cancelled, rendered, value: () => value, type: text => {value = text; controller.input();}};
}
function resolve(call, title = '新标题') {call.resolve({...call.data, title, cached: false});}
(async () => {
  let f = fixture(), pending = f.controller.open('a', []);
  assert.equal(f.calls.length, 1); resolve(f.calls[0]); await pending;
  assert.equal(f.value(), '旧标题', 'never auto-fill or auto-save');
  assert.equal(f.controller.useSuggestion(), true); assert.equal(f.value(), '新标题');
  f = fixture(); pending = f.controller.open('a', []); f.type('用户正在写'); resolve(f.calls[0]); await pending;
  assert.equal(f.controller.useSuggestion(), false); assert.equal(f.value(), '用户正在写');
  f = fixture(); pending = f.controller.open('a', []); f.controller.close(); resolve(f.calls[0]); await pending;
  assert.equal(f.rendered.at(-1).state, 'closed'); assert.equal(f.cancelled.length, 1);
  f = fixture(); const first = f.controller.open('a', []); const second = f.controller.open('b', []);
  resolve(f.calls[1], 'B'); await second; resolve(f.calls[0], 'A'); await first;
  assert.equal(f.rendered.at(-1).title, 'B');
  f = fixture(); pending = f.controller.open('a', []); f.calls[0].reject(Error('timeout')); await pending;
  assert.equal(f.value(), '旧标题'); assert.equal(f.rendered.at(-1).state, 'error');
  f = fixture(); pending = f.controller.open('a', []); f.calls[0].resolve({requestId:'wrong', threadId:'a', title:'错误'}); await pending;
  assert.equal(f.rendered.at(-1).state, 'error');
  f = fixture(); pending = f.controller.open('a', []); resolve(f.calls[0]); await pending;
  const again = f.controller.generate(); assert.equal(f.calls[1].data.refresh, true); resolve(f.calls[1], '另一标题'); await again;
  assert.equal(f.rendered.at(-1).title, '另一标题');
  assert.equal(f.controller.useSuggestion(), true);
  const third = f.controller.generate(); resolve(f.calls[2], '再一个标题'); await third;
  assert.equal(f.controller.useSuggestion(), true); assert.equal(f.value(), '再一个标题');
  console.log('PASS: 7 controller scenarios (plain JS fixture; not native Codex UI)');
})().catch(error => {console.error(error); process.exitCode = 1;});
