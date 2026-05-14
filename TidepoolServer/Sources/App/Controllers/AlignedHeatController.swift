import Vapor
import Fluent
import SQLKit
@preconcurrency import Redis
import TidepoolShared

struct AlignedHeatController: RouteCollection {
    private let kMin = 2
    private let epsilon: Float = 0.5

    func boot(routes: RoutesBuilder) throws {
        routes.post("aligned-heat", use: alignedHeat)
    }

    /// Return heat tiles based on where similar users visit at this time of day.
    func alignedHeat(req: Request) async throws -> HeatTileResponse {
        let payload = try req.auth.require(DevicePayload.self)
        let body = try req.content.decode(AlignedHeatRequest.self)

        guard let sql = req.db as? SQLDatabase else {
            throw Abort(.internalServerError, reason: "SQL database required")
        }

        let deviceIDStr = payload.deviceID.uuidString

        // Get similar users (cached in Redis or computed)
        let similarUsers = try await getSimilarUsers(deviceID: deviceIDStr, sql: sql, req: req)

        guard !similarUsers.isEmpty else {
            let meta = HeatTileMeta(kMin: kMin, epsilon: epsilon, ttlSeconds: 900)
            return HeatTileResponse(tiles: [], meta: meta)
        }

        // Build similarity lookup
        let simLookup = Dictionary(uniqueKeysWithValues: similarUsers.map { ($0.id, $0.similarity) })
        let deviceList = similarUsers.map { "'\($0.id)'::uuid" }.joined(separator: ",")

        // Enumerate the viewport's tile IDs once on the server. tile_id is a
        // GENERATED column on visits, so the SQL groups by it directly and
        // returns one row per (device, tile, hour) instead of one row per
        // (device, exact lat, exact lng, hour). That's typically a 5-10x
        // reduction in rows shipped for a city-scale user.
        let viewportTileIDs = GridTiler.tilesInBounds(sw: body.viewport.sw, ne: body.viewport.ne)
            .map { $0.description }
        guard !viewportTileIDs.isEmpty else {
            let meta = HeatTileMeta(kMin: kMin, epsilon: epsilon, ttlSeconds: 900)
            return HeatTileResponse(tiles: [], meta: meta)
        }

        // Query visits with individual device_id for similarity weighting,
        // grouped by precomputed tile_id.
        let visitRows = try await sql.raw(SQLQueryString("""
            SELECT device_id::text as device_id, tile_id, hour_of_day,
                   COUNT(*) as visit_count
            FROM visits
            WHERE device_id IN (\(unsafeRaw: deviceList))
              AND tile_id = ANY(\(bind: viewportTileIDs)::text[])
              AND (day_of_week = \(unsafeRaw: String(body.currentDayOfWeek))
                   OR day_of_week = \(unsafeRaw: String((body.currentDayOfWeek + 6) % 7))
                   OR day_of_week = \(unsafeRaw: String((body.currentDayOfWeek + 1) % 7)))
            GROUP BY device_id, tile_id, hour_of_day
            """)).all(decoding: WeightedVisitRow.self)

        // Compute weighted intensity per tile.
        var tileScores: [String: Float] = [:]
        var tileContributors: [String: Set<String>] = [:]

        for row in visitRows {
            let similarity = simLookup[row.device_id] ?? 0.1
            let frequency = min(Float(row.visit_count) / 20.0, 1.0)
            let timeRelevance = gaussianTimeRelevance(visitHour: row.hour_of_day, currentHour: body.currentHour)

            let score = similarity * frequency * timeRelevance
            tileScores[row.tile_id, default: 0] += score
            tileContributors[row.tile_id, default: []].insert(row.device_id)
        }

        var heatTiles: [HeatTile] = []
        for (tileStr, score) in tileScores {
            let contributorCount = tileContributors[tileStr]?.count ?? 0
            guard contributorCount >= kMin else { continue }

            let noisyScore = score + laplace(epsilon: epsilon) * 0.1
            let intensity = min(1.0, max(0, noisyScore))

            heatTiles.append(HeatTile(
                tileID: tileStr,
                intensity: intensity,
                contributorCount: contributorCount
            ))
        }

        let meta = HeatTileMeta(kMin: kMin, epsilon: epsilon, ttlSeconds: 900)
        return HeatTileResponse(tiles: heatTiles, meta: meta)
    }

    // MARK: - Similar Users

    /// Read precomputed tidepool matches, fall back to inline computation for new users.
    /// Cache the similar-users list in Redis. Aligned-heat fires on every map
    /// pan and the underlying tidepools table only changes when the nightly
    /// batch runs or the user's vectors update, so the DB query is wasted
    /// work on the second-through-N-th pan.
    private let similarCacheTTL = 900 // 15 minutes

    private func getSimilarUsers(deviceID: String, sql: SQLDatabase, req: Request) async throws -> [(id: String, similarity: Float)] {
        let cacheKey = "aligned_sim:\(deviceID)"

        if let cached = try? await req.redis.get(RedisKey(cacheKey), asJSON: [CachedSim].self) {
            return cached.map { (id: $0.id, similarity: $0.similarity) }
        }

        // Read from precomputed tidepools table
        let rows = try await sql.raw(SQLQueryString("""
            SELECT match_id::text as device_id, similarity_score
            FROM tidepools
            WHERE device_id = '\(unsafeRaw: deviceID)'::uuid
            ORDER BY similarity_score DESC
            """)).all(decoding: SimilarRow.self)

        let result: [(id: String, similarity: Float)]
        if !rows.isEmpty {
            result = rows.map { (id: $0.device_id, similarity: $0.similarity_score) }
        } else {
            // Fallback for users with no precomputed tidepool yet
            req.logger.info("[AlignedHeat] No precomputed tidepool for \(deviceID), using inline")
            let fallback = try await sql.raw(SQLQueryString("""
                SELECT p2.device_id::text as device_id,
                       1.0 - (p1.interest_vector <=> p2.interest_vector) as similarity_score
                FROM device_profiles p1
                CROSS JOIN device_profiles p2
                WHERE p1.device_id = '\(unsafeRaw: deviceID)'::uuid
                  AND p2.device_id != '\(unsafeRaw: deviceID)'::uuid
                  AND p2.quality != 'poor'
                ORDER BY p1.interest_vector <=> p2.interest_vector
                LIMIT 100
                """)).all(decoding: SimilarRow.self)
            result = fallback.map { (id: $0.device_id, similarity: $0.similarity_score) }
        }

        // Cache atomically (SET ... EX). A separate SET + EXPIRE would leak
        // a TTL-less key on a crash between the two.
        let cacheable = result.map { CachedSim(id: $0.id, similarity: $0.similarity) }
        if let data = try? JSONEncoder().encode(cacheable),
           let json = String(data: data, encoding: .utf8) {
            _ = try? await req.redis.send(command: "SET", with: [
                .init(from: cacheKey),
                .init(from: json),
                .init(from: "EX"),
                .init(from: String(similarCacheTTL))
            ]).get()
        }

        return result
    }

    private struct SimilarRow: Decodable {
        let device_id: String
        let similarity_score: Float
    }

    /// Storage shape for the Redis-cached similar-users list. Kept separate
    /// from SimilarRow because Decodable for a tuple in Swift is annoying.
    private struct CachedSim: Codable {
        let id: String
        let similarity: Float
    }

    private struct WeightedVisitRow: Decodable {
        let device_id: String
        let tile_id: String
        let hour_of_day: Int
        let visit_count: Int
    }

    /// Gaussian decay centered on current hour (sigma = 2 hours).
    private func gaussianTimeRelevance(visitHour: Int, currentHour: Int) -> Float {
        let diff = min(abs(visitHour - currentHour), 24 - abs(visitHour - currentHour))
        let sigma: Float = 2.0
        return exp(-Float(diff * diff) / (2 * sigma * sigma))
    }

    private func laplace(epsilon: Float) -> Float {
        let scale = 1.0 / epsilon
        let u = Float.random(in: -0.5..<0.5)
        return -scale * (u > 0 ? 1 : -1) * log(1.0 - 2.0 * abs(u))
    }
}

extension AlignedHeatRequest: @retroactive Content {}
