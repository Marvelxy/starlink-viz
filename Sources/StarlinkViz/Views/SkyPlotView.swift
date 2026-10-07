import SwiftUI

/// Polar sky plot: center = zenith (90° el), rim = horizon.
/// Dots = overhead sats (azimuth → angle, elevation → radius).
/// Red wedges = real dish `wedge_fraction_obstructed` (12 × 30°).
/// Dimmed sats sit inside a blocked wedge — likely unusable even if high.
struct SkyPlotView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        HStack(spacing: 16) {
            Canvas { ctx, size in
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                let R = min(size.width, size.height) / 2 - 8
                // Rings at 0/30/60 deg elevation.
                for el in [0.0, 30.0, 60.0] {
                    let r = R * (1 - el / 90)
                    ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)),
                               with: .color(.gray.opacity(0.5)))
                }
                // Cardinal cross + labels.
                ctx.stroke(Path { p in
                    p.move(to: CGPoint(x: c.x - R, y: c.y)); p.addLine(to: CGPoint(x: c.x + R, y: c.y))
                    p.move(to: CGPoint(x: c.x, y: c.y - R)); p.addLine(to: CGPoint(x: c.x, y: c.y + R))
                }, with: .color(.gray.opacity(0.4)))
                // Real obstruction wedges (12 × 30°, 0° = North at top).
                let wedges = state.obstructionMap.wedges
                if wedges.count == 12 {
                    for i in 0 ..< 12 {
                        let frac = min(1, max(0, wedges[i]))
                        guard frac > 0.005 else { continue }
                        // Canvas 0° = East, so North-up azimuth a → angle a-90.
                        let start = Angle.degrees(Double(i * 30) - 90)
                        let end = Angle.degrees(Double((i + 1) * 30) - 90)
                        ctx.fill(Path { p in
                            p.move(to: c)
                            p.addArc(center: c, radius: R, startAngle: start, endAngle: end, clockwise: false)
                            p.closeSubpath()
                        }, with: .color(.red.opacity(0.08 + 0.5 * frac)))
                    }
                }
                // Satellites; dim those behind blocked wedges.
                for sat in state.overhead {
                    let blocked = state.obstructionMap.isBlocked(azimuthDeg: sat.azimuthDeg)
                    let r = R * (1 - sat.elevationDeg / 90)
                    let a = (sat.azimuthDeg - 90) * .pi / 180
                    let pt = CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a))
                    let dot = Path(ellipseIn: CGRect(x: pt.x - 4, y: pt.y - 4, width: 8, height: 8))
                    if blocked {
                        ctx.fill(dot, with: .color(.gray.opacity(0.5)))
                    } else {
                        ctx.fill(dot, with: .color(sat.isCandidate ? .green : .blue))
                    }
                }
            }
            .frame(minWidth: 380, minHeight: 380)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                if state.overhead.isEmpty {
                    Text("No sats above \(Int(state.minElevation))° right now.\nRefresh TLE or lower min elevation in Settings.")
                        .multilineTextAlignment(.center)
                        .font(.callout).foregroundStyle(.secondary)
                        .padding()
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Sky overhead (≥ \(Int(state.minElevation))°)")
                    .font(.headline)
                if state.obstructionStale {
                    Text("Obstruction: waiting for first dish sample…")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    Text("Blocked sky: \(String(format: "%.1f", state.obstructionMap.meanBlocked * 100))% mean · red = blocked wedges · grey dots = behind obstruction")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Text("\(state.overhead.count) sats · green = top-3 likely serving")
                    .font(.callout).foregroundStyle(.secondary)
                if state.overhead.contains(where: { $0.name.hasPrefix("DEMO-") }) {
                    Text("DEMO- sats are synthetic mock data (thin TLE set) — Refresh from CelesTrak in Settings for the real constellation.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                // Wedge readout: 12 rows, worst first.
                if !state.obstructionStale {
                    Text("Worst wedges").font(.caption.bold())
                    ForEach(worstWedges, id: \.index) { w in
                        HStack {
                            Text("az \(w.index * 30)–\(w.index * 30 + 30)°")
                            Spacer()
                            Text(String(format: "%.0f%%", w.frac * 100))
                                .monospacedDigit()
                                .foregroundStyle(w.frac >= 0.3 ? .red : .secondary)
                        }.font(.caption)
                    }
                }
                List(state.overhead.prefix(20)) { s in
                    let blocked = state.obstructionMap.isBlocked(azimuthDeg: s.azimuthDeg)
                    HStack {
                        Circle().frame(width: 8, height: 8)
                            .foregroundStyle(blocked ? .gray : (s.isCandidate ? .green : .blue))
                        Text(s.name).font(.callout)
                        if blocked { Text("blocked").font(.caption).foregroundStyle(.red) }
                        Spacer()
                        Text("el \(String(format: "%.0f", s.elevationDeg))° · az \(String(format: "%.0f", s.azimuthDeg))°")
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
        }
        .padding()
        .navigationTitle("Sky")
    }

    private var worstWedges: [(index: Int, frac: Double)] {
        let w = state.obstructionMap.wedges
        guard w.count == 12 else { return [] }
        return w.enumerated().map { ($0.offset, $0.element) }
            .sorted { $0.1 > $1.1 }.prefix(4).map { (index: $0.0, frac: $0.1) }
    }
}
