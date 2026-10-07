import Foundation

/// Known Starlink gateway earth stations, community-curated from FCC filings,
/// Nigeria's NCC ground-segment registry, and press reports
/// (positions approximate, status as of the 2025 public dataset).
///
/// Honest scope: the dish API does not expose which gateway is currently
/// serving you, so this is a map overlay + nearest-site computation, not
/// live ground-truth. Distances are great-circle (haversine) km.
/// `approx` = city/town-level pin, not the exact site.
struct GroundStation: Identifiable, Hashable {
    var id: String { name }
    var name: String
    var latitude: Double
    var longitude: Double
    var approx: Bool = false
}

enum GroundStations {
    static let all: [GroundStation] = [
        // United States (operational per 2025 dataset)
        GroundStation(name: "Baxley, GA", latitude: 31.7791, longitude: -82.3485),
        GroundStation(name: "Beekmantown, NY", latitude: 44.7629, longitude: -73.5754),
        GroundStation(name: "Bellingham, WA", latitude: 48.7519, longitude: -122.4787),
        GroundStation(name: "Boca Chica, TX", latitude: 26.0621, longitude: -97.1668),
        GroundStation(name: "Brewster, WA", latitude: 48.0962, longitude: -119.7806),
        GroundStation(name: "Broadview, IL", latitude: 41.8642, longitude: -87.8534),
        GroundStation(name: "Butte, MT", latitude: 46.0038, longitude: -112.5348),
        GroundStation(name: "Cass County, ND", latitude: 46.93, longitude: -97.25),
        GroundStation(name: "Colburn, ID", latitude: 48.4, longitude: -116.55),
        GroundStation(name: "Conrad, MT", latitude: 48.17, longitude: -111.95),
        GroundStation(name: "Dumas, TX", latitude: 35.8628, longitude: -101.9732),
        GroundStation(name: "Elbert, CO", latitude: 39.2239, longitude: -104.5347),
        GroundStation(name: "Evanston, WY", latitude: 41.2683, longitude: -110.9632),
        GroundStation(name: "Fairbanks, AK", latitude: 64.8378, longitude: -147.7164),
        GroundStation(name: "Fort Lauderdale, FL", latitude: 26.1224, longitude: -80.1373),
        GroundStation(name: "Frederick, MD", latitude: 39.4143, longitude: -77.4105),
        GroundStation(name: "Prosser, WA", latitude: 46.2062, longitude: -119.7673),
        GroundStation(name: "Panaca, NV", latitude: 37.7908, longitude: -114.3876),
        GroundStation(name: "Punta Gorda, FL", latitude: 26.9298, longitude: -82.0454),
        GroundStation(name: "Redmond, WA", latitude: 47.674, longitude: -122.1215),
        GroundStation(name: "McGregor, TX", latitude: 31.4335, longitude: -97.4117),
        GroundStation(name: "Hawthorne, CA", latitude: 33.9164, longitude: -118.3526),
        GroundStation(name: "Kalama, WA", latitude: 46.0082, longitude: -122.8429),
        GroundStation(name: "Roll, AZ", latitude: 32.7548, longitude: -113.9867),
        GroundStation(name: "Vernon, UT", latitude: 40.1042, longitude: -112.4516),
        GroundStation(name: "Lawrence, KS", latitude: 38.9717, longitude: -95.2353),
        GroundStation(name: "Inman, KS", latitude: 38.2317, longitude: -97.7767),
        GroundStation(name: "Tionesta, CA", latitude: 41.64, longitude: -121.33),
        GroundStation(name: "Chico, CA", latitude: 39.7754, longitude: -121.9199),
        GroundStation(name: "Burbank, CA", latitude: 34.2001, longitude: -118.3438),
        GroundStation(name: "Banning, CA", latitude: 33.9191, longitude: -116.8494),
        GroundStation(name: "Cal-Nev-Ari, NV", latitude: 35.2987, longitude: -114.8745),
        GroundStation(name: "Loring, ME", latitude: 46.9506, longitude: -67.8859),
        GroundStation(name: "Calais, ME", latitude: 45.1714, longitude: -67.2476),
        GroundStation(name: "Lockport, NY", latitude: 43.1706, longitude: -78.691),
        GroundStation(name: "Greenville, PA", latitude: 41.4078, longitude: -80.3917),
        GroundStation(name: "Bridgewater, CT", latitude: 41.5454, longitude: -73.3544),
        GroundStation(name: "Calverton, NY", latitude: 40.9089, longitude: -72.7976),
        GroundStation(name: "Manistique, MI", latitude: 45.9572, longitude: -86.2467),
        GroundStation(name: "Duluth, MN", latitude: 46.8281, longitude: -92.1304),
        GroundStation(name: "Eagan, MN", latitude: 44.8393, longitude: -93.1456),
        GroundStation(name: "Dubuque, IA", latitude: 42.4446, longitude: -90.6785),
        GroundStation(name: "Chattanooga, TN", latitude: 35.0317, longitude: -85.2975),
        GroundStation(name: "Chapel Hill, NC", latitude: 35.8958, longitude: -79.2267),
        GroundStation(name: "Wise, NC", latitude: 36.5035, longitude: -78.1719),
        GroundStation(name: "Charleston, SC", latitude: 32.7765, longitude: -79.9311),
        GroundStation(name: "Norcross, GA", latitude: 33.9417, longitude: -84.2139),
        GroundStation(name: "Clarksville, GA", latitude: 34.6485, longitude: -83.5473),
        GroundStation(name: "Robertsdale, AL", latitude: 30.5532, longitude: -87.7111),
        GroundStation(name: "New Braunfels, TX", latitude: 29.703, longitude: -98.1245),
        GroundStation(name: "Sanderson, TX", latitude: 30.1418, longitude: -102.3957),
        GroundStation(name: "Nome, AK", latitude: 64.5011, longitude: -165.4064),
        GroundStation(name: "Ketchikan, AK", latitude: 55.3422, longitude: -131.6461),
        GroundStation(name: "Molokai, HI", latitude: 21.1356, longitude: -157.0189),
        GroundStation(name: "Kuparuk, AK", latitude: 70.3342, longitude: -149.5946),
        // Rest of world (operational per 2025 dataset)
        GroundStation(name: "Aerzen, Germany", latitude: 52.0489, longitude: 9.2683),
        GroundStation(name: "Awarua, NZ", latitude: -46.5294, longitude: 168.3781),
        GroundStation(name: "Ballinspittle, Ireland", latitude: 51.6508, longitude: -8.5808),
        GroundStation(name: "Elfordstown, Ireland", latitude: 52.0833, longitude: -8.25),
        GroundStation(name: "Chalfont Grove, UK", latitude: 51.6167, longitude: -0.5667),
        GroundStation(name: "Foggia, Italy", latitude: 41.4621, longitude: 15.5444),
        GroundStation(name: "Boorowa, Australia", latitude: -34.4392, longitude: 148.7142),
        GroundStation(name: "Broken Hill, Australia", latitude: -31.9505, longitude: 141.4681),
        GroundStation(name: "Akita, Japan", latitude: 39.72, longitude: 140.1024),
        GroundStation(name: "Angeles, Philippines", latitude: 15.145, longitude: 120.5887),
        GroundStation(name: "Caldera, Chile", latitude: -27.0667, longitude: -70.8167),
        GroundStation(name: "Camaçari, Brazil", latitude: -12.6996, longitude: -38.3263),
        GroundStation(name: "Falda del Carmen, Argentina", latitude: -31.5333, longitude: -64.45),
        GroundStation(name: "Charcas, Mexico", latitude: 23.1314, longitude: -101.1136),
        GroundStation(name: "Cabo San Lucas, Mexico", latitude: 22.8905, longitude: -109.9167),
        // Nigeria: NCC licensed 5 Ka-band gateway earth stations 04/07/2022
        // (Tarau, Ibeju Lekki, Ikire, Sakpenwa, Murfa/Kalam) and Aug-2024
        // press reports builds in Okun Ajah (Lagos), Sagamu (Ogun) and
        // Port Harcourt (Rivers). Pins below are the mappable ones; Tarau and
        // Murfa/Kalam have no public coordinates, so they are intentionally
        // unmapped rather than guessed.
        GroundStation(name: "Lekki, Nigeria", latitude: 6.4698, longitude: 3.6015, approx: true),
        GroundStation(name: "Sagamu, Nigeria", latitude: 6.8333, longitude: 3.65, approx: true),
        GroundStation(name: "Port Harcourt, Nigeria", latitude: 4.78, longitude: 7.01, approx: true),
        GroundStation(name: "Ikire, Nigeria", latitude: 7.37, longitude: 4.18, approx: true),
    ]

    /// Nearest `count` stations to the observer with great-circle distances.
    static func nearest(to observer: ObserverLocation, count: Int = 5) -> [(station: GroundStation, km: Double)] {
        all.map { ($0, haversineKm(
            lat1: observer.latitude, lon1: observer.longitude,
            lat2: $0.latitude, lon2: $0.longitude
        )) }
        .sorted { $0.1 < $1.1 }
        .prefix(count)
        .map { $0 }
    }

    static func haversineKm(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
        let d2r = Double.pi / 180
        let dLat = (lat2 - lat1) * d2r
        let dLon = (lon2 - lon1) * d2r
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1 * d2r) * cos(lat2 * d2r) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * 6371.0 * asin(min(1, sqrt(a)))
    }
}
