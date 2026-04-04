import Vapor
import Fluent
import SQLKit
import Redis
import TidepoolShared

struct SearchController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        routes.post("places", use: searchPlaces)
    }

    /// POST /v1/search/places — Blended place search with interest alignment scoring
    func searchPlaces(req: Request) async throws -> Response {
        let payload = try req.auth.require(DevicePayload.self)
        let body = try req.content.decode(PlaceSearchRequest.self)

        guard let apiKey = Environment.get("YELP_API_KEY") else {
            throw Abort(.internalServerError, reason: "Yelp API key not configured")
        }

        let yelp = YelpService(apiKey: apiKey)
        let radiusMeters = body.radiusKm.map { Int($0 * 1000) }

        // Fetch Yelp results
        let yelpResults = try await yelp.searchBusinesses(
            .init(
                term: body.query,
                latitude: body.location.latitude,
                longitude: body.location.longitude,
                radiusMeters: radiusMeters,
                limit: body.limit ?? 20
            ),
            on: req
        )

        // Get viewer's interest vector for alignment scoring
        let viewerVector: [Float]?
        if let provided = body.interestVector {
            viewerVector = provided
        } else {
            // Try to load from DB
            viewerVector = try await loadVector(deviceID: payload.deviceID, on: req)
        }

        // Map and score results
        let results: [PlaceSearchResult] = yelpResults.businesses.enumerated().map { index, biz in
            let alignment = viewerVector.map { vec in
                computeInterestAlignment(categories: biz.categories.map(\.alias), viewerVector: vec)
            } ?? Float(0)

            let yelpScore = (biz.rating ?? 0) / 5.0
            let positionDecay = 1.0 - Float(index) / Float(max(yelpResults.businesses.count, 1))

            // Blended relevance: 0.4 yelp + 0.3 alignment + 0.2 position + 0.1 baseline
            let relevance = 0.4 * yelpScore + 0.3 * alignment + 0.2 * positionDecay + 0.1

            let coordinates = biz.coordinates.map { Coordinate(latitude: $0.latitude, longitude: $0.longitude) }
                ?? body.location

            var photos = biz.photos ?? []
            if photos.isEmpty, let imageUrl = biz.imageUrl {
                photos = [imageUrl]
            }

            let hours: [DayHours]? = biz.hours?.first?.open.map { period in
                DayHours(day: period.day, start: period.start, end: period.end)
            }

            return PlaceSearchResult(
                yelpID: biz.id,
                name: biz.name,
                category: biz.categories.first?.title ?? "Other",
                location: coordinates,
                rating: biz.rating,
                price: biz.price,
                photos: photos.isEmpty ? nil : photos,
                hours: hours,
                isOpenNow: biz.hours?.first?.isOpenNow,
                relevanceScore: relevance,
                interestAlignment: alignment
            )
        }.sorted { $0.relevanceScore > $1.relevanceScore }

        let response = PlaceSearchResponse(results: results, total: yelpResults.total)
        return try await response.encodeResponse(for: req)
    }

    // MARK: - Interest Alignment

    /// Compute alignment between a place's categories and the viewer's interest vector.
    private func computeInterestAlignment(categories: [String], viewerVector: [Float]) -> Float {
        guard !viewerVector.isEmpty else { return 0 }

        // Map Yelp category aliases to interest vocabulary tags
        let categoryTagMap: [String: [String]] = [
            "restaurants": ["dining", "restaurant", "social"],
            "food": ["dining", "restaurant"],
            "bars": ["bar", "nightlife", "social"],
            "coffee": ["coffee", "cafe", "work"],
            "cafes": ["cafe", "coffee", "social"],
            "nightlife": ["nightlife", "bar", "social", "entertainment"],
            "arts": ["arts", "culture", "museum"],
            "shopping": ["shopping", "mall"],
            "fitness": ["fitness", "gym", "sports"],
            "beautysvc": ["upscale", "trendy"],
            "parks": ["park", "outdoor", "nature"],
            "museums": ["museum", "culture", "arts"],
            "bakeries": ["bakery", "cafe"],
            "breweries": ["brewery", "craft_beer", "bar"],
            "wine_bars": ["wine_bar", "bar", "romantic"],
            "cocktailbars": ["cocktails", "bar", "nightlife"],
            "hiking": ["hiking", "outdoor", "nature", "fitness"],
            "bookstores": ["bookstore", "quiet", "culture"],
        ]

        // Build a simple place vector from categories
        var placeVector = [Float](repeating: 0, count: InterestVocabulary.dimensions)
        for categoryAlias in categories {
            let tags = categoryTagMap[categoryAlias] ?? []
            for tag in tags {
                if let idx = InterestVocabulary.index(of: tag) {
                    placeVector[idx] = 1.0
                }
            }
        }

        // Cosine similarity
        let dotProduct = zip(viewerVector, placeVector).reduce(Float(0)) { $0 + $1.0 * $1.1 }
        let normA = sqrt(viewerVector.reduce(Float(0)) { $0 + $1 * $1 })
        let normB = sqrt(placeVector.reduce(Float(0)) { $0 + $1 * $1 })

        guard normA > 0, normB > 0 else { return 0 }
        return dotProduct / (normA * normB)
    }

    // MARK: - Load Vector from DB

    private func loadVector(deviceID: UUID, on req: Request) async throws -> [Float]? {
        guard let sql = req.db as? SQLDatabase else { return nil }
        let rows = try await sql.raw(SQLQueryString("""
            SELECT interest_vector::text as interest_vector
            FROM device_profiles WHERE device_id = '\(unsafeRaw: deviceID.uuidString)'::uuid
            """)).all(decoding: VectorRow.self)
        return rows.first.map { DeviceProfile.stringToVector($0.interest_vector) }
    }

    private struct VectorRow: Decodable {
        let interest_vector: String
    }
}

extension PlaceSearchRequest: @retroactive Content {}
extension PlaceSearchResponse: @retroactive Content {}
extension PlaceSearchResult: @retroactive Content {}
