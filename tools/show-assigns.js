#!/usr/bin/env node
// Print one memory's assigns from the looper (storage mode) or the local backup.
//   node tools/show-assigns.js <memory 1-99>
const fs = require('fs');
const live = '/Volumes/BOSS_RC-505/ROLAND/DATA/MEMORY.RC0';
const file = fs.existsSync(live) ? live : require('path').join(__dirname, '..', 'device-backup', 'MEMORY.RC0');
const n = Number(process.argv[2] || 1);
const mem = fs.readFileSync(file, 'utf8').match(new RegExp(`<mem id="${n - 1}">([\\s\\S]*?)</mem>`))[1];
console.log(`memory ${n} from ${file}`);
for (const a of mem.match(/<ASSIGN\d+>[\s\S]*?<\/ASSIGN\d+>/g)) {
  const slot = a.match(/<ASSIGN(\d+)>/)[1];
  const v = Object.fromEntries([...a.matchAll(/<(\w+)>(-?\d+)</g)].map((m) => [m[1], m[2]]));
  console.log(`  ${slot.padStart(2)}: sw=${v.Sw} src=${v.Src} mode=${v.SrcMod} tgt=${v.Tgt} min=${v.TgtMin} max=${v.TgtMax}`);
}
console.log(' ', mem.match(/<PLAY_OPTION>[\s\S]*?<\/PLAY_OPTION>/)[0].replace(/\s+/g, ''));
console.log('  tracks with audio:', [1, 2, 3, 4, 5].filter((t) => /<WavStat>1</.test(mem.match(new RegExp(`<TRACK${t}>([\\s\\S]*?)</TRACK${t}>`))[1])).join(',') || 'none');
