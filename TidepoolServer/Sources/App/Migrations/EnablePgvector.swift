import Fluent
import SQLKit

struct EnablePgvector: AsyncMigration {
    func prepare(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else { return }
        try await sql.raw("CREATE EXTENSION IF NOT EXISTS vector").run()
    }

    func revert(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else { return }
        try await sql.raw("DROP EXTENSION IF EXISTS vector").run()
    }
}
