// Service worker owns the loopback WebSocket; content scripts keep only ports.
// Adapted from Andrei-Kondrykau's browser-bridge, with owned callbacks and
// complete replay records. Native hub must explicitly allow this extension ID.
const URL = 'ws://127.0.0.1:24810';
const RETRY_MS = 2000;
const ports = new Set();
const rumbleOwners = new Map(); // slot -> content-script port
const MAX_SOCKET_BUFFER = 256 * 1024;
let socket = null;
let retryTimer = null;
let replay = new Map(); // slot -> {connection, state}; a rename is not a connection

const fanOut = (text) => {
  for (const port of ports) { try { port.postMessage(text); } catch {} }
};

function connect() {
  retryTimer = null;
  if (socket || ports.size === 0) return;
  let owner;
  try { socket = owner = new WebSocket(URL); } catch { scheduleRetry(); return; }
  owner.onopen = () => {
    if (socket === owner) fanOut('{"t":"bridge","up":true}');
  };
  owner.onmessage = (ev) => {
    if (socket !== owner || typeof ev.data !== 'string' || ev.data.length > 65536) return;
    track(ev.data);
    fanOut(ev.data);
  };
  owner.onclose = () => {
    if (socket !== owner) return;
    socket = null;
    replay.clear();
    rumbleOwners.clear();
    fanOut('{"t":"bridge","up":false}');
    scheduleRetry();
  };
  owner.onerror = () => {}; // onclose owns failure/retry
}


function sendNative(text) {
  const owner = socket;
  if (!owner || owner.readyState !== WebSocket.OPEN) return false;
  // Do not build seconds of stale rumble/telemetry behind a wedged browser
  // socket. Closing transfers cleanup to the native client's disconnect path.
  if ((owner.bufferedAmount || 0) > MAX_SOCKET_BUFFER) {
    socket = null;
    replay.clear();
    rumbleOwners.clear();
    try { owner.close(); } catch {}
    fanOut('{"t":"bridge","up":false}');
    scheduleRetry();
    return false;
  }
  try { owner.send(text); return true; } catch {
    socket = null;
    replay.clear();
    rumbleOwners.clear();
    try { owner.close(); } catch {}
    fanOut('{"t":"bridge","up":false}');
    scheduleRetry();
    return false;
  }
}

function scheduleRetry() {
  if (retryTimer !== null || ports.size === 0) return;
  retryTimer = setTimeout(connect, RETRY_MS);
}

function track(text) {
  let m;
  try { m = JSON.parse(text); } catch { return; }
  if (!m || !Number.isInteger(m.slot) || m.slot < 0 || m.slot >= 4) return;
  if (m.t === 'connected') replay.set(m.slot, {connection:m, state:null});
  else if (m.t === 'disconnected') replay.delete(m.slot);
  else {
    const saved = replay.get(m.slot);
    if (!saved) return;
    if (m.t === 'name') saved.connection = {...saved.connection, name:m.name};
    if (m.t === 'state') saved.state = m;
  }
}

chrome.runtime.onConnect.addListener((port) => {
  if (port.name !== 'ftcw' || ports.size >= 64) return;
  ports.add(port);
  port.onMessage.addListener((text) => {
    if (!ports.has(port) || typeof text !== 'string' || text.length > 65536) return;
    let m;
    try { m = JSON.parse(text); } catch { return; }
    if (!m || !['rumble', 'stats'].includes(m.t) ||
        !Number.isInteger(m.slot) || m.slot < 0 || m.slot >= 4) return;
    if (m.t === 'rumble') {
      const strong = Number(m.strong) || 0, weak = Number(m.weak) || 0;
      const phase = m.phase || ((strong === 0 && weak === 0) ? 'stop' : 'start');
      const owner = rumbleOwners.get(m.slot);
      if (phase === 'refresh' && owner !== port) return;
      if (phase === 'stop') {
        if (owner !== port) return;
        rumbleOwners.delete(m.slot);
      } else if (phase === 'start') {
        // A new effect may preempt the previous tab, but its old refreshes
        // cannot reclaim ownership afterwards.
        rumbleOwners.set(m.slot, port);
      } else if (phase !== 'refresh') { return; }
    }
    sendNative(text);
  });
  port.onDisconnect.addListener(() => {
    ports.delete(port);
    for (const [slot, owner] of [...rumbleOwners]) {
      if (owner !== port) continue;
      rumbleOwners.delete(slot);
      sendNative(JSON.stringify({t:'rumble', slot, strong:0, weak:0, phase:'stop'}));
    }
    if (ports.size !== 0) return;
    if (retryTimer !== null) clearTimeout(retryTimer);
    retryTimer = null;
    const old = socket;
    socket = null; // retire before its asynchronous close callback can run
    replay.clear();
    rumbleOwners.clear();
    old?.close();
  });
  if (socket && socket.readyState === WebSocket.OPEN) {
    port.postMessage('{"t":"bridge","up":true}');
    for (const saved of replay.values()) {
      port.postMessage(JSON.stringify(saved.connection));
      if (saved.state) port.postMessage(JSON.stringify(saved.state));
    }
  } else {
    connect();
  }
});
