import Fluent
import Vapor
import SQLKit

struct CreateTidepools: AsyncMigration {
    func prepare(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else {
            throw Abort(.internalServerError, reason: "SQL database required")
        }

        try await sql.raw("""
            CREATE TABLE tidepools (
                id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
                device_id UUID NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
                match_id UUID NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
                similarity_score REAL NOT NULL,
                places_similarity REAL,
                music_similarity REAL,
                vibe_similarity REAL,
                computed_at TIMESTAMPTZ NOT NULL DEFAULT now(),
                UNIQUE(device_id, match_id)
            )
            """).run()

        try await sql.raw("CREATE INDEX idx_tp_device_score ON tidepools(device_id, similarity_score DESC)").run()
        try await sql.raw("CREATE INDEX idx_tp_match ON tidepools(match_id)").run()
        try await sql.raw("CREATE INDEX idx_tp_computed ON tidepools(computed_at)").run()

        // Track when each user's tidepool was last computed
        try await sql.raw("ALTER TABLE device_profiles ADD COLUMN tidepool_computed_at TIMESTAMPTZ").run()
        try await sql.raw("ALTER TABLE device_profiles ADD COLUMN tidepool_version INT NOT NULL DEFAULT 0").run()
    }

    func revert(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else { return }
        try await sql.raw("DROP TABLE IF EXISTS tidepools").run()
        try await sql.raw("ALTER TABLE device_profiles DROP COLUMN IF EXISTS tidepool_computed_at").run()
        try await sql.raw("ALTER TABLE device_profiles DROP COLUMN IF EXISTS tidepool_version").run()
    }
}
