import Foundation

/// Single seam for "talk to the dish". Mock works everywhere;
/// RealDishClient is where you drop in grpc-swift generated code.
protocol DishService {
    /// One status poll (1s cadence in production).
    func fetchStatus() async throws -> DishStatusSample
    /// Recent history ring (for the timeline). Mock synthesizes it.
    func fetchHistory() async throws -> [DishStatusSample]
    /// Polar obstruction grid (wedges now; pixels when firmware exposes them).
    func fetchObstructionMap() async throws -> ObstructionMap
}

extension DishService {
    func fetchObstructionMap() async throws -> ObstructionMap {
        try await fetchStatus().obstructionMap
    }
}

// MARK: - Mock (wandering signal + random dropouts so UI is demonstrable)

final class MockDishService: DishService {
    private var t: Double = 0

    func fetchStatus() async throws -> DishStatusSample {
        t += 1
        // Simulate occasional dropout every ~45s lasting a few seconds.
        let inOutage = Int(t) % 45 > 42
        let snr = inOutage ? Double.random(in: -1...1) : Double.random(in: 7...9.5)
        let drop: Double = inOutage ? Double.random(in: 0.4...1.0) : Double.random(in: 0...0.03)
        // One blocked wedge (SW) like a tree/building; worse during outage.
        var wedges = Array(repeating: 0.002, count: 12)
        wedges[7] = inOutage ? 0.65 : 0.35
        wedges[6] = 0.08
        return DishStatusSample(
            timestamp: Date(),
            state: inOutage ? .searching : .connected,
            snr: snr,
            pingLatencyMs: inOutage ? Double.random(in: 120...400) : Double.random(in: 22...38),
            pingDropRate: drop,
            downlinkMbps: inOutage ? Double.random(in: 0...5) : Double.random(in: 120...220),
            uplinkMbps: inOutage ? Double.random(in: 0...2) : Double.random(in: 15...30),
            obstructed: inOutage,
            obstructionFraction: 0.004,
            wedgeFractionObstructed: wedges,
            secondsSinceOutage1s: inOutage ? 0 : t,
            secondsSinceOutage2s: inOutage ? 0 : t,
            secondsSinceOutage5s: t
        )
    }

    func fetchHistory() async throws -> [DishStatusSample] {
        // 10 minutes of 1 sample / 2s for the starter timeline.
        var out: [DishStatusSample] = []
        let now = Date()
        let wedges = [0.002, 0.002, 0.003, 0.002, 0.004, 0.08, 0.08, 0.35, 0.01, 0.002, 0.002, 0.002]
        for i in stride(from: 300, through: 0, by: -2) {
            let outage = (i % 90) < 4
            out.append(DishStatusSample(
                timestamp: now.addingTimeInterval(Double(-i)),
                state: outage ? .searching : .connected,
                snr: outage ? 0.5 : 8.5,
                pingLatencyMs: outage ? 250 : 29,
                pingDropRate: outage ? 0.8 : 0.01,
                downlinkMbps: outage ? 2 : 170,
                uplinkMbps: outage ? 1 : 22,
                obstructed: outage,
                obstructionFraction: 0.004,
                wedgeFractionObstructed: wedges,
                secondsSinceOutage1s: outage ? 0 : Double(i),
                secondsSinceOutage2s: outage ? 0 : Double(i),
                secondsSinceOutage5s: Double(i)
            ))
        }
        return out
    }
}

// MARK: - Real dish via grpcurl bridge (no Swift gRPC dependency)
//
// The dish speaks gRPC at 192.168.100.1:9200, service
// `SpaceX.API.Device.Device/Handle` with `Request{get_status,get_history}`
// oneofs (fields 1004/1007) returning `dish_get_status` (2004) /
// `dish_get_history` (2006). Field numbers verified against
// starlink-community/starlink-grpc-go; vendored protoset: Proto/dish.protoset.
//
// Why grpcurl instead of grpc-swift here?
// - No protoc / codegen needed to get live data today.
// - `swift build` stays green with zero new SPM deps.
// - Native grpc-swift path is documented in Proto/NATIVE_GRPC.md for later.
// Requires: `brew install grpcurl` + same Starlink LAN.

import Foundation

final class RealDishClient: DishService {
    let host: String
    let port: Int
    init(host: String = "192.168.100.1", port: Int = 9200) {
        self.host = host; self.port = port
    }

    var address: String { "\(host):\(port)" }

    func fetchStatus() async throws -> DishStatusSample {
        try await fetchStatusWithRaw().0
    }

    /// Status plus the raw grpcurl JSON (truncated) for the in-app viewer.
    func fetchStatusWithRaw() async throws -> (DishStatusSample, String) {
        let json = try await GrpcURLBridge.call(
            address: address, payload: #"{"getStatus":{}}"#)
        let sample = try DishJSON.parseStatus(json, timestamp: Date())
        let raw = String(data: json, encoding: .utf8) ?? ""
        return (sample, String(raw.prefix(2000)))
    }

    func fetchHistory() async throws -> [DishStatusSample] {
        let json = try await GrpcURLBridge.call(
            address: address, payload: #"{"getHistory":{}}"#)
        return try DishJSON.parseHistory(json)
    }

    func fetchObstructionMap() async throws -> ObstructionMap {
        let s = try await fetchStatus()
        return s.obstructionMap
    }
}

/// Shells `grpcurl -plaintext -protoset Proto/dish.protoset -format json`.
enum GrpcURLBridge {
    static func protosetPath() throws -> String {
        if let env = ProcessInfo.processInfo.environment["STARLINK_PROTOSET"],
           !env.isEmpty, FileManager.default.fileExists(atPath: env)
        {
            return env
        }
        let fm = FileManager.default
        let candidates = [
            fm.currentDirectoryPath + "/Proto/dish.protoset",
            fm.currentDirectoryPath + "/StarlinkViz/Proto/dish.protoset",
            Bundle.main.bundlePath + "/Proto/dish.protoset",
            (Bundle.main.executablePath.map { ($0 as NSString).deletingLastPathComponent } ?? "") + "/Proto/dish.protoset",
        ]
        for c in candidates where fm.fileExists(atPath: c) { return c }
        throw DishError.missingProtoset(
            "Proto/dish.protoset not found. Set STARLINK_PROTOSET env or run from repo root.")
    }

    static func grpcurlBinary() throws -> String {
        for p in ["/opt/homebrew/bin/grpcurl", "/usr/local/bin/grpcurl", "/usr/bin/grpcurl"] {
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        // Fall back to PATH lookup.
        return "grpcurl"
    }

    static func call(address: String, payload: String) async throws -> Data {
        let bin = try grpcurlBinary()
        let protoset = try protosetPath()
        return try await withCheckedThrowingContinuation { cont in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: bin)
            proc.arguments = [
                "-plaintext", "-protoset", protoset,
                "-format", "json",
                "-emit-defaults",
                "-d", payload,
                address, "SpaceX.API.Device.Device/Handle",
            ]
            let out = Pipe(), err = Pipe()
            proc.standardOutput = out
            proc.standardError = err
            do { try proc.run() } catch {
                cont.resume(throwing: DishError.unreachable(
                    "Cannot launch grpcurl (\(bin)). Install with: brew install grpcurl. \(error.localizedDescription)"))
                return
            }
            proc.terminationHandler = { _ in
                let data = out.fileHandleForReading.readDataToEndOfFile()
                let errText = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                guard proc.terminationStatus == 0 else {
                    cont.resume(throwing: DishError.unreachable(
                        "grpcurl failed (is Mac on Starlink LAN? address \(address) reachable?). \(errText.prefix(300))"))
                    return
                }
                cont.resume(returning: data)
            }
        }
    }
}

/// Parses grpcurl JSON into app models. Tolerant of string-vs-number uint64/enums.
enum DishJSON {
    static func parseStatus(_ data: Data, timestamp: Date) throws -> DishStatusSample {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DishError.parse("Status: top-level JSON is not an object")
        }
        guard let s = root["dishGetStatus"] as? [String: Any] else {
            throw DishError.parse("Status: missing dishGetStatus (raw: \(String(data: data, encoding: .utf8)?.prefix(200) ?? "?"))")
        }
        guard !s.isEmpty else {
            throw DishError.parse("Dish returned an empty status — dish may be offline/booting, or this host:9200 may be the router rather than the dish")
        }
        let state = dishState(from: s["state"])
        let obs = s["obstructionStats"] as? [String: Any] ?? [:]
        let alerts = s["alerts"] as? [String: Any] ?? [:]
        let info = s["deviceInfo"] as? [String: Any] ?? [:]
        let devState = s["deviceState"] as? [String: Any] ?? [:]
        let outage = s["outage"] as? [String: Any] ?? [:]
        let wedges = doubleArray(obs["wedgeFractionObstructed"])
        let downBps = doubleVal(s["downlinkThroughputBps"])
        let upBps = doubleVal(s["uplinkThroughputBps"])
        return DishStatusSample(
            timestamp: timestamp,
            state: state,
            snr: doubleVal(s["snr"]),
            pingLatencyMs: doubleVal(s["popPingLatencyMs"]),
            pingDropRate: doubleVal(s["popPingDropRate"]),
            downlinkMbps: downBps / 1_000_000,
            uplinkMbps: upBps / 1_000_000,
            obstructed: boolVal(obs["currentlyObstructed"]),
            obstructionFraction: doubleVal(obs["fractionObstructed"]),
            wedgeFractionObstructed: wedges.count == 12 ? wedges : [],
            alerts: DishAlertsState(
                motorsStuck: boolVal(alerts["motorsStuck"]),
                thermalThrottle: boolVal(alerts["thermalThrottle"]),
                thermalShutdown: boolVal(alerts["thermalShutdown"]),
                obstructed: boolVal(obs["currentlyObstructed"])
            ),
            secondsSinceOutage1s: 0, secondsSinceOutage2s: 0, secondsSinceOutage5s: 0,
            stateRaw: stateRaw(from: s["state"]),
            hardwareVersion: stringVal(info["hardwareVersion"]),
            softwareVersion: stringVal(info["softwareVersion"]),
            uptimeS: doubleVal(devState["uptimeS"]),
            outageCause: stringVal(outage["cause"]),
            disablementCode: disablementName(from: s["disablementCode"])
        )
    }

    /// History arrays are ring buffers (~1 sample/sec). `current` is newest index.
    /// We map array order oldest→newest ending at now; 1s spacing.
    static func parseHistory(_ data: Data) throws -> [DishStatusSample] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let h = root["dishGetHistory"] as? [String: Any]
        else { throw DishError.parse("History: missing dishGetHistory") }
        let drops = doubleArray(h["popPingDropRate"])
        let lats = doubleArray(h["popPingLatencyMs"])
        let downs = doubleArray(h["downlinkThroughputBps"])
        let ups = doubleArray(h["uplinkThroughputBps"])
        let snrs = doubleArray(h["snr"])
        let obs = boolArray(h["obstructed"])
        let n = [drops.count, lats.count, downs.count, ups.count, snrs.count, obs.count].max() ?? 0
        guard n > 0 else { throw DishError.parse("History: all arrays empty") }
        let now = Date()
        // Cap to last 15 min for the timeline.
        let count = min(n, 900)
        var out: [DishStatusSample] = []
        out.reserveCapacity(count)
        for i in 0 ..< count {
            let src = n - count + i
            let drop = src < drops.count ? drops[src] : 0
            out.append(DishStatusSample(
                timestamp: now.addingTimeInterval(Double(i - count)),
                state: drop > 0.4 || (src < obs.count && obs[src]) ? .searching : .connected,
                snr: src < snrs.count ? snrs[src] : 0,
                pingLatencyMs: src < lats.count ? lats[src] : 0,
                pingDropRate: drop,
                downlinkMbps: (src < downs.count ? downs[src] : 0) / 1_000_000,
                uplinkMbps: (src < ups.count ? ups[src] : 0) / 1_000_000,
                obstructed: src < obs.count ? obs[src] : false,
                obstructionFraction: 0,
                secondsSinceOutage1s: 0, secondsSinceOutage2s: 0, secondsSinceOutage5s: 0
            ))
        }
        return out
    }

    // MARK: - tolerant JSON helpers

    static func dishState(from v: Any?) -> DishState {
        if let s = v as? String {
            // grpcurl prints proto enum names verbatim — accept prefixed
            // variants like STATE_CONNECTED as well as bare CONNECTED.
            var key = s.uppercased()
            if key.hasPrefix("STATE_") { key = String(key.dropFirst(6)) }
            switch key {
            case "CONNECTED", "ONLINE": return .connected
            case "SEARCHING", "NO_SCHEDULE": return .searching
            case "BOOTING", "BOOTSTRAPPING": return .bootstrapping
            case "STOWED": return .stowed
            case "THERMAL_SHUTDOWN": return .thermalShutdown
            case "NO_SATS": return .noSats
            case "OBSTRUCTED": return .obstructedState
            case "NO_DOWNLINK": return .noDownlink
            case "NO_PINGS": return .noPings
            case "OFFLINE": return .offline
            default: return .unknown
            }
        }
        if let n = v as? Int {
            switch n { case 1: return .connected
            case 2: return .searching
            case 3: return .bootstrapping
            default: return .unknown
            }
        }
        if let n = v as? NSNumber { return dishState(from: n.intValue) }
        return .unknown
    }

    /// Raw `state` value as the dish sent it — for diagnosing unrecognized
    /// states. Nil key → "(missing)".
    static func stateRaw(from v: Any?) -> String {
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        if v == nil { return "(missing)" }
        return "\(v!)"
    }

    static func doubleVal(_ v: Any?) -> Double {
        if let d = v as? Double { return d }
        if let f = v as? Float { return Double(f) }
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s) ?? 0 }
        return 0
    }

    static func boolVal(_ v: Any?) -> Bool {
        if let b = v as? Bool { return b }
        if let n = v as? NSNumber { return n.boolValue }
        return false
    }

    static func stringVal(_ v: Any?) -> String {
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return ""
    }

    /// `disablement_code` arrives as a proto enum name (or number on
    /// firmware that sends raw values). Names from the public proto.
    static func disablementName(from v: Any?) -> String {
        if let s = v as? String, !s.isEmpty { return s }
        let n: Int?
        if let i = v as? Int { n = i } else if let d = v as? Double { n = Int(d) }
        else if let num = v as? NSNumber { n = num.intValue } else { n = nil }
        switch n {
        case nil: return ""
        case 0: return "UNKNOWN"
        case 1: return "OKAY"
        case 2: return "NO_ACTIVE_ACCOUNT"
        case 3: return "TOO_FAR_FROM_SERVICE_ADDRESS"
        case 4: return "IN_OCEAN"
        case 6: return "BLOCKED_COUNTRY"
        case 7: return "DATA_OVERAGE_SANDBOX_POLICY"
        case 8: return "CELL_IS_DISABLED"
        case 10: return "ROAM_RESTRICTED"
        case 11: return "UNKNOWN_LOCATION"
        case 12: return "ACCOUNT_DISABLED"
        case 13: return "UNSUPPORTED_VERSION"
        case 14: return "MOVING_TOO_FAST_FOR_POLICY"
        default: return "CODE_\(n!)"
        }
    }

    static func doubleArray(_ v: Any?) -> [Double] {
        guard let arr = v as? [Any] else { return [] }
        return arr.map { doubleVal($0) }
    }

    static func boolArray(_ v: Any?) -> [Bool] {
        guard let arr = v as? [Any] else { return [] }
        return arr.map { boolVal($0) }
    }
}

enum DishError: LocalizedError {
    case notImplemented(String)
    case unreachable(String)
    case missingProtoset(String)
    case parse(String)
    var errorDescription: String? {
        switch self {
        case .notImplemented(let s): return s
        case .unreachable(let s): return s
        case .missingProtoset(let s): return s
        case .parse(let s): return s
        }
    }
}
