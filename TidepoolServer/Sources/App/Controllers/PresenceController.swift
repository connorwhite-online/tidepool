import Vapor
@preconcurrency import Redis
import TidepoolShared

struct PresenceController: RouteCollection {
    /// TTL for presence entries in Redis (30 minutes)
    private let presenceTTLSeconds = 1800

    func boot(routes: RoutesBuilder) throws {
        routes.post("report", use: report)
    }

    /// Accept a presence report and store device in the tile's Redis sorted set.
    func report(req: Request) async throws -> PresenceResponse {
        let payload = try req.auth.require(DevicePayload.self)
        let body = try req.content.decode(PresenceReport.self)

        let redisKey = RedisKey("presence:\(body.tileID)")
        let score = Double(body.epochMs)
        let member = payload.deviceID.uuidString

        // ZADD tile sorted set: score = epoch_ms, member = device_id
        _ = try await req.redis.send(command: "ZADD", with: [
            .init(from: redisKey.rawValue),
            .init(from: String(score)),
            .init(from: member)
        ]).get()

        // Set TTL on the key (resets on each write so active tiles stay alive)
        _ = try await req.redis.send(command: "EXPIRE", with: [
            .init(from: redisKey.rawValue),
            .init(from: String(presenceTTLSeconds))
        ]).get()

        // Probabilistic pruning: only clean up ~10% of requests to reduce Redis load
        if Int.random(in: 0..<10) == 0 {
            let cutoff = Double(Date().timeIntervalSince1970 * 1000) - Double(presenceTTLSeconds * 1000)
            _ = try await req.redis.send(command: "ZREMRANGEBYSCORE", with: [
                .init(from: redisKey.rawValue),
                .init(from: "0"),
                .init(from: String(cutoff))
            ]).get()
        }

        return PresenceResponse(accepted: true)
    }
}

// MARK: - Vapor Content conformance

extension PresenceReport: @retroactive Content {}
extension PresenceResponse: @retroactive Content {}
