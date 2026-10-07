import SwiftUI
import Charts

struct TimelineView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading) {
            Text("Dropout timeline — ping-drop % and latency. Spikes aligned with orange outage ticks are your “sometimes doesn’t work” moments.")
                .font(.callout).foregroundStyle(.secondary)
            Chart {
                ForEach(state.history) { s in
                    LineMark(
                        x: .value("t", s.timestamp),
                        y: .value("drop %", s.pingDropRate * 100)
                    )
                    .foregroundStyle(.red)
                }
                ForEach(state.outages) { o in
                    RuleMark(x: .value("outage", o.timestamp))
                        .foregroundStyle(.orange.opacity(0.7))
                }
            }
            .frame(height: 220)
            .chartYScale(domain: 0...100)
            .chartXAxis { AxisMarks(values: .automatic) }

            Chart {
                ForEach(state.history) { s in
                    LineMark(
                        x: .value("t", s.timestamp),
                        y: .value("ms", s.pingLatencyMs)
                    )
                    .foregroundStyle(.blue)
                }
            }
            .frame(height: 150)
            .chartXAxis { AxisMarks(values: .automatic) }

            Text("Outages (\(state.outages.count)) — latest first")
                .font(.headline)
            List(state.outages.reversed().prefix(30), id: \.id) { o in
                HStack {
                    Text(o.timestamp, style: .time).monospacedDigit()
                    Text(o.durationClass).bold().foregroundStyle(.orange)
                    Text(o.note).foregroundStyle(.secondary)
                }.font(.callout)
            }
            if !state.lastOutageSnapshot.isEmpty {
                Text("At last outage, top candidates were: \(state.lastOutageSnapshot.map(\.name).joined(separator: ", "))")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding()
        .navigationTitle("Outages")
    }
}
