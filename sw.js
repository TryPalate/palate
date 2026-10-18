/* Palate service worker: keeps artwork on the device so pictures show instantly, and shows friend-update notifications. */
const IMG = 'palate-img-v1';
const MAX_IMAGES = 1500;                    /* roughly 30 to 40 MB at most; the oldest go first */
const noCors = new Set();                   /* picture sites that do not allow saving a copy: they just load normally */

self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', e => e.waitUntil((async () => {
  for (const k of await caches.keys()) if (k.startsWith('palate-img-') && k !== IMG) await caches.delete(k);
  await self.clients.claim();
})()));

self.addEventListener('fetch', e => {
  const r = e.request;
  if (r.method !== 'GET' || r.destination !== 'image') return;
  let u; try { u = new URL(r.url); } catch (_) { return; }
  if (u.protocol !== 'https:') return;
  e.respondWith(image(r, u));
});

async function image(req, u) {
  const cache = await caches.open(IMG);
  const hit = await cache.match(req.url);
  if (hit) return hit;
  if (!noCors.has(u.host)) {
    try {
      const res = await fetch(req.url, { mode: 'cors', credentials: 'omit' });
      if (res.ok) { cache.put(req.url, res.clone()).then(() => trim(cache)).catch(() => {}); }
      return res;
    } catch (_) { noCors.add(u.host); }
  }
  return fetch(req);
}
async function trim(cache) {
  const keys = await cache.keys();
  for (let i = 0; i < keys.length - MAX_IMAGES; i++) await cache.delete(keys[i]);
}

/* Notifications */
self.addEventListener('push', e => {
  let d = {};
  try { d = e.data ? e.data.json() : {}; } catch (_) { d = { body: e.data ? e.data.text() : '' }; }
  e.waitUntil(self.registration.showNotification(d.title || 'Palate', {
    body: d.body || '',
    icon: 'icons/icon-192.png',
    badge: 'icons/badge-96.png',
    tag: d.tag || 'palate-friends',
    data: { url: d.url || './#friends' }
  }));
});
self.addEventListener('notificationclick', e => {
  e.notification.close();
  const url = new URL((e.notification.data && e.notification.data.url) || './', self.registration.scope).href;
  e.waitUntil((async () => {
    const all = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    for (const c of all) {
      if (c.url.startsWith(self.registration.scope)) { await c.focus(); try { await c.navigate(url); } catch (_) {} return; }
    }
    await self.clients.openWindow(url);
  })());
});
