# boss-rc505

Control a Boss RC-505 Loop Station (original model, firmware 2.0) from a Mac over USB MIDI, and show what it is doing in an OBS overlay.

**Status:** working on real hardware. Control, hardware mirroring and memory switching are all tested against an RC-505.

## What it does

- **Bridge** between the looper's USB MIDI port and the browser (HTTP + WebSocket on `localhost:5055`). There are two interchangeable implementations that serve the same pages:
  - `Sources/RC505Core` — Swift, no third-party packages; run it as the `rc505` command-line tool on any platform or as `RC-505.app` on macOS. MIDI through CoreMIDI (macOS), ALSA raw MIDI (Linux) or WinMM (Windows).
  - `server.js` — the original Node.js version.
- `http://localhost:5055/` — control page: per-track rec/play/overdub and stop, all start/stop, memory select.
- `http://localhost:5055/overlay` — transparent OBS browser source in the RC-505's own colours: five track buttons with LED loop rings, an LCD-style memory/tempo readout, a beat pulse and a label on each press. Options: `?style=outline` (nothing filled, so video behind shows through), `?scale=1.5`, `?pos=top`, `?align=left|right`.
- `GET /api/press/<action>` and `/api/memory/<n>` — for a Stream Deck or scripts (`t1.recplay` … `t5.recplay`, `t1.stop` … `t5.stop`, `all`).

## How the RC-505 is driven

The RC-505 has no fixed MIDI map. Each of its 99 memories has 16 ASSIGN slots that connect a source to a target, and both directions are used:

- **Reporting (slots 4–13):** source `TR1–5 REC/DUB` → `CC#1–5` and `TR1–5 PLAY/STOP` → `CC#6–10`, so the looper sends a CC when a track starts recording, starts playing or stops, whether that came from its own buttons or from MIDI. It also sends MIDI clock, Start/Stop and a Program Change on memory select without any assigns.
- **Control (slots 14–16):** `CC#20` → `TARGET TRACK INC/DEC`, `CC#21` → `TGT TR REC/PLAY`, `CC#22` → `TGT TR STOP`. Each rising edge of CC#20 moves the target track down by one, wrapping 1 → 5; the bridge counts steps to reach the track it wants, then taps rec/play or stop. All start/stop is done track by track.
- **Memory select:** Program Change. The looper echoes it when it switches and ignores it while recording.

Slots 1–3 (the default pedal assigns) are left untouched. `tools/final-plan.json` holds this layout.

Assigns are stored in `ROLAND/DATA/MEMORY.RC0` (XML) on the looper's USB storage volume. `tools/assigns.js` rewrites chosen slots from a plan file and backs the file up first.

Numeric ids confirmed on hardware (firmware 2.0):

| Kind | Ids |
| --- | --- |
| Source | 0 EXP, 1 CTL1, 2 CTL2, 3 INPUT FX knob, 5–9 TR1–5 REC/DUB, 10–14 TR1–5 PLAY/STOP, 16–46 CC#1–31, 47–78 CC#64–95 |
| Target | 0–4 TR1–5 REC/PLAY, 5–9 TR1–5 PLAY/STOP, 10–14 TR1–5 CLEAR, 30 TGT TR REC/PLAY, 31 TGT TR STOP, 32 TGT TR CLEAR, 35 ALL START/STOP, 37 UNDO/REDO, 38 RHYTHM LEVEL, 76 TARGET TRACK INC/DEC, 79 INPUT LEVEL, 80–110 CC#1–31, 111–142 CC#64–95 |

Known limits:

- Switching between play and overdub after a track's first pass sends nothing, and a cleared track reports the same as a stopped one. The control page has a per-track menu to correct the display.
- With 13 free slots there is no room for clear, undo/redo or tap tempo from the app.
- The target track cannot be read back. The bridge remembers it in `data/state.json`; if it ever acts on the wrong track, reselect the memory (which resets it) or call `/api/target/<n>`.
- MIDI Start/Stop sent to the looper over USB had no effect in testing.

## Setup

The looper must be in `AUDIO/MIDI` USB mode (SYSTEM → USB Mode) for MIDI, and in `STORAGE` mode for the tools below. After changing the mode, replug the USB cable.

### Swift bridge

```bash
swift build -c release
.build/release/rc505
```

Run it from the project folder, or pass `--root <folder>` (the folder holding `public/` and `config.json`) and optionally `--port <n>`.

| Platform | Needs | Status |
| --- | --- | --- |
| macOS 12+ | Xcode or the Swift toolchain; Roland RC-505 USB driver | Tested with the looper |
| Linux | Swift toolchain, `libasound2-dev` | Builds and serves pages (`tools/linux-check.sh`); not yet tested with a looper attached |
| Windows | Swift toolchain (with VS Build Tools and the Windows SDK); Roland RC-505 USB driver | Builds and serves pages (Swift 6.4.2, before the bridge moved into `RC505Core`); not yet tested with a looper attached |

`./build.sh` makes a release build in `dist/` and, on macOS, signs it with the identity in `CODESIGN_IDENTITY`.

### macOS app

`./build.sh --install` also builds `dist/RC-505.app` and copies it to `/Applications`. The app bundles the web pages, `config.json` and the memory snapshot, runs the bridge, and shows the control page in a window. Closing the window leaves the bridge running so the OBS overlay keeps working; quit the app to stop it. The Overlay menu copies the overlay URLs for OBS. Its state lives in `~/Library/Application Support/RC-505`. Rebuild after `tools/snapshot.js` to pick up new memory names.

### Node bridge

```bash
npm install
npm start
```

The assign and probe tools under `tools/` are Node scripts and are needed once, to set up the looper.

## Tools

- `node tools/snapshot.js` — copy the looper's settings to `device-backup/` and build `data/memories.json` (memory names, tempo, which tracks hold audio).
- `node tools/assigns.js <plan.json> [--apply]` — dry-run or write assign slots.
- `node tools/show-assigns.js <memory>` — print a memory's assigns.
- `node tools/probe.js listen|cc|tap|pc|raw` and `tools/probe-seq.js` — low-level MIDI probing.

Not affiliated with Roland or Boss.
