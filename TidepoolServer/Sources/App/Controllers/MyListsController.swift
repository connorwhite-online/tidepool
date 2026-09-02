import CryptoKit
import Vapor
import Fluent
import SQLKit
@preconcurrency import Redis
import TidepoolShared

struct MyListsController: RouteCollection {
    private let cacheTTLSeconds = 120

    func boot(routes: RoutesBuilder) throws {
        routes.get(use: getMyLists)
    }

    /// GET /v1/lists?lat=..&lng=..&radius_miles=10
    /// Compiles categorized, ranked "My Lists" from visits + favorites near the user.
    func getMyLists(req: Request) async throws -> MyListsResponse {
        let payload = try req.auth.require(DevicePayload.self)

        guard let lat = try? req.query.get(Double.self, at: "lat"),
              let lng = try? req.query.get(Double.self, at: "lng") else {
            throw Abort(.badRequest, reason: "lat and lng query parameters are required")
        }

        let radiusMiles = (try? req.query.get(Double.self, at: "radius_miles")) ?? 10
        let center = Coordinate(latitude: lat, longitude: lng)

        // Cache keyed by device + coarse location bucket (~1km) + radius.
        let bucketLat = (lat * 100).rounded() / 100
        let bucketLng = (lng * 100).rounded() / 100
        let cacheKey = RedisKey("my_lists:\(payload.deviceID.uuidString):\(bucketLat):\(bucketLng):\(radiusMiles)")
        if let cached = try? await req.redis.get(cacheKey, asJSON: MyListsResponse.self) {
            return cached
        }

        guard let sql = req.db as? SQLDatabase else {
            throw Abort(.internalServerError, reason: "SQL database required")
        }

        let deviceIDStr = payload.deviceID.uuidString
        let signals = try await loadSignals(deviceID: payload.deviceID, sql: sql, db: req.db)

        let response = MyListsEngine.compile(
            signals: signals,
            options: MyListsCompileOptions(center: center, radiusMiles: radiusMiles)
        )

        if let data = try? JSONEncoder().encode(response),
           let json = String(data: data, encoding: .utf8) {
            _ = try? await req.redis.send(command: "SET", with: [
                .init(from: cacheKey.rawValue),
                .init(from: json),
                .init(from: "EX"),
                .init(from: String(cacheTTLSeconds))
            ]).get()
        }

        return response
    }

    private func loadSignals(deviceID: UUID, sql: SQLDatabase, db: Database) async throws -> [MyListPlaceSignal] {
        let deviceIDStr = deviceID.uuidString
        let patternRows = try await sql.raw(SQLQueryString("""
            SELECT
                poi_id,
                yelp_id,
                name,
                category,
                latitude,
                longitude,
                COUNT(*) as visit_count,
                AVG(duration_minutes)::int as avg_duration,
                array_agg(DISTINCT hour_of_day ORDER BY hour_of_day) as typical_hours,
                MAX(arrived_at) as last_visit
            FROM visits
            WHERE device_id = '\(unsafeRaw: deviceIDStr)'::uuid
            GROUP BY poi_id, yelp_id, name, category, latitude, longitude
            """)).all(decoding: PatternRow.self)

        let favorites = try await Favorite.query(on: db)
            .filter(\.$device.$id == deviceID)
            .all()

        let favByPlaceID = Dictionary(uniqueKeysWithValues: favorites.map { ($0.placeID, $0) })

        var signals: [MyListPlaceSignal] = []
        signals.reserveCapacity(patternRows.count + favorites.count)

        var seenPlaceIDs = Set<String>()

        for row in patternRows {
            let placeID = stablePlaceID(name: row.name, lat: row.latitude, lng: row.longitude)
            seenPlaceIDs.insert(placeID)
            let fav = favByPlaceID[placeID]

            signals.append(MyListPlaceSignal(
                poiId: row.poi_id,
                yelpId: row.yelp_id,
                placeId: placeID,
                name: row.name,
                category: PlaceCategory(rawValue: row.category) ?? .other,
                latitude: row.latitude,
                longitude: row.longitude,
                visitCount: row.visit_count,
                avgDurationMinutes: row.avg_duration,
                typicalHours: row.typical_hours,
                lastVisit: row.last_visit,
                favoriteRating: fav?.rating,
                isExplicitFavorite: fav != nil
            ))
        }

        // Favorites without enough visits still belong in lists.
        for fav in favorites where !seenPlaceIDs.contains(fav.placeID) {
            signals.append(MyListPlaceSignal(
                poiId: nil,
                yelpId: fav.yelpID,
                placeId: fav.placeID,
                name: fav.name,
                category: PlaceCategory(rawValue: fav.category) ?? .other,
                latitude: fav.latitude,
                longitude: fav.longitude,
                visitCount: 1,
                avgDurationMinutes: 30,
                typicalHours: [],
                lastVisit: fav.createdAt,
                favoriteRating: fav.rating,
                isExplicitFavorite: true
            ))
        }

        return signals
    }

    /// Mirrors iOS `FavoriteLocation.stablePlaceId` — deterministic opaque id.
    private func stablePlaceID(name: String, lat: Double, lng: Double) -> String {
        let latStr = String(format: "%.5f", lat)
        let lngStr = String(format: "%.5f", lng)
        let input = "\(name)|\(latStr)|\(lngStr)"
        let digest = SHA256.hash(data: Data(input.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "p_" + String(hex.prefix(16))
    }

    private struct PatternRow: Decodable {
        let poi_id: String?
        let yelp_id: String?
        let name: String
        let category: String
        let latitude: Double
        let longitude: Double
        let visit_count: Int
        let avg_duration: Int
        let typical_hours: [Int]
        let last_visit: Date
    }
}

extension MyListsResponse: @retroactive Content {}
