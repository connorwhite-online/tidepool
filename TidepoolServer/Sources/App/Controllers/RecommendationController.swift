import Vapor
import Fluent
import SQLKit
@preconcurrency import Redis
import TidepoolShared

struct RecommendationController: RouteCollection {
    /// 5 minutes — fresh enough that newly-onboarded similar users surface
    /// quickly but long enough to absorb repeated For You panel opens.
    private let responseCacheTTL = 300

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

        // Response cache — the heavy aggregate query is the bulk of the cost
        // and the result varies only by (device, day_of_week, hour-bucket).
        let responseCacheKey = "rec:\(deviceIDStr):\(body.currentDayOfWeek):\(body.currentHour)"
        if let cached = try? await req.redis.get(RedisKey(responseCacheKey), asJSON: RecommendationResponse.self) {
            return cached
        }

        let similarIDs = try await loadSimilarUserIDs(deviceID: deviceIDStr, sql: sql, req: req)

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

        let response = RecommendationResponse(recommendations: recommendations)

        // Atomic SET ... EX so we never leak a TTL-less cache entry on crash.
        if let data = try? JSONEncoder().encode(response),
           let json = String(data: data, encoding: .utf8) {
            _ = try? await req.redis.send(command: "SET", with: [
                .init(from: responseCacheKey),
                .init(from: json),
                .init(from: "EX"),
                .init(from: String(responseCacheTTL))
            ]).get()
        }

        return response
    }

    private func loadSimilarUserIDs(deviceID: String, sql: SQLDatabase, req: Request) async throws -> [String] {
        let entries = try await SimilarUsersCache.load(
            deviceID: deviceID,
            sql: sql,
            redis: req.redis,
            logger: req.logger
        )
        return entries.map { $0.id }
    }

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
