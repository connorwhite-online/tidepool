import Foundation

// MARK: - Auth

public struct AttestRequest: Codable, Sendable {
    public let attestationObject: String // base64
    public let keyID: String // base64
    public let appVersion: String

    public init(attestationObject: String, keyID: String, appVersion: String) {
        self.attestationObject = attestationObject
        self.keyID = keyID
        self.appVersion = appVersion
    }

    enum CodingKeys: String, CodingKey {
        case attestationObject = "attestation_object"
        case keyID = "key_id"
        case appVersion = "app_version"
    }
}

public struct AuthResponse: Codable, Sendable {
    public let token: String
    public let expiresIn: Int
    public let deviceID: String

    public init(token: String, expiresIn: Int, deviceID: String) {
        self.token = token
        self.expiresIn = expiresIn
        self.deviceID = deviceID
    }

    enum CodingKeys: String, CodingKey {
        case token
        case expiresIn = "expires_in"
        case deviceID = "device_id"
    }
}

// MARK: - Profile

public struct ProfileVectorRequest: Codable, Sendable {
    public let vector: [Float]
    public let quality: String
    public let activeSources: [String]

    public init(vector: [Float], quality: String, activeSources: [String]) {
        self.vector = vector
        self.quality = quality
        self.activeSources = activeSources
    }

    enum CodingKeys: String, CodingKey {
        case vector
        case quality
        case activeSources = "active_sources"
    }
}

public struct ProfileVectorResponse: Codable, Sendable {
    public let vector: [Float]
    public let vectorVersion: Int
    public let quality: String
    public let updatedAt: String

    public init(vector: [Float], vectorVersion: Int, quality: String, updatedAt: String) {
        self.vector = vector
        self.vectorVersion = vectorVersion
        self.quality = quality
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case vector
        case vectorVersion = "vector_version"
        case quality
        case updatedAt = "updated_at"
    }
}

// MARK: - Presence

public struct PresenceReport: Codable, Sendable {
    public let tileID: String
    public let epochMs: Int64
    public let clientJitterMs: Int

    public init(tileID: String, epochMs: Int64, clientJitterMs: Int) {
        self.tileID = tileID
        self.epochMs = epochMs
        self.clientJitterMs = clientJitterMs
    }

    enum CodingKeys: String, CodingKey {
        case tileID = "tile_id"
        case epochMs = "epoch_ms"
        case clientJitterMs = "client_jitter_ms"
    }
}

public struct PresenceResponse: Codable, Sendable {
    public let accepted: Bool

    public init(accepted: Bool) {
        self.accepted = accepted
    }
}

// MARK: - Heat Tiles

public struct HeatTileRequest: Codable, Sendable {
    public let viewport: Viewport
    public let viewerVector: [Float]?

    public init(viewport: Viewport, viewerVector: [Float]?) {
        self.viewport = viewport
        self.viewerVector = viewerVector
    }

    enum CodingKeys: String, CodingKey {
        case viewport
        case viewerVector = "viewer_vector"
    }
}

public struct Viewport: Codable, Sendable {
    public let ne: Coordinate
    public let sw: Coordinate

    public init(ne: Coordinate, sw: Coordinate) {
        self.ne = ne
        self.sw = sw
    }
}

public struct HeatTile: Codable, Sendable {
    public let tileID: String
    public let intensity: Float
    public let contributorCount: Int

    public init(tileID: String, intensity: Float, contributorCount: Int) {
        self.tileID = tileID
        self.intensity = intensity
        self.contributorCount = contributorCount
    }

    enum CodingKeys: String, CodingKey {
        case tileID = "tile_id"
        case intensity
        case contributorCount = "contributor_count"
    }
}

public struct HeatTileResponse: Codable, Sendable {
    public let tiles: [HeatTile]
    public let meta: HeatTileMeta

    public init(tiles: [HeatTile], meta: HeatTileMeta) {
        self.tiles = tiles
        self.meta = meta
    }
}

public struct HeatTileMeta: Codable, Sendable {
    public let kMin: Int
    public let epsilon: Float
    public let ttlSeconds: Int

    public init(kMin: Int, epsilon: Float, ttlSeconds: Int) {
        self.kMin = kMin
        self.epsilon = epsilon
        self.ttlSeconds = ttlSeconds
    }

    enum CodingKeys: String, CodingKey {
        case kMin = "k_min"
        case epsilon
        case ttlSeconds = "ttl_s"
    }
}

// MARK: - Places (Yelp Proxy)

public struct PlaceDetail: Codable, Sendable {
    public let yelpID: String
    public let name: String
    public let categories: [String]
    public let rating: Float?
    public let reviewCount: Int?
    public let price: String?
    public let phone: String?
    public let address: PlaceAddress?
    public let coordinates: Coordinate?
    public let hours: [DayHours]?
    public let photos: [String]?
    public let isOpenNow: Bool?

    public init(yelpID: String, name: String, categories: [String], rating: Float?,
                reviewCount: Int?, price: String?, phone: String?, address: PlaceAddress?,
                coordinates: Coordinate?, hours: [DayHours]?, photos: [String]?, isOpenNow: Bool?) {
        self.yelpID = yelpID
        self.name = name
        self.categories = categories
        self.rating = rating
        self.reviewCount = reviewCount
        self.price = price
        self.phone = phone
        self.address = address
        self.coordinates = coordinates
        self.hours = hours
        self.photos = photos
        self.isOpenNow = isOpenNow
    }

    enum CodingKeys: String, CodingKey {
        case yelpID = "yelp_id"
        case name, categories, rating, price, phone, address, coordinates, hours, photos
        case reviewCount = "review_count"
        case isOpenNow = "is_open_now"
    }
}

public struct PlaceAddress: Codable, Sendable {
    public let address1: String?
    public let city: String?
    public let state: String?
    public let zipCode: String?

    public init(address1: String?, city: String?, state: String?, zipCode: String?) {
        self.address1 = address1
        self.city = city
        self.state = state
        self.zipCode = zipCode
    }

    enum CodingKeys: String, CodingKey {
        case address1
        case city
        case state
        case zipCode = "zip_code"
    }
}

public struct DayHours: Codable, Sendable {
    public let day: Int // 0 = Monday, 6 = Sunday
    public let start: String // "0800"
    public let end: String // "2200"

    public init(day: Int, start: String, end: String) {
        self.day = day
        self.start = start
        self.end = end
    }
}

// MARK: - Search

public struct PlaceSearchRequest: Codable, Sendable {
    public let query: String
    public let location: Coordinate
    public let radiusKm: Float?
    public let interestVector: [Float]?
    public let limit: Int?

    public init(query: String, location: Coordinate, radiusKm: Float? = nil,
                interestVector: [Float]? = nil, limit: Int? = nil) {
        self.query = query
        self.location = location
        self.radiusKm = radiusKm
        self.interestVector = interestVector
        self.limit = limit
    }

    enum CodingKeys: String, CodingKey {
        case query, location, limit
        case radiusKm = "radius_km"
        case interestVector = "interest_vector"
    }
}

public struct PlaceSearchResult: Codable, Sendable {
    public let yelpID: String
    public let name: String
    public let category: String
    public let location: Coordinate
    public let rating: Float?
    public let price: String?
    public let photos: [String]?
    public let hours: [DayHours]?
    public let isOpenNow: Bool?
    public let relevanceScore: Float
    public let interestAlignment: Float

    public init(yelpID: String, name: String, category: String, location: Coordinate,
                rating: Float?, price: String?, photos: [String]?, hours: [DayHours]?,
                isOpenNow: Bool?, relevanceScore: Float, interestAlignment: Float) {
        self.yelpID = yelpID
        self.name = name
        self.category = category
        self.location = location
        self.rating = rating
        self.price = price
        self.photos = photos
        self.hours = hours
        self.isOpenNow = isOpenNow
        self.relevanceScore = relevanceScore
        self.interestAlignment = interestAlignment
    }

    enum CodingKeys: String, CodingKey {
        case yelpID = "yelp_id"
        case name, category, location, rating, price, photos, hours
        case isOpenNow = "is_open_now"
        case relevanceScore = "relevance_score"
        case interestAlignment = "interest_alignment"
    }
}

public struct PlaceSearchResponse: Codable, Sendable {
    public let results: [PlaceSearchResult]
    public let total: Int

    public init(results: [PlaceSearchResult], total: Int) {
        self.results = results
        self.total = total
    }
}

// MARK: - Favorites

public struct FavoriteRequest: Codable, Sendable {
    public let placeID: String
    public let yelpID: String?
    public let name: String
    public let category: PlaceCategory
    public let latitude: Double
    public let longitude: Double
    public let rating: Int?

    public init(placeID: String, yelpID: String?, name: String, category: PlaceCategory,
                latitude: Double, longitude: Double, rating: Int?) {
        self.placeID = placeID
        self.yelpID = yelpID
        self.name = name
        self.category = category
        self.latitude = latitude
        self.longitude = longitude
        self.rating = rating
    }

    enum CodingKeys: String, CodingKey {
        case placeID = "place_id"
        case yelpID = "yelp_id"
        case name, category, latitude, longitude, rating
    }
}

public struct FavoriteResponse: Codable, Sendable {
    public let id: String
    public let placeID: String
    public let yelpID: String?
    public let name: String
    public let category: PlaceCategory
    public let rating: Int?
    public let createdAt: String

    public init(id: String, placeID: String, yelpID: String?, name: String,
                category: PlaceCategory, rating: Int?, createdAt: String) {
        self.id = id
        self.placeID = placeID
        self.yelpID = yelpID
        self.name = name
        self.category = category
        self.rating = rating
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case placeID = "place_id"
        case yelpID = "yelp_id"
        case name, category, rating
        case createdAt = "created_at"
    }
}

// MARK: - Taste Summary

public struct TasteSummaryResponse: Codable, Sendable {
    public let summary: String
    public let topInterests: [String]
    public let generatedAt: String

    public init(summary: String, topInterests: [String], generatedAt: String) {
        self.summary = summary
        self.topInterests = topInterests
        self.generatedAt = generatedAt
    }

    enum CodingKeys: String, CodingKey {
        case summary
        case topInterests = "top_interests"
        case generatedAt = "generated_at"
    }
}

// MARK: - Visits

public struct VisitReport: Codable, Sendable {
    public let poiId: String?
    public let yelpId: String?
    public let name: String
    public let category: PlaceCategory
    public let latitude: Double
    public let longitude: Double
    public let arrivedAt: String
    public let departedAt: String
    public let dayOfWeek: Int
    public let hourOfDay: Int
    public let durationMinutes: Int
    public let confidence: Float
    public let source: String

    public init(poiId: String?, yelpId: String?, name: String, category: PlaceCategory,
                latitude: Double, longitude: Double, arrivedAt: String, departedAt: String,
                dayOfWeek: Int, hourOfDay: Int, durationMinutes: Int,
                confidence: Float = 1.0, source: String = "visit") {
        self.poiId = poiId; self.yelpId = yelpId; self.name = name; self.category = category
        self.latitude = latitude; self.longitude = longitude
        self.arrivedAt = arrivedAt; self.departedAt = departedAt
        self.dayOfWeek = dayOfWeek; self.hourOfDay = hourOfDay
        self.durationMinutes = durationMinutes; self.confidence = confidence; self.source = source
    }

    enum CodingKeys: String, CodingKey {
        case poiId = "poi_id", yelpId = "yelp_id", name, category, latitude, longitude
        case arrivedAt = "arrived_at", departedAt = "departed_at"
        case dayOfWeek = "day_of_week", hourOfDay = "hour_of_day"
        case durationMinutes = "duration_minutes", confidence, source
    }
}

public struct VisitBatchRequest: Codable, Sendable {
    public let visits: [VisitReport]
    public init(visits: [VisitReport]) { self.visits = visits }
}

public struct VisitBatchResponse: Codable, Sendable {
    public let accepted: Int
    public let duplicates: Int
    public init(accepted: Int, duplicates: Int) { self.accepted = accepted; self.duplicates = duplicates }
}

public struct VisitPattern: Codable, Sendable {
    public let poiId: String?
    public let name: String
    public let category: PlaceCategory
    public let latitude: Double
    public let longitude: Double
    public let visitCount: Int
    public let avgDurationMinutes: Int
    public let typicalDays: [Int]
    public let typicalHours: [Int]
    public let lastVisit: String

    public init(poiId: String?, name: String, category: PlaceCategory,
                latitude: Double, longitude: Double, visitCount: Int,
                avgDurationMinutes: Int, typicalDays: [Int], typicalHours: [Int], lastVisit: String) {
        self.poiId = poiId; self.name = name; self.category = category
        self.latitude = latitude; self.longitude = longitude; self.visitCount = visitCount
        self.avgDurationMinutes = avgDurationMinutes; self.typicalDays = typicalDays
        self.typicalHours = typicalHours; self.lastVisit = lastVisit
    }

    enum CodingKeys: String, CodingKey {
        case poiId = "poi_id", name, category, latitude, longitude
        case visitCount = "visit_count", avgDurationMinutes = "avg_duration_minutes"
        case typicalDays = "typical_days", typicalHours = "typical_hours"
        case lastVisit = "last_visit"
    }
}

public struct VisitPatternResponse: Codable, Sendable {
    public let patterns: [VisitPattern]
    public init(patterns: [VisitPattern]) { self.patterns = patterns }
}

// MARK: - Multi-Vector Profile

public struct MultiVectorRequest: Codable, Sendable {
    public let musicGenres: [String: Float]
    public let placePois: [String: Float]
    public let vibeVector: [Float]
    public let quality: String
    public let activeSources: [String]

    public init(musicGenres: [String: Float], placePois: [String: Float], vibeVector: [Float],
                quality: String, activeSources: [String]) {
        self.musicGenres = musicGenres; self.placePois = placePois; self.vibeVector = vibeVector
        self.quality = quality; self.activeSources = activeSources
    }

    enum CodingKeys: String, CodingKey {
        case musicGenres = "music_genres", placePois = "place_pois"
        case vibeVector = "vibe_vector", quality, activeSources = "active_sources"
    }
}

// MARK: - Aligned Heat

public struct AlignedHeatRequest: Codable, Sendable {
    public let viewport: Viewport
    public let currentHour: Int
    public let currentDayOfWeek: Int

    public init(viewport: Viewport, currentHour: Int, currentDayOfWeek: Int) {
        self.viewport = viewport; self.currentHour = currentHour; self.currentDayOfWeek = currentDayOfWeek
    }

    enum CodingKeys: String, CodingKey {
        case viewport, currentHour = "current_hour", currentDayOfWeek = "current_day_of_week"
    }
}

// MARK: - Recommendations

public struct RecommendationRequest: Codable, Sendable {
    public let location: Coordinate
    public let currentHour: Int
    public let currentDayOfWeek: Int
    public let limit: Int?

    public init(location: Coordinate, currentHour: Int, currentDayOfWeek: Int, limit: Int? = nil) {
        self.location = location; self.currentHour = currentHour
        self.currentDayOfWeek = currentDayOfWeek; self.limit = limit
    }

    enum CodingKeys: String, CodingKey {
        case location, currentHour = "current_hour", currentDayOfWeek = "current_day_of_week", limit
    }
}

public struct RecommendedPlace: Codable, Sendable {
    public let poiId: String?
    public let yelpId: String?
    public let name: String
    public let category: PlaceCategory
    public let latitude: Double
    public let longitude: Double
    public let score: Float
    public let alignedVisitors: Int
    public let typicalHours: [Int]

    public init(poiId: String?, yelpId: String?, name: String, category: PlaceCategory,
                latitude: Double, longitude: Double, score: Float,
                alignedVisitors: Int, typicalHours: [Int]) {
        self.poiId = poiId; self.yelpId = yelpId; self.name = name; self.category = category
        self.latitude = latitude; self.longitude = longitude; self.score = score
        self.alignedVisitors = alignedVisitors; self.typicalHours = typicalHours
    }

    enum CodingKeys: String, CodingKey {
        case poiId = "poi_id", yelpId = "yelp_id", name, category, latitude, longitude, score
        case alignedVisitors = "aligned_visitors", typicalHours = "typical_hours"
    }
}

public struct RecommendationResponse: Codable, Sendable {
    public let recommendations: [RecommendedPlace]
    public init(recommendations: [RecommendedPlace]) { self.recommendations = recommendations }
}
