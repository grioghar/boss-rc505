#!/usr/bin/env node
// RC-505 bridge: talks MIDI to the looper over USB, keeps a model of what the
// looper is doing, and serves the control page and the OBS overlay.
const fs = require('fs');
const http = require('http');
const path = require('path');
const midi = require('@julusian/midi');
const { WebSocketServer } = require('ws');

const root = __dirname;
const config = JSON.parse(fs.readFileSync(path.join(root, 'config.json'), 'utf8'));
const snapshotPath = path.join(root, 'data', 'memories.json');
const snapshot = fs.existsSync(snapshotPath) ? JSON.parse(fs.readFileSync(snapshotPath, 'utf8')) : null;
const chan = (config.midiChannel || 1) - 1;

// ---------- state ----------
const state = {
  connected: false,
  portName: null,
  memory: { number: snapshot?.currentMemory || 1, name: '' },
  tempo: null,          // from the looper's MIDI clock when it sends one
  clockRunning: false,
  tracks: [],
  actions: Object.fromEntries(Object.entries(config.actions).map(([id, a]) => [id, a.label])),
};

function loadMemory(number) {
  const mem = snapshot?.memories.find((m) => m.number === number);
  state.memory = { number, name: mem?.name || '' };
  state.snapshotTempo = mem?.tempo || null;
  state.recAction = mem?.recAction ?? 0; // 0: REC -> OVERDUB, 1: REC -> PLAY
  state.tracks = [0, 1, 2, 3, 4].map((i) => {
    const t = mem?.tracks[i];
    return { state: t?.hasPhrase ? 'stop' : 'empty', loopMs: t?.loopMs || 0, since: Date.now() };
  });
}
loadMemory(state.memory.number);

// ---------- clients ----------
const clients = new Set();
const send = (msg) => { const s = JSON.stringify(msg); for (const c of clients) if (c.readyState === 1) c.send(s); };
const pushState = () => send({ type: 'state', state, now: Date.now() });

// ---------- track model ----------
function setTrack(i, next, extra = {}) {
  Object.assign(state.tracks[i], { state: next, since: Date.now() }, extra);
}
function recPlay(i) {
  const t = state.tracks[i];
  const now = Date.now();
  if (t.state === 'empty') setTrack(i, 'rec', { loopMs: 0 });
  else if (t.state === 'rec') setTrack(i, state.recAction === 1 ? 'play' : 'overdub', { loopMs: now - t.since });
  else if (t.state === 'play') setTrack(i, 'overdub', { since: t.since });
  else if (t.state === 'overdub') setTrack(i, 'play', { since: t.since });
  else if (t.state === 'stop') setTrack(i, 'play');
}
function stopTrack(i) {
  const t = state.tracks[i];
  if (t.state === 'rec') setTrack(i, 'stop', { loopMs: Date.now() - t.since });
  else if (t.state === 'play' || t.state === 'overdub') setTrack(i, 'stop');
}
function allStartStop(force) {
  const anyRunning = state.tracks.some((t) => ['rec', 'play', 'overdub'].includes(t.state));
  const stop = force ? force === 'stop' : anyRunning;
  state.tracks.forEach((t, i) => {
    if (stop) stopTrack(i);
    else if (t.state === 'stop') setTrack(i, 'play');
  });
}
function applyAction(id) {
  const m = id.match(/^t([1-5])\.(recplay|stop|clear)$/);
  if (m) {
    const i = Number(m[1]) - 1;
    if (m[2] === 'recplay') recPlay(i);
    else if (m[2] === 'stop') stopTrack(i);
    else setTrack(i, 'empty', { loopMs: 0 });
  } else if (id === 'all') allStartStop();
}

// ---------- MIDI ----------
let input = null;
let output = null;
const findPort = (io) => {
  const re = new RegExp(config.midiPortMatch, 'i');
  for (let i = 0; i < io.getPortCount(); i++) if (re.test(io.getPortName(i))) return i;
  return -1;
};
function closeMidi() {
  try { input?.closePort(); } catch {}
  try { output?.closePort(); } catch {}
  input = output = null;
  if (state.connected) { state.connected = false; state.portName = null; state.clockRunning = false; pushState(); console.log('Looper disconnected'); }
}
function scanMidi() {
  const probeIn = new midi.Input();
  const probeOut = new midi.Output();
  const i = findPort(probeIn);
  const o = findPort(probeOut);
  if (state.connected) {
    if (i < 0 || o < 0) closeMidi();
    probeIn.destroy?.(); probeOut.destroy?.();
    return;
  }
  if (i < 0 || o < 0) { probeIn.destroy?.(); probeOut.destroy?.(); return; }
  input = probeIn; output = probeOut;
  state.portName = input.getPortName(i);
  input.ignoreTypes(true, false, true); // keep clock/start/stop, drop sysex and active sensing
  input.on('message', (_dt, msg) => onMidi(msg));
  input.openPort(i);
  output.openPort(o);
  state.connected = true;
  console.log(`Looper connected: ${state.portName}`);
  pushState();
}

let lastTick = 0;
let tickCount = 0;
const intervals = [];
function onMidi(msg) {
  const [status, d1, d2] = msg;
  if (status === 0xf8) return onClock();
  if (status === 0xfa || status === 0xfb) { // start / continue
    tickCount = 0; state.clockRunning = true;
    allStartStop('start');
    send({ type: 'press', id: 'all', source: 'device', label: 'All Start' });
    return pushState();
  }
  if (status === 0xfc) {
    state.clockRunning = false;
    allStartStop('stop');
    send({ type: 'press', id: 'all', source: 'device', label: 'All Stop' });
    return pushState();
  }
  const kind = status & 0xf0;
  if (kind === 0xc0) { // program change = memory select on the looper
    loadMemory(d1 + 1);
    send({ type: 'press', id: 'memory', source: 'device', label: `Memory ${d1 + 1}` });
    return pushState();
  }
  if (kind === 0xb0) send({ type: 'midi', cc: d1, value: d2, channel: (status & 0x0f) + 1 });
  if (process.env.MIDI_LOG) console.log('in ', msg.map((b) => b.toString(16).padStart(2, '0')).join(' '));
}
function onClock() {
  const now = performance.now();
  if (lastTick) {
    intervals.push(now - lastTick);
    if (intervals.length > 48) intervals.shift();
  }
  lastTick = now;
  if (tickCount % 24 === 0) {
    if (intervals.length >= 24) {
      const avg = intervals.reduce((a, b) => a + b, 0) / intervals.length;
      const bpm = Math.round((60000 / (avg * 24)) * 10) / 10;
      if (bpm !== state.tempo) { state.tempo = bpm; pushState(); }
    }
    send({ type: 'beat', n: Math.floor(tickCount / 24) % 4 });
  }
  tickCount++;
}
setInterval(() => { // clock went quiet
  if (state.tempo !== null && performance.now() - lastTick > 2000) { state.tempo = null; intervals.length = 0; pushState(); }
}, 1000);

const sendMidi = (bytes) => {
  if (process.env.MIDI_LOG) console.log('out', bytes.map((b) => b.toString(16).padStart(2, '0')).join(' '));
  if (output) try { output.sendMessage(bytes); } catch (e) { console.error('MIDI send failed:', e.message); closeMidi(); }
};
const sendCC = (cc, value) => sendMidi([0xb0 | chan, cc, value]);

// press: a tap (CC 127 then 0). Holding the stop CC clears the track, like holding the button.
function press(id, source = 'app') {
  const clear = id.match(/^t([1-5])\.clear$/);
  const action = config.actions[clear ? `t${clear[1]}.stop` : id];
  if (!action) return false;
  sendCC(action.cc, 127);
  setTimeout(() => sendCC(action.cc, 0), clear ? config.clearHoldMs : config.tapMs);
  applyAction(id);
  send({ type: 'press', id, source, label: clear ? `Track ${clear[1]} Clear` : action.label });
  pushState();
  return true;
}
function selectMemory(number, source = 'app') {
  if (!(number >= 1 && number <= 99)) return false;
  sendMidi([0xc0 | chan, number - 1]);
  loadMemory(number);
  send({ type: 'press', id: 'memory', source, label: `Memory ${number}` });
  pushState();
  return true;
}
// Correct the model by hand when it has drifted from the real looper.
function setTrackState(i, next) {
  if (!state.tracks[i] || !['empty', 'stop', 'play', 'rec', 'overdub'].includes(next)) return false;
  setTrack(i, next);
  pushState();
  return true;
}

// ---------- HTTP + WebSocket ----------
const types = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.json': 'application/json', '.svg': 'image/svg+xml' };
const server = http.createServer((req, res) => {
  const url = new URL(req.url, 'http://localhost');
  const json = (code, body) => { res.writeHead(code, { 'content-type': 'application/json' }); res.end(JSON.stringify(body)); };
  // Simple GET/POST endpoints so a Stream Deck or script can trigger actions.
  let m;
  if ((m = url.pathname.match(/^\/api\/press\/([\w.]+)$/))) return json(press(m[1], 'api') ? 200 : 404, { ok: !!config.actions[m[1]] || /clear$/.test(m[1]) });
  if ((m = url.pathname.match(/^\/api\/memory\/(\d+)$/))) return json(selectMemory(Number(m[1]), 'api') ? 200 : 400, { ok: true });
  if (url.pathname === '/api/state') return json(200, state);
  if (url.pathname === '/memories.json') return json(200, (snapshot?.memories || []).map((x) => ({ number: x.number, name: x.name })));
  const file = { '/': 'control.html', '/overlay': 'overlay.html' }[url.pathname] || url.pathname.slice(1);
  const full = path.join(root, 'public', path.normalize(file));
  if (!full.startsWith(path.join(root, 'public')) || !fs.existsSync(full) || fs.statSync(full).isDirectory()) { res.writeHead(404); return res.end('Not found'); }
  res.writeHead(200, { 'content-type': types[path.extname(full)] || 'application/octet-stream', 'cache-control': 'no-store' });
  fs.createReadStream(full).pipe(res);
});
const wss = new WebSocketServer({ server });
wss.on('connection', (ws) => {
  clients.add(ws);
  ws.send(JSON.stringify({ type: 'state', state, now: Date.now() }));
  ws.on('close', () => clients.delete(ws));
  ws.on('message', (raw) => {
    let msg; try { msg = JSON.parse(raw); } catch { return; }
    if (msg.type === 'press') press(String(msg.id));
    else if (msg.type === 'memory') selectMemory(Number(msg.number));
    else if (msg.type === 'setTrack') setTrackState(Number(msg.track), msg.state);
  });
});

server.listen(config.httpPort, '127.0.0.1', () => {
  console.log(`Control page: http://localhost:${config.httpPort}/`);
  console.log(`OBS overlay:  http://localhost:${config.httpPort}/overlay`);
  scanMidi();
  if (!state.connected) console.log(`Waiting for a MIDI port matching "${config.midiPortMatch}" (the looper must not be in USB storage mode)`);
  setInterval(scanMidi, 3000);
});
