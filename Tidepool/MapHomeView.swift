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
    // POI annotations are now handled natively by MapKit
    @State private var mockSpotsLoaded: Bool = false
    // Hysteresis thresholds to prevent rapid toggling near boundary
    private let homeHideInnerRadiusMeters: CLLocationDistance = 137.16 // 450 ft
    private let homeShowOuterRadiusMeters: CLLocationDistance = 167.64 // 550 ft
    @State private var isPresenceVisible: Bool = false

    private let homeHideRadiusMeters: CLLocationDistance = 152.4 // 500 ft
    private let presenceRadiusMeters: CLLocationDistance = 30.48  // 100 ft

    @State private var currentTileIdDescription: String = "—"
    @State private var showTileHUD: Bool = false
    private let presenceReporter = PresenceReporter()
    
    // Location detail sheet
    @Binding var selectedLocationDetail: LocationDetail?
    @Binding var mapCenterCoordinate: CLLocationCoordinate2D
    @Binding var navigateToCoordinate: CLLocationCoordinate2D?
    @Binding var searchResultPin: POIAnnotation?
    @EnvironmentObject var favoritesManager: InAppFavoritesManager

    private var searchPinAnnotations: [POIAnnotation] {
        if let pin = searchResultPin { return [pin] } else { return [] }
    }

    private var mapView: some View {
        ZStack(alignment: .center) {
            MapViewRepresentable(
                presenceOverlays: presenceOverlays,
                heatOverlays: heatOverlays,
                heatBlobGroups: heatBlobGroups,
                highContrast: true,
                poiAnnotations: searchPinAnnotations,
                isDetailShowing: selectedLocationDetail != nil,
                navigateToCoordinate: $navigateToCoordinate,
                onAnnotationTap: { annotation, tapPoint in
                    handleAnnotationTap(annotation: annotation, tapPoint: tapPoint)
                },
                onCenterChanged: { center in
                    mapCenterCoordinate = center
                }
            )
            .ignoresSafeArea()

            if heatBlobGroups.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "map")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("Explore hotspots nearby")
                        .foregroundStyle(.secondary)
                }
                .padding(12)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if showTileHUD {
                debugTileIdHUD
                    .padding(.trailing, 16)
                    .padding(.bottom, 100)
            }
        }
    }

    var body: some View {
        mapView
            .onAppear {
                location.requestAuthorization()
                if !mockSpotsLoaded {
                    loadMockHeatSpots()
                    mockSpotsLoaded = true
                }
                updatePresenceOverlay()
                updateTileId()
                // POIs are now handled natively by MapKit
                presenceReporter.start(using: location)
            }
            .onDisappear {
                presenceReporter.stop()
            }
            .onChange(of: location.latestLocation) { _, _ in
                updatePresenceOverlay()
                updateTileId()
                // POIs are now handled natively by MapKit
            }
            .onChange(of: heatBlobGroups) { _, _ in
                // Heat blobs updated - no need to refresh POIs as they're native
            }
    }

    private var debugTileIdHUD: some View {
        Text("Tile: \(currentTileIdDescription)")
            .font(.footnote)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
    }

    private func updateTileId() {
        if let coord = location.latestLocation?.coordinate {
            currentTileIdDescription = Tiling.current.tileIdString(for: coord)
        } else {
            currentTileIdDescription = "—"
        }
    }

    private func updatePresenceOverlay(force: Bool = false) {
        guard let userLoc = location.latestLocation else { return }
        var newVisible: Bool
        if let home = location.homeLocation {
            let homeCL = CLLocation(latitude: home.latitude, longitude: home.longitude)
            let distance = userLoc.distance(from: homeCL)
            if force {
                newVisible = distance >= homeHideRadiusMeters
            } else if isPresenceVisible {
                // Once visible, hide only when well inside inner threshold
                newVisible = distance >= homeHideInnerRadiusMeters
            } else {
                // Once hidden, show only when well outside outer threshold
                newVisible = distance >= homeShowOuterRadiusMeters
            }
        } else {
            newVisible = true
        }

        isPresenceVisible = newVisible
        if newVisible {
            presenceOverlays = [PresenceCircleOverlay(coordinate: userLoc.coordinate, radiusMeters: presenceRadiusMeters)]
        } else {
            presenceOverlays = []
        }
    }

    // MARK: - POIs are now handled natively by MapKit

    private func isCoordinateInsideAnyHeat(_ coord: CLLocationCoordinate2D) -> Bool {
        // Approximate: within any blob group's stroked hull radius envelope
        for group in heatBlobGroups {
            guard let first = group.points.first else { continue }
            // Use distance to each point within group allowing per-user radius + a small blend
            for p in group.points {
                let d = distanceMeters(coord, p)
                if d <= group.perUserRadiusMeters * 1.2 { return true }
            }
            // Fallback: within 80 m of group centroid
            let centroid = centroidOf(group.points)
            if distanceMeters(coord, centroid) <= max(80, group.perUserRadiusMeters) { return true }
            _ = first // silence unused warning if needed
        }
        return false
    }

    private func centroidOf(_ coords: [CLLocationCoordinate2D]) -> CLLocationCoordinate2D {
        var sx: Double = 0, sy: Double = 0
        for c in coords { sx += c.latitude; sy += c.longitude }
        let n = Double(max(coords.count, 1))
        return CLLocationCoordinate2D(latitude: sx / n, longitude: sy / n)
    }

    private func distanceMeters(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> CLLocationDistance {
        let la = CLLocation(latitude: a.latitude, longitude: a.longitude)
        let lb = CLLocation(latitude: b.latitude, longitude: b.longitude)
        return la.distance(from: lb)
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
            // POIs are now handled natively by MapKit
        }
    }

    private func offsetCoordinate(from base: CLLocationCoordinate2D, metersNorth: Double, metersEast: Double) -> CLLocationCoordinate2D {
        let metersPerDegreeLat = 111_000.0
        let deltaLat = metersNorth / metersPerDegreeLat
        let deltaLon = metersEast / (metersPerDegreeLat * cos(base.latitude * .pi / 180))
        return CLLocationCoordinate2D(latitude: base.latitude + deltaLat, longitude: base.longitude + deltaLon)
    }
    
    // MARK: - Location Detail Sheet
    
    private func handleAnnotationTap(annotation: POIAnnotation, tapPoint: CGPoint) {
        selectedLocationDetail = createLocationDetail(from: annotation)
        HapticFeedbackManager.shared.impact(.light)
    }
    
    private func createLocationDetail(from annotation: POIAnnotation) -> LocationDetail {
        let category = mapPOICategoryToPlaceCategory(annotation.subtitle)
        let name = annotation.title ?? "Unknown Place"
        let stablePlaceId = FavoriteLocation.stablePlaceId(name: name, coordinate: annotation.coordinate)
        let favorite = favoritesManager.getFavorite(for: stablePlaceId)

        let favoriteStatus: LocationDetail.FavoriteStatus
        if let fav = favorite {
            favoriteStatus = .favorited(rating: fav.rating ?? 0, notes: fav.notes)
        } else {
            favoriteStatus = .notFavorited
        }

        return LocationDetail(
            name: name,
            category: category,
            coordinate: annotation.coordinate,
            address: nil,
            phoneNumber: nil,
            website: nil,
            hours: nil,
            images: [],
            rating: favorite.flatMap { $0.rating }.map { Double($0) },
            priceLevel: nil,
            amenities: [],
            userFavoriteStatus: favoriteStatus
        )
    }
    
    private func mapPOICategoryToPlaceCategory(_ poiCategory: String?) -> PlaceCategory {
        guard let category = poiCategory?.lowercased() else { return .other }
        
        switch category {
        case let c where c.contains("restaurant") || c.contains("food"):
            return .restaurant
        case let c where c.contains("cafe") || c.contains("coffee"):
            return .cafe
        case let c where c.contains("bar") || c.contains("nightlife"):
            return .bar
        case let c where c.contains("park"):
            return .park
        case let c where c.contains("store") || c.contains("shop") || c.contains("retail"):
            return .shopping
        case let c where c.contains("museum"):
            return .museum
        case let c where c.contains("gym") || c.contains("fitness") || c.contains("fitnesscenter"):
            return .gym
        case let c where c.contains("hospital") || c.contains("medical"):
            return .hospital
        case let c where c.contains("school") || c.contains("university"):
            return .school
        case let c where c.contains("library"):
            return .library
        case let c where c.contains("gas"):
            return .gasStation
        case let c where c.contains("pharmacy") || c.contains("bank"):
            return .bank
        default:
            return .other
        }
    }
    
} 