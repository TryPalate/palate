// Writes one tiny page per topic (albums/index.html, fastfood/index.html, ...) so that
// trypalate.github.io/palate/albums answers with a normal 200 page that has its own link preview,
// then forwards to the app at ./?c=albums. Topics without a folder still work through 404.html.
// Run after adding a topic to CATS in index.html:   node scripts/make-topic-pages.mjs
import fs from 'node:fs';
import path from 'node:path';
const root = path.resolve(path.dirname(new URL(import.meta.url).pathname), '..');
const src = fs.readFileSync(path.join(root, 'index.html'), 'utf8');
const a = src.indexOf('const CATS = ['), b = src.indexOf('\n].map(', a);
if (a < 0 || b < 0) throw new Error('Could not find CATS in index.html');
const rows = new Function('return ' + src.slice(a + 'const CATS = '.length, b + 2))();
const SITE = 'https://trypalate.github.io/palate/';
const taken = new Set(fs.readdirSync(root));
const esc = s => s.replace(/&/g, '&amp;').replace(/"/g, '&quot;').replace(/</g, '&lt;');
const phrase = n => n.split(' ').map(w => (/[A-Z].*[A-Z]/.test(w) || /^(Pokémon|K-dramas)$/.test(w)) ? w : w.toLowerCase()).join(' ');
const made = [];
for (const [id, name] of rows) {
  if (!/^[a-z0-9-]{1,40}$/.test(id)) throw new Error('Topic id cannot be a web path: ' + id);
  const dir = path.join(root, id);
  if (taken.has(id) && !(fs.existsSync(path.join(dir, 'index.html')) && fs.readFileSync(path.join(dir, 'index.html'), 'utf8').includes('data-topic-page'))) throw new Error(`"${id}" collides with an existing file or folder`);
  const t = phrase(name), title = `Rank your top 5 ${t} · Palate`, desc = `Build your top 5 ${t} on Palate, say why, and see how your taste matches your friends'.`;
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, 'index.html'), `<!doctype html>
<html lang="en" data-topic-page>
<meta charset="utf-8">
<title>${esc(title)}</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="description" content="${esc(desc)}">
<meta name="robots" content="noindex">
<meta property="og:type" content="website">
<meta property="og:site_name" content="Palate">
<meta property="og:title" content="${esc(title)}">
<meta property="og:description" content="${esc(desc)}">
<meta property="og:url" content="${SITE}${id}/">
<meta property="og:image" content="${SITE}icons/og-image.png">
<meta property="og:image:width" content="1200">
<meta property="og:image:height" content="630">
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:title" content="${esc(title)}">
<meta name="twitter:description" content="${esc(desc)}">
<meta name="twitter:image" content="${SITE}icons/og-image.png">
<meta name="theme-color" content="#0A0A0D">
<style>html{background:#0A0A0D;color:#F5F5F7;font:16px system-ui,sans-serif}body{margin:0;display:grid;place-items:center;min-height:100vh}a{color:#FFB06B}</style>
<script>location.replace('../?c=${id}'+(location.search?'&'+location.search.slice(1):'')+location.hash);</script>
<noscript><meta http-equiv="refresh" content="0;url=../?c=${id}"></noscript>
<p>Opening Palate… <a href="../?c=${id}">Continue</a></p>
</html>
`);
  made.push(id);
}
console.log(`Wrote ${made.length} topic pages.`);
