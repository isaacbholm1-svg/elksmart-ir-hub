// Plays an IR signal through the headphone/USB-C audio output for audio-type
// IR blasters. Those dongles wire two IR LEDs in opposite directions across the
// left and right channels, so a sine at HALF the carrier on L and its inverse
// on R lights an LED on every half-cycle: 19 kHz audio -> 38 kHz infrared.
const IRAudio = (() => {
  let ctx = null;
  let playing = null;

  function context() {
    if (!ctx) {
      // iOS: "playback" keeps sound on even when the silent switch is on.
      try { if (navigator.audioSession) navigator.audioSession.type = 'playback'; } catch { /* not supported */ }
      const AC = window.AudioContext || window.webkitAudioContext;
      // 48 kHz is what iPhones run at; 19 kHz needs at least 44.1 kHz.
      try { ctx = new AC({ sampleRate: 48000 }); } catch { ctx = new AC(); }
    }
    if (ctx.state === 'suspended') ctx.resume();
    return ctx;
  }

  // settings: { mode: 'half' | 'full', repeats: n, invert: bool }
  function buildBuffer(sig, settings) {
    const ac = context();
    const rate = ac.sampleRate;
    const toneHz = settings.mode === 'full' ? sig.freq : sig.freq / 2;
    if (toneHz >= rate / 2) throw new Error(`Output is ${rate} Hz; it can't play a ${toneHz / 1000} kHz tone. Use the half-carrier mode.`);

    const frame = sig.timings;
    const frameSamples = frame.reduce((n, us) => n + Math.round((us * rate) / 1e6), 0);
    const lead = Math.round(rate * 0.02); // short silence so the output is awake
    const total = lead + frameSamples * settings.repeats;
    const buf = ac.createBuffer(2, total, rate);
    const L = buf.getChannelData(0);
    const R = buf.getChannelData(1);
    const w = (2 * Math.PI * toneHz) / rate;
    const sign = settings.invert ? -1 : 1;

    let pos = lead;
    for (let r = 0; r < settings.repeats; r++) {
      frame.forEach((us, i) => {
        const n = Math.round((us * rate) / 1e6);
        if (i % 2 === 0) {
          for (let k = 0; k < n; k++) {
            const v = Math.sin(w * (pos + k)) * sign;
            L[pos + k] = v;
            R[pos + k] = -v;
          }
        }
        pos += n;
      });
    }
    return buf;
  }

  function blast(sig, settings) {
    const ac = context();
    const buf = buildBuffer(sig, settings);
    if (playing) try { playing.stop(); } catch { /* already stopped */ }
    const src = ac.createBufferSource();
    src.buffer = buf;
    src.connect(ac.destination);
    src.start();
    playing = src;
    return { toneHz: settings.mode === 'full' ? sig.freq : sig.freq / 2, sampleRate: ac.sampleRate };
  }

  return { blast, buildBuffer };
})();
