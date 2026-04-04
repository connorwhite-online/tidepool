import Fluent
import Vapor
import SQLKit

struct CreateDeviceProfiles: AsyncMigration {
    func prepare(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else {
            throw Abort(.internalServerError, reason: "SQL database required")
        }

        // Create the table with a pgvector column (not expressible via Fluent schema builder)
        try await sql.raw("""
            CREATE TABLE device_profiles (
                id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
                device_id UUID NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
                interest_vector vector(130) NOT NULL,
                vector_version INT NOT NULL DEFAULT 1,
                quality TEXT NOT NULL DEFAULT 'poor',
                active_sources TEXT[] NOT NULL DEFAULT '{}',
                updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
                UNIQUE(device_id)
            )
            """).run()

        // HNSW index for fast nearest-neighbor queries
        try await sql.raw("""
            CREATE INDEX idx_device_profiles_vector
            ON device_profiles USING hnsw (interest_vector vector_cosine_ops)
            """).run()
    }

    func revert(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else { return }
        try await sql.raw("DROP TABLE IF EXISTS device_profiles").run()
    }
}
