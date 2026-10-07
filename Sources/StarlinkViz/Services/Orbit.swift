import Foundation

/// Minimal orbit math so the starter builds with zero dependencies.
///
/// PRODUCTION WARNING: this is a simplified circular-orbit propagator derived
/// from TLE mean motion / inclination / RAAN / mean anomaly. It is fine for
/// demonstrating sky-plot + map plumbing, but for real handover analysis swap
/// the inside of `propagate()` for full SGP4 (add an SPM SGP4 package; the
/// `OverheadFilter.rankedCandidates()` signature stays unchanged).
enum Orbit {
    static let earthRadiusKm = 6371.0
    static let mu = 398600.4418 // km^3/s^2

    struct Elements {
        var inclinationDeg: Double
        var raanDeg: Double
        var meanAnomalyDeg: Double
        var meanMotionRevPerDay: Double
        var epochDayOfYear: Double
    }

    static func parseElements(_ tle: TLE) -> Elements? {
        // TLE columns (1-indexed): L1 cols 21-32 epoch day, L2 cols 9-16 incl,
        // 18-25 RAAN, 44-51 mean anomaly, 53-63 mean motion.
        func slice(_ s: String, _ from: Int, _ to: Int) -> String {
            guard s.count >= to else { return "" }
            let a = s.index(s.startIndex, offsetBy: from - 1)
            let b = s.index(s.startIndex, offsetBy: to)
            return String(s[a ..< b])
        }
        guard let incl = Double(slice(tle.line2, 9, 16).trimmingCharacters(in: .whitespaces)),
              let raan = Double(slice(tle.line2, 18, 25).trimmingCharacters(in: .whitespaces)),
              let ma = Double(slice(tle.line2, 44, 51).trimmingCharacters(in: .whitespaces)),
              let mm = Double(slice(tle.line2, 53, 63).trimmingCharacters(in: .whitespaces))
        else { return nil }
        let epoch = Double(slice(tle.line1, 21, 32).trimmingCharacters(in: .whitespaces)) ?? 1
        return Elements(
            inclinationDeg: incl, raanDeg: raan, meanAnomalyDeg: ma,
            meanMotionRevPerDay: mm, epochDayOfYear: epoch
        )
    }

    /// Subsatellite point at `date` (days-since-epoch approximated from wall clock).
    static func propagate(_ tle: TLE, observer: ObserverLocation, date: Date = Date()) -> SatellitePosition? {
        guard let el = parseElements(tle), el.meanMotionRevPerDay > 0 else { return nil }
        let periodMin = 1440.0 / el.meanMotionRevPerDay
        let nRadS = 2 * .pi / (periodMin * 60)

        // Elapsed minutes this year -> advance mean anomaly (wraps).
        // macOS 14-compatible day-of-year (Calendar.dayOfYear needs macOS 15).
        let cal = Calendar(identifier: .gregorian)
        let startOfYear = cal.date(from: cal.dateComponents([.year], from: date)) ?? date
        let dayOfYear = (cal.dateComponents([.day], from: startOfYear, to: date).day ?? 0) + 1
        let hm = cal.dateComponents([.hour, .minute, .second], from: date)
        let nowDoy = Double(dayOfYear) + Double(hm.hour ?? 0) / 24
            + Double(hm.minute ?? 0) / 1440 + Double(hm.second ?? 0) / 86400
        var dtMin = (nowDoy - el.epochDayOfYear) * 1440
        if dtMin < 0 { dtMin = dtMin.truncatingRemainder(dividingBy: periodMin) + periodMin }

        let ma = (el.meanAnomalyDeg * .pi / 180 + nRadS * dtMin * 60).truncatingRemainder(dividingBy: 2 * .pi)
        // Circular orbit: E ≈ M.
        let incl = el.inclinationDeg * .pi / 180
        let raan = el.raanDeg * .pi / 180
        // Argument of latitude for circular orbit.
        let u = ma
        let x = cos(raan) * cos(u) - sin(raan) * sin(u) * cos(incl)
        let y = sin(raan) * cos(u) + cos(raan) * sin(u) * cos(incl)
        let z = sin(u) * sin(incl)

        let a = pow(mu / pow(nRadS, 2), 1.0 / 3.0) // semi-major axis km
        let altKm = max(300, a - earthRadiusKm)

        // Earth rotation: crude GMST from unix time.
        let gmst = fmod(280.46061837 + 360.98564736629 * (date.timeIntervalSince1970 / 86400) + 360, 360) * .pi / 180
        var lon = atan2(y, x) - gmst
        while lon > .pi { lon -= 2 * .pi }
        while lon < -.pi { lon += 2 * .pi }
        let lat = asin(max(-1, min(1, z)))

        let latDeg = lat * 180 / .pi
        let lonDeg = lon * 180 / .pi
        let look = lookAngles(
            satLat: latDeg, satLon: lonDeg, satAltKm: altKm,
            obsLat: observer.latitude, obsLon: observer.longitude, obsAltM: observer.altitudeM
        )
        return SatellitePosition(
            id: tle.noradId, name: tle.name,
            latitude: latDeg, longitude: lonDeg, altitudeKm: altKm,
            azimuthDeg: look.az, elevationDeg: look.el, rangeKm: look.range
        )
    }

    /// Subsatellite track around `center`: past + future positions for drawing
    /// a motion trail. Returns (lat, lon) pairs oldest → newest.
    static func track(_ tle: TLE, observer: ObserverLocation, center: Date = Date(),
                      spanSec: Double = 300, stepSec: Double = 30) -> [(lat: Double, lon: Double)]
    {
        var pts: [(Double, Double)] = []
        var t = -spanSec
        while t <= spanSec {
            if let p = propagate(tle, observer: observer, date: center.addingTimeInterval(t)) {
                pts.append((p.latitude, p.longitude))
            }
            t += stepSec
        }
        return pts
    }
    /// Synthetic mock satellites so Sky/Map tabs are demonstrable when TLE
    /// data is thin (e.g. only the 3 bundled samples, none overhead).
    /// Deterministic in `date` with a ~90 min period, so they glide
    /// continuously. Clearly labeled DEMO- — never real NORAD IDs.
    static func demoSats(observer: ObserverLocation, date: Date = Date(), count: Int = 8) -> [SatellitePosition] {
        let period: Double = 5400
        let t = date.timeIntervalSince1970 / period
        let latR = observer.latitude * .pi / 180
        var out: [SatellitePosition] = []
        for i in 0 ..< count {
            let f = Double(i) / Double(count)
            let az = fmod(360 * (t + f) + 45 * Double(i), 360)
            let el = 38 + 27 * sin(2 * .pi * (t + f) + Double(i))
            let azR = az * .pi / 180
            let lat = observer.latitude + 6 * cos(azR)
            let lon = observer.longitude + 6 * sin(azR) / max(0.3, cos(latR))
            out.append(SatellitePosition(
                id: -(i + 1), name: String(format: "DEMO-%02d", i + 1),
                latitude: lat, longitude: lon, altitudeKm: 550,
                azimuthDeg: az < 0 ? az + 360 : az,
                elevationDeg: el, rangeKm: 900,
                isCandidate: false
            ))
        }
        out.sort { $0.elevationDeg > $1.elevationDeg }
        for i in out.indices { out[i].isCandidate = i < 3 }
        return out
    }

    private static func lookAngles(satLat: Double, satLon: Double, satAltKm: Double,
                                   obsLat: Double, obsLon: Double, obsAltM: Double) -> (az: Double, el: Double, range: Double)
    {
        let d2r = Double.pi / 180
        let slat = satLat * d2r, slon = satLon * d2r
        let olat = obsLat * d2r, olon = obsLon * d2r
        let R = earthRadiusKm + obsAltM / 1000
        let r = earthRadiusKm + satAltKm
        let sx = r * cos(slat) * cos(slon), sy = r * cos(slat) * sin(slon), sz = r * sin(slat)
        let ox = R * cos(olat) * cos(olon), oy = R * cos(olat) * sin(olon), oz = R * sin(olat)
        let dx = sx - ox, dy = sy - oy, dz = sz - oz
        let range = sqrt(dx * dx + dy * dy + dz * dz)
        // ENU frame.
        let e = -sin(olon) * dx + cos(olon) * dy
        let n = -sin(olat) * cos(olon) * dx - sin(olat) * sin(olon) * dy + cos(olat) * dz
        let u = cos(olat) * cos(olon) * dx + cos(olat) * sin(olon) * dy + sin(olat) * dz
        let el = asin(max(-1, min(1, u / range))) / d2r
        var az = atan2(e, n) / d2r
        if az < 0 { az += 360 }
        return (az, el, range)
    }
}

// MARK: - Overhead ranking

enum OverheadFilter {
    /// Starlink serves roughly above ~25° elevation. Rank by elevation, flag top 3.
    static func rankedCandidates(
        tles: [TLE], observer: ObserverLocation,
        minElevationDeg: Double = 25, limit: Int = 40, date: Date = Date()
    ) -> [SatellitePosition] {
        var sats: [SatellitePosition] = []
        sats.reserveCapacity(min(tles.count, 2000))
        for tle in tles.prefix(8000) {
            if let p = Orbit.propagate(tle, observer: observer, date: date),
               p.elevationDeg >= minElevationDeg
            {
                sats.append(p)
            }
        }
        sats.sort { $0.elevationDeg > $1.elevationDeg }
        var top = Array(sats.prefix(limit))
        for i in top.indices { top[i].isCandidate = i < 3 }
        return top
    }
}
