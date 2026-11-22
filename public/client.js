// Shared by the control page and the overlay: one auto-reconnecting socket.
window.RC = (() => {
  const handlers = { state: [], press: [], beat: [], notice: [], link: [] };
  let ws;
  let offset = 0; // server clock minus local clock
  const emit = (type, payload) => handlers[type]?.forEach((fn) => fn(payload));
  function connect() {
    ws = new WebSocket(`ws://${location.host}`);
    ws.onopen = () => emit('link', true);
    ws.onclose = () => { emit('link', false); setTimeout(connect, 1000); };
    ws.onmessage = (e) => {
      const msg = JSON.parse(e.data);
      if (msg.type === 'state') { offset = msg.now - Date.now(); emit('state', msg.state); } else emit(msg.type, msg);
    };
  }
  connect();
  return {
    on: (type, fn) => handlers[type].push(fn),
    send: (msg) => ws?.readyState === 1 && ws.send(JSON.stringify(msg)),
    press: (id) => RC.send({ type: 'press', id }),
    serverNow: () => Date.now() + offset,
  };
})();

// Track ring drawn like the RC-505's: a segmented red LED loop indicator around a
// centre button that lights green (play), red (rec) or amber (overdub).
window.RCRing = {
  C: 2 * Math.PI * 42,
  svg: (n) => `
    <svg viewBox="0 0 100 100" class="ring">
      <defs><mask id="ring-mask-${n}" maskUnits="userSpaceOnUse" x="0" y="0" width="100" height="100">
        <circle class="ring-arc" cx="50" cy="50" r="42" transform="rotate(-90 50 50)"/>
      </mask></defs>
      <circle class="ring-body" cx="50" cy="50" r="49"/>
      <circle class="ring-leds ring-leds-off" cx="50" cy="50" r="42" transform="rotate(-90 50 50)"/>
      <circle class="ring-leds ring-leds-on" cx="50" cy="50" r="42" transform="rotate(-90 50 50)" mask="url(#ring-mask-${n})"/>
      <circle class="ring-button" cx="50" cy="50" r="29"/>
      <path class="ring-glyph" d="M36 42 l11 8 -11 8z M50 60 l8 -20 M65 50 m-5 0 a5 5 0 1 0 10 0 a5 5 0 1 0 -10 0"/>
    </svg>`,
  // fraction of the loop elapsed, or null when it isn't meaningful
  progress(track, now) {
    if (!track.loopMs || !['play', 'overdub'].includes(track.state)) return null;
    return ((now - track.since) % track.loopMs) / track.loopMs;
  },
};
