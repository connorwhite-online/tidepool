import Foundation
import Combine
import CoreLocation
import TidepoolShared

/// Enriches a LocationDetail with Yelp data (hours, photos, rating, price) via the backend proxy.
@MainActor
class YelpEnrichmentManager: ObservableObject {
    static let shared = YelpEnrichmentManager()

    /// Cached enrichment keyed by stable place ID. Bounded LRU so a long
    /// browsing session doesn't accumulate every place the user opened.
    private var cache: [String: YelpEnrichment] = [:]
    private var cacheOrder: [String] = []
    private let cacheMax = 200

    /// In-flight requests keyed by cacheKey. Two rapid taps on the same POI
    /// (or two views appearing simultaneously) coalesce into one network
    /// call instead of racing.
    private var inFlight: [String: Task<YelpEnrichment?, Never>] = [:]

    struct YelpEnrichment {
        let yelpID: String
        let rating: Double?
        let reviewCount: Int?
        let price: LocationDetail.PriceLevel?
        let hours: BusinessHours?
        let photos: [LocationImage]
        let phone: String?
        let isOpenNow: Bool?
    }

    /// Fetch Yelp enrichment for a place. Returns cached result if available,
    /// otherwise dedups concurrent calls for the same key.
    func enrich(name: String, coordinate: CLLocationCoordinate2D) async -> YelpEnrichment? {
        let cacheKey = "\(name.lowercased()):\(String(format: "%.4f", coordinate.latitude)):\(String(format: "%.4f", coordinate.longitude))"

        if let cached = cache[cacheKey] {
            return cached
        }

        if let existing = inFlight[cacheKey] {
            return await existing.value
        }

        let task = Task { [weak self] () -> YelpEnrichment? in
            await self?.performEnrich(name: name, coordinate: coordinate, cacheKey: cacheKey) ?? nil
        }
        inFlight[cacheKey] = task
        defer { inFlight[cacheKey] = nil }
        return await task.value
    }

    private func performEnrich(name: String, coordinate: CLLocationCoordinate2D, cacheKey: String) async -> YelpEnrichment? {
        if !BackendClient.shared.isAuthenticated {
            print("[Enrichment] Not authenticated, waiting briefly...")
            // Resume the moment auth flips, instead of polling every 500ms.
            // Cap the wait at 3s to avoid hanging forever if auth fails.
            let authPublisher = BackendClient.shared.$isAuthenticated
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    for await isAuth in authPublisher.values where isAuth { return }
                }
                group.addTask {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                }
                _ = await group.next()
                group.cancelAll()
            }
        }

        guard BackendClient.shared.isAuthenticated else {
            print("[Enrichment] Still not authenticated after waiting, skipping '\(name)'")
            return nil
        }

        do {
            print("[Enrichment] Fetching for '\(name)' at \(coordinate.latitude), \(coordinate.longitude)")
            let detail = try await BackendClient.shared.matchPlace(name: name, lat: coordinate.latitude, lng: coordinate.longitude)
            print("[Enrichment] Got: \(detail.name), rating: \(detail.rating ?? 0), photos: \(detail.photos?.count ?? 0)")
            let enrichment = mapToEnrichment(detail)
            store(enrichment, for: cacheKey)
            return enrichment
        } catch {
            print("[Enrichment] Failed '\(name)': \(error.localizedDescription)")
            return nil
        }
    }

    private func store(_ enrichment: YelpEnrichment, for cacheKey: String) {
        cache[cacheKey] = enrichment
        cacheOrder.append(cacheKey)
        if cacheOrder.count > cacheMax, let evict = cacheOrder.first {
            cacheOrder.removeFirst()
            cache.removeValue(forKey: evict)
        }
    }

    private func mapToEnrichment(_ detail: PlaceDetail) -> YelpEnrichment {
        let priceLevel: LocationDetail.PriceLevel? = detail.price.flatMap { price in
            switch price.count {
            case 1: return .budget
            case 2: return .moderate
            case 3: return .expensive
            case 4: return .luxury
            default: return nil
            }
        }

        let hours: BusinessHours? = detail.hours.flatMap { dayHours in
            guard !dayHours.isEmpty else { return nil }
            let periods = dayHours.compactMap { dh -> BusinessHours.Period? in
                guard dh.start.count == 4, dh.end.count == 4 else { return nil }
                let openHour = Int(dh.start.prefix(2)) ?? 0
                let openMin = Int(dh.start.suffix(2)) ?? 0
                let closeHour = Int(dh.end.prefix(2)) ?? 0
                let closeMin = Int(dh.end.suffix(2)) ?? 0

                // Yelp uses 0=Monday, our Weekday uses 1=Sunday..7=Saturday
                // Convert: Yelp 0(Mon)→our 2, Yelp 1(Tue)→our 3, ..., Yelp 6(Sun)→our 1
                let weekdayRaw = dh.day == 6 ? 1 : dh.day + 2
                guard let weekday = BusinessHours.Weekday(rawValue: weekdayRaw) else { return nil }

                return BusinessHours.Period(
                    open: BusinessHours.Time(hour: openHour, minute: openMin),
                    close: BusinessHours.Time(hour: closeHour, minute: closeMin),
                    day: weekday
                )
            }
            return BusinessHours(periods: periods, isOpenNow: detail.isOpenNow ?? false)
        }

        let photos: [LocationImage] = (detail.photos ?? []).compactMap { urlString in
            guard let url = URL(string: urlString) else { return nil }
            return LocationImage(url: url, caption: nil, aspectRatio: 1.5)
        }

        return YelpEnrichment(
            yelpID: detail.yelpID,
            rating: detail.rating.map { Double($0) },
            reviewCount: detail.reviewCount,
            price: priceLevel,
            hours: hours,
            photos: photos,
            phone: detail.phone,
            isOpenNow: detail.isOpenNow
        )
    }
}
