// Shared by the control page and the overlay: one auto-reconnecting socket.
window.RC = (() => {
  const handlers = { state: [], press: [], beat: [], midi: [], link: [] };
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

// Ring geometry shared by both pages: a track ring with a progress arc.
window.RCRing = {
  R: 42,
  C: 2 * Math.PI * 42,
  svg: (n) => `
    <svg viewBox="0 0 100 100" class="ring">
      <circle class="ring-base" cx="50" cy="50" r="42"/>
      <circle class="ring-arc" cx="50" cy="50" r="42" transform="rotate(-90 50 50)"/>
      <text class="ring-num" x="50" y="50">${n}</text>
    </svg>`,
  // fraction of the loop elapsed, or null when it isn't meaningful
  progress(track, now) {
    if (!track.loopMs || !['play', 'overdub'].includes(track.state)) return null;
    return ((now - track.since) % track.loopMs) / track.loopMs;
  },
};
