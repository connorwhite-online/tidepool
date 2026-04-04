import Fluent

struct CreateDevices: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("devices")
            .id()
            .field("key_id", .string, .required)
            .field("attestation_hash", .string)
            .field("app_version", .string, .required)
            .field("created_at", .datetime, .required)
            .field("last_seen_at", .datetime, .required)
            .field("is_banned", .bool, .required, .custom("DEFAULT FALSE"))
            .unique(on: "key_id")
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema("devices").delete()
    }
}
