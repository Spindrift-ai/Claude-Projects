'use strict';

importScripts('https://cdn.jsdelivr.net/npm/satellite.js@4.1.3/dist/satellite.min.js');

const MIN_ELEV_DEG = 10;
const STEP_SEC     = 10;
const PASS_DAYS    = 7;

function sunEciUnit(date) {
  const jd  = date.getTime() / 86400000 + 2440587.5;
  const n   = jd - 2451545.0;
  const L   = (280.460 + 0.9856474 * n) % 360;
  const g   = ((357.528 + 0.9856003 * n) % 360) * Math.PI / 180;
  const lam = (L + 1.915 * Math.sin(g) + 0.020 * Math.sin(2 * g)) * Math.PI / 180;
  const eps = 23.439 * Math.PI / 180;
  return { x: Math.cos(lam), y: Math.cos(eps) * Math.sin(lam), z: Math.sin(eps) * Math.sin(lam) };
}

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

function issInSunlight(posEci, sunUnit) {
  const dot = posEci.x * sunUnit.x + posEci.y * sunUnit.y + posEci.z * sunUnit.z;
  if (dot > 0) return true;
  const r2    = posEci.x * posEci.x + posEci.y * posEci.y + posEci.z * posEci.z;
  const perp2 = r2 - dot * dot;
  return perp2 > 6371 * 6371;
}

function computePasses(lat, lon, satrec) {
  const obs = {
    longitude: satellite.degreesToRadians(lon),
    latitude:  satellite.degreesToRadians(lat),
    height: 0
  };
  const now = Date.now();
  const end = now + PASS_DAYS * 86400000;
  const result = [];
  let inPass = false, cur = null;

  for (let t = now; t < end; t += STEP_SEC * 1000) {
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
        cur = { start: t, peak: t, peakEl: el, peakAz: az,
                startAz: az, endAz: az, peakPosEci: pv.position };
      } else {
        if (el > cur.peakEl) {
          cur.peak = t; cur.peakEl = el; cur.peakAz = az;
          cur.peakPosEci = pv.position;
        }
        cur.endAz = az;
      }
    } else if (inPass) {
      inPass = false;
      cur.end = t;
      const sunVec    = sunEciUnit(new Date(cur.peak));
      const obsInDark = sunElevDeg(new Date(cur.peak), lat, lon) < 0;
      const issLit    = issInSunlight(cur.peakPosEci, sunVec);
      if (obsInDark && issLit) result.push(cur);
      cur = null;
    }
  }
  return result;
}

self.onmessage = function (e) {
  try {
    const { lat, lon, line1, line2 } = e.data;
    const satrec = satellite.twoline2satrec(line1, line2);
    const passes = computePasses(lat, lon, satrec);
    self.postMessage({ passes });
  } catch (err) {
    self.postMessage({ error: String(err) });
  }
};
