import Vapor
import Redis
import TidepoolShared

struct PlacesController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        routes.get(":placeID", use: getDetail)
        routes.get("match", use: matchPlace)
    }

    // MARK: - Place Detail

    /// GET /v1/places/:placeID — Enriched place detail from Google Places
    func getDetail(req: Request) async throws -> Response {
        guard let placeID = req.parameters.get("placeID") else {
            throw Abort(.badRequest, reason: "Missing placeID parameter")
        }

        let google = try getService(req: req)
        let detail = try await google.getPlaceDetails(placeID: placeID, on: req)
        let mapped = google.toPlaceDetail(detail)

        return try await mapped.encodeResponse(for: req)
    }

    // MARK: - Place Match

    struct PlaceMatchQuery: Content {
        let name: String
        let lat: Double
        let lng: Double
    }

    /// GET /v1/places/match?name=X&lat=Y&lng=Z — Match a place via Google Places
    func matchPlace(req: Request) async throws -> Response {
        let query = try req.query.decode(PlaceMatchQuery.self)

        let google = try getService(req: req)
        guard let detail = try await google.matchPlace(
            name: query.name,
            latitude: query.lat,
            longitude: query.lng,
            on: req
        ) else {
            throw Abort(.notFound, reason: "No match found for '\(query.name)'")
        }

        let mapped = google.toPlaceDetail(detail)
        return try await mapped.encodeResponse(for: req)
    }

    // MARK: - Helpers

    private func getService(req: Request) throws -> GooglePlacesService {
        guard let apiKey = Environment.get("GOOGLE_PLACES_KEY") else {
            throw Abort(.internalServerError, reason: "Google Places API key not configured")
        }
        return GooglePlacesService(apiKey: apiKey)
    }
}

extension PlaceDetail: @retroactive Content {}
extension PlaceAddress: @retroactive Content {}
