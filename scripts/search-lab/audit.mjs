// Drives the REAL app in a real browser with real network, types every test query into the editor's search box,
// and records what comes back (names, subtitles, whether a picture actually loaded). Writes out/audit.json + out/audit.md.
import { chromium } from 'playwright';
import fs from 'node:fs'; import http from 'node:http'; import path from 'node:path';
import { Q } from './queries.mjs';
const ROOT = path.resolve(path.dirname(new URL(import.meta.url).pathname), '../..');
const ONLY = (process.env.ONLY_CATS || '').split(',').filter(Boolean), WORKERS = +(process.env.WORKERS || 4);
const SDK = fs.readFileSync(path.join(process.env.LAB_DIR || '/tmp/lab', 'node_modules/@supabase/supabase-js/dist/umd/supabase.js'), 'utf8');
const MIME = { '.html': 'text/html', '.js': 'text/javascript', '.json': 'application/json', '.css': 'text/css', '.png': 'image/png', '.svg': 'image/svg+xml', '.webmanifest': 'application/json', '.ico': 'image/x-icon' };
const srv = http.createServer((req, res) => { let p = decodeURIComponent(req.url.split('?')[0]); if (!p.startsWith('/palate/')) { res.writeHead(404); return res.end(); } p = p.slice(8) || 'index.html'; let f = path.join(ROOT, p); if (fs.existsSync(f) && fs.statSync(f).isDirectory()) f = path.join(f, 'index.html'); if (!fs.existsSync(f)) { res.writeHead(404); return res.end('nf'); } res.writeHead(200, { 'Content-Type': MIME[path.extname(f)] || 'application/octet-stream' }); res.end(fs.readFileSync(f)); }).listen(8802);
const HTML = fs.readFileSync(path.join(ROOT, 'index.html'), 'utf8').replace('(async function boot(){', 'window.__t={openEditor,get ed(){return ed},CATALOG};\n(async function boot(){');
const user = { id: '11111111-1111-1111-1111-111111111111', aud: 'authenticated', role: 'authenticated', email: 'lab@test.com', user_metadata: { name: 'Lab' }, app_metadata: {}, created_at: new Date().toISOString() };
const session = { access_token: 'a.b.c', token_type: 'bearer', expires_in: 3600, expires_at: Math.floor(Date.now() / 1000) + 3600, refresh_token: 'r', user };
const J = (r, b, s = 200) => r.fulfill({ status: s, contentType: 'application/json', body: JSON.stringify(b) });
async function newPage(browser) {
  const ctx = await browser.newContext({ viewport: { width: 420, height: 900 } }), page = await ctx.newPage();
  await page.route(/\/palate\/(\?.*)?$/, r => r.fulfill({ contentType: 'text/html', body: HTML }));
  await page.route('**/supabase-js@2.45.4/**', r => r.fulfill({ contentType: 'application/javascript', body: SDK }));
  await page.route('**/auth/v1/**', r => { const u = r.request().url(); if (/signup|token/.test(u)) return J(r, session); if (/\/user/.test(u)) return J(r, user); return J(r, {}); });
  await page.route('**/rest/v1/*', r => { const obj = /pgrst\.object/.test(r.request().headers()['accept'] || ''); if (r.request().method() !== 'GET') return J(r, [], 201); return obj ? r.fulfill({ status: 200, contentType: 'application/json', body: 'null' }) : J(r, []); });
  await page.route('**/rest/v1/rpc/*', r => { const n = r.request().url().split('/rpc/')[1].split('?')[0]; if (n === 'unlock_state') return J(r, { gate: false, v: 3, revealed: true, picks_left: 0, unlocked: [], invites: 0, days: 1, shelves: 0, rewards: [], points: 0, per_pick: 3, to_next: 3 }); return J(r, null); });
  await page.route('**/rest/v1/profiles*', r => { const obj = /pgrst\.object/.test(r.request().headers()['accept'] || ''); const row = { id: user.id, name: 'Lab', invite_code: 'LABCODE000000000', avatar: 0 }; if (r.request().method() === 'GET' && !obj) return J(r, [row]); return J(r, row, r.request().method() === 'POST' ? 201 : 200); });
  await page.goto('http://127.0.0.1:8802/palate/', { waitUntil: 'load' }); await page.waitForTimeout(800);
  await page.fill('#au-email', 'lab@test.com'); await page.fill('#au-pass', 'password123'); await page.click('#auth-form button[type=submit]');
  await page.waitForFunction(() => document.body.classList.contains('in'), null, { timeout: 20000 }).catch(async e => { console.log('LOGIN FAIL', (await page.evaluate(() => document.body.className + ' | ' + document.body.innerText.slice(0, 300))).replace(/\n/g, ' / ')); throw e; }); await page.waitForTimeout(500);
  return { ctx, page };
}
const norm = s => String(s || '').toLowerCase();
async function runQuery(page, cat, q) {
  const t0 = Date.now();
  await page.evaluate(c => { document.querySelector('#sheet-root .scrim')?.click?.(); __t.openEditor(c, false); }, cat);
  await page.waitForSelector('#ed-q', { timeout: 8000 }); await page.fill('#ed-q', ''); await page.type('#ed-q', q, { delay: 8 });
  const done = async (ms) => { const end = Date.now() + ms; while (Date.now() < end) { if (!(await page.$('#ed-results .res-wait'))) return true; await page.waitForTimeout(250); } return false; };
  const settled = await done(20000); await page.waitForTimeout(500);
  const t1 = Date.now() - t0;
  // give picture lookups time to land: wait until no result is still waiting for a picture, or 8s
  const end = Date.now() + 12000; while (Date.now() < end) { const pend = await page.$$eval('#ed-results .res .art:not(.photo)', n => n.length); if (!pend) break; await page.waitForTimeout(400); }
  const rows = await page.$$eval('#ed-results li:not(.sec):not(.res-wait):not(.res-none)', lis => lis.map(li => ({ n: li.querySelector('.nm b')?.textContent || '', s: li.querySelector('.nm span')?.textContent || '', photo: !!li.querySelector('.art.photo.ld'), photoPending: !!li.querySelector('.art.photo:not(.ld):not(.ld-err)'), src: (li.querySelector('.art.photo')?.dataset.src || '').replace(/^https?:\/\/([^/]+).*/, '$1'), add: !!li.querySelector('[data-act=custom]') })));
  return { settled, ms: t1, rows };
}
(async () => {
  const browser = await chromium.launch(); const jobs = Q.filter(x => !ONLY.length || ONLY.includes(x[0])); const out = []; let next = 0;
  async function worker(w) {
    let { ctx, page } = await newPage(browser);
    while (next < jobs.length) { const [cat, q, re] = jobs[next++]; let r;
      try { r = await runQuery(page, cat, q); } catch (e) { r = { error: String(e.message).slice(0, 120), rows: [] }; try { await ctx.close(); ({ ctx, page } = await newPage(browser)); } catch (e2) {} }
      const items = r.rows.filter(x => !x.add), rx = new RegExp(re, 'i'); const idx = items.findIndex(x => rx.test(norm(x.n)));
      out.push({ cat, q, re, found: idx, photo: idx >= 0 ? items[idx].photo : null, ms: r.ms, settled: r.settled, error: r.error, top: items.slice(0, 6).map(x => `${x.n}${x.s ? ' · ' + x.s : ''}${x.photo ? ' 📷' : ''}`), photoShare: items.length ? items.filter(x => x.photo).length / items.length : 0, src: items.filter(x => x.photo).map(x => x.src).slice(0, 3) });
      console.log(`[w${w}] ${cat} | ${q} -> ${idx >= 0 ? 'found #' + (idx + 1) + (items[idx].photo ? ' 📷' : ' (no pic)') : 'MISSING'} (${items.length} rows, ${r.ms}ms)`); }
    await ctx.close();
  }
  await Promise.all(Array.from({ length: WORKERS }, (_, i) => worker(i)));
  await browser.close(); srv.close(); fs.mkdirSync('out', { recursive: true });
  out.sort((a, b) => a.cat.localeCompare(b.cat)); fs.writeFileSync('out/audit.json', JSON.stringify(out, null, 1));
  const cats = [...new Set(out.map(x => x.cat))]; let md = '# Search audit\n\n| category | found | top-3 | with picture | avg ms |\n|---|---|---|---|---|\n';
  for (const c of cats) { const l = out.filter(x => x.cat === c), f = l.filter(x => x.found >= 0), t3 = l.filter(x => x.found >= 0 && x.found < 3), p = f.filter(x => x.photo); md += `| ${c} | ${f.length}/${l.length} | ${t3.length}/${l.length} | ${p.length}/${f.length || 0} | ${Math.round(l.reduce((s, x) => s + (x.ms || 0), 0) / l.length)} |\n`; }
  const tot = out.length, fa = out.filter(x => x.found >= 0).length, pa = out.filter(x => x.found >= 0 && x.photo).length;
  md += `\n**Overall:** found ${fa}/${tot}, with picture ${pa}/${fa}\n\n## Misses and picture gaps\n`;
  for (const x of out.filter(x => x.found < 0 || !x.photo)) md += `- **${x.cat}** “${x.q}” ${x.found < 0 ? '**MISSING**' : '(no picture)'}${x.error ? ' ERROR ' + x.error : ''}: ${x.top.slice(0, 4).join(' / ') || '(no results)'}\n`;
  fs.writeFileSync('out/audit.md', md); console.log(md.split('\n').slice(0, 5).join('\n'));
})();
