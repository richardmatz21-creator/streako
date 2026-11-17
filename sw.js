// Streako Service Worker – zeigt Push-Benachrichtigungen an.
// (Kein Offline-Cache: die App lädt immer frisch.)
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', e => e.waitUntil(self.clients.claim()));

self.addEventListener('push', e => {
  let d = {};
  try { d = e.data ? e.data.json() : {}; } catch (_) { d = { body: e.data ? e.data.text() : '' }; }
  e.waitUntil((async () => {
    await self.registration.showNotification(d.title || 'Streako', {
      body: d.body || '',
      icon: 'apple-touch-icon.png',
      badge: 'apple-touch-icon.png',
      tag: d.tag || undefined,
      data: { url: self.registration.scope },
    });
    // Offene App sofort aktualisieren
    const wins = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    wins.forEach(c => c.postMessage('refresh'));
  })());
});

self.addEventListener('notificationclick', e => {
  e.notification.close();
  e.waitUntil((async () => {
    const wins = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    for (const c of wins) { if ('focus' in c) return c.focus(); }
    return self.clients.openWindow((e.notification.data && e.notification.data.url) || './');
  })());
});
