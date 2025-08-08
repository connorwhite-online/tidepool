import SwiftUI
import MapKit
import CoreLocation

struct PresenceCircleOverlay: Identifiable {
    let id = UUID()
    let coordinate: CLLocationCoordinate2D
    let radiusMeters: CLLocationDistance
}

struct MapHomeView: View {
    @StateObject private var location = LocationManager()
    @State private var presenceOverlays: [PresenceCircleOverlay] = []
    @State private var heatOverlays: [HeatCircleOverlay] = []
    @State private var heatBlobGroups: [HeatBlobGroup] = []
    @State private var mockSpotsLoaded: Bool = false

    private let homeHideRadiusMeters: CLLocationDistance = 152.4 // 500 ft
    private let presenceRadiusMeters: CLLocationDistance = 30.48  // 100 ft

    private var mapView: some View {
        MapViewRepresentable(
            presenceOverlays: presenceOverlays,
            heatOverlays: heatOverlays,
            heatBlobGroups: heatBlobGroups
        )
        .ignoresSafeArea(edges: .top)
    }

    var body: some View {
        NavigationStack {
            mapView
                .onAppear {
                    location.requestAuthorization()
                    if !mockSpotsLoaded {
                        loadMockHeatSpots()
                        mockSpotsLoaded = true
                    }
                }
                .onChange(of: location.latestLocation) { _, _ in
                    updatePresenceOverlay()
                }
                .toolbar(.hidden, for: .navigationBar)
        }
    }

    private func updatePresenceOverlay(force: Bool = false) {
        guard let userLoc = location.latestLocation else { return }
        var shouldShow = false
        if let home = location.homeLocation {
            let homeCL = CLLocation(latitude: home.latitude, longitude: home.longitude)
            let distance = userLoc.distance(from: homeCL)
            shouldShow = distance >= homeHideRadiusMeters
        } else {
            shouldShow = true
        }

        if shouldShow || force {
            presenceOverlays = [PresenceCircleOverlay(coordinate: userLoc.coordinate, radiusMeters: presenceRadiusMeters)]
        } else {
            presenceOverlays = []
        }
    }

    // MARK: - Mock Heat Spots (Search -> Geocode -> Hardcoded fallback)

    private func loadMockHeatSpots() {
        let spots: [(name: String, query: String, baseIntensity: CGFloat)] = [
            ("Erewhon Silver Lake", "Erewhon 4121 Santa Monica Blvd, Los Angeles, CA 90029", 0.85),
            ("Seco Silverlake", "Seco 3820 W Sunset Blvd, Los Angeles, CA 90026", 0.75),
            ("Bar Sinitzki", "Bar Sinitzki 3147 Glendale Blvd, Los Angeles, CA 90039", 0.70)
        ]

        // Hardcoded fallbacks (approximate)
        let fallbackCoords: [String: CLLocationCoordinate2D] = [
            "Erewhon Silver Lake": CLLocationCoordinate2D(latitude: 34.0909, longitude: -118.2826),
            "Seco Silverlake": CLLocationCoordinate2D(latitude: 34.0928, longitude: -118.2829),
            "Bar Sinitzki": CLLocationCoordinate2D(latitude: 34.1159, longitude: -118.2604)
        ]

        // Per-user radius ~40 m
        let circleRadiusMeters: CLLocationDistance = 40

        // Deterministic jitter pattern (metersNorth, metersEast, intensityScale)
        let jitter: [(Double, Double, CGFloat)] = [
            (0,    0,    1.00),
            (8,    5,    0.85),
            (-10,  12,   0.78),
            (15,   -6,   0.70),
            (-14,  -9,   0.72),
            (22,   3,    0.60),
            (-6,   18,   0.65),
            (5,    -16,  0.68),
            (12,   -12,  0.62),
            (-18,  7,    0.58)
        ]

        var groups: [HeatBlobGroup] = []
        let group = DispatchGroup()

        let searchRegion: MKCoordinateRegion = {
            if let userLoc = location.latestLocation?.coordinate {
                return MKCoordinateRegion(center: userLoc, span: MKCoordinateSpan(latitudeDelta: 0.15, longitudeDelta: 0.15))
            } else {
                // Default to Silver Lake/Atwater vicinity
                return MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 34.096, longitude: -118.273), span: MKCoordinateSpan(latitudeDelta: 0.18, longitudeDelta: 0.18))
            }
        }()

        let geocoder = CLGeocoder()

        for spot in spots {
            group.enter()
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = spot.query
            request.region = searchRegion
            MKLocalSearch(request: request).start { response, _ in
                let baseCoord: CLLocationCoordinate2D? = response?.mapItems.first?.placemark.location?.coordinate
                    ?? fallbackCoords[spot.name]

                if let c = baseCoord {
                    let pts: [CLLocationCoordinate2D] = jitter.map { j in
                        offsetCoordinate(from: c, metersNorth: j.0, metersEast: j.1)
                    }
                    groups.append(HeatBlobGroup(points: pts, baseIntensity: spot.baseIntensity, perUserRadiusMeters: circleRadiusMeters))
                    group.leave()
                } else {
                    geocoder.geocodeAddressString(spot.query) { placemarks, _ in
                        let gc = placemarks?.first?.location?.coordinate ?? fallbackCoords[spot.name]
                        if let c = gc {
                            let pts: [CLLocationCoordinate2D] = jitter.map { j in
                                offsetCoordinate(from: c, metersNorth: j.0, metersEast: j.1)
                            }
                            groups.append(HeatBlobGroup(points: pts, baseIntensity: spot.baseIntensity, perUserRadiusMeters: circleRadiusMeters))
                        }
                        group.leave()
                    }
                }
            }
        }

        group.notify(queue: .main) {
            heatBlobGroups = groups
            heatOverlays = [] // no per-point circles needed when using blob
        }
    }

    private func offsetCoordinate(from base: CLLocationCoordinate2D, metersNorth: Double, metersEast: Double) -> CLLocationCoordinate2D {
        let metersPerDegreeLat = 111_000.0
        let deltaLat = metersNorth / metersPerDegreeLat
        let deltaLon = metersEast / (metersPerDegreeLat * cos(base.latitude * .pi / 180))
        return CLLocationCoordinate2D(latitude: base.latitude + deltaLat, longitude: base.longitude + deltaLon)
    }
} 