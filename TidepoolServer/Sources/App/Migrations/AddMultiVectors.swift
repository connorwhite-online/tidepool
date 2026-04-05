import Fluent
import Vapor
import SQLKit

struct AddMultiVectors: AsyncMigration {
    func prepare(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else {
            throw Abort(.internalServerError, reason: "SQL database required")
        }

        // Global vocabulary table: maps tokens to dimension indices per vector type
        try await sql.raw("""
            CREATE TABLE vector_vocabularies (
                id SERIAL PRIMARY KEY,
                vector_type TEXT NOT NULL,
                token TEXT NOT NULL,
                dimension_index INT NOT NULL,
                usage_count INT NOT NULL DEFAULT 1,
                created_at TIMESTAMPTZ DEFAULT now(),
                UNIQUE(vector_type, token),
                UNIQUE(vector_type, dimension_index)
            )
            """).run()

        // New vector columns on device_profiles
        try await sql.raw("ALTER TABLE device_profiles ADD COLUMN music_vector vector(512)").run()
        try await sql.raw("ALTER TABLE device_profiles ADD COLUMN places_vector vector(512)").run()
        try await sql.raw("ALTER TABLE device_profiles ADD COLUMN vibe_vector vector(130)").run()

        // Seed vibe_vector from existing interest_vector
        try await sql.raw("UPDATE device_profiles SET vibe_vector = interest_vector").run()

        // HNSW indexes per vector type
        try await sql.raw("""
            CREATE INDEX idx_dp_music ON device_profiles
            USING hnsw (music_vector vector_cosine_ops) WHERE music_vector IS NOT NULL
            """).run()
        try await sql.raw("""
            CREATE INDEX idx_dp_places ON device_profiles
            USING hnsw (places_vector vector_cosine_ops) WHERE places_vector IS NOT NULL
            """).run()
        try await sql.raw("""
            CREATE INDEX idx_dp_vibe ON device_profiles
            USING hnsw (vibe_vector vector_cosine_ops) WHERE vibe_vector IS NOT NULL
            """).run()
    }

    func revert(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else { return }
        try await sql.raw("ALTER TABLE device_profiles DROP COLUMN IF EXISTS music_vector").run()
        try await sql.raw("ALTER TABLE device_profiles DROP COLUMN IF EXISTS places_vector").run()
        try await sql.raw("ALTER TABLE device_profiles DROP COLUMN IF EXISTS vibe_vector").run()
        try await sql.raw("DROP TABLE IF EXISTS vector_vocabularies").run()
    }
}
