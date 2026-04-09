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

        guard let apiKey = Environment.get("GOOGLE_PLACES_KEY") else {
            throw Abort(.internalServerError, reason: "Google Places API key not configured")
        }

        let google = GooglePlacesService(apiKey: apiKey)
        let radiusMeters = body.radiusKm.map { Int($0 * 1000) }

        // Fetch Google Places results
        let googleResults = try await google.searchPlaces(
            .init(
                query: body.query,
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
            viewerVector = try await loadVector(deviceID: payload.deviceID, on: req)
        }

        // Map and score results
        let results: [PlaceSearchResult] = googleResults.enumerated().map { index, place in
            let categoryNames = (place.types ?? []).map { $0.lowercased() }
            let alignment = viewerVector.map { vec in
                computeInterestAlignment(categories: categoryNames, viewerVector: vec)
            } ?? Float(0)

            let ratingScore = (place.rating ?? 0) / 5.0
            let positionDecay = 1.0 - Float(index) / Float(max(googleResults.count, 1))

            let relevance = 0.4 * ratingScore + 0.3 * alignment + 0.2 * positionDecay + 0.1

            let coordinates = place.geometry.map { Coordinate(latitude: $0.location.lat, longitude: $0.location.lng) }
                ?? body.location

            let priceStr: String? = place.priceLevel.map { String(repeating: "$", count: $0) }

            return PlaceSearchResult(
                yelpID: place.placeId,
                name: place.name,
                category: (place.types ?? []).first ?? "Other",
                location: coordinates,
                rating: place.rating,
                price: priceStr,
                photos: nil,
                hours: nil,
                isOpenNow: place.openingHours?.openNow,
                relevanceScore: relevance,
                interestAlignment: alignment
            )
        }.sorted { $0.relevanceScore > $1.relevanceScore }

        let response = PlaceSearchResponse(results: results, total: googleResults.count)
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
