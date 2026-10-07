import Foundation
import CoreLocation

/// Automatic observer location with graceful fallbacks.
///
/// Priority (first fix wins):
///   1. Dish GPS over the local gRPC API (`getLocation`) — only attempted in
///      Real-dish mode, and only useful on plans where it still exists
///      (removed May 2026 for most plans, kept for Priority).
///   2. This Mac via Core Location (prompts once for permission).
///   3. Coarse IP geolocation (ip-api.com) — city-level, no permission needed.
///   4. Whatever is already set (manual lat/lon, default San Francisco).
enum LocationService {
    /// Best-effort dish position. Returns nil quickly when not on dish LAN
    /// (8s cap so a missing dish can't stall boot).
    static func dishLocation(host: String) async -> ObserverLocation? {
        let target = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return nil }
        let data: Data? = await withTimeout(seconds: 8) {
            try await GrpcURLBridge.call(
                address: "\(target):9200", payload: #"{"getLocation":{}}"#)
        }
        guard let data,
              let json = try? JSONSerialization.jsonObject(with: data),
              let (lat, lon) = findLatLon(json),
              lat != 0 || lon != 0
        else { return nil }
        return ObserverLocation(latitude: lat, longitude: lon)
    }

    /// Coarse city-level fix, no permission prompt. 8s cap.
    static func ipLocation() async -> ObserverLocation? {
        struct IPGeo: Decodable { var status: String?; var lat: Double?; var lon: Double? }
        guard let url = URL(string: "http://ip-api.com/json/?fields=status,lat,lon") else { return nil }
        let geo: IPGeo? = await withTimeout(seconds: 8) {
            let (data, _) = try await URLSession.shared.data(from: url)
            return try JSONDecoder().decode(IPGeo.self, from: data)
        }
        guard let geo, geo.status == "success", let lat = geo.lat, let lon = geo.lon else { return nil }
        return ObserverLocation(latitude: lat, longitude: lon)
    }

    // MARK: - helpers

    /// Recursively finds the first plausible lat/lon pair in tolerant dish JSON.
    static func findLatLon(_ v: Any) -> (Double, Double)? {
        if let d = v as? [String: Any] {
            if let lat = num(d["latitude"] ?? d["lat"]),
               let lon = num(d["longitude"] ?? d["lon"] ?? d["lng"] ?? d["long"]),
               (-90 ... 90).contains(lat), (-180 ... 180).contains(lon),
               lat != 0 || lon != 0
            {
                return (lat, lon)
            }
            for child in d.values {
                if let found = findLatLon(child) { return found }
            }
        } else if let a = v as? [Any] {
            for child in a {
                if let found = findLatLon(child) { return found }
            }
        }
        return nil
    }

    static func num(_ v: Any?) -> Double? {
        if let d = v as? Double { return d }
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s) }
        return nil
    }

    /// Returns the operation's result, or nil if `seconds` elapse first.
    static func withTimeout<T: Sendable>(seconds: UInt64, _ op: @escaping @Sendable () async throws -> T) async -> T? {
        await withTaskGroup(of: T?.self, returning: T?.self) { group in
            group.addTask { try? await op() }
            group.addTask {
                try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
                return nil
            }
            for await value in group {
                group.cancelAll()
                return value
            }
            return nil
        }
    }
}

/// One-shot fix from this Mac. Create and drive from the main actor;
/// delegate callbacks arrive on the main runloop.
final class LocationProvider: NSObject, CLLocationManagerDelegate {
    private var manager: CLLocationManager?
    private var continuation: CheckedContinuation<CLLocationCoordinate2D?, Never>?
    private var finished = false

    @MainActor
    func macLocation() async -> CLLocationCoordinate2D? {
        await withCheckedContinuation { cont in
            let m = CLLocationManager()
            let status = m.authorizationStatus
            guard status != .denied, status != .restricted else {
                cont.resume(returning: nil)
                return
            }
            continuation = cont
            finished = false
            m.delegate = self
            m.desiredAccuracy = kCLLocationAccuracyKilometer
            manager = m
            m.requestWhenInUseAuthorization()
            m.requestLocation()
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 12_000_000_000)
                self?.finish(with: nil)
            }
        }
    }

    // MARK: - CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorized, .authorizedAlways:
            manager.requestLocation()
        case .denied, .restricted:
            finish(with: nil)
        default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        finish(with: locations.last?.coordinate)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        finish(with: nil)
    }

    // MARK: - private

    private func finish(with coord: CLLocationCoordinate2D?) {
        guard !finished else { return }
        finished = true
        manager?.stopUpdatingLocation()
        manager?.delegate = nil
        manager = nil
        continuation?.resume(returning: coord)
        continuation = nil
    }
}
