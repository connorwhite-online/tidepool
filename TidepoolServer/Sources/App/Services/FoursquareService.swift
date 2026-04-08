import Vapor
import Redis
import TidepoolShared

/// Server-side Foursquare Places API v2 client with Redis caching.
/// Uses Client ID + Secret auth (v2) since v3 Service API keys have provisioning issues.
struct FoursquareService {
    private let clientID: String
    private let clientSecret: String
    private let baseURL = "https://api.foursquare.com/v2"
    private let apiVersion = "20240101"

    init(clientID: String, clientSecret: String) {
        self.clientID = clientID
        self.clientSecret = clientSecret
    }

    private func authParams() -> [URLQueryItem] {
        [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "client_secret", value: clientSecret),
            URLQueryItem(name: "v", value: apiVersion),
        ]
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
            return cached
        }

        var urlComponents = URLComponents(string: baseURL + "/venues/search")!
        urlComponents.queryItems = authParams() + [
            URLQueryItem(name: "query", value: params.query),
            URLQueryItem(name: "ll", value: "\(params.latitude),\(params.longitude)"),
            URLQueryItem(name: "limit", value: String(params.limit)),
        ]
        if let radius = params.radiusMeters {
            urlComponents.queryItems?.append(URLQueryItem(name: "radius", value: String(min(radius, 100000))))
        }

        let data = try await makeRequest(url: urlComponents.url!, on: req)
        let wrapper = try JSONDecoder().decode(FSQv2Response<FSQv2VenueList>.self, from: data)
        let results = wrapper.response.venues.map { $0.toFSQPlace() }
        let decoded = FSQSearchResponse(results: results)

        try? await req.redis.set(RedisKey(cacheKey), toJSON: decoded)
        _ = try? await req.redis.expire(RedisKey(cacheKey), after: .seconds(3600))

        return decoded
    }

    // MARK: - Place Details

    func getPlaceDetails(fsqID: String, on req: Request) async throws -> FSQPlace {
        let cacheKey = "fsq:place:\(fsqID)"
        if let cached = try? await req.redis.get(RedisKey(cacheKey), asJSON: FSQPlace.self) {
            return cached
        }

        var urlComponents = URLComponents(string: baseURL + "/venues/\(fsqID)")!
        urlComponents.queryItems = authParams()

        let data = try await makeRequest(url: urlComponents.url!, on: req)
        let wrapper = try JSONDecoder().decode(FSQv2Response<FSQv2VenueWrapper>.self, from: data)
        let decoded = wrapper.response.venue.toFSQPlace()

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

        // Search with intent=match for best name match
        let searchResult = try await searchPlaces(
            SearchParams(query: name, latitude: latitude, longitude: longitude, radiusMeters: 1000, limit: 5),
            on: req
        )

        let match = searchResult.results.first { place in
            place.name.lowercased().contains(name.lowercased()) ||
            name.lowercased().contains(place.name.lowercased())
        } ?? searchResult.results.first

        // Fetch full details for the matched venue (includes rating, photos, hours)
        guard let match, let fsqId = match.fsqId else { return match }
        let detailed = try await getPlaceDetails(fsqID: fsqId, on: req)

        try? await req.redis.set(RedisKey(cacheKey), toJSON: detailed)
        _ = try? await req.redis.expire(RedisKey(cacheKey), after: .seconds(86400))

        return detailed
    }

    // MARK: - HTTP

    private func makeRequest(url: URL, on req: Request) async throws -> Data {
        var urlRequest = URLRequest(url: url)
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

// MARK: - v2 Response Wrappers

struct FSQv2Response<T: Codable>: Codable {
    let response: T
}

struct FSQv2VenueList: Codable {
    let venues: [FSQv2Venue]
}

struct FSQv2VenueWrapper: Codable {
    let venue: FSQv2Venue
}

struct FSQv2Venue: Codable {
    let id: String
    let name: String
    let categories: [FSQv2Category]?
    let location: FSQv2Location?
    let rating: Float?
    let price: FSQv2Price?
    let hours: FSQv2Hours?
    let contact: FSQv2Contact?
    let url: String?
    let bestPhoto: FSQv2Photo?

    func toFSQPlace() -> FSQPlace {
        let coords = location.map { FSQGeocodes(main: FSQLatLng(latitude: $0.lat, longitude: $0.lng)) }
        let fsqLocation = location.map { loc in
            FSQLocation(address: loc.address, locality: loc.city, region: loc.state, postcode: loc.postalCode, country: loc.country, formattedAddress: loc.formattedAddress?.joined(separator: ", "))
        }
        let fsqHours = hours.map { h in
            FSQHours(regular: h.timeframes?.flatMap { tf in
                tf.open?.map { slot in
                    FSQHourPeriod(day: tf.days.hashValue, open: slot.start ?? "0000", close: slot.end ?? "2359")
                } ?? []
            }, openNow: hours?.isOpen)
        }
        let photos: [FSQPhoto]? = bestPhoto.map { [FSQPhoto(id: nil, prefix: $0.prefix, suffix: $0.suffix, width: $0.width, height: $0.height)] }

        return FSQPlace(
            fsqId: id, name: name,
            categories: categories?.map { FSQCategory(id: String($0.id), name: $0.name, shortName: $0.shortName, icon: nil) },
            geocodes: coords, location: fsqLocation,
            rating: rating, price: price?.tier,
            hours: fsqHours, photos: photos,
            tel: contact?.phone, website: url
        )
    }
}

struct FSQv2Category: Codable {
    let id: String
    let name: String
    let shortName: String?
}

struct FSQv2Location: Codable {
    let address: String?
    let lat: Double
    let lng: Double
    let city: String?
    let state: String?
    let postalCode: String?
    let country: String?
    let formattedAddress: [String]?
}

struct FSQv2Price: Codable {
    let tier: Int?
    let message: String?
}

struct FSQv2Hours: Codable {
    let isOpen: Bool?
    let timeframes: [FSQv2Timeframe]?
}

struct FSQv2Timeframe: Codable {
    let days: String?
    let open: [FSQv2TimeSlot]?
}

struct FSQv2TimeSlot: Codable {
    let start: String?
    let end: String?
    let renderedTime: String?
}

struct FSQv2Contact: Codable {
    let phone: String?
    let formattedPhone: String?
}

struct FSQv2Photo: Codable {
    let prefix: String?
    let suffix: String?
    let width: Int?
    let height: Int?
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
    let id: String
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
