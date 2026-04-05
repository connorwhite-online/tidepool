import Vapor

func routes(_ app: Application) throws {
    // Health check
    app.get("health") { req in
        ["status": "ok"]
    }

    // API v1
    let v1 = app.grouped("v1")

    // Auth (unauthenticated)
    try v1.grouped("auth").register(collection: AuthController())

    // Authenticated routes
    let authenticated = v1.grouped(JWTAuthMiddleware())

    try authenticated.grouped("profile").register(collection: ProfileController())
    try authenticated.grouped("places").register(collection: PlacesController())
    try authenticated.grouped("search").register(collection: SearchController())
    try authenticated.grouped("presence").register(collection: PresenceController())
    try authenticated.grouped("tiles").register(collection: HeatTileController())
    try authenticated.grouped("favorites").register(collection: FavoritesController())
    try authenticated.grouped("profile").register(collection: SimilarController())
    try authenticated.grouped("profile").register(collection: TasteSummaryController())
    try authenticated.grouped("visits").register(collection: VisitController())
    try authenticated.grouped("tiles").register(collection: AlignedHeatController())
    try authenticated.grouped("recommendations").register(collection: RecommendationController())
}
