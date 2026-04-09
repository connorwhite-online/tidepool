import Vapor
import Redis
import TidepoolShared

/// Server-side Google Places API client with Redis caching.
struct GooglePlacesService {
    private let apiKey: String
    private let baseURL = "https://maps.googleapis.com/maps/api/place"

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

    func searchPlaces(_ params: SearchParams, on req: Request) async throws -> [GooglePlace] {
        let cacheKey = "gp:search:\(params.query.lowercased()):\(String(format: "%.3f", params.latitude)):\(String(format: "%.3f", params.longitude))"
        if let cached = try? await req.redis.get(RedisKey(cacheKey), asJSON: [GooglePlace].self) {
            return cached
        }

        let radius = params.radiusMeters ?? 1000
        let encoded = params.query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? params.query
        let url = URL(string: "\(baseURL)/nearbysearch/json?location=\(params.latitude),\(params.longitude)&radius=\(radius)&keyword=\(encoded)&key=\(apiKey)")!

        let data = try await makeRequest(url: url, on: req)
        let response = try JSONDecoder().decode(GoogleNearbyResponse.self, from: data)
        let places = Array(response.results.prefix(params.limit))

        try? await req.redis.set(RedisKey(cacheKey), toJSON: places)
        _ = try? await req.redis.expire(RedisKey(cacheKey), after: .seconds(3600))

        return places
    }

    // MARK: - Place Details

    func getPlaceDetails(placeID: String, on req: Request) async throws -> GooglePlaceDetail {
        let cacheKey = "gp:detail:\(placeID)"
        if let cached = try? await req.redis.get(RedisKey(cacheKey), asJSON: GooglePlaceDetail.self) {
            return cached
        }

        let url = URL(string: "\(baseURL)/details/json?place_id=\(placeID)&fields=name,rating,price_level,formatted_phone_number,website,opening_hours,photos,formatted_address,geometry,types&key=\(apiKey)")!

        let data = try await makeRequest(url: url, on: req)
        let response = try JSONDecoder().decode(GoogleDetailResponse.self, from: data)
        let detail = response.result

        try? await req.redis.set(RedisKey(cacheKey), toJSON: detail)
        _ = try? await req.redis.expire(RedisKey(cacheKey), after: .seconds(86400))

        return detail
    }

    // MARK: - Place Match (find by name + location)

    func matchPlace(name: String, latitude: Double, longitude: Double, on req: Request) async throws -> GooglePlaceDetail? {
        let cacheKey = "gp:match:\(name.lowercased()):\(String(format: "%.4f", latitude)):\(String(format: "%.4f", longitude))"
        if let cached = try? await req.redis.get(RedisKey(cacheKey), asJSON: GooglePlaceDetail.self) {
            return cached
        }

        // Find Place from Text with location bias
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name
        let url = URL(string: "\(baseURL)/findplacefromtext/json?input=\(encoded)&inputtype=textquery&locationbias=circle:1000@\(latitude),\(longitude)&fields=place_id,name,geometry&key=\(apiKey)")!

        let data = try await makeRequest(url: url, on: req)
        let response = try JSONDecoder().decode(GoogleFindPlaceResponse.self, from: data)

        guard let candidate = response.candidates.first else { return nil }

        // Fetch full details
        let detail = try await getPlaceDetails(placeID: candidate.placeId, on: req)

        try? await req.redis.set(RedisKey(cacheKey), toJSON: detail)
        _ = try? await req.redis.expire(RedisKey(cacheKey), after: .seconds(86400))

        return detail
    }

    // MARK: - Photo URL Builder

    func photoURL(reference: String, maxWidth: Int = 400) -> String {
        "\(baseURL)/photo?maxwidth=\(maxWidth)&photo_reference=\(reference)&key=\(apiKey)"
    }

    // MARK: - HTTP

    private func makeRequest(url: URL, on req: Request) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: URLRequest(url: url))

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            req.logger.error("[Google Places] API error \(status): \(String(data: data, encoding: .utf8) ?? "")")
            throw Abort(.badGateway, reason: "Google Places API returned \(status)")
        }

        return data
    }

    // MARK: - Convert to PlaceDetail (shared type)

    func toPlaceDetail(_ detail: GooglePlaceDetail) -> PlaceDetail {
        let hours: [DayHours]? = detail.openingHours?.periods?.compactMap { period in
            guard let open = period.open, let close = period.close else { return nil }
            return DayHours(day: open.day, start: open.time, end: close.time)
        }

        let photos: [String]? = detail.photos?.prefix(5).map { photo in
            photoURL(reference: photo.photoReference, maxWidth: 600)
        }

        let coords = detail.geometry.map {
            Coordinate(latitude: $0.location.lat, longitude: $0.location.lng)
        }

        let address = PlaceAddress(
            address1: detail.formattedAddress,
            city: nil, state: nil, zipCode: nil
        )

        let priceStr: String? = detail.priceLevel.map { String(repeating: "$", count: $0) }

        return PlaceDetail(
            yelpID: detail.placeId ?? "",
            name: detail.name,
            categories: detail.types ?? [],
            rating: detail.rating,
            reviewCount: nil,
            price: priceStr,
            phone: detail.formattedPhoneNumber,
            address: address,
            coordinates: coords,
            hours: hours,
            photos: photos,
            isOpenNow: detail.openingHours?.openNow
        )
    }
}

// MARK: - Google Places Response Types

struct GoogleNearbyResponse: Codable {
    let results: [GooglePlace]
    let status: String
}

struct GooglePlace: Codable {
    let placeId: String
    let name: String
    let rating: Float?
    let priceLevel: Int?
    let geometry: GoogleGeometry?
    let photos: [GooglePhoto]?
    let openingHours: GoogleOpeningHours?
    let types: [String]?
    let vicinity: String?

    enum CodingKeys: String, CodingKey {
        case placeId = "place_id"
        case name, rating, geometry, photos, types, vicinity
        case priceLevel = "price_level"
        case openingHours = "opening_hours"
    }
}

struct GoogleDetailResponse: Codable {
    let result: GooglePlaceDetail
    let status: String
}

struct GooglePlaceDetail: Codable {
    let placeId: String?
    let name: String
    let rating: Float?
    let priceLevel: Int?
    let formattedPhoneNumber: String?
    let website: String?
    let formattedAddress: String?
    let geometry: GoogleGeometry?
    let photos: [GooglePhoto]?
    let openingHours: GoogleDetailHours?
    let types: [String]?

    enum CodingKeys: String, CodingKey {
        case placeId = "place_id"
        case name, rating, geometry, photos, types, website
        case priceLevel = "price_level"
        case formattedPhoneNumber = "formatted_phone_number"
        case formattedAddress = "formatted_address"
        case openingHours = "opening_hours"
    }
}

struct GoogleGeometry: Codable {
    let location: GoogleLatLng
}

struct GoogleLatLng: Codable {
    let lat: Double
    let lng: Double
}

struct GooglePhoto: Codable {
    let photoReference: String
    let height: Int?
    let width: Int?

    enum CodingKeys: String, CodingKey {
        case photoReference = "photo_reference"
        case height, width
    }
}

struct GoogleOpeningHours: Codable {
    let openNow: Bool?

    enum CodingKeys: String, CodingKey {
        case openNow = "open_now"
    }
}

struct GoogleDetailHours: Codable {
    let openNow: Bool?
    let periods: [GoogleHourPeriod]?

    enum CodingKeys: String, CodingKey {
        case openNow = "open_now"
        case periods
    }
}

struct GoogleHourPeriod: Codable {
    let open: GoogleDayTime?
    let close: GoogleDayTime?
}

struct GoogleDayTime: Codable {
    let day: Int
    let time: String
}

struct GoogleFindPlaceResponse: Codable {
    let candidates: [GoogleFindCandidate]
    let status: String
}

struct GoogleFindCandidate: Codable {
    let placeId: String
    let name: String?
    let geometry: GoogleGeometry?

    enum CodingKeys: String, CodingKey {
        case placeId = "place_id"
        case name, geometry
    }
}
