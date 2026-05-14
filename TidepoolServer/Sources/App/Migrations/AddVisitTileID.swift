import Fluent
import Vapor
import SQLKit

/// Adds a generated tile_id column to visits so aligned-heat aggregation
/// can `GROUP BY tile_id` in SQL instead of shipping every visit row across
/// the wire and re-grouping the tile in app code.
///
/// The formula must match TidepoolShared.GridTiler.tileID(for:) byte-for-byte
/// — the iOS client computes tile IDs the same way when bounding the
/// viewport. cos(), radians(), and floor() are immutable so the column is
/// safe as STORED.
struct AddVisitTileID: AsyncMigration {
    func prepare(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else {
            throw Abort(.internalServerError, reason: "SQL database required")
        }

        try await sql.raw("""
            ALTER TABLE visits
            ADD COLUMN tile_id TEXT GENERATED ALWAYS AS (
                'grid_150_m_' ||
                floor((longitude + 180.0) * (111000.0 * cos(radians(latitude))) / 150.0)::bigint ||
                '_' ||
                floor((latitude + 90.0) * 111000.0 / 150.0)::bigint
            ) STORED
            """).run()

        try await sql.raw("CREATE INDEX idx_visits_tile_id ON visits(tile_id)").run()

        // Covering index for the aligned-heat query: tile_id range + day-of-week
        // filter + device_id grouping. INCLUDE keeps the planner from having
        // to hit the heap for hour_of_day.
        try await sql.raw("""
            CREATE INDEX idx_visits_tile_day_device
            ON visits(tile_id, day_of_week, device_id)
            INCLUDE (hour_of_day)
            """).run()
    }

    func revert(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else { return }
        try await sql.raw("DROP INDEX IF EXISTS idx_visits_tile_day_device").run()
        try await sql.raw("DROP INDEX IF EXISTS idx_visits_tile_id").run()
        try await sql.raw("ALTER TABLE visits DROP COLUMN IF EXISTS tile_id").run()
    }
}
