import Vapor
@preconcurrency import Redis
import TidepoolShared

struct HeatTileController: RouteCollection {
    /// Minimum number of unique contributors before a tile is revealed (k-anonymity)
    private let kMin = 2
    /// Laplace noise parameter (smaller = more noise)
    private let epsilon: Float = 0.5
    /// TTL reported to clients so they know when to re-fetch
    private let ttlSeconds = 1800 // matches presence TTL

    func boot(routes: RoutesBuilder) throws {
        routes.post("heat", use: heatTiles)
    }

    /// Return heat tiles for the requested viewport, gated by k-anonymity with Laplace noise.
    func heatTiles(req: Request) async throws -> HeatTileResponse {
        let body = try req.content.decode(HeatTileRequest.self)

        // Enumerate tiles in viewport
        let tiles = GridTiler.tilesInBounds(sw: body.viewport.sw, ne: body.viewport.ne)

        // Cap tile count to prevent abuse on huge viewports
        let maxTiles = 500
        guard tiles.count <= maxTiles else {
            throw Abort(.badRequest, reason: "Viewport too large: \(tiles.count) tiles exceeds max \(maxTiles)")
        }

        // Pipeline all ZCARD commands in a single Redis round trip
        var zcardArgs: [RESPValue] = []
        for tile in tiles {
            zcardArgs.append(.init(from: "ZCARD"))
            zcardArgs.append(.init(from: "presence:\(tile.description)"))
        }

        let counts: [Int]
        if tiles.isEmpty {
            counts = []
        } else {
            // Use PIPELINE via individual sends wrapped in a concurrent group
            counts = try await withThrowingTaskGroup(of: (Int, Int).self) { group in
                for (i, tile) in tiles.enumerated() {
                    let key = "presence:\(tile.description)"
                    group.addTask {
                        let resp = try await req.redis.send(command: "ZCARD", with: [
                            .init(from: key)
                        ]).get()
                        return (i, resp.int ?? 0)
                    }
                }
                var result = [Int](repeating: 0, count: tiles.count)
                for try await (i, count) in group {
                    result[i] = count
                }
                return result
            }
        }

        var heatTiles: [HeatTile] = []

        for (i, tile) in tiles.enumerated() {
            let count = counts[i]

            // k-anonymity: only include tiles with enough contributors
            guard count >= kMin else { continue }

            // Add Laplace noise to the count for differential privacy
            let noisyCount = Float(count) + laplace(epsilon: epsilon)
            // Clamp to at least kMin (don't reveal sub-threshold after noise)
            let clampedCount = max(Float(kMin), noisyCount)

            // Intensity: normalize to 0...1 range (soft cap at 50 contributors)
            let intensity = min(1.0, clampedCount / 50.0)

            heatTiles.append(HeatTile(
                tileID: tile.description,
                intensity: intensity,
                contributorCount: Int(clampedCount)
            ))
        }

        let meta = HeatTileMeta(kMin: kMin, epsilon: epsilon, ttlSeconds: ttlSeconds)
        return HeatTileResponse(tiles: heatTiles, meta: meta)
    }

    // MARK: - Laplace Noise

    /// Generate a sample from the Laplace distribution with location 0 and scale 1/epsilon.
    private func laplace(epsilon: Float) -> Float {
        let scale = 1.0 / epsilon
        let u = Float.random(in: -0.5..<0.5)
        // Laplace via inverse CDF: -scale * sign(u) * ln(1 - 2|u|)
        return -scale * (u > 0 ? 1 : -1) * log(1.0 - 2.0 * abs(u))
    }
}

// MARK: - Vapor Content conformance

extension HeatTileRequest: @retroactive Content {}
extension HeatTileResponse: @retroactive Content {}
