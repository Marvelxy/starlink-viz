import Foundation

/// Fetches the full Starlink TLE set and caches to disk.
///
/// Sources tried in order (first non-empty parse wins):
///   1. CelesTrak `gp.php?GROUP=starlink&FORMAT=TLE` — full constellation,
///      one request. Note: CelesTrak 403s some networks entirely
///      (VPN/datacenter/flagged IPs), hence the fallback.
///   2. tle-api (`tle.ivanstanojevic.me`, Hydra JSON, 100/page) — server-side
///      source, unaffected by CelesTrak IP blocks. Partial (first pages).
///
/// Validation rule: an HTTP 200 with unparsable content (e.g. a 403 HTML
/// page) is treated as failure and NEVER written to the cache, so a bad
/// response can't poison offline startup.
enum TLEError: LocalizedError {
    case http(String)
    case empty(String)
    case allSourcesFailed(String)
    var errorDescription: String? {
        switch self {
        case .http(let s): return s
        case .empty(let s): return s
        case .allSourcesFailed(let s): return "TLE refresh failed — \(s)"
        }
    }
}

final class CelesTrakService {
    static let starlinkURL = URL(string: "https://celestrak.org/NORAD/elements/gp.php?GROUP=starlink&FORMAT=TLE")!

    private static var cacheURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("starlink.tle")
    }

    /// Bundled fallback so Sky/Map tabs work offline on first launch.
    static let sampleTLE: String = """
        STARLINK-1007
        1 44713U 19074A   26096.51791667  .00016717  00000-0  10284-2 0  90006
        2 44713  53.0542  10.1234 0001456  90.0000 270.0000 15.06390000    10
        STARLINK-1008
        1 44714U 19074B   26096.51791667  .00016717  00000-0  10284-2 0  90017
        2 44714  53.0542  40.5678 0001456  90.0000 200.0000 15.06390000    11
        STARLINK-1012
        1 44718U 19074F   26096.51791667  .00016717  00000-0  10284-2 0  90039
        2 44718  53.0542  90.0000 0001456  90.0000 100.0000 15.06390000    12
        """

    static func loadCachedOrSample() -> [TLE] {
        if let data = try? Data(contentsOf: cacheURL),
           let text = String(data: data, encoding: .utf8),
           !text.isEmpty
        {
            let parsed = parseTLE(text)
            if !parsed.isEmpty { return parsed }
        }
        return parseTLE(sampleTLE)
    }

    static func refresh() async throws -> [TLE] {
        var problems: [String] = []
        // 1. CelesTrak.
        do {
            let text = try await fetchText(from: starlinkURL)
            let parsed = parseTLE(text)
            guard !parsed.isEmpty else {
                throw TLEError.empty("CelesTrak returned no parseable TLE (likely an error page)")
            }
            try? text.data(using: .utf8)?.write(to: cacheURL)
            return parsed
        } catch {
            problems.append("CelesTrak: \(friendly(error, host: "celestrak.org"))")
        }
        // 2. tle-api fallback.
        do {
            let parsed = try await fetchTleApiFallback(pages: 6)
            guard !parsed.isEmpty else {
                throw TLEError.empty("tle-api returned no parseable TLE")
            }
            // Cache as plain TLE text so offline restarts keep a full sky.
            let text = parsed.map { "\($0.name)\n\($0.line1)\n\($0.line2)" }.joined(separator: "\n")
            try? text.data(using: .utf8)?.write(to: cacheURL)
            return parsed
        } catch {
            problems.append("tle-api: \(friendly(error, host: "tle.ivanstanojevic.me"))")
        }
        throw TLEError.allSourcesFailed(problems.joined(separator: "; "))
    }

    // MARK: - fetch helpers

    /// GET with a real User-Agent; non-200 HTTP is an error (with the code).
    static func fetchText(from url: URL) async throws -> String {
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.setValue("StarlinkViz/1.0 (macOS)", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            throw TLEError.http("HTTP \(http.statusCode)")
        }
        guard let text = String(data: data, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw TLEError.empty("empty response body") }
        return text
    }

    /// First `pages` × 100 STARLINK results as TLEs. Partial constellation,
    /// but plenty for a full sky when CelesTrak is unreachable.
    static func fetchTleApiFallback(pages: Int) async throws -> [TLE] {
        struct Page: Decodable {
            struct Entry: Decodable {
                var name: String?
                var satelliteId: Int?
                var line1: String?
                var line2: String?
            }
            var member: [Entry]?
        }
        var out: [TLE] = []
        for page in 1 ... max(1, pages) {
            var comps = URLComponents(string: "https://tle.ivanstanojevic.me/api/tle/")!
            comps.queryItems = [
                URLQueryItem(name: "search", value: "STARLINK"),
                URLQueryItem(name: "page", value: "\(page)"),
                URLQueryItem(name: "page-size", value: "100"),
            ]
            guard let url = comps.url else { break }
            var req = URLRequest(url: url, timeoutInterval: 30)
            req.setValue("StarlinkViz/1.0 (macOS)", forHTTPHeaderField: "User-Agent")
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                throw TLEError.http("HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1)")
            }
            let entries = (try? JSONDecoder().decode(Page.self, from: data))?.member ?? []
            if entries.isEmpty { break }
            for e in entries {
                if let n = e.name, let l1 = e.line1, l1.hasPrefix("1 "),
                   let l2 = e.line2, l2.hasPrefix("2 "), let id = e.satelliteId
                {
                    out.append(TLE(name: n, line1: l1, line2: l2, noradId: id))
                }
            }
            if entries.count < 100 { break }
        }
        return out
    }

    static func friendly(_ error: Error, host: String) -> String {
        if let t = error as? TLEError, case .http(let s) = t {
            if s == "HTTP 403" {
                return "\(host) denied this network (\(s)) — common on VPN/datacenter IPs; trying next source"
            }
            return "\(host) \(s)"
        }
        return "\(host): \(error.localizedDescription)"
    }

    /// Parses 3-line sets: name + line1 + line2. Skips malformed triples.
    static func parseTLE(_ text: String) -> [TLE] {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var out: [TLE] = []
        var i = 0
        while i + 2 < lines.count {
            let name = lines[i], l1 = lines[i + 1], l2 = lines[i + 2]
            if l1.hasPrefix("1 ") && l2.hasPrefix("2 ") {
                let idStr = String(l1.dropFirst(2).prefix(5)).trimmingCharacters(in: .whitespaces)
                if let id = Int(idStr) {
                    out.append(TLE(name: name, line1: l1, line2: l2, noradId: id))
                }
                i += 3
            } else {
                i += 1
            }
        }
        return out
    }
}
