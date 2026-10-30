// Turns IRDB (protocol, device, subdevice, function) into raw timings.
// Each encoder returns { freq, timings } where timings are alternating
// mark/space durations in microseconds, starting with a mark.
const IR = (() => {
  const bitsLSB = (value, count) => {
    const out = [];
    for (let i = 0; i < count; i++) out.push((value >> i) & 1);
    return out;
  };
  const bitsMSB = (value, count) => bitsLSB(value, count).reverse();
  const inv = (v) => (~v) & 0xff;

  // Pulse-distance protocols: every bit is a mark followed by a 0- or 1-space.
  function pulseDistance(unit, lead, zero, one, bits, trail) {
    // Negative numbers mark spaces in the IRP notation; durations are positive.
    const t = lead.map((x) => Math.abs(x) * unit);
    for (const b of bits) (b ? one : zero).forEach((x) => t.push(Math.abs(x) * unit));
    trail.forEach((x) => t.push(Math.abs(x) * unit));
    return t;
  }

  // Bi-phase (Manchester) protocols. half = half-bit length in µs.
  // level pairs: for each bit, [first, second] where 1 = mark, 0 = space.
  function biphase(segments) {
    const t = [];
    let level = null;
    for (const [isMark, dur] of segments) {
      if (!t.length && !isMark) continue; // signal must start with a mark
      if (level === isMark && t.length) t[t.length - 1] += dur;
      else { t.push(dur); level = isMark; }
    }
    if (!level) t.pop(); // drop trailing space; caller adds the gap
    return t;
  }

  function nec(D, S, F, lead) {
    if (S < 0) S = inv(D);
    const bits = [...bitsLSB(D, 8), ...bitsLSB(S, 8), ...bitsLSB(F, 8), ...bitsLSB(inv(F), 8)];
    const t = pulseDistance(564, lead, [1, -1], [1, -3], bits, [1]);
    return { freq: 38000, timings: finish(t, 108000) };
  }

  function sony(D, S, F, dBits, sBits = 0) {
    const bits = [...bitsLSB(F, 7), ...bitsLSB(D, dBits), ...bitsLSB(Math.max(S, 0), sBits)];
    const t = pulseDistance(600, [4, -1], [1, -1], [2, -1], bits, []);
    t.pop(); // last space becomes the frame gap
    return { freq: 40000, timings: finish(t, 45000) };
  }

  function rc5(D, F) {
    const bits = [1, ((~F) >> 6) & 1, 0, ...bitsMSB(D, 5), ...bitsMSB(F & 63, 6)];
    const segs = [];
    for (const b of bits) segs.push(b ? [false, 889] : [true, 889], b ? [true, 889] : [false, 889]);
    const t = biphase(segs);
    return { freq: 36000, timings: finish(t, 114000) };
  }

  function rc6(D, F) {
    const u = 444;
    const segs = [[true, 6 * u], [false, 2 * u]];
    const push = (b, w) => segs.push(b ? [true, w * u] : [false, w * u], b ? [false, w * u] : [true, w * u]);
    push(1, 1);
    [0, 0, 0].forEach((b) => push(b, 1));
    push(0, 2); // toggle bit, double width
    bitsMSB(D, 8).forEach((b) => push(b, 1));
    bitsMSB(F, 8).forEach((b) => push(b, 1));
    const t = biphase(segs);
    return { freq: 36000, timings: finish(t, 107000) };
  }

  function jvc(D, F) {
    const bits = [...bitsLSB(D, 8), ...bitsLSB(F, 8)];
    const t = pulseDistance(527, [16, -8], [1, -1], [1, -3], bits, [1]);
    return { freq: 38000, timings: finish(t, 60000) };
  }

  function kaseikyo(D, S, F) {
    if (S < 0) S = 0;
    const check = (D ^ S ^ F) & 0xff;
    const bits = [0x02, 0x20, D, S, F, check].flatMap((b) => bitsLSB(b, 8));
    const t = pulseDistance(432, [8, -4], [1, -1], [1, -3], bits, [1]);
    return { freq: 37000, timings: finish(t, 130000) };
  }

  function denon(D, F) {
    const frame = (f, ext) => pulseDistance(264, [], [1, -3], [1, -7], [...bitsLSB(D, 5), ...bitsLSB(f, 8), ...bitsLSB(ext, 2)], [1]);
    const gap = 165 * 264;
    return { freq: 38000, timings: [...frame(F, 0), gap, ...frame(inv(F), 3), gap] };
  }

  // Pad the final space so the whole frame lasts `total` µs (min 10 ms gap).
  function finish(t, total) {
    if (t.length % 2 === 0) t.pop();
    const used = t.reduce((a, b) => a + b, 0);
    t.push(Math.max(10000, total - used));
    return t;
  }

  const table = {
    'NEC': (D, S, F) => nec(D, S, F, [16, -8]),
    'NEC1': (D, S, F) => nec(D, S, F, [16, -8]),
    'NEC2': (D, S, F) => nec(D, S, F, [16, -8]),
    'NECX': (D, S, F) => nec(D, S < 0 ? D : S, F, [8, -8]),
    'NECX1': (D, S, F) => nec(D, S < 0 ? D : S, F, [8, -8]),
    'NECX2': (D, S, F) => nec(D, S < 0 ? D : S, F, [8, -8]),
    'SAMSUNG': (D, S, F) => nec(D, S < 0 ? D : S, F, [8, -8]),
    'SAMSUNG32': (D, S, F) => nec(D, S < 0 ? D : S, F, [8, -8]),
    'SONY12': (D, S, F) => sony(D, S, F, 5),
    'SONY15': (D, S, F) => sony(D, S, F, 8),
    'SONY20': (D, S, F) => sony(D, S, F, 5, 8),
    'RC5': (D, S, F) => rc5(D, F),
    'RC6': (D, S, F) => rc6(D, F),
    'JVC': (D, S, F) => jvc(D, F),
    'KASEIKYO': kaseikyo,
    'PANASONIC': kaseikyo,
    'DENON': (D, S, F) => denon(D, F),
  };

  function normalize(proto) {
    return String(proto || '').toUpperCase().replace(/[^A-Z0-9]/g, '');
  }

  function encode(proto, D, S, F) {
    const fn = table[normalize(proto)];
    if (!fn) return null;
    return fn(+D, S === '' || S == null ? -1 : +S, +F);
  }

  // Pronto hex: 0000 <freq> <once pairs> <repeat pairs> <durations in carrier cycles>
  function toPronto({ freq, timings }) {
    const hex = (n) => Math.max(0, Math.min(0xffff, Math.round(n))).toString(16).toUpperCase().padStart(4, '0');
    const freqCode = 1000000 / (freq * 0.241246);
    const cycles = timings.map((us) => (us * freq) / 1e6);
    return ['0000', hex(freqCode), '0000', hex(cycles.length / 2), ...cycles.map(hex)].join(' ');
  }

  function supported(proto) { return normalize(proto) in table; }

  return { encode, toPronto, supported };
})();
