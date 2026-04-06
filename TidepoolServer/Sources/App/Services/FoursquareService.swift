import Vapor
import Redis
import TidepoolShared

/// Server-side Foursquare Places API v3 client with Redis caching.
/// Replaces YelpService — same interface, different backend.
struct FoursquareService {
    private let apiKey: String
    private let baseURL = "https://api.foursquare.com/v3"

    init(apiKey: String) {
        self.apiKey = apiKey
    }

    // MARK: - Place Search

    struct SearchParams {
        let query: String
        let latitude: Double
        let longitude: Double
        let radiusMeters: Int?
        let limit: Int
    }

    func searchPlaces(_ params: SearchParams, on req: Request) async throws -> FSQSearchResponse {
        let cacheKey = "fsq:search:\(params.query.lowercased()):\(String(format: "%.3f", params.latitude)):\(String(format: "%.3f", params.longitude)):\(params.radiusMeters ?? 0)"
        if let cached = try? await req.redis.get(RedisKey(cacheKey), asJSON: FSQSearchResponse.self) {
            req.logger.info("[Foursquare] Cache hit for search: \(params.query)")
            return cached
        }

        var urlComponents = URLComponents(string: baseURL + "/places/search")!
        urlComponents.queryItems = [
            URLQueryItem(name: "query", value: params.query),
            URLQueryItem(name: "ll", value: "\(params.latitude),\(params.longitude)"),
            URLQueryItem(name: "limit", value: String(params.limit)),
            URLQueryItem(name: "fields", value: "fsq_id,name,categories,geocodes,location,rating,price,hours,photos,tel,website"),
        ]
        if let radius = params.radiusMeters {
            urlComponents.queryItems?.append(URLQueryItem(name: "radius", value: String(min(radius, 100000))))
        }

        let data = try await makeRequest(url: urlComponents.url!, on: req)
        let decoded = try JSONDecoder().decode(FSQSearchResponse.self, from: data)

        try? await req.redis.set(RedisKey(cacheKey), toJSON: decoded)
        _ = try? await req.redis.expire(RedisKey(cacheKey), after: .seconds(3600))

        return decoded
    }

    // MARK: - Place Details

    func getPlaceDetails(fsqID: String, on req: Request) async throws -> FSQPlace {
        let cacheKey = "fsq:place:\(fsqID)"
        if let cached = try? await req.redis.get(RedisKey(cacheKey), asJSON: FSQPlace.self) {
            req.logger.info("[Foursquare] Cache hit for place: \(fsqID)")
            return cached
        }

        let url = URL(string: "\(baseURL)/places/\(fsqID)?fields=fsq_id,name,categories,geocodes,location,rating,price,hours,photos,tel,website")!
        let data = try await makeRequest(url: url, on: req)
        let decoded = try JSONDecoder().decode(FSQPlace.self, from: data)

        try? await req.redis.set(RedisKey(cacheKey), toJSON: decoded)
        _ = try? await req.redis.expire(RedisKey(cacheKey), after: .seconds(86400))

        return decoded
    }

    // MARK: - Place Match

    func matchPlace(name: String, latitude: Double, longitude: Double, on req: Request) async throws -> FSQPlace? {
        let cacheKey = "fsq:match:\(name.lowercased()):\(String(format: "%.4f", latitude)):\(String(format: "%.4f", longitude))"
        if let cached = try? await req.redis.get(RedisKey(cacheKey), asJSON: FSQPlace.self) {
            return cached
        }

        // Try the match endpoint first
        var matchComponents = URLComponents(string: baseURL + "/places/match")!
        matchComponents.queryItems = [
            URLQueryItem(name: "name", value: name),
            URLQueryItem(name: "ll", value: "\(latitude),\(longitude)"),
            URLQueryItem(name: "fields", value: "fsq_id,name,categories,geocodes,location,rating,price,hours,photos,tel,website"),
        ]

        if let data = try? await makeRequest(url: matchComponents.url!, on: req) {
            if let place = try? JSONDecoder().decode(FSQPlace.self, from: data), place.fsqId != nil {
                try? await req.redis.set(RedisKey(cacheKey), toJSON: place)
                _ = try? await req.redis.expire(RedisKey(cacheKey), after: .seconds(86400))
                return place
            }
        }

        // Fallback: search with name + tight radius
        let searchResult = try await searchPlaces(
            SearchParams(query: name, latitude: latitude, longitude: longitude, radiusMeters: 200, limit: 3),
            on: req
        )

        let match = searchResult.results.first { place in
            place.name.lowercased().contains(name.lowercased()) ||
            name.lowercased().contains(place.name.lowercased())
        } ?? searchResult.results.first

        if let match {
            try? await req.redis.set(RedisKey(cacheKey), toJSON: match)
            _ = try? await req.redis.expire(RedisKey(cacheKey), after: .seconds(86400))
        }

        return match
    }

    // MARK: - HTTP

    private func makeRequest(url: URL, on req: Request) async throws -> Data {
        var urlRequest = URLRequest(url: url)
        urlRequest.setValue(apiKey, forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw Abort(.badGateway, reason: "Invalid response from Foursquare API")
        }

        guard httpResponse.statusCode == 200 else {
            req.logger.error("[Foursquare] API error \(httpResponse.statusCode): \(String(data: data, encoding: .utf8) ?? "unknown")")
            if httpResponse.statusCode == 429 {
                throw Abort(.tooManyRequests, reason: "Foursquare API rate limit exceeded")
            }
            throw Abort(.badGateway, reason: "Foursquare API returned \(httpResponse.statusCode)")
        }

        return data
    }
}

// MARK: - Foursquare Response Types

struct FSQSearchResponse: Codable {
    let results: [FSQPlace]
}

struct FSQPlace: Codable {
    let fsqId: String?
    let name: String
    let categories: [FSQCategory]?
    let geocodes: FSQGeocodes?
    let location: FSQLocation?
    let rating: Float?
    let price: Int?           // 1-4
    let hours: FSQHours?
    let photos: [FSQPhoto]?
    let tel: String?
    let website: String?

    enum CodingKeys: String, CodingKey {
        case fsqId = "fsq_id"
        case name, categories, geocodes, location, rating, price, hours, photos, tel, website
    }
}

struct FSQCategory: Codable {
    let id: Int
    let name: String
    let shortName: String?
    let icon: FSQIcon?

    enum CodingKeys: String, CodingKey {
        case id, name, icon
        case shortName = "short_name"
    }
}

struct FSQIcon: Codable {
    let prefix: String?
    let suffix: String?
}

struct FSQGeocodes: Codable {
    let main: FSQLatLng?
}

struct FSQLatLng: Codable {
    let latitude: Double
    let longitude: Double
}

struct FSQLocation: Codable {
    let address: String?
    let locality: String?
    let region: String?
    let postcode: String?
    let country: String?
    let formattedAddress: String?

    enum CodingKeys: String, CodingKey {
        case address, locality, region, postcode, country
        case formattedAddress = "formatted_address"
    }
}

struct FSQHours: Codable {
    let regular: [FSQHourPeriod]?
    let openNow: Bool?

    enum CodingKeys: String, CodingKey {
        case regular
        case openNow = "open_now"
    }
}

struct FSQHourPeriod: Codable {
    let day: Int       // 1=Monday, 7=Sunday
    let open: String   // "0800"
    let close: String  // "2200"
}

struct FSQPhoto: Codable {
    let id: String?
    let prefix: String?
    let suffix: String?
    let width: Int?
    let height: Int?

    /// Construct full photo URL
    var url: String? {
        guard let prefix, let suffix else { return nil }
        return "\(prefix)original\(suffix)"
    }
}
