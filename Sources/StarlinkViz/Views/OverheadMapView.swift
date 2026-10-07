import SwiftUI
import MapKit

struct OverheadMapView: View {
    @EnvironmentObject var state: AppState
    @State private var position = MapCameraPosition.automatic
    @State private var showGateways = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle().frame(width: 8, height: 8).foregroundStyle(.green)
                Text("Live · updated \(state.lastSkyUpdate.formatted(date: .omitted, time: .standard))")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Toggle("Ground stations", isOn: $showGateways)
                    .toggleStyle(.switch)
                Button("Recenter") { recenter() }
            }
            Text("Subsatellite points for sats above your horizon. Blue = overhead, green = top-3 candidates. Orange trail = top candidate's ±5 min track.")
                .font(.callout).foregroundStyle(.secondary)
            if state.overhead.isEmpty {
                HStack {
                    Text("No sats above \(Int(state.minElevation))° right now.")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Refresh TLE") {
                        Task { await state.refreshTLE() }
                    }
                }
            }
            Map(position: $position) {
                ForEach(state.overhead.prefix(60)) { s in
                    Annotation(s.name, coordinate: CLLocationCoordinate2D(latitude: s.latitude, longitude: s.longitude)) {
                        Circle()
                            .frame(width: s.isCandidate ? 12 : 7, height: s.isCandidate ? 12 : 7)
                            .foregroundStyle(s.isCandidate ? .green : .blue.opacity(0.8))
                            .overlay(Circle().stroke(.white, lineWidth: 1))
                    }
                }
                if let trail = topTrail, trail.count > 1 {
                    MapPolyline(coordinates: trail)
                        .stroke(.orange, lineWidth: 2)
                }
                if showGateways {
                    ForEach(GroundStations.all) { g in
                        Annotation(g.name, coordinate: CLLocationCoordinate2D(latitude: g.latitude, longitude: g.longitude)) {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .font(.caption)
                                .foregroundStyle(.red)
                                .background(.white.opacity(0.7), in: Circle())
                        }
                    }
                }
                Marker("You (\(state.locationSource))", coordinate: CLLocationCoordinate2D(
                    latitude: state.observer.latitude, longitude: state.observer.longitude
                ))
                .tint(.orange)
            }
            .mapStyle(.standard(elevation: .realistic))
            .cornerRadius(12)
            .animation(.linear(duration: 1), value: state.updateTick)
            .onAppear { recenter() }
            Text("TLE count: \(state.tles.count) · \(GroundStations.all.count) known gateways (community-curated, approx) · simplified propagator — swap full SGP4 for operational accuracy (see README).")
                .font(.caption).foregroundStyle(.secondary)
            if showGateways {
                Text("Nearest gateways").font(.caption.bold())
                ForEach(nearestGateways, id: \.station.id) { item in
                    HStack {
                        Text(item.station.name + (item.station.approx ? " *" : ""))
                        Spacer()
                        Text("\(Int(item.km)) km")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }.font(.caption)
                }
                Text("Gateway serving is not exposed by the dish API — nearest ≠ necessarily serving. * city/town-level pin, not the exact site.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding()
        .navigationTitle("Map")
    }

    private func recenter() {
        position = .region(MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: state.observer.latitude, longitude: state.observer.longitude),
            span: MKCoordinateSpan(latitudeDelta: 30, longitudeDelta: 30)
        ))
    }

    /// ±5 min subsatellite track of the current top candidate.
    private var topTrail: [CLLocationCoordinate2D]? {
        guard let top = state.overhead.first(where: { $0.isCandidate }),
              let tle = state.tles.first(where: { $0.noradId == top.id })
        else { return nil }
        let pts = Orbit.track(tle, observer: state.observer, center: state.lastSkyUpdate)
        guard pts.count > 1 else { return nil }
        return pts.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
    }

    private var nearestGateways: [(station: GroundStation, km: Double)] {
        GroundStations.nearest(to: state.observer)
    }
}
