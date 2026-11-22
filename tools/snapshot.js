#!/usr/bin/env node
// Reads MEMORY.RC0 / SYSTEM.RC0 (from the looper in USB storage mode, or from
// device-backup/) and writes data/memories.json: per-memory name, tempo and
// which tracks hold a phrase. Read-only with respect to the device.
const fs = require('fs');
const path = require('path');

const root = path.join(__dirname, '..');
const live = '/Volumes/BOSS_RC-505/ROLAND/DATA';
const backup = path.join(root, 'device-backup');

if (fs.existsSync(path.join(live, 'MEMORY.RC0'))) {
  fs.mkdirSync(backup, { recursive: true });
  for (const f of ['MEMORY.RC0', 'SYSTEM.RC0']) fs.copyFileSync(path.join(live, f), path.join(backup, f));
  console.log('Copied settings from the looper to device-backup/');
}

const num = (block, tag) => {
  const m = block && block.match(new RegExp(`<${tag}>(-?\\d+)</${tag}>`));
  return m ? Number(m[1]) : null;
};
const section = (block, tag) => {
  const m = block.match(new RegExp(`<${tag}>([\\s\\S]*?)</${tag}>`));
  return m ? m[1] : '';
};

const xml = fs.readFileSync(path.join(backup, 'MEMORY.RC0'), 'utf8');
const memories = [];
for (const m of xml.matchAll(/<mem id="(\d+)">([\s\S]*?)<\/mem>/g)) {
  const body = m[2];
  const name = [...section(body, 'NAME').matchAll(/<C\d+>(\d+)</g)]
    .map((c) => String.fromCharCode(Number(c[1]))).join('').trimEnd();
  const tracks = [1, 2, 3, 4, 5].map((t) => {
    const tr = section(body, `TRACK${t}`);
    const samples = num(tr, 'WavLen') || 0;
    return { hasPhrase: num(tr, 'WavStat') === 1, loopMs: Math.round(samples / 44.1) };
  });
  memories.push({
    number: Number(m[1]) + 1,
    name,
    tempo: (num(section(body, 'MASTER'), 'Tmp') || 1200) / 10,
    recAction: num(section(body, 'REC_OPTION'), 'RecAct'),
    targetTrack: (num(section(body, 'PLAY_OPTION'), 'TgtTr') ?? 0) + 1,
    tracks,
  });
}

const sys = fs.readFileSync(path.join(backup, 'SYSTEM.RC0'), 'utf8');
const midi = section(sys, 'MIDI');
const out = {
  takenAt: new Date().toISOString(),
  currentMemory: (num(section(sys, 'SETUP'), 'MemNum') ?? 0) + 1,
  midi: { rxCh: num(midi, 'RxCh'), omni: num(midi, 'Omni'), txCh: num(midi, 'TxCh'), sync: num(midi, 'Sync'), pcOut: num(midi, 'PcOut') },
  memories,
};
fs.mkdirSync(path.join(root, 'data'), { recursive: true });
fs.writeFileSync(path.join(root, 'data', 'memories.json'), JSON.stringify(out, null, 1));
console.log(`Wrote data/memories.json (${memories.length} memories, ${memories.filter((x) => x.tracks.some((t) => t.hasPhrase)).length} with audio)`);
