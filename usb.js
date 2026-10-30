// WebUSB driver for Ocrustar / ElkSmart USB IR blasters (USB vendor 0x045C).
// Ported from elksmart-comm by Přemysl Eric Janouch (0BSD licence):
// https://git.janouch.name/p/usb-drivers
// Works in Chrome / Edge on Android and desktop. iOS browsers have no WebUSB.
const IRUsb = (() => {
  const VENDOR = 0x045c;
  const CMD = {
    transmit: [0xff, 0xff, 0xff, 0xff],
    identify: [0xfc, 0xfc, 0xfc, 0xfc],
  };

  let device = null;
  let epOut = 0, epIn = 0;
  let protocol = 'plain'; // or 'huffman'
  let busy = Promise.resolve();

  const supported = () => 'usb' in navigator;
  const connected = () => !!(device && device.opened);
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

  // --- Coding ----------------------------------------------------------------

  function mangle(value) {
    let reversed = 0;
    for (let i = 0; i < 8; i++) {
      reversed = (reversed << 1) | (value & 1);
      value >>= 1;
    }
    return ~reversed & 0xff;
  }

  function checksum(bytes) {
    let sum = 0;
    for (const b of bytes) sum = (sum + b) >>> 0;
    return mangle((sum & 0xf0) | ((sum >> 8) & 0x0f));
  }

  function compressValue(value, out) {
    if (value <= 2032) {
      out.push(Math.max(2, Math.floor(value / 16 + 0.5)));
    } else {
      do {
        let v = value & 0x7f;
        if ((value >>>= 7)) v |= 0x80;
        out.push(v);
      } while (value);
    }
  }

  // pulses: [{ on, off }] in microseconds
  function compressPulses(pulses) {
    const eq = (a, b) => a.on === b.on && a.off === b.off;
    const counts = pulses.map((p) => pulses.filter((q) => eq(p, q)).length);

    let top1 = 0;
    pulses.forEach((_, i) => { if (counts[i] > counts[top1]) top1 = i; });
    let top2 = top1;
    pulses.forEach((p, i) => {
      if (!eq(p, pulses[top1]) && (top2 === top1 || counts[i] > counts[top2])) top2 = i;
    });
    const p1 = pulses[top1], p2 = pulses[top2];

    const out = [];
    compressValue(p2.on, out);
    compressValue(p2.off, out);
    compressValue(p1.on, out);
    compressValue(p1.off, out);
    out.push(0xff, 0xff, 0xff);
    for (const p of pulses) {
      if (eq(p, p1)) out.push(0);
      else if (eq(p, p2)) out.push(1);
      else { compressValue(p.on, out); compressValue(p.off, out); }
    }
    return out;
  }

  // Binary heap that breaks ties like Java's PriorityQueue (as the app does).
  function heapPush(heap, node) {
    let child = heap.length;
    heap.push(node);
    while (child) {
      const parent = (child - 1) >> 1;
      if (node.frequency >= heap[parent].frequency) break;
      heap[child] = heap[parent];
      child = parent;
    }
    heap[child] = node;
  }

  function heapPop(heap) {
    const result = heap[0];
    const node = heap.pop();
    if (!heap.length) return result;
    let parent = 0;
    while (parent < heap.length >> 1) {
      let child = parent * 2 + 1;
      if (child + 1 < heap.length && heap[child + 1].frequency < heap[child].frequency) child++;
      if (heap[child].frequency >= node.frequency) break;
      heap[parent] = heap[child];
      parent = child;
    }
    heap[parent] = node;
    return result;
  }

  function huffmanEncode(input) {
    const freq = new Array(256).fill(0);
    for (const b of input) freq[b]++;

    const heap = [], leaves = [];
    for (let i = 0; i < 256; i++) {
      if (!freq[i]) continue;
      leaves[i] = { frequency: freq[i], parent: null, bit: 0 };
      heapPush(heap, leaves[i]);
    }

    const out = [(heap.length >> 8) & 0xff, heap.length & 0xff];
    for (let i = 0; i < 256; i++) {
      if (freq[i]) out.push(i, (freq[i] >> 8) & 0xff, freq[i] & 0xff);
    }

    while (heap.length > 1) {
      const left = heapPop(heap), right = heapPop(heap);
      const node = { frequency: left.frequency + right.frequency, parent: null, bit: 0 };
      left.parent = right.parent = node;
      left.bit = 0;
      right.bit = 1;
      heapPush(heap, node);
    }

    const padding = out.length;
    out.push(0);
    let byte = 0, bit = 0;
    for (const b of input) {
      const bits = [];
      for (let n = leaves[b]; n.parent; n = n.parent) bits.push(n.bit);
      while (bits.length) {
        byte = (byte << 1) | bits.pop();
        if (++bit === 8) { out.push(byte & 0xff); byte = bit = 0; }
      }
    }
    if (bit) {
      out[padding] = 8 - bit;
      out.push((byte << (8 - bit)) & 0xff);
    }
    return out;
  }

  // Full transmit message, split into USB packets (62 bytes + checksum).
  function buildPackets(sig, repeats = 1) {
    const pulses = [];
    for (let r = 0; r < repeats; r++) {
      for (let i = 0; i < sig.timings.length; i += 2) {
        pulses.push({ on: Math.round(sig.timings[i]), off: Math.round(sig.timings[i + 1] ?? 25000) });
      }
    }
    let data = compressPulses(pulses);
    if (protocol === 'huffman') data = huffmanEncode(data);

    const f = sig.freq + 0x7ffff;
    const msg = [
      ...CMD.transmit,
      mangle((f >> 8) & 0xff), mangle((f >> 16) & 0xff), mangle(f & 0xff),
      mangle((data.length >> 8) & 0xff), mangle(data.length & 0xff),
      ...data,
    ];

    const packets = [];
    for (let i = 0; i < msg.length; i += 62) {
      const chunk = msg.slice(i, i + 62);
      if (chunk.length === 62) chunk.push(checksum(chunk));
      packets.push(new Uint8Array(chunk));
    }
    return packets;
  }

  // --- Device ----------------------------------------------------------------

  function readWithTimeout(ms) {
    return Promise.race([
      device.transferIn(epIn, 64).then((r) => (r.data ? new Uint8Array(r.data.buffer, r.data.byteOffset, r.data.byteLength) : new Uint8Array())),
      sleep(ms).then(() => null),
    ]);
  }

  async function identify() {
    for (let attempt = 0; attempt < 4; attempt++) {
      await device.transferOut(epOut, new Uint8Array(CMD.identify));
      const b = await readWithTimeout(500);
      if (!b) continue;
      if (b.length === 6 && b[0] === 0xfc && b[4] === 0x02 && b[5] === 0xaa) return 'huffman';
      if (b.length === 6) return 'plain';
    }
    return 'plain'; // no answer: the plain format is what older dongles use
  }

  async function open(d) {
    device = d;
    await device.open();
    if (!device.configuration) await device.selectConfiguration(1);
    await device.claimInterface(0);
    const alt = device.configuration.interfaces[0].alternate;
    for (const ep of alt.endpoints) {
      if (ep.type !== 'bulk') continue;
      if (ep.direction === 'out') epOut = ep.endpointNumber;
      else epIn = ep.endpointNumber;
    }
    if (!epOut || !epIn) throw new Error('This blaster has an unexpected USB layout.');
    protocol = await identify();
    return { name: device.productName || 'IR blaster', protocol, productId: device.productId };
  }

  async function connect() {
    if (!supported()) throw new Error('This browser has no WebUSB. Use Chrome on Android or a computer.');
    const d = await navigator.usb.requestDevice({ filters: [{ vendorId: VENDOR }] });
    return open(d);
  }

  // Reconnect silently to a blaster the user already allowed on this site.
  async function reconnect() {
    if (!supported()) return null;
    const list = await navigator.usb.getDevices();
    const d = list.find((x) => x.vendorId === VENDOR);
    return d ? open(d) : null;
  }

  function send(sig, repeats) {
    // Queue sends so fast taps don't interleave packets.
    busy = busy.catch(() => {}).then(async () => {
      if (!connected()) throw new Error('Connect the USB blaster first.');
      for (const packet of buildPackets(sig, repeats)) {
        await device.transferOut(epOut, packet);
        await sleep(2);
      }
      await sleep(100);
    });
    return busy;
  }

  if (supported()) {
    navigator.usb.addEventListener('disconnect', (e) => {
      if (e.device === device) {
        device = null;
        window.dispatchEvent(new Event('irusb-disconnect'));
      }
    });
  }

  return { supported, connected, connect, reconnect, send, buildPackets, huffmanEncode, compressPulses, mangle };
})();
