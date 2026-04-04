import Fluent
import Vapor

/// DeviceProfile stores the interest vector for a device.
/// The `interest_vector` column is a pgvector `vector(130)` type, stored as a
/// comma-separated string like "[0.1,0.2,...]" for raw SQL queries.
/// Fluent doesn't natively support pgvector, so vector operations use raw SQL.
final class DeviceProfile: Model, Content, @unchecked Sendable {
    static let schema = "device_profiles"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "device_id")
    var device: Device

    // pgvector column — we store/retrieve via raw SQL, but keep a Fluent field
    // for basic CRUD. Fluent sees it as a String like "[0.1,0.2,...]".
    @Field(key: "interest_vector")
    var interestVector: String

    @Field(key: "vector_version")
    var vectorVersion: Int

    @Field(key: "quality")
    var quality: String

    @Field(key: "active_sources")
    var activeSources: [String]

    @Field(key: "updated_at")
    var updatedAt: Date

    init() {}

    init(id: UUID? = nil, deviceID: UUID, vector: [Float], quality: String, activeSources: [String]) {
        self.id = id
        self.$device.id = deviceID
        self.interestVector = DeviceProfile.vectorToString(vector)
        self.vectorVersion = 1
        self.quality = quality
        self.activeSources = activeSources
        self.updatedAt = Date()
    }

    // MARK: - Vector Helpers

    static func vectorToString(_ vector: [Float]) -> String {
        "[" + vector.map { String($0) }.joined(separator: ",") + "]"
    }

    static func stringToVector(_ str: String) -> [Float] {
        let trimmed = str.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return trimmed.split(separator: ",").compactMap { Float($0.trimmingCharacters(in: .whitespaces)) }
    }

    var vectorArray: [Float] {
        DeviceProfile.stringToVector(interestVector)
    }
}
