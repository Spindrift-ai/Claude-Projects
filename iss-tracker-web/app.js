'use strict';

// ── Config ─────────────────────────────────────────────────────────────────────
const TLE_URL_PRIMARY  = 'https://tle.ivanstanojevic.me/api/tle/25544';
const TLE_URL_FALLBACK = 'https://api.wheretheiss.at/v1/satellites/25544/tles';
const MIN_ELEV_DEG     = 10;
const PASS_DAYS        = 7;
const STEP_SEC         = 10;
const UPDATE_MS        = 5000;
const TLE_TTL_MS       = 3600 * 1000;

// ── State ──────────────────────────────────────────────────────────────────────
let map, issMarker, userMarker, trackLine, passTrackLine;
let satrec = null;
let tleLine1 = null, tleLine2 = null;
let userLat = null, userLon = null;
let passes  = [];
let passesComputing = false;
let passRefreshTimer = null;
let weatherData = null;

// ── Boot ───────────────────────────────────────────────────────────────────────
document.addEventListener('DOMContentLoaded', () => {
  console.log('[ISS] DOMContentLoaded');
  registerSW();
  initMap();
  initTabs();
  loadSavedState();
  console.log('[ISS] location after loadSavedState:', userLat, userLon);
  fetchTLE().then(() => {
    console.log('[ISS] TLE ready, satrec:', !!satrec, 'userLat:', userLat);
    startTracking();
    if (userLat !== null) recomputePasses();
  }).catch(e => console.error('[ISS] fetchTLE rejected:', e));
  refreshNotifUI();
  detectIOS();
});

// ── Service Worker ─────────────────────────────────────────────────────────────
function registerSW() {
  if ('serviceWorker' in navigator) {
    navigator.serviceWorker.register('sw.js')
      .then(reg => console.log('SW registered', reg.scope))
      .catch(e  => console.warn('SW failed', e));
  }
}

// ── Map ────────────────────────────────────────────────────────────────────────
function initMap() {
  map = L.map('map', { center: [20, 0], zoom: 2, zoomControl: true, attributionControl: false });

  L.tileLayer('https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}{r}.png', {
    subdomains: 'abcd', maxZoom: 19
  }).addTo(map);

  const issIcon = L.divIcon({
    html: '<div class="iss-marker"></div>',
    iconSize: [18, 18], iconAnchor: [9, 9], className: ''
  });
  issMarker   = L.marker([20, 0], { icon: issIcon }).addTo(map);
  trackLine   = L.polyline([], { color: '#4a9eff', weight: 1.5, opacity: .5, dashArray: '5 4' }).addTo(map);
  passTrackLine = L.polyline([], { color: '#f7e04a', weight: 2, opacity: .35, dashArray: '8 5' }).addTo(map);
}

// ── TLE ────────────────────────────────────────────────────────────────────────
async function fetchTLE() {
  const cachedTLE = localStorage.getItem('tle');
  const cachedAt  = Number(localStorage.getItem('tle_at') || 0);
  if (cachedTLE && (Date.now() - cachedAt) < TLE_TTL_MS) {
    const { line1, line2 } = JSON.parse(cachedTLE);
    tleLine1 = line1; tleLine2 = line2;
    satrec = satellite.twoline2satrec(line1, line2);
    setTLEAge(cachedAt);
    scheduleNextTLEFetch();
    return;
  }
  await doFetchTLE();
}

async function doFetchTLE() {
  let line1, line2;
  console.log('[ISS] fetching TLE from primary…');
  try {
    const r    = await fetch(TLE_URL_PRIMARY);
    const data = await r.json();
    line1 = data.line1; line2 = data.line2;
    console.log('[ISS] primary TLE ok, line1 length:', line1 && line1.length);
  } catch (e1) {
    console.warn('[ISS] primary TLE failed:', e1);
    try {
      console.log('[ISS] trying fallback TLE…');
      const r    = await fetch(TLE_URL_FALLBACK);
      const data = await r.json();
      line1 = data.line1; line2 = data.line2;
      console.log('[ISS] fallback TLE ok');
    } catch (e) {
      console.error('[ISS] both TLE sources failed:', e);
      setStatus('TLE unavailable – retrying…');
      setTimeout(doFetchTLE, 60000);
      return;
    }
  }
  tleLine1 = line1; tleLine2 = line2;
  satrec = satellite.twoline2satrec(line1, line2);
  const now = Date.now();
  localStorage.setItem('tle', JSON.stringify({ line1, line2 }));
  localStorage.setItem('tle_at', String(now));
  setTLEAge(now);
  scheduleNextTLEFetch();
  // Recompute passes with fresh TLE
  if (userLat !== null) recomputePasses();
}

function scheduleNextTLEFetch() { setTimeout(doFetchTLE, TLE_TTL_MS); }

function setTLEAge(fetchedAtMs) {
  const mins = Math.round((Date.now() - fetchedAtMs) / 60_000);
  document.getElementById('tle-age').textContent =
    mins < 2 ? 'Just now' : mins < 60 ? `${mins} min ago` : `${Math.round(mins/60)}h ago`;
}

// ── Live Tracking ──────────────────────────────────────────────────────────────
function startTracking() {
  updatePosition();
  setInterval(updatePosition, UPDATE_MS);
}

function updatePosition() {
  if (!satrec) return;
  const now    = new Date();
  const posVel = satellite.propagate(satrec, now);
  if (!posVel?.position) return;

  const gmst = satellite.gstime(now);
  const geod = satellite.eciToGeodetic(posVel.position, gmst);
  const lat  = satellite.degreesLat(geod.latitude);
  const lon  = satellite.degreesLong(geod.longitude);
  const alt  = geod.height;   // km
  const spd  = Math.sqrt(posVel.velocity.x**2 + posVel.velocity.y**2 + posVel.velocity.z**2) * 3600;

  // Map
  issMarker.setLatLng([lat, lon]);
  appendTrackPoint(lat, lon);

  // Telemetry
  setText('t-alt', alt.toFixed(1) + ' km');
  setText('t-vel', Math.round(spd).toLocaleString() + ' km/h');
  setText('t-lat', lat.toFixed(2) + '°');
  setText('t-lon', lon.toFixed(2) + '°');
  document.getElementById('live-dot').classList.add('live');

  // Status
  if (userLat !== null) {
    const el = getElevation(posVel.position, gmst, userLat, userLon);
    setStatus(el > 0 ? `Visible – ${el.toFixed(1)}° above your horizon` : 'Below your horizon');
  } else {
    setStatus('Live · Open Settings to set your location');
  }
}

function appendTrackPoint(lat, lon) {
  const pts = trackLine.getLatLngs();
  if (pts.length > 0) {
    const last = pts[pts.length - 1];
    if (Math.abs(lon - last.lng) > 100) { trackLine.setLatLngs([]); }  // antimeridian reset
  }
  const p = trackLine.getLatLngs();
  p.push(L.latLng(lat, lon));
  if (p.length > 90) p.shift();
  trackLine.setLatLngs(p);
}

function getElevation(posEci, gmst, lat, lon) {
  const obs    = { longitude: satellite.degreesToRadians(lon), latitude: satellite.degreesToRadians(lat), height: 0 };
  const posEcf = satellite.eciToEcf(posEci, gmst);
  const look   = satellite.ecfToLookAngles(obs, posEcf);
  return satellite.radiansToDegrees(look.elevation);
}

// ── Pass Computation ───────────────────────────────────────────────────────────

// Low-precision solar ECI unit vector (~0.5° accuracy, sufficient for day/night)
function sunEciUnit(date) {
  const jd  = date.getTime() / 86400000 + 2440587.5;
  const n   = jd - 2451545.0;
  const L   = (280.460 + 0.9856474 * n) % 360;
  const g   = ((357.528 + 0.9856003 * n) % 360) * Math.PI / 180;
  const lam = (L + 1.915 * Math.sin(g) + 0.020 * Math.sin(2 * g)) * Math.PI / 180;
  const eps = 23.439 * Math.PI / 180;
  return { x: Math.cos(lam), y: Math.cos(eps) * Math.sin(lam), z: Math.sin(eps) * Math.sin(lam) };
}

// Sun elevation (degrees) at observer — negative means night
function sunElevDeg(date, latDeg, lonDeg) {
  const sun  = sunEciUnit(date);
  const gmst = satellite.gstime(date);
  const cg = Math.cos(gmst), sg = Math.sin(gmst);
  const sx = sun.x * cg + sun.y * sg;
  const sy = -sun.x * sg + sun.y * cg;
  const sz = sun.z;
  const latR = latDeg * Math.PI / 180, lonR = lonDeg * Math.PI / 180;
  const dot  = Math.cos(latR) * Math.cos(lonR) * sx +
               Math.cos(latR) * Math.sin(lonR) * sy +
               Math.sin(latR) * sz;
  return Math.asin(Math.max(-1, Math.min(1, dot))) * 180 / Math.PI;
}

// Returns true if the satellite ECI position (km) is in sunlight (not in Earth's umbra)
function issInSunlight(posEci, sunUnit) {
  const dot = posEci.x * sunUnit.x + posEci.y * sunUnit.y + posEci.z * sunUnit.z;
  if (dot > 0) return true;  // satellite on the sun-facing side
  const r2    = posEci.x ** 2 + posEci.y ** 2 + posEci.z ** 2;
  const perp2 = r2 - dot * dot;
  return perp2 > 6371 * 6371;  // outside Earth's shadow cylinder
}

// ── Weather (Open-Meteo, free, no key) ────────────────────────────────────────
async function fetchWeather(lat, lon) {
  try {
    const url = `https://api.open-meteo.com/v1/forecast?latitude=${lat}&longitude=${lon}&hourly=cloud_cover&timezone=auto&forecast_days=7`;
    const r = await fetch(url);
    weatherData = (await r.json()).hourly;
    console.log('[ISS] weather ok');
  } catch (e) { console.warn('[ISS] weather fetch failed:', e); weatherData = null; }
}

function getCloudCoverAt(date) {
  if (!weatherData) return null;
  const t = date.getTime();
  let best = null, bestDiff = Infinity;
  for (let i = 0; i < weatherData.time.length; i++) {
    const diff = Math.abs(new Date(weatherData.time[i]).getTime() - t);
    if (diff < bestDiff) { bestDiff = diff; best = weatherData.cloud_cover[i]; }
  }
  return best;
}

// ── Geocoding (Nominatim / OpenStreetMap) ─────────────────────────────────────
async function geocodeAddress(query) {
  try {
    const url = 'https://nominatim.openstreetmap.org/search?q=' + encodeURIComponent(query) + '&format=json&limit=1';
    const r = await fetch(url, { headers: { 'Accept-Language': 'en' } });
    const data = await r.json();
    if (data && data.length > 0) {
      // Shorten display name: take first two comma-separated parts
      const parts = data[0].display_name.split(',');
      const name = parts.slice(0, 2).join(',').trim();
      return { lat: parseFloat(data[0].lat), lon: parseFloat(data[0].lon), name };
    }
    return null;
  } catch (e) { return null; }
}

// Async chunked pass computation — yields to browser every 1000 steps so iOS stays responsive
async function computePassesAsync(lat, lon) {
  if (!satrec) return [];
  const obs = { longitude: satellite.degreesToRadians(lon), latitude: satellite.degreesToRadians(lat), height: 0 };
  const now = Date.now();
  const end = now + PASS_DAYS * 86400000;
  const result = [];
  let inPass = false, cur = null;
  let step = 0;

  for (let t = now; t < end; t += STEP_SEC * 1000) {
    // Yield to the browser every 1000 iterations to prevent UI freeze
    if (step++ % 1000 === 0) await new Promise(r => setTimeout(r, 0));

    const date   = new Date(t);
    const pv     = satellite.propagate(satrec, date);
    if (!pv || !pv.position) continue;
    const gmst   = satellite.gstime(date);
    const posEcf = satellite.eciToEcf(pv.position, gmst);
    const look   = satellite.ecfToLookAngles(obs, posEcf);
    const el     = satellite.radiansToDegrees(look.elevation);
    const az     = satellite.radiansToDegrees(look.azimuth);

    if (el >= MIN_ELEV_DEG) {
      if (!inPass) {
        inPass = true;
        cur = { start: date, peak: date, peakEl: el, peakAz: az,
                startAz: az, endAz: az, peakPosEci: pv.position };
      } else {
        if (el > cur.peakEl) { cur.peak = date; cur.peakEl = el; cur.peakAz = az; cur.peakPosEci = pv.position; }
        cur.endAz = az;
      }
    } else if (inPass) {
      inPass = false;
      cur.end = date;
      const sunVec    = sunEciUnit(cur.peak);
      const obsInDark = sunElevDeg(cur.peak, lat, lon) < 0;
      const issLit    = issInSunlight(cur.peakPosEci, sunVec);
      if (obsInDark && issLit) result.push(cur);
      cur = null;
    }
  }
  return result;
}

async function recomputePasses() {
  console.log('[ISS] recomputePasses — userLat:', userLat, 'satrec:', !!satrec, 'computing:', passesComputing);
  if (userLat === null || !satrec) { renderPasses(); return; }
  if (passesComputing) return;
  passesComputing = true;
  renderPasses();
  setStatus('Computing passes…');

  try {
    console.log('[ISS] starting computePassesAsync…');
    passes = await computePassesAsync(userLat, userLon);
    console.log('[ISS] computation done — passes found:', passes.length);
    await fetchWeather(userLat, userLon);
    for (const p of passes) p.cloudPct = getCloudCoverAt(p.peak);
  } catch (e) {
    console.error('[ISS] pass computation error:', e);
    passes = [];
  } finally {
    passesComputing = false;
  }

  drawNextPassTrack();
  renderPasses();
  scheduleNotifications();
  if (passRefreshTimer) clearInterval(passRefreshTimer);
  passRefreshTimer = setInterval(recomputePasses, 30 * 60000);
}

// Draw the next upcoming pass ground track on the map
function drawNextPassTrack() {
  passTrackLine.setLatLngs([]);
  const next = passes.find(p => p.end > new Date());
  if (!next || !satrec) return;

  const pts = [];
  const step = 15_000; // 15s steps
  for (let t = next.start.getTime() - 2 * 60_000; t <= next.end.getTime() + 2 * 60_000; t += step) {
    const pv = satellite.propagate(satrec, new Date(t));
    if (!pv?.position) continue;
    const gmst = satellite.gstime(new Date(t));
    const geod = satellite.eciToGeodetic(pv.position, gmst);
    pts.push([satellite.degreesLat(geod.latitude), satellite.degreesLong(geod.longitude)]);
  }
  // Handle antimeridian: split segments
  const segments = [[]];
  for (let i = 0; i < pts.length; i++) {
    const seg = segments[segments.length - 1];
    if (seg.length > 0 && Math.abs(pts[i][1] - seg[seg.length - 1][1]) > 100) {
      segments.push([]);
    }
    segments[segments.length - 1].push(pts[i]);
  }
  passTrackLine.setLatLngs(segments);
}

// ── Passes Rendering ───────────────────────────────────────────────────────────
const COMPASS = ['N','NNE','NE','ENE','E','ESE','SE','SSE','S','SSW','SW','WSW','W','WNW','NW','NNW'];
const compass  = az => COMPASS[Math.round(az / 22.5) % 16];
function passRating(maxEl, durSec, cloudPct) {
  const base = maxEl >= 75 ? 5 : maxEl >= 55 ? 4 : maxEl >= 35 ? 3 : maxEl >= 18 ? 2 : 1;
  const bonus = (durSec >= 300 && maxEl >= 18 && maxEl < 75) ? 1 : 0;
  const penalty = (cloudPct == null) ? 0 : cloudPct >= 80 ? 2 : cloudPct >= 50 ? 1 : 0;
  return Math.max(1, Math.min(5, base + bonus - penalty));
}
const ratingStars = r => '★'.repeat(r) + '☆'.repeat(5 - r);
const durFmt      = s => s >= 60 ? `${Math.floor(s/60)}m ${s % 60}s` : `${s}s`;
const cloudIcon   = pct => pct == null ? '' : pct < 20 ? '☀️' : pct < 50 ? '⛅' : pct < 80 ? '🌥️' : '☁️';

function renderPasses() {
  const el = document.getElementById('passes-content');

  // Defensive: try to recover location from localStorage if JS state was lost
  if (userLat === null) {
    try {
      const saved = localStorage.getItem('loc');
      if (saved) { const { lat, lon } = JSON.parse(saved); userLat = lat; userLon = lon; }
    } catch (e) {}
  }

  if (userLat === null) {
    el.innerHTML = `<div class="empty-state"><div class="empty-icon">📡</div><p>Set your location in Settings<br>to see upcoming passes</p></div>`;
    return;
  }
  if (!satrec) {
    el.innerHTML = `<div class="empty-state"><div class="empty-icon">⏳</div><p>Loading orbital data…<br><small style="color:var(--text2);font-size:13px">Fetching latest TLE from network</small></p><button class="btn btn-secondary" style="margin-top:16px;width:auto;padding:10px 24px" onclick="doFetchTLE()">Retry</button></div>`;
    return;
  }
  if (passesComputing) {
    el.innerHTML = `<div class="empty-state"><div class="empty-icon">🔄</div><p>Computing passes…<br><small style="color:var(--text2);font-size:13px">Scanning the next ${PASS_DAYS} days</small></p></div>`;
    return;
  }
  if (!passes.length) {
    el.innerHTML = `<div class="empty-state"><div class="empty-icon">🌙</div><p>No visible night passes<br>in the next ${PASS_DAYS} days</p><p style="font-size:13px;margin-top:8px;color:var(--text2)">Only passes where it's dark at your<br>location and the ISS is sunlit are shown</p><button class="btn btn-secondary" style="margin-top:16px;width:auto;padding:10px 24px" onclick="recomputePasses()">Refresh</button></div>`;
    return;
  }

  const now = Date.now();
  const timeFmt = new Intl.DateTimeFormat('en', { hour: 'numeric', minute: '2-digit' });
  const dayFmt  = new Intl.DateTimeFormat('en', { weekday: 'short', month: 'short', day: 'numeric' });

  let html = '';
  if (window.Notification?.permission !== 'granted') {
    html += `<div class="notif-cta">
      <div class="notif-cta-body">
        <strong>🔔 Get pass alerts</strong>
        <span>24 h, 1 h and 5 min ahead</span>
      </div>
      <button class="btn-inline" onclick="enableNotifications()">Enable</button>
    </div>`;
  }

  // Group by day
  const days = {};
  for (const p of passes) {
    const d = new Date(p.start); d.setHours(0, 0, 0, 0);
    const today = new Date(); today.setHours(0, 0, 0, 0);
    const tom   = new Date(today); tom.setDate(tom.getDate() + 1);
    const key   = +d === +today ? 'Today' : +d === +tom ? 'Tomorrow' : dayFmt.format(d);
    (days[key] = days[key] || []).push(p);
  }

  for (const [label, group] of Object.entries(days)) {
    html += `<div class="passes-day"><div class="day-label">${label}</div>`;
    for (const p of group) {
      const sec    = (p.start - now) / 1000;
      const isNow  = now >= p.start && now <= p.end;
      const durSec = Math.round((p.end - p.start) / 1000);
      const rating = passRating(p.peakEl, durSec, p.cloudPct);
      let badge;
      if (isNow)         badge = `<span class="pass-badge badge-now">NOW</span>`;
      else if (sec < 3600) badge = `<span class="pass-badge badge-soon">in ${Math.floor(sec / 60)}m</span>`;
      else if (sec < 86400) {
        const h = Math.floor(sec / 3600), m = Math.floor((sec % 3600) / 60);
        badge = `<span class="pass-badge badge-hours">in ${h}h ${m}m</span>`;
      } else badge = `<span class="pass-badge badge-days">in ${Math.floor(sec / 86400)}d</span>`;

      html += `<div class="pass-card r${rating}${isNow ? ' active-now' : ''}" onclick="openPassDetail(${passes.indexOf(p)})">
        <div class="pass-header">
          <span class="pass-time">${timeFmt.format(p.start)}</span>
          <div class="pass-meta">
            <span class="pass-quality q-r${rating}">${ratingStars(rating)}</span>
            ${badge}
          </div>
        </div>
        <div class="pass-details">
          <span>${compass(p.startAz)} → ${compass(p.endAz)}</span>
          <span>Max <strong>${p.peakEl.toFixed(0)}°</strong></span>
          <span>${durFmt(durSec)}</span>
          ${p.cloudPct != null ? `<span>${cloudIcon(p.cloudPct)} ${p.cloudPct}%</span>` : ''}
        </div>
      </div>`;
    }
    html += '</div>';
  }
  el.innerHTML = html;
}

// Refresh countdowns every minute
setInterval(() => { if (userLat !== null) renderPasses(); }, 60_000);

// ── Pass Detail Modal ──────────────────────────────────────────────────────────
function openPassDetail(idx) {
  const p = passes[idx];
  if (!p) return;
  const durSec = Math.round((p.end - p.start) / 1000);
  const rating = passRating(p.peakEl, durSec, p.cloudPct);
  const tf = new Intl.DateTimeFormat('en', { hour: 'numeric', minute: '2-digit' });
  const df = new Intl.DateTimeFormat('en', { weekday: 'long', month: 'long', day: 'numeric' });
  const cloudStr = p.cloudPct == null ? 'Weather unavailable'
    : `${cloudIcon(p.cloudPct)} ${p.cloudPct}% — ${p.cloudPct < 20 ? 'Clear skies' : p.cloudPct < 50 ? 'Partly cloudy' : p.cloudPct < 80 ? 'Mostly cloudy' : 'Overcast'}`;
  const visNote = p.cloudPct >= 80 ? 'Heavy cloud cover — ISS may not be visible.' : p.cloudPct >= 50 ? 'Moderate cloud cover may reduce visibility.' : '';

  document.getElementById('pass-detail-content').innerHTML = `
    <div class="det-header">
      <div class="det-date">${df.format(p.start)}</div>
      <div class="det-time">${tf.format(p.start)} – ${tf.format(p.end)}</div>
      <div class="det-stars q-r${rating}">${ratingStars(rating)}</div>
    </div>
    <div class="det-events">
      <div class="det-event">
        <div class="det-ev-label">Appears</div>
        <div class="det-ev-time">${tf.format(p.start)}</div>
        <div class="det-ev-dir">${compass(p.startAz)}</div>
      </div>
      <div class="det-event det-event-peak">
        <div class="det-ev-label">Peak</div>
        <div class="det-ev-time">${tf.format(p.peak)}</div>
        <div class="det-ev-dir">${compass(p.peakAz)}</div>
        <div class="det-ev-el">${p.peakEl.toFixed(0)}° up</div>
      </div>
      <div class="det-event">
        <div class="det-ev-label">Disappears</div>
        <div class="det-ev-time">${tf.format(p.end)}</div>
        <div class="det-ev-dir">${compass(p.endAz)}</div>
      </div>
    </div>
    <div class="det-stats">
      <div class="det-stat"><span>Duration</span><strong>${durFmt(durSec)}</strong></div>
      <div class="det-stat"><span>Max elevation</span><strong>${p.peakEl.toFixed(1)}°</strong></div>
      <div class="det-stat"><span>Cloud cover</span><strong>${cloudStr}</strong></div>
    </div>
    ${visNote ? `<div class="det-note">${visNote}</div>` : ''}
    <div class="det-guide">Face <strong>${compass(p.startAz)}</strong> at <strong>${tf.format(p.start)}</strong> and look toward the horizon. Track the ISS as it arcs to <strong>${p.peakEl.toFixed(0)}°</strong> in the <strong>${compass(p.peakAz)}</strong>.</div>
  `;
  document.getElementById('pass-detail-overlay').classList.add('open');
}

function closePassDetail() {
  document.getElementById('pass-detail-overlay').classList.remove('open');
}

// ── Notifications ──────────────────────────────────────────────────────────────
async function enableNotifications() {
  if (!('Notification' in window)) {
    alert('Notifications are not supported in this browser.\n\nOn iPhone, add this page to your Home Screen first, then open it from there.');
    return;
  }
  const perm = await window.Notification.requestPermission();
  refreshNotifUI();
  if (perm === 'granted') {
    localStorage.setItem('notif', '1');
    scheduleNotifications();
  } else if (perm === 'denied') {
    alert('Notification permission denied. To fix this, go to your browser/phone settings and allow notifications for this site.');
  }
}

function scheduleNotifications() {
  if (window.Notification?.permission !== 'granted' || !passes.length) return;
  const payload = { type: 'SCHEDULE', passes: passes.map(p => ({
    start: p.start.getTime(), end: p.end.getTime(),
    peakEl: p.peakEl, startAz: p.startAz, endAz: p.endAz
  }))};
  navigator.serviceWorker?.ready.then(reg => reg.active?.postMessage(payload));
}

function refreshNotifUI() {
  const btn    = document.getElementById('btn-notif');
  const status = document.getElementById('notif-status');
  if (!('Notification' in window)) {
    btn.textContent = '🔔 Enable Pass Notifications';
    status.textContent = '';
    return;
  }
  if (window.Notification?.permission === 'granted') {
    btn.textContent = '✓ Notifications Enabled';
    btn.className   = 'btn on';
    btn.disabled    = true;
    status.textContent = 'You\'ll be alerted 24 h, 1 h, and 5 min before each pass.';
    status.className   = 'ok';
  } else if (window.Notification?.permission === 'denied') {
    btn.textContent  = 'Notifications Blocked';
    btn.className    = 'btn off';
    btn.disabled     = true;
    status.textContent = 'Enable notifications in your browser settings to receive alerts.';
    status.className   = 'err';
  }
}

// ── Location ───────────────────────────────────────────────────────────────────
function setLocation(lat, lon, displayName) {
  userLat = lat; userLon = lon;
  const locLabel = displayName || `${lat.toFixed(4)}°, ${lon.toFixed(4)}°`;
  localStorage.setItem('loc', JSON.stringify({ lat, lon, displayName: displayName || null }));

  document.getElementById('lat-input').value = lat.toFixed(4);
  document.getElementById('lon-input').value = lon.toFixed(4);
  document.getElementById('location-text').textContent = locLabel;
  document.getElementById('current-location').style.color = 'var(--text)';

  if (userMarker) map.removeLayer(userMarker);
  userMarker = L.circleMarker([lat, lon], {
    radius: 7, color: '#4a9eff', fillColor: '#4a9eff',
    fillOpacity: .85, weight: 2
  }).bindPopup('Your Location').addTo(map);

  recomputePasses();
}

function loadSavedState() {
  try {
    const raw = localStorage.getItem('loc');
    if (raw) {
      const { lat, lon, displayName } = JSON.parse(raw);
      const locLabel = displayName || `${lat.toFixed(4)}°, ${lon.toFixed(4)}°`;
      document.getElementById('lat-input').value = lat.toFixed(4);
      document.getElementById('lon-input').value = lon.toFixed(4);
      document.getElementById('location-text').textContent = locLabel;
      document.getElementById('current-location').style.color = 'var(--text)';
      userLat = lat; userLon = lon;
    }
  } catch (e) {
    console.warn('loadSavedState failed:', e);
  }
  try {
    if (localStorage.getItem('notif') === '1' && window.Notification?.permission === 'granted') {
      refreshNotifUI();
    }
  } catch (e) {}
}

// ── AR Sky View ───────────────────────────────────────────────────────────────
let arStream      = null;
let arAnimFrame   = null;
let arActive      = false;
let deviceHeading = null;   // compass bearing phone is pointing (0=N, 90=E)
let devicePitch   = null;   // elevation angle being looked at (degrees)

const AR_FOV_H = 65;   // approximate horizontal camera FOV (degrees)
const AR_FOV_V = 50;   // approximate vertical camera FOV (degrees)

async function startAR() {
  const prereq = document.getElementById('ar-prereq');

  if (userLat === null) {
    prereq.textContent = 'Set your location in Settings first.';
    return;
  }
  prereq.textContent = '';

  // Request camera
  try {
    arStream = await navigator.mediaDevices.getUserMedia({
      video: { facingMode: 'environment', width: { ideal: 1280 }, height: { ideal: 720 } },
      audio: false
    });
    const video = document.getElementById('ar-video');
    video.srcObject = arStream;
    await video.play();
  } catch (e) {
    prereq.textContent = 'Camera access denied. Allow camera in browser settings.';
    arStream = null;
    return;
  }

  // Request DeviceOrientationEvent permission (iOS 13+)
  if (typeof DeviceOrientationEvent !== 'undefined' &&
      typeof DeviceOrientationEvent.requestPermission === 'function') {
    try {
      const perm = await DeviceOrientationEvent.requestPermission();
      if (perm !== 'granted') {
        prereq.textContent = 'Motion sensor access denied. Enable in Settings > Safari.';
        stopAR();
        return;
      }
    } catch (e) {
      console.warn('[AR] orientation permission error:', e);
    }
  }

  // Listen to absolute orientation (Android) and regular (iOS webkitCompassHeading)
  window.addEventListener('deviceorientationabsolute', handleOrientation, true);
  window.addEventListener('deviceorientation', handleOrientation, true);
  arActive = true;
  document.getElementById('ar-start-overlay').style.display = 'none';
  document.getElementById('btn-ar-stop').style.display = 'block';
  resizeARCanvas();
  window.addEventListener('resize', resizeARCanvas);
  renderAR();
}

function stopAR() {
  arActive = false;
  if (arStream) { arStream.getTracks().forEach(t => t.stop()); arStream = null; }
  if (arAnimFrame) { cancelAnimationFrame(arAnimFrame); arAnimFrame = null; }
  window.removeEventListener('deviceorientationabsolute', handleOrientation, true);
  window.removeEventListener('deviceorientation', handleOrientation, true);
  window.removeEventListener('resize', resizeARCanvas);
  const video = document.getElementById('ar-video');
  video.srcObject = null;
  document.getElementById('ar-start-overlay').style.display = 'flex';
  document.getElementById('btn-ar-stop').style.display = 'none';
  deviceHeading = null; devicePitch = null;
}

function handleOrientation(e) {
  // Priority: iOS webkitCompassHeading → Android absolute alpha → plain alpha
  if (isFinite(e.webkitCompassHeading) && e.webkitCompassHeading >= 0) {
    // iOS: degrees clockwise from magnetic north, already true-north compensated
    deviceHeading = e.webkitCompassHeading;
  } else if ((e.absolute === true || e.type === 'deviceorientationabsolute') && isFinite(e.alpha)) {
    // Android absolute: alpha is CCW from geographic north → convert to CW
    deviceHeading = (360 - e.alpha) % 360;
  } else if (isFinite(e.alpha) && e.absolute !== false) {
    // Fallback: non-tagged alpha that may still be compass-relative on some browsers
    deviceHeading = (360 - e.alpha) % 360;
  }
  // beta = 90° → phone vertical, looking at horizon (0° elevation)
  // beta = 0°  → phone flat face-up, looking straight up (90° elevation)
  if (isFinite(e.beta)) {
    const b = Math.min(90, Math.max(0, Math.abs(e.beta)));
    devicePitch = 90 - b;
  }
}

function resizeARCanvas() {
  const canvas = document.getElementById('ar-canvas');
  const cont   = document.getElementById('ar-container');
  canvas.width  = cont.clientWidth;
  canvas.height = cont.clientHeight;
}

function getISSLookAngles() {
  if (!satrec || userLat === null) return null;
  const now    = new Date();
  const posVel = satellite.propagate(satrec, now);
  if (!posVel?.position) return null;
  const gmst   = satellite.gstime(now);
  const obs    = { longitude: satellite.degreesToRadians(userLon), latitude: satellite.degreesToRadians(userLat), height: 0 };
  const posEcf = satellite.eciToEcf(posVel.position, gmst);
  const look   = satellite.ecfToLookAngles(obs, posEcf);
  return {
    az:    satellite.radiansToDegrees(look.azimuth),
    el:    satellite.radiansToDegrees(look.elevation),
    range: look.rangeSat
  };
}

function renderAR() {
  if (!arActive) return;
  arAnimFrame = requestAnimationFrame(renderAR);

  const canvas = document.getElementById('ar-canvas');
  const ctx    = canvas.getContext('2d');
  const W = canvas.width, H = canvas.height;
  ctx.clearRect(0, 0, W, H);

  const look = getISSLookAngles();

  // Update HUD
  const issAzEl = look ? `${compass(look.az)} ${look.az.toFixed(0)}°` : '—';
  const issElStr = look ? `${look.el.toFixed(1)}°` : '—';
  const hdgStr = deviceHeading != null ? `${compass(deviceHeading)} ${deviceHeading.toFixed(0)}°` : 'No sensor';
  document.getElementById('ar-iss-az').textContent = issAzEl;
  document.getElementById('ar-iss-el').textContent = issElStr;
  document.getElementById('ar-dev-az').textContent = hdgStr;

  if (!look) {
    drawARMsg(ctx, W, H, 'Waiting for ISS data…');
    return;
  }

  const issAz = look.az, issEl = look.el;

  if (deviceHeading === null) {
    drawARMsg(ctx, W, H, 'Waiting for compass…\nMove device in a figure-8 to calibrate');
    return;
  }

  // Compass rose overlay
  drawARCompass(ctx, W, H, deviceHeading, issAz);

  if (issEl <= 0) {
    drawARMsg(ctx, W, H, 'ISS is below the horizon');
    return;
  }

  // Project ISS onto screen
  let deltaAz = issAz - deviceHeading;
  if (deltaAz > 180) deltaAz -= 360;
  if (deltaAz < -180) deltaAz += 360;
  const deltaEl = issEl - (devicePitch ?? 0);

  const x = W / 2 + (deltaAz / AR_FOV_H) * W;
  const y = H / 2 - (deltaEl / AR_FOV_V) * H;

  const margin = 60;
  const onScreen = x >= margin && x <= W - margin && y >= margin && y <= H - margin;

  if (onScreen) {
    drawARTarget(ctx, x, y, issEl);
  } else {
    drawARArrow(ctx, x, y, W, H, issEl);
  }
}

function drawARTarget(ctx, x, y, elev) {
  // Outer ring
  ctx.strokeStyle = '#4a9eff';
  ctx.lineWidth = 2;
  ctx.setLineDash([]);
  ctx.beginPath();
  ctx.arc(x, y, 42, 0, Math.PI * 2);
  ctx.stroke();

  // Corner tick marks only (crosshair feel)
  ctx.lineWidth = 2.5;
  ctx.strokeStyle = '#4a9eff';
  const gap = 48, len = 14;
  for (const [dx, dy] of [[-1,-1],[1,-1],[1,1],[-1,1]]) {
    ctx.beginPath();
    ctx.moveTo(x + dx * gap, y + dy * len);
    ctx.lineTo(x + dx * gap, y + dy * gap);
    ctx.lineTo(x + dx * len, y + dy * gap);
    ctx.stroke();
  }

  // Centre dot
  ctx.fillStyle = '#4a9eff';
  ctx.beginPath();
  ctx.arc(x, y, 5, 0, Math.PI * 2);
  ctx.fill();

  // Label
  ctx.fillStyle = '#fff';
  ctx.font = 'bold 14px -apple-system, sans-serif';
  ctx.textAlign = 'center';
  ctx.textBaseline = 'alphabetic';
  ctx.fillText('ISS', x, y - 56);
  ctx.fillStyle = '#4a9eff';
  ctx.font = '12px -apple-system, sans-serif';
  ctx.fillText(elev.toFixed(1) + '° above horizon', x, y - 41);
}

function drawARArrow(ctx, issX, issY, W, H, issEl) {
  const cx = W / 2, cy = H / 2;
  const angle = Math.atan2(issY - cy, issX - cx);
  const margin = 56;

  // Find intersection with viewport edge
  const cos = Math.cos(angle), sin = Math.sin(angle);
  const tx = cos > 0 ? (W - margin - cx) / cos : (margin - cx) / cos;
  const ty = sin > 0 ? (H - margin - cy) / sin : (margin - cy) / sin;
  const t  = Math.min(Math.abs(tx), Math.abs(ty));
  const ax = cx + cos * t;
  const ay = cy + sin * t;

  // Arrow
  ctx.save();
  ctx.translate(ax, ay);
  ctx.rotate(angle);
  ctx.strokeStyle = '#f7e04a';
  ctx.fillStyle   = '#f7e04a';
  ctx.lineWidth   = 2.5;
  ctx.setLineDash([]);

  ctx.beginPath();
  ctx.moveTo(-22, 0); ctx.lineTo(8, 0);
  ctx.stroke();

  ctx.beginPath();
  ctx.moveTo(22, 0);
  ctx.lineTo(9, -9); ctx.lineTo(9, 9);
  ctx.closePath(); ctx.fill();

  ctx.restore();

  // Label near arrow
  const lx = ax + Math.cos(angle + Math.PI) * 34;
  const ly = ay + Math.sin(angle + Math.PI) * 34;
  ctx.fillStyle = '#f7e04a';
  ctx.font = 'bold 12px -apple-system, sans-serif';
  ctx.textAlign = 'center';
  ctx.textBaseline = 'middle';
  ctx.fillText('ISS ' + issEl.toFixed(0) + '°', lx, ly);
}

function drawARMsg(ctx, W, H, msg) {
  ctx.fillStyle = 'rgba(0,0,0,.45)';
  ctx.beginPath();
  ctx.roundRect(W/2 - 160, H/2 - 30, 320, 60, 10);
  ctx.fill();
  ctx.fillStyle = 'rgba(255,255,255,.85)';
  ctx.font = '15px -apple-system, sans-serif';
  ctx.textAlign = 'center';
  ctx.textBaseline = 'middle';
  const lines = msg.split('\n');
  lines.forEach((l, i) => ctx.fillText(l, W/2, H/2 + (i - (lines.length-1)/2) * 22));
}

function drawARCompass(ctx, W, H, heading, issAz) {
  const cx = W / 2, cy = 52, r = 32;

  ctx.fillStyle = 'rgba(0,0,0,.55)';
  ctx.beginPath();
  ctx.arc(cx, cy, r + 6, 0, Math.PI * 2);
  ctx.fill();

  ctx.strokeStyle = 'rgba(255,255,255,.2)';
  ctx.lineWidth = 1;
  ctx.setLineDash([]);
  ctx.beginPath();
  ctx.arc(cx, cy, r, 0, Math.PI * 2);
  ctx.stroke();

  // Cardinal labels
  ctx.font = '10px -apple-system, sans-serif';
  ctx.textAlign = 'center';
  ctx.textBaseline = 'middle';
  for (const [label, az] of [['N',0],['E',90],['S',180],['W',270]]) {
    const relAngle = ((az - heading) * Math.PI / 180) - Math.PI / 2;
    const lx = cx + Math.cos(relAngle) * r * 0.72;
    const ly = cy + Math.sin(relAngle) * r * 0.72;
    ctx.fillStyle = label === 'N' ? '#ff5a5a' : 'rgba(255,255,255,.65)';
    ctx.fillText(label, lx, ly);
  }

  // ISS dot on compass ring
  const issAngle = ((issAz - heading) * Math.PI / 180) - Math.PI / 2;
  ctx.fillStyle = '#4a9eff';
  ctx.beginPath();
  ctx.arc(cx + Math.cos(issAngle) * (r - 5), cy + Math.sin(issAngle) * (r - 5), 4.5, 0, Math.PI * 2);
  ctx.fill();

  // Fixed heading pointer (triangle at top)
  ctx.fillStyle = 'rgba(255,255,255,.8)';
  ctx.beginPath();
  ctx.moveTo(cx, cy - r - 3);
  ctx.lineTo(cx - 5, cy - r + 6);
  ctx.lineTo(cx + 5, cy - r + 6);
  ctx.closePath(); ctx.fill();
}

// ── Tabs ───────────────────────────────────────────────────────────────────────
function initTabs() {
  document.querySelectorAll('.tab-btn').forEach(btn => {
    btn.addEventListener('click', () => {
      const prevActive = document.querySelector('.tab-btn.active');
      if (prevActive && prevActive.dataset.tab === 'ar') stopAR();
      document.querySelectorAll('.tab-btn,.tab-panel').forEach(el => el.classList.remove('active'));
      btn.classList.add('active');
      document.getElementById('panel-' + btn.dataset.tab).classList.add('active');
      if (btn.dataset.tab === 'passes') {
        // If we have location + TLE but no passes yet, trigger compute
        if (userLat !== null && satrec && !passes.length && !passesComputing) {
          recomputePasses();
        } else {
          renderPasses();
        }
      }
    });
  });
}

// ── iOS hint ───────────────────────────────────────────────────────────────────
function detectIOS() {
  const isIOS = /iPhone|iPad|iPod/.test(navigator.userAgent);
  const isStandalone = window.navigator.standalone;
  // Show "add to home screen" hint only on iOS Safari, not in standalone mode
  if (isIOS && !isStandalone) {
    document.getElementById('ios-hint').style.display = 'block';
  }
}

// ── Event Wiring ───────────────────────────────────────────────────────────────
document.getElementById('btn-detect').addEventListener('click', () => {
  if (!navigator.geolocation) { alert('Geolocation is not available.'); return; }
  setStatus('Getting your location…');
  navigator.geolocation.getCurrentPosition(
    p => setLocation(p.coords.latitude, p.coords.longitude),
    e => { setStatus('Location error'); alert(e.message); }
  );
});

document.getElementById('btn-set-location').addEventListener('click', () => {
  const lat = parseFloat(document.getElementById('lat-input').value);
  const lon = parseFloat(document.getElementById('lon-input').value);
  if (isNaN(lat) || lat < -90  || lat > 90)  { alert('Latitude must be between -90 and 90');   return; }
  if (isNaN(lon) || lon < -180 || lon > 180) { alert('Longitude must be between -180 and 180'); return; }
  setLocation(lat, lon);
});

document.getElementById('btn-notif').addEventListener('click', enableNotifications);

document.getElementById('btn-addr-search').addEventListener('click', async () => {
  const query = document.getElementById('addr-input').value.trim();
  if (!query) return;
  const status = document.getElementById('addr-status');
  status.textContent = 'Searching…'; status.className = 'addr-status';
  const result = await geocodeAddress(query);
  if (result) {
    status.textContent = result.name;
    status.className = 'addr-status';
    setLocation(result.lat, result.lon, result.name);
  } else {
    status.textContent = 'Location not found. Try a city name or ZIP code.';
    status.className = 'addr-status err';
  }
});

document.getElementById('addr-input').addEventListener('keydown', e => {
  if (e.key === 'Escape') { hideAddrSuggestions(); return; }
  if (e.key === 'Enter')  { document.getElementById('btn-addr-search').click(); return; }
});

document.getElementById('addr-input').addEventListener('input', () => {
  clearTimeout(addrSuggestTimer);
  const q = document.getElementById('addr-input').value.trim();
  if (q.length < 3) { hideAddrSuggestions(); return; }
  addrSuggestTimer = setTimeout(() => fetchAddrSuggestions(q), 380);
});

document.addEventListener('pointerdown', e => {
  if (!e.target.closest('.addr-wrap')) hideAddrSuggestions();
});

// ── Address autocomplete ───────────────────────────────────────────────────────
let addrSuggestTimer = null;

async function fetchAddrSuggestions(query) {
  try {
    const url = 'https://nominatim.openstreetmap.org/search?q=' +
      encodeURIComponent(query) + '&format=json&limit=5&addressdetails=0';
    const r = await fetch(url, { headers: { 'Accept-Language': 'en' } });
    const data = await r.json();
    renderAddrSuggestions(data);
  } catch (e) { /* network error — ignore */ }
}

function renderAddrSuggestions(results) {
  const box   = document.getElementById('addr-suggestions');
  const input = document.getElementById('addr-input');
  if (!results || results.length === 0) { hideAddrSuggestions(); return; }

  box.innerHTML = results.map(r => {
    const parts = r.display_name.split(',');
    const main  = parts[0].trim();
    const sub   = parts.slice(1, 3).join(',').trim();
    return `<div class="addr-sug-item"
                 data-lat="${r.lat}" data-lon="${r.lon}"
                 data-name="${sub ? main + ', ' + sub : main}">
      <div class="addr-sug-main">${escHtml(main)}</div>
      ${sub ? `<div class="addr-sug-sub">${escHtml(sub)}</div>` : ''}
    </div>`;
  }).join('');

  box.querySelectorAll('.addr-sug-item').forEach(item => {
    item.addEventListener('pointerdown', e => e.preventDefault()); // keep input focus
    item.addEventListener('click', () => {
      const name = item.dataset.name;
      input.value = name;
      document.getElementById('addr-status').textContent = name;
      document.getElementById('addr-status').className = 'addr-status';
      hideAddrSuggestions();
      setLocation(parseFloat(item.dataset.lat), parseFloat(item.dataset.lon), name);
    });
  });

  box.style.display = 'block';
  input.classList.add('has-suggestions');
}

function hideAddrSuggestions() {
  document.getElementById('addr-suggestions').style.display = 'none';
  document.getElementById('addr-input').classList.remove('has-suggestions');
}

function escHtml(s) {
  return s.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
}

document.getElementById('btn-ar-start').addEventListener('click', startAR);
document.getElementById('btn-ar-stop').addEventListener('click', stopAR);

// ── Pass Detail Modal ──────────────────────────────────────────────────────────
function openPassDetail(idx) {
  const p = passes[idx];
  if (!p) return;
  const durSec = Math.round((p.end - p.start) / 1000);
  const rating = passRating(p.peakEl, durSec, p.cloudPct);
  const tf = new Intl.DateTimeFormat('en', { hour: 'numeric', minute: '2-digit' });
  const df = new Intl.DateTimeFormat('en', { weekday: 'long', month: 'long', day: 'numeric' });
  const cloudStr = p.cloudPct == null
    ? 'Weather unavailable'
    : `${cloudIcon(p.cloudPct)} ${p.cloudPct}% — ${p.cloudPct < 20 ? 'Clear skies' : p.cloudPct < 50 ? 'Partly cloudy' : p.cloudPct < 80 ? 'Mostly cloudy' : 'Overcast'}`;
  const visNote = p.cloudPct != null && p.cloudPct >= 80 ? 'Heavy cloud cover — ISS may not be visible.'
                : p.cloudPct != null && p.cloudPct >= 50 ? 'Moderate cloud cover may reduce visibility.' : '';

  document.getElementById('pass-detail-content').innerHTML = `
    <div class="det-header">
      <div class="det-date">${df.format(p.start)}</div>
      <div class="det-time">${tf.format(p.start)} – ${tf.format(p.end)}</div>
      <div class="det-stars q-r${rating}">${ratingStars(rating)}</div>
    </div>
    <div class="det-events">
      <div class="det-event">
        <div class="det-ev-label">Appears</div>
        <div class="det-ev-time">${tf.format(p.start)}</div>
        <div class="det-ev-dir">${compass(p.startAz)}</div>
      </div>
      <div class="det-event det-event-peak">
        <div class="det-ev-label">Peak</div>
        <div class="det-ev-time">${tf.format(p.peak)}</div>
        <div class="det-ev-dir">${compass(p.peakAz)}</div>
        <div class="det-ev-el">${p.peakEl.toFixed(0)}° up</div>
      </div>
      <div class="det-event">
        <div class="det-ev-label">Disappears</div>
        <div class="det-ev-time">${tf.format(p.end)}</div>
        <div class="det-ev-dir">${compass(p.endAz)}</div>
      </div>
    </div>
    <div class="det-stats">
      <div class="det-stat"><span>Duration</span><strong>${durFmt(durSec)}</strong></div>
      <div class="det-stat"><span>Max elevation</span><strong>${p.peakEl.toFixed(1)}°</strong></div>
      <div class="det-stat"><span>Cloud cover</span><strong>${cloudStr}</strong></div>
    </div>
    ${visNote ? `<div class="det-note">${visNote}</div>` : ''}
    <div class="det-guide">Face <strong>${compass(p.startAz)}</strong> at <strong>${tf.format(p.start)}</strong> and look toward the horizon. Track the ISS as it arcs to <strong>${p.peakEl.toFixed(0)}°</strong> in the <strong>${compass(p.peakAz)}</strong>.</div>
  `;
  document.getElementById('pass-detail-overlay').classList.add('open');
}

function closePassDetail() {
  document.getElementById('pass-detail-overlay').classList.remove('open');
}

// ── Helpers ────────────────────────────────────────────────────────────────────
function setStatus(msg) { document.getElementById('status-text').textContent = msg; }
function setText(id, val) { document.getElementById(id).textContent = val; }
