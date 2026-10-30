const RAW = 'https://raw.githubusercontent.com/probonopd/irdb/master/codes/';
const $ = (sel) => document.querySelector(sel);
const view = $('#view');
const crumbs = $('#crumbs');
const search = $('#search');

// brand -> [{ type, file, path }]
let brands = new Map();
let totalRemotes = 0;

const store = {
  get(key, fallback) {
    try { return JSON.parse(localStorage.getItem(key)) ?? fallback; } catch { return fallback; }
  },
  set(key, value) {
    try { localStorage.setItem(key, JSON.stringify(value)); } catch { /* storage unavailable */ }
  },
};
let favorites = store.get('favorites', []);

const blastOpts = { mode: 'half', repeats: 2, invert: false, ...store.get('blastOpts', {}) };
$('#opt-mode').value = blastOpts.mode;
$('#opt-repeats').value = String(blastOpts.repeats);
$('#opt-invert').checked = blastOpts.invert;
$('#blast-settings').addEventListener('change', () => {
  blastOpts.mode = $('#opt-mode').value;
  blastOpts.repeats = +$('#opt-repeats').value;
  blastOpts.invert = $('#opt-invert').checked;
  store.set('blastOpts', blastOpts);
});

function blast(sig, label) {
  try {
    const { toneHz } = IRAudio.blast(sig, blastOpts);
    toast(`📡 ${label} · ${(toneHz / 1000).toFixed(1)} kHz tone`);
  } catch (e) {
    toast(e.message);
  }
}

const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const urlFor = (path) => RAW + path.split('/').map(encodeURIComponent).join('/');
const hashFor = (...parts) => '#/' + parts.map(encodeURIComponent).join('/');

function toast(msg) {
  const el = $('#toast');
  el.textContent = msg;
  el.hidden = false;
  clearTimeout(toast.t);
  toast.t = setTimeout(() => (el.hidden = true), 1600);
}

async function copy(text, label) {
  try {
    await navigator.clipboard.writeText(text);
  } catch {
    const ta = document.createElement('textarea');
    ta.value = text;
    document.body.appendChild(ta);
    ta.select();
    document.execCommand('copy');
    ta.remove();
  }
  toast(`${label} copied`);
}

async function loadIndex() {
  const res = await fetch(RAW + 'index');
  if (!res.ok) throw new Error('index ' + res.status);
  const lines = (await res.text()).split('\n').map((l) => l.trim()).filter(Boolean);
  for (const path of lines) {
    const [brand, type, file] = path.split('/');
    if (!file) continue;
    if (!brands.has(brand)) brands.set(brand, []);
    brands.get(brand).push({ type, file: file.replace(/\.csv$/, ''), path });
  }
  brands = new Map([...brands].sort((a, b) => a[0].localeCompare(b[0], undefined, { sensitivity: 'base' })));
  totalRemotes = lines.length;
  $('#stats').textContent = `${brands.size.toLocaleString()} brands · ${totalRemotes.toLocaleString()} remotes`;
}

function parseCsv(text) {
  const rows = text.trim().split(/\r?\n/);
  const header = rows.shift().split(',').map((h) => h.trim().toLowerCase());
  return rows.map((line) => {
    // functionname can contain commas when quoted
    const cells = [];
    let cur = '', q = false;
    for (const ch of line) {
      if (ch === '"') q = !q;
      else if (ch === ',' && !q) { cells.push(cur); cur = ''; }
      else cur += ch;
    }
    cells.push(cur);
    return Object.fromEntries(header.map((h, i) => [h, (cells[i] ?? '').trim()]));
  });
}

function setCrumbs(parts) {
  crumbs.innerHTML = [`<a href="#/">All brands</a>`, ...parts].join('<span>›</span>');
}

/* ---------- views ---------- */

function renderHome() {
  setCrumbs([]);
  const q = search.value.trim().toLowerCase();
  let html = '';

  if (!q && favorites.length) {
    html += `<div class="section-title">★ Saved remotes</div><div class="grid">` +
      favorites.map((f) => `<a class="card" href="${hashFor(f.brand, f.type, f.file)}"><b>${esc(f.brand)}</b><small>${esc(f.type)}</small></a>`).join('') +
      `</div><div class="section-title">All brands</div>`;
  }

  const matches = [];
  for (const [brand, remotes] of brands) {
    if (!q || brand.toLowerCase().includes(q)) matches.push({ brand, remotes, hit: null });
    else {
      const hit = remotes.filter((r) => r.type.toLowerCase().includes(q));
      if (hit.length) matches.push({ brand, remotes, hit });
    }
  }

  if (!matches.length) {
    view.innerHTML = html + `<div class="notice">No brands or device types match “${esc(q)}”.</div>`;
    return;
  }

  html += `<div class="grid">` + matches.map(({ brand, remotes, hit }) => {
    const sub = hit ? hit.map((r) => r.type).slice(0, 2).join(', ') + (hit.length > 2 ? '…' : '') : `${remotes.length} remote${remotes.length > 1 ? 's' : ''}`;
    return `<a class="card" href="${hashFor(brand)}"><b>${esc(brand)}</b><small>${esc(sub)}</small></a>`;
  }).join('') + `</div>`;
  view.innerHTML = html;
}

function renderBrand(brand) {
  const remotes = brands.get(brand);
  if (!remotes) return notFound();
  setCrumbs([`<a href="${hashFor(brand)}">${esc(brand)}</a>`]);
  view.innerHTML = `<h2>${esc(brand)}</h2>
    <div class="meta">${remotes.length} remote${remotes.length > 1 ? 's' : ''}. Pick the one matching your device; if it doesn't work, try the next one.</div>
    <div class="grid">${remotes.map((r) => `
      <a class="card" href="${hashFor(brand, r.type, r.file)}">
        <b>${esc(r.type.replace(/_/g, ' '))}</b>
        <small>device ${esc(r.file.replace(',', ' / sub '))}</small>
      </a>`).join('')}
    </div>`;
}

async function renderRemote(brand, type, file) {
  const remote = (brands.get(brand) || []).find((r) => r.type === type && r.file === file);
  if (!remote) return notFound();
  setCrumbs([`<a href="${hashFor(brand)}">${esc(brand)}</a>`, `<span>${esc(type)}</span>`]);
  view.innerHTML = `<div class="notice">Loading codes…</div>`;

  let rows;
  try {
    const res = await fetch(urlFor(remote.path));
    if (!res.ok) throw new Error(res.status);
    rows = parseCsv(await res.text());
  } catch (e) {
    view.innerHTML = `<div class="notice">Couldn't load this remote (${esc(e.message)}). Check your connection and try again.</div>`;
    return;
  }

  const codes = rows.map((r) => {
    const sig = IR.encode(r.protocol, r.device, r.subdevice, r.function);
    return { ...r, sig, pronto: sig && IR.toPronto(sig), raw: sig && sig.timings.join(',') };
  });

  const isFav = favorites.some((f) => f.brand === brand && f.type === type && f.file === file);
  const protos = [...new Set(rows.map((r) => r.protocol))].join(', ');

  view.innerHTML = `
    <h2>${esc(brand)} · ${esc(type.replace(/_/g, ' '))}</h2>
    <div class="meta">${codes.length} buttons · protocol ${esc(protos)} · device ${esc(file)}</div>
    <div class="toolbar">
      <button class="star ${isFav ? 'on' : ''}" id="fav">${isFav ? '★ Saved' : '☆ Save remote'}</button>
      <button id="dl-json">Download JSON</button>
      <button id="dl-pronto">Download Pronto list</button>
      <a class="btn" href="${esc(urlFor(remote.path))}" target="_blank" rel="noopener">Source CSV</a>
    </div>
    <div class="codes">${codes.map((c, i) => `
      <div class="code" data-i="${i}">
        <div>
          <div class="name">${esc(c.functionname || '(unnamed)')}</div>
          <div class="proto">${esc(c.protocol)} D=${esc(c.device)} S=${esc(c.subdevice)} F=${esc(c.function)}${c.sig ? ` · ${c.sig.freq / 1000} kHz` : ''}</div>
        </div>
        <div class="actions">${c.sig ? `
          <button class="primary" data-act="blast">Blast</button>
          <button data-act="pronto">Copy Pronto</button>
          <button data-act="raw">Copy raw</button>
          <button data-act="wave">Show</button>` : `<span class="unsupported">Protocol not encodable yet</span>`}
        </div>
        <div class="wave"></div>
      </div>`).join('')}
    </div>`;

  $('#fav').onclick = () => {
    const idx = favorites.findIndex((f) => f.brand === brand && f.type === type && f.file === file);
    if (idx >= 0) favorites.splice(idx, 1); else favorites.unshift({ brand, type, file });
    store.set('favorites', favorites);
    renderRemote(brand, type, file);
  };

  const name = `${brand}_${type}_${file}`.replace(/[^\w-]+/g, '_');
  $('#dl-json').onclick = () => download(`${name}.json`, JSON.stringify(codes.map(({ sig, ...c }) => ({ ...c, frequency: sig?.freq ?? null })), null, 2));
  $('#dl-pronto').onclick = () => download(`${name}.txt`, codes.filter((c) => c.pronto).map((c) => `${c.functionname}\n${c.pronto}\n`).join('\n'));

  view.querySelector('.codes').onclick = (e) => {
    const btn = e.target.closest('button[data-act]');
    if (!btn) return;
    const row = btn.closest('.code');
    const c = codes[row.dataset.i];
    if (btn.dataset.act === 'blast') blast(c.sig, c.functionname || 'Button');
    if (btn.dataset.act === 'pronto') copy(c.pronto, 'Pronto hex');
    if (btn.dataset.act === 'raw') copy(c.raw, 'Raw timings');
    if (btn.dataset.act === 'wave') {
      const open = row.classList.toggle('open');
      btn.textContent = open ? 'Hide' : 'Show';
      if (open && !row.querySelector('.wave').innerHTML) {
        row.querySelector('.wave').innerHTML = waveform(c.sig.timings) +
          `<pre>Pronto: ${esc(c.pronto)}\n\nRaw (µs, ${c.sig.freq} Hz): ${esc(c.raw)}</pre>`;
      }
    }
  };
}

function waveform(timings) {
  const total = timings.reduce((a, b) => a + b, 0);
  const W = 1000, H = 40;
  let x = 0, d = `M0 ${H - 4}`;
  timings.forEach((t, i) => {
    const y = i % 2 === 0 ? 4 : H - 4;
    d += ` L${x.toFixed(1)} ${y}`;
    x += (t / total) * W;
    d += ` L${x.toFixed(1)} ${y}`;
  });
  return `<svg viewBox="0 0 ${W} ${H}" preserveAspectRatio="none"><path d="${d}" fill="none" stroke="var(--accent)" stroke-width="1.5" vector-effect="non-scaling-stroke"/></svg>`;
}

function download(filename, text) {
  const a = document.createElement('a');
  a.href = URL.createObjectURL(new Blob([text], { type: 'text/plain' }));
  a.download = filename;
  a.click();
  setTimeout(() => URL.revokeObjectURL(a.href), 1000);
}

function notFound() {
  setCrumbs([]);
  view.innerHTML = `<div class="notice">That remote wasn't found. <a href="#/">Back to all brands</a></div>`;
}

/* ---------- routing ---------- */

function route() {
  const parts = location.hash.replace(/^#\/?/, '').split('/').filter(Boolean).map(decodeURIComponent);
  window.scrollTo(0, 0);
  if (parts.length === 0) renderHome();
  else if (parts.length === 1) renderBrand(parts[0]);
  else renderRemote(parts[0], parts[1], parts[2]);
}

search.addEventListener('input', () => {
  if (location.hash.length > 2) location.hash = '#/';
  else renderHome();
});
window.addEventListener('hashchange', route);

loadIndex().then(route).catch((e) => {
  $('#stats').textContent = '';
  view.innerHTML = `<div class="notice">Couldn't load the code database (${esc(e.message)}). Check your connection and reload.</div>`;
});
