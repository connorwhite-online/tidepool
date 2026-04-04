import SwiftUI
import MapKit
import CoreLocation
import TidepoolShared

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
    @State private var heatFetchTask: Task<Void, Never>?
    @State private var lastFetchedTileSet: Set<String> = []
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
                },
                onRegionChanged: { region in
                    debouncedFetchHeatTiles(region: region)
                }
            )
            .ignoresSafeArea()
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
                updatePresenceOverlay()
                updateTileId()
                presenceReporter.start(using: location)
            }
            .onDisappear {
                presenceReporter.stop()
                heatFetchTask?.cancel()
            }
            .onChange(of: location.latestLocation) { _, _ in
                updatePresenceOverlay()
                updateTileId()
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

    // MARK: - Heat Tile Fetching

    private func debouncedFetchHeatTiles(region: MKCoordinateRegion) {
        heatFetchTask?.cancel()
        heatFetchTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s debounce
            guard !Task.isCancelled else { return }
            await fetchHeatTiles(region: region)
        }
    }

    private func fetchHeatTiles(region: MKCoordinateRegion) async {
        let sw = Coordinate(
            latitude: region.center.latitude - region.span.latitudeDelta / 2,
            longitude: region.center.longitude - region.span.longitudeDelta / 2
        )
        let ne = Coordinate(
            latitude: region.center.latitude + region.span.latitudeDelta / 2,
            longitude: region.center.longitude + region.span.longitudeDelta / 2
        )

        // Skip if the viewport covers the same corner tiles as last fetch
        let swTile = Tiling.current.tileIdString(for: CLLocationCoordinate2D(latitude: sw.latitude, longitude: sw.longitude))
        let neTile = Tiling.current.tileIdString(for: CLLocationCoordinate2D(latitude: ne.latitude, longitude: ne.longitude))
        let tileSet: Set<String> = [swTile, neTile]
        guard tileSet != lastFetchedTileSet else { return }
        lastFetchedTileSet = tileSet

        let request = HeatTileRequest(
            viewport: Viewport(ne: ne, sw: sw),
            viewerVector: nil
        )

        do {
            let response = try await BackendClient.shared.fetchHeatTiles(request)
            let groups = response.tiles.compactMap { tile -> HeatBlobGroup? in
                guard let center = coordinateFromTileID(tile.tileID) else { return nil }
                let points = syntheticPoints(around: center, count: tile.contributorCount)
                return HeatBlobGroup(
                    points: points,
                    baseIntensity: CGFloat(tile.intensity),
                    perUserRadiusMeters: 40
                )
            }
            heatBlobGroups = groups
        } catch {
            print("[MapHomeView] heat tile fetch failed: \(error.localizedDescription)")
        }
    }

    /// Parse a tile ID string like "grid_150_m_X_Y" back to its center coordinate.
    private func coordinateFromTileID(_ tileID: String) -> CLLocationCoordinate2D? {
        let parts = tileID.split(separator: "_")
        // Expected format: grid_150_m_X_Y
        guard parts.count == 5,
              let metersPerTile = Int(parts[1]),
              let x = Int(parts[3]),
              let y = Int(parts[4]) else { return nil }

        let latMeters = 111_000.0
        let dLat = Double(metersPerTile) / latMeters
        // Center of tile
        let lat = (Double(y) + 0.5) * dLat - 90.0
        let lonMeters = latMeters * cos(lat * .pi / 180)
        let dLon = Double(metersPerTile) / lonMeters
        let lon = (Double(x) + 0.5) * dLon - 180.0
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    /// Generate jittered points around a center to give heat blobs an organic look.
    private func syntheticPoints(around center: CLLocationCoordinate2D, count: Int) -> [CLLocationCoordinate2D] {
        let clamped = min(max(count, 3), 15)
        let metersPerDegreeLat = 111_000.0
        return (0..<clamped).map { i in
            let angle = Double(i) * (2 * .pi / Double(clamped)) + Double.random(in: -0.3...0.3)
            let radius = Double.random(in: 5...30)
            let dLat = radius * cos(angle) / metersPerDegreeLat
            let dLon = radius * sin(angle) / (metersPerDegreeLat * cos(center.latitude * .pi / 180))
            return CLLocationCoordinate2D(latitude: center.latitude + dLat, longitude: center.longitude + dLon)
        }
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