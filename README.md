# StarlinkViz (macOS SwiftUI starter)

Visualize Starlink dropouts, your link health, and which Starlink satellites are overhead.

## Install (macOS 14+, Intel + Apple silicon)

1. Download `StarlinkViz-vX.Y.Z-macOS-universal.dmg` from
   [Releases](../../releases).
2. Open it, drag **StarlinkViz** into **Applications**.
3. First launch: right-click → Open (ad-hoc signature, not notarized).

Or run from source with `make run` (see below).

## What this starter does

- **Tab 1 – Link:** live poll of dish status (mock by default), SNR / latency / throughput cards.
- **Tab 2 – Outages:** dropout timeline from `getHistory`-style samples (Swift Charts). This is how you debug "sometimes doesn't work".
- **Tab 3 – Sky:** polar sky-plot of candidate serving satellites + obstruction wedges.
- **Tab 4 – Map:** MapKit view of subsatellite points overhead.
- **Tab 5 – Settings:** your lat/lon, dish host, TLE refresh.

## Important Starlink realities (read before you expect exact sat ID)

1. **Dish local API = gRPC at `192.168.100.1:9200` (or `dishy.starlink.com:9200`).**
   `getStatus / getHistory / getDiagnostics / getObstructionMap` give you state,
   SNR, `pop_ping_latency/drop`, throughput, outage counters
   (`seconds_since_last_{1s,2s,5s}_outage`), alerts, obstruction stats.
   You must be on the same Starlink WiFi/LAN. No auth, but needs
   Local Network permission on macOS (`NSLocalNetworkUsageDescription` in Info.plist
   when you convert to Xcode project).
2. **There is NO public "currently connected NORAD ID" field.**
   The dish hands over roughly every ~15s (`seconds_to_slot_end`). Old `initial_satellite_id`
   fields are unreliable/zero. So this app shows **ranked candidates**
   (highest elevation / closest range) and labels them "likely serving",
   not ground truth. When an outage fires we snapshot the candidate set —
   that's the honest correlation you can build.
3. **Dish GPS over local API was removed May 2026 for most plans** (kept for Priority).
   This app uses your Mac location / manual lat-lon instead. That is also what
   CelesTrak + SGP4 propagation needs.
4. **Overhead sats = CelesTrak Starlink TLE + SGP4.**
   `https://celestrak.org/NORAD/elements/gp.php?GROUP=starlink&FORMAT=TLE`
   Refresh every 6–12h, cache to disk. Starter ships with a simplified Kepler
   propagator so it builds with zero deps; swap in full SGP4 for production
   (see `Services/Orbit.swift`).

## Run

```bash
make run      # build + wrap StarlinkViz.app + open it (macOS 14+)
```

Other targets: `make` (= `make app`), `make open` (open without rebuilding),
`make app-release`, `make check`, `make clean`, `make help`.

> Do not run `./.build/debug/StarlinkViz` directly — the raw SwiftPM binary
> has no bundle, so it runs headless (no Dock icon / window). The `make`
> wrapper copies it into `StarlinkViz.app` (with `Info.plist`) and ad-hoc
> signs it, which is what makes the GUI appear. No Xcode required.

The app boots in **Mock mode** so every tab works without a dish.

## Wiring a real dish (Standard dish + Starlink router, same LAN)

Real mode is implemented — no Swift gRPC dependency needed. It shells the
`grpcurl` CLI using the vendored `Proto/dish.protoset` (field numbers verified
against starlink-community/starlink-grpc-go: `get_status=1004`,
`get_history=1007` → `dish_get_status=2004`, `dish_get_history=2006`).

1. In the app: Settings → Dish connection → **Check dish**.
   This runs ping + `getStatus` + `getHistory` against your dish host and
   shows the log inline (same as the script below). If `grpcurl` is missing,
   tap **Install grpcurl** (requires Homebrew; otherwise install from
   https://brew.sh first). On success, tap **switch to Real dish**.
   Or from a terminal (Mac on Starlink LAN):
   `make check` (= `./Tools/check_dish.sh 192.168.100.1`).
2. In app Settings, switch Source → Real dish. 1s poll for status, history on boot,
   wedges feed the Sky tab's red obstruction overlay.
3. Optional: set `STARLINK_PROTOSET` env if you keep a fresher protoset elsewhere.
4. For full SGP4, add an SPM SGP4 package and replace `Orbit.propagate()`
   internals — the `OverheadFilter` interface stays the same.
5. For fully native Swift gRPC (no grpcurl binary), see `Proto/NATIVE_GRPC.md`.

## Files

```
Sources/StarlinkViz/
  StarlinkVizApp.swift
  Models.swift
  Services/DishService.swift      protocol + Mock + Real (grpcurl bridge)
  Services/DishCheck.swift        in-app ping/status/history check + brew install
  Services/CelesTrakService.swift fetch + cache TLE
  Services/Orbit.swift            TLE parse + propagate + az/el + overhead rank
  Services/AppState.swift         Observable store, polling, outage detection
  Views/ContentView.swift
  Views/StatusView.swift
  Views/TimelineView.swift
  Views/SkyPlotView.swift
  Views/OverheadMapView.swift
  Views/SettingsView.swift        source/host/TLE + Dish connection section
Makefile                          build/wrap/run/open/check/clean
```

## Debugging your dropouts — what to look at

- `Timeline`: 1s/2s/5s outage ticks + ping-drop spikes. Regular ~15s-spaced blips = handover/obstruction; random long blocks = obstruction/heating/cable/POP issue.
- `Sky`: if outage snapshot always has low max-elevation or a blocked azimuth wedge matching your `obstruction wedges`, it's a sky-view problem — move dish.
- `getDiagnostics` alerts: `obstructed`, `high_sky_obstruction`, `motorsStuck`, thermal, etc.

## License

MIT — see [LICENSE](LICENSE).
