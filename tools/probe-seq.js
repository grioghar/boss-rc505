// Sends a timed sequence of messages while logging everything the looper sends back.
// usage: node tools/probe-seq.js "tap 1" 2000 "raw fc" 1500 ...
const midi = require('@julusian/midi');
const find = (io) => { for (let i = 0; i < io.getPortCount(); i++) if (/RC-505/i.test(io.getPortName(i))) return i; return -1; };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const input = new midi.Input(), out = new midi.Output();
const t0 = Date.now();
const stamp = () => ((Date.now() - t0) / 1000).toFixed(2).padStart(6) + 's';
const hex = (m) => m.map((b) => b.toString(16).padStart(2, '0')).join(' ');
input.ignoreTypes(true, false, true);
input.on('message', (_d, m) => {
  if (m[0] === 0xf8) return;
  const k = { 0xfa: 'START', 0xfc: 'STOP', 0xfb: 'CONTINUE' }[m[0]] || ((m[0] & 0xf0) === 0xb0 ? `CC#${m[1]}=${m[2]}` : (m[0] & 0xf0) === 0xc0 ? `PC memory ${m[1] + 1}` : '');
  console.log(`${stamp()}   <- ${hex(m).padEnd(9)} ${k}`);
});
input.openPort(find(input)); out.openPort(find(out));
(async () => {
  await sleep(300);
  for (const step of process.argv.slice(2)) {
    if (/^\d+$/.test(step)) { await sleep(Number(step)); continue; }
    const [cmd, ...a] = step.split(' ');
    console.log(`${stamp()} -> ${step}`);
    if (cmd === 'tap') { out.sendMessage([0xb0, +a[0], 127]); await sleep(80); out.sendMessage([0xb0, +a[0], 0]); }
    else if (cmd === 'cc') out.sendMessage([0xb0, +a[0], +a[1]]);
    else if (cmd === 'pc') out.sendMessage([0xc0, +a[0] - 1]);
    else if (cmd === 'raw') out.sendMessage(a.map((h) => parseInt(h, 16)));
  }
  process.exit(0);
})();
