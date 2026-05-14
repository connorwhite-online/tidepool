import Vapor
import Fluent
import SQLKit
import TidepoolShared

struct ProfileController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        routes.put("vector", use: uploadVector)
        routes.get("vector", use: getVector)
        routes.put("vectors", use: uploadMultiVectors)
    }

    // MARK: - Raw SQL row for reading pgvector columns

    private struct ProfileRow: Decodable {
        let interest_vector: String
        let vector_version: Int
        let quality: String
        let active_sources: [String]
        let updated_at: Date
    }

    /// Upload or update the device's interest vector.
    func uploadVector(req: Request) async throws -> Response {
        let payload = try req.auth.require(DevicePayload.self)
        let body = try req.content.decode(ProfileVectorRequest.self)

        guard body.vector.count == InterestVocabulary.dimensions else {
            throw Abort(.badRequest, reason: "Vector must have \(InterestVocabulary.dimensions) dimensions, got \(body.vector.count)")
        }

        guard let sql = req.db as? SQLDatabase else {
            throw Abort(.internalServerError, reason: "SQL database required")
        }

        let vectorStr = DeviceProfile.vectorToString(body.vector)
        let deviceIDStr = payload.deviceID.uuidString
        let sourcesStr = "{" + body.activeSources.joined(separator: ",") + "}"

        // Upsert: insert or update on conflict
        try await sql.raw(SQLQueryString("""
            INSERT INTO device_profiles (id, device_id, interest_vector, quality, active_sources, updated_at)
            VALUES (gen_random_uuid(), '\(unsafeRaw: deviceIDStr)'::uuid, '\(unsafeRaw: vectorStr)'::vector, \(bind: body.quality), '\(unsafeRaw: sourcesStr)'::text[], now())
            ON CONFLICT (device_id)
            DO UPDATE SET
                interest_vector = '\(unsafeRaw: vectorStr)'::vector,
                quality = \(bind: body.quality),
                active_sources = '\(unsafeRaw: sourcesStr)'::text[],
                vector_version = device_profiles.vector_version + 1,
                tidepool_computed_at = NULL,
                updated_at = now()
            """)).run()

        // The interest vector just changed — drop the cached similar-users
        // list so the next aligned-heat/recommendation request rebuilds
        // against the new profile instead of serving from the stale snapshot.
        await SimilarUsersCache.invalidate(deviceID: deviceIDStr, redis: req.redis)

        // Fetch via raw SQL to get the vector as text
        let rows = try await sql.raw(SQLQueryString("""
            SELECT interest_vector::text as interest_vector, vector_version, quality, active_sources, updated_at
            FROM device_profiles WHERE device_id = '\(unsafeRaw: deviceIDStr)'::uuid
            """)).all(decoding: ProfileRow.self)

        guard let row = rows.first else {
            throw Abort(.internalServerError, reason: "Failed to retrieve profile after upsert")
        }

        let response = ProfileVectorResponse(
            vector: DeviceProfile.stringToVector(row.interest_vector),
            vectorVersion: row.vector_version,
            quality: row.quality,
            updatedAt: iso8601Formatter.string(from: row.updated_at)
        )
        return try await response.encodeResponse(for: req)
    }

    /// Get the device's current interest vector.
    func getVector(req: Request) async throws -> Response {
        let payload = try req.auth.require(DevicePayload.self)

        guard let sql = req.db as? SQLDatabase else {
            throw Abort(.internalServerError, reason: "SQL database required")
        }

        let deviceIDStr = payload.deviceID.uuidString
        let rows = try await sql.raw(SQLQueryString("""
            SELECT interest_vector::text as interest_vector, vector_version, quality, active_sources, updated_at
            FROM device_profiles WHERE device_id = '\(unsafeRaw: deviceIDStr)'::uuid
            """)).all(decoding: ProfileRow.self)

        guard let row = rows.first else {
            throw Abort(.notFound, reason: "No profile found for this device")
        }

        let response = ProfileVectorResponse(
            vector: DeviceProfile.stringToVector(row.interest_vector),
            vectorVersion: row.vector_version,
            quality: row.quality,
            updatedAt: iso8601Formatter.string(from: row.updated_at)
        )
        return try await response.encodeResponse(for: req)
    }

    // MARK: - Multi-Vector Upload

    /// Upload music, places, and vibe vectors. Maps raw tokens to global vocabulary dimensions.
    func uploadMultiVectors(req: Request) async throws -> Response {
        let payload = try req.auth.require(DevicePayload.self)
        let body = try req.content.decode(MultiVectorRequest.self)

        guard let sql = req.db as? SQLDatabase else {
            throw Abort(.internalServerError, reason: "SQL database required")
        }

        let deviceIDStr = payload.deviceID.uuidString

        // Build music vector from raw genre strings
        let musicVector = try await buildVector(
            tokens: body.musicGenres, vectorType: "music", maxDims: 512, sql: sql
        )

        // Build places vector from POI IDs
        let placesVector = try await buildVector(
            tokens: body.placePois, vectorType: "places", maxDims: 512, sql: sql
        )

        // Vibe vector is already 130-dim
        guard body.vibeVector.count == InterestVocabulary.dimensions else {
            throw Abort(.badRequest, reason: "Vibe vector must have \(InterestVocabulary.dimensions) dimensions")
        }

        let musicStr = DeviceProfile.vectorToString(musicVector)
        let placesStr = DeviceProfile.vectorToString(placesVector)
        let vibeStr = DeviceProfile.vectorToString(body.vibeVector)
        let interestStr = DeviceProfile.vectorToString(body.vibeVector) // also update legacy column
        let sourcesStr = "{" + body.activeSources.joined(separator: ",") + "}"

        try await sql.raw(SQLQueryString("""
            INSERT INTO device_profiles (id, device_id, interest_vector, music_vector, places_vector, vibe_vector, quality, active_sources, updated_at)
            VALUES (gen_random_uuid(), '\(unsafeRaw: deviceIDStr)'::uuid,
                    '\(unsafeRaw: interestStr)'::vector,
                    '\(unsafeRaw: musicStr)'::vector,
                    '\(unsafeRaw: placesStr)'::vector,
                    '\(unsafeRaw: vibeStr)'::vector,
                    \(bind: body.quality), '\(unsafeRaw: sourcesStr)'::text[], now())
            ON CONFLICT (device_id)
            DO UPDATE SET
                interest_vector = '\(unsafeRaw: interestStr)'::vector,
                music_vector = '\(unsafeRaw: musicStr)'::vector,
                places_vector = '\(unsafeRaw: placesStr)'::vector,
                vibe_vector = '\(unsafeRaw: vibeStr)'::vector,
                quality = \(bind: body.quality),
                active_sources = '\(unsafeRaw: sourcesStr)'::text[],
                vector_version = device_profiles.vector_version + 1,
                tidepool_computed_at = NULL,
                updated_at = now()
            """)).run()

        // Invalidate cached similar-users — the user's vectors just changed.
        await SimilarUsersCache.invalidate(deviceID: deviceIDStr, redis: req.redis)

        let rows = try await sql.raw(SQLQueryString("""
            SELECT interest_vector::text as interest_vector, vector_version, quality, active_sources, updated_at
            FROM device_profiles WHERE device_id = '\(unsafeRaw: deviceIDStr)'::uuid
            """)).all(decoding: ProfileRow.self)

        guard let row = rows.first else {
            throw Abort(.internalServerError, reason: "Failed to retrieve profile after upsert")
        }

        let response = ProfileVectorResponse(
            vector: DeviceProfile.stringToVector(row.interest_vector),
            vectorVersion: row.vector_version,
            quality: row.quality,
            updatedAt: iso8601Formatter.string(from: row.updated_at)
        )
        return try await response.encodeResponse(for: req)
    }

    /// Map raw token→weight pairs to a fixed-size vector using the global vocabulary table.
    /// Bulk-fetches existing mappings, bumps usage counts in one statement,
    /// and bulk-inserts any new tokens in a single statement.
    private func buildVector(tokens: [String: Float], vectorType: String, maxDims: Int, sql: SQLDatabase) async throws -> [Float] {
        var vector = [Float](repeating: 0, count: maxDims)
        guard !tokens.isEmpty else { return vector }

        let tokenList = Array(tokens.keys)

        // Bulk fetch existing token→dimension mappings.
        let existingRows = try await sql.raw(SQLQueryString("""
            SELECT token, dimension_index FROM vector_vocabularies
            WHERE vector_type = \(bind: vectorType) AND token = ANY(\(bind: tokenList))
            """)).all(decoding: TokenDimRow.self)

        var tokenToDim: [String: Int] = [:]
        for row in existingRows {
            tokenToDim[row.token] = row.dimension_index
        }

        // Bump usage counts for the existing tokens in one statement.
        if !tokenToDim.isEmpty {
            try await sql.raw(SQLQueryString("""
                UPDATE vector_vocabularies SET usage_count = usage_count + 1
                WHERE vector_type = \(bind: vectorType) AND token = ANY(\(bind: Array(tokenToDim.keys)))
                """)).run()
        }

        // Assign dimension indices to new tokens and insert them all in a
        // single statement. The previous version did one INSERT per new
        // token, which was up to ~50 round-trips for a new user with a
        // rich music library or POI history.
        let newTokens = tokenList.filter { tokenToDim[$0] == nil }
        if !newTokens.isEmpty {
            let maxRows = try await sql.raw(SQLQueryString("""
                SELECT COALESCE(MAX(dimension_index), -1) as max_dim
                FROM vector_vocabularies WHERE vector_type = \(bind: vectorType)
                """)).all(decoding: MaxDimRow.self)
            var nextDim = (maxRows.first?.max_dim ?? -1) + 1

            var tokensToInsert: [String] = []
            var dimsToInsert: [Int] = []
            for token in newTokens {
                guard nextDim < maxDims else { break }
                tokenToDim[token] = nextDim
                tokensToInsert.append(token)
                dimsToInsert.append(nextDim)
                nextDim += 1
            }

            if !tokensToInsert.isEmpty {
                try await sql.raw(SQLQueryString("""
                    INSERT INTO vector_vocabularies (vector_type, token, dimension_index, usage_count)
                    SELECT \(bind: vectorType), t.token, t.dim, 1
                    FROM unnest(\(bind: tokensToInsert)::text[], \(bind: dimsToInsert)::int[]) AS t(token, dim)
                    ON CONFLICT (vector_type, token) DO NOTHING
                    """)).run()
            }
        }

        // Build vector from mappings.
        for (token, weight) in tokens {
            if let dimIndex = tokenToDim[token], dimIndex < maxDims {
                vector[dimIndex] = weight
            }
        }

        // L2 normalize.
        let magnitude = sqrt(vector.map { $0 * $0 }.reduce(0, +))
        if magnitude > 0 {
            vector = vector.map { $0 / magnitude }
        }

        return vector
    }

    private struct TokenDimRow: Decodable {
        let token: String
        let dimension_index: Int
    }

    private struct MaxDimRow: Decodable {
        let max_dim: Int
    }
}

// MARK: - Vapor Content conformance for TidepoolShared types

extension ProfileVectorRequest: @retroactive Content {}
extension ProfileVectorResponse: @retroactive Content {}
extension MultiVectorRequest: @retroactive Content {}
