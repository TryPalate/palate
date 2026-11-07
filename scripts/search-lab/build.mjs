// Builds the big per-category search lists (data/catalog/<cat>.json) from open databases.
// Runs inside GitHub Actions (open internet). Each file: {"v":1,"items":[[name, sub, picture, pop], ...]}
//   picture: "" | "c:<Commons file name>" | "https://..." ; pop: 0-100 (popularity, higher first)
import fs from 'node:fs'; import path from 'node:path';
const OUT = 'out/data/catalog'; fs.mkdirSync(OUT, { recursive: true });
const UA = 'PalateSearchLab/1.0 (https://trypalate.github.io; build job)';
const sleep = ms => new Promise(r => setTimeout(r, ms));
const log = (...a) => console.log(...a);
const norm = s => String(s || '').normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase().replace(/[^a-z0-9]+/g, ' ').trim();
const store = {};                         // cat -> Map(normName -> item)
function add(cat, name, sub = '', pic = '', pop = 0) {
  name = String(name || '').replace(/\s+/g, ' ').trim(); if (!name || /^Q\d+$/.test(name) || name.length > 90) return;
  const m = store[cat] ||= new Map(), k = norm(name); if (!k) return; const o = m.get(k);
  if (!o) m.set(k, { n: name, s: String(sub || '').slice(0, 70), p: pic, pop }); else { if (!o.p && pic) o.p = pic; if (!o.s && sub) o.s = String(sub).slice(0, 70); o.pop = Math.max(o.pop, pop); }
}
async function getJ(url, opt = {}, tries = 4) {
  for (let i = 0; i < tries; i++) {
    try { const r = await fetch(url, { ...opt, headers: { 'User-Agent': UA, Accept: 'application/json', ...(opt.headers || {}) }, signal: AbortSignal.timeout(opt.timeout || 80000) });
      if (r.status === 429 || r.status >= 500) { const w = +(r.headers.get('retry-after') || 0) * 1000 || 4000 * (i + 1); log('  retry', r.status, url.slice(0, 80)); await sleep(w); continue; }
      if (!r.ok) throw new Error('http ' + r.status); return await r.json(); }
    catch (e) { if (i === tries - 1) throw e; await sleep(3000 * (i + 1)); } }
}
// ---------- Wikidata ----------
let lastWd = 0;
async function wd(query) {
  const gap = Date.now() - lastWd; if (gap < 2500) await sleep(2500 - gap); lastWd = Date.now();
  const j = await getJ('https://query.wikidata.org/sparql', { method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded', Accept: 'application/sparql-results+json' }, body: 'query=' + encodeURIComponent(query) });
  return j.results.bindings;
}
const fileOf = u => { try { return 'c:' + decodeURIComponent(String(u).split('/').pop()); } catch (e) { return ''; } };
function spq(classes, o = {}) {
  const { direct = false, sl = 10, extra = '', limit = 3000, logo = false } = o;
  return `SELECT ?item ?itemLabel ?itemDescription ?sl ?img WHERE {
  VALUES ?cls { ${classes.map(q => 'wd:' + q).join(' ')} }
  ?item ${direct ? 'wdt:P31' : 'wdt:P31/wdt:P279*'} ?cls .
  ?item wikibase:sitelinks ?sl . FILTER(?sl >= ${sl}) ${extra}
  OPTIONAL { ?item wdt:${logo ? 'P154' : 'P18'} ?img }
  SERVICE wikibase:label { bd:serviceParam wikibase:language "en,mul". }
} ORDER BY DESC(?sl) LIMIT ${limit}`;
}
const BAD = /disambiguation|family name|given name|surname|wikimedia|list of|category:/i;
async function fromWd(cat, label, q, { sub = d => d, keep = () => true } = {}) {
  try {
    const rows = await wd(q); let n = 0;
    for (const b of rows) { const name = b.itemLabel?.value, desc = b.itemDescription?.value || ''; if (!name || BAD.test(desc) || !keep(name, desc)) continue;
      add(cat, name, sub(desc), b.img ? fileOf(b.img.value) : '', Math.min(100, Math.round(+b.sl.value))); n++; }
    log(`wd ${cat.padEnd(14)} ${label.padEnd(26)} ${rows.length} rows -> ${n} kept`);
  } catch (e) { log(`wd ${cat.padEnd(14)} ${label.padEnd(26)} FAILED ${String(e.message).slice(0, 100)}`); }
}
const cap = t => String(t || '').replace(/^./, m => m.toUpperCase());
const D = d => cap(d).replace(/\s*\((born|\d{3,4}\s*[–-])[^)]*\)\s*$/, '');
const specs = [
  // [cat, label, classes, options, keep]
  ['fragrances', 'perfume', ['Q131746'], { sl: 1, limit: 2000 }],
  ['watches', 'watch models', ['Q178794'], { sl: 3, limit: 1500 }],
  ['tech', 'smartphone models', ['Q19723451'], { sl: 4, limit: 1500 }],
  ['tech', 'game consoles', ['Q8076'], { sl: 8, limit: 300 }],
  ['boardgames', 'board games', ['Q131436'], { sl: 6, limit: 2500 }],
  ['boardgames', 'card games', ['Q142714'], { sl: 12, limit: 800 }],
  ['games', 'video games', ['Q7889'], { direct: true, sl: 25, limit: 4000 }],
  ['fastfood', 'restaurant chains', ['Q18534542'], { sl: 6, limit: 1500, logo: true }],
  ['restaurants', 'restaurants', ['Q11707'], { sl: 10, limit: 1500, logo: true }],
  ['cafes', 'coffeehouses', ['Q30022'], { sl: 8, limit: 1200, logo: true }],
  ['brands', 'brands', ['Q431289'], { sl: 25, limit: 4000, logo: true }],
  ['airlines', 'airlines', ['Q46970'], { sl: 12, limit: 1500, logo: true }],
  ['universities', 'universities', ['Q3918'], { sl: 25, limit: 2500, logo: true }],
  ['clubs', 'football clubs', ['Q476028'], { sl: 18, limit: 2500, logo: true }],
  ['themeparks', 'theme parks', ['Q2416723'], { sl: 5, limit: 800, logo: true }],
  ['wonders', 'world heritage sites', ['Q9259'], { sl: 12, limit: 2000 }],
  ['wonders', 'tourist attractions', ['Q570116'], { sl: 45, limit: 1500 }],
  ['civilizations', 'civilizations', ['Q8432', 'Q28171280'], { sl: 8, limit: 600 }],
  ['civilizations', 'empires', ['Q48349'], { sl: 25, limit: 300 }],
  ['mythology', 'deities', ['Q178885'], { sl: 15, limit: 1500 }],
  ['mythology', 'mythical creatures', ['Q2239243'], { sl: 20, limit: 700 }],
  ['hobbies', 'hobbies', ['Q47728'], { sl: 8, limit: 500 }],
  ['subjects', 'academic disciplines', ['Q11862829'], { sl: 25, limit: 800 }],
  ['holidays', 'holidays', ['Q1445650'], { sl: 18, limit: 800 }],
  ['instruments', 'instruments', ['Q34379'], { sl: 18, limit: 900 }],
  ['languages', 'languages', ['Q34770'], { direct: true, sl: 40, limit: 800 }],
  ['proglangs', 'programming languages', ['Q9143'], { sl: 12, limit: 900 }],
  ['dogs', 'dog breeds', ['Q39367'], { direct: true, sl: 6, limit: 600 }],
  ['catbreeds', 'cat breeds', ['Q43577'], { direct: true, sl: 6, limit: 200 }],
  ['dinosaurs', 'dinosaur genera', ['Q34740'], { direct: true, sl: 14, limit: 400, extra: '?item wdt:P171* wd:Q430 .' }],
  ['fruits', 'fruits', ['Q3314483'], { sl: 22, limit: 300 }],
  ['desserts', 'desserts', ['Q182940'], { sl: 18, limit: 500 }],
  ['pasta', 'pasta', ['Q178'], { sl: 10, limit: 300 }],
  ['cheese', 'cheeses', ['Q10943'], { sl: 6, limit: 800 }],
  ['cocktails', 'cocktails', ['Q134768'], { sl: 8, limit: 600 }],
  ['sauces', 'sauces', ['Q1569'], { sl: 12, limit: 400 }],
  ['cuisines', 'cuisines', ['Q1778821', 'Q15714'], { sl: 15, limit: 500 }],
  ['sports', 'sports', ['Q349'], { sl: 40, limit: 600 }],
  ['podcasts', 'podcasts', ['Q24634210'], { sl: 6, limit: 800 }],
  ['musicals', 'musicals', ['Q2743'], { sl: 10, limit: 800 }],
  ['kdramas', 'K-dramas', ['Q5398426'], { sl: 4, limit: 1200, extra: '?item wdt:P495 wd:Q884 .' }],
  ['comedians', 'comedians', ['Q5'], { direct: true, sl: 35, limit: 1500, extra: '?item wdt:P106 wd:Q245068 .' }],
  ['painters', 'painters', ['Q5'], { direct: true, sl: 60, limit: 1500, extra: '?item wdt:P106 wd:Q1028181 .' }],
  ['philosophers', 'philosophers', ['Q5'], { direct: true, sl: 50, limit: 1200, extra: '?item wdt:P106 wd:Q4964182 .' }],
  ['influencers', 'YouTubers', ['Q5'], { direct: true, sl: 6, limit: 1500, extra: '?item wdt:P106 wd:Q17125263 .' }],
  ['weapons', 'weapon models', ['Q728'], { sl: 18, limit: 1500 }],
  ['aircraft', 'aircraft models', ['Q15056995', 'Q15056993'], { sl: 6, limit: 2500 }],
  ['motorcycles', 'motorcycle models', ['Q23866334'], { sl: 3, limit: 2500 }],
  ['cars', 'car models', ['Q3231690'], { sl: 5, limit: 4000 }],
  ['sneakers', 'sneaker models', ['Q1311163'], { sl: 3, limit: 800 }],
];
const only = (process.env.ONLY || '').split(',').filter(Boolean);
for (const [cat, label, cls, o] of specs) { if (only.length && !only.includes(cat)) continue; await fromWd(cat, label, spq(cls, o), { sub: D }); }
// ---------- TheCocktailDB (free, CORS) ----------
if (!only.length || only.includes('cocktails')) { let n = 0;
  for (const ch of 'abcdefghijklmnopqrstuvwxyz0123456789') { try { const j = await getJ('https://www.thecocktaildb.com/api/json/v1/1/search.php?f=' + ch); for (const d of j.drinks || []) { add('cocktails', d.strDrink, [d.strCategory, d.strAlcoholic].filter(Boolean).join(' · '), d.strDrinkThumb ? d.strDrinkThumb.replace(/^http:/, 'https:') + '/small' : '', 55); n++; } } catch (e) {} await sleep(300); }
  log('cocktaildb', n); }
// ---------- Open Beauty Facts: perfumes ----------
if (!only.length || only.includes('fragrances')) { let n = 0;
  for (let p = 1; p <= 6; p++) { try { const j = await getJ(`https://world.openbeautyfacts.org/facets/categories/perfumes.json?page_size=100&page=${p}&fields=product_name,brands,image_front_small_url,unique_scans_n`); const ps = j.products || []; if (!ps.length) break;
    for (const x of ps) { let nm = String(x.product_name || '').replace(/&quot;/g, '"').replace(/\b\d+(\.\d+)?\s*(ml|oz|fl\.?\s*oz|cl)\b/ig, '').replace(/\s*[-–,]\s*$/, '').replace(/\s+/g, ' ').trim(); const br = String(x.brands || '').split(',')[0].trim(); if (!nm || /^\d+$/.test(nm)) continue;
      if (br && !norm(nm).includes(norm(br))) nm = br + ' ' + nm; add('fragrances', nm, br, x.image_front_small_url || '', 30 + Math.min(40, x.unique_scans_n || 0)); n++; } } catch (e) { log('obf fail', e.message); break; } await sleep(1500); }
  log('obf perfumes', n); }
// ---------- Open Food Facts for the food and drink shelves ----------
const OFF = { cereal: ['breakfast-cereals'], snacks: ['snacks'], sauces: ['sauces'], pasta: ['pastas'], cheese: ['cheeses'], icecream: ['ice-creams'], breakfast: ['breakfasts'], drinks: ['sodas', 'energy-drinks', 'iced-teas'], spirits: ['beers', 'spirits', 'whiskies', 'vodkas', 'rums', 'tequilas', 'gins', 'wines'] };
const offClean = (nm, br) => { nm = String(nm || '').replace(/\b\d+([.,]\d+)?\s*(g|kg|ml|cl|l|oz|lb)\b/ig, '').replace(/\s+/g, ' ').replace(/[-–,]\s*$/, '').trim(); br = String(br || '').split(',')[0].trim(); if (!nm || nm.length < 3 || /^\d+$/.test(nm)) return null; if (br && !norm(nm).includes(norm(br)) && nm.split(' ').length <= 4) nm = br + ' ' + nm; return { n: nm, b: br }; };
for (const [cat, tags] of Object.entries(OFF)) { if (only.length && !only.includes(cat)) continue; let n = 0;
  for (const tag of tags) for (const country of ['united-states', 'united-kingdom']) for (let p = 1; p <= 3; p++) {
    try { const j = await getJ(`https://world.openfoodfacts.org/api/v2/search?categories_tags_en=${tag}&countries_tags_en=${country}&sort_by=unique_scans_n&page_size=100&page=${p}&fields=product_name,brands,image_front_small_url,unique_scans_n,lang`); const ps = j.products || []; if (!ps.length) break;
      for (const x of ps) { const c = offClean(x.product_name, x.brands); if (!c || !x.image_front_small_url) continue; add(cat, c.n, c.b, x.image_front_small_url, 20 + Math.min(60, x.unique_scans_n || 0)); n++; } } catch (e) { log('off fail', cat, tag, country, p, String(e.message).slice(0, 60)); break; } await sleep(6500); }
  log('off', cat, n); }
// ---------- EPA vehicles: every model sold in the US since 1984 ----------
if (!only.length || only.includes('cars')) { try {
  const r = await fetch('https://www.fueleconomy.gov/feg/epadata/vehicles.csv.zip', { headers: { 'User-Agent': UA } }); fs.writeFileSync('/tmp/veh.zip', Buffer.from(await r.arrayBuffer()));
  const { execSync } = await import('node:child_process'); const csv = execSync('unzip -p /tmp/veh.zip vehicles.csv', { maxBuffer: 1 << 28 }).toString().split('\n'); const h = csv[0].split(','), iM = h.indexOf('make'), iO = h.indexOf('model'), iY = h.indexOf('year'); const by = new Map();
  for (const ln of csv.slice(1)) { if (!ln) continue; const c = ln.split(','); const mk = c[iM], md = c[iO], y = +c[iY]; if (!mk || !md) continue; const k = mk + ' ' + md; const o = by.get(k) || { mk, md, a: 9999, b: 0 }; o.a = Math.min(o.a, y); o.b = Math.max(o.b, y); by.set(k, o); }
  for (const o of by.values()) { const nm = norm(o.md).startsWith(norm(o.mk)) ? o.md : o.mk + ' ' + o.md; add('cars', nm, `${o.mk} · ${o.a === o.b ? o.a : o.a + '–' + o.b}`, '', Math.min(40, 5 + (o.b - o.a))); }
  log('epa models', by.size); } catch (e) { log('epa failed', e.message); } }
// ---------- Fragrance datasets with open licences (names and brands only), headers logged so the mapping can be checked ----------
if (!only.length || only.includes('fragrances')) for (const [id, f] of [['scento/fragrance-index', 'scento-fragrance-index.csv'], ['10ml/perfume-sample-prices', ''], ['pelegelraz/perfumes-dataset', ''], ['FragDBnet/fragrance-database', 'fragrances.csv']]) {
  try { let file = f; if (!file) { const info = await getJ('https://huggingface.co/api/datasets/' + id); file = (info.siblings || []).map(s => s.rfilename).find(x => /\.csv$/i.test(x)) || ''; } if (!file) { log('hf', id, 'no csv'); continue; }
    const r = await fetch(`https://huggingface.co/datasets/${id}/resolve/main/${file}`, { headers: { 'User-Agent': UA } }); const t = await r.text(); fs.mkdirSync('out/raw', { recursive: true }); fs.writeFileSync('out/raw/' + id.replace('/', '_') + '.head.csv', t.split('\n').slice(0, 12).join('\n'));
    log('hf', id, file, t.length, 'bytes', t.split('\n').length, 'lines'); log('   header:', t.split('\n')[0].slice(0, 300)); } catch (e) { log('hf', id, 'failed', String(e.message).slice(0, 80)); }
}
// ---------- write ----------
let total = 0; const sizes = [];
for (const [cat, m] of Object.entries(store)) { const items = [...m.values()].sort((a, b) => b.pop - a.pop || a.n.localeCompare(b.n)).map(x => [x.n, x.s, x.p, x.pop]);
  const f = path.join(OUT, cat + '.json'); fs.writeFileSync(f, JSON.stringify({ v: 1, items })); const sz = fs.statSync(f).size; total += sz; sizes.push([cat, items.length, items.filter(x => x[2]).length, sz]); }
log('\ncategory        items  withPic   bytes'); for (const s of sizes.sort()) log(s[0].padEnd(14), String(s[1]).padStart(6), String(s[2]).padStart(8), String(s[3]).padStart(8)); log('total bytes', total);
// samples for checking
for (const [cat, m] of Object.entries(store)) { const top = [...m.values()].sort((a, b) => b.pop - a.pop).slice(0, 6).map(x => x.n); log('  top', cat + ':', top.join(' | ')); }
