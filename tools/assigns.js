#!/usr/bin/env node
// Rewrites ASSIGN slots in MEMORY.RC0 from a plan file.
//
//   node tools/assigns.js <plan.json>           dry run: show what would change
//   node tools/assigns.js <plan.json> --apply   back up, then write to the looper (USB storage mode)
//
// Plan: { "memories": [94] | "all", "assigns": { "4": {"src":5,"tgt":80,"min":0,"max":127,"mode":0}, ... } }
// Only the listed slots are touched; everything else in the file is preserved byte for byte.
const fs = require('fs');
const path = require('path');

const root = path.join(__dirname, '..');
const devicePath = '/Volumes/BOSS_RC-505/ROLAND/DATA/MEMORY.RC0';
const [planFile, flag] = process.argv.slice(2);
if (!planFile) { console.error('usage: assigns.js <plan.json> [--apply]'); process.exit(2); }
const plan = JSON.parse(fs.readFileSync(planFile, 'utf8'));
const apply = flag === '--apply';

const source = fs.existsSync(devicePath) ? devicePath : path.join(root, 'device-backup', 'MEMORY.RC0');
if (apply && source !== devicePath) { console.error('Looper is not mounted in USB storage mode; nothing written.'); process.exit(1); }
const original = fs.readFileSync(source, 'utf8');

const wanted = (n) => plan.memories === 'all' || plan.memories.includes(n);
let changed = 0;
const next = original.replace(/(<mem id="(\d+)">)([\s\S]*?)(<\/mem>)/g, (whole, open, id, body, close) => {
  const number = Number(id) + 1;
  if (!wanted(number)) return whole;
  for (const [slot, a] of Object.entries(plan.assigns)) {
    const re = new RegExp(`(<ASSIGN${slot}>)([\\s\\S]*?)(</ASSIGN${slot}>)`);
    const m = body.match(re);
    if (!m) throw new Error(`Memory ${number} has no ASSIGN${slot}`);
    const values = { Sw: a.sw ?? 1, Src: a.src, SrcMod: a.mode ?? 0, Tgt: a.tgt, TgtMin: a.min ?? 0, TgtMax: a.max ?? 0 };
    let block = m[2];
    for (const [tag, v] of Object.entries(values)) {
      if (!new RegExp(`<${tag}>-?\\d+</${tag}>`).test(block)) throw new Error(`ASSIGN${slot} in memory ${number} has no <${tag}>`);
      block = block.replace(new RegExp(`<${tag}>-?\\d+</${tag}>`), `<${tag}>${v}</${tag}>`);
    }
    if (block !== m[2]) changed++;
    body = body.replace(re, `$1${block}$3`);
  }
  return open + body + close;
});

const count = plan.memories === 'all' ? 99 : plan.memories.length;
console.log(`${changed} assign slot(s) would change across ${count} memory/memories (source: ${source})`);
if (original.split('\n').length !== next.split('\n').length) throw new Error('Line count changed; refusing to write.');
if (!apply) { console.log('Dry run. Add --apply to write to the looper.'); process.exit(0); }

const stamp = new Date().toISOString().replace(/[:.]/g, '-');
const backup = path.join(root, 'device-backup', `MEMORY-${stamp}.RC0`);
fs.writeFileSync(backup, original);
fs.writeFileSync(devicePath, next);
if (fs.readFileSync(devicePath, 'utf8') !== next) throw new Error('Read-back mismatch after writing!');
console.log(`Backed up the previous file to ${path.relative(root, backup)} and wrote the looper's MEMORY.RC0.`);
