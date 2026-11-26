// Sets REC ACTION for one memory in the looper's MEMORY.RC0 (USB storage mode).
// Usage: node tools/set-rec-action.js <memory 1-99> <dub|play>
//   dub  = Record → Overdub → Play (factory default)
//   play = Record → Play → Overdub
const fs = require('fs');
const path = require('path');

const root = path.join(__dirname, '..');
const devicePath = '/Volumes/BOSS_RC-505/ROLAND/DATA/MEMORY.RC0';
const [num, mode] = [Number(process.argv[2]), process.argv[3]];
const value = { dub: 0, play: 1 }[mode];
if (!(num >= 1 && num <= 99) || value === undefined) {
  console.error('Usage: node tools/set-rec-action.js <memory 1-99> <dub|play>');
  process.exit(1);
}
if (!fs.existsSync(devicePath)) {
  console.error('The looper is not mounted. Set USB mode to STORAGE and replug the cable.');
  process.exit(1);
}

const original = fs.readFileSync(devicePath, 'latin1');
const memRe = new RegExp(`(<mem id="${num - 1}">[\\s\\S]*?<REC_OPTION>[\\s\\S]*?<RecAct>)(\\d+)(</RecAct>)`);
const match = original.match(memRe);
if (!match) { console.error(`Could not find RecAct for memory ${num}.`); process.exit(1); }
if (Number(match[2]) === value) { console.log(`Memory ${num} already uses REC ACTION ${mode}.`); process.exit(0); }

const stamp = new Date().toISOString().replace(/[:.]/g, '-');
const backup = path.join(root, 'device-backup', `MEMORY-${stamp}.RC0`);
fs.copyFileSync(devicePath, backup);
const updated = original.replace(memRe, `$1${value}$3`);
fs.writeFileSync(devicePath, updated, 'latin1');
fs.copyFileSync(devicePath, path.join(root, 'device-backup', 'MEMORY.RC0'));

const check = fs.readFileSync(devicePath, 'latin1').match(memRe);
if (!check || Number(check[2]) !== value) { console.error('Read-back failed; restore from ' + backup); process.exit(1); }
const diff = [...original].filter((c, i) => c !== updated[i]).length;
console.log(`Memory ${num}: REC ACTION was ${match[2]}, now ${value} (${mode}). ${diff} byte(s) changed. Backup: ${path.relative(root, backup)}`);
