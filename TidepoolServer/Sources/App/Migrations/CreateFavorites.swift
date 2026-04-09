import Fluent
import Vapor
import SQLKit

struct CreateFavorites: AsyncMigration {
    func prepare(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else {
            throw Abort(.internalServerError, reason: "SQL database required")
        }

        try await sql.raw("""
            CREATE TABLE favorites (
                id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
                device_id UUID NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
                place_id TEXT NOT NULL,
                yelp_id TEXT,
                name TEXT NOT NULL,
                category TEXT NOT NULL,
                latitude DOUBLE PRECISION NOT NULL,
                longitude DOUBLE PRECISION NOT NULL,
                rating INT,
                created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
                UNIQUE(device_id, place_id)
            )
            """).run()

        try await sql.raw("""
            CREATE INDEX idx_favorites_device_id ON favorites (device_id)
            """).run()
    }

    func revert(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else { return }
        try await sql.raw("DROP TABLE IF EXISTS favorites").run()
    }
}
