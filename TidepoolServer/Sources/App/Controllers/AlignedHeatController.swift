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

        // Query visits with individual device_id for similarity weighting
        let visitRows = try await sql.raw(SQLQueryString("""
            SELECT device_id::text as device_id, latitude, longitude, hour_of_day,
                   COUNT(*) as visit_count
            FROM visits
            WHERE device_id IN (\(unsafeRaw: deviceList))
              AND (day_of_week = \(unsafeRaw: String(body.currentDayOfWeek))
                   OR day_of_week = \(unsafeRaw: String((body.currentDayOfWeek + 6) % 7))
                   OR day_of_week = \(unsafeRaw: String((body.currentDayOfWeek + 1) % 7)))
            GROUP BY device_id, latitude, longitude, hour_of_day
            """)).all(decoding: WeightedVisitRow.self)

        // Snap to tiles and compute weighted intensity
        var tileScores: [String: Float] = [:]
        var tileContributors: [String: Set<String>] = [:]

        for row in visitRows {
            let coord = Coordinate(latitude: row.latitude, longitude: row.longitude)
            let tileID = GridTiler.tileID(for: coord).description

            let similarity = simLookup[row.device_id] ?? 0.1
            let frequency = min(Float(row.visit_count) / 20.0, 1.0)
            let timeRelevance = gaussianTimeRelevance(visitHour: row.hour_of_day, currentHour: body.currentHour)

            let score = similarity * frequency * timeRelevance
            tileScores[tileID, default: 0] += score
            tileContributors[tileID, default: []].insert(row.device_id)
        }

        // Filter by viewport and k-anonymity
        let viewportTiles = Set(
            GridTiler.tilesInBounds(sw: body.viewport.sw, ne: body.viewport.ne)
                .map { $0.description }
        )

        var heatTiles: [HeatTile] = []
        for (tileStr, score) in tileScores where viewportTiles.contains(tileStr) {
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
    private func getSimilarUsers(deviceID: String, sql: SQLDatabase, req: Request) async throws -> [(id: String, similarity: Float)] {
        // Read from precomputed tidepools table
        let rows = try await sql.raw(SQLQueryString("""
            SELECT match_id::text as device_id, similarity_score
            FROM tidepools
            WHERE device_id = '\(unsafeRaw: deviceID)'::uuid
            ORDER BY similarity_score DESC
            """)).all(decoding: SimilarRow.self)

        if !rows.isEmpty {
            return rows.map { (id: $0.device_id, similarity: $0.similarity_score) }
        }

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

        return fallback.map { (id: $0.device_id, similarity: $0.similarity_score) }
    }

    private struct SimilarRow: Decodable {
        let device_id: String
        let similarity_score: Float
    }

    private struct WeightedVisitRow: Decodable {
        let device_id: String
        let latitude: Double
        let longitude: Double
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
