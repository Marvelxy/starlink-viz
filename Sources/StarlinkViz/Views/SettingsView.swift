import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @StateObject private var checker = DishChecker()

    var body: some View {
        Form {
            Section("Dish source") {
                Picker("Source", selection: $state.source) {
                    ForEach(DishSource.allCases) { Text($0.rawValue).tag($0) }
                }
                .onChange(of: state.source) { _, _ in
                    Task { await state.boot() }
                }
                TextField("Dish host", text: $state.dishHost)
                    .onSubmit { state.applySource() }
                Text("Real dish requires same Starlink LAN + grpc-swift wiring (README). Mock works anywhere.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Your location (used for overhead sats)") {
                Text("Source: \(state.locationSource)")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("Latitude", value: $state.observer.latitude, format: .number)
                TextField("Longitude", value: $state.observer.longitude, format: .number)
                HStack {
                    Button("Use my location") {
                        Task { await state.autoLocate(force: true) }
                    }
                    Button("Recompute sky") { state.recomputeOverhead() }
                }
                Text("Auto tries dish GPS (Real mode, Priority plans) → this Mac → coarse IP fix. Dish GPS was removed May 2026 for most plans.")
                    .font(.caption).foregroundStyle(.secondary)
                Slider(value: $state.minElevation, in: 10...50, step: 1) {
                    Text("Min elevation \(Int(state.minElevation))°")
                }
            }
            Section("TLE data") {
                Text("Cached objects: \(state.tles.count)")
                Button("Refresh from CelesTrak") {
                    Task { await state.refreshTLE() }
                }
                Text("Refresh every 6–12h. CelesTrak rate-limits aggressive polling.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Dish connection (replaces check_dish.sh)") {
                HStack {
                    Circle()
                        .fill(checker.grpcurlInstalled ? .green : .red)
                        .frame(width: 8, height: 8)
                    Text(checker.grpcurlInstalled
                         ? "grpcurl: \(checker.grpcurlPath ?? "")"
                         : "grpcurl: missing")
                    .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Rescan") { checker.refreshToolStatus() }
                        .buttonStyle(.link)
                }
                if !checker.brewInstalled {
                    Text("Homebrew not found — Install button will point you to brew.sh.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button(checker.isRunning ? "Working…" : "Check dish (\(state.dishHost))") {
                        Task { await checker.runCheck(host: state.dishHost) }
                    }
                    .disabled(checker.isRunning)
                    Button(checker.grpcurlInstalled ? "grpcurl installed ✓" : "Install grpcurl") {
                        Task { await checker.installGrpcurl() }
                    }
                    .disabled(checker.isRunning || checker.grpcurlInstalled)
                }
                if checker.lastCheckSucceeded {
                    Button("Check passed — switch to Real dish") {
                        state.source = .mock  // reset first so onChange-style boot always re-runs
                        state.source = .real
                        Task { await state.boot() }
                    }
                }
                if !checker.log.isEmpty {
                    ScrollView {
                        Text(checker.log)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minHeight: 120, maxHeight: 220)
                    HStack {
                        Button("Clear log") { checker.clear() }
                            .buttonStyle(.link)
                        Spacer()
                        Button("Copy log") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(checker.log, forType: .string)
                        }
                        .buttonStyle(.link)
                    }
                } else {
                    Text("Runs ping + getStatus + getHistory against the host above, same as ./Tools/check_dish.sh. Must be on Starlink LAN.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding()
        .navigationTitle("Settings")
    }
}
