import Vapor
import Fluent
import SQLKit
import TidepoolShared

struct SimilarController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        routes.get("similar", use: findSimilar)
    }

    private struct SimilarRow: Decodable {
        let device_id: UUID
        let similarity: Double
    }

    /// Find profiles with similar interest vectors using pgvector cosine similarity.
    /// Returns device IDs and similarity scores (excluding the requesting device).
    func findSimilar(req: Request) async throws -> [SimilarProfileResponse] {
        let payload = try req.auth.require(DevicePayload.self)

        guard let sql = req.db as? SQLDatabase else {
            throw Abort(.internalServerError, reason: "SQL database required")
        }

        let limit = (try? req.query.get(Int.self, at: "limit")) ?? 10
        let clampedLimit = min(max(limit, 1), 50)
        let deviceIDStr = payload.deviceID.uuidString

        // Find nearest neighbors by cosine distance, excluding self
        let rows = try await sql.raw(SQLQueryString("""
            SELECT p2.device_id,
                   1 - (p1.interest_vector <=> p2.interest_vector) AS similarity
            FROM device_profiles p1
            CROSS JOIN device_profiles p2
            WHERE p1.device_id = '\(unsafeRaw: deviceIDStr)'::uuid
              AND p2.device_id != '\(unsafeRaw: deviceIDStr)'::uuid
              AND p2.quality != 'poor'
            ORDER BY p1.interest_vector <=> p2.interest_vector
            LIMIT \(unsafeRaw: String(clampedLimit))
            """)).all(decoding: SimilarRow.self)

        return rows.map {
            SimilarProfileResponse(
                deviceID: $0.device_id.uuidString,
                similarity: Float($0.similarity)
            )
        }
    }
}

// MARK: - Response type

public struct SimilarProfileResponse: Content, Sendable {
    public let deviceID: String
    public let similarity: Float

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case similarity
    }
}
