import Foundation
import Combine

/// In-app equivalent of `Tools/check_dish.sh` + `brew install grpcurl`.
/// Lets users verify dish reachability without leaving the app.
@MainActor
final class DishChecker: ObservableObject {
    @Published var log: String = ""
    @Published var isRunning = false
    @Published var grpcurlPath: String?
    @Published var brewPath: String?
    @Published var lastCheckSucceeded = false

    var grpcurlInstalled: Bool { grpcurlPath != nil }
    var brewInstalled: Bool { brewPath != nil }

    init() {
        refreshToolStatus()
    }

    func refreshToolStatus() {
        grpcurlPath = Self.resolveTool(
            candidates: ["/opt/homebrew/bin/grpcurl", "/usr/local/bin/grpcurl"],
            name: "grpcurl")
        brewPath = Self.resolveTool(
            candidates: ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"],
            name: "brew")
    }

    func clear() {
        log = ""
        lastCheckSucceeded = false
    }

    func append(_ line: String) {
        if !log.isEmpty { log += "\n" }
        log += line
    }

    // MARK: - Check (ping + getStatus + getHistory)

    /// Mirrors check_dish.sh steps, reusing GrpcURLBridge so results
    /// match what Real-dish mode will actually do.
    func runCheck(host: String) async {
        guard !isRunning else { return }
        isRunning = true
        lastCheckSucceeded = false
        defer { isRunning = false }

        let target = host.trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty ? "192.168.100.1" : host.trimmingCharacters(in: .whitespacesAndNewlines)
        append("== check dish @ \(target) ==")

        // 1. grpcurl present?
        refreshToolStatus()
        if let g = grpcurlPath {
            append("grpcurl: \(g)")
        } else {
            append("grpcurl: NOT FOUND — install it with the button below (or: brew install grpcurl)")
            append("FAILED: grpcurl missing")
            return
        }

        // 2. protoset present?
        do {
            let p = try GrpcURLBridge.protosetPath()
            append("protoset: \(p)")
        } catch {
            append("FAILED: \(error.localizedDescription)")
            return
        }

        // 3. ping
        append("== ping \(target) ==")
        do {
            let out = try await Self.runProcess(executable: "/sbin/ping", args: ["-c2", "-t2", target])
            append(out.output.trimmingCharacters(in: .whitespacesAndNewlines))
            guard out.exitCode == 0 else {
                append("FAILED: host unreachable (ping exit \(out.exitCode)). Is this Mac on the Starlink LAN?")
                return
            }
        } catch {
            append("FAILED: ping error: \(error.localizedDescription)")
            return
        }

        // 4. getStatus
        let address = "\(target):9200"
        append("== getStatus \(address) ==")
        do {
            let data = try await GrpcURLBridge.call(address: address, payload: #"{"getStatus":{}}"#)
            let sample = try DishJSON.parseStatus(data, timestamp: Date())
            append("state=\(sample.state.rawValue)" + (sample.stateRaw.isEmpty ? "" : " (dish sent \"\(sample.stateRaw)\")") + " snr=\(String(format: "%.1f", sample.snr))dB " +
                   "latency=\(String(format: "%.0f", sample.pingLatencyMs))ms " +
                   "drop=\(Int(sample.pingDropRate * 100))% " +
                   "down=\(String(format: "%.0f", sample.downlinkMbps))Mbps up=\(String(format: "%.0f", sample.uplinkMbps))Mbps")
            if let raw = String(data: data, encoding: .utf8) {
                append("raw: \(raw.prefix(1200))")
            }
            if !sample.disablementCode.isEmpty {
                append("disablement: \(sample.disablementCode)")
            }
            if !sample.outageCause.isEmpty {
                append("outage cause: \(sample.outageCause)")
            }
            append("link assessment: \(sample.linkLooksUp ? "UP" : "DOWN/DEGRADED") " +
                   "(outage: \(sample.outageCause.isEmpty ? "none" : sample.outageCause), " +
                   "drop: \(Int(sample.pingDropRate * 100))%)")
        } catch {
            append("FAILED getStatus: \(error.localizedDescription)")
            return
        }

        // 5. getHistory summary
        append("== getHistory (summary) ==")
        do {
            let data = try await GrpcURLBridge.call(address: address, payload: #"{"getHistory":{}}"#)
            let hist = try DishJSON.parseHistory(data)
            append("history samples: \(hist.count) (last 15 min cap 900)")
        } catch {
            append("FAILED getHistory: \(error.localizedDescription)")
            return
        }

        lastCheckSucceeded = true
        append("OK — dish reachable. You can switch Source to Real dish.")
    }

    // MARK: - Install grpcurl via Homebrew

    /// Runs `brew install grpcurl`, streaming brew output into `log`.
    /// brew itself must already exist; otherwise we point at brew.sh.
    func installGrpcurl() async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }

        refreshToolStatus()
        guard let brew = brewPath else {
            append("brew NOT FOUND — install Homebrew first: https://brew.sh")
            append("then re-open this screen and tap Install again.")
            return
        }
        append("== \(brew) install grpcurl ==")
        append("(this can take a minute…)")
        do {
            let out = try await Self.runProcess(executable: brew, args: ["install", "grpcurl"])
            let trimmed = out.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                // Keep log readable: last ~40 lines.
                let lines = trimmed.components(separatedBy: "\n")
                append(lines.suffix(40).joined(separator: "\n"))
            }
            refreshToolStatus()
            if grpcurlInstalled, out.exitCode == 0 {
                append("OK — grpcurl installed at \(grpcurlPath ?? "unknown"). Now tap Check dish.")
            } else if grpcurlInstalled {
                append("grpcurl now present at \(grpcurlPath ?? "unknown") (brew exit \(out.exitCode)).")
            } else {
                append("FAILED: brew exit \(out.exitCode). See output above.")
            }
        } catch {
            append("FAILED: \(error.localizedDescription)")
        }
    }

    // MARK: - Process helpers

    struct ProcessResult {
        var output: String
        var exitCode: Int32
    }

    /// Runs a binary, merging stdout+stderr, no timeout (caller runs short commands,
    /// except brew install which legitimately takes a while).
    static func runProcess(executable: String, args: [String]) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { cont in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: executable)
            proc.arguments = args
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = pipe
            do { try proc.run() } catch {
                cont.resume(throwing: error)
                return
            }
            proc.terminationHandler = { _ in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let text = String(data: data, encoding: .utf8) ?? ""
                cont.resume(returning: ProcessResult(output: text, exitCode: proc.terminationStatus))
            }
        }
    }

    /// Returns the first existing executable candidate, else `which <name>`.
    static func resolveTool(candidates: [String], name: String) -> String? {
        let fm = FileManager.default
        for c in candidates where fm.isExecutableFile(atPath: c) { return c }
        // PATH lookup via `which`.
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        proc.arguments = [name]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 else { return nil }
            let path = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return path.isEmpty ? nil : path
        } catch {
            return nil
        }
    }
}
