import SwiftUI

struct ContentView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        TabView {
            StatusView()
                .tabItem { Label("Link", systemImage: "antenna.radiowaves.left.and.right") }
            TimelineView()
                .tabItem { Label("Outages", systemImage: "chart.line.downtrend.xyaxis") }
            SkyPlotView()
                .tabItem { Label("Sky", systemImage: "circle.dotted") }
            OverheadMapView()
                .tabItem { Label("Map", systemImage: "map") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gear") }
        }
        .frame(minWidth: 980, minHeight: 640)
    }
}
