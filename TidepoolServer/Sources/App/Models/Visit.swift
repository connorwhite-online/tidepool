import Fluent
import Vapor

final class Visit: Model, Content, @unchecked Sendable {
    static let schema = "visits"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "device_id")
    var device: Device

    @OptionalField(key: "poi_id")
    var poiID: String?

    @OptionalField(key: "yelp_id")
    var yelpID: String?

    @Field(key: "name")
    var name: String

    @Field(key: "category")
    var category: String

    @Field(key: "latitude")
    var latitude: Double

    @Field(key: "longitude")
    var longitude: Double

    @Field(key: "arrived_at")
    var arrivedAt: Date

    @Field(key: "departed_at")
    var departedAt: Date

    @Field(key: "day_of_week")
    var dayOfWeek: Int

    @Field(key: "hour_of_day")
    var hourOfDay: Int

    @Field(key: "duration_minutes")
    var durationMinutes: Int

    @Field(key: "confidence")
    var confidence: Float

    @Field(key: "source")
    var source: String

    @Field(key: "created_at")
    var createdAt: Date

    init() {}
}
