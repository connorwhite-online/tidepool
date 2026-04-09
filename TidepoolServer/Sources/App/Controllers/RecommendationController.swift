import Vapor
import Fluent
import SQLKit
@preconcurrency import Redis
import TidepoolShared

struct RecommendationController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        routes.post(use: getRecommendations)
    }

    /// Return ranked POI recommendations based on where similar users go.
    func getRecommendations(req: Request) async throws -> RecommendationResponse {
        let payload = try req.auth.require(DevicePayload.self)
        let body = try req.content.decode(RecommendationRequest.self)

        guard let sql = req.db as? SQLDatabase else {
            throw Abort(.internalServerError, reason: "SQL database required")
        }

        let deviceIDStr = payload.deviceID.uuidString
        let limit = body.limit ?? 20

        // Get similar users from Redis cache or compute
        let cacheKey = RedisKey("aligned:\(deviceIDStr)")
        let cached = try? await req.redis.send(command: "SMEMBERS", with: [
            .init(from: cacheKey.rawValue)
        ]).get()

        var similarIDs: [String] = []
        if let cached, let members = cached.array, !members.isEmpty {
            similarIDs = members.compactMap { $0.string }
        } else {
            // Fallback: compute similarity inline
            let rows = try await sql.raw(SQLQueryString("""
                SELECT p2.device_id::text as device_id
                FROM device_profiles p1
                CROSS JOIN device_profiles p2
                WHERE p1.device_id = '\(unsafeRaw: deviceIDStr)'::uuid
                  AND p2.device_id != '\(unsafeRaw: deviceIDStr)'::uuid
                  AND p2.quality != 'poor'
                ORDER BY
                    CASE
                        WHEN p1.places_vector IS NOT NULL AND p2.places_vector IS NOT NULL
                        THEN 0.5 * (p1.places_vector <=> p2.places_vector)
                             + 0.3 * COALESCE(p1.music_vector <=> p2.music_vector, 1)
                             + 0.2 * COALESCE(p1.vibe_vector <=> p2.vibe_vector, 1)
                        ELSE p1.interest_vector <=> p2.interest_vector
                    END
                LIMIT 50
                """)).all(decoding: DeviceIDRow.self)
            similarIDs = rows.map { $0.device_id }
        }

        guard !similarIDs.isEmpty else {
            return RecommendationResponse(recommendations: [])
        }

        let deviceList = similarIDs.map { "'\($0)'::uuid" }.joined(separator: ",")
        let hourLow = (body.currentHour - 3 + 24) % 24
        let hourHigh = (body.currentHour + 3) % 24

        let hourFilter: String
        if hourLow < hourHigh {
            hourFilter = "hour_of_day BETWEEN \(hourLow) AND \(hourHigh)"
        } else {
            hourFilter = "(hour_of_day >= \(hourLow) OR hour_of_day <= \(hourHigh))"
        }

        // Aggregate visits from similar users, exclude requesting user's own visits
        let rows = try await sql.raw(SQLQueryString("""
            SELECT
                v.poi_id, v.yelp_id, v.name, v.category,
                AVG(v.latitude) as latitude, AVG(v.longitude) as longitude,
                COUNT(*) as total_visits,
                COUNT(DISTINCT v.device_id) as unique_visitors,
                array_agg(DISTINCT v.hour_of_day ORDER BY v.hour_of_day) as typical_hours
            FROM visits v
            WHERE v.device_id IN (\(unsafeRaw: deviceList))
              AND v.device_id != '\(unsafeRaw: deviceIDStr)'::uuid
              AND \(unsafeRaw: hourFilter)
            GROUP BY v.poi_id, v.yelp_id, v.name, v.category
            HAVING COUNT(DISTINCT v.device_id) >= 2
            ORDER BY COUNT(DISTINCT v.device_id) DESC, COUNT(*) DESC
            LIMIT \(unsafeRaw: String(limit))
            """)).all(decoding: RecommendationRow.self)

        let recommendations = rows.map { row in
            let score = Float(row.unique_visitors) * Float(row.total_visits) / 100.0
            return RecommendedPlace(
                poiId: row.poi_id,
                yelpId: row.yelp_id,
                name: row.name,
                category: PlaceCategory(rawValue: row.category) ?? .other,
                latitude: row.latitude,
                longitude: row.longitude,
                score: min(1.0, score),
                alignedVisitors: row.unique_visitors,
                typicalHours: row.typical_hours
            )
        }

        return RecommendationResponse(recommendations: recommendations)
    }

    private struct DeviceIDRow: Decodable { let device_id: String }
    private struct RecommendationRow: Decodable {
        let poi_id: String?
        let yelp_id: String?
        let name: String
        let category: String
        let latitude: Double
        let longitude: Double
        let total_visits: Int
        let unique_visitors: Int
        let typical_hours: [Int]
    }
}

extension RecommendationRequest: @retroactive Content {}
extension RecommendationResponse: @retroactive Content {}
