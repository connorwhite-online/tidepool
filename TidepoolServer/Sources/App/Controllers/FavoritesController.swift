import Vapor
import Fluent
import TidepoolShared

struct FavoritesController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        routes.post(use: addFavorite)
        routes.get(use: getFavorites)
        routes.delete(":favoriteID", use: deleteFavorite)
    }

    /// Add a favorite for the authenticated device.
    func addFavorite(req: Request) async throws -> FavoriteResponse {
        let payload = try req.auth.require(DevicePayload.self)
        let body = try req.content.decode(FavoriteRequest.self)

        // Check for duplicate
        let existing = try await Favorite.query(on: req.db)
            .filter(\.$device.$id == payload.deviceID)
            .filter(\.$placeID == body.placeID)
            .first()

        if let existing {
            // Update existing favorite
            existing.rating = body.rating
            existing.yelpID = body.yelpID
            try await existing.save(on: req.db)
            return favoriteToResponse(existing)
        }

        let favorite = Favorite(
            deviceID: payload.deviceID,
            placeID: body.placeID,
            yelpID: body.yelpID,
            name: body.name,
            category: body.category.rawValue,
            latitude: body.latitude,
            longitude: body.longitude,
            rating: body.rating
        )
        try await favorite.save(on: req.db)
        return favoriteToResponse(favorite)
    }

    /// Get all favorites for the authenticated device.
    func getFavorites(req: Request) async throws -> [FavoriteResponse] {
        let payload = try req.auth.require(DevicePayload.self)

        let favorites = try await Favorite.query(on: req.db)
            .filter(\.$device.$id == payload.deviceID)
            .sort(\.$createdAt, .descending)
            .all()

        return favorites.map { favoriteToResponse($0) }
    }

    /// Delete a favorite by ID.
    func deleteFavorite(req: Request) async throws -> HTTPStatus {
        let payload = try req.auth.require(DevicePayload.self)

        guard let favoriteIDString = req.parameters.get("favoriteID"),
              let favoriteID = UUID(uuidString: favoriteIDString) else {
            throw Abort(.badRequest, reason: "Invalid favorite ID")
        }

        guard let favorite = try await Favorite.find(favoriteID, on: req.db) else {
            throw Abort(.notFound, reason: "Favorite not found")
        }

        // Ensure the favorite belongs to this device
        guard favorite.$device.id == payload.deviceID else {
            throw Abort(.forbidden, reason: "Not your favorite")
        }

        try await favorite.delete(on: req.db)
        return .noContent
    }

    // MARK: - Helpers

    private func favoriteToResponse(_ fav: Favorite) -> FavoriteResponse {
        FavoriteResponse(
            id: fav.id?.uuidString ?? "",
            placeID: fav.placeID,
            yelpID: fav.yelpID,
            name: fav.name,
            category: PlaceCategory(rawValue: fav.category) ?? .other,
            rating: fav.rating,
            createdAt: ISO8601DateFormatter().string(from: fav.createdAt)
        )
    }
}

// MARK: - Vapor Content conformance

extension FavoriteRequest: @retroactive Content {}
extension FavoriteResponse: @retroactive Content {}
