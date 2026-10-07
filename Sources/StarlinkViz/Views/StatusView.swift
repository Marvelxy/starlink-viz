import SwiftUI

struct StatusView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.source == .real
                         ? "Source: Real dish @ \(state.dishHost)"
                         : "Source: Mock (simulated dish)")
                        .font(.caption.bold())
                    Text(state.statusMessage)
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if state.source == .mock {
                    Button("Use Real dish") {
                        state.source = .real
                        Task { await state.reconnect() }
                    }
                    .help("Switch to the real dish and restart polling")
                }
                Button {
                    Task { await state.reconnect() }
                } label: {
                    if state.isReloading {
                        ProgressView()
                            .scaleEffect(0.7)
                            .frame(width: 22, height: 22)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(state.isReloading)
                .help("Reload now: restarts polling and refills history (live polling self-heals on its own, but won't backfill history gaps)")
            }

            if let s = state.latest {
                HStack {
                    stateDot(effectiveState(s))
                    Text(effectiveState(s).rawValue).font(.title2.bold())
                    Spacer()
                    Text(s.timestamp, style: .time).foregroundStyle(.secondary)
                }
                if s.state == .unknown, !s.linkLooksUp, !s.stateRaw.isEmpty {
                    Text("Dish reports state \"\(s.stateRaw)\" — unrecognized value. If you see this, run Settings → Check dish and share the log.")
                        .font(.caption).foregroundStyle(.orange)
                }
                if !s.disablementCode.isEmpty, s.disablementCode != "OKAY", s.disablementCode != "UNKNOWN" {
                    Text("Dish disablement: \(s.disablementCode) — this is why it won't serve. Check account/service address in the Starlink app.")
                        .font(.callout).foregroundStyle(.red)
                } else if !s.outageCause.isEmpty {
                    Text("Dish outage cause: \(s.outageCause)")
                        .font(.caption).foregroundStyle(.orange)
                }
                if !s.hardwareVersion.isEmpty || s.uptimeS > 0 {
                    Text(dishInfoLine(s))
                        .font(.caption).foregroundStyle(.secondary)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170))], spacing: 10) {
                    metric("SNR", "\(String(format: "%.1f", s.snr)) dB")
                    metric("Latency", "\(String(format: "%.0f", s.pingLatencyMs)) ms")
                    metric("Drop", "\(String(format: "%.1f", s.pingDropRate * 100))%")
                    metric("Down", "\(String(format: "%.0f", s.downlinkMbps)) Mbps")
                    metric("Up", "\(String(format: "%.0f", s.uplinkMbps)) Mbps")
                    metric("Obstructed", s.obstructed ? "YES" : "no")
                    metric("Sky blocked", "\(String(format: "%.1f", s.obstructionMap.meanBlocked * 100))%")
                    metric("Alerts", alertSummary(s))
                }
                Text("Honest note: Starlink exposes no reliable real-time NORAD ID for the serving beam. Below are ranked overhead candidates — treat the top one as “likely serving”, not ground truth.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ProgressView("Waiting for first dish sample…")
            }

            Text("Likely serving now (top 5 overhead ≥ \(Int(state.minElevation))°)")
                .font(.headline)
            Table(state.overhead.prefix(5).map { $0 }) {
                TableColumn("Satellite", value: \.name)
                TableColumn("NORAD") { Text("\($0.id)") }
                TableColumn("El°") { Text(String(format: "%.1f", $0.elevationDeg)) }
                TableColumn("Az°") { Text(String(format: "%.0f", $0.azimuthDeg)) }
                TableColumn("Range km") { Text(String(format: "%.0f", $0.rangeKm)) }
            }
            if !state.lastRawStatus.isEmpty {
                DisclosureGroup("Raw dish response (first 2000 chars)") {
                    ScrollView([.horizontal, .vertical]) {
                        Text(state.lastRawStatus)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 220)
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding()
        .navigationTitle("Link")
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.bold()).monospacedDigit()
        }
        .frame(maxWidth: .infinity)
        .padding(8)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    private func stateDot(_ s: DishState) -> some View {
        Circle().frame(width: 12, height: 12)
            .foregroundStyle(s == .connected ? .green
                : (s == .offline || s == .thermalShutdown ? .red : .orange))
    }

    /// What to show as the headline state. A dish reporting UNKNOWN with no
    /// outage and no ping loss is treated as up (verified against live dish
    /// data: 167 Mbps peaks at 0% drop while reporting UNKNOWN).
    private func effectiveState(_ s: DishStatusSample) -> DishState {
        (s.state == .unknown && s.linkLooksUp) ? .connected : s.state
    }

    private func dishInfoLine(_ s: DishStatusSample) -> String {
        var parts: [String] = []
        if !s.hardwareVersion.isEmpty { parts.append(s.hardwareVersion) }
        if !s.softwareVersion.isEmpty { parts.append("fw \(s.softwareVersion)") }
        if s.uptimeS > 0 {
            let t = Int(s.uptimeS)
            parts.append("up \(t / 3600)h \((t % 3600) / 60)m")
        }
        return parts.joined(separator: " · ")
    }

    private func alertSummary(_ s: DishStatusSample) -> String {
        var parts: [String] = []
        if s.alerts.motorsStuck { parts.append("motors") }
        if s.alerts.thermalThrottle { parts.append("thermal-throttle") }
        if s.alerts.thermalShutdown { parts.append("thermal-shutdown") }
        return parts.isEmpty ? "none" : parts.joined(separator: ", ")
    }
}
