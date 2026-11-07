// Combines the parts written by build.mjs (parts/**/part-*/<cat>.json) into data/catalog/<cat>.json + index.json
import fs from 'node:fs'; import path from 'node:path';
const norm = s => String(s || '').normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase().replace(/[^a-z0-9]+/g, ' ').trim();
const dirs = []; (function walk(d) { for (const e of fs.existsSync(d) ? fs.readdirSync(d, { withFileTypes: true }) : []) { const p = path.join(d, e.name); if (e.isDirectory()) { if (/^part-/.test(e.name) && fs.readdirSync(p).some(x => x.endsWith('.json'))) dirs.push(p); else walk(p); } } })(process.argv[2] || 'parts');
const by = {}; for (const d of dirs) for (const f of fs.readdirSync(d).filter(x => x.endsWith('.json'))) { const c = f.slice(0, -5), j = JSON.parse(fs.readFileSync(path.join(d, f), 'utf8')); const m = by[c] ||= new Map();
  for (const [n, s, p, pop] of j.items) { const k = norm(n); const o = m.get(k); if (!o) m.set(k, [n, s, p, pop]); else { if (!o[2] && p) o[2] = p; if (!o[1] && s) o[1] = s; o[3] = Math.max(o[3], pop); } } }
const manual = path.join(path.dirname(new URL(import.meta.url).pathname), 'manual.json');   // hand-written extras for things the open databases lack
if (fs.existsSync(manual)) for (const [c, list] of Object.entries(JSON.parse(fs.readFileSync(manual, 'utf8')))) { const m = by[c] ||= new Map(); for (const [n, s, p, pop] of list) { const k = norm(n); const o = m.get(k); if (!o) m.set(k, [n, s, p, pop]); else { if (!o[1] && s) o[1] = s; o[3] = Math.max(o[3], pop); } } }
const OUT = process.argv[3] || 'data/catalog'; fs.rmSync(OUT, { recursive: true, force: true }); fs.mkdirSync(OUT, { recursive: true }); const cats = {}; let total = 0;
for (const [c, m] of Object.entries(by)) { const items = [...m.values()].sort((a, b) => b[3] - a[3] || a[0].localeCompare(b[0])); fs.writeFileSync(path.join(OUT, c + '.json'), JSON.stringify({ v: 1, items })); cats[c] = items.length; total += fs.statSync(path.join(OUT, c + '.json')).size; }
fs.writeFileSync(path.join(OUT, 'index.json'), JSON.stringify({ t: Math.floor(Date.now() / 1000), cats }));
console.log('merged', dirs.length, 'parts ->', Object.keys(cats).length, 'topics,', Object.values(cats).reduce((a, b) => a + b, 0), 'items,', total, 'bytes'); for (const [c, n] of Object.entries(cats).sort()) console.log(' ', c.padEnd(14), n);
