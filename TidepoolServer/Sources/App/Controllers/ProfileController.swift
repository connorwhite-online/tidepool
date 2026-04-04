import Vapor
import Fluent
import SQLKit
import TidepoolShared

struct ProfileController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        routes.put("vector", use: uploadVector)
        routes.get("vector", use: getVector)
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
                updated_at = now()
            """)).run()

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
            updatedAt: ISO8601DateFormatter().string(from: row.updated_at)
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
            updatedAt: ISO8601DateFormatter().string(from: row.updated_at)
        )
        return try await response.encodeResponse(for: req)
    }
}

// MARK: - Vapor Content conformance for TidepoolShared types

extension ProfileVectorRequest: @retroactive Content {}
extension ProfileVectorResponse: @retroactive Content {}
