'use strict';

const OFFSETS = [
  { ms: 24 * 60 * 60 * 1000, label: '24 hours'  },
  { ms:      60 * 60 * 1000, label: '1 hour'     },
  { ms:           5 * 60 * 1000, label: '5 minutes' },
];

const COMPASS = ['N','NNE','NE','ENE','E','ESE','SE','SSE','S','SSW','SW','WSW','W','WNW','NW','NNW'];
const compass = az => COMPASS[Math.round(az / 22.5) % 16];

let pending = [];  // setTimeout IDs

self.addEventListener('install',  () => self.skipWaiting());
self.addEventListener('activate', e  => e.waitUntil(self.clients.claim()));

// ── Message from page ──────────────────────────────────────────────────────────
self.addEventListener('message', event => {
  if (event.data?.type === 'SCHEDULE') {
    reschedule(event.data.passes);
  }
});

function reschedule(passes) {
  pending.forEach(clearTimeout);
  pending = [];

  const now    = Date.now();
  const timeFmt = new Intl.DateTimeFormat('en', { hour: 'numeric', minute: '2-digit' });

  for (const pass of passes) {
    for (const { ms, label } of OFFSETS) {
      const fireAt = pass.start - ms;
      const delay  = fireAt - now;
      if (delay <= 0) continue;

      const id = setTimeout(() => {
        const startDate = new Date(pass.start);
        self.registration.showNotification(`ISS Pass in ${label}`, {
          body:             `${timeFmt.format(startDate)} · Max ${pass.peakEl.toFixed(0)}° · ${compass(pass.startAz)} → ${compass(pass.endAz)}`,
          tag:              `iss-${pass.start}-${ms}`,
          requireInteraction: ms === 5 * 60 * 1000,
          data:             { url: '/' },
        });
      }, delay);

      pending.push(id);
    }
  }
}

// ── Notification tap ───────────────────────────────────────────────────────────
self.addEventListener('notificationclick', event => {
  event.notification.close();
  event.waitUntil(
    clients.matchAll({ type: 'window', includeUncontrolled: true }).then(list => {
      for (const client of list) {
        if ('focus' in client) return client.focus();
      }
      return clients.openWindow(event.notification.data?.url || '/');
    })
  );
});
