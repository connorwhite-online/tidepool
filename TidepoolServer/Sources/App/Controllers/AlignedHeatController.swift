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
        let similarDeviceIDs = try await getSimilarUsers(deviceID: deviceIDStr, sql: sql, req: req)

        guard !similarDeviceIDs.isEmpty else {
            let meta = HeatTileMeta(kMin: kMin, epsilon: epsilon, ttlSeconds: 900)
            return HeatTileResponse(tiles: [], meta: meta)
        }

        // Query visits for similar users filtered by time
        let deviceList = similarDeviceIDs.map { "'\($0)'::uuid" }.joined(separator: ",")
        let hourLow = (body.currentHour - 2 + 24) % 24
        let hourHigh = (body.currentHour + 2) % 24

        let hourFilter: String
        if hourLow < hourHigh {
            hourFilter = "hour_of_day BETWEEN \(hourLow) AND \(hourHigh)"
        } else {
            hourFilter = "(hour_of_day >= \(hourLow) OR hour_of_day <= \(hourHigh))"
        }

        let visitRows = try await sql.raw(SQLQueryString("""
            SELECT latitude, longitude, COUNT(DISTINCT device_id) as contributor_count
            FROM visits
            WHERE device_id IN (\(unsafeRaw: deviceList))
              AND (day_of_week = \(unsafeRaw: String(body.currentDayOfWeek))
                   OR day_of_week = \(unsafeRaw: String((body.currentDayOfWeek + 6) % 7))
                   OR day_of_week = \(unsafeRaw: String((body.currentDayOfWeek + 1) % 7)))
              AND \(unsafeRaw: hourFilter)
            GROUP BY latitude, longitude
            """)).all(decoding: VisitHeatRow.self)

        // Snap to tiles and aggregate
        var tileCounts: [String: Int] = [:]
        for row in visitRows {
            let coord = Coordinate(latitude: row.latitude, longitude: row.longitude)
            let tileID = GridTiler.tileID(for: coord)
            tileCounts[tileID.description, default: 0] += row.contributor_count
        }

        // Filter by viewport
        let viewportTiles = Set(
            GridTiler.tilesInBounds(sw: body.viewport.sw, ne: body.viewport.ne)
                .map { $0.description }
        )

        var heatTiles: [HeatTile] = []
        for (tileStr, count) in tileCounts where viewportTiles.contains(tileStr) {
            guard count >= kMin else { continue }

            let noisyCount = Float(count) + laplace(epsilon: epsilon)
            let clampedCount = max(Float(kMin), noisyCount)
            let intensity = min(1.0, clampedCount / 20.0) // lower cap than live presence

            heatTiles.append(HeatTile(
                tileID: tileStr,
                intensity: intensity,
                contributorCount: Int(clampedCount)
            ))
        }

        let meta = HeatTileMeta(kMin: kMin, epsilon: epsilon, ttlSeconds: 900)
        return HeatTileResponse(tiles: heatTiles, meta: meta)
    }

    // MARK: - Similar Users

    private func getSimilarUsers(deviceID: String, sql: SQLDatabase, req: Request) async throws -> [String] {
        // Check Redis cache
        let cacheKey = RedisKey("aligned:\(deviceID)")
        let cached = try? await req.redis.send(command: "SMEMBERS", with: [
            .init(from: cacheKey.rawValue)
        ]).get()

        if let cached, let members = cached.array, !members.isEmpty {
            return members.compactMap { $0.string }
        }

        // Compute: weighted multi-vector similarity
        // Try multi-vector first, fall back to single vector
        let rows = try await sql.raw(SQLQueryString("""
            SELECT p2.device_id::text as device_id
            FROM device_profiles p1
            CROSS JOIN device_profiles p2
            WHERE p1.device_id = '\(unsafeRaw: deviceID)'::uuid
              AND p2.device_id != '\(unsafeRaw: deviceID)'::uuid
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

        let ids = rows.map { $0.device_id }

        // Cache in Redis for 15 min
        if !ids.isEmpty {
            for id in ids {
                _ = try? await req.redis.send(command: "SADD", with: [
                    .init(from: cacheKey.rawValue),
                    .init(from: id)
                ]).get()
            }
            _ = try? await req.redis.send(command: "EXPIRE", with: [
                .init(from: cacheKey.rawValue),
                .init(from: "900")
            ]).get()
        }

        return ids
    }

    private struct DeviceIDRow: Decodable { let device_id: String }
    private struct VisitHeatRow: Decodable {
        let latitude: Double
        let longitude: Double
        let contributor_count: Int
    }

    private func laplace(epsilon: Float) -> Float {
        let scale = 1.0 / epsilon
        let u = Float.random(in: -0.5..<0.5)
        return -scale * (u > 0 ? 1 : -1) * log(1.0 - 2.0 * abs(u))
    }
}

extension AlignedHeatRequest: @retroactive Content {}
