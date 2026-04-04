import Fluent
import Vapor

final class Favorite: Model, Content, @unchecked Sendable {
    static let schema = "favorites"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "device_id")
    var device: Device

    @Field(key: "place_id")
    var placeID: String

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

    @OptionalField(key: "rating")
    var rating: Int?

    @Field(key: "created_at")
    var createdAt: Date

    init() {}

    init(deviceID: UUID, placeID: String, yelpID: String?, name: String, category: String,
         latitude: Double, longitude: Double, rating: Int?) {
        self.$device.id = deviceID
        self.placeID = placeID
        self.yelpID = yelpID
        self.name = name
        self.category = category
        self.latitude = latitude
        self.longitude = longitude
        self.rating = rating
        self.createdAt = Date()
    }
}
