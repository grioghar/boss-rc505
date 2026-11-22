#!/usr/bin/env node
// Low-level MIDI probe for the looper.
//   node tools/probe.js listen [seconds]     log everything it sends (clock summarised)
//   node tools/probe.js cc <number> <value>  send a control change (channel 1)
//   node tools/probe.js tap <number>         send CC 127 then 0
//   node tools/probe.js pc <memory 1-99>     select a memory
//   node tools/probe.js raw <hex bytes...>   e.g. raw fa
const midi = require('@julusian/midi');
const [cmd, ...args] = process.argv.slice(2);
const find = (io) => { for (let i = 0; i < io.getPortCount(); i++) if (/RC-505/i.test(io.getPortName(i))) return i; return -1; };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

(async () => {
  if (cmd === 'listen') {
    const input = new midi.Input();
    const i = find(input);
    if (i < 0) { console.error('No RC-505 MIDI port.'); process.exit(1); }
    input.ignoreTypes(true, false, true);
    let ticks = 0;
    const t0 = Date.now();
    input.on('message', (_dt, m) => {
      if (m[0] === 0xf8) { ticks++; return; }
      const t = ((Date.now() - t0) / 1000).toFixed(2).padStart(7);
      const kind = m[0] >= 0xf0 ? { 0xfa: 'START', 0xfb: 'CONTINUE', 0xfc: 'STOP' }[m[0]] || 'sys'
        : { 0xb0: `CC#${m[1]} = ${m[2]}`, 0xc0: `PC ${m[1]} (memory ${m[1] + 1})` }[m[0] & 0xf0] || 'other';
      console.log(`${t}s  ${m.map((b) => b.toString(16).padStart(2, '0')).join(' ').padEnd(9)} ${kind}${m[0] < 0xf0 ? `  ch${(m[0] & 15) + 1}` : ''}`);
    });
    input.openPort(i);
    console.log(`Listening on ${input.getPortName(i)}`);
    const secs = Number(args[0]) || 30;
    await sleep(secs * 1000);
    console.log(`clock: ${ticks} ticks in ${secs}s = ${(ticks / 24 / secs * 60).toFixed(1)} BPM`);
    process.exit(0);
  }
  const out = new midi.Output();
  const o = find(out);
  if (o < 0) { console.error('No RC-505 MIDI port.'); process.exit(1); }
  out.openPort(o);
  const n = args.map(Number);
  if (cmd === 'cc') out.sendMessage([0xb0, n[0], n[1]]);
  else if (cmd === 'tap') { out.sendMessage([0xb0, n[0], 127]); await sleep(80); out.sendMessage([0xb0, n[0], 0]); }
  else if (cmd === 'pc') out.sendMessage([0xc0, n[0] - 1]);
  else if (cmd === 'raw') out.sendMessage(args.map((h) => parseInt(h, 16)));
  else { console.error('unknown command'); process.exit(2); }
  await sleep(200);
  process.exit(0);
})();
