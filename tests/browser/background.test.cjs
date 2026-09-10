const {test} = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
const path = require('node:path');

function fixture() {
  const sockets = [], timers = new Map(); let next = 0, attach;
  class Socket {
    static OPEN = 1;
    constructor() { this.readyState = 0; this.sent = []; this.bufferedAmount = 0; sockets.push(this); }
    open() { this.readyState = 1; this.onopen?.(); }
    message(obj) { this.onmessage?.({data: JSON.stringify(obj)}); }
    close() { this.readyState = 3; }
    closed() { this.readyState = 3; this.onclose?.(); }
    send(text) { this.sent.push(JSON.parse(text)); }
  }
  const context = {WebSocket: Socket, console,
    setTimeout(fn) {timers.set(++next, fn); return next;},
    clearTimeout(id) {timers.delete(id);},
    chrome: {runtime: {onConnect: {addListener(fn) {attach = fn;}}}},
  };
  vm.runInNewContext(fs.readFileSync(process.env.BACKGROUND_SOURCE || path.join(__dirname, '../../browser/extension/background.js'), 'utf8'), context);
  function port() {
    const p = {name: 'ftcw', received: [], postMessage(text) {this.received.push(JSON.parse(text));},
      onMessage: {addListener(fn) {p.send = fn;}},
      onDisconnect: {addListener(fn) {p.close = fn;}},
    };
    attach(p); return p;
  }
  return {port, sockets, timers};
}

test('rename replay retains a connection record and latest state for a new tab', () => {
  const f = fixture(), a = f.port(), ws = f.sockets[0]; ws.open();
  ws.message({t:'connected', slot:0, model:'NSO GameCube Controller', name:'original'});
  ws.message({t:'name', slot:0, name:'my pad'});
  ws.message({t:'state', slot:0, seq:9, b:8, lx:0.5, ly:0, rx:0, ry:0, lt:0, rt:0});
  const b = f.port();
  assert.deepEqual(b.received.find(e=>e.t==='connected'), {t:'connected',slot:0,model:'NSO GameCube Controller',name:'my pad'});
  assert.equal(b.received.find(e=>e.t==='state')?.b, 8);
  a.close(); b.close();
});

test('obsolete socket callbacks cannot clear or feed its replacement', () => {
  const f = fixture(), a = f.port(), old = f.sockets[0]; old.open(); a.close();
  const b = f.port(), current = f.sockets[1]; current.open();
  const before = b.received.length;
  old.message({t:'connected', slot:3, model:'obsolete', name:'obsolete'});
  old.closed();
  assert.equal(b.received.length, before);
  b.send(JSON.stringify({t:'rumble',slot:0,strong:1,weak:0}));
  assert.equal(current.sent.length, 1);
  assert.equal(f.timers.size, 0);
  b.close();
});

test('last tab closure cancels retry and connection replay', () => {
  const f = fixture(), a = f.port(), ws = f.sockets[0]; ws.open();
  ws.message({t:'connected',slot:0,model:'pad',name:'pad'});
  ws.closed(); assert.equal(f.timers.size, 1);
  a.close(); assert.equal(f.timers.size, 0);
  const b = f.port(); f.sockets[1].open();
  assert.equal(b.received.filter(e=>e.t==='connected').length, 0);
  b.close();
});

test('only bounded known command messages cross from a page to the local hub', () => {
  const f = fixture(), p = f.port(), ws = f.sockets[0]; ws.open();
  for (const text of ['invalid', JSON.stringify({t:'unknown'}), JSON.stringify({t:'rumble',slot:9}), 'x'.repeat(65537)]) p.send(text);
  assert.equal(ws.sent.length, 0);
  p.send(JSON.stringify({t:'rumble',slot:1,strong:0.3,weak:0}));
  assert.equal(ws.sent.length, 1); p.close();
});

test('one tab cannot stop or refresh another tab rumble effect', () => {
  const f = fixture(), a = f.port(), b = f.port(), ws = f.sockets[0]; ws.open();
  a.send(JSON.stringify({t:'rumble',slot:0,strong:1,weak:0,phase:'start'}));
  b.send(JSON.stringify({t:'rumble',slot:0,strong:0,weak:1,phase:'refresh'}));
  b.send(JSON.stringify({t:'rumble',slot:0,strong:0,weak:0,phase:'stop'}));
  assert.equal(ws.sent.length, 1);
  assert.equal(ws.sent[0].strong, 1);
  b.send(JSON.stringify({t:'rumble',slot:0,strong:0,weak:1,phase:'start'}));
  a.send(JSON.stringify({t:'rumble',slot:0,strong:1,weak:0,phase:'refresh'}));
  assert.equal(ws.sent.length, 2);
  assert.equal(ws.sent[1].weak, 1);
  b.close();
  assert.equal(ws.sent.at(-1).strong, 0);
  assert.equal(ws.sent.at(-1).weak, 0);
  a.close();
});

test('wedged websocket is retired instead of buffering stale commands', () => {
  const f = fixture(), p = f.port(), ws = f.sockets[0]; ws.open();
  ws.bufferedAmount = 300 * 1024;
  p.send(JSON.stringify({t:'rumble',slot:1,strong:1,weak:0,phase:'start'}));
  assert.equal(ws.sent.length, 0);
  assert.equal(ws.readyState, 3);
  assert.equal(p.received.at(-1).t, 'bridge');
  assert.equal(p.received.at(-1).up, false);
  assert.equal(f.timers.size, 1);
  p.close();
});
