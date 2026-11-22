# boss-rc505

Control a Boss RC-505 Loop Station (original model, firmware 2.0) from a Mac over USB MIDI, and show what it is doing in an OBS overlay.

**Status: work in progress.** MIDI control and status reporting are proven on real hardware; the final per-memory assign layout is still being worked out.

## What it does

- `server.js` — bridge between the looper's USB MIDI port and the browser (HTTP + WebSocket on `localhost:5055`).
- `http://localhost:5055/` — control page: track rec/play/stop/clear, all start/stop, undo/redo, tap tempo, memory select.
- `http://localhost:5055/overlay` — transparent OBS browser source: five track rings with loop progress, memory name, tempo, beat pulse and a flash on each press. Options: `?scale=1.5`, `?pos=top`, `?align=left|right`.
- `GET /api/press/<action>` and `/api/memory/<n>` — for a Stream Deck or scripts (actions are listed in `config.json`).

## How the RC-505 is driven

The RC-505 has no fixed MIDI map. Each of its 99 memories has 16 ASSIGN slots that connect a source to a target, and both directions are used:

- **Control:** source `CC#n` → target such as `TR3 REC/PLAY` or `ALL START/STOP`.
- **Reporting:** source `TR1–5 REC/DUB` or `TR1–5 PLAY/STOP` → target `CC#n`, so the looper sends a CC when a track starts recording, starts playing or stops. It also sends MIDI clock, Start/Stop and a Program Change on memory select without any assigns.

Assigns are stored in `ROLAND/DATA/MEMORY.RC0` (XML) on the looper's USB storage volume. `tools/assigns.js` rewrites chosen slots from a plan file and backs the file up first.

Numeric ids confirmed on hardware (firmware 2.0):

| Kind | Ids |
| --- | --- |
| Source | 0 EXP, 1 CTL1, 2 CTL2, 3 INPUT FX knob, 5–9 TR1–5 REC/DUB, 10–14 TR1–5 PLAY/STOP, 16–46 CC#1–31, 47–78 CC#64–95 |
| Target | 0–4 TR1–5 REC/PLAY, 5–9 TR1–5 PLAY/STOP, 10–14 TR1–5 CLEAR, 30 TGT TR REC/PLAY, 31 TGT TR STOP, 35 ALL START/STOP, 37 UNDO/REDO, 38 RHYTHM LEVEL, 79 INPUT LEVEL, 80–110 CC#1–31, 111–142 CC#64–95 |

Known limits of the looper's reporting: switching between play and overdub after a track's first pass sends nothing, and a cleared track reports the same as a stopped one.

## Setup

Requires macOS with the Roland RC-505 USB driver, and Node.js.

```bash
npm install
npm start
```

The looper must be in `AUDIO/MIDI` USB mode (SYSTEM → USB Mode) for MIDI, and in `STORAGE` mode for the tools below.

## Tools

- `node tools/snapshot.js` — copy the looper's settings to `device-backup/` and build `data/memories.json` (memory names, tempo, which tracks hold audio).
- `node tools/assigns.js <plan.json> [--apply]` — dry-run or write assign slots.
- `node tools/probe.js listen|cc|tap|pc|raw` and `tools/probe-seq.js` — low-level MIDI probing.

Not affiliated with Roland or Boss.
