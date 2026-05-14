import Vapor
import Fluent
import SQLKit
@preconcurrency import Redis

/// Cached "users similar to me" list shared by the aligned-heat and
/// recommendation endpoints. Both queries used to compute this themselves on
/// every request (and the recommendation path used a Redis key that nothing
/// ever wrote to, so it always fell through to the heavy CROSS JOIN).
///
/// Invalidation: ProfileController calls `invalidate(deviceID:)` whenever the
/// user uploads a fresh vector so similar-users data isn't served from a
/// stale snapshot.
enum SimilarUsersCache {
    /// 15 minutes — matches the heat tile TTL the client uses. The next
    /// nightly tidepool batch (or a vector upload by the requesting user)
    /// invalidates earlier.
    static let ttlSeconds = 900

    struct Entry: Codable {
        let id: String
        let similarity: Float
    }

    /// Read from Redis, or fall back to the live query + populate the cache.
    /// If the user has precomputed tidepool matches, those are preferred;
    /// otherwise we compute via pgvector inline (used for new users with no
    /// nightly batch result yet).
    static func load(deviceID: String, sql: SQLDatabase, redis: RedisClient, logger: Logger) async throws -> [Entry] {
        let cacheKey = key(for: deviceID)
        if let cached = try? await redis.get(RedisKey(cacheKey), asJSON: [Entry].self) {
            return cached
        }

        let entries = try await computeSimilar(deviceID: deviceID, sql: sql, logger: logger)
        await write(entries, key: cacheKey, redis: redis)
        return entries
    }

    /// Drop the cached list for a device. Called when their vectors change so
    /// the next request recomputes against the new profile.
    static func invalidate(deviceID: String, redis: RedisClient) async {
        _ = try? await redis.delete(RedisKey(key(for: deviceID))).get()
    }

    // MARK: - Internals

    private static func key(for deviceID: String) -> String {
        "aligned_sim:\(deviceID)"
    }

    private static func computeSimilar(deviceID: String, sql: SQLDatabase, logger: Logger) async throws -> [Entry] {
        // Prefer the precomputed tidepools table; fall back to a live
        // pgvector composite distance for users who haven't been batched yet.
        let precomputed = try await sql.raw(SQLQueryString("""
            SELECT match_id::text as device_id, similarity_score
            FROM tidepools
            WHERE device_id = '\(unsafeRaw: deviceID)'::uuid
            ORDER BY similarity_score DESC
            """)).all(decoding: PrecomputedRow.self)

        if !precomputed.isEmpty {
            return precomputed.map { Entry(id: $0.device_id, similarity: $0.similarity_score) }
        }

        logger.info("[SimilarUsersCache] No precomputed tidepool for \(deviceID), using inline pgvector")
        let inline = try await sql.raw(SQLQueryString("""
            SELECT p2.device_id::text as device_id,
                   CASE
                       WHEN p1.places_vector IS NOT NULL AND p2.places_vector IS NOT NULL
                       THEN 1.0 - (0.5 * (p1.places_vector <=> p2.places_vector)
                                   + 0.3 * COALESCE(p1.music_vector <=> p2.music_vector, 1)
                                   + 0.2 * COALESCE(p1.vibe_vector <=> p2.vibe_vector, 1))
                       ELSE 1.0 - (p1.interest_vector <=> p2.interest_vector)
                   END as similarity
            FROM device_profiles p1
            CROSS JOIN device_profiles p2
            WHERE p1.device_id = '\(unsafeRaw: deviceID)'::uuid
              AND p2.device_id != '\(unsafeRaw: deviceID)'::uuid
              AND p2.quality != 'poor'
            ORDER BY similarity DESC
            LIMIT 100
            """)).all(decoding: InlineRow.self)

        return inline.map { Entry(id: $0.device_id, similarity: Float($0.similarity)) }
    }

    private static func write(_ entries: [Entry], key: String, redis: RedisClient) async {
        guard !entries.isEmpty,
              let data = try? JSONEncoder().encode(entries),
              let json = String(data: data, encoding: .utf8) else { return }
        // Atomic SET ... EX — separate SET + EXPIRE could leak a TTL-less key.
        _ = try? await redis.send(command: "SET", with: [
            .init(from: key),
            .init(from: json),
            .init(from: "EX"),
            .init(from: String(ttlSeconds))
        ]).get()
    }

    private struct PrecomputedRow: Decodable {
        let device_id: String
        let similarity_score: Float
    }

    private struct InlineRow: Decodable {
        let device_id: String
        let similarity: Double
    }
}
