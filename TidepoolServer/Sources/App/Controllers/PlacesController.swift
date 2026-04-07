import Vapor
import Redis
import TidepoolShared

struct PlacesController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        routes.get(":placeID", use: getDetail)
        routes.get("match", use: matchPlace)
    }

    // MARK: - Place Detail

    /// GET /v1/places/:placeID — Enriched place detail from Foursquare
    func getDetail(req: Request) async throws -> Response {
        guard let placeID = req.parameters.get("placeID") else {
            throw Abort(.badRequest, reason: "Missing placeID parameter")
        }

        let fsq = try getService(req: req)
        let place = try await fsq.getPlaceDetails(fsqID: placeID, on: req)
        let detail = mapToPlaceDetail(place)

        return try await detail.encodeResponse(for: req)
    }

    // MARK: - Place Match

    struct PlaceMatchQuery: Content {
        let name: String
        let lat: Double
        let lng: Double
    }

    /// GET /v1/places/match?name=X&lat=Y&lng=Z — Match a place to Foursquare
    func matchPlace(req: Request) async throws -> Response {
        let query = try req.query.decode(PlaceMatchQuery.self)

        let fsq = try getService(req: req)
        guard let place = try await fsq.matchPlace(
            name: query.name,
            latitude: query.lat,
            longitude: query.lng,
            on: req
        ) else {
            throw Abort(.notFound, reason: "No match found for '\(query.name)'")
        }

        let detail = mapToPlaceDetail(place)
        return try await detail.encodeResponse(for: req)
    }

    // MARK: - Helpers

    private func getService(req: Request) throws -> FoursquareService {
        guard let clientID = Environment.get("FSQ_CLIENT_ID"),
              let clientSecret = Environment.get("FSQ_CLIENT_SECRET") else {
            throw Abort(.internalServerError, reason: "Foursquare credentials not configured")
        }
        return FoursquareService(clientID: clientID, clientSecret: clientSecret)
    }

    private func mapToPlaceDetail(_ place: FSQPlace) -> PlaceDetail {
        // Map Foursquare hours (day: 1=Mon..7=Sun) to our format (day: 0=Mon..6=Sun)
        let hours: [DayHours]? = place.hours?.regular?.map { period in
            DayHours(day: period.day - 1, start: period.open, end: period.close)
        }

        // Build photo URLs from prefix + suffix
        let photos: [String] = (place.photos ?? []).compactMap { $0.url }

        let address = place.location.map { loc in
            PlaceAddress(
                address1: loc.address,
                city: loc.locality,
                state: loc.region,
                zipCode: loc.postcode
            )
        }

        let coordinates = place.geocodes?.main.map { geo in
            Coordinate(latitude: geo.latitude, longitude: geo.longitude)
        }

        // Map Foursquare price (1-4 int) to string ($-$$$$)
        let priceStr: String? = place.price.map { String(repeating: "$", count: $0) }

        return PlaceDetail(
            yelpID: place.fsqId ?? "",  // reusing field name for backward compat
            name: place.name,
            categories: (place.categories ?? []).map(\.name),
            rating: place.rating.map { $0 / 2.0 },  // FSQ uses 0-10, normalize to 0-5
            reviewCount: nil,
            price: priceStr,
            phone: place.tel,
            address: address,
            coordinates: coordinates,
            hours: hours,
            photos: photos.isEmpty ? nil : photos,
            isOpenNow: place.hours?.openNow
        )
    }
}

extension PlaceDetail: @retroactive Content {}
extension PlaceAddress: @retroactive Content {}
