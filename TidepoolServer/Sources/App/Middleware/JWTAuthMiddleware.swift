import Vapor
import JWT
@preconcurrency import Redis

/// JWT payload identifying an authenticated device.
struct DevicePayload: JWTPayload, Authenticatable {
    var sub: SubjectClaim    // device UUID
    var iat: IssuedAtClaim
    var exp: ExpirationClaim

    func verify(using signer: JWTSigner) throws {
        try exp.verifyNotExpired()
    }

    var deviceID: UUID {
        UUID(uuidString: sub.value)!
    }
}

/// Middleware that validates the Bearer JWT and sets the authenticated DevicePayload.
/// Optimized: caches ban status in Redis, throttles last_seen DB writes to every 5 minutes.
struct JWTAuthMiddleware: AsyncMiddleware {
    private let lastSeenThresholdSeconds: TimeInterval = 300 // 5 minutes

    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        let payload = try request.jwt.verify(as: DevicePayload.self)
        let deviceIDStr = payload.deviceID.uuidString

        // Check ban status from Redis cache first
        let banKey = RedisKey("ban:\(deviceIDStr)")
        let cachedBan = try? await request.redis.get(banKey, as: String.self).get()

        if let cachedBan {
            // Cache hit
            if cachedBan == "1" {
                throw Abort(.forbidden, reason: "Device is banned")
            }
            // cachedBan == "0" means not banned, skip DB lookup
        } else {
            // Cache miss — check DB and populate cache
            guard let device = try await Device.find(payload.deviceID, on: request.db) else {
                throw Abort(.unauthorized, reason: "Device not found")
            }
            if device.isBanned {
                // Cache ban status for 1 hour
                _ = try? await request.redis.set(banKey, to: "1").get()
                _ = try? await request.redis.send(command: "EXPIRE", with: [
                    .init(from: banKey.rawValue), .init(from: "3600")
                ]).get()
                throw Abort(.forbidden, reason: "Device is banned")
            }
            // Cache not-banned for 10 minutes
            _ = try? await request.redis.set(banKey, to: "0").get()
            _ = try? await request.redis.send(command: "EXPIRE", with: [
                .init(from: banKey.rawValue), .init(from: "600")
            ]).get()
        }

        // Throttle last_seen updates: only write to DB if >5 minutes since last update
        let lastSeenKey = RedisKey("last_seen:\(deviceIDStr)")
        let lastSeenStr = try? await request.redis.get(lastSeenKey, as: String.self).get()
        let now = Date()

        let shouldUpdate: Bool
        if let lastSeenStr, let lastSeenTs = Double(lastSeenStr) {
            shouldUpdate = now.timeIntervalSince1970 - lastSeenTs > lastSeenThresholdSeconds
        } else {
            shouldUpdate = true
        }

        if shouldUpdate {
            // Fire-and-forget DB write — don't block the request
            let deviceID = payload.deviceID
            let db = request.db
            Task {
                if let device = try? await Device.find(deviceID, on: db) {
                    device.lastSeenAt = now
                    try? await device.save(on: db)
                }
            }
            _ = try? await request.redis.set(lastSeenKey, to: String(now.timeIntervalSince1970)).get()
            _ = try? await request.redis.send(command: "EXPIRE", with: [
                .init(from: lastSeenKey.rawValue), .init(from: "600")
            ]).get()
        }

        // Store payload in request auth
        request.auth.login(payload)

        return try await next.respond(to: request)
    }
}
