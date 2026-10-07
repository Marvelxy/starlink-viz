import Foundation
import Combine

enum DishSource: String, CaseIterable, Identifiable {
    case mock = "Mock (works now)"
    case real = "Real dish (needs gRPC)"
    var id: String { rawValue }
}

/// Central store: polls dish, keeps timeline, detects outages, ranks overhead sats.
@MainActor
final class AppState: ObservableObject {
    private enum Prefs {
        static let source = "StarlinkViz.dishSource"
        static let host = "StarlinkViz.dishHost"
        static let lat = "StarlinkViz.observerLat"
        static let lon = "StarlinkViz.observerLon"
        static let minEl = "StarlinkViz.minElevation"
    }

    @Published var source: DishSource = .mock { didSet { savePrefs() } }
    @Published var dishHost = "192.168.100.1" { didSet { savePrefs() } }
    @Published var observer = ObserverLocation() { didSet { savePrefs() } }
    @Published var minElevation = 25.0 { didSet { savePrefs() } }

    @Published var latest: DishStatusSample?
    @Published var history: [DishStatusSample] = []
    @Published var outages: [OutageEvent] = []
    @Published var overhead: [SatellitePosition] = []
    @Published var tles: [TLE] = CelesTrakService.loadCachedOrSample()
    @Published var obstructionMap = ObstructionMap.clear
    @Published var obstructionStale = true
    @Published var statusMessage = "Booting in mock mode…"
    @Published var lastOutageSnapshot: [SatellitePosition] = []
    @Published var locationSource = "default (San Francisco)"
    @Published var lastSkyUpdate = Date()
    @Published var updateTick = 0
    @Published var isReloading = false
    @Published var lastRawStatus = ""

    private var dish: DishService = MockDishService()
    private var pollTask: Task<Void, Never>?
    private var skyTask: Task<Void, Never>?
    private let locator = LocationProvider()
    private var didAutoLocate = false

    init() {
        let d = UserDefaults.standard
        if let s = d.string(forKey: Prefs.source), let src = DishSource(rawValue: s) {
            source = src
        }
        if let host = d.string(forKey: Prefs.host), !host.isEmpty {
            dishHost = host
        }
        if d.object(forKey: Prefs.lat) != nil {
            observer.latitude = d.double(forKey: Prefs.lat)
        }
        if d.object(forKey: Prefs.lon) != nil {
            observer.longitude = d.double(forKey: Prefs.lon)
        }
        if d.object(forKey: Prefs.minEl) != nil {
            minElevation = d.double(forKey: Prefs.minEl)
        }
        Task { await boot() }
    }

    func savePrefs() {
        let d = UserDefaults.standard
        d.set(source.rawValue, forKey: Prefs.source)
        d.set(dishHost, forKey: Prefs.host)
        d.set(observer.latitude, forKey: Prefs.lat)
        d.set(observer.longitude, forKey: Prefs.lon)
        d.set(minElevation, forKey: Prefs.minEl)
    }

    func boot() async {
        applySource()
        await autoLocate()
        // With only the 3 bundled samples overhead is often empty — pull the
        // real constellation once so Sky/Map have something to show.
        let hadSampleOnly = tles.count <= 5
        if hadSampleOnly { await refreshTLEQuietly() }
        do { history = try await dish.fetchHistory() } catch { history = [] }
        recomputeOverhead()
        startLoops()
        var base = source == .mock
            ? "Mock mode: switch to Real dish in Settings when on Starlink LAN."
            : "Real mode: needs `brew install grpcurl` + same Starlink LAN (see README)."
        if hadSampleOnly, tles.count > 5 {
            base += " TLE auto-loaded: \(tles.count) objects."
        }
        statusMessage = base
    }

    func applySource() {
        switch source {
        case .mock: dish = MockDishService()
        case .real: dish = RealDishClient(host: dishHost)
        }
    }

    /// Re-apply the dish source and restart all polling. Picks up a newly
    /// installed grpcurl, a changed dish host, or a reconnected dish
    /// without restarting the app. Safe to call any time (old loops cancel).
    func reconnect() async {
        guard !isReloading else { return }
        isReloading = true
        defer { isReloading = false }
        await boot()
    }

    func refreshTLE() async {
        statusMessage = "Refreshing TLE from CelesTrak…"
        do {
            tles = try await CelesTrakService.refresh()
            recomputeOverhead()
            statusMessage = "TLE refreshed: \(tles.count) Starlink objects."
        } catch {
            statusMessage = "TLE refresh failed (\(error.localizedDescription)); using cache."
        }
    }

    /// Same as refreshTLE() but silent — for boot-time auto-load.
    func refreshTLEQuietly() async {
        if let fresh = try? await CelesTrakService.refresh() {
            tles = fresh
        }
    }

    func recomputeOverhead(date: Date = Date()) {
        var sats = OverheadFilter.rankedCandidates(
            tles: tles, observer: observer,
            minElevationDeg: minElevation, date: date
        )
        // Mock mode promises working tabs: pad thin real data with clearly
        // labeled synthetic sats so Sky/Map are never mysteriously empty.
        if source == .mock, sats.count < 6 {
            sats += Orbit.demoSats(observer: observer, date: date, count: 8 - sats.count)
            sats.sort { $0.elevationDeg > $1.elevationDeg }
            for i in sats.indices { sats[i].isCandidate = i < 3 }
        }
        overhead = sats
        lastSkyUpdate = date
        updateTick += 1
    }

    /// Automatic observer location: dish GPS (Real mode only) → this Mac →
    /// coarse IP fix → keep current. Runs once per launch unless forced.
    func autoLocate(force: Bool = false) async {
        if didAutoLocate, !force { return }
        didAutoLocate = true
        // 1. Dish GPS (often absent since May 2026 except Priority plans).
        if source == .real, let dishLoc = await LocationService.dishLocation(host: dishHost) {
            observer.latitude = dishLoc.latitude
            observer.longitude = dishLoc.longitude
            locationSource = "dish GPS"
            recomputeOverhead()
            return
        }
        // 2. This Mac (one permission prompt, then cached by the OS).
        if let coord = await locator.macLocation() {
            observer.latitude = coord.latitude
            observer.longitude = coord.longitude
            locationSource = "this Mac"
            recomputeOverhead()
            return
        }
        // 3. Coarse IP fix.
        if let ip = await LocationService.ipLocation() {
            observer.latitude = ip.latitude
            observer.longitude = ip.longitude
            locationSource = "IP fix (coarse)"
            recomputeOverhead()
            return
        }
        locationSource += " — auto-fix failed, set manually"
    }

    private func startLoops() {
        pollTask?.cancel()
        skyTask?.cancel()
        // 1s dish poll.
        pollTask = Task {
            while !Task.isCancelled {
                do {
                    if let real = self.dish as? RealDishClient {
                        let (sample, raw) = try await real.fetchStatusWithRaw()
                        self.latest = sample
                        self.lastRawStatus = raw
                    } else {
                        self.latest = try await dish.fetchStatus()
                        self.lastRawStatus = ""
                    }
                    if let s = self.latest, s.wedgeFractionObstructed.count == 12 {
                        self.obstructionMap = s.obstructionMap
                        self.obstructionStale = false
                    }
                    if let s = self.latest {
                        self.history.append(s)
                        if self.history.count > 1800 { self.history.removeFirst(self.history.count - 1800) }
                        self.detectOutage(sample: s)
                    }
                    self.statusMessage = self.source == .real
                        ? "Live from dish @ \(self.dishHost)"
                        : "Mock feed live · switch to Real dish in Settings when on Starlink LAN."
                } catch {
                    self.statusMessage = "Dish poll failed: \(error.localizedDescription)"
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    continue
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        // 1s live sky recompute — sats glide continuously instead of jumping.
        skyTask = Task {
            while !Task.isCancelled {
                self.recomputeOverhead()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func detectOutage(sample: DishStatusSample) {
        // Drop-based only. Newer firmware parks `state` at UNKNOWN (and SNR
        // at 0) even on healthy links, so state labels must not drive this —
        // otherwise every poll would log a phantom outage.
        guard sample.pingDropRate > 0.4 else { return }
        let cls = sample.pingDropRate > 0.8 ? "2s+" : "1s+"
        outages.append(OutageEvent(
            timestamp: sample.timestamp,
            durationClass: cls,
            note: "drop \(Int(sample.pingDropRate * 100))% · SNR \(String(format: "%.1f", sample.snr)) dB"
        ))
        if outages.count > 200 { outages.removeFirst() }
        lastOutageSnapshot = Array(overhead.prefix(5))
    }
}
