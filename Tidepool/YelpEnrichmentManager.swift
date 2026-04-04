import Foundation
import CoreLocation
import TidepoolShared

/// Enriches a LocationDetail with Yelp data (hours, photos, rating, price) via the backend proxy.
@MainActor
class YelpEnrichmentManager: ObservableObject {
    static let shared = YelpEnrichmentManager()

    /// Cached enrichment keyed by stable place ID
    private var cache: [String: YelpEnrichment] = [:]

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

    /// Fetch Yelp enrichment for a place. Returns cached result if available.
    func enrich(name: String, coordinate: CLLocationCoordinate2D) async -> YelpEnrichment? {
        let cacheKey = "\(name.lowercased()):\(String(format: "%.4f", coordinate.latitude)):\(String(format: "%.4f", coordinate.longitude))"

        if let cached = cache[cacheKey] {
            return cached
        }

        guard BackendClient.shared.isAuthenticated else { return nil }

        do {
            let detail = try await BackendClient.shared.matchPlace(name: name, lat: coordinate.latitude, lng: coordinate.longitude)
            let enrichment = mapToEnrichment(detail)
            cache[cacheKey] = enrichment
            return enrichment
        } catch {
            print("[YelpEnrichment] Failed to enrich '\(name)': \(error.localizedDescription)")
            return nil
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
