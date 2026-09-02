import Foundation

// MARK: - Categories

/// Curated list buckets compiled automatically from visit patterns and favorites.
public enum MyListCategory: String, Codable, CaseIterable, Sendable {
    case coffee
    case breakfast
    case lunch
    case dinner
    case lateNight = "late_night"
    case movies
    case beaches
    case parks
    case nightlife
    case shopping
    case fitness
    case favorites

    public var displayName: String {
        switch self {
        case .coffee: return "Coffee"
        case .breakfast: return "Breakfast"
        case .lunch: return "Lunch"
        case .dinner: return "Dinner"
        case .lateNight: return "Late Night"
        case .movies: return "Movies"
        case .beaches: return "Beaches"
        case .parks: return "Parks"
        case .nightlife: return "Nightlife"
        case .shopping: return "Shopping"
        case .fitness: return "Fitness"
        case .favorites: return "Favorites"
        }
    }

    public var iconName: String {
        switch self {
        case .coffee: return "cup.and.saucer.fill"
        case .breakfast: return "sunrise.fill"
        case .lunch: return "sun.max.fill"
        case .dinner: return "moon.stars.fill"
        case .lateNight: return "moon.fill"
        case .movies: return "film.fill"
        case .beaches: return "beach.umbrella.fill"
        case .parks: return "tree.fill"
        case .nightlife: return "music.note.house.fill"
        case .shopping: return "bag.fill"
        case .fitness: return "dumbbell.fill"
        case .favorites: return "star.fill"
        }
    }

    /// Display order for UI carousels.
    public static let displayOrder: [MyListCategory] = [
        .favorites, .coffee, .breakfast, .lunch, .dinner, .lateNight,
        .movies, .beaches, .parks, .nightlife, .shopping, .fitness
    ]
}

// MARK: - Input models

/// Aggregated visit signal for one POI, before list compilation.
public struct MyListPlaceSignal: Sendable {
    public let poiId: String?
    public let yelpId: String?
    public let placeId: String
    public let name: String
    public let category: PlaceCategory
    public let latitude: Double
    public let longitude: Double
    public let visitCount: Int
    public let avgDurationMinutes: Int
    public let typicalHours: [Int]
    public let lastVisit: Date?
    public let favoriteRating: Int?
    public let isExplicitFavorite: Bool

    public init(
        poiId: String?,
        yelpId: String?,
        placeId: String,
        name: String,
        category: PlaceCategory,
        latitude: Double,
        longitude: Double,
        visitCount: Int,
        avgDurationMinutes: Int,
        typicalHours: [Int],
        lastVisit: Date?,
        favoriteRating: Int?,
        isExplicitFavorite: Bool
    ) {
        self.poiId = poiId
        self.yelpId = yelpId
        self.placeId = placeId
        self.name = name
        self.category = category
        self.latitude = latitude
        self.longitude = longitude
        self.visitCount = visitCount
        self.avgDurationMinutes = avgDurationMinutes
        self.typicalHours = typicalHours
        self.lastVisit = lastVisit
        self.favoriteRating = favoriteRating
        self.isExplicitFavorite = isExplicitFavorite
    }
}

public struct MyListsCompileOptions: Sendable {
    public let center: Coordinate
    public let radiusMiles: Double
    public let minVisitCount: Int
    public let maxPlacesPerList: Int
    public let referenceDate: Date

    public init(
        center: Coordinate,
        radiusMiles: Double = 10,
        minVisitCount: Int = 2,
        maxPlacesPerList: Int = 20,
        referenceDate: Date = Date()
    ) {
        self.center = center
        self.radiusMiles = radiusMiles
        self.minVisitCount = minVisitCount
        self.maxPlacesPerList = maxPlacesPerList
        self.referenceDate = referenceDate
    }

    public var radiusMeters: Double { radiusMiles * 1609.344 }
}

// MARK: - Output models

public struct MyListPlace: Codable, Sendable, Hashable {
    public let poiId: String?
    public let yelpId: String?
    public let placeId: String
    public let name: String
    public let category: PlaceCategory
    public let latitude: Double
    public let longitude: Double
    public let visitCount: Int
    public let avgDurationMinutes: Int
    public let score: Float
    public let distanceMeters: Double
    public let lastVisit: String?
    public let isExplicitFavorite: Bool

    public init(
        poiId: String?,
        yelpId: String?,
        placeId: String,
        name: String,
        category: PlaceCategory,
        latitude: Double,
        longitude: Double,
        visitCount: Int,
        avgDurationMinutes: Int,
        score: Float,
        distanceMeters: Double,
        lastVisit: String?,
        isExplicitFavorite: Bool
    ) {
        self.poiId = poiId
        self.yelpId = yelpId
        self.placeId = placeId
        self.name = name
        self.category = category
        self.latitude = latitude
        self.longitude = longitude
        self.visitCount = visitCount
        self.avgDurationMinutes = avgDurationMinutes
        self.score = score
        self.distanceMeters = distanceMeters
        self.lastVisit = lastVisit
        self.isExplicitFavorite = isExplicitFavorite
    }

    enum CodingKeys: String, CodingKey {
        case poiId = "poi_id", yelpId = "yelp_id", placeId = "place_id"
        case name, category, latitude, longitude
        case visitCount = "visit_count", avgDurationMinutes = "avg_duration_minutes"
        case score, distanceMeters = "distance_meters", lastVisit = "last_visit"
        case isExplicitFavorite = "is_explicit_favorite"
    }
}

public struct MyList: Codable, Sendable {
    public let category: MyListCategory
    public let places: [MyListPlace]

    public init(category: MyListCategory, places: [MyListPlace]) {
        self.category = category
        self.places = places
    }
}

/// Pre-sorted locale rankings for downstream recommendation / aggregation algorithms.
public struct LocalePlaceRanking: Codable, Sendable {
    public let poiId: String?
    public let placeId: String
    public let name: String
    public let score: Float
    public let visitCount: Int
    public let categories: [MyListCategory]

    public init(
        poiId: String?,
        placeId: String,
        name: String,
        score: Float,
        visitCount: Int,
        categories: [MyListCategory]
    ) {
        self.poiId = poiId
        self.placeId = placeId
        self.name = name
        self.score = score
        self.visitCount = visitCount
        self.categories = categories
    }

    enum CodingKeys: String, CodingKey {
        case poiId = "poi_id", placeId = "place_id", name, score
        case visitCount = "visit_count", categories
    }
}

public struct MyListsMeta: Codable, Sendable {
    public let radiusMiles: Double
    public let center: Coordinate
    public let placeCount: Int
    public let localeRankings: [LocalePlaceRanking]

    public init(radiusMiles: Double, center: Coordinate, placeCount: Int, localeRankings: [LocalePlaceRanking]) {
        self.radiusMiles = radiusMiles
        self.center = center
        self.placeCount = placeCount
        self.localeRankings = localeRankings
    }

    enum CodingKeys: String, CodingKey {
        case radiusMiles = "radius_miles", center
        case placeCount = "place_count", localeRankings = "locale_rankings"
    }
}

public struct MyListsResponse: Codable, Sendable {
    public let lists: [MyList]
    public let meta: MyListsMeta

    public init(lists: [MyList], meta: MyListsMeta) {
        self.lists = lists
        self.meta = meta
    }
}

// MARK: - Engine

public enum MyListsEngine {
    /// Compile categorized, ranked lists from visit/favorite signals near `center`.
    public static func compile(
        signals: [MyListPlaceSignal],
        options: MyListsCompileOptions
    ) -> MyListsResponse {
        let iso = ISO8601DateFormatter()
        var scored: [(signal: MyListPlaceSignal, score: Float, distance: Double, categories: [MyListCategory])] = []

        for signal in signals {
            let distance = Geo.distanceMeters(
                from: options.center,
                to: Coordinate(latitude: signal.latitude, longitude: signal.longitude)
            )
            guard distance <= options.radiusMeters else { continue }

            let qualifies = signal.isExplicitFavorite || signal.visitCount >= options.minVisitCount
            guard qualifies else { continue }

            let score = rankScore(for: signal, referenceDate: options.referenceDate)
            let categories = categories(for: signal)
            guard !categories.isEmpty else { continue }

            scored.append((signal, score, distance, categories))
        }

        // Locale-wide async-sort input: highest visit-weighted scores first.
        let localeRankings = scored
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                if lhs.signal.visitCount != rhs.signal.visitCount { return lhs.signal.visitCount > rhs.signal.visitCount }
                return lhs.distance < rhs.distance
            }
            .map { entry in
                LocalePlaceRanking(
                    poiId: entry.signal.poiId,
                    placeId: entry.signal.placeId,
                    name: entry.signal.name,
                    score: entry.score,
                    visitCount: entry.signal.visitCount,
                    categories: entry.categories
                )
            }

        var lists: [MyList] = []
        for category in MyListCategory.displayOrder {
            let places = scored
                .filter { $0.categories.contains(category) }
                .sorted { lhs, rhs in
                    if lhs.score != rhs.score { return lhs.score > rhs.score }
                    if lhs.signal.visitCount != rhs.signal.visitCount { return lhs.signal.visitCount > rhs.signal.visitCount }
                    return lhs.distance < rhs.distance
                }
                .prefix(options.maxPlacesPerList)
                .map { entry -> MyListPlace in
                    MyListPlace(
                        poiId: entry.signal.poiId,
                        yelpId: entry.signal.yelpId,
                        placeId: entry.signal.placeId,
                        name: entry.signal.name,
                        category: entry.signal.category,
                        latitude: entry.signal.latitude,
                        longitude: entry.signal.longitude,
                        visitCount: entry.signal.visitCount,
                        avgDurationMinutes: entry.signal.avgDurationMinutes,
                        score: entry.score,
                        distanceMeters: entry.distance,
                        lastVisit: entry.signal.lastVisit.map { iso.string(from: $0) },
                        isExplicitFavorite: entry.signal.isExplicitFavorite
                    )
                }

            if !places.isEmpty {
                lists.append(MyList(category: category, places: Array(places)))
            }
        }

        let meta = MyListsMeta(
            radiusMiles: options.radiusMiles,
            center: options.center,
            placeCount: localeRankings.count,
            localeRankings: localeRankings
        )

        return MyListsResponse(lists: lists, meta: meta)
    }

    // MARK: - Scoring

    static func rankScore(for signal: MyListPlaceSignal, referenceDate: Date) -> Float {
        var score = Float(signal.visitCount) * 10

        // Repeat visits are the primary favorite signal.
        if signal.visitCount >= 3 { score += 15 }
        else if signal.visitCount >= 2 { score += 8 }

        score += Float(min(signal.avgDurationMinutes, 120)) / 12

        if let last = signal.lastVisit {
            let days = referenceDate.timeIntervalSince(last) / 86_400
            let recency = exp(-days / 45) // ~45-day half-life
            score += Float(recency) * 6
        }

        if signal.isExplicitFavorite {
            score += 12
            if let rating = signal.favoriteRating {
                score += Float(rating) * 2
            }
        }

        return score
    }

    // MARK: - Category assignment

    static func categories(for signal: MyListPlaceSignal) -> [MyListCategory] {
        var result: [MyListCategory] = []
        let hours = Set(signal.typicalHours)
        let cat = signal.category

        if signal.isExplicitFavorite {
            result.append(.favorites)
        }

        switch cat {
        case .cafe, .bakery:
            result.append(.coffee)
        default:
            break
        }

        if hoursOverlaps(hours, range: 5...10) && isFoodCategory(cat) {
            result.append(.breakfast)
        }
        if hoursOverlaps(hours, range: 11...14) && isFoodCategory(cat) {
            result.append(.lunch)
        }
        if hoursOverlaps(hours, range: 17...21) && isDinnerCategory(cat) {
            result.append(.dinner)
        }
        if hoursOverlaps(hours, range: 21...23) || hoursOverlaps(hours, range: 0...3) {
            if isNightCategory(cat) || isFoodCategory(cat) {
                result.append(.lateNight)
            }
        }

        switch cat {
        case .movie: result.append(.movies)
        case .beach: result.append(.beaches)
        case .park, .hiking: result.append(.parks)
        case .bar, .nightclub: result.append(.nightlife)
        case .shopping, .mall, .bookstore: result.append(.shopping)
        case .gym: result.append(.fitness)
        default: break
        }

        // Category-only fallback when we lack hour data but visits qualify.
        if result.isEmpty || (result.count == 1 && result[0] == .favorites) {
            switch cat {
            case .cafe, .bakery: result.append(.coffee)
            case .restaurant, .fastFood: result.append(.lunch)
            case .fineDining: result.append(.dinner)
            case .movie: result.append(.movies)
            case .beach: result.append(.beaches)
            case .park, .hiking: result.append(.parks)
            case .bar, .nightclub: result.append(.nightlife)
            case .shopping, .mall: result.append(.shopping)
            case .gym: result.append(.fitness)
            default: break
            }
        }

        return Array(Set(result))
    }

    private static func hoursOverlaps(_ hours: Set<Int>, range: ClosedRange<Int>) -> Bool {
        guard !hours.isEmpty else { return false }
        return hours.contains { range.contains($0) }
    }

    private static func isFoodCategory(_ cat: PlaceCategory) -> Bool {
        switch cat {
        case .restaurant, .cafe, .fastFood, .fineDining, .bakery: return true
        default: return false
        }
    }

    private static func isDinnerCategory(_ cat: PlaceCategory) -> Bool {
        switch cat {
        case .restaurant, .fineDining, .bar: return true
        default: return false
        }
    }

    private static func isNightCategory(_ cat: PlaceCategory) -> Bool {
        switch cat {
        case .bar, .nightclub: return true
        default: return false
        }
    }
}

// MARK: - Geo helpers

public enum Geo {
    /// Haversine distance in meters between two coordinates.
    public static func distanceMeters(from: Coordinate, to: Coordinate) -> Double {
        let earthRadius = 6_371_000.0
        let dLat = (to.latitude - from.latitude) * .pi / 180
        let dLon = (to.longitude - from.longitude) * .pi / 180
        let lat1 = from.latitude * .pi / 180
        let lat2 = to.latitude * .pi / 180

        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        let c = 2 * atan2(sqrt(a), sqrt(1 - a))
        return earthRadius * c
    }
}
