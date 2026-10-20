// Sends "friend updated their shelf" and "friend reacted to your pick" notifications. Run by .github/workflows/notify.yml every few minutes.
// Needs two secrets: PUSH_KEY (select value from app_config where key = 'push_key') and VAPID_PRIVATE_KEY.
import fs from 'node:fs';
import webpush from 'web-push';

const { PUSH_KEY, VAPID_PRIVATE_KEY } = process.env;
if (!PUSH_KEY || !VAPID_PRIVATE_KEY) { console.log('Add the PUSH_KEY and VAPID_PRIVATE_KEY secrets to turn notifications on.'); process.exit(0); }

const cfg = fs.readFileSync('config.js', 'utf8');
const BASE = process.env.PALATE_API || /https:\/\/[a-z0-9]+\.supabase\.co/.exec(cfg)[0];
const KEY = /sb_publishable_[\w-]+|eyJ[\w.-]+/.exec(cfg)[0];
const PUB = /vapidPublicKey:\s*"([^"]+)"/.exec(cfg)[1];
webpush.setVapidDetails('https://trypalate.github.io/palate/', PUB, VAPID_PRIVATE_KEY);

// Category names, straight from the app so they never drift
const html = fs.readFileSync('index.html', 'utf8');
const block = html.slice(html.indexOf('const CATS = ['), html.indexOf('].map(([id,name,group'));
const NAME = {}; for (const m of block.matchAll(/\['([a-z0-9]+)','([^']+)'/g)) NAME[m[1]] = m[2];

async function rpc(fn, body) {
  const r = await fetch(`${BASE}/rest/v1/rpc/${fn}`, { method: 'POST', headers: { apikey: KEY, Authorization: `Bearer ${KEY}`, 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
  if (!r.ok) throw new Error(`${fn}: ${r.status} ${await r.text()}`);
  const t = await r.text(); return t ? JSON.parse(t) : null;
}

export function message(items) {            // items: Map friend name -> [shelf names], newest first
  const friends = [...items.keys()];
  const shelves = [...new Set([...items.values()].flat())];
  const first = friends[0];
  if (friends.length === 1 && shelves.length === 1) return { title: `${first} updated their ${shelves[0]} shelf`, body: 'See what they picked.' };
  if (friends.length === 1) return { title: `${first} updated ${shelves.length} shelves`, body: shelves.slice(0, 3).join(', ') + (shelves.length > 3 ? '…' : '') };
  const who = friends.length === 2 ? `${friends[0]} and ${friends[1]}` : `${first} and ${friends.length - 1} others`;
  return { title: `${who} updated their shelves`, body: shelves.slice(0, 3).join(', ') + (shelves.length > 3 ? '…' : '') };
}

const KIND = { same: 'Same', nope: 'No way', curious: 'Curious' };
export function reactionMessage(list) {    // list: [{friend, cat, item, kind}], newest first
  if (list.length === 1) { const r = list[0]; return { title: `${r.friend}: “${KIND[r.kind] || r.kind}”`, body: `On ${r.item}, in your ${NAME[r.cat] || r.cat}` }; }
  const people = [...new Set(list.map(r => r.friend))];
  const who = people.length === 1 ? people[0] : people.length === 2 ? `${people[0]} and ${people[1]}` : `${people[0]} and ${people.length - 1} others`;
  return { title: `${who} reacted to ${list.length} of your picks`, body: list.slice(0, 2).map(r => `${KIND[r.kind] || r.kind} on ${r.item}`).join(', ') + (list.length > 2 ? '…' : '') };
}

const rows = (await rpc('push_pending', { p_key: PUSH_KEY })) || [];
let asOf = rows.length ? rows[0].as_of : null;
let reacts = [];
try { reacts = (await rpc('push_reactions_pending', { p_key: PUSH_KEY, p_as_of: asOf })) || []; }
catch (e) { console.log('Reactions are not set up yet (run supabase/reactions.sql):', e.message.slice(0, 120)); }
if (!asOf && reacts.length) asOf = reacts[0].as_of;
if (!rows.length && !reacts.length) { console.log('Nothing to send.'); process.exit(0); }

const subs = new Map();
const subOf = r => { if (!subs.has(r.endpoint)) subs.set(r.endpoint, { sub: { endpoint: r.endpoint, keys: { p256dh: r.p256dh, auth: r.auth_key } }, items: new Map(), reacts: [] }); return subs.get(r.endpoint); };
for (const r of rows) {
  const m = subOf(r).items, nm = NAME[r.cat] || r.cat;
  if (!m.has(r.friend)) m.set(r.friend, []);
  if (!m.get(r.friend).includes(nm)) m.get(r.friend).push(nm);
}
for (const r of reacts) subOf(r).reacts.push(r);

const sent = [];
for (const [endpoint, { sub, items, reacts: rs }] of subs) {
  const notes = [];
  if (items.size) notes.push({ ...message(items), url: './#friends', tag: 'palate-friends' });
  if (rs.length) notes.push({ ...reactionMessage(rs), url: './#activity', tag: 'palate-reactions' });
  let ok = true;
  for (const n of notes) {
    try { await webpush.sendNotification(sub, JSON.stringify(n), { TTL: 86400 }); console.log('sent:', n.title); }
    catch (e) {
      ok = false;
      if (e.statusCode === 404 || e.statusCode === 410) { console.log('removing expired subscription'); await rpc('push_drop', { p_key: PUSH_KEY, p_endpoint: endpoint }).catch(() => {}); break; }
      else console.log('could not send, will retry next run:', e.statusCode || e.message);
    }
  }
  if (ok) sent.push(endpoint);
}
if (sent.length) await rpc('push_done', { p_key: PUSH_KEY, p_endpoints: sent, p_as_of: asOf });
console.log(`Done: ${sent.length} of ${subs.size} phones notified.`);
