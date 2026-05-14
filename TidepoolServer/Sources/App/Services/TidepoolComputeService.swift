import Vapor
import Fluent
import SQLKit
import TidepoolShared

/// Computes tidepools: for each user, finds all other users above a similarity threshold
/// and stores the matches in the `tidepools` table.
/// Designed to run as a nightly batch — full scan, no shortcuts.
enum TidepoolComputeService {
    /// Minimum composite similarity to be included in someone's tidepool.
    /// Generous for now — tighten as user base grows.
    static let similarityThreshold: Float = 0.15

    /// Weights for multi-vector composite similarity.
    static let placesWeight: Float = 0.5
    static let musicWeight: Float = 0.3
    static let vibeWeight: Float = 0.2

    // MARK: - Full Batch Computation

    /// Compute tidepools for ALL users. Runs nightly.
    static func computeAll(app: Application) async {
        app.logger.info("[Tidepools] Starting full batch computation...")
        let start = Date()

        guard let sql = app.db as? SQLDatabase else {
            app.logger.error("[Tidepools] SQL database required")
            return
        }

        // Load all profiles with vectors
        let profiles = try? await sql.raw(SQLQueryString("""
            SELECT device_id::text as device_id,
                   interest_vector::text as interest_vector,
                   music_vector::text as music_vector,
                   places_vector::text as places_vector,
                   vibe_vector::text as vibe_vector,
                   quality
            FROM device_profiles
            WHERE quality != 'poor'
            """)).all(decoding: ProfileVectors.self)

        guard let profiles, profiles.count > 1 else {
            app.logger.info("[Tidepools] Not enough profiles to compute (\(profiles?.count ?? 0))")
            return
        }

        app.logger.info("[Tidepools] Computing for \(profiles.count) profiles...")

        // Parse vectors and precompute magnitudes once per profile.
        // Previously each magnitude was recomputed N times in the inner loop.
        let parsed = profiles.map { PrecomputedProfile(profile: $0) }

        // Pairwise comparison — only i<j, since cosine is symmetric.
        // Each match yields two directional rows (a→b and b→a) because the
        // tidepools table stores per-viewer rows.
        var matches: [Match] = []
        matches.reserveCapacity(parsed.count * 4)

        for i in 0..<parsed.count {
            for j in (i + 1)..<parsed.count {
                let (composite, placesSim, musicSim, vibeSim) = computeSimilarity(a: parsed[i], b: parsed[j])
                guard composite >= similarityThreshold else { continue }
                matches.append(Match(deviceID: parsed[i].deviceID, matchID: parsed[j].deviceID,
                                     score: composite, places: placesSim, music: musicSim, vibe: vibeSim))
                matches.append(Match(deviceID: parsed[j].deviceID, matchID: parsed[i].deviceID,
                                     score: composite, places: placesSim, music: musicSim, vibe: vibeSim))
            }
        }

        app.logger.info("[Tidepools] Found \(matches.count) matches above threshold \(similarityThreshold)")

        // Bulk upsert in chunks. Each chunk is one INSERT ... SELECT FROM unnest
        // statement instead of one INSERT per match — at N users we went from
        // O(N²) statements down to O(N²/chunkSize).
        let chunkSize = 500
        for chunkStart in stride(from: 0, to: matches.count, by: chunkSize) {
            let chunkEnd = min(chunkStart + chunkSize, matches.count)
            let chunk = Array(matches[chunkStart..<chunkEnd])
            await upsertMatches(chunk, sql: sql, logger: app.logger)
        }

        // Clean up old matches that fell below threshold
        try? await sql.raw(SQLQueryString("""
            DELETE FROM tidepools WHERE computed_at < now() - interval '2 days'
            """)).run()

        // Mark all profiles as computed
        try? await sql.raw(SQLQueryString("""
            UPDATE device_profiles SET tidepool_computed_at = now(), tidepool_version = tidepool_version + 1
            WHERE quality != 'poor'
            """)).run()

        let elapsed = Date().timeIntervalSince(start)
        app.logger.info("[Tidepools] Batch complete: \(matches.count) matches for \(profiles.count) users in \(String(format: "%.1f", elapsed))s")
    }

    private struct Match {
        let deviceID: String
        let matchID: String
        let score: Float
        let places: Float
        let music: Float
        let vibe: Float
    }

    /// Bulk upsert a chunk of matches as a single multi-row INSERT ... SELECT
    /// driven by unnest arrays. ON CONFLICT updates similarity fields in place.
    private static func upsertMatches(_ matches: [Match], sql: SQLDatabase, logger: Logger) async {
        guard !matches.isEmpty else { return }
        let deviceIDs = matches.map { $0.deviceID }
        let matchIDs = matches.map { $0.matchID }
        let scores = matches.map { $0.score }
        let places = matches.map { $0.places }
        let musics = matches.map { $0.music }
        let vibes = matches.map { $0.vibe }
        do {
            try await sql.raw(SQLQueryString("""
                INSERT INTO tidepools (id, device_id, match_id, similarity_score, places_similarity, music_similarity, vibe_similarity, computed_at)
                SELECT gen_random_uuid(), did::uuid, mid::uuid, s, p, m, v, now()
                FROM unnest(\(bind: deviceIDs)::text[], \(bind: matchIDs)::text[],
                            \(bind: scores)::real[], \(bind: places)::real[],
                            \(bind: musics)::real[], \(bind: vibes)::real[])
                     AS t(did, mid, s, p, m, v)
                ON CONFLICT (device_id, match_id) DO UPDATE SET
                    similarity_score = EXCLUDED.similarity_score,
                    places_similarity = EXCLUDED.places_similarity,
                    music_similarity = EXCLUDED.music_similarity,
                    vibe_similarity = EXCLUDED.vibe_similarity,
                    computed_at = now()
                """)).run()
        } catch {
            logger.error("[Tidepools] bulk upsert failed: \(error)")
        }
    }

    // MARK: - Single User Recomputation

    /// Recompute tidepool for a single user (triggered when their vectors update).
    static func computeForUser(deviceID: String, app: Application) async {
        guard let sql = app.db as? SQLDatabase else { return }

        // Load this user's vectors
        let userRows = try? await sql.raw(SQLQueryString("""
            SELECT device_id::text as device_id,
                   interest_vector::text as interest_vector,
                   music_vector::text as music_vector,
                   places_vector::text as places_vector,
                   vibe_vector::text as vibe_vector,
                   quality
            FROM device_profiles WHERE device_id = '\(unsafeRaw: deviceID)'::uuid
            """)).all(decoding: ProfileVectors.self)

        guard let userProfile = userRows?.first else { return }

        // Load all other profiles
        let others = try? await sql.raw(SQLQueryString("""
            SELECT device_id::text as device_id,
                   interest_vector::text as interest_vector,
                   music_vector::text as music_vector,
                   places_vector::text as places_vector,
                   vibe_vector::text as vibe_vector,
                   quality
            FROM device_profiles
            WHERE device_id != '\(unsafeRaw: deviceID)'::uuid AND quality != 'poor'
            """)).all(decoding: ProfileVectors.self)

        guard let others else { return }

        let user = PrecomputedProfile(profile: userProfile)
        let otherProfiles = others.map { PrecomputedProfile(profile: $0) }

        var matches: [Match] = []
        matches.reserveCapacity(otherProfiles.count * 2)
        var below: [String] = []

        for b in otherProfiles {
            let (composite, placesSim, musicSim, vibeSim) = computeSimilarity(a: user, b: b)
            if composite >= similarityThreshold {
                // Both directions, as in computeAll
                matches.append(Match(deviceID: user.deviceID, matchID: b.deviceID,
                                     score: composite, places: placesSim, music: musicSim, vibe: vibeSim))
                matches.append(Match(deviceID: b.deviceID, matchID: user.deviceID,
                                     score: composite, places: placesSim, music: musicSim, vibe: vibeSim))
            } else {
                below.append(b.deviceID)
            }
        }

        await upsertMatches(matches, sql: sql, logger: app.logger)

        // Bulk-delete the now-below-threshold pairs in one statement instead
        // of one DELETE per other user.
        if !below.isEmpty {
            try? await sql.raw(SQLQueryString("""
                DELETE FROM tidepools
                WHERE (device_id = '\(unsafeRaw: deviceID)'::uuid AND match_id = ANY(\(bind: below)::uuid[]))
                   OR (match_id = '\(unsafeRaw: deviceID)'::uuid AND device_id = ANY(\(bind: below)::uuid[]))
                """)).run()
        }

        try? await sql.raw(SQLQueryString("""
            UPDATE device_profiles SET tidepool_computed_at = now(), tidepool_version = tidepool_version + 1
            WHERE device_id = '\(unsafeRaw: deviceID)'::uuid
            """)).run()

        app.logger.info("[Tidepools] Recomputed for user \(deviceID): \(matches.count / 2) matches, \(below.count) below threshold")
    }

    // MARK: - Similarity Math

    private static func computeSimilarity(a: PrecomputedProfile, b: PrecomputedProfile) -> (composite: Float, places: Float, music: Float, vibe: Float) {
        let placesSim = cosineSimilarity(a.placesVector, b.placesVector, magA: a.placesMag, magB: b.placesMag)
        let musicSim = cosineSimilarity(a.musicVector, b.musicVector, magA: a.musicMag, magB: b.musicMag)
        let vibeSim = cosineSimilarity(a.vibeVector, b.vibeVector, magA: a.vibeMag, magB: b.vibeMag)

        // If multi-vectors exist, use weighted composite
        let hasMulti = !a.placesVector.isEmpty && !b.placesVector.isEmpty
        let composite: Float
        if hasMulti {
            composite = placesWeight * placesSim + musicWeight * musicSim + vibeWeight * vibeSim
        } else {
            // Fall back to single interest vector
            composite = cosineSimilarity(a.interestVector, b.interestVector, magA: a.interestMag, magB: b.interestMag)
        }

        return (composite, placesSim, musicSim, vibeSim)
    }

    /// Cosine similarity with caller-supplied magnitudes so the same vector's
    /// magnitude isn't recomputed N times across the outer loop.
    private static func cosineSimilarity(_ a: [Float], _ b: [Float], magA: Float, magB: Float) -> Float {
        guard a.count == b.count, !a.isEmpty, magA > 0, magB > 0 else { return 0 }
        var dot: Float = 0
        for i in 0..<a.count { dot += a[i] * b[i] }
        return dot / (magA * magB)
    }

    private static func magnitude(_ v: [Float]) -> Float {
        var sum: Float = 0
        for x in v { sum += x * x }
        return sqrt(sum)
    }

    // MARK: - Data Models

    private struct ProfileVectors: Decodable {
        let device_id: String
        let interest_vector: String?
        let music_vector: String?
        let places_vector: String?
        let vibe_vector: String?
        let quality: String
    }

    private struct PrecomputedProfile {
        let deviceID: String
        let interestVector: [Float]
        let musicVector: [Float]
        let placesVector: [Float]
        let vibeVector: [Float]
        let interestMag: Float
        let musicMag: Float
        let placesMag: Float
        let vibeMag: Float

        init(profile: ProfileVectors) {
            self.deviceID = profile.device_id
            self.interestVector = profile.interest_vector.flatMap { DeviceProfile.stringToVector($0) } ?? []
            self.musicVector = profile.music_vector.flatMap { DeviceProfile.stringToVector($0) } ?? []
            self.placesVector = profile.places_vector.flatMap { DeviceProfile.stringToVector($0) } ?? []
            self.vibeVector = profile.vibe_vector.flatMap { DeviceProfile.stringToVector($0) } ?? []
            self.interestMag = TidepoolComputeService.magnitude(self.interestVector)
            self.musicMag = TidepoolComputeService.magnitude(self.musicVector)
            self.placesMag = TidepoolComputeService.magnitude(self.placesVector)
            self.vibeMag = TidepoolComputeService.magnitude(self.vibeVector)
        }
    }
}
