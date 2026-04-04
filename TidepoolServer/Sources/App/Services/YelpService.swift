import Vapor
import Redis
import TidepoolShared

/// Server-side Yelp Fusion API client with 2-layer caching (Redis + Postgres).
/// The Yelp API key stays server-side — clients never see it.
struct YelpService {
    private let apiKey: String
    private let baseURL = "https://api.yelp.com/v3"

    init(apiKey: String) {
        self.apiKey = apiKey
    }

    // MARK: - Business Search

    struct YelpSearchParams {
        let term: String
        let latitude: Double
        let longitude: Double
        let radiusMeters: Int?
        let limit: Int
    }

    func searchBusinesses(_ params: YelpSearchParams, on req: Request) async throws -> YelpSearchResponse {
        // Check Redis cache first
        let cacheKey = "yelp:search:\(params.term.lowercased()):\(String(format: "%.3f", params.latitude)):\(String(format: "%.3f", params.longitude)):\(params.radiusMeters ?? 0)"
        if let cached = try? await req.redis.get(RedisKey(cacheKey), asJSON: YelpSearchResponse.self) {
            req.logger.info("[Yelp] Cache hit for search: \(params.term)")
            return cached
        }

        // Build Yelp API request
        var urlComponents = URLComponents(string: baseURL + "/businesses/search")!
        urlComponents.queryItems = [
            URLQueryItem(name: "term", value: params.term),
            URLQueryItem(name: "latitude", value: String(params.latitude)),
            URLQueryItem(name: "longitude", value: String(params.longitude)),
            URLQueryItem(name: "limit", value: String(params.limit)),
            URLQueryItem(name: "sort_by", value: "best_match"),
        ]
        if let radius = params.radiusMeters {
            urlComponents.queryItems?.append(URLQueryItem(name: "radius", value: String(min(radius, 40000))))
        }

        let response = try await makeRequest(url: urlComponents.url!, on: req)
        let decoded = try JSONDecoder().decode(YelpSearchResponse.self, from: response)

        // Cache for 1 hour
        try? await req.redis.set(RedisKey(cacheKey), toJSON: decoded)
        _ = try? await req.redis.expire(RedisKey(cacheKey), after: .seconds(3600))

        return decoded
    }

    // MARK: - Business Details

    func getBusinessDetails(yelpID: String, on req: Request) async throws -> YelpBusiness {
        // Check Redis cache first (24h for details)
        let cacheKey = "yelp:business:\(yelpID)"
        if let cached = try? await req.redis.get(RedisKey(cacheKey), asJSON: YelpBusiness.self) {
            req.logger.info("[Yelp] Cache hit for business: \(yelpID)")
            return cached
        }

        let url = URL(string: "\(baseURL)/businesses/\(yelpID)")!
        let response = try await makeRequest(url: url, on: req)
        let decoded = try JSONDecoder().decode(YelpBusiness.self, from: response)

        // Cache for 24 hours
        try? await req.redis.set(RedisKey(cacheKey), toJSON: decoded)
        _ = try? await req.redis.expire(RedisKey(cacheKey), after: .seconds(86400))

        return decoded
    }

    // MARK: - Business Match (name + coordinates → Yelp ID)

    func matchBusiness(name: String, latitude: Double, longitude: Double, on req: Request) async throws -> YelpBusiness? {
        let cacheKey = "yelp:match:\(name.lowercased()):\(String(format: "%.4f", latitude)):\(String(format: "%.4f", longitude))"
        if let cached = try? await req.redis.get(RedisKey(cacheKey), asJSON: YelpBusiness.self) {
            return cached
        }

        // Use search with the exact name + tight radius
        var urlComponents = URLComponents(string: baseURL + "/businesses/search")!
        urlComponents.queryItems = [
            URLQueryItem(name: "term", value: name),
            URLQueryItem(name: "latitude", value: String(latitude)),
            URLQueryItem(name: "longitude", value: String(longitude)),
            URLQueryItem(name: "radius", value: "200"), // tight 200m radius
            URLQueryItem(name: "limit", value: "3"),
        ]

        let response = try await makeRequest(url: urlComponents.url!, on: req)
        let decoded = try JSONDecoder().decode(YelpSearchResponse.self, from: response)

        // Find best name match
        let match = decoded.businesses.first { business in
            business.name.lowercased().contains(name.lowercased()) ||
            name.lowercased().contains(business.name.lowercased())
        } ?? decoded.businesses.first

        if let match {
            try? await req.redis.set(RedisKey(cacheKey), toJSON: match)
            _ = try? await req.redis.expire(RedisKey(cacheKey), after: .seconds(86400))
        }

        return match
    }

    // MARK: - HTTP

    private func makeRequest(url: URL, on req: Request) async throws -> Data {
        var urlRequest = URLRequest(url: url)
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw Abort(.badGateway, reason: "Invalid response from Yelp API")
        }

        guard httpResponse.statusCode == 200 else {
            req.logger.error("[Yelp] API error \(httpResponse.statusCode): \(String(data: data, encoding: .utf8) ?? "unknown")")
            if httpResponse.statusCode == 429 {
                throw Abort(.tooManyRequests, reason: "Yelp API rate limit exceeded")
            }
            throw Abort(.badGateway, reason: "Yelp API returned \(httpResponse.statusCode)")
        }

        return data
    }
}

// MARK: - Yelp API Response Types

struct YelpSearchResponse: Codable {
    let businesses: [YelpBusiness]
    let total: Int
}

struct YelpBusiness: Codable {
    let id: String
    let name: String
    let rating: Float?
    let reviewCount: Int?
    let price: String?
    let phone: String?
    let categories: [YelpCategory]
    let coordinates: YelpCoordinates?
    let location: YelpLocation?
    let hours: [YelpHours]?
    let photos: [String]?
    let isClosed: Bool?
    let url: String?
    let imageUrl: String?

    enum CodingKeys: String, CodingKey {
        case id, name, rating, price, phone, categories, coordinates, location, hours, photos, url
        case reviewCount = "review_count"
        case isClosed = "is_closed"
        case imageUrl = "image_url"
    }
}

struct YelpCategory: Codable {
    let alias: String
    let title: String
}

struct YelpCoordinates: Codable {
    let latitude: Double
    let longitude: Double
}

struct YelpLocation: Codable {
    let address1: String?
    let city: String?
    let state: String?
    let zipCode: String?
    let country: String?

    enum CodingKeys: String, CodingKey {
        case address1, city, state, country
        case zipCode = "zip_code"
    }
}

struct YelpHours: Codable {
    let open: [YelpHourOpen]
    let isOpenNow: Bool?

    enum CodingKeys: String, CodingKey {
        case open
        case isOpenNow = "is_open_now"
    }
}

struct YelpHourOpen: Codable {
    let day: Int       // 0=Monday, 6=Sunday
    let start: String  // "0800"
    let end: String    // "2200"
    let isOvernight: Bool?

    enum CodingKeys: String, CodingKey {
        case day, start, end
        case isOvernight = "is_overnight"
    }
}

// MARK: - Redis JSON Helpers

extension RedisClient {
    func get<T: Decodable>(_ key: RedisKey, asJSON type: T.Type) async throws -> T? {
        let result = try await get(key, as: String.self).get()
        guard let jsonString = result else { return nil }
        return try JSONDecoder().decode(type, from: Data(jsonString.utf8))
    }

    func set<T: Encodable>(_ key: RedisKey, toJSON value: T) async throws {
        let data = try JSONEncoder().encode(value)
        let jsonString = String(data: data, encoding: .utf8) ?? ""
        _ = try await set(key, to: jsonString).get()
    }
}
