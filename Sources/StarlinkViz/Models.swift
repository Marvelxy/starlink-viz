import Foundation
import MapKit

// MARK: - Dish link models (mirrors local gRPC getStatus/getHistory fields)

enum DishState: String, Codable {
    case connected = "CONNECTED"
    case searching = "SEARCHING"
    case bootstrapping = "BOOTSTRAPPING"
    case stowed = "STOWED"
    case thermalShutdown = "THERMAL_SHUTDOWN"
    case noSats = "NO_SATS"
    case obstructedState = "OBSTRUCTED"
    case noDownlink = "NO_DOWNLINK"
    case noPings = "NO_PINGS"
    case offline = "OFFLINE"
    case unknown = "UNKNOWN"
}

struct DishAlertsState: Codable {
    var motorsStuck = false
    var thermalThrottle = false
    var thermalShutdown = false
    var obstructed = false
}

/// Polar obstruction grid from the dish.
/// - wedges: 12 azimuthal wedges from `wedge_fraction_obstructed` (0.0–1.0 each).
///   Wedge i covers azimuth [i*30°, (i+1)*30°), 0° = North, clockwise.
/// - pixels: optional full 2-D map (row-major, 0.0 clear → 1.0 blocked) once you
///   enable a firmware exposing DishGetObstructionMap. Nil on older protosets.
struct ObstructionMap: Codable {
    var wedges: [Double] // 12 values
    var pixels: [Double]? // width*height or nil
    var pixelsWidth: Int = 0
    var pixelsHeight: Int = 0

    static let clear = ObstructionMap(wedges: Array(repeating: 0, count: 12))

    /// Mean blocked fraction across wedges.
    var meanBlocked: Double {
        guard !wedges.isEmpty else { return 0 }
        return wedges.reduce(0, +) / Double(wedges.count)
    }

    /// Wedge index (0–11) for an azimuth in degrees.
    static func wedgeIndex(forAzimuthDeg az: Double) -> Int {
        var a = az.truncatingRemainder(dividingBy: 360)
        if a < 0 { a += 360 }
        return min(11, Int(a / 30))
    }

    /// Is this look direction (az) considered blocked? Threshold default 30%.
    func isBlocked(azimuthDeg: Double, threshold: Double = 0.3) -> Bool {
        guard wedges.count == 12 else { return false }
        return wedges[Self.wedgeIndex(forAzimuthDeg: azimuthDeg)] >= threshold
    }
}

struct DishStatusSample: Identifiable, Codable {
    var id: Date { timestamp }
    let timestamp: Date
    var state: DishState
    /// Signal-to-noise ratio in dB (typical 0–12).
    var snr: Double
    var pingLatencyMs: Double
    /// 0.0–1.0 fraction of pings dropped in window.
    var pingDropRate: Double
    var downlinkMbps: Double
    var uplinkMbps: Double
    var obstructed: Bool
    var obstructionFraction: Double
    /// 12 wedge fractions, 0.0–1.0. Empty = unknown (older sample).
    var wedgeFractionObstructed: [Double] = []
    var alerts = DishAlertsState()
    /// Seconds since last outage of that class; large = healthy.
    var secondsSinceOutage1s: Double
    var secondsSinceOutage2s: Double
    var secondsSinceOutage5s: Double
    /// Raw `state` value as the dish sent it ("" for mock/synthetic).
    /// Shown when `state` is .unknown so unrecognized values are diagnosable.
    var stateRaw: String = ""
    /// True when the link looks usable despite what the `state` label says.
    /// Newer firmware parks `state` at UNKNOWN (and SNR at 0) even on healthy
    /// links, so the real signal is: no outage object + no ping loss.
    /// (Matches starlink-grpc-tools, which derives CONNECTED from absent outage.)
    var linkLooksUp: Bool {
        outageCause.isEmpty && pingDropRate < 0.4
            && state != .offline && state != .thermalShutdown
    }
    // MARK: - Dish identity & service flags (Real dish; "" / 0 when absent)
    var hardwareVersion: String = ""
    var softwareVersion: String = ""
    var uptimeS: Double = 0
    /// `outage.cause` (e.g. NO_SCHEDULE) — absent when no outage.
    var outageCause: String = ""
    /// `disablement_code` (e.g. OKAY, NO_ACTIVE_ACCOUNT) — the money field
    /// when a dish won't serve. Absent/UNKNOWN on older firmware.
    var disablementCode: String = ""

    var obstructionMap: ObstructionMap {
        ObstructionMap(wedges: wedgeFractionObstructed.count == 12 ? wedgeFractionObstructed : Array(repeating: 0, count: 12))
    }
}

struct OutageEvent: Identifiable {
    let id = UUID()
    let timestamp: Date
    let durationClass: String // "1s+", "2s+", "5s+"
    let note: String
}

// MARK: - Satellite models (from CelesTrak TLE)

struct TLE: Codable, Hashable {
    var name: String
    var line1: String
    var line2: String
    var noradId: Int
}

struct SatellitePosition: Identifiable {
    let id: Int // noradId
    var name: String
    var latitude: Double
    var longitude: Double
    var altitudeKm: Double
    /// Observer-centric look angles.
    var azimuthDeg: Double
    var elevationDeg: Double
    var rangeKm: Double
    var isCandidate: Bool = false
}

struct ObserverLocation: Codable {
    var latitude: Double = 37.7749
    var longitude: Double = -122.4194
    var altitudeM: Double = 10
}
