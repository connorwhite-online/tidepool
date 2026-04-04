import Vapor
import Redis
import TidepoolShared

struct PlacesController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        // All places routes require authentication (set up in routes.swift)
        routes.get(":yelpID", use: getDetail)
        routes.get("match", use: matchPlace)
    }

    // MARK: - Place Detail

    /// GET /v1/places/:yelpID — Enriched place detail from Yelp
    func getDetail(req: Request) async throws -> Response {
        guard let yelpID = req.parameters.get("yelpID") else {
            throw Abort(.badRequest, reason: "Missing yelpID parameter")
        }

        let yelp = try getYelpService(req: req)
        let business = try await yelp.getBusinessDetails(yelpID: yelpID, on: req)
        let detail = mapToPlaceDetail(business)

        return try await detail.encodeResponse(for: req)
    }

    // MARK: - Place Match

    struct PlaceMatchQuery: Content {
        let name: String
        let lat: Double
        let lng: Double
    }

    /// GET /v1/places/match?name=X&lat=Y&lng=Z — Match a MapKit place to a Yelp ID
    func matchPlace(req: Request) async throws -> Response {
        let query = try req.query.decode(PlaceMatchQuery.self)

        let yelp = try getYelpService(req: req)
        guard let business = try await yelp.matchBusiness(
            name: query.name,
            latitude: query.lat,
            longitude: query.lng,
            on: req
        ) else {
            throw Abort(.notFound, reason: "No Yelp match found for '\(query.name)'")
        }

        let detail = mapToPlaceDetail(business)
        return try await detail.encodeResponse(for: req)
    }

    // MARK: - Helpers

    private func getYelpService(req: Request) throws -> YelpService {
        guard let apiKey = Environment.get("YELP_API_KEY") else {
            throw Abort(.internalServerError, reason: "Yelp API key not configured")
        }
        return YelpService(apiKey: apiKey)
    }

    private func mapToPlaceDetail(_ business: YelpBusiness) -> PlaceDetail {
        let hours: [DayHours]? = business.hours?.first?.open.map { period in
            DayHours(day: period.day, start: period.start, end: period.end)
        }

        var photos = business.photos ?? []
        if photos.isEmpty, let imageUrl = business.imageUrl {
            photos = [imageUrl]
        }

        let address = business.location.map { loc in
            PlaceAddress(
                address1: loc.address1,
                city: loc.city,
                state: loc.state,
                zipCode: loc.zipCode
            )
        }

        let coordinates = business.coordinates.map { coords in
            Coordinate(latitude: coords.latitude, longitude: coords.longitude)
        }

        let isOpenNow = business.hours?.first?.isOpenNow

        return PlaceDetail(
            yelpID: business.id,
            name: business.name,
            categories: business.categories.map(\.title),
            rating: business.rating,
            reviewCount: business.reviewCount,
            price: business.price,
            phone: business.phone,
            address: address,
            coordinates: coordinates,
            hours: hours,
            photos: photos.isEmpty ? nil : photos,
            isOpenNow: isOpenNow
        )
    }
}

extension PlaceDetail: @retroactive Content {}
extension PlaceAddress: @retroactive Content {}
