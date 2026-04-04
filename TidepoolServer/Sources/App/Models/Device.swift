import Fluent
import Vapor

final class Device: Model, Content, @unchecked Sendable {
    static let schema = "devices"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "key_id")
    var keyID: String

    @OptionalField(key: "attestation_hash")
    var attestationHash: String?

    @Field(key: "app_version")
    var appVersion: String

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Field(key: "last_seen_at")
    var lastSeenAt: Date

    @Field(key: "is_banned")
    var isBanned: Bool

    init() {}

    init(id: UUID? = nil, keyID: String, attestationHash: String? = nil,
         appVersion: String, isBanned: Bool = false) {
        self.id = id
        self.keyID = keyID
        self.attestationHash = attestationHash
        self.appVersion = appVersion
        self.lastSeenAt = Date()
        self.isBanned = isBanned
    }
}
