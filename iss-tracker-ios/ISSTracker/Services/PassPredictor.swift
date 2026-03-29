import Foundation

/// Computes upcoming ISS passes over a ground observer using SGP4.
enum PassPredictor {

    /// Minimum elevation (degrees) for a pass to be considered visible.
    static let minElevationDeg = 10.0

    /// Step size in seconds for the integration loop.
    static let stepSeconds: Double = 10.0

    /// Predict all passes for the next `days` days.
    /// - Parameters:
    ///   - tle:     Current TLE data.
    ///   - lat:     Observer geodetic latitude  (degrees).
    ///   - lon:     Observer geodetic longitude (degrees).
    ///   - altM:    Observer altitude above WGS-84 (metres).
    ///   - days:    How many days ahead to search (default 7).
    /// - Returns: Array of ISSPass objects sorted by start time.
    static func computePasses(tle: TLEData,
                               lat: Double,
                               lon: Double,
                               altM: Double = 0,
                               days: Double = 7) -> [ISSPass] {

        guard let propagator = SGP4Propagator(tle: tle) else { return [] }

        let observer = GeodeticObserver(
            latitude:  lat * .pi / 180.0,
            longitude: lon * .pi / 180.0,
            altitude:  altM / 1000.0         // m → km
        )

        let minElevRad = minElevationDeg * .pi / 180.0
        let now        = Date()
        let endDate    = now.addingTimeInterval(days * 86400.0)
        let stepSec    = stepSeconds

        var passes: [ISSPass]  = []
        var inPass             = false

        // Accumulate values during a pass
        var passStart     = Date()
        var passPeak      = Date()
        var peakEl        = 0.0
        var peakAz        = 0.0
        var startAz       = 0.0
        var currentEndAz  = 0.0

        var t = now
        while t < endDate {
            guard let state = propagator.propagate(to: t) else {
                t = t.addingTimeInterval(stepSec)
                continue
            }
            let gmst   = gstimeForDate(t)
            let posEcf = eciToEcf(state.position, gmst: gmst)
            let look   = ecfToLookAngles(observer: observer, satelliteEcf: posEcf)

            if look.elevation >= minElevRad {
                let azDeg = look.azimuth * 180.0 / .pi
                if !inPass {
                    // Acquisition of signal
                    inPass     = true
                    passStart  = t
                    passPeak   = t
                    peakEl     = look.elevation
                    peakAz     = azDeg
                    startAz    = azDeg
                }
                if look.elevation > peakEl {
                    peakEl   = look.elevation
                    passPeak = t
                    peakAz   = azDeg
                }
                currentEndAz = azDeg

            } else if inPass {
                // Loss of signal
                inPass = false
                let pass = ISSPass(
                    start:        passStart,
                    peak:         passPeak,
                    end:          t,
                    maxElevation: peakEl * 180.0 / .pi,
                    startAzimuth: startAz,
                    peakAzimuth:  peakAz,
                    endAzimuth:   currentEndAz
                )
                passes.append(pass)
            }

            t = t.addingTimeInterval(stepSec)
        }

        return passes
    }
}
