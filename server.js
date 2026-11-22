#!/usr/bin/env node
// RC-505 bridge: talks MIDI to the looper over USB, keeps a model of what the
// looper is doing, and serves the control page and the OBS overlay.
//
// The looper is set up (tools/assigns.js + tools/final-plan.json) so that:
//   - it reports each track's rec/dub and play/stop as CCs (config.report)
//   - three CCs control it: step the "target track", rec/play it, stop it (config.control)
const fs = require('fs');
const http = require('http');
const path = require('path');
const midi = require('@julusian/midi');
const { WebSocketServer } = require('ws');

const root = __dirname;
const config = JSON.parse(fs.readFileSync(path.join(root, 'config.json'), 'utf8'));
const readJson = (p) => (fs.existsSync(p) ? JSON.parse(fs.readFileSync(p, 'utf8')) : null);
const snapshot = readJson(path.join(root, 'data', 'memories.json'));
const savedPath = path.join(root, 'data', 'state.json');
const saved = readJson(savedPath);
const chan = (config.midiChannel || 1) - 1;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const RUNNING = ['rec', 'play', 'overdub'];

// ---------- state ----------
const state = {
  connected: false,
  portName: null,
  memory: { number: 1, name: '' },
  tempo: null,        // from the looper's MIDI clock
  snapshotTempo: null,
  tracks: [],
};
// What the looper itself last reported per track, and which track its rec/play and stop CCs act on.
let flags = [];
let targetTrack = 1;
let recAction = 0; // 0: REC -> OVERDUB, 1: REC -> PLAY

function loadMemory(number, keepTarget) {
  const mem = snapshot?.memories.find((m) => m.number === number);
  state.memory = { number, name: mem?.name || '' };
  state.snapshotTempo = mem?.tempo || null;
  recAction = mem?.recAction ?? 0;
  if (!keepTarget) targetTrack = mem?.targetTrack || 1;
  flags = [0, 1, 2, 3, 4].map(() => ({ rec: false, play: false }));
  state.tracks = [0, 1, 2, 3, 4].map((i) => {
    const t = mem?.tracks[i];
    return { state: t?.hasPhrase ? 'stop' : 'empty', loopMs: t?.loopMs || 0, since: Date.now() };
  });
  persist();
}
function persist() {
  try { fs.mkdirSync(path.dirname(savedPath), { recursive: true }); fs.writeFileSync(savedPath, JSON.stringify({ memory: state.memory.number, targetTrack })); } catch {}
}
// Resume on the memory and target track we last knew about; the looper cannot be asked for either.
if (saved?.memory) { targetTrack = saved.targetTrack || 1; loadMemory(saved.memory, true); } else loadMemory(snapshot?.currentMemory || 1);

// ---------- clients ----------
const clients = new Set();
const send = (msg) => { const s = JSON.stringify(msg); for (const c of clients) if (c.readyState === 1) c.send(s); };
const pushState = () => send({ type: 'state', state, now: Date.now() });
const lastAppPress = [0, 0, 0, 0, 0];
function announce(id, label, source) { send({ type: 'press', id, label, source }); }

// ---------- track model ----------
function setTrack(i, next, extra = {}) {
  Object.assign(state.tracks[i], { state: next, since: Date.now() }, extra);
}
// What a press of rec/play should do. The looper does not report rec -> overdub or
// play <-> overdub, so presses made from the app are predicted here.
function predictRecPlay(i) {
  const t = state.tracks[i];
  const now = Date.now();
  if (t.state === 'empty') setTrack(i, 'rec', { loopMs: 0 });
  else if (t.state === 'rec') setTrack(i, recAction === 1 ? 'play' : 'overdub', { loopMs: now - t.since });
  else if (t.state === 'play') setTrack(i, 'overdub', { since: t.since });
  else if (t.state === 'overdub') setTrack(i, 'play', { since: t.since });
  else if (t.state === 'stop') setTrack(i, 'play');
}
function predictStop(i) {
  const t = state.tracks[i];
  if (t.state === 'rec') setTrack(i, 'stop', { loopMs: Date.now() - t.since });
  else if (RUNNING.includes(t.state)) setTrack(i, 'stop');
}
// A status report from the looper: the truth, applied over any prediction.
function onReport(kind, i, on) {
  const t = state.tracks[i];
  const f = flags[i];
  const before = t.state;
  f[kind] = on;
  if (kind === 'rec' && on) {
    if (f.play) { if (t.state !== 'overdub') setTrack(i, 'overdub', { since: t.since }); }
    else if (!['rec', 'overdub'].includes(t.state)) setTrack(i, 'rec', { loopMs: 0 });
  } else if (kind === 'play' && on) {
    if (t.state === 'rec' && f.rec) setTrack(i, 'play', { loopMs: Date.now() - t.since }); // a real first pass just ended
    else if (t.state === 'overdub') setTrack(i, 'play', { since: t.since });
    else if (t.state !== 'play') setTrack(i, 'play');
  } else if (!on && !f.rec && !f.play) {
    if (t.state === 'rec') setTrack(i, 'stop', { loopMs: Date.now() - t.since });
    else if (RUNNING.includes(t.state)) setTrack(i, 'stop');
  }
  // Show it as a hardware press unless the app just pressed this track itself.
  if (t.state !== before && Date.now() - lastAppPress[i] > 1500) {
    const label = { rec: 'Rec', play: 'Play', overdub: 'Overdub', stop: 'Stop' }[t.state];
    announce(`t${i + 1}.${t.state === 'stop' ? 'stop' : 'recplay'}`, `Track ${i + 1} ${label}`, 'device');
  }
  pushState();
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
  if (state.connected) { state.connected = false; state.portName = null; state.tempo = null; pushState(); console.log('Looper disconnected'); }
}
function scanMidi() {
  const probeIn = new midi.Input();
  const probeOut = new midi.Output();
  const i = findPort(probeIn);
  const o = findPort(probeOut);
  if (state.connected || i < 0 || o < 0) {
    if (state.connected && (i < 0 || o < 0)) closeMidi();
    probeIn.destroy?.(); probeOut.destroy?.();
    return;
  }
  input = probeIn; output = probeOut;
  state.portName = input.getPortName(i);
  input.ignoreTypes(true, false, true); // keep clock/start/stop, drop sysex and active sensing
  input.on('message', (dt, msg) => onMidi(msg, dt));
  input.openPort(i);
  output.openPort(o);
  state.connected = true;
  console.log(`Looper connected: ${state.portName}`);
  pushState();
}

let lastMemoryRequest = 0;
let lastTick = 0;
let sinceTick = 0; // ms since the previous clock tick, by the MIDI driver's timestamps
let tickCount = 0;
const intervals = [];
function onMidi(msg, dt) {
  const [status, d1, d2] = msg;
  sinceTick += dt * 1000;
  if (status === 0xf8) return onClock();
  if (process.env.MIDI_LOG) console.log('in ', msg.map((b) => b.toString(16).padStart(2, '0')).join(' '));
  if (status === 0xfa || status === 0xfb) { tickCount = 0; return; } // loop start: re-align the beat counter
  if (status === 0xfc) return;
  const kind = status & 0xf0;
  if (kind === 0xc0) { // the looper switched memory
    loadMemory(d1 + 1);
    announce('memory', `Memory ${d1 + 1}`, Date.now() - lastMemoryRequest < 1500 ? 'app' : 'device');
    return pushState();
  }
  if (kind === 0xb0) {
    const r = config.report.rec.indexOf(d1);
    const p = config.report.play.indexOf(d1);
    if (r >= 0) onReport('rec', r, d2 >= 64);
    else if (p >= 0) onReport('play', p, d2 >= 64);
  }
}
function onClock() {
  if (lastTick && sinceTick < 500) {
    intervals.push(sinceTick);
    if (intervals.length > 96) intervals.shift();
  }
  sinceTick = 0;
  lastTick = performance.now();
  if (tickCount % 24 === 0) {
    if (intervals.length >= 24) {
      const avg = intervals.reduce((a, b) => a + b, 0) / intervals.length;
      const bpm = Math.round((60000 / (avg * 24)) * 10) / 10;
      if (state.tempo === null || Math.abs(bpm - state.tempo) >= 0.3) { state.tempo = bpm; pushState(); }
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
// Everything sent to the looper goes through one queue so multi-message actions never interleave.
let queue = Promise.resolve();
const enqueue = (fn) => (queue = queue.then(fn).catch((e) => console.error(e)));
async function tap(cc) {
  sendMidi([0xb0 | chan, cc, 127]);
  await sleep(config.gapMs);
  sendMidi([0xb0 | chan, cc, 0]);
  await sleep(config.gapMs);
}
// Each tap of the step CC moves the looper's target track down by one, wrapping 1 -> 5.
async function selectTrack(i) {
  const want = i + 1;
  while (targetTrack !== want) {
    await tap(config.control.targetStep);
    targetTrack = targetTrack === 1 ? 5 : targetTrack - 1;
  }
  persist();
}
async function trackAction(i, what) {
  lastAppPress[i] = Date.now();
  await selectTrack(i);
  // Predict first: the looper's own report arrives within milliseconds and must win.
  if (what === 'stop') predictStop(i); else predictRecPlay(i);
  pushState();
  await tap(what === 'stop' ? config.control.stop : config.control.recPlay);
}

function press(id, source = 'app') {
  const m = id.match(/^t([1-5])\.(recplay|stop)$/);
  if (m) {
    const i = Number(m[1]) - 1;
    announce(id, `Track ${m[1]} ${m[2] === 'stop' ? 'Stop' : 'Rec/Play'}`, source);
    enqueue(() => trackAction(i, m[2]));
    return true;
  }
  if (id === 'all') { // no spare assign slot for ALL START/STOP, so do it track by track
    const stopping = state.tracks.some((t) => RUNNING.includes(t.state));
    announce(id, stopping ? 'All Stop' : 'All Start', source);
    state.tracks.forEach((t, i) => {
      if (stopping ? RUNNING.includes(t.state) : t.state === 'stop') enqueue(() => trackAction(i, stopping ? 'stop' : 'recplay'));
    });
    return true;
  }
  return false;
}
function selectMemory(number, source = 'app') {
  if (!(number >= 1 && number <= 99)) return false;
  // The looper echoes the program change when it really switches (it refuses while a track
  // is running), so the model only changes when that echo arrives in onMidi.
  enqueue(async () => {
    lastMemoryRequest = Date.now();
    sendMidi([0xc0 | chan, number - 1]);
    await sleep(1500);
    if (state.memory.number !== number) send({ type: 'notice', text: `The looper did not switch to memory ${number}. Stop all tracks first.` });
  });
  return true;
}
// Manual corrections for when the model has drifted from the real looper.
function setTrackState(i, next) {
  if (!state.tracks[i] || !['empty', 'stop', 'play', 'rec', 'overdub'].includes(next)) return false;
  setTrack(i, next);
  pushState();
  return true;
}
function setTargetTrack(n) {
  if (!(n >= 1 && n <= 5)) return false;
  targetTrack = n;
  persist();
  return true;
}

// ---------- HTTP + WebSocket ----------
const types = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.json': 'application/json', '.svg': 'image/svg+xml' };
const server = http.createServer((req, res) => {
  const url = new URL(req.url, 'http://localhost');
  const json = (code, body) => { res.writeHead(code, { 'content-type': 'application/json' }); res.end(JSON.stringify(body)); };
  // Simple endpoints so a Stream Deck or script can trigger actions.
  let m;
  if ((m = url.pathname.match(/^\/api\/press\/([\w.]+)$/))) { const ok = press(m[1], 'api'); return json(ok ? 200 : 404, { ok }); }
  if ((m = url.pathname.match(/^\/api\/memory\/(\d+)$/))) { const ok = selectMemory(Number(m[1]), 'api'); return json(ok ? 200 : 400, { ok }); }
  if ((m = url.pathname.match(/^\/api\/target\/([1-5])$/))) return json(200, { ok: setTargetTrack(Number(m[1])) });
  if (url.pathname === '/api/state') return json(200, { ...state, targetTrack });
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
