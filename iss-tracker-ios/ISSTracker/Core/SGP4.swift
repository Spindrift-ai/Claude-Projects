// SGP4.swift
// Swift port of the satellite.js SGP4 propagator
// Original algorithm: Vallado et al., "Revisiting Spacetrack Report #3", AIAA 2006-6753
// satellite.js: Shashwat Kandadai — MIT License

import Foundation

// MARK: - Public Types

struct ECIVector {
    let x, y, z: Double   // km
}

struct ECIState {
    let position: ECIVector  // km
    let velocity: ECIVector  // km/s
}

struct GeodeticCoord {
    let latitude: Double    // radians
    let longitude: Double   // radians
    let altitude: Double    // km
}

struct GeodeticObserver {
    let latitude: Double    // radians
    let longitude: Double   // radians
    let altitude: Double    // km (above ellipsoid)
}

struct LookAngles {
    let azimuth: Double     // radians  [0, 2π)
    let elevation: Double   // radians  (-π/2, π/2]
    let range: Double       // km
}

// MARK: - SGP4 Constants

private let twoPi   = 2.0 * Double.pi
private let x2o3    = 2.0 / 3.0
private let xke     = 0.07436691613317   // √(GM/Re³) rad/min
private let j2      = 1.082616e-3
private let j3      = -2.53881e-6
private let j4      = -1.655970e-6
private let j3oj2   = j3 / j2
private let Re      = 6378.137           // km
private let sConst  = 1.0 + 78.0 / Re   // s* (Earth radii)
private let qzms2t  = pow((120.0 - 78.0) / Re, 4.0)  // (q₀ - s*)⁴
private let temp4   = 1.5e-12
private let vkmpersec = Re * xke / 60.0  // ≈ 7.9054 km/s per unit velocity

// MARK: - Internal Satellite Record

private struct SatRec {
    // ── From TLE ──────────────────────────────────
    var bstar, ecco, argpo, inclo, mo, no_kozai, nodeo: Double
    var jdsatepoch: Double

    // ── Derived by init ────────────────────────────
    var a, alta, altp, no_unkozai: Double

    // trig values of inclination
    var cosio, cosio2, sinio: Double

    // orbit shape
    var omeosq, betao2, rteosq, posq, rp: Double

    // perturbation constants
    var con41, con42, x1mth2, x7thm1: Double

    // drag coefficients
    var cc1, cc3, cc4, cc5: Double
    var d2, d3, d4: Double
    var t2cof, t3cof, t4cof, t5cof: Double

    // secular / mean element rates
    var mdot, argpdot, nodedot: Double
    var nodecf: Double

    // long-period coefficients
    var eta: Double
    var omgcof, xmcof: Double
    var delmo, sinmao: Double
    var xlcof, aycof: Double

    // flags
    var isimp: Int
    var error: Int

    init(bstar: Double, ecco: Double, argpo: Double, inclo: Double,
         mo: Double, no_kozai: Double, nodeo: Double, jdsatepoch: Double) {
        self.bstar = bstar; self.ecco = ecco; self.argpo = argpo
        self.inclo = inclo; self.mo = mo; self.no_kozai = no_kozai
        self.nodeo = nodeo; self.jdsatepoch = jdsatepoch

        a = 0; alta = 0; altp = 0; no_unkozai = 0
        cosio = 0; cosio2 = 0; sinio = 0
        omeosq = 0; betao2 = 0; rteosq = 0; posq = 0; rp = 0
        con41 = 0; con42 = 0; x1mth2 = 0; x7thm1 = 0
        cc1 = 0; cc3 = 0; cc4 = 0; cc5 = 0
        d2 = 0; d3 = 0; d4 = 0
        t2cof = 0; t3cof = 0; t4cof = 0; t5cof = 0
        mdot = 0; argpdot = 0; nodedot = 0; nodecf = 0
        eta = 0; omgcof = 0; xmcof = 0; delmo = 0; sinmao = 0
        xlcof = 0; aycof = 0
        isimp = 0; error = 0
    }
}

// MARK: - Public SGP4 Propagator

final class SGP4Propagator {
    private var satrec: SatRec
    let epochDate: Date

    /// Initialise from two TLE lines.  Returns nil if TLE is malformed.
    init?(tle: TLEData) {
        guard let (sr, epoch) = SGP4Propagator.parseTLE(tle) else { return nil }
        satrec = sr
        epochDate = epoch
        SGP4Propagator.initSatRec(&satrec)
    }

    /// Propagate to `date`. Returns nil on numerical failure.
    func propagate(to date: Date) -> ECIState? {
        let tsince = date.timeIntervalSince(epochDate) / 60.0   // → minutes
        return SGP4Propagator.sgp4(satrec: satrec, tsince: tsince)
    }
}

// MARK: - TLE Parsing

private extension SGP4Propagator {

    static func parseTLE(_ tle: TLEData) -> (SatRec, Date)? {
        let l1 = Array(tle.line1)
        let l2 = Array(tle.line2)
        guard l1.count >= 69, l2.count >= 69 else { return nil }

        func str(_ chars: [Character], _ a: Int, _ b: Int) -> String {
            String(chars[a..<min(b, chars.count)]).trimmingCharacters(in: .whitespaces)
        }
        func dbl(_ s: String) -> Double { Double(s) ?? 0 }

        // ── Line 1 ────────────────────────────────────
        let epochYr2    = Int(str(l1, 18, 20)) ?? 0
        let epochDay    = dbl(str(l1, 20, 32))
        let epochYear   = epochYr2 < 57 ? 2000 + epochYr2 : 1900 + epochYr2

        let bstarMant   = dbl(str(l1, 53, 59))           // e.g. 26629
        let bstarExpStr = str(l1, 59, 61)                 // e.g. "-4"
        let bstarExp    = dbl(bstarExpStr)
        let bstar       = bstarMant * 1.0e-5 * pow(10.0, bstarExp)

        // ── Line 2 ────────────────────────────────────
        let inclo   = dbl(str(l2,  8, 16)) * .pi / 180.0
        let nodeo   = dbl(str(l2, 17, 25)) * .pi / 180.0
        let ecco    = dbl("0." + str(l2, 26, 33))
        let argpo   = dbl(str(l2, 34, 42)) * .pi / 180.0
        let mo      = dbl(str(l2, 43, 51)) * .pi / 180.0
        let no_kozai = dbl(str(l2, 52, 63)) * twoPi / 1440.0  // rev/day → rad/min

        // ── Epoch → Julian date ───────────────────────
        let epochDate = epochToDate(year: epochYear, dayOfYear: epochDay)
        let jd        = dateToJulian(epochDate)

        var sr = SatRec(bstar: bstar, ecco: ecco, argpo: argpo, inclo: inclo,
                        mo: mo, no_kozai: no_kozai, nodeo: nodeo, jdsatepoch: jd)
        return (sr, epochDate)
    }

    // day-of-year → Calendar date
    static func epochToDate(year: Int, dayOfYear: Double) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        var dc = DateComponents()
        dc.year = year; dc.month = 1; dc.day = 1
        let jan1 = cal.date(from: dc)!
        return jan1.addingTimeInterval((dayOfYear - 1.0) * 86400.0)
    }

    static func dateToJulian(_ date: Date) -> Double {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year,.month,.day,.hour,.minute,.second,.nanosecond], from: date)
        let sec = Double(c.second!) + Double(c.nanosecond!) / 1e9
        return jday(year: c.year!, month: c.month!, day: c.day!,
                    hour: c.hour!, minute: c.minute!, second: sec)
    }
}

// MARK: - SGP4 Initialisation

private extension SGP4Propagator {

    static func initSatRec(_ s: inout SatRec) {
        let eo = s.ecco
        let no = s.no_kozai

        // ── Trig values ────────────────────────────────
        s.cosio  = cos(s.inclo)
        s.cosio2 = s.cosio * s.cosio
        s.sinio  = sin(s.inclo)
        s.con41  = 3.0 * s.cosio2 - 1.0
        s.con42  = 1.0 - 5.0 * s.cosio2
        s.x1mth2 = 1.0 - s.cosio2

        // ── Recover mean motion from Kozai elements ────
        s.omeosq = 1.0 - eo * eo
        s.betao2 = s.omeosq
        s.rteosq = sqrt(s.betao2)

        let ak   = pow(xke / no, x2o3)
        let d1   = 0.75 * j2 * s.con41 / (s.rteosq * s.betao2 * ak * ak)
        let del1 = d1 * (1.0/3.0 + d1 * (1.0 + 134.0/81.0 * d1))
        let ao   = ak * (1.0 - del1)
        let del0 = 0.75 * j2 * s.con41 / (s.rteosq * s.betao2 * ao * ao)
        s.no_unkozai = no / (1.0 + del0)
        s.a     = pow(xke / s.no_unkozai, x2o3)
        s.alta  = s.a * (1.0 + eo) - 1.0
        s.altp  = s.a * (1.0 - eo) - 1.0

        let po  = s.a * s.betao2
        s.posq  = po * po
        s.rp    = s.a * (1.0 - eo)

        // ── s* and (q₀-s*)⁴ adjusted for perigee height ──
        let perigeeKm = (s.rp - 1.0) * Re
        let sfour: Double
        let qzms24: Double
        if perigeeKm < 98.0 {
            sfour   = 20.0 / Re + 1.0
            qzms24  = pow((120.0 - 20.0) / Re, 4.0)
        } else if perigeeKm < 156.0 {
            sfour   = (perigeeKm - 78.0) / Re + 1.0
            qzms24  = pow((120.0 - (perigeeKm - 78.0)) / Re, 4.0)
        } else {
            sfour   = sConst
            qzms24  = qzms2t
        }
        s.isimp = s.rp < (220.0 / Re + 1.0) ? 1 : 0

        // ── Drag & perturbation coefficients ──────────
        let tsi     = 1.0 / (s.a - sfour)
        s.eta       = s.a * eo * tsi
        let etasq   = s.eta * s.eta
        let eeta    = eo * s.eta
        let psisq   = abs(1.0 - etasq)
        let pinvsq  = 1.0 / s.posq
        let coef    = qzms24 * pow(tsi, 4.0)
        let coef1   = coef / pow(psisq, 3.5)

        let cc2 = coef1 * s.no_unkozai * (
            s.a * (1.0 + 1.5 * etasq + eeta * (4.0 + etasq)) +
            0.375 * j2 * tsi / psisq * s.con41 * (8.0 + 3.0 * etasq * (8.0 + etasq))
        )
        s.cc1 = s.bstar * cc2
        s.cc3 = (eo > 1e-4)
            ? -2.0 * qzms24 * tsi * j3oj2 * s.no_unkozai * s.sinio / eo
            : 0.0
        s.cc4 = 2.0 * s.no_unkozai * coef1 * s.a * s.betao2 * (
            s.eta * (2.0 + 0.5 * etasq) + eo * (0.5 + 2.0 * etasq) -
            j2 * tsi / (s.a * psisq) * (
                -3.0 * s.con41 * (1.0 - 2.0 * eeta + etasq * (1.5 - 0.5 * eeta)) +
                0.75 * s.x1mth2 * (2.0 * etasq - eeta * (1.0 + etasq)) * cos(2.0 * s.argpo)
            )
        )
        s.cc5 = 2.0 * coef1 * s.a * s.betao2 * (1.0 + 2.75 * (etasq + eeta) + eeta * etasq)

        // ── Secular rates ──────────────────────────────
        let cosio4 = s.cosio2 * s.cosio2
        let tmp1   = 1.5 * j2 * pinvsq * s.no_unkozai
        let tmp2   = 0.5 * tmp1 * j2 * pinvsq
        let tmp3   = -0.46875 * j4 * pinvsq * pinvsq * s.no_unkozai

        s.mdot    = s.no_unkozai +
            0.5 * tmp1 * s.rteosq * s.con41 +
            0.0625 * tmp2 * s.rteosq * (13.0 - 78.0 * s.cosio2 + 137.0 * cosio4)
        s.argpdot = -0.5 * tmp1 * s.con42 +
            0.0625 * tmp2 * (7.0 - 114.0 * s.cosio2 + 395.0 * cosio4) +
            tmp3 * (3.0 - 36.0 * s.cosio2 + 49.0 * cosio4)
        let xhdot1 = -tmp1 * s.cosio
        s.nodedot = xhdot1 + (
            0.5 * tmp2 * (4.0 - 19.0 * s.cosio2) +
            2.0 * tmp3 * (3.0 - 7.0 * s.cosio2)
        ) * s.cosio

        // ── Other coefficients ─────────────────────────
        s.omgcof  = s.bstar * s.cc3 * cos(s.argpo)
        s.xmcof   = (eo > 1e-4) ? -x2o3 * coef * s.bstar / eeta : 0.0
        s.nodecf  = 3.5 * s.betao2 * xhdot1 * s.cc1
        s.t2cof   = 1.5 * s.cc1
        s.x7thm1  = 7.0 * s.cosio2 - 1.0

        s.xlcof = (abs(s.cosio + 1.0) > temp4)
            ? -0.25 * j3oj2 * s.sinio * (3.0 + 5.0 * s.cosio) / (1.0 + s.cosio)
            : -0.25 * j3oj2 * s.sinio * (3.0 + 5.0 * s.cosio) / temp4
        s.aycof  = -0.5 * j3oj2 * s.sinio

        let dt    = 1.0 + s.eta * cos(s.mo)
        s.delmo   = dt * dt * dt
        s.sinmao  = sin(s.mo)

        // ── Higher-order drag terms (non-simplified case) ──
        if s.isimp == 0 {
            let cc1sq = s.cc1 * s.cc1
            s.d2 = 4.0 * s.a * tsi * cc1sq
            let t = s.d2 * tsi * s.cc1 / 3.0
            s.d3 = (17.0 * s.a + sfour) * t
            s.d4 = 0.5 * t * s.a * tsi * (221.0 * s.a + 31.0 * sfour) * s.cc1
            s.t3cof = s.d2 + 2.0 * cc1sq
            s.t4cof = 0.25 * (3.0 * s.d3 + s.cc1 * (12.0 * s.d2 + 10.0 * cc1sq))
            s.t5cof = 0.2 * (3.0 * s.d4 + 12.0 * s.cc1 * s.d3 +
                6.0 * s.d2 * s.d2 + 15.0 * cc1sq * (2.0 * s.d2 + cc1sq))
        }
    }
}

// MARK: - SGP4 Propagation

private extension SGP4Propagator {

    /// Core SGP4 propagator — near-Earth branch only (valid for ISS orbit).
    /// `tsince` is minutes since epoch.
    static func sgp4(satrec s: SatRec, tsince: Double) -> ECIState? {
        // ── Secular gravity & atmospheric drag ─────────
        let xmdf   = s.mo      + s.mdot    * tsince
        let argpdf = s.argpo   + s.argpdot * tsince
        let nodedf = s.nodeo   + s.nodedot * tsince
        var argpm  = argpdf
        var mm     = xmdf
        let t2     = tsince * tsince
        var nodem  = nodedf + s.nodecf * t2
        var tempa  = 1.0 - s.cc1 * tsince
        var tempe  = s.bstar * s.cc4 * tsince
        var templ  = s.t2cof * t2

        if s.isimp == 0 {
            let delmotemp = 1.0 + s.eta * cos(xmdf)
            let delm  = s.xmcof * (delmotemp * delmotemp * delmotemp - s.delmo)
            let delomg = s.omgcof * tsince
            let tmp    = delomg + delm
            mm    = xmdf + tmp
            argpm = argpdf - tmp
            let t3 = t2 * tsince
            let t4 = t3 * tsince
            tempa  -= s.d2 * t2 + s.d3 * t3 + s.d4 * t4
            tempe  += s.bstar * s.cc5 * (sin(mm) - s.sinmao)
            templ  += s.t3cof * t3 + t4 * (s.t4cof + tsince * s.t5cof)
        }

        let a = pow(s.no_unkozai * tempa, -x2o3) * tempa * tempa
        let e = s.ecco - tempe
        guard e > 0.0 && e < 1.0 else { return nil }

        let inclm = s.inclo
        let xl    = mm + argpm + nodem + s.no_unkozai * templ

        // ── Long-period periodics ───────────────────────
        let axnl  = e * cos(argpm)
        let tmp0  = 1.0 / (a * (1.0 - e * e))
        let aynl  = e * sin(argpm) + tmp0 * s.aycof
        let xl2   = xl + tmp0 * s.xlcof * axnl

        // ── Kepler's equation (eccentric longitude) ─────
        var eo1 = xl2.truncatingRemainder(dividingBy: twoPi)
        var sineo1 = sin(eo1)
        var coseo1 = cos(eo1)
        for _ in 0..<10 {
            let tem5 = 1.0 - coseo1 * axnl - sineo1 * aynl
            let tem6 = (xl2 - aynl * coseo1 + axnl * sineo1 - eo1) / tem5
            let clamped = max(-0.95, min(0.95, tem6))
            eo1 += clamped
            sineo1 = sin(eo1); coseo1 = cos(eo1)
            if abs(tem6) < 1e-12 { break }
        }

        // ── Short-period preliminary quantities ─────────
        let ecose  = axnl * coseo1 + aynl * sineo1
        let esine  = axnl * sineo1 - aynl * coseo1
        let el2    = axnl * axnl + aynl * aynl
        let pl     = a * (1.0 - el2)
        guard pl > 0 else { return nil }

        let rl     = a * (1.0 - ecose)
        let rdotl  = sqrt(a) * esine / rl
        let rvdotl = sqrt(pl) / rl
        let betal  = sqrt(1.0 - el2)
        let tmp1   = esine / (1.0 + betal)
        let cosu   = a / rl * (coseo1 - axnl + aynl * tmp1)
        let sinu   = a / rl * (sineo1 - aynl - axnl * tmp1)
        let su     = atan2(sinu, cosu)
        let sin2u  = 2.0 * cosu * sinu
        let cos2u  = 1.0 - 2.0 * sinu * sinu
        let t1     = 0.5 * j2 / pl
        let t2c    = t1 / pl

        // ── Short-period perturbations ───────────────────
        let mrt   = rl * (1.0 - 1.5 * t2c * betal * s.con41) +
                    0.5 * t1 * s.x1mth2 * cos2u
        let sfu   = su - 0.25 * t2c * (7.0 * betal - s.x7thm1) * sin2u
        let xnodes = nodem + 1.5 * t2c * s.cosio * cos2u
        let xinc  = inclm + 1.5 * t2c * s.cosio * s.sinio * cos2u
        let mvt   = rdotl - s.no_unkozai * t1 * s.x1mth2 * sin2u / xke
        let rvdot = rvdotl + s.no_unkozai * t1 *
                    (s.x1mth2 * cos2u + 1.5 * s.con41) / xke

        // ── Position & velocity in ECI ───────────────────
        let sinsu = sin(sfu), cossu = cos(sfu)
        let snod  = sin(xnodes), cnod = cos(xnodes)
        let sini  = sin(xinc),   cosi = cos(xinc)

        let xmx = -snod * cosi;  let xmy = cnod * cosi
        let ux  = xmx * sinsu + cnod * cossu
        let uy  = xmy * sinsu + snod * cossu
        let uz  = sini * sinsu
        let vx  = xmx * cossu - cnod * sinsu
        let vy  = xmy * cossu - snod * sinsu
        let vz  = sini * cossu

        return ECIState(
            position: ECIVector(
                x: mrt * ux * Re,
                y: mrt * uy * Re,
                z: mrt * uz * Re
            ),
            velocity: ECIVector(
                x: (mvt * ux + rvdot * vx) * vkmpersec,
                y: (mvt * uy + rvdot * vy) * vkmpersec,
                z: (mvt * uz + rvdot * vz) * vkmpersec
            )
        )
    }
}

// MARK: - Julian Day & Sidereal Time

func jday(year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Double) -> Double {
    return 367.0 * Double(year)
        - floor(7.0 * (Double(year) + floor((Double(month) + 9.0) / 12.0)) * 0.25)
        + floor(275.0 * Double(month) / 9.0)
        + Double(day)
        + 1721013.5
        + ((second / 60.0 + Double(minute)) / 60.0 + Double(hour)) / 24.0
}

/// Greenwich Mean Sidereal Time (radians) for a Julian date.
func gstime(jdut1: Double) -> Double {
    let tut1 = (jdut1 - 2451545.0) / 36525.0
    var gst = -6.2e-6 * tut1 * tut1 * tut1
            + 0.093104 * tut1 * tut1
            + (876600.0 * 3600.0 + 8640184.812866) * tut1
            + 67310.54841
    gst = (gst * (.pi / 180.0) / 240.0).truncatingRemainder(dividingBy: twoPi)
    if gst < 0 { gst += twoPi }
    return gst
}

/// GMST for a Swift Date.
func gstimeForDate(_ date: Date) -> Double {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    let c = cal.dateComponents([.year,.month,.day,.hour,.minute,.second,.nanosecond], from: date)
    let sec = Double(c.second!) + Double(c.nanosecond!) / 1e9
    let jd = jday(year: c.year!, month: c.month!, day: c.day!,
                  hour: c.hour!, minute: c.minute!, second: sec)
    return gstime(jdut1: jd)
}

// MARK: - Coordinate Transforms

/// ECI → ECF (Earth-Centred Fixed)
func eciToEcf(_ pos: ECIVector, gmst: Double) -> ECIVector {
    ECIVector(
        x:  pos.x * cos(gmst) + pos.y * sin(gmst),
        y: -pos.x * sin(gmst) + pos.y * cos(gmst),
        z:  pos.z
    )
}

/// ECI position → geodetic latitude, longitude, altitude
func eciToGeodetic(_ pos: ECIVector, gmst: Double) -> GeodeticCoord {
    let a  = Re
    let b  = 6356.7523142
    let f  = (a - b) / a
    let e2 = 2.0 * f - f * f
    let R  = sqrt(pos.x * pos.x + pos.y * pos.y)

    var lon = atan2(pos.y, pos.x) - gmst
    while lon < -.pi { lon += twoPi }
    while lon >  .pi { lon -= twoPi }

    var lat = atan2(pos.z, R)
    var C   = 1.0
    for _ in 0..<20 {
        C   = 1.0 / sqrt(1.0 - e2 * sin(lat) * sin(lat))
        lat = atan2(pos.z + a * C * e2 * sin(lat), R)
    }
    let alt: Double
    if abs(lat) > 1.0 {
        alt = pos.z / sin(lat) - a * C * (1.0 - e2)
    } else {
        alt = R / cos(lat) - a * C
    }
    return GeodeticCoord(latitude: lat, longitude: lon, altitude: alt)
}

/// Geodetic observer position in ECF (km)
private func geodeticToEcf(_ obs: GeodeticObserver) -> ECIVector {
    let a  = Re
    let b  = 6356.7523142
    let f  = (a - b) / a
    let e2 = 2.0 * f - f * f
    let C  = a / sqrt(1.0 - e2 * sin(obs.latitude) * sin(obs.latitude))
    return ECIVector(
        x: (C + obs.altitude) * cos(obs.latitude) * cos(obs.longitude),
        y: (C + obs.altitude) * cos(obs.latitude) * sin(obs.longitude),
        z: (C * (1.0 - e2) + obs.altitude) * sin(obs.latitude)
    )
}

/// ECF satellite position + geodetic observer → azimuth / elevation / range
func ecfToLookAngles(observer: GeodeticObserver, satelliteEcf: ECIVector) -> LookAngles {
    let obsEcf = geodeticToEcf(observer)
    let rx = satelliteEcf.x - obsEcf.x
    let ry = satelliteEcf.y - obsEcf.y
    let rz = satelliteEcf.z - obsEcf.z

    let sinLat = sin(observer.latitude);  let cosLat = cos(observer.latitude)
    let sinLon = sin(observer.longitude); let cosLon = cos(observer.longitude)

    let topS =  sinLat * cosLon * rx + sinLat * sinLon * ry - cosLat * rz
    let topE = -sinLon * rx + cosLon * ry
    let topZ =  cosLat * cosLon * rx + cosLat * sinLon * ry + sinLat * rz

    let range = sqrt(rx*rx + ry*ry + rz*rz)
    let elevation = asin(topZ / range)
    let azimuth   = (atan2(-topE, topS) + .pi).truncatingRemainder(dividingBy: twoPi)

    return LookAngles(azimuth: azimuth, elevation: elevation, range: range)
}
