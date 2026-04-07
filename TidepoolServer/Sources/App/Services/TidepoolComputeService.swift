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

        // Parse vectors once
        let parsed = profiles.map { profile -> ParsedProfile in
            ParsedProfile(
                deviceID: profile.device_id,
                interestVector: profile.interest_vector.flatMap { DeviceProfile.stringToVector($0) } ?? [],
                musicVector: profile.music_vector.flatMap { DeviceProfile.stringToVector($0) } ?? [],
                placesVector: profile.places_vector.flatMap { DeviceProfile.stringToVector($0) } ?? [],
                vibeVector: profile.vibe_vector.flatMap { DeviceProfile.stringToVector($0) } ?? []
            )
        }

        // Pairwise comparison
        var allMatches: [(deviceID: String, matchID: String, score: Float, places: Float, music: Float, vibe: Float)] = []

        for i in 0..<parsed.count {
            for j in 0..<parsed.count {
                guard i != j else { continue }

                let a = parsed[i]
                let b = parsed[j]

                let (composite, placesSim, musicSim, vibeSim) = computeSimilarity(a: a, b: b)

                if composite >= similarityThreshold {
                    allMatches.append((
                        deviceID: a.deviceID,
                        matchID: b.deviceID,
                        score: composite,
                        places: placesSim,
                        music: musicSim,
                        vibe: vibeSim
                    ))
                }
            }
        }

        app.logger.info("[Tidepools] Found \(allMatches.count) matches above threshold \(similarityThreshold)")

        // Batch upsert
        let batchSize = 100
        for batchStart in stride(from: 0, to: allMatches.count, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, allMatches.count)
            let batch = allMatches[batchStart..<batchEnd]

            for match in batch {
                try? await sql.raw(SQLQueryString("""
                    INSERT INTO tidepools (id, device_id, match_id, similarity_score, places_similarity, music_similarity, vibe_similarity, computed_at)
                    VALUES (gen_random_uuid(), '\(unsafeRaw: match.deviceID)'::uuid, '\(unsafeRaw: match.matchID)'::uuid,
                            \(unsafeRaw: String(match.score)), \(unsafeRaw: String(match.places)),
                            \(unsafeRaw: String(match.music)), \(unsafeRaw: String(match.vibe)), now())
                    ON CONFLICT (device_id, match_id) DO UPDATE SET
                        similarity_score = \(unsafeRaw: String(match.score)),
                        places_similarity = \(unsafeRaw: String(match.places)),
                        music_similarity = \(unsafeRaw: String(match.music)),
                        vibe_similarity = \(unsafeRaw: String(match.vibe)),
                        computed_at = now()
                    """)).run()
            }
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
        app.logger.info("[Tidepools] Batch complete: \(allMatches.count) matches for \(profiles.count) users in \(String(format: "%.1f", elapsed))s")
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

        let user = ParsedProfile(
            deviceID: userProfile.device_id,
            interestVector: userProfile.interest_vector.flatMap { DeviceProfile.stringToVector($0) } ?? [],
            musicVector: userProfile.music_vector.flatMap { DeviceProfile.stringToVector($0) } ?? [],
            placesVector: userProfile.places_vector.flatMap { DeviceProfile.stringToVector($0) } ?? [],
            vibeVector: userProfile.vibe_vector.flatMap { DeviceProfile.stringToVector($0) } ?? []
        )

        for other in others {
            let b = ParsedProfile(
                deviceID: other.device_id,
                interestVector: other.interest_vector.flatMap { DeviceProfile.stringToVector($0) } ?? [],
                musicVector: other.music_vector.flatMap { DeviceProfile.stringToVector($0) } ?? [],
                placesVector: other.places_vector.flatMap { DeviceProfile.stringToVector($0) } ?? [],
                vibeVector: other.vibe_vector.flatMap { DeviceProfile.stringToVector($0) } ?? []
            )

            let (composite, placesSim, musicSim, vibeSim) = computeSimilarity(a: user, b: b)

            if composite >= similarityThreshold {
                try? await sql.raw(SQLQueryString("""
                    INSERT INTO tidepools (id, device_id, match_id, similarity_score, places_similarity, music_similarity, vibe_similarity, computed_at)
                    VALUES (gen_random_uuid(), '\(unsafeRaw: user.deviceID)'::uuid, '\(unsafeRaw: b.deviceID)'::uuid,
                            \(unsafeRaw: String(composite)), \(unsafeRaw: String(placesSim)),
                            \(unsafeRaw: String(musicSim)), \(unsafeRaw: String(vibeSim)), now())
                    ON CONFLICT (device_id, match_id) DO UPDATE SET
                        similarity_score = \(unsafeRaw: String(composite)),
                        places_similarity = \(unsafeRaw: String(placesSim)),
                        music_similarity = \(unsafeRaw: String(musicSim)),
                        vibe_similarity = \(unsafeRaw: String(vibeSim)),
                        computed_at = now()
                    """)).run()
            } else {
                // Remove if below threshold
                try? await sql.raw(SQLQueryString("""
                    DELETE FROM tidepools WHERE device_id = '\(unsafeRaw: user.deviceID)'::uuid AND match_id = '\(unsafeRaw: b.deviceID)'::uuid
                    """)).run()
            }
        }

        try? await sql.raw(SQLQueryString("""
            UPDATE device_profiles SET tidepool_computed_at = now(), tidepool_version = tidepool_version + 1
            WHERE device_id = '\(unsafeRaw: deviceID)'::uuid
            """)).run()

        app.logger.info("[Tidepools] Recomputed for user \(deviceID)")
    }

    // MARK: - Similarity Math

    private static func computeSimilarity(a: ParsedProfile, b: ParsedProfile) -> (composite: Float, places: Float, music: Float, vibe: Float) {
        let placesSim = cosineSimilarity(a.placesVector, b.placesVector)
        let musicSim = cosineSimilarity(a.musicVector, b.musicVector)
        let vibeSim = cosineSimilarity(a.vibeVector, b.vibeVector)

        // If multi-vectors exist, use weighted composite
        let hasMulti = !a.placesVector.isEmpty && !b.placesVector.isEmpty
        let composite: Float
        if hasMulti {
            composite = placesWeight * placesSim + musicWeight * musicSim + vibeWeight * vibeSim
        } else {
            // Fall back to single interest vector
            composite = cosineSimilarity(a.interestVector, b.interestVector)
        }

        return (composite, placesSim, musicSim, vibeSim)
    }

    private static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        let dot = zip(a, b).reduce(Float(0)) { $0 + $1.0 * $1.1 }
        let magA = sqrt(a.reduce(Float(0)) { $0 + $1 * $1 })
        let magB = sqrt(b.reduce(Float(0)) { $0 + $1 * $1 })
        guard magA > 0, magB > 0 else { return 0 }
        return dot / (magA * magB)
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

    private struct ParsedProfile {
        let deviceID: String
        let interestVector: [Float]
        let musicVector: [Float]
        let placesVector: [Float]
        let vibeVector: [Float]
    }
}
