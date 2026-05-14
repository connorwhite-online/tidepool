import Fluent
import Vapor
import SQLKit

/// Adds an index on visits(device_id, arrived_at DESC) so the
/// `getRecentVisits` query (Profile → Check-ins list) can satisfy
/// `WHERE device_id = ? ORDER BY arrived_at DESC LIMIT 50` from the index
/// without a sort. The existing idx_visits_device covered the filter but not
/// the sort, so Postgres had to fetch every row for the user and sort it.
struct AddVisitsRecentIndex: AsyncMigration {
    func prepare(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else {
            throw Abort(.internalServerError, reason: "SQL database required")
        }
        try await sql.raw("""
            CREATE INDEX idx_visits_device_arrived
            ON visits(device_id, arrived_at DESC)
            """).run()
    }

    func revert(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else { return }
        try await sql.raw("DROP INDEX IF EXISTS idx_visits_device_arrived").run()
    }
}
