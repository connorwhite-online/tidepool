import Fluent
import Vapor
import SQLKit

struct CreateVisits: AsyncMigration {
    func prepare(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else {
            throw Abort(.internalServerError, reason: "SQL database required")
        }

        try await sql.raw("""
            CREATE TABLE visits (
                id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
                device_id UUID NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
                poi_id TEXT,
                yelp_id TEXT,
                name TEXT NOT NULL,
                category TEXT NOT NULL,
                latitude DOUBLE PRECISION NOT NULL,
                longitude DOUBLE PRECISION NOT NULL,
                arrived_at TIMESTAMPTZ NOT NULL,
                departed_at TIMESTAMPTZ NOT NULL,
                day_of_week SMALLINT NOT NULL,
                hour_of_day SMALLINT NOT NULL,
                duration_minutes INT NOT NULL,
                confidence REAL NOT NULL DEFAULT 1.0,
                source TEXT NOT NULL DEFAULT 'visit',
                created_at TIMESTAMPTZ NOT NULL DEFAULT now()
            )
            """).run()

        try await sql.raw("CREATE INDEX idx_visits_device ON visits(device_id)").run()
        try await sql.raw("CREATE INDEX idx_visits_poi ON visits(poi_id) WHERE poi_id IS NOT NULL").run()
        try await sql.raw("CREATE INDEX idx_visits_time ON visits(device_id, day_of_week, hour_of_day)").run()
        try await sql.raw("CREATE INDEX idx_visits_device_poi ON visits(device_id, poi_id)").run()
    }

    func revert(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else { return }
        try await sql.raw("DROP TABLE IF EXISTS visits").run()
    }
}
