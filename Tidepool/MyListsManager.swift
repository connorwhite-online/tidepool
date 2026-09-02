import Combine
import Foundation
import CoreLocation
import TidepoolShared

/// Loads and caches location-scoped "My Lists" compiled from visits and favorites.
@MainActor
final class MyListsManager: ObservableObject {
    static let shared = MyListsManager()

    @Published private(set) var response: MyListsResponse?
    @Published private(set) var isLoading = false
    @Published private(set) var lastError: String?

    private var loadTask: Task<Void, Never>?
    private var lastCenter: Coordinate?
    private var lastRadiusMiles: Double = 10

    /// Refresh lists for the given location. Debounces in-flight requests.
    func refresh(
        near coordinate: CLLocationCoordinate2D,
        radiusMiles: Double = 10,
        favorites: [FavoriteLocation] = [],
        pendingVisits: [VisitReport] = []
    ) {
        let center = Coordinate(latitude: coordinate.latitude, longitude: coordinate.longitude)
        lastCenter = center
        lastRadiusMiles = radiusMiles

        loadTask?.cancel()
        loadTask = Task {
            isLoading = true
            lastError = nil
            defer { isLoading = false }

            if BackendClient.shared.isAuthenticated {
                do {
                    let remote = try await BackendClient.shared.getMyLists(
                        lat: center.latitude,
                        lng: center.longitude,
                        radiusMiles: radiusMiles
                    )
                    guard !Task.isCancelled else { return }
                    response = remote
                    return
                } catch {
                    guard !Task.isCancelled else { return }
                    lastError = error.localizedDescription
                    print("[MyLists] server fetch failed: \(error.localizedDescription)")
                }
            }

            // Offline / fallback: compile locally from pending visits + favorites.
            let local = compileLocally(
                center: center,
                radiusMiles: radiusMiles,
                favorites: favorites,
                pendingVisits: pendingVisits
            )
            guard !Task.isCancelled else { return }
            response = local
        }
    }

    /// Non-empty lists for UI, in display order.
    var lists: [MyList] {
        response?.lists ?? []
    }

    /// Pre-sorted locale rankings for recommendation blending.
    var localeRankings: [LocalePlaceRanking] {
        response?.meta.localeRankings ?? []
    }

    private func compileLocally(
        center: Coordinate,
        radiusMiles: Double,
        favorites: [FavoriteLocation],
        pendingVisits: [VisitReport]
    ) -> MyListsResponse {
        let iso = ISO8601DateFormatter()
        var aggregated: [String: (visitCount: Int, totalDuration: Int, hours: Set<Int>, lastVisit: Date?, report: VisitReport)] = [:]

        for visit in pendingVisits {
            let placeId = FavoriteLocation.stablePlaceId(
                name: visit.name,
                coordinate: CLLocationCoordinate2D(latitude: visit.latitude, longitude: visit.longitude)
            )
            var entry = aggregated[placeId] ?? (0, 0, [], nil, visit)
            entry.visitCount += 1
            entry.totalDuration += visit.durationMinutes
            entry.hours.insert(visit.hourOfDay)
            if let arrived = iso.date(from: visit.arrivedAt) {
                if entry.lastVisit == nil || arrived > entry.lastVisit! {
                    entry.lastVisit = arrived
                }
            }
            entry.report = visit
            aggregated[placeId] = entry
        }

        let favByPlaceID = Dictionary(uniqueKeysWithValues: favorites.map { ($0.placeId, $0) })
        var signals: [MyListPlaceSignal] = []
        var seen = Set<String>()

        for (placeId, entry) in aggregated {
            seen.insert(placeId)
            let fav = favByPlaceID[placeId]
            let avgDuration = entry.visitCount > 0 ? entry.totalDuration / entry.visitCount : 0
            signals.append(MyListPlaceSignal(
                poiId: entry.report.poiId,
                yelpId: entry.report.yelpId,
                placeId: placeId,
                name: entry.report.name,
                category: entry.report.category,
                latitude: entry.report.latitude,
                longitude: entry.report.longitude,
                visitCount: entry.visitCount,
                avgDurationMinutes: avgDuration,
                typicalHours: Array(entry.hours).sorted(),
                lastVisit: entry.lastVisit,
                favoriteRating: fav?.rating,
                isExplicitFavorite: fav != nil
            ))
        }

        for fav in favorites where !seen.contains(fav.placeId) {
            signals.append(MyListPlaceSignal(
                poiId: nil,
                yelpId: nil,
                placeId: fav.placeId,
                name: fav.name,
                category: TidepoolShared.PlaceCategory(rawValue: fav.category.rawValue) ?? .other,
                latitude: fav.coordinate.latitude,
                longitude: fav.coordinate.longitude,
                visitCount: max(fav.visitCount, 1),
                avgDurationMinutes: 30,
                typicalHours: [],
                lastVisit: fav.lastVisited ?? fav.createdAt,
                favoriteRating: fav.rating,
                isExplicitFavorite: true
            ))
        }

        return MyListsEngine.compile(
            signals: signals,
            options: MyListsCompileOptions(center: center, radiusMiles: radiusMiles)
        )
    }
}
